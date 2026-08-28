#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ScriptPath,
    [string]$CompanionTestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
    $ScriptPath = Join-Path $PSScriptRoot '..\Watch-ChromeRam.ps1'
}
if ([string]::IsNullOrWhiteSpace($CompanionTestPath)) {
    $CompanionTestPath = Join-Path $PSScriptRoot 'Test-Companion.js'
}

$resolvedScript = (Resolve-Path -LiteralPath $ScriptPath).Path
$repositoryRoot = Split-Path -Parent $resolvedScript
$resolvedCompanionTest = (Resolve-Path -LiteralPath $CompanionTestPath).Path
$resolvedAutoGuardTest = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'Test-AutoGuard.js')).Path

function Assert-Equal {
    param(
        [AllowNull()]
        [object]$Actual,
        [AllowNull()]
        [object]$Expected,
        [string]$Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', received '$Actual'."
    }
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Null {
    param(
        [AllowNull()]
        [object]$Actual,
        [string]$Message
    )

    if ($null -ne $Actual) {
        throw "$Message Expected null, received '$Actual'."
    }
}

function Assert-SequenceEqual {
    param(
        [AllowEmptyCollection()]
        [object[]]$Actual,
        [AllowEmptyCollection()]
        [object[]]$Expected,
        [string]$Message
    )

    $actualText = $Actual -join ','
    $expectedText = $Expected -join ','
    if ($actualText -ne $expectedText) {
        throw "$Message Expected '$expectedText', received '$actualText'."
    }
}

function Assert-Between {
    param(
        [double]$Actual,
        [double]$Minimum,
        [double]$Maximum,
        [string]$Message
    )

    if ($Actual -lt $Minimum -or $Actual -gt $Maximum) {
        throw "$Message Expected $Minimum through $Maximum, received $Actual."
    }
}

function Assert-PropertySet {
    param(
        [object]$Object,
        [string[]]$Expected,
        [string]$Message
    )

    $actualNames = @($Object.PSObject.Properties.Name | Sort-Object)
    $expectedNames = @($Expected | Sort-Object)
    Assert-SequenceEqual -Actual $actualNames -Expected $expectedNames -Message $Message
}

function Assert-Throw {
    param(
        [scriptblock]$Action,
        [string]$Pattern,
        [string]$Message
    )

    $caughtText = $null
    try {
        & $Action
    }
    catch {
        $caughtText = $_.ToString()
    }

    if ($null -eq $caughtText) {
        throw "$Message Expected an exception, but the action completed."
    }
    if (-not [string]::IsNullOrWhiteSpace($Pattern) -and $caughtText -notmatch $Pattern) {
        throw "$Message Exception did not match '$Pattern': $caughtText"
    }

    return $caughtText
}

function Get-FakeChromeProcess {
    param(
        [int]$ProcessId,
        [int]$ParentProcessId,
        [string]$CommandLine,
        [datetime]$CreationDate,
        [string]$ExecutablePath = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
    )

    [pscustomobject]@{
        ProcessId       = $ProcessId
        ParentProcessId = $ParentProcessId
        SessionId       = $script:CurrentSessionId
        CommandLine     = $CommandLine
        ExecutablePath  = $ExecutablePath
        CreationDate    = $CreationDate
    }
}

function Get-FakeRuntimeProcess {
    param(
        [int]$ProcessId,
        [datetime]$StartTime,
        [double]$CpuSeconds,
        [int64]$WorkingSetBytes,
        [int64]$PrivateBytes
    )

    [pscustomobject]@{
        Id                  = $ProcessId
        SessionId           = $script:CurrentSessionId
        StartTime           = $StartTime
        CPU                 = $CpuSeconds
        WorkingSet64        = $WorkingSetBytes
        PrivateMemorySize64 = $PrivateBytes
    }
}

# Parse every shipped PowerShell file with the current engine before executing helpers.
$powerShellFiles = @(
    $resolvedScript
    Join-Path $repositoryRoot 'tools\Build-Release.ps1'
    Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File | ForEach-Object { $_.FullName }
) | Sort-Object -Unique

$watchTokens = $null
$watchParseErrors = $null
$watchSyntaxTree = [System.Management.Automation.Language.Parser]::ParseFile(
    $resolvedScript,
    [ref]$watchTokens,
    [ref]$watchParseErrors
)
if ($watchParseErrors.Count -gt 0) {
    $details = ($watchParseErrors | ForEach-Object { $_.Message }) -join [Environment]::NewLine
    throw "PowerShell parser errors in Watch-ChromeRam.ps1:$([Environment]::NewLine)$details"
}

foreach ($powerShellFile in $powerShellFiles) {
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $powerShellFile,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) {
        $details = ($parseErrors | ForEach-Object { $_.Message }) -join [Environment]::NewLine
        throw "PowerShell parser errors in $powerShellFile`:$([Environment]::NewLine)$details"
    }
}

. $resolvedScript

Assert-Equal -Actual $script:ChromeRamWatchVersion -Expected '0.3.0' -Message 'Watcher version mismatch.'
Assert-Equal `
    -Actual $script:SustainedPressureThresholdSamples `
    -Expected 3 `
    -Message 'Sustained-pressure sample threshold changed.'

$createdAt = [datetime]'2026-08-28T04:00:00Z'
$chromeProcesses = @(
    Get-FakeChromeProcess `
        -ProcessId 100 `
        -ParentProcessId 10 `
        -CommandLine '"C:\Program Files\Google\Chrome\Application\chrome.exe" --profile-directory="Profile 35"' `
        -CreationDate $createdAt
    Get-FakeChromeProcess `
        -ProcessId 101 `
        -ParentProcessId 100 `
        -CommandLine 'chrome.exe --type=renderer' `
        -CreationDate $createdAt.AddSeconds(1)
    Get-FakeChromeProcess `
        -ProcessId 102 `
        -ParentProcessId 101 `
        -CommandLine 'chrome.exe --type=utility --extension-process' `
        -CreationDate $createdAt.AddSeconds(2)
    Get-FakeChromeProcess `
        -ProcessId 200 `
        -ParentProcessId 20 `
        -CommandLine 'chrome.exe --user-data-dir="C:\Temp\ChromeTest" --profile-directory=Default' `
        -CreationDate $createdAt.AddMinutes(1)
    Get-FakeChromeProcess `
        -ProcessId 201 `
        -ParentProcessId 200 `
        -CommandLine 'chrome.exe --type=renderer' `
        -CreationDate $createdAt.AddMinutes(1).AddSeconds(1)
)

$rootIds = @(
    Get-ChromeBrowserRoot -ChromeProcesses $chromeProcesses |
        ForEach-Object { [int]$_.ProcessId } |
        Sort-Object
)
Assert-SequenceEqual -Actual $rootIds -Expected @(100, 200) -Message 'Root detection failed.'

$allRoots = @(
    Resolve-ChromeBrowserRootSet `
        -ChromeProcesses $chromeProcesses `
        -RequestedBrowserProcessId 0 `
        -IncludeAllInstances $true
)
Assert-SequenceEqual `
    -Actual @($allRoots.ProcessId) `
    -Expected @(100, 200) `
    -Message 'All-instance root selection failed.'

$standardRoot = Resolve-ChromeBrowserRoot `
    -ChromeProcesses $chromeProcesses `
    -RequestedBrowserProcessId 0
Assert-Equal -Actual $standardRoot.ProcessId -Expected 100 -Message 'Standard-instance selection failed.'

$customRoot = Resolve-ChromeBrowserRoot `
    -ChromeProcesses $chromeProcesses `
    -RequestedBrowserProcessId 200
Assert-Equal -Actual $customRoot.ProcessId -Expected 200 -Message 'Explicit-instance selection failed.'

$descendantIds = @(
    Get-ChromeDescendantProcessId -ChromeProcesses $chromeProcesses -RootProcessId 100 |
        Sort-Object
)
Assert-SequenceEqual `
    -Actual $descendantIds `
    -Expected @(100, 101, 102) `
    -Message 'Process-tree isolation failed.'

$newerReusedParent = Get-FakeChromeProcess `
    -ProcessId 400 `
    -ParentProcessId 40 `
    -CommandLine 'chrome.exe --profile-directory=Default' `
    -CreationDate $createdAt.AddHours(4)
$olderDetachedBrowser = Get-FakeChromeProcess `
    -ProcessId 500 `
    -ParentProcessId 400 `
    -CommandLine 'chrome.exe --profile-directory=Profile 2' `
    -CreationDate $createdAt.AddHours(3)
$olderDetachedRenderer = Get-FakeChromeProcess `
    -ProcessId 501 `
    -ParentProcessId 500 `
    -CommandLine 'chrome.exe --type=renderer' `
    -CreationDate $createdAt.AddHours(3).AddSeconds(1)
$temporalInventory = @($newerReusedParent, $olderDetachedBrowser, $olderDetachedRenderer)
Assert-SequenceEqual `
    -Actual @(
        Get-ChromeBrowserRoot -ChromeProcesses $temporalInventory |
            ForEach-Object { [int]$_.ProcessId } |
            Sort-Object
    ) `
    -Expected @(400, 500) `
    -Message 'A newer reused parent PID must not absorb an older browser tree.'
Assert-SequenceEqual `
    -Actual @(Get-ChromeDescendantProcessId -ChromeProcesses $temporalInventory -RootProcessId 400 | Sort-Object) `
    -Expected @(400) `
    -Message 'An impossible parent-after-child edge must be excluded from traversal.'
Assert-SequenceEqual `
    -Actual @(Get-ChromeDescendantProcessId -ChromeProcesses $temporalInventory -RootProcessId 500 | Sort-Object) `
    -Expected @(500, 501) `
    -Message 'The detached older browser tree must remain internally attributable.'

$unknownTimingParent = Get-FakeChromeProcess `
    -ProcessId 600 `
    -ParentProcessId 60 `
    -CommandLine 'chrome.exe --profile-directory=Default' `
    -CreationDate $createdAt
$unknownTimingChild = Get-FakeChromeProcess `
    -ProcessId 601 `
    -ParentProcessId 600 `
    -CommandLine 'chrome.exe --profile-directory=Profile 3' `
    -CreationDate $createdAt.AddSeconds(1)
$unknownTimingChild.CreationDate = $null
$unknownTimingInventory = @($unknownTimingParent, $unknownTimingChild)
Assert-SequenceEqual `
    -Actual @(
        Get-ChromeBrowserRoot -ChromeProcesses $unknownTimingInventory |
            ForEach-Object { [int]$_.ProcessId } |
            Sort-Object
    ) `
    -Expected @(600, 601) `
    -Message 'Unavailable creation timing must fail closed instead of asserting a parent edge.'
Assert-SequenceEqual `
    -Actual @(Get-ChromeDescendantProcessId -ChromeProcesses $unknownTimingInventory -RootProcessId 600 | Sort-Object) `
    -Expected @(600) `
    -Message 'Traversal must exclude an edge whose identity timing is unavailable.'

$secondStandardRoot = Get-FakeChromeProcess `
    -ProcessId 300 `
    -ParentProcessId 30 `
    -CommandLine 'chrome.exe --profile-directory=Default' `
    -CreationDate $createdAt.AddMinutes(2)
[void](Assert-Throw `
    -Action { Resolve-ChromeBrowserRoot -ChromeProcesses @($chromeProcesses + $secondStandardRoot) -RequestedBrowserProcessId 0 } `
    -Pattern 'Multiple standard Chrome browser instances' `
    -Message 'Ambiguous standard-instance selection must fail closed.')

Assert-Equal `
    -Actual (Get-ChromeLaunchProfile -CommandLine '--profile-directory="Profile 35"') `
    -Expected 'Profile 35' `
    -Message 'Quoted launch-profile parsing failed.'
Assert-Equal `
    -Actual (Get-ChromeLaunchProfile -CommandLine '--profile-directory=Default') `
    -Expected 'Default' `
    -Message 'Unquoted launch-profile parsing failed.'
Assert-Equal `
    -Actual (Get-ChromeUserDataMode -CommandLine '--user-data-dir="C:\Temp\Test"') `
    -Expected 'Custom' `
    -Message 'Custom user-data detection failed.'
Assert-Equal `
    -Actual (Get-ChromeProcessType -CommandLine '--type=renderer') `
    -Expected 'renderer' `
    -Message 'Process-type parsing failed.'
Assert-Equal `
    -Actual (Get-ChromeChannelHint -ExecutablePath 'C:\Program Files\Google\Chrome Beta\Application\chrome.exe') `
    -Expected 'Beta' `
    -Message 'Channel detection failed.'

$cpuPercent = Get-ChromeCpuPercent `
    -CurrentCpuSeconds 12 `
    -PreviousCpuSeconds 10 `
    -ElapsedSeconds 4 `
    -LogicalProcessorCount 10
Assert-Equal -Actual $cpuPercent -Expected 5.0 -Message 'CPU normalization failed.'
Assert-Equal `
    -Actual (Get-ChromeCpuPercent -CurrentCpuSeconds 9 -PreviousCpuSeconds 10 -ElapsedSeconds 4 -LogicalProcessorCount 10) `
    -Expected 0.0 `
    -Message 'Negative CPU deltas must clamp to zero.'

$creationOne = Get-ChromeProcessCreationInfo `
    -ProcessId 101 `
    -CimProcess $chromeProcesses[1] `
    -RuntimeProcess $null `
    -SampleAt $createdAt.AddHours(1)
$creationSame = Get-ChromeProcessCreationInfo `
    -ProcessId 101 `
    -CimProcess $chromeProcesses[1] `
    -RuntimeProcess $null `
    -SampleAt $createdAt.AddHours(2)
$reusedProcess = Get-FakeChromeProcess `
    -ProcessId 101 `
    -ParentProcessId 100 `
    -CommandLine 'chrome.exe --type=renderer' `
    -CreationDate $createdAt.AddMinutes(30)
$creationReused = Get-ChromeProcessCreationInfo `
    -ProcessId 101 `
    -CimProcess $reusedProcess `
    -RuntimeProcess $null `
    -SampleAt $createdAt.AddHours(2)
Assert-Equal `
    -Actual $creationOne.CreationIdentity `
    -Expected $creationSame.CreationIdentity `
    -Message 'A surviving process must retain its creation identity.'
Assert-True `
    -Condition ($creationOne.CreationIdentity -ne $creationReused.CreationIdentity) `
    -Message 'A reused PID must receive a different creation identity.'

$runtimeWithinTolerance = Get-FakeRuntimeProcess `
    -ProcessId 100 `
    -StartTime $createdAt.AddMilliseconds(500) `
    -CpuSeconds 1 `
    -WorkingSetBytes (10MB) `
    -PrivateBytes (8MB)
$matchedCreation = Get-ChromeProcessCreationInfo `
    -ProcessId 100 `
    -CimProcess $chromeProcesses[0] `
    -RuntimeProcess $runtimeWithinTolerance `
    -SampleAt $createdAt.AddHours(1) `
    -RequireSourceMatch
Assert-Equal `
    -Actual $matchedCreation.CreationIdentity `
    -Expected ('100@{0}' -f $createdAt.ToUniversalTime().Ticks) `
    -Message 'CIM/runtime timestamp precision tolerance changed the canonical CIM identity.'

$runtimeReuseRace = Get-FakeRuntimeProcess `
    -ProcessId 100 `
    -StartTime $createdAt.AddSeconds(2) `
    -CpuSeconds 1 `
    -WorkingSetBytes (10MB) `
    -PrivateBytes (8MB)
[void](Assert-Throw `
    -Action {
        Get-ChromeProcessCreationInfo `
            -ProcessId 100 `
            -CimProcess $chromeProcesses[0] `
            -RuntimeProcess $runtimeReuseRace `
            -SampleAt $createdAt.AddHours(1) `
            -RequireSourceMatch
    } `
    -Pattern 'changed identity between CIM and runtime collection' `
    -Message 'A CIM/runtime PID-reuse race must reject the sample.')
[void](Assert-Throw `
    -Action {
        Get-ChromeProcessCreationInfo `
            -ProcessId 100 `
            -CimProcess $chromeProcesses[0] `
            -RuntimeProcess $null `
            -SampleAt $createdAt.AddHours(1) `
            -RequireSourceMatch
    } `
    -Pattern 'incomplete CIM/runtime creation timing' `
    -Message 'Required cross-source identity timing must fail closed when unavailable.')

$unknownOne = Get-ChromeProcessCreationInfo `
    -ProcessId 999 `
    -CimProcess $null `
    -RuntimeProcess $null `
    -SampleAt $createdAt
$unknownTwo = Get-ChromeProcessCreationInfo `
    -ProcessId 999 `
    -CimProcess $null `
    -RuntimeProcess $null `
    -SampleAt $createdAt.AddSeconds(1)
Assert-Null -Actual $unknownOne.CreatedAt -Message 'Unknown creation time must remain explicit.'
Assert-True `
    -Condition ($unknownOne.CreationIdentity -ne $unknownTwo.CreationIdentity) `
    -Message 'Unknown creation times must never fall back to PID-only trend matching.'

$pressureCases = @(
    [pscustomobject]@{ Available = 20.0001; Commit = 79.9999; Expected = 'Normal' }
    [pscustomobject]@{ Available = 20.1; Commit = 79; Expected = 'Normal' }
    [pscustomobject]@{ Available = 20.0; Commit = 79; Expected = 'Elevated' }
    [pscustomobject]@{ Available = 10.0001; Commit = 79; Expected = 'Elevated' }
    [pscustomobject]@{ Available = 10.1; Commit = 79; Expected = 'Elevated' }
    [pscustomobject]@{ Available = 10.0; Commit = 79; Expected = 'High' }
    [pscustomobject]@{ Available = 5.0001; Commit = 79; Expected = 'High' }
    [pscustomobject]@{ Available = 5.1; Commit = 79; Expected = 'High' }
    [pscustomobject]@{ Available = 5.0; Commit = 79; Expected = 'Critical' }
    [pscustomobject]@{ Available = 90.0; Commit = 79.9999; Expected = 'Normal' }
    [pscustomobject]@{ Available = 90.0; Commit = 80; Expected = 'Elevated' }
    [pscustomobject]@{ Available = 90.0; Commit = 89.9999; Expected = 'Elevated' }
    [pscustomobject]@{ Available = 90.0; Commit = 90; Expected = 'High' }
    [pscustomobject]@{ Available = 90.0; Commit = 94.9999; Expected = 'High' }
    [pscustomobject]@{ Available = 90.0; Commit = 95; Expected = 'Critical' }
    [pscustomobject]@{ Available = 5.0; Commit = 95; Expected = 'Critical' }
)
foreach ($pressureCase in $pressureCases) {
    $assessment = Get-SystemPressureAssessment `
        -AvailableRamPercent $pressureCase.Available `
        -CommitPercent $pressureCase.Commit
    Assert-Equal `
        -Actual $assessment.Level `
        -Expected $pressureCase.Expected `
        -Message "Pressure boundary failed for available=$($pressureCase.Available), commit=$($pressureCase.Commit)."
    Assert-Equal -Actual @($assessment.Reasons).Count -Expected 2 -Message 'Pressure must explain both signals.'
}

$streak = 0
foreach ($sampleNumber in 1..3) {
    $sustained = Get-SustainedPressureAssessment `
        -PressureLevel 'Elevated' `
        -CurrentStreakSamples $streak `
        -ThresholdSamples 3
    $streak = $sustained.PressureStreakSamples
    Assert-Equal -Actual $streak -Expected $sampleNumber -Message 'Pressure streak did not advance.'
    Assert-Equal `
        -Actual $sustained.SustainedPressure `
        -Expected ($sampleNumber -ge 3) `
        -Message 'Sustained-pressure threshold was applied incorrectly.'
}
$resetPressure = Get-SustainedPressureAssessment `
    -PressureLevel 'Normal' `
    -CurrentStreakSamples $streak `
    -ThresholdSamples 3
Assert-Equal -Actual $resetPressure.PressureStreakSamples -Expected 0 -Message 'Normal pressure must reset the streak.'
Assert-Equal -Actual $resetPressure.SustainedPressure -Expected $false -Message 'Normal pressure cannot be sustained.'

# Lock the v2 machine-readable contract with an exact structural fixture.
$instanceFixture = @(
    [pscustomobject]@{
        RootProcessId     = 100
        CreationIdentity  = '100@1'
        CreatedAt         = '2026-08-28T04:00:00.0000000Z'
        ProcessAgeSeconds = 3600
        Channel           = 'Stable'
        UserDataMode      = 'Standard'
        LaunchProfileHint = 'Profile 35'
        ExecutablePath    = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
    }
    [pscustomobject]@{
        RootProcessId     = 200
        CreationIdentity  = '200@2'
        CreatedAt         = '2026-08-28T04:01:00.0000000Z'
        ProcessAgeSeconds = 3540
        Channel           = 'Stable'
        UserDataMode      = 'Custom'
        LaunchProfileHint = 'Default'
        ExecutablePath    = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
    }
)
$processFixture = @(
    [pscustomobject]@{
        PID                      = 101
        RootProcessId            = 100
        Type                     = 'renderer'
        Extension                = $false
        CreationIdentity         = '101@3'
        CreatedAt                = '2026-08-28T04:00:01.0000000Z'
        ProcessAgeSeconds        = 3599
        ProcessAge               = '00:59:59'
        WorkingSetMB             = 512
        WorkingSetDeltaMB        = 12
        PrivateBytesMB           = 500
        PrivateBytesDeltaMB      = 10
        PrivateGrowthMBPerMinute = 20
        CPUPercent               = 2.5
    }
    [pscustomobject]@{
        PID                      = 201
        RootProcessId            = 200
        Type                     = 'renderer'
        Extension                = $false
        CreationIdentity         = '201@4'
        CreatedAt                = '2026-08-28T04:01:01.0000000Z'
        ProcessAgeSeconds        = 3539
        ProcessAge               = '00:58:59'
        WorkingSetMB             = 256
        WorkingSetDeltaMB        = $null
        PrivateBytesMB           = 240
        PrivateBytesDeltaMB      = $null
        PrivateGrowthMBPerMinute = $null
        CPUPercent               = $null
    }
)
$sampleSnapshot = [pscustomobject]@{
    SampleAt                          = [datetimeoffset]'2026-08-28T04:00:00+08:00'
    SampleNumber                      = 2
    ScopeType                         = 'all-browser-process-trees'
    AllInstances                      = $true
    RootProcessId                     = $null
    RootProcessIds                    = @(100, 200)
    RootProcessCount                  = 2
    Instances                         = $instanceFixture
    Channel                           = 'Stable'
    UserDataMode                      = 'Mixed'
    LaunchProfileHint                 = $null
    TotalRamGB                        = 40
    AvailableRamGB                    = 6
    AvailableRamPercent               = 15
    CommitGB                          = 60
    CommitLimitGB                     = 80
    CommitPercent                     = 75
    PressureLevel                     = 'Elevated'
    PressureReason                    = 'Available RAM is low. Commit is normal.'
    PressureReasons                   = @('Available RAM is low.', 'Commit is normal.')
    PressureStreakSamples             = 2
    SustainedPressureThresholdSamples = 3
    SustainedPressure                 = $false
    PagesPerSecond                    = 10
    PageReadsPerSecond                = 2
    ProcessCount                      = 2
    SummedWorkingSetGB                = 0.75
    PrivateBytesGB                    = 0.72
    TrendIntervalSeconds              = 30
    TrendProcessCount                 = 1
    TotalPrivateGrowthMBPerMinute     = 20
    GrowingProcessCount               = 1
    Processes                         = $processFixture
    TopProcesses                      = $processFixture
}
$jsonText = ConvertTo-ChromeRamJson -Snapshot $sampleSnapshot
Assert-True `
    -Condition ($jsonText -match '"SampleAt"\s*:\s*"2026-08-28T04:00:00\.0000000\+08:00"') `
    -Message 'JSON SampleAt must remain an ISO-8601 string with its offset.'
$jsonSample = $jsonText | ConvertFrom-Json
Assert-PropertySet `
    -Object $jsonSample `
    -Expected @('SchemaVersion', 'ToolVersion', 'SampleAt', 'SampleNumber', 'Scope', 'System', 'Chrome', 'Processes', 'TopProcesses') `
    -Message 'Top-level JSON schema changed.'
Assert-PropertySet `
    -Object $jsonSample.Scope `
    -Expected @('Type', 'AllInstances', 'RootProcessId', 'RootProcessIds', 'RootProcessCount', 'WindowsSessionId', 'Channel', 'UserDataMode', 'LaunchProfileHint', 'MayIncludeProfiles', 'Instances') `
    -Message 'JSON scope schema changed.'
Assert-PropertySet `
    -Object $jsonSample.System `
    -Expected @('TotalRamGB', 'AvailableRamGB', 'AvailableRamPercent', 'CommitGB', 'CommitLimitGB', 'CommitPercent', 'PressureLevel', 'PressureReason', 'PressureReasons', 'PressureStreakSamples', 'SustainedPressureThresholdSamples', 'SustainedPressure', 'PagesPerSecond', 'PageReadOperationsPerSecond') `
    -Message 'JSON system schema changed.'
Assert-PropertySet `
    -Object $jsonSample.Chrome `
    -Expected @('ProcessCount', 'SummedWorkingSetGB', 'PrivateBytesGB', 'TrendIntervalSeconds', 'TrendProcessCount', 'TotalPrivateGrowthMBPerMinute', 'GrowingProcessCount') `
    -Message 'JSON Chrome schema changed.'
Assert-PropertySet `
    -Object @($jsonSample.Processes)[0] `
    -Expected @('PID', 'RootProcessId', 'Type', 'Extension', 'CreationIdentity', 'CreatedAt', 'ProcessAgeSeconds', 'ProcessAge', 'WorkingSetMB', 'WorkingSetDeltaMB', 'PrivateBytesMB', 'PrivateBytesDeltaMB', 'PrivateGrowthMBPerMinute', 'CPUPercent') `
    -Message 'JSON process schema changed.'
Assert-Equal -Actual $jsonSample.SchemaVersion -Expected 'chrome-ram-watch/v2' -Message 'JSON schema version changed.'
Assert-Equal -Actual $jsonSample.ToolVersion -Expected '0.3.0' -Message 'JSON tool version changed.'
Assert-Equal -Actual $jsonSample.Scope.Type -Expected 'all-browser-process-trees' -Message 'JSON all-instance scope changed.'
Assert-Equal -Actual $jsonSample.Scope.AllInstances -Expected $true -Message 'JSON all-instance flag changed.'
Assert-Null -Actual $jsonSample.Scope.RootProcessId -Message 'All-instance JSON must not claim one root PID.'
Assert-SequenceEqual -Actual @($jsonSample.Scope.RootProcessIds) -Expected @(100, 200) -Message 'JSON root PID array changed.'
Assert-Equal -Actual @($jsonSample.Scope.Instances).Count -Expected 2 -Message 'JSON instance count changed.'
Assert-Equal -Actual @($jsonSample.Processes).Count -Expected 2 -Message 'JSON full process array is missing.'
Assert-Equal -Actual $jsonSample.System.PressureStreakSamples -Expected 2 -Message 'JSON pressure streak is missing.'
Assert-Equal -Actual $jsonSample.System.SustainedPressure -Expected $false -Message 'JSON sustained-pressure state changed.'
Assert-True `
    -Condition ($jsonText -notmatch '(?i)CommandLine|--profile-directory=|https?://') `
    -Message 'JSON leaked raw command lines or network-like data.'

# Deterministic snapshot fixtures replace Get-Process and Get-CimInstance only inside this test process.
$script:MockOperatingSystem = [pscustomobject]@{
    TotalVisibleMemorySize = [int64](40 * 1MB)
    FreePhysicalMemory     = [int64](6 * 1MB)
}
$script:MockMemory = [pscustomobject]@{
    CommittedBytes             = [int64](60GB)
    CommitLimit                = [int64](80GB)
    PercentCommittedBytesInUse = 75
    PagesPersec                = [int64]10
    PageReadsPersec            = [int64]2
}
$script:MockCimProcesses = @(
    Get-FakeChromeProcess -ProcessId 100 -ParentProcessId 10 -CommandLine 'chrome.exe --profile-directory=Default' -CreationDate $createdAt
    Get-FakeChromeProcess -ProcessId 101 -ParentProcessId 100 -CommandLine 'chrome.exe --type=renderer' -CreationDate $createdAt.AddSeconds(1)
    Get-FakeChromeProcess -ProcessId 200 -ParentProcessId 20 -CommandLine 'chrome.exe --user-data-dir="C:\Temp\Second"' -CreationDate $createdAt.AddMinutes(1)
    Get-FakeChromeProcess -ProcessId 201 -ParentProcessId 200 -CommandLine 'chrome.exe --type=renderer --extension-process' -CreationDate $createdAt.AddMinutes(1).AddSeconds(1)
)
$script:MockRuntimeProcesses = @(
    Get-FakeRuntimeProcess -ProcessId 100 -StartTime $createdAt -CpuSeconds 10 -WorkingSetBytes (100MB) -PrivateBytes (90MB)
    Get-FakeRuntimeProcess -ProcessId 101 -StartTime $createdAt.AddSeconds(1) -CpuSeconds 20 -WorkingSetBytes (300MB) -PrivateBytes (280MB)
    Get-FakeRuntimeProcess -ProcessId 200 -StartTime $createdAt.AddMinutes(1) -CpuSeconds 5 -WorkingSetBytes (80MB) -PrivateBytes (70MB)
    Get-FakeRuntimeProcess -ProcessId 201 -StartTime $createdAt.AddMinutes(1).AddSeconds(1) -CpuSeconds 8 -WorkingSetBytes (120MB) -PrivateBytes (110MB)
)

function Get-Process {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidOverwritingBuiltInCmdlets',
        '',
        Justification = 'This test-local function is a deterministic process-reader double.'
    )]
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Name
    )

    if ($Name -ne 'chrome') {
        return @()
    }
    return @($script:MockRuntimeProcesses)
}

function Get-CimInstance {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidOverwritingBuiltInCmdlets',
        '',
        Justification = 'This test-local function is a deterministic CIM-reader double.'
    )]
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$ClassName,
        [string]$Filter
    )

    [void]$Filter
    switch ($ClassName) {
        'Win32_Process' { return @($script:MockCimProcesses) }
        'Win32_OperatingSystem' { return $script:MockOperatingSystem }
        'Win32_PerfFormattedData_PerfOS_Memory' { return $script:MockMemory }
        default { throw "Unexpected mocked CIM class: $ClassName" }
    }
}

$script:Options.AllInstances = $true
$script:Options.Top = 3
Initialize-ChromeCpuSample
$snapshotOne = Get-ChromeRamSnapshot `
    -ChromeProcesses $script:MockCimProcesses `
    -BrowserRoots @($script:MockCimProcesses[0], $script:MockCimProcesses[2]) `
    -SampleNumber 1
Assert-Null -Actual $snapshotOne.RootProcessId -Message 'All-instance snapshots must keep singular RootProcessId null.'
Assert-SequenceEqual -Actual $snapshotOne.RootProcessIds -Expected @(100, 200) -Message 'All-instance roots changed.'
Assert-Equal -Actual $snapshotOne.ProcessCount -Expected 4 -Message 'All-instance process union is incomplete.'
Assert-Equal -Actual @($snapshotOne.Processes).Count -Expected 4 -Message 'Full process output is incomplete.'
Assert-Equal -Actual @($snapshotOne.TopProcesses).Count -Expected 3 -Message 'Top process limit was not applied.'
Assert-Equal -Actual $snapshotOne.PressureLevel -Expected 'Elevated' -Message 'Snapshot pressure assessment changed.'
Assert-Equal -Actual $snapshotOne.PressureStreakSamples -Expected 1 -Message 'First elevated sample must start the streak.'
Assert-Equal -Actual $snapshotOne.SustainedPressure -Expected $false -Message 'One elevated sample is not sustained.'

foreach ($processId in @(100, 101)) {
    $processRow = @($snapshotOne.Processes | Where-Object { $_.PID -eq $processId })[0]
    Assert-Equal -Actual $processRow.RootProcessId -Expected 100 -Message "PID $processId has wrong root attribution."
}
foreach ($processId in @(200, 201)) {
    $processRow = @($snapshotOne.Processes | Where-Object { $_.PID -eq $processId })[0]
    Assert-Equal -Actual $processRow.RootProcessId -Expected 200 -Message "PID $processId has wrong root attribution."
}

$renderer = @($script:MockRuntimeProcesses | Where-Object { $_.Id -eq 101 })[0]
$renderer.CPU = [double]$renderer.CPU + 1
$renderer.WorkingSet64 = [int64]$renderer.WorkingSet64 + [int64](30MB)
$renderer.PrivateMemorySize64 = [int64]$renderer.PrivateMemorySize64 + [int64](60MB)
$script:PreviousSampleAt = (Get-Date).AddMinutes(-1)
$snapshotTwo = Get-ChromeRamSnapshot `
    -ChromeProcesses $script:MockCimProcesses `
    -BrowserRoots @($script:MockCimProcesses[0], $script:MockCimProcesses[2]) `
    -SampleNumber 2
$rendererRow = @($snapshotTwo.Processes | Where-Object { $_.PID -eq 101 })[0]
Assert-Equal -Actual $rendererRow.WorkingSetDeltaMB -Expected 30 -Message 'Working-set delta changed.'
Assert-Equal -Actual $rendererRow.PrivateBytesDeltaMB -Expected 60 -Message 'Private-bytes delta changed.'
Assert-Between `
    -Actual $rendererRow.PrivateGrowthMBPerMinute `
    -Minimum 59 `
    -Maximum 61 `
    -Message 'Private growth rate changed.'
Assert-Equal -Actual $snapshotTwo.TrendProcessCount -Expected 4 -Message 'Comparable-process count changed.'
Assert-Equal -Actual $snapshotTwo.GrowingProcessCount -Expected 1 -Message 'Growing-process count changed.'
Assert-Between `
    -Actual $snapshotTwo.TotalPrivateGrowthMBPerMinute `
    -Minimum 59 `
    -Maximum 61 `
    -Message 'Aggregate private growth changed.'
Assert-Equal -Actual $snapshotTwo.PressureStreakSamples -Expected 2 -Message 'Second elevated sample must advance the streak.'

$replacementTime = $createdAt.AddHours(3)
$reusedCim = @($script:MockCimProcesses | Where-Object { $_.ProcessId -eq 101 })[0]
$reusedCim.CreationDate = $replacementTime
$script:PreviousSampleAt = (Get-Date).AddMinutes(-1)
[void](Assert-Throw `
    -Action {
        Get-ChromeRamSnapshot `
            -ChromeProcesses $script:MockCimProcesses `
            -BrowserRoots @($script:MockCimProcesses[0], $script:MockCimProcesses[2]) `
            -SampleNumber 3
    } `
    -Pattern 'changed identity between CIM and runtime collection' `
    -Message 'A PID reused between CIM and runtime enumeration must reject the entire sample.')
$renderer.StartTime = $replacementTime
$renderer.WorkingSet64 = [int64]$renderer.WorkingSet64 + [int64](500MB)
$renderer.PrivateMemorySize64 = [int64]$renderer.PrivateMemorySize64 + [int64](500MB)
$script:PreviousSampleAt = (Get-Date).AddMinutes(-1)
$snapshotThree = Get-ChromeRamSnapshot `
    -ChromeProcesses $script:MockCimProcesses `
    -BrowserRoots @($script:MockCimProcesses[0], $script:MockCimProcesses[2]) `
    -SampleNumber 3
$reusedRow = @($snapshotThree.Processes | Where-Object { $_.PID -eq 101 })[0]
Assert-Null -Actual $reusedRow.WorkingSetDeltaMB -Message 'A reused PID must not inherit working-set history.'
Assert-Null -Actual $reusedRow.PrivateBytesDeltaMB -Message 'A reused PID must not inherit private-byte history.'
Assert-Null -Actual $reusedRow.PrivateGrowthMBPerMinute -Message 'A reused PID must not report inherited growth.'
Assert-Null -Actual $reusedRow.CPUPercent -Message 'A reused PID must not inherit CPU history.'
Assert-Equal -Actual $snapshotThree.TrendProcessCount -Expected 3 -Message 'Reused PID must be excluded from comparable trends.'
Assert-Between `
    -Actual $snapshotThree.TotalPrivateGrowthMBPerMinute `
    -Minimum 499 `
    -Maximum 501 `
    -Message 'Aggregate scope growth must include memory introduced by a reused PID.'
Assert-Equal -Actual $snapshotThree.PressureStreakSamples -Expected 3 -Message 'Third elevated sample must advance the streak.'
Assert-Equal -Actual $snapshotThree.SustainedPressure -Expected $true -Message 'Third elevated sample must become sustained.'

$script:MockOperatingSystem.FreePhysicalMemory = [int64](20 * 1MB)
$script:MockMemory.PercentCommittedBytesInUse = 50
$script:PreviousSampleAt = (Get-Date).AddMinutes(-1)
$snapshotFour = Get-ChromeRamSnapshot `
    -ChromeProcesses $script:MockCimProcesses `
    -BrowserRoots @($script:MockCimProcesses[0], $script:MockCimProcesses[2]) `
    -SampleNumber 4
Assert-Equal -Actual $snapshotFour.PressureLevel -Expected 'Normal' -Message 'Normal snapshot pressure changed.'
Assert-Equal -Actual $snapshotFour.PressureStreakSamples -Expected 0 -Message 'Normal sample must reset the pressure streak.'
Assert-Equal -Actual $snapshotFour.SustainedPressure -Expected $false -Message 'Normal sample must clear sustained pressure.'

# Snapshot classification must use unrounded source ratios even when the public
# display fields round onto a threshold boundary.
$script:MockOperatingSystem.TotalVisibleMemorySize = [int64]1000000
$script:MockOperatingSystem.FreePhysicalMemory = [int64]200001
$script:MockMemory.CommittedBytes = [int64]500000
$script:MockMemory.CommitLimit = [int64]1000000
Initialize-ChromeCpuSample
$rawAvailableBoundary = Get-ChromeRamSnapshot `
    -ChromeProcesses $script:MockCimProcesses `
    -BrowserRoots @($script:MockCimProcesses[0], $script:MockCimProcesses[2]) `
    -SampleNumber 1
Assert-Equal -Actual $rawAvailableBoundary.AvailableRamPercent -Expected 20.0 -Message 'Available-RAM display rounding changed.'
Assert-Equal `
    -Actual $rawAvailableBoundary.PressureLevel `
    -Expected 'Normal' `
    -Message 'Raw available RAM just above 20 percent must remain Normal despite display rounding.'

$script:MockOperatingSystem.FreePhysicalMemory = [int64]900000
$script:MockMemory.CommittedBytes = [int64]799999
$script:PreviousSampleAt = (Get-Date).AddMinutes(-1)
$rawCommitBoundary = Get-ChromeRamSnapshot `
    -ChromeProcesses $script:MockCimProcesses `
    -BrowserRoots @($script:MockCimProcesses[0], $script:MockCimProcesses[2]) `
    -SampleNumber 2
Assert-Equal -Actual $rawCommitBoundary.CommitPercent -Expected 80.0 -Message 'Commit display rounding changed.'
Assert-Equal `
    -Actual $rawCommitBoundary.PressureLevel `
    -Expected 'Normal' `
    -Message 'Raw commit just below 80 percent must remain Normal despite display rounding.'

$script:MockOperatingSystem.TotalVisibleMemorySize = [int64](40 * 1MB)
$script:MockOperatingSystem.FreePhysicalMemory = [int64](20 * 1MB)
$script:MockMemory.CommittedBytes = [int64](60GB)
$script:MockMemory.CommitLimit = [int64](80GB)
$script:MockMemory.PercentCommittedBytesInUse = 75

# Aggregate private growth is the exact selected-scope total delta, including
# process starts and exits, while per-process trends remain identity matched.
Initialize-ChromeCpuSample
$churnRoots = @(
    $script:MockCimProcesses |
        Where-Object { $_.ProcessId -in @(100, 200) } |
        Sort-Object ProcessId
)
[void](Get-ChromeRamSnapshot `
    -ChromeProcesses $script:MockCimProcesses `
    -BrowserRoots $churnRoots `
    -SampleNumber 1)
$newProcessTime = $createdAt.AddHours(2)
$script:MockCimProcesses = @(
    $script:MockCimProcesses | Where-Object { $_.ProcessId -ne 201 }
)
$script:MockCimProcesses += Get-FakeChromeProcess `
    -ProcessId 202 `
    -ParentProcessId 200 `
    -CommandLine 'chrome.exe --type=renderer' `
    -CreationDate $newProcessTime
$script:MockRuntimeProcesses = @(
    $script:MockRuntimeProcesses | Where-Object { $_.Id -ne 201 }
)
$script:MockRuntimeProcesses += Get-FakeRuntimeProcess `
    -ProcessId 202 `
    -StartTime $newProcessTime `
    -CpuSeconds 1 `
    -WorkingSetBytes (320MB) `
    -PrivateBytes (310MB)
$churnRoots = @(
    $script:MockCimProcesses |
        Where-Object { $_.ProcessId -in @(100, 200) } |
        Sort-Object ProcessId
)
$script:PreviousSampleAt = (Get-Date).AddMinutes(-1)
$churnSnapshot = Get-ChromeRamSnapshot `
    -ChromeProcesses $script:MockCimProcesses `
    -BrowserRoots $churnRoots `
    -SampleNumber 2
$newProcessRow = @($churnSnapshot.Processes | Where-Object { $_.PID -eq 202 })[0]
Assert-Null -Actual $newProcessRow.PrivateBytesDeltaMB -Message 'A new process must not receive an inherited per-process delta.'
Assert-Equal -Actual $churnSnapshot.TrendProcessCount -Expected 3 -Message 'Churn changed the comparable-process count.'
Assert-Between `
    -Actual $churnSnapshot.TotalPrivateGrowthMBPerMinute `
    -Minimum 199 `
    -Maximum 201 `
    -Message 'Aggregate private growth must include both the exited and newly created process.'

$replacementRootTime = $createdAt.AddHours(1).AddMinutes(30)
$replacementRootCim = @($script:MockCimProcesses | Where-Object { $_.ProcessId -eq 200 })[0]
$replacementRootRuntime = @($script:MockRuntimeProcesses | Where-Object { $_.Id -eq 200 })[0]
$replacementRootCim.CreationDate = $replacementRootTime
$replacementRootRuntime.StartTime = $replacementRootTime
$changedScopeRoots = @(
    $script:MockCimProcesses |
        Where-Object { $_.ProcessId -in @(100, 200) } |
        Sort-Object ProcessId
)
$script:PreviousSampleAt = (Get-Date).AddMinutes(-1)
$changedScopeSnapshot = Get-ChromeRamSnapshot `
    -ChromeProcesses $script:MockCimProcesses `
    -BrowserRoots $changedScopeRoots `
    -SampleNumber 3
Assert-Null `
    -Actual $changedScopeSnapshot.TotalPrivateGrowthMBPerMinute `
    -Message 'Aggregate private growth must be unavailable when the exact root identity set changes.'

$script:PressureStreakSamples = 2
[void](Assert-Throw `
    -Action { Get-ChromeRamSnapshot -ChromeProcesses @() -BrowserRoots @() -SampleNumber 5 } `
    -Pattern 'No Chrome browser roots' `
    -Message 'Unavailable samples must fail before pressure state changes.')
Assert-Equal `
    -Actual $script:PressureStreakSamples `
    -Expected 2 `
    -Message 'The snapshot helper must not partially commit pressure state before the sampling loop handles failure.'
Initialize-ChromeCpuSample
Assert-Equal -Actual $script:PressureStreakSamples -Expected 0 -Message 'Initialization must reset pressure history.'
Assert-Null -Actual $script:PreviousScopePrivateBytes -Message 'Initialization must reset aggregate private-byte history.'
Assert-Null -Actual $script:PreviousScopeRootIdentityKey -Message 'Initialization must reset aggregate scope identity.'

# Exercise the sampling loop with deterministic in-process doubles and no real delay.
$script:LoopSnapshotCalls = 0
$script:LoopSampleNumbers = @()
$script:LoopShownNumbers = @()
$script:LoopSleepSeconds = @()
$script:LoopUnavailableMessages = @()
$script:LoopUnavailableWillRetry = @()
$script:LoopFailAttempts = @()
$script:LoopJsonCalls = 0
$script:LoopInventoryCalls = 0
$script:LoopUseReusedRoot = $false
$script:LoopPressureOnSuccess = $false
$script:LoopRootOne = Get-FakeChromeProcess `
    -ProcessId 100 `
    -ParentProcessId 10 `
    -CommandLine 'chrome.exe --profile-directory=Default' `
    -CreationDate $createdAt
$script:LoopRootTwo = Get-FakeChromeProcess `
    -ProcessId 100 `
    -ParentProcessId 10 `
    -CommandLine 'chrome.exe --profile-directory=Default' `
    -CreationDate $createdAt.AddHours(1)

function Get-ChromeProcessInventory {
    $script:LoopInventoryCalls++
    if ($script:LoopUseReusedRoot -and $script:LoopInventoryCalls -gt 1) {
        return @($script:LoopRootTwo)
    }
    return @($script:LoopRootOne)
}

function Get-ChromeRamSnapshot {
    param(
        [object[]]$ChromeProcesses,
        [object[]]$BrowserRoots,
        [int]$SampleNumber
    )

    [void]$ChromeProcesses
    [void]$BrowserRoots
    $script:LoopSnapshotCalls++
    $script:LoopSampleNumbers += $SampleNumber
    if ($script:LoopFailAttempts -contains $SampleNumber) {
        throw "Synthetic sample failure $SampleNumber"
    }
    if ($script:LoopPressureOnSuccess) {
        $script:PressureStreakSamples++
    }
    return [pscustomobject]@{ SampleNumber = $SampleNumber }
}

function Show-ChromeRamSnapshot {
    param([pscustomobject]$Snapshot)
    $script:LoopShownNumbers += $Snapshot.SampleNumber
}

function Show-ChromeRamUnavailable {
    param(
        [string]$Message,
        [bool]$WillRetry = $true
    )

    $script:LoopUnavailableMessages += $Message
    $script:LoopUnavailableWillRetry += $WillRetry
}

function ConvertTo-ChromeRamJson {
    param([pscustomobject]$Snapshot)
    [void]$Snapshot
    $script:LoopJsonCalls++
    return '{"synthetic":true}'
}

function Start-Sleep {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidOverwritingBuiltInCmdlets',
        '',
        Justification = 'This test-local function records bounded-loop delays without waiting.'
    )]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'This test-local function records a delay value and changes no system state.'
    )]
    [CmdletBinding()]
    param([int]$Seconds)
    $script:LoopSleepSeconds += $Seconds
}

function Initialize-TestWatchOption {
    param(
        [bool]$AllInstances = $true,
        [int]$BrowserProcessId = 0,
        [bool]$ListInstances = $false,
        [bool]$Once = $false,
        [int]$SampleCount = 0,
        [bool]$Json = $false
    )

    $script:Options.AllInstances = $AllInstances
    $script:Options.BrowserProcessId = $BrowserProcessId
    $script:Options.ListInstances = $ListInstances
    $script:Options.Once = $Once
    $script:Options.SampleCount = $SampleCount
    $script:Options.Json = $Json
    $script:Options.RefreshSeconds = 5
    $script:Options.NoClear = $true
}

Initialize-TestWatchOption -AllInstances $true -SampleCount 3
Invoke-ChromeRamWatch
Assert-Equal -Actual $script:LoopSnapshotCalls -Expected 3 -Message 'Bounded sampling did not attempt exactly three samples.'
Assert-SequenceEqual -Actual $script:LoopSampleNumbers -Expected @(1, 2, 3) -Message 'Bounded sample numbering changed.'
Assert-SequenceEqual -Actual $script:LoopShownNumbers -Expected @(1, 2, 3) -Message 'Bounded sampling did not show every success.'
Assert-SequenceEqual -Actual $script:LoopSleepSeconds -Expected @(5, 5) -Message 'Bounded sampling must sleep exactly N-1 times.'

$script:LoopSnapshotCalls = 0
$script:LoopSampleNumbers = @()
$script:LoopShownNumbers = @()
$script:LoopSleepSeconds = @()
$script:LoopUnavailableMessages = @()
$script:LoopUnavailableWillRetry = @()
$script:LoopFailAttempts = @(2, 3)
$script:LoopInventoryCalls = 0
$script:LoopPressureOnSuccess = $true
Initialize-TestWatchOption -AllInstances $true -SampleCount 3
$boundedFailure = Assert-Throw `
    -Action { Invoke-ChromeRamWatch } `
    -Pattern 'Completed 3 sampling attempts.*2 were unavailable.*Collected 1 of 3' `
    -Message 'Bounded sampling must terminate nonzero after unavailable attempts.'
Assert-Equal -Actual $script:LoopSnapshotCalls -Expected 3 -Message 'Unavailable attempts must still consume the finite bound.'
Assert-SequenceEqual -Actual $script:LoopShownNumbers -Expected @(1) -Message 'Only successful bounded attempts may be shown as snapshots.'
Assert-SequenceEqual -Actual $script:LoopSleepSeconds -Expected @(5, 5) -Message 'Failed bounded attempts changed sleep count.'
Assert-SequenceEqual `
    -Actual $script:LoopUnavailableWillRetry `
    -Expected @($true, $false) `
    -Message 'Final unavailable attempt must not claim it will retry.'
Assert-True -Condition ($boundedFailure -match 'Collected 1 of 3') -Message 'Bounded failure summary is incomplete.'
Assert-Equal `
    -Actual $script:PressureStreakSamples `
    -Expected 0 `
    -Message 'Unavailable attempts must reset the sustained-pressure streak.'
$script:LoopPressureOnSuccess = $false

$script:LoopSnapshotCalls = 0
$script:LoopSampleNumbers = @()
$script:LoopShownNumbers = @()
$script:LoopSleepSeconds = @()
$script:LoopFailAttempts = @()
$script:LoopInventoryCalls = 0
Initialize-TestWatchOption -AllInstances $true -Once $true
Invoke-ChromeRamWatch
Assert-Equal -Actual $script:LoopSnapshotCalls -Expected 1 -Message '-Once must attempt exactly one sample.'
Assert-Equal -Actual $script:LoopSleepSeconds.Count -Expected 0 -Message '-Once must not sleep.'

$script:LoopSnapshotCalls = 0
$script:LoopJsonCalls = 0
$script:LoopSleepSeconds = @()
$script:LoopFailAttempts = @()
$script:LoopInventoryCalls = 0
Initialize-TestWatchOption -AllInstances $true -SampleCount 1 -Json $true
Invoke-ChromeRamWatch | Out-Null
Assert-Equal -Actual $script:LoopSnapshotCalls -Expected 1 -Message '-SampleCount 1 JSON must sample once.'
Assert-Equal -Actual $script:LoopJsonCalls -Expected 1 -Message '-SampleCount 1 JSON must serialize once.'
Assert-Equal -Actual $script:LoopSleepSeconds.Count -Expected 0 -Message '-SampleCount 1 JSON must not sleep.'

Initialize-TestWatchOption -AllInstances $true -BrowserProcessId 100 -Once $true
[void](Assert-Throw `
    -Action { Invoke-ChromeRamWatch } `
    -Pattern '-AllInstances cannot be combined with -BrowserProcessId' `
    -Message 'AllInstances and BrowserProcessId must be mutually exclusive.')
Initialize-TestWatchOption -AllInstances $true -Once $true -SampleCount 2
[void](Assert-Throw `
    -Action { Invoke-ChromeRamWatch } `
    -Pattern '-Once can be combined only with -SampleCount 0 or 1' `
    -Message 'Once and multi-sample bounds must be mutually exclusive.')
Initialize-TestWatchOption -AllInstances $true -Json $true
[void](Assert-Throw `
    -Action { Invoke-ChromeRamWatch } `
    -Pattern '-Json requires -Once or -SampleCount 1' `
    -Message 'Unbounded JSON must be rejected.')
Initialize-TestWatchOption -AllInstances $true -ListInstances $true
[void](Assert-Throw `
    -Action { Invoke-ChromeRamWatch } `
    -Pattern '-ListInstances cannot be combined with' `
    -Message 'ListInstances combinations must be rejected.')

$script:LoopSnapshotCalls = 0
$script:LoopSampleNumbers = @()
$script:LoopShownNumbers = @()
$script:LoopSleepSeconds = @()
$script:LoopUnavailableMessages = @()
$script:LoopUnavailableWillRetry = @()
$script:LoopFailAttempts = @()
$script:LoopInventoryCalls = 0
$script:LoopUseReusedRoot = $true
Initialize-TestWatchOption -AllInstances $false -BrowserProcessId 100 -SampleCount 2
[void](Assert-Throw `
    -Action { Invoke-ChromeRamWatch } `
    -Pattern 'Completed 2 sampling attempts.*1 were unavailable.*Collected 1 of 2' `
    -Message 'Explicit-root PID replacement must fail the bounded run.')
Assert-Equal -Actual $script:LoopSnapshotCalls -Expected 1 -Message 'Replacement root must be rejected before snapshot collection.'
Assert-True `
    -Condition (($script:LoopUnavailableMessages -join ' ') -match 'replaced by a different process') `
    -Message 'PID-reuse rejection reason was not surfaced.'

$script:LoopSnapshotCalls = 0
$script:LoopSampleNumbers = @()
$script:LoopShownNumbers = @()
$script:LoopSleepSeconds = @()
$script:LoopUnavailableMessages = @()
$script:LoopUnavailableWillRetry = @()
$script:LoopFailAttempts = @()
$script:LoopInventoryCalls = 0
Initialize-TestWatchOption -AllInstances $false -BrowserProcessId 0 -SampleCount 2
[void](Assert-Throw `
    -Action { Invoke-ChromeRamWatch } `
    -Pattern 'Completed 2 sampling attempts.*1 were unavailable.*Collected 1 of 2' `
    -Message 'Auto-selected root replacement must fail the bounded run.')
Assert-Equal `
    -Actual $script:LoopSnapshotCalls `
    -Expected 1 `
    -Message 'An auto-selected replacement root must be rejected before snapshot collection.'
Assert-True `
    -Condition (($script:LoopUnavailableMessages -join ' ') -match 'replaced by a different process') `
    -Message 'Auto-selected root replacement reason was not surfaced.'
$script:LoopUseReusedRoot = $false

# Enforce the watcher-only no-network, no-write, no-process-control contract through its AST.
$blockedCommands = @(
    'Add-Content',
    'Add-Type',
    'Clear-Content',
    'Copy-Item',
    'curl',
    'Export-Clixml',
    'Export-Csv',
    'Invoke-CimMethod',
    'Invoke-Expression',
    'Invoke-RestMethod',
    'Invoke-WebRequest',
    'irm',
    'iwr',
    'Move-Item',
    'New-Item',
    'New-ItemProperty',
    'Out-File',
    'Remove-CimInstance',
    'Remove-Item',
    'Remove-ItemProperty',
    'Rename-Item',
    'Set-CimInstance',
    'Set-Content',
    'Set-Item',
    'Set-ItemProperty',
    'Start-BitsTransfer',
    'Start-Process',
    'Stop-Process',
    'taskkill',
    'Tee-Object',
    'wget'
)
$usedCommands = @(
    $watchSyntaxTree.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.CommandAst] },
        $true
    ) |
        ForEach-Object { $_.GetCommandName() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)
foreach ($blockedCommand in $blockedCommands) {
    Assert-True `
        -Condition ($usedCommands -notcontains $blockedCommand) `
        -Message "Read-only contract failed. Main script invokes '$blockedCommand'."
}

$blockedMemberNames = @(
    'CloseMainWindow',
    'Delete',
    'Kill',
    'Move',
    'Replace',
    'Send',
    'SetValue',
    'WriteAllBytes',
    'WriteAllLines',
    'WriteAllText'
)
$blockedMemberCalls = @(
    $watchSyntaxTree.FindAll(
        {
            param($node)
            $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            [string]$node.Member.Value -in $blockedMemberNames
        },
        $true
    )
)
Assert-Equal -Actual $blockedMemberCalls.Count -Expected 0 -Message 'Read-only contract failed through a .NET member call.'

$blockedTypes = @(
    $watchSyntaxTree.FindAll(
        {
            param($node)
            $node -is [System.Management.Automation.Language.TypeExpressionAst] -and
            $node.TypeName.FullName -match '^(?:System\.)?Net\.|^System\.IO\.(?:File|Directory)$|^Microsoft\.Win32\.Registry'
        },
        $true
    )
)
Assert-Equal -Actual $blockedTypes.Count -Expected 0 -Message 'Read-only contract failed through a network or filesystem type.'

$dynamicInvocations = @(
    $watchSyntaxTree.FindAll(
        {
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand
        },
        $true
    )
)
Assert-Equal -Actual $dynamicInvocations.Count -Expected 0 -Message 'Dynamic command invocation is forbidden in the watcher.'

$fileRedirections = @(
    $watchSyntaxTree.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.FileRedirectionAst] },
        $true
    )
)
Assert-Equal -Actual $fileRedirections.Count -Expected 0 -Message 'The watcher must not redirect output to files.'

$nodeCommand = Get-Command node -ErrorAction SilentlyContinue
Assert-True -Condition ($null -ne $nodeCommand) -Message 'Node.js is required for companion safety tests.'
& $nodeCommand.Source $resolvedCompanionTest
if ($LASTEXITCODE -ne 0) {
    throw "Companion safety tests failed with exit code $LASTEXITCODE."
}

& $nodeCommand.Source $resolvedAutoGuardTest
if ($LASTEXITCODE -ne 0) {
    throw "Auto Guard safety tests failed with exit code $LASTEXITCODE."
}

Write-Output 'All Chrome RAM Watch v0.3 static and behavior tests passed.'
