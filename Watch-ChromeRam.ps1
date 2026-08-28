#Requires -Version 5.1

<#
.SYNOPSIS
Monitors Windows memory pressure and one or all Chrome instances.

.DESCRIPTION
Chrome RAM Watch reports Windows memory pressure and the Chrome processes that
belong to one browser process tree or all Chrome browser process trees in the
current Windows session. It is read-only. It does not close tabs, end
processes, inspect page contents, change Chrome settings, write files, or use
the network.

Chrome normally shares one browser instance across profiles that use the same
user-data directory. A launch profile shown by this script is only a startup
hint. It is not reliable per-profile attribution.

.PARAMETER BrowserProcessId
Root process ID of a Chrome browser instance. If omitted, the script selects
the single standard Chrome instance in the current Windows session and ignores
instances launched with a custom --user-data-dir.

.PARAMETER AllInstances
Monitors all Chrome browser process trees in the current Windows session and
reports their combined totals. Cannot be combined with -BrowserProcessId.

.PARAMETER ListInstances
Lists Chrome browser instances in the current Windows session and exits.

.PARAMETER RefreshSeconds
Seconds between samples. The default is 10.

.PARAMETER Top
Number of Chrome processes to display. The default is 12.

.PARAMETER Once
Collects one sample and exits.

.PARAMETER SampleCount
Number of sampling intervals to attempt. Unavailable intervals count toward a
finite limit so bounded observation cannot retry forever. Zero, the default,
runs until Ctrl+C. One is equivalent to -Once. -Once may be combined with
-SampleCount 0 or 1, but not a value greater than 1.

.PARAMETER Json
Writes one machine-readable JSON sample. Requires -Once or -SampleCount 1.

.PARAMETER NoClear
Does not clear the console between continuous samples.

.EXAMPLE
.\Watch-ChromeRam.ps1

Automatically detects the standard Chrome instance and refreshes every ten
seconds.

.EXAMPLE
.\Watch-ChromeRam.ps1 -ListInstances

Lists selectable Chrome browser process IDs.

.EXAMPLE
.\Watch-ChromeRam.ps1 -BrowserProcessId 10536 -Once

Collects one sample for the Chrome instance rooted at process 10536.

.EXAMPLE
.\Watch-ChromeRam.ps1 -AllInstances -SampleCount 6 -NoClear

Attempts six combined sampling intervals for every Chrome instance in the
current Windows session without clearing earlier samples.

.EXAMPLE
.\Watch-ChromeRam.ps1 -Once -Json

Writes one JSON sample for automation or logging.
#>

[CmdletBinding()]
param(
    [ValidateRange(0, 2147483647)]
    [int]$BrowserProcessId = 0,
    [switch]$AllInstances,
    [switch]$ListInstances,
    [ValidateRange(5, 300)]
    [int]$RefreshSeconds = 10,
    [ValidateRange(3, 50)]
    [int]$Top = 12,
    [switch]$Once,
    [ValidateRange(0, 2147483647)]
    [int]$SampleCount = 0,
    [switch]$Json,
    [switch]$NoClear
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ChromeRamWatchVersion = '0.2.0'
$script:CurrentSessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
$script:LogicalProcessorCount = [math]::Max(1, [Environment]::ProcessorCount)
$script:Options = [pscustomobject]@{
    BrowserProcessId = $BrowserProcessId
    AllInstances     = [bool]$AllInstances
    ListInstances    = [bool]$ListInstances
    RefreshSeconds   = $RefreshSeconds
    Top              = $Top
    Once             = [bool]$Once
    SampleCount      = $SampleCount
    Json             = [bool]$Json
    NoClear          = [bool]$NoClear
}
$script:PreviousProcessSamples = @{}
$script:PreviousSampleAt = $null
$script:PreviousScopePrivateBytes = $null
$script:PreviousScopeRootIdentityKey = $null
$script:PinnedBrowserRootIdentity = $null
$script:PressureStreakSamples = 0
$script:SustainedPressureThresholdSamples = 3
# CIM and System.Diagnostics can represent the same process start with slightly
# different sub-second precision. Differences over one second are treated as a
# PID-reuse race, not as the same process.
$script:ProcessCreationTimeToleranceSeconds = 1.0

function Get-ChromeProcessType {
    param([string]$CommandLine)

    if ($CommandLine -match '--type=([^\s\"]+)') {
        return $matches[1]
    }

    return 'browser/other'
}

function Get-ChromeLaunchProfile {
    param([string]$CommandLine)

    if ($CommandLine -match '--profile-directory=\"([^\"]+)\"') {
        return $matches[1]
    }

    if ($CommandLine -match '--profile-directory=(.+?)(?=\s+--|$)') {
        $profileHint = $matches[1].Trim()
        if ($profileHint.Length -gt 0) {
            return $profileHint
        }
    }

    return $null
}

function Get-ChromeUserDataMode {
    param([string]$CommandLine)

    if ($CommandLine -match '--user-data-dir=') {
        return 'Custom'
    }

    return 'Standard'
}

function Get-ChromeChannelHint {
    param([string]$ExecutablePath)

    if ($ExecutablePath -match '\\Chrome SxS\\') {
        return 'Canary'
    }

    if ($ExecutablePath -match '\\Chrome Beta\\') {
        return 'Beta'
    }

    if ($ExecutablePath -match '\\Chrome Dev\\') {
        return 'Dev'
    }

    if ($ExecutablePath -match '\\Google\\Chrome\\') {
        return 'Stable'
    }

    return 'Chrome/Chromium'
}

function Get-ChromeProcessInventory {
    return @(
        Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction Stop |
            Where-Object { [int]$_.SessionId -eq $script:CurrentSessionId }
    )
}

function Get-CimProcessCreationTimeUtc {
    param([object]$CimProcess)

    if ($null -eq $CimProcess -or $null -eq $CimProcess.CreationDate) {
        return $null
    }

    try {
        $creationTime = if ($CimProcess.CreationDate -is [datetime]) {
            [datetime]$CimProcess.CreationDate
        }
        else {
            [System.Management.ManagementDateTimeConverter]::ToDateTime(
                [string]$CimProcess.CreationDate
            )
        }
        return $creationTime.ToUniversalTime()
    }
    catch {
        Write-Verbose (
            'Could not read CIM creation time for PID {0}: {1}' -f
            $CimProcess.ProcessId,
            $_.Exception.Message
        )
        return $null
    }
}

function Test-ChromeParentChildEdge {
    param(
        [object]$ParentProcess,
        [object]$ChildProcess
    )

    $parentProcessId = [int]$ParentProcess.ProcessId
    $childProcessId = [int]$ChildProcess.ProcessId
    if ($parentProcessId -eq $childProcessId) {
        Write-Verbose "Excluded self-referential Chrome parent edge for PID $childProcessId."
        return $false
    }

    $parentCreatedAt = Get-CimProcessCreationTimeUtc -CimProcess $ParentProcess
    $childCreatedAt = Get-CimProcessCreationTimeUtc -CimProcess $ChildProcess
    if ($null -eq $parentCreatedAt -or $null -eq $childCreatedAt) {
        Write-Verbose (
            'Excluded Chrome parent edge {0} -> {1} because creation timing is unavailable.' -f
            $parentProcessId,
            $childProcessId
        )
        return $false
    }

    if ($parentCreatedAt -gt $childCreatedAt) {
        Write-Verbose (
            'Excluded impossible Chrome parent edge {0} -> {1}: the parent is newer than the child.' -f
            $parentProcessId,
            $childProcessId
        )
        return $false
    }

    return $true
}

function Get-ChromeBrowserRoot {
    param([object[]]$ChromeProcesses)

    $chromeById = @{}
    foreach ($process in $ChromeProcesses) {
        $chromeById[[int]$process.ProcessId] = $process
    }

    return @(
        $ChromeProcesses | Where-Object {
            if (-not $_.CommandLine -or $_.CommandLine -match '--type=') {
                return $false
            }

            $parentProcessId = [int]$_.ParentProcessId
            if (-not $chromeById.ContainsKey($parentProcessId)) {
                return $true
            }

            return -not (Test-ChromeParentChildEdge `
                -ParentProcess $chromeById[$parentProcessId] `
                -ChildProcess $_)
        }
    )
}

function Get-ChromeInstance {
    param([object[]]$ChromeProcesses)

    return @(
        Get-ChromeBrowserRoot -ChromeProcesses $ChromeProcesses |
            ForEach-Object {
                [pscustomobject]@{
                    BrowserProcessId  = [int]$_.ProcessId
                    Channel           = Get-ChromeChannelHint -ExecutablePath ([string]$_.ExecutablePath)
                    UserDataMode      = Get-ChromeUserDataMode -CommandLine ([string]$_.CommandLine)
                    LaunchProfileHint = Get-ChromeLaunchProfile -CommandLine ([string]$_.CommandLine)
                    ExecutablePath    = [string]$_.ExecutablePath
                    ProcessObject     = $_
                }
            }
    )
}

function Resolve-ChromeBrowserRoot {
    param(
        [object[]]$ChromeProcesses,
        [int]$RequestedBrowserProcessId
    )

    $instances = @(Get-ChromeInstance -ChromeProcesses $ChromeProcesses)

    if ($RequestedBrowserProcessId -gt 0) {
        $match = @(
            $instances | Where-Object { $_.BrowserProcessId -eq $RequestedBrowserProcessId }
        )
        if ($match.Count -eq 1) {
            return $match[0].ProcessObject
        }

        throw "Chrome browser root PID $RequestedBrowserProcessId is not running in Windows session $script:CurrentSessionId. Run with -ListInstances to see current root PIDs."
    }

    $standardInstances = @($instances | Where-Object { $_.UserDataMode -eq 'Standard' })
    if ($standardInstances.Count -eq 1) {
        return $standardInstances[0].ProcessObject
    }

    if ($standardInstances.Count -eq 0) {
        throw 'No standard Chrome browser instance was detected. Run with -ListInstances, then pass -BrowserProcessId to select a custom instance.'
    }

    $processIds = ($standardInstances.BrowserProcessId | Sort-Object) -join ', '
    throw "Multiple standard Chrome browser instances were detected (root PIDs: $processIds). Run with -ListInstances, then pass -BrowserProcessId."
}

function Resolve-ChromeBrowserRootSet {
    param(
        [object[]]$ChromeProcesses,
        [int]$RequestedBrowserProcessId,
        [bool]$IncludeAllInstances
    )

    if ($IncludeAllInstances) {
        $roots = @(Get-ChromeBrowserRoot -ChromeProcesses $ChromeProcesses)
        if ($roots.Count -eq 0) {
            throw "No Chrome browser instances were detected in Windows session $script:CurrentSessionId."
        }

        return @($roots | Sort-Object { [int]$_.ProcessId })
    }

    return @(
        Resolve-ChromeBrowserRoot `
            -ChromeProcesses $ChromeProcesses `
            -RequestedBrowserProcessId $RequestedBrowserProcessId
    )
}

function Get-ChromeDescendantProcessId {
    param(
        [object[]]$ChromeProcesses,
        [int]$RootProcessId
    )

    $chromeById = @{}
    foreach ($process in $ChromeProcesses) {
        $chromeById[[int]$process.ProcessId] = $process
    }

    $processIds = [System.Collections.Generic.HashSet[int]]::new()
    [void]$processIds.Add($RootProcessId)

    $added = $true
    while ($added) {
        $added = $false
        foreach ($process in $ChromeProcesses) {
            $parentProcessId = [int]$process.ParentProcessId
            if (
                $processIds.Contains($parentProcessId) -and
                -not $processIds.Contains([int]$process.ProcessId) -and
                $chromeById.ContainsKey($parentProcessId) -and
                (Test-ChromeParentChildEdge `
                    -ParentProcess $chromeById[$parentProcessId] `
                    -ChildProcess $process)
            ) {
                [void]$processIds.Add([int]$process.ProcessId)
                $added = $true
            }
        }
    }

    return @($processIds)
}

function Initialize-ChromeCpuSample {
    $script:PreviousProcessSamples = @{}
    $script:PreviousSampleAt = $null
    $script:PreviousScopePrivateBytes = $null
    $script:PreviousScopeRootIdentityKey = $null
    $script:PressureStreakSamples = 0
}

function Get-ChromeProcessCreationInfo {
    param(
        [int]$ProcessId,
        [object]$CimProcess,
        [object]$RuntimeProcess,
        [datetime]$SampleAt,
        [switch]$RequireSourceMatch
    )

    $cimCreationTimeUtc = Get-CimProcessCreationTimeUtc -CimProcess $CimProcess
    $runtimeCreationTimeUtc = $null
    if ($null -ne $RuntimeProcess) {
        try {
            $runtimeCreationTimeUtc = ([datetime]$RuntimeProcess.StartTime).ToUniversalTime()
        }
        catch {
            Write-Verbose "Could not read runtime creation time for PID $ProcessId`: $($_.Exception.Message)"
        }
    }

    if ($RequireSourceMatch) {
        if ($null -eq $cimCreationTimeUtc -or $null -eq $runtimeCreationTimeUtc) {
            throw "Chrome PID $ProcessId has incomplete CIM/runtime creation timing, so its identity cannot be joined safely."
        }

        $creationDifferenceSeconds = [math]::Abs(
            ($cimCreationTimeUtc - $runtimeCreationTimeUtc).TotalSeconds
        )
        if ($creationDifferenceSeconds -gt $script:ProcessCreationTimeToleranceSeconds) {
            throw (
                'Chrome PID {0} changed identity between CIM and runtime collection ' +
                '(creation times differ by {1:N3} seconds; tolerance: {2:N1}). Retry the sample.' -f
                $ProcessId,
                $creationDifferenceSeconds,
                $script:ProcessCreationTimeToleranceSeconds
            )
        }
    }

    $creationTimeUtc = if ($null -ne $cimCreationTimeUtc) {
        $cimCreationTimeUtc
    }
    else {
        $runtimeCreationTimeUtc
    }

    if ($null -eq $creationTimeUtc) {
        return [pscustomobject]@{
            CreatedAt         = $null
            CreationIdentity  = "${ProcessId}@unknown-$($SampleAt.ToUniversalTime().Ticks)"
            ProcessAgeSeconds = $null
            ProcessAge        = 'unknown'
        }
    }

    $ageSeconds = [math]::Max(
        0,
        ($SampleAt.ToUniversalTime() - $creationTimeUtc).TotalSeconds
    )
    $age = [timespan]::FromSeconds($ageSeconds)
    if ($age.Days -gt 0) {
        $ageText = '{0}d {1:00}:{2:00}:{3:00}' -f $age.Days, $age.Hours, $age.Minutes, $age.Seconds
    }
    else {
        $ageText = '{0:00}:{1:00}:{2:00}' -f $age.Hours, $age.Minutes, $age.Seconds
    }

    return [pscustomobject]@{
        CreatedAt         = $creationTimeUtc.ToString('o')
        CreationIdentity  = '{0}@{1}' -f $ProcessId, $creationTimeUtc.Ticks
        ProcessAgeSeconds = [math]::Round($ageSeconds, 0)
        ProcessAge        = $ageText
    }
}

function Get-SystemPressureAssessment {
    param(
        [double]$AvailableRamPercent,
        [double]$CommitPercent
    )

    if ($AvailableRamPercent -le 5) {
        $availableLevel = 'Critical'
        $availableReason = 'Available RAM is {0:N1}% (Critical threshold: 5% or less).' -f $AvailableRamPercent
    }
    elseif ($AvailableRamPercent -le 10) {
        $availableLevel = 'High'
        $availableReason = 'Available RAM is {0:N1}% (High threshold: 10% or less).' -f $AvailableRamPercent
    }
    elseif ($AvailableRamPercent -le 20) {
        $availableLevel = 'Elevated'
        $availableReason = 'Available RAM is {0:N1}% (Elevated threshold: 20% or less).' -f $AvailableRamPercent
    }
    else {
        $availableLevel = 'Normal'
        $availableReason = 'Available RAM is {0:N1}% (Normal: above 20%).' -f $AvailableRamPercent
    }

    if ($CommitPercent -ge 95) {
        $commitLevel = 'Critical'
        $commitReason = 'Commit usage is {0:N1}% (Critical threshold: 95% or more).' -f $CommitPercent
    }
    elseif ($CommitPercent -ge 90) {
        $commitLevel = 'High'
        $commitReason = 'Commit usage is {0:N1}% (High threshold: 90% or more).' -f $CommitPercent
    }
    elseif ($CommitPercent -ge 80) {
        $commitLevel = 'Elevated'
        $commitReason = 'Commit usage is {0:N1}% (Elevated threshold: 80% or more).' -f $CommitPercent
    }
    else {
        $commitLevel = 'Normal'
        $commitReason = 'Commit usage is {0:N1}% (Normal: below 80%).' -f $CommitPercent
    }

    $severity = @{
        Normal   = 0
        Elevated = 1
        High     = 2
        Critical = 3
    }
    $pressureLevel = $availableLevel
    if ($severity[$commitLevel] -gt $severity[$pressureLevel]) {
        $pressureLevel = $commitLevel
    }

    $reasons = @($availableReason, $commitReason)
    return [pscustomobject]@{
        Level   = $pressureLevel
        Reason  = $reasons -join ' '
        Reasons = $reasons
    }
}

function Get-SustainedPressureAssessment {
    param(
        [ValidateSet('Normal', 'Elevated', 'High', 'Critical')]
        [string]$PressureLevel,
        [ValidateRange(0, 2147483647)]
        [int]$CurrentStreakSamples,
        [ValidateRange(1, 2147483647)]
        [int]$ThresholdSamples
    )

    $nextStreakSamples = if ($PressureLevel -eq 'Normal') {
        0
    }
    else {
        $CurrentStreakSamples + 1
    }

    return [pscustomobject]@{
        PressureStreakSamples             = $nextStreakSamples
        SustainedPressureThresholdSamples = $ThresholdSamples
        SustainedPressure                 = $nextStreakSamples -ge $ThresholdSamples
    }
}

function Get-ChromeCpuPercent {
    param(
        [double]$CurrentCpuSeconds,
        [double]$PreviousCpuSeconds,
        [double]$ElapsedSeconds,
        [int]$LogicalProcessorCount
    )

    if ($ElapsedSeconds -le 0 -or $LogicalProcessorCount -le 0) {
        return 0.0
    }

    $rawCpuPercent = (
        (($CurrentCpuSeconds - $PreviousCpuSeconds) / $ElapsedSeconds) * 100
    ) / $LogicalProcessorCount
    return [math]::Round([math]::Min(100, [math]::Max(0, $rawCpuPercent)), 1)
}

function Get-ChromeRamSnapshot {
    param(
        [object[]]$ChromeProcesses,
        [object[]]$BrowserRoots,
        [int]$SampleNumber
    )

    $sampleAt = Get-Date
    if ($BrowserRoots.Count -eq 0) {
        throw 'No Chrome browser roots were supplied for this sample.'
    }

    $rootProcessIds = @($BrowserRoots | ForEach-Object { [int]$_.ProcessId } | Sort-Object)
    foreach ($rootProcessId in $rootProcessIds) {
        $activeRoot = @($ChromeProcesses | Where-Object { [int]$_.ProcessId -eq $rootProcessId })
        if ($activeRoot.Count -ne 1) {
            throw "Chrome browser root PID $rootProcessId is no longer running."
        }
    }

    $processIdSet = [System.Collections.Generic.HashSet[int]]::new()
    $rootProcessIdByProcessId = @{}
    foreach ($rootProcessId in $rootProcessIds) {
        $instanceProcessIds = @(
            Get-ChromeDescendantProcessId `
                -ChromeProcesses $ChromeProcesses `
                -RootProcessId $rootProcessId
        )
        foreach ($processId in $instanceProcessIds) {
            [void]$processIdSet.Add([int]$processId)
            if (-not $rootProcessIdByProcessId.ContainsKey([int]$processId)) {
                $rootProcessIdByProcessId[[int]$processId] = $rootProcessId
            }
        }
    }

    $cimById = @{}
    foreach ($process in $ChromeProcesses) {
        $cimById[[int]$process.ProcessId] = $process
    }

    $runtimeProcesses = @(foreach ($runtimeProcess in @(Get-Process chrome -ErrorAction SilentlyContinue)) {
        try {
            if (
                $runtimeProcess.SessionId -eq $script:CurrentSessionId -and
                $processIdSet.Contains([int]$runtimeProcess.Id)
            ) {
                $runtimeProcess
            }
        }
        catch {
            Write-Verbose "Skipped a Chrome process that exited before collection: $($_.Exception.Message)"
        }
    })

    $elapsedSeconds = $null
    if ($null -ne $script:PreviousSampleAt) {
        $elapsedSeconds = ($sampleAt - $script:PreviousSampleAt).TotalSeconds
    }

    $currentProcessSamples = @{}
    $growingProcessCount = 0
    $trendProcessCount = 0
    $rows = @(foreach ($process in $runtimeProcesses) {
        try {
            $processId = [int]$process.Id
            $cpuSeconds = if ($null -eq $process.CPU) { 0.0 } else { [double]$process.CPU }
            $workingSetBytes = [int64]$process.WorkingSet64
            $privateBytes = [int64]$process.PrivateMemorySize64
        }
        catch {
            Write-Verbose "Skipped a Chrome process that exited during collection: $($_.Exception.Message)"
            continue
        }

        $cimProcess = $null
        if ($cimById.ContainsKey($processId)) {
            $cimProcess = $cimById[$processId]
        }
        $creation = Get-ChromeProcessCreationInfo `
            -ProcessId $processId `
            -CimProcess $cimProcess `
            -RuntimeProcess $process `
            -SampleAt $sampleAt `
            -RequireSourceMatch

        $workingSetDeltaMB = $null
        $privateBytesDeltaMB = $null
        $privateGrowthMBPerMinute = $null
        $cpuPercent = $null
        if (
            $null -ne $elapsedSeconds -and
            $elapsedSeconds -gt 0 -and
            $script:PreviousProcessSamples.ContainsKey($creation.CreationIdentity)
        ) {
            $previous = $script:PreviousProcessSamples[$creation.CreationIdentity]
            $cpuPercent = Get-ChromeCpuPercent `
                -CurrentCpuSeconds $cpuSeconds `
                -PreviousCpuSeconds $previous.CpuSeconds `
                -ElapsedSeconds $elapsedSeconds `
                -LogicalProcessorCount $script:LogicalProcessorCount

            $workingSetDeltaBytes = [int64]($workingSetBytes - $previous.WorkingSetBytes)
            $privateBytesDeltaBytes = [int64]($privateBytes - $previous.PrivateBytes)
            $workingSetDeltaMB = [math]::Round($workingSetDeltaBytes / 1MB, 2)
            $privateBytesDeltaMB = [math]::Round($privateBytesDeltaBytes / 1MB, 2)
            $privateGrowthMBPerMinute = [math]::Round(
                (($privateBytesDeltaBytes / 1MB) * 60) / $elapsedSeconds,
                2
            )
            $trendProcessCount++
            if ($privateBytesDeltaBytes -gt 0) {
                $growingProcessCount++
            }
        }

        $commandLine = ''
        if ($null -ne $cimProcess) {
            $commandLine = [string]$cimProcess.CommandLine
        }

        $currentProcessSamples[$creation.CreationIdentity] = [pscustomobject]@{
            PID             = $processId
            CpuSeconds      = $cpuSeconds
            WorkingSetBytes = $workingSetBytes
            PrivateBytes    = $privateBytes
            SampleAt        = $sampleAt
        }

        [pscustomobject]@{
            PID                       = $processId
            RootProcessId             = [int]$rootProcessIdByProcessId[$processId]
            Type                      = Get-ChromeProcessType -CommandLine $commandLine
            Extension                 = $commandLine -match '--extension-process'
            CreationIdentity          = $creation.CreationIdentity
            CreatedAt                 = $creation.CreatedAt
            ProcessAgeSeconds         = $creation.ProcessAgeSeconds
            ProcessAge                = $creation.ProcessAge
            WorkingSetBytes           = $workingSetBytes
            PrivateBytes              = $privateBytes
            WorkingSetMB              = [math]::Round($workingSetBytes / 1MB, 0)
            WorkingSetDeltaMB         = $workingSetDeltaMB
            PrivateBytesMB            = [math]::Round($privateBytes / 1MB, 0)
            PrivateBytesDeltaMB       = $privateBytesDeltaMB
            PrivateGrowthMBPerMinute  = $privateGrowthMBPerMinute
            CPUPercent                = $cpuPercent
        }
    })

    $sampledProcessIds = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($row in $rows) {
        [void]$sampledProcessIds.Add([int]$row.PID)
    }
    foreach ($rootProcessId in $rootProcessIds) {
        if (-not $sampledProcessIds.Contains($rootProcessId)) {
            throw "Chrome browser root PID $rootProcessId exited or changed identity during runtime collection."
        }
    }

    $operatingSystem = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $memory = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop
    $workingSetSum = ($rows | Measure-Object WorkingSetBytes -Sum).Sum
    $privateBytesSum = ($rows | Measure-Object PrivateBytes -Sum).Sum
    if ($null -eq $workingSetSum) {
        $workingSetSum = 0
    }
    if ($null -eq $privateBytesSum) {
        $privateBytesSum = 0
    }
    $workingSetSum = [int64]$workingSetSum
    $privateBytesSum = [int64]$privateBytesSum

    $totalRamGB = [math]::Round($operatingSystem.TotalVisibleMemorySize / 1MB, 2)
    $availableRamGB = [math]::Round($operatingSystem.FreePhysicalMemory / 1MB, 2)
    $totalVisibleMemorySize = [double]$operatingSystem.TotalVisibleMemorySize
    if ($totalVisibleMemorySize -le 0) {
        throw 'Windows total visible memory is unavailable, so pressure cannot be classified safely.'
    }

    $availableRamPercentRaw = (
        [double]$operatingSystem.FreePhysicalMemory / $totalVisibleMemorySize
    ) * 100
    $availableRamPercent = [math]::Round($availableRamPercentRaw, 1)

    $commitLimitBytes = [double]$memory.CommitLimit
    if ($commitLimitBytes -le 0) {
        throw 'Windows commit limit is unavailable, so pressure cannot be classified safely.'
    }

    $commitPercentRaw = ([double]$memory.CommittedBytes / $commitLimitBytes) * 100
    $commitPercent = [math]::Round($commitPercentRaw, 1)
    $pressure = Get-SystemPressureAssessment `
        -AvailableRamPercent $availableRamPercentRaw `
        -CommitPercent $commitPercentRaw
    $sustainedPressure = Get-SustainedPressureAssessment `
        -PressureLevel $pressure.Level `
        -CurrentStreakSamples $script:PressureStreakSamples `
        -ThresholdSamples $script:SustainedPressureThresholdSamples

    $reportedGrowingProcessCount = $null
    if ($null -ne $elapsedSeconds -and $elapsedSeconds -gt 0 -and $trendProcessCount -gt 0) {
        $reportedGrowingProcessCount = $growingProcessCount
    }

    $processProperties = @(
        'PID',
        'RootProcessId',
        'Type',
        'Extension',
        'CreationIdentity',
        'CreatedAt',
        'ProcessAgeSeconds',
        'ProcessAge',
        'WorkingSetMB',
        'WorkingSetDeltaMB',
        'PrivateBytesMB',
        'PrivateBytesDeltaMB',
        'PrivateGrowthMBPerMinute',
        'CPUPercent'
    )
    $allProcesses = @(
        $rows |
            Sort-Object PID |
            Select-Object -Property $processProperties
    )
    $topProcesses = @(
        $rows |
            Sort-Object WorkingSetBytes -Descending |
            Select-Object -First $script:Options.Top -Property $processProperties
    )

    $instances = @(foreach ($browserRoot in $BrowserRoots) {
        $rootProcessId = [int]$browserRoot.ProcessId
        $creation = Get-ChromeProcessCreationInfo `
            -ProcessId $rootProcessId `
            -CimProcess $browserRoot `
            -RuntimeProcess $null `
            -SampleAt $sampleAt
        [pscustomobject]@{
            RootProcessId      = $rootProcessId
            CreationIdentity   = $creation.CreationIdentity
            CreatedAt          = $creation.CreatedAt
            ProcessAgeSeconds  = $creation.ProcessAgeSeconds
            Channel            = Get-ChromeChannelHint -ExecutablePath ([string]$browserRoot.ExecutablePath)
            UserDataMode       = Get-ChromeUserDataMode -CommandLine ([string]$browserRoot.CommandLine)
            LaunchProfileHint  = Get-ChromeLaunchProfile -CommandLine ([string]$browserRoot.CommandLine)
            ExecutablePath     = [string]$browserRoot.ExecutablePath
        }
    })
    $instances = @($instances | Sort-Object RootProcessId)
    $rootCreationIdentityKey = (@(
        $instances.CreationIdentity | Sort-Object
    )) -join '|'
    $totalPrivateGrowthMBPerMinute = $null
    if (
        $null -ne $elapsedSeconds -and
        $elapsedSeconds -gt 0 -and
        $null -ne $script:PreviousScopePrivateBytes -and
        $null -ne $script:PreviousScopeRootIdentityKey -and
        $script:PreviousScopeRootIdentityKey -ceq $rootCreationIdentityKey
    ) {
        $scopePrivateDeltaBytes = [int64](
            $privateBytesSum - $script:PreviousScopePrivateBytes
        )
        $totalPrivateGrowthMBPerMinute = [math]::Round(
            (($scopePrivateDeltaBytes / 1MB) * 60) / $elapsedSeconds,
            2
        )
    }

    $channels = @($instances.Channel | Sort-Object -Unique)
    $userDataModes = @($instances.UserDataMode | Sort-Object -Unique)
    $channel = if ($channels.Count -eq 1) { $channels[0] } else { 'Mixed' }
    $userDataMode = if ($userDataModes.Count -eq 1) { $userDataModes[0] } else { 'Mixed' }
    $launchProfileHint = if ($instances.Count -eq 1) {
        $instances[0].LaunchProfileHint
    }
    else {
        $null
    }
    $rootProcessId = if (-not $script:Options.AllInstances -and $rootProcessIds.Count -eq 1) {
        $rootProcessIds[0]
    }
    else {
        $null
    }

    $script:PreviousProcessSamples = $currentProcessSamples
    $script:PreviousSampleAt = $sampleAt
    $script:PreviousScopePrivateBytes = $privateBytesSum
    $script:PreviousScopeRootIdentityKey = $rootCreationIdentityKey
    $script:PressureStreakSamples = $sustainedPressure.PressureStreakSamples

    [pscustomobject]@{
        SampleAt                       = $sampleAt
        SampleNumber                   = $SampleNumber
        ScopeType                      = if ($script:Options.AllInstances) { 'all-browser-process-trees' } else { 'browser-process-tree' }
        AllInstances                   = $script:Options.AllInstances
        RootProcessId                  = $rootProcessId
        RootProcessIds                 = $rootProcessIds
        RootProcessCount               = $rootProcessIds.Count
        Instances                      = $instances
        Channel                        = $channel
        UserDataMode                   = $userDataMode
        LaunchProfileHint              = $launchProfileHint
        TotalRamGB                     = $totalRamGB
        AvailableRamGB                 = $availableRamGB
        AvailableRamPercent            = $availableRamPercent
        CommitGB                       = [math]::Round($memory.CommittedBytes / 1GB, 2)
        CommitLimitGB                  = [math]::Round($memory.CommitLimit / 1GB, 2)
        CommitPercent                  = $commitPercent
        PressureLevel                  = $pressure.Level
        PressureReason                 = $pressure.Reason
        PressureReasons                = $pressure.Reasons
        PressureStreakSamples          = $sustainedPressure.PressureStreakSamples
        SustainedPressureThresholdSamples = $sustainedPressure.SustainedPressureThresholdSamples
        SustainedPressure              = $sustainedPressure.SustainedPressure
        PagesPerSecond                 = [int64]$memory.PagesPersec
        PageReadsPerSecond             = [int64]$memory.PageReadsPersec
        ProcessCount                   = $rows.Count
        SummedWorkingSetGB             = [math]::Round($workingSetSum / 1GB, 2)
        PrivateBytesGB                 = [math]::Round($privateBytesSum / 1GB, 2)
        TrendIntervalSeconds           = if ($null -eq $elapsedSeconds) { $null } else { [math]::Round($elapsedSeconds, 2) }
        TrendProcessCount              = $trendProcessCount
        TotalPrivateGrowthMBPerMinute  = $totalPrivateGrowthMBPerMinute
        GrowingProcessCount            = $reportedGrowingProcessCount
        Processes                      = $allProcesses
        TopProcesses                   = $topProcesses
    }
}

function Clear-ChromeRamDisplay {
    if ($script:Options.NoClear -or $script:Options.Once -or $script:Options.Json) {
        return
    }

    try {
        Clear-Host
    }
    catch {
        Write-Verbose "Console clear skipped: $($_.Exception.Message)"
    }
}

function Show-ChromeRamSnapshot {
    param([pscustomobject]$Snapshot)

    Clear-ChromeRamDisplay
    Write-Host 'Chrome RAM Watch (read-only)' -ForegroundColor Cyan
    if ($Snapshot.AllInstances) {
        Write-Host (
            'Scope: all {0} Chrome browser process trees in session {1} | Root PIDs: {2}' -f
            $Snapshot.RootProcessCount,
            $script:CurrentSessionId,
            ($Snapshot.RootProcessIds -join ', ')
        )
        Write-Host (
            'Chrome channel: {0} | User data mode: {1} | Updated: {2}' -f
            $Snapshot.Channel,
            $Snapshot.UserDataMode,
            $Snapshot.SampleAt.ToString('yyyy-MM-dd HH:mm:ss')
        )
    }
    else {
        Write-Host (
            'Instance: {0} Chrome, {1} user data | Root PID: {2} | Updated: {3}' -f
            $Snapshot.Channel,
            $Snapshot.UserDataMode.ToLowerInvariant(),
            $Snapshot.RootProcessId,
            $Snapshot.SampleAt.ToString('yyyy-MM-dd HH:mm:ss')
        )
        if (-not [string]::IsNullOrWhiteSpace($Snapshot.LaunchProfileHint)) {
            Write-Host (
                'Launch profile hint: {0} (this process tree may contain other profiles)' -f
                $Snapshot.LaunchProfileHint
            )
        }
        else {
            Write-Host 'Scope: the browser process tree, which may contain multiple Chrome profiles.'
        }
    }
    Write-Host ''
    Write-Host (
        'System RAM: {0:N2} GB available of {1:N2} GB ({2:N1}%) | Commit: {3:N2}/{4:N2} GB ({5}%)' -f
        $Snapshot.AvailableRamGB,
        $Snapshot.TotalRamGB,
        $Snapshot.AvailableRamPercent,
        $Snapshot.CommitGB,
        $Snapshot.CommitLimitGB,
        $Snapshot.CommitPercent
    )
    $pressureColor = switch ($Snapshot.PressureLevel) {
        'Critical' { 'Red' }
        'High' { 'DarkYellow' }
        'Elevated' { 'Yellow' }
        default { 'Green' }
    }
    Write-Host ('System pressure: {0}' -f $Snapshot.PressureLevel) -ForegroundColor $pressureColor
    foreach ($reason in $Snapshot.PressureReasons) {
        Write-Host ('  - {0}' -f $reason)
    }
    if ($Snapshot.SustainedPressure) {
        Write-Host (
            'Sustained pressure: YES | Elevated-or-worse streak: {0} comparable successful samples (threshold: {1}).' -f
            $Snapshot.PressureStreakSamples,
            $Snapshot.SustainedPressureThresholdSamples
        ) -ForegroundColor Red
    }
    elseif ($Snapshot.PressureLevel -eq 'Normal') {
        Write-Host (
            'Sustained pressure: no | Elevated-or-worse streak: 0 comparable successful samples (threshold: {0}).' -f
            $Snapshot.SustainedPressureThresholdSamples
        )
    }
    else {
        Write-Host (
            'Sustained pressure: not yet | Elevated-or-worse streak: {0} comparable successful samples (threshold: {1}).' -f
            $Snapshot.PressureStreakSamples,
            $Snapshot.SustainedPressureThresholdSamples
        ) -ForegroundColor Yellow
    }
    Write-Host (
        'Memory paging: {0:N0} pages/sec | {1:N0} disk page-read operations/sec' -f
        $Snapshot.PagesPerSecond,
        $Snapshot.PageReadsPerSecond
    )
    Write-Host 'Paging rates are informational and do not determine pressure from a one-off spike.'
    Write-Host (
        'Chrome scope: {0} processes | {1:N2} GB summed working set | {2:N2} GB private bytes' -f
        $Snapshot.ProcessCount,
        $Snapshot.SummedWorkingSetGB,
        $Snapshot.PrivateBytesGB
    )
    if ($null -eq $Snapshot.TotalPrivateGrowthMBPerMinute) {
        Write-Host 'Chrome private growth: baseline sample collected; rates begin with the next comparable sample.'
    }
    else {
        Write-Host (
            'Chrome private growth: {0:N2} MB/min total | {1} growing processes | {2} comparable processes over {3:N2} sec' -f
            $Snapshot.TotalPrivateGrowthMBPerMinute,
            $Snapshot.GrowingProcessCount,
            $Snapshot.TrendProcessCount,
            $Snapshot.TrendIntervalSeconds
        )
    }
    Write-Host ''
    Write-Host 'Largest Chrome processes in this scope:' -ForegroundColor Yellow
    $tableProperties = @('PID')
    if ($Snapshot.AllInstances) {
        $tableProperties += 'RootProcessId'
    }
    $tableProperties += @(
        'Type',
        'Extension',
        'ProcessAge',
        'WorkingSetMB',
        'PrivateBytesMB',
        'CPUPercent'
    )
    $Snapshot.TopProcesses | Format-Table -Property $tableProperties -AutoSize

    Write-Host 'Per-process change since the previous comparable sample:' -ForegroundColor Yellow
    $Snapshot.TopProcesses |
        Format-Table `
            PID,
            WorkingSetDeltaMB,
            PrivateBytesDeltaMB,
            PrivateGrowthMBPerMinute `
            -AutoSize

    Write-Host 'Process creation identities (PID plus creation time):' -ForegroundColor Yellow
    $Snapshot.TopProcesses |
        Format-Table PID, CreatedAt, CreationIdentity -AutoSize

    Write-Host 'To map a renderer PID to its page:' -ForegroundColor Yellow
    Write-Host '1. Paste chrome://process-internals/#web-contents into Chrome.'
    Write-Host '2. Press Ctrl+F and search for the PID shown above.'
    Write-Host '3. Read the site and URL beside Frame[PID:routing_id].'
    Write-Host ''
    Write-Host 'This watcher never closes tabs, ends processes, or changes Chrome settings.'
    if ($script:Options.Once -or $script:Options.SampleCount -eq 1) {
        return
    }

    if ($script:Options.SampleCount -gt 1) {
        if ($Snapshot.SampleNumber -lt $script:Options.SampleCount) {
            Write-Host (
                'Sample {0} of {1}. Refreshing every {2} seconds until the requested count is complete.' -f
                $Snapshot.SampleNumber,
                $script:Options.SampleCount,
                $script:Options.RefreshSeconds
            )
        }
        else {
            Write-Host ('Sample {0} of {1} complete.' -f $Snapshot.SampleNumber, $script:Options.SampleCount)
        }
    }
    else {
        Write-Host ("Refreshing every {0} seconds. Press Ctrl+C to stop." -f $script:Options.RefreshSeconds)
    }
}

function Show-ChromeRamUnavailable {
    param(
        [string]$Message,
        [bool]$WillRetry = $true
    )

    Clear-ChromeRamDisplay
    Write-Host 'Chrome RAM Watch (read-only)' -ForegroundColor Cyan
    Write-Host ("Updated: {0}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
    Write-Host ''
    Write-Host 'Chrome data is temporarily unavailable.' -ForegroundColor Yellow
    Write-Host $Message
    Write-Host ''
    if ($WillRetry) {
        Write-Host ("Retrying in {0} seconds. Press Ctrl+C to stop." -f $script:Options.RefreshSeconds)
    }
    else {
        Write-Host 'No requested sampling intervals remain.'
    }
}

function ConvertTo-ChromeRamJson {
    param([pscustomobject]$Snapshot)

    [pscustomobject]@{
        SchemaVersion = 'chrome-ram-watch/v2'
        ToolVersion   = $script:ChromeRamWatchVersion
        SampleAt      = $Snapshot.SampleAt.ToString('o')
        SampleNumber  = $Snapshot.SampleNumber
        Scope         = [pscustomobject]@{
            Type               = $Snapshot.ScopeType
            AllInstances       = $Snapshot.AllInstances
            RootProcessId      = $Snapshot.RootProcessId
            RootProcessIds     = $Snapshot.RootProcessIds
            RootProcessCount   = $Snapshot.RootProcessCount
            WindowsSessionId   = $script:CurrentSessionId
            Channel            = $Snapshot.Channel
            UserDataMode       = $Snapshot.UserDataMode
            LaunchProfileHint  = $Snapshot.LaunchProfileHint
            MayIncludeProfiles = $true
            Instances          = $Snapshot.Instances
        }
        System        = [pscustomobject]@{
            TotalRamGB                 = $Snapshot.TotalRamGB
            AvailableRamGB             = $Snapshot.AvailableRamGB
            AvailableRamPercent        = $Snapshot.AvailableRamPercent
            CommitGB                   = $Snapshot.CommitGB
            CommitLimitGB              = $Snapshot.CommitLimitGB
            CommitPercent              = $Snapshot.CommitPercent
            PressureLevel              = $Snapshot.PressureLevel
            PressureReason             = $Snapshot.PressureReason
            PressureReasons            = $Snapshot.PressureReasons
            PressureStreakSamples      = $Snapshot.PressureStreakSamples
            SustainedPressureThresholdSamples = $Snapshot.SustainedPressureThresholdSamples
            SustainedPressure          = $Snapshot.SustainedPressure
            PagesPerSecond             = $Snapshot.PagesPerSecond
            PageReadOperationsPerSecond = $Snapshot.PageReadsPerSecond
        }
        Chrome        = [pscustomobject]@{
            ProcessCount                  = $Snapshot.ProcessCount
            SummedWorkingSetGB            = $Snapshot.SummedWorkingSetGB
            PrivateBytesGB                = $Snapshot.PrivateBytesGB
            TrendIntervalSeconds          = $Snapshot.TrendIntervalSeconds
            TrendProcessCount             = $Snapshot.TrendProcessCount
            TotalPrivateGrowthMBPerMinute = $Snapshot.TotalPrivateGrowthMBPerMinute
            GrowingProcessCount           = $Snapshot.GrowingProcessCount
        }
        Processes     = $Snapshot.Processes
        TopProcesses  = $Snapshot.TopProcesses
    } | ConvertTo-Json -Depth 8
}

function Show-ChromeInstance {
    param([object[]]$ChromeProcesses)

    $instances = @(Get-ChromeInstance -ChromeProcesses $ChromeProcesses)
    if ($instances.Count -eq 0) {
        Write-Host "No Chrome browser instances were found in Windows session $script:CurrentSessionId."
        return
    }

    Write-Host "Chrome browser instances in Windows session $script:CurrentSessionId"
    Write-Host 'A launch profile is only a startup hint, not per-profile attribution.'
    Write-Host ''
    $instances |
        Select-Object BrowserProcessId, Channel, UserDataMode, LaunchProfileHint, ExecutablePath |
        Format-Table -AutoSize
}

function Invoke-ChromeRamWatch {
    if ($script:Options.AllInstances -and $script:Options.BrowserProcessId -gt 0) {
        throw '-AllInstances cannot be combined with -BrowserProcessId.'
    }
    if ($script:Options.Once -and $script:Options.SampleCount -gt 1) {
        throw '-Once can be combined only with -SampleCount 0 or 1.'
    }

    $sampleLimit = if ($script:Options.Once) { 1 } else { $script:Options.SampleCount }
    if ($script:Options.Json -and $sampleLimit -ne 1) {
        throw '-Json requires -Once or -SampleCount 1.'
    }
    if (
        $script:Options.ListInstances -and
        (
            $script:Options.Json -or
            $script:Options.Once -or
            $script:Options.AllInstances -or
            $script:Options.SampleCount -gt 0 -or
            $script:Options.BrowserProcessId -gt 0
        )
    ) {
        throw '-ListInstances cannot be combined with -AllInstances, -Json, -Once, -SampleCount, or -BrowserProcessId.'
    }

    if ($script:Options.ListInstances) {
        $chromeProcesses = Get-ChromeProcessInventory
        Show-ChromeInstance -ChromeProcesses $chromeProcesses
        return
    }

    Initialize-ChromeCpuSample
    $script:PinnedBrowserRootIdentity = $null
    $attemptCount = 0
    $successfulSampleCount = 0
    $failedSampleCount = 0
    do {
        $attemptCount++
        try {
            $chromeProcesses = Get-ChromeProcessInventory
            $browserRoots = @(
                Resolve-ChromeBrowserRootSet `
                -ChromeProcesses $chromeProcesses `
                    -RequestedBrowserProcessId $script:Options.BrowserProcessId `
                    -IncludeAllInstances $script:Options.AllInstances
            )

            if (-not $script:Options.AllInstances) {
                $rootCreation = Get-ChromeProcessCreationInfo `
                    -ProcessId ([int]$browserRoots[0].ProcessId) `
                    -CimProcess $browserRoots[0] `
                    -RuntimeProcess $null `
                    -SampleAt (Get-Date)
                if ($null -eq $rootCreation.CreatedAt) {
                    throw "Chrome browser root PID $($browserRoots[0].ProcessId) has no readable creation time, so its identity cannot be pinned safely."
                }
                if ($null -eq $script:PinnedBrowserRootIdentity) {
                    $script:PinnedBrowserRootIdentity = $rootCreation.CreationIdentity
                }
                elseif ($script:PinnedBrowserRootIdentity -ne $rootCreation.CreationIdentity) {
                    throw "Chrome browser root PID $($browserRoots[0].ProcessId) was replaced by a different process. Re-run the watcher to select the new instance explicitly."
                }
            }

            $snapshot = Get-ChromeRamSnapshot `
                -ChromeProcesses $chromeProcesses `
                -BrowserRoots $browserRoots `
                -SampleNumber $attemptCount
            if ($script:Options.Json) {
                ConvertTo-ChromeRamJson -Snapshot $snapshot
            }
            else {
                Show-ChromeRamSnapshot -Snapshot $snapshot
            }
            $successfulSampleCount++
        }
        catch {
            $failedSampleCount++
            # A missing interval breaks evidence of consecutive pressure. Never
            # carry a sustained-pressure streak across an unavailable sample.
            $script:PressureStreakSamples = 0
            if ($sampleLimit -eq 1) {
                throw
            }

            $willRetry = $sampleLimit -eq 0 -or $attemptCount -lt $sampleLimit
            Show-ChromeRamUnavailable `
                -Message $_.Exception.Message `
                -WillRetry $willRetry
        }

        $hasMoreSamples = $sampleLimit -eq 0 -or $attemptCount -lt $sampleLimit
        if ($hasMoreSamples) {
            Start-Sleep -Seconds $script:Options.RefreshSeconds
        }
    } while ($hasMoreSamples)

    if ($sampleLimit -gt 1 -and $failedSampleCount -gt 0) {
        throw "Completed $attemptCount sampling attempts, but $failedSampleCount were unavailable. Collected $successfulSampleCount of $sampleLimit requested snapshots."
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-ChromeRamWatch
    }
    catch {
        Write-Error $_
        exit 1
    }
}
