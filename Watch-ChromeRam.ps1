#Requires -Version 5.1

<#
.SYNOPSIS
Monitors memory pressure for one Chrome browser instance on Windows.

.DESCRIPTION
Chrome RAM Watch reports Windows memory pressure and the Chrome processes that
belong to one browser process tree. It is read-only. It does not close tabs,
end processes, inspect page contents, change Chrome settings, or use the
network.

Chrome normally shares one browser instance across profiles that use the same
user-data directory. A launch profile shown by this script is only a startup
hint. It is not reliable per-profile attribution.

.PARAMETER BrowserProcessId
Root process ID of a Chrome browser instance. If omitted, the script selects
the single standard Chrome instance in the current Windows session and ignores
instances launched with a custom --user-data-dir.

.PARAMETER ListInstances
Lists Chrome browser instances in the current Windows session and exits.

.PARAMETER RefreshSeconds
Seconds between samples. The default is 10.

.PARAMETER Top
Number of Chrome processes to display. The default is 12.

.PARAMETER Once
Collects one sample and exits.

.PARAMETER Json
Writes one machine-readable JSON sample. Requires -Once.

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
.\Watch-ChromeRam.ps1 -Once -Json

Writes one JSON sample for automation or logging.
#>

[CmdletBinding()]
param(
    [ValidateRange(0, 2147483647)]
    [int]$BrowserProcessId = 0,
    [switch]$ListInstances,
    [ValidateRange(5, 300)]
    [int]$RefreshSeconds = 10,
    [ValidateRange(3, 50)]
    [int]$Top = 12,
    [switch]$Once,
    [switch]$Json,
    [switch]$NoClear
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ChromeRamWatchVersion = '0.1.0'
$script:CurrentSessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
$script:LogicalProcessorCount = [math]::Max(1, [Environment]::ProcessorCount)
$script:Options = [pscustomobject]@{
    BrowserProcessId = $BrowserProcessId
    ListInstances    = [bool]$ListInstances
    RefreshSeconds   = $RefreshSeconds
    Top              = $Top
    Once             = [bool]$Once
    Json             = [bool]$Json
    NoClear          = [bool]$NoClear
}
$script:PreviousCpu = @{}
$script:PreviousSampleAt = $null
$script:SelectedBrowserRoot = $null

function Get-ChromeProcessType {
    param([string]$CommandLine)

    if ($CommandLine -match '--type=([^\s\"]+)') {
        return $matches[1]
    }

    return 'browser/other'
}

function Get-ChromeLaunchProfile {
    param([string]$CommandLine)

    if ($CommandLine -match '--profile-directory=(?:\"([^\"]+)\"|([^\s]+))') {
        if ($matches[1]) {
            return $matches[1]
        }

        return $matches[2]
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

function Get-ChromeBrowserRoot {
    param([object[]]$ChromeProcesses)

    $chromeIds = @($ChromeProcesses | ForEach-Object { [int]$_.ProcessId })
    return @(
        $ChromeProcesses | Where-Object {
            $_.CommandLine -and
            $_.CommandLine -notmatch '--type=' -and
            $chromeIds -notcontains [int]$_.ParentProcessId
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

function Get-ChromeDescendantProcessId {
    param(
        [object[]]$ChromeProcesses,
        [int]$RootProcessId
    )

    $processIds = [System.Collections.Generic.HashSet[int]]::new()
    [void]$processIds.Add($RootProcessId)

    $added = $true
    while ($added) {
        $added = $false
        foreach ($process in $ChromeProcesses) {
            if (
                $processIds.Contains([int]$process.ParentProcessId) -and
                -not $processIds.Contains([int]$process.ProcessId)
            ) {
                [void]$processIds.Add([int]$process.ProcessId)
                $added = $true
            }
        }
    }

    return @($processIds)
}

function Initialize-ChromeCpuSample {
    $script:PreviousCpu = @{}
    $script:PreviousSampleAt = $null
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
        [object]$BrowserRoot
    )

    $sampleAt = Get-Date
    $rootProcessId = [int]$BrowserRoot.ProcessId
    $activeRoot = @($ChromeProcesses | Where-Object { [int]$_.ProcessId -eq $rootProcessId })
    if ($activeRoot.Count -ne 1) {
        throw "Chrome browser root PID $rootProcessId is no longer running."
    }

    $instanceProcessIds = @(
        Get-ChromeDescendantProcessId -ChromeProcesses $ChromeProcesses -RootProcessId $rootProcessId
    )
    $processIdSet = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($processId in $instanceProcessIds) {
        [void]$processIdSet.Add([int]$processId)
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

    $currentCpu = @{}
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

        $currentCpu[$processId] = $cpuSeconds
        $cpuPercent = $null
        if (
            $null -ne $elapsedSeconds -and
            $elapsedSeconds -gt 0 -and
            $script:PreviousCpu.ContainsKey($processId)
        ) {
            $cpuPercent = Get-ChromeCpuPercent `
                -CurrentCpuSeconds $cpuSeconds `
                -PreviousCpuSeconds $script:PreviousCpu[$processId] `
                -ElapsedSeconds $elapsedSeconds `
                -LogicalProcessorCount $script:LogicalProcessorCount
        }

        $commandLine = ''
        if ($cimById.ContainsKey($processId)) {
            $commandLine = [string]$cimById[$processId].CommandLine
        }

        [pscustomobject]@{
            PID             = $processId
            Type            = Get-ChromeProcessType -CommandLine $commandLine
            Extension       = $commandLine -match '--extension-process'
            WorkingSetBytes = $workingSetBytes
            PrivateBytes    = $privateBytes
            WorkingSetMB    = [math]::Round($workingSetBytes / 1MB, 0)
            PrivateBytesMB  = [math]::Round($privateBytes / 1MB, 0)
            CPUPercent      = $cpuPercent
        }
    })

    $script:PreviousCpu = $currentCpu
    $script:PreviousSampleAt = $sampleAt

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

    $topProcesses = @(
        $rows |
            Sort-Object WorkingSetBytes -Descending |
            Select-Object -First $script:Options.Top PID, Type, Extension, WorkingSetMB, PrivateBytesMB, CPUPercent
    )

    [pscustomobject]@{
        SampleAt           = $sampleAt
        RootProcessId      = $rootProcessId
        Channel            = Get-ChromeChannelHint -ExecutablePath ([string]$BrowserRoot.ExecutablePath)
        UserDataMode       = Get-ChromeUserDataMode -CommandLine ([string]$BrowserRoot.CommandLine)
        LaunchProfileHint  = Get-ChromeLaunchProfile -CommandLine ([string]$BrowserRoot.CommandLine)
        TotalRamGB         = [math]::Round($operatingSystem.TotalVisibleMemorySize / 1MB, 2)
        AvailableRamGB     = [math]::Round($operatingSystem.FreePhysicalMemory / 1MB, 2)
        CommitGB           = [math]::Round($memory.CommittedBytes / 1GB, 2)
        CommitLimitGB      = [math]::Round($memory.CommitLimit / 1GB, 2)
        CommitPercent      = [int]$memory.PercentCommittedBytesInUse
        PagesPerSecond     = [int64]$memory.PagesPersec
        PageReadsPerSecond = [int64]$memory.PageReadsPersec
        ProcessCount       = $rows.Count
        SummedWorkingSetGB = [math]::Round($workingSetSum / 1GB, 2)
        PrivateBytesGB     = [math]::Round($privateBytesSum / 1GB, 2)
        TopProcesses       = $topProcesses
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
    Write-Host ''
    Write-Host (
        'System RAM: {0:N2} GB available of {1:N2} GB | Commit: {2:N2}/{3:N2} GB ({4}%)' -f
        $Snapshot.AvailableRamGB,
        $Snapshot.TotalRamGB,
        $Snapshot.CommitGB,
        $Snapshot.CommitLimitGB,
        $Snapshot.CommitPercent
    )
    Write-Host (
        'Memory paging: {0:N0} pages/sec | {1:N0} disk page-read operations/sec' -f
        $Snapshot.PagesPerSecond,
        $Snapshot.PageReadsPerSecond
    )
    Write-Host (
        'Chrome tree: {0} processes | {1:N2} GB summed working set | {2:N2} GB private bytes' -f
        $Snapshot.ProcessCount,
        $Snapshot.SummedWorkingSetGB,
        $Snapshot.PrivateBytesGB
    )
    Write-Host ''
    Write-Host 'Largest Chrome processes in this browser instance:' -ForegroundColor Yellow
    $Snapshot.TopProcesses |
        Format-Table PID, Type, Extension, WorkingSetMB, PrivateBytesMB, CPUPercent -AutoSize

    Write-Host 'To map a renderer PID to its page:' -ForegroundColor Yellow
    Write-Host '1. Paste chrome://process-internals/#web-contents into Chrome.'
    Write-Host '2. Press Ctrl+F and search for the PID shown above.'
    Write-Host '3. Read the site and URL beside Frame[PID:routing_id].'
    Write-Host ''
    Write-Host 'This watcher never closes tabs, ends processes, or changes Chrome settings.'
    if (-not $script:Options.Once) {
        Write-Host ("Refreshing every {0} seconds. Press Ctrl+C to stop." -f $script:Options.RefreshSeconds)
    }
}

function Show-ChromeRamUnavailable {
    param([string]$Message)

    Clear-ChromeRamDisplay
    Write-Host 'Chrome RAM Watch (read-only)' -ForegroundColor Cyan
    Write-Host ("Updated: {0}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
    Write-Host ''
    Write-Host 'Chrome data is temporarily unavailable.' -ForegroundColor Yellow
    Write-Host $Message
    Write-Host ''
    Write-Host ("Retrying in {0} seconds. Press Ctrl+C to stop." -f $script:Options.RefreshSeconds)
}

function ConvertTo-ChromeRamJson {
    param([pscustomobject]$Snapshot)

    [pscustomobject]@{
        SchemaVersion = 'chrome-ram-watch/v1'
        ToolVersion   = $script:ChromeRamWatchVersion
        SampleAt      = $Snapshot.SampleAt.ToString('o')
        Scope         = [pscustomobject]@{
            Type               = 'browser-process-tree'
            RootProcessId      = $Snapshot.RootProcessId
            WindowsSessionId   = $script:CurrentSessionId
            Channel            = $Snapshot.Channel
            UserDataMode       = $Snapshot.UserDataMode
            LaunchProfileHint  = $Snapshot.LaunchProfileHint
            MayIncludeProfiles = $true
        }
        System        = [pscustomobject]@{
            TotalRamGB                 = $Snapshot.TotalRamGB
            AvailableRamGB             = $Snapshot.AvailableRamGB
            CommitGB                   = $Snapshot.CommitGB
            CommitLimitGB              = $Snapshot.CommitLimitGB
            CommitPercent              = $Snapshot.CommitPercent
            PagesPerSecond             = $Snapshot.PagesPerSecond
            PageReadOperationsPerSecond = $Snapshot.PageReadsPerSecond
        }
        Chrome        = [pscustomobject]@{
            ProcessCount       = $Snapshot.ProcessCount
            SummedWorkingSetGB = $Snapshot.SummedWorkingSetGB
            PrivateBytesGB     = $Snapshot.PrivateBytesGB
        }
        TopProcesses  = $Snapshot.TopProcesses
    } | ConvertTo-Json -Depth 6
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
    if ($script:Options.Json -and -not $script:Options.Once) {
        throw '-Json requires -Once.'
    }
    if (
        $script:Options.ListInstances -and
        ($script:Options.Json -or $script:Options.Once -or $script:Options.BrowserProcessId -gt 0)
    ) {
        throw '-ListInstances cannot be combined with -Json, -Once, or -BrowserProcessId.'
    }

    if ($script:Options.ListInstances) {
        $chromeProcesses = Get-ChromeProcessInventory
        Show-ChromeInstance -ChromeProcesses $chromeProcesses
        return
    }

    do {
        try {
            $chromeProcesses = Get-ChromeProcessInventory
            $browserRoot = Resolve-ChromeBrowserRoot `
                -ChromeProcesses $chromeProcesses `
                -RequestedBrowserProcessId $script:Options.BrowserProcessId

            if (
                $null -eq $script:SelectedBrowserRoot -or
                [int]$script:SelectedBrowserRoot.ProcessId -ne [int]$browserRoot.ProcessId
            ) {
                $script:SelectedBrowserRoot = $browserRoot
                Initialize-ChromeCpuSample
            }

            $snapshot = Get-ChromeRamSnapshot `
                -ChromeProcesses $chromeProcesses `
                -BrowserRoot $script:SelectedBrowserRoot
            if ($script:Options.Json) {
                ConvertTo-ChromeRamJson -Snapshot $snapshot
            }
            else {
                Show-ChromeRamSnapshot -Snapshot $snapshot
            }
        }
        catch {
            if ($script:Options.Once) {
                throw
            }

            Show-ChromeRamUnavailable -Message $_.Exception.Message
        }

        if (-not $script:Options.Once) {
            Start-Sleep -Seconds $script:Options.RefreshSeconds
        }
    } while (-not $script:Options.Once)
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
