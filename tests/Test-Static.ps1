#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ScriptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
    $ScriptPath = Join-Path $PSScriptRoot '..\Watch-ChromeRam.ps1'
}

function Assert-Equal {
    param(
        [object]$Actual,
        [object]$Expected,
        [string]$Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', received '$Actual'."
    }
}

function Assert-SequenceEqual {
    param(
        [object[]]$Actual,
        [object[]]$Expected,
        [string]$Message
    )

    $actualText = $Actual -join ','
    $expectedText = $Expected -join ','
    if ($actualText -ne $expectedText) {
        throw "$Message Expected '$expectedText', received '$actualText'."
    }
}

function Get-FakeChromeProcess {
    param(
        [int]$ProcessId,
        [int]$ParentProcessId,
        [string]$CommandLine,
        [string]$ExecutablePath = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
    )

    [pscustomobject]@{
        ProcessId       = $ProcessId
        ParentProcessId = $ParentProcessId
        SessionId       = 1
        CommandLine     = $CommandLine
        ExecutablePath  = $ExecutablePath
    }
}

$resolvedScript = (Resolve-Path -LiteralPath $ScriptPath).Path
$tokens = $null
$parseErrors = $null
$syntaxTree = [System.Management.Automation.Language.Parser]::ParseFile(
    $resolvedScript,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    $details = ($parseErrors | ForEach-Object { $_.Message }) -join [Environment]::NewLine
    throw "PowerShell parser errors:$([Environment]::NewLine)$details"
}

. $resolvedScript

$chromeProcesses = @(
    Get-FakeChromeProcess `
        -ProcessId 100 `
        -ParentProcessId 10 `
        -CommandLine '"C:\Program Files\Google\Chrome\Application\chrome.exe" --profile-directory="Profile 35"'
    Get-FakeChromeProcess `
        -ProcessId 101 `
        -ParentProcessId 100 `
        -CommandLine 'chrome.exe --type=renderer'
    Get-FakeChromeProcess `
        -ProcessId 102 `
        -ParentProcessId 101 `
        -CommandLine 'chrome.exe --type=utility --extension-process'
    Get-FakeChromeProcess `
        -ProcessId 200 `
        -ParentProcessId 20 `
        -CommandLine 'chrome.exe --user-data-dir="C:\Temp\ChromeTest" --profile-directory=Default'
    Get-FakeChromeProcess `
        -ProcessId 201 `
        -ParentProcessId 200 `
        -CommandLine 'chrome.exe --type=renderer'
)

$rootIds = @(
    Get-ChromeBrowserRoot -ChromeProcesses $chromeProcesses |
        ForEach-Object { [int]$_.ProcessId } |
        Sort-Object
)
Assert-SequenceEqual -Actual $rootIds -Expected @(100, 200) -Message 'Root detection failed.'

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
Assert-SequenceEqual -Actual $descendantIds -Expected @(100, 101, 102) -Message 'Process-tree isolation failed.'

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

$sampleSnapshot = [pscustomobject]@{
    SampleAt           = [datetimeoffset]'2026-08-28T04:00:00+08:00'
    RootProcessId      = 100
    Channel            = 'Stable'
    UserDataMode       = 'Standard'
    LaunchProfileHint  = 'Profile 35'
    TotalRamGB         = 40
    AvailableRamGB     = 20
    CommitGB           = 25
    CommitLimitGB      = 75
    CommitPercent      = 33
    PagesPerSecond     = 0
    PageReadsPerSecond = 0
    ProcessCount       = 3
    SummedWorkingSetGB = 6.5
    PrivateBytesGB     = 6.2
    TopProcesses       = @()
}
$jsonSample = ConvertTo-ChromeRamJson -Snapshot $sampleSnapshot | ConvertFrom-Json
Assert-Equal -Actual $jsonSample.SchemaVersion -Expected 'chrome-ram-watch/v1' -Message 'JSON schema changed.'
Assert-Equal -Actual $jsonSample.Scope.Type -Expected 'browser-process-tree' -Message 'JSON scope changed.'
Assert-Equal -Actual $jsonSample.Scope.MayIncludeProfiles -Expected $true -Message 'JSON scope disclosure missing.'

$blockedCommands = @(
    'Invoke-RestMethod',
    'Invoke-WebRequest',
    'New-ItemProperty',
    'Remove-Item',
    'Set-ItemProperty',
    'Start-BitsTransfer',
    'Start-Process',
    'Stop-Process',
    'taskkill'
)
$usedCommands = @(
    $syntaxTree.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.CommandAst] },
        $true
    ) |
        ForEach-Object { $_.GetCommandName() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)
foreach ($blockedCommand in $blockedCommands) {
    if ($usedCommands -contains $blockedCommand) {
        throw "Read-only contract failed. Main script invokes '$blockedCommand'."
    }
}

$blockedMemberCalls = @(
    $syntaxTree.FindAll(
        {
            param($node)
            $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            $node.Member.Value -in @('Kill', 'CloseMainWindow')
        },
        $true
    )
)
if ($blockedMemberCalls.Count -gt 0) {
    throw 'Read-only contract failed. Main script invokes a process-closing method.'
}

Write-Output 'All Chrome RAM Watch static tests passed.'
