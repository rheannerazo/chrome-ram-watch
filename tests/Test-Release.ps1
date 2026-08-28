#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string]$Version = '0.2.0'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent $PSScriptRoot
}
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path

function Assert-ReleaseCondition {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-ReleaseSequence {
    param(
        [string[]]$Actual,
        [string[]]$Expected,
        [string]$Message
    )

    $actualText = $Actual -join [Environment]::NewLine
    $expectedText = $Expected -join [Environment]::NewLine
    if ($actualText -ne $expectedText) {
        $missing = @($Expected | Where-Object { $Actual -notcontains $_ })
        $unexpected = @($Actual | Where-Object { $Expected -notcontains $_ })
        throw (
            '{0}{1}Missing:{1}{2}{1}Unexpected:{1}{3}' -f
            $Message,
            [Environment]::NewLine,
            ($missing -join [Environment]::NewLine),
            ($unexpected -join [Environment]::NewLine)
        )
    }
}

function Assert-ReleaseThrow {
    param(
        [scriptblock]$Action,
        [string]$Pattern,
        [string]$Message
    )

    $didThrow = $false
    $caughtMessage = $null
    try {
        & $Action | Out-Null
    }
    catch {
        $didThrow = $true
        $caughtMessage = $_.Exception.Message
    }

    if (-not $didThrow) {
        throw $Message
    }
    if ($caughtMessage -notmatch $Pattern) {
        throw "$Message Unexpected error: $caughtMessage"
    }

    return $caughtMessage
}

$includedPaths = @(
    '.github',
    'assets',
    'companion-extension',
    'tests',
    'tools',
    '.editorconfig',
    '.gitignore',
    'CHANGELOG.md',
    'CONTRIBUTING.md',
    'LICENSE',
    'PSScriptAnalyzerSettings.psd1',
    'README.md',
    'SECURITY.md',
    'Watch-ChromeRam.ps1'
)

foreach ($relativePath in $includedPaths) {
    Assert-ReleaseCondition `
        -Condition (Test-Path -LiteralPath (Join-Path $RepositoryRoot $relativePath)) `
        -Message "Required release source is missing: $relativePath"
}

$temporaryBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$temporaryRoot = Join-Path `
    ([System.IO.Path]::GetTempPath()) `
    ('chrome-ram-watch-release-test-' + [guid]::NewGuid().ToString('N'))
$resolvedTemporaryRoot = [System.IO.Path]::GetFullPath($temporaryRoot)
Assert-ReleaseCondition `
    -Condition (
        $resolvedTemporaryRoot.StartsWith($temporaryBase, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTemporaryRoot) -like 'chrome-ram-watch-release-test-*'
    ) `
    -Message "Unsafe release-test temporary path: $resolvedTemporaryRoot"

function Copy-TestRepository {
    param(
        [string]$SourceRoot,
        [string]$DestinationRoot,
        [string[]]$Paths
    )

    [void](New-Item -ItemType Directory -Path $DestinationRoot -Force)
    foreach ($relativePath in $Paths) {
        Copy-Item `
            -LiteralPath (Join-Path $SourceRoot $relativePath) `
            -Destination $DestinationRoot `
            -Recurse `
            -Force
    }
}

function Get-ExpectedArchiveFile {
    param(
        [string]$SourceRoot,
        [string[]]$Paths,
        [string]$ArchiveRootName
    )

    $files = foreach ($relativePath in $Paths) {
        $sourcePath = Join-Path $SourceRoot $relativePath
        if ((Get-Item -LiteralPath $sourcePath).PSIsContainer) {
            Get-ChildItem -LiteralPath $sourcePath -Recurse -File -Force
        }
        else {
            Get-Item -LiteralPath $sourcePath
        }
    }

    [string[]]$expectedFiles = @(
        $files |
            ForEach-Object {
                $relativeFile = $_.FullName.Substring($SourceRoot.Length + 1).Replace('\', '/')
                "$ArchiveRootName/$relativeFile"
            }
    )
    [System.Array]::Sort([System.Array]$expectedFiles, [System.StringComparer]::Ordinal)
    return $expectedFiles
}

function Test-ReleaseArchive {
    param(
        [string]$ArchivePath,
        [string]$ChecksumPath,
        [string[]]$ExpectedFiles,
        [string]$ArchiveRootName,
        [string]$ExpectedVersion
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $directoryEntries = @($archive.Entries | Where-Object { [string]::IsNullOrEmpty($_.Name) })
        Assert-ReleaseCondition `
            -Condition ($directoryEntries.Count -eq 0) `
            -Message 'Release archive must not contain directory entries.'

        $fileEntries = @($archive.Entries | Where-Object { -not [string]::IsNullOrEmpty($_.Name) })
        $orderedFiles = @($fileEntries | ForEach-Object { $_.FullName.Replace('\', '/') })
        Assert-ReleaseSequence `
            -Actual $orderedFiles `
            -Expected $ExpectedFiles `
            -Message 'Release archive entries are not in deterministic order.'

        [string[]]$actualFiles = @($orderedFiles)
        [System.Array]::Sort([System.Array]$actualFiles, [System.StringComparer]::Ordinal)
        Assert-ReleaseSequence `
            -Actual $actualFiles `
            -Expected $ExpectedFiles `
            -Message 'Release archive contents differ from the exact allowlist.'

        $nonStoredEntries = @($fileEntries | Where-Object { $_.CompressedLength -ne $_.Length })
        Assert-ReleaseCondition `
            -Condition ($nonStoredEntries.Count -eq 0) `
            -Message 'Release archive contains an entry that is not in ZIP store mode.'

        $fixedTimestamp = [datetime]'2000-01-01T00:00:00'
        $wrongTimestamps = @($fileEntries | Where-Object { $_.LastWriteTime.DateTime -ne $fixedTimestamp })
        Assert-ReleaseCondition `
            -Condition ($wrongTimestamps.Count -eq 0) `
            -Message 'Release archive contains a non-deterministic timestamp.'

        $duplicateNames = @($actualFiles | Group-Object | Where-Object { $_.Count -gt 1 })
        $caseInsensitiveDuplicates = @(
            $actualFiles |
                Group-Object { $_.ToLowerInvariant() } |
                Where-Object { $_.Count -gt 1 }
        )
        Assert-ReleaseCondition -Condition ($duplicateNames.Count -eq 0) -Message 'Release archive has duplicate entries.'
        Assert-ReleaseCondition `
            -Condition ($caseInsensitiveDuplicates.Count -eq 0) `
            -Message 'Release archive has case-insensitive path collisions.'

        $unsafePaths = @(
            $actualFiles |
                Where-Object {
                    $_ -match '(^[/\\])|(^|[/\\])\.\.([/\\]|$)|^[A-Za-z]:' -or
                    -not $_.StartsWith("$ArchiveRootName/", [System.StringComparison]::Ordinal)
                }
        )
        Assert-ReleaseCondition -Condition ($unsafePaths.Count -eq 0) -Message 'Release archive has an unsafe path.'

        $forbiddenEntries = @(
            $actualFiles |
                Where-Object {
                    $_ -match '(?i)(^|/)(?:\.git|\.analysis-tools|dist|node_modules)(?:/|$)' -or
                    $_ -match '(?i)\.(?:log|tmp|bak|key|pem|pfx|crx)$'
                }
        )
        Assert-ReleaseCondition `
            -Condition ($forbiddenEntries.Count -eq 0) `
            -Message "Release archive contains forbidden files: $($forbiddenEntries -join ', ')"

        $watchEntryName = "$ArchiveRootName/Watch-ChromeRam.ps1"
        $watchEntry = @($fileEntries | Where-Object { $_.FullName.Replace('\', '/') -eq $watchEntryName })
        Assert-ReleaseCondition -Condition ($watchEntry.Count -eq 1) -Message 'Packaged watcher is missing or duplicated.'
        $reader = [System.IO.StreamReader]::new($watchEntry[0].Open())
        try {
            $watchText = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
        Assert-ReleaseCondition `
            -Condition ($watchText -match "ChromeRamWatchVersion\s*=\s*'$([regex]::Escape($ExpectedVersion))'") `
            -Message 'Archive name and watcher version do not match.'
    }
    finally {
        $archive.Dispose()
    }

    $archiveHash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $archiveName = Split-Path -Leaf $ArchivePath
    $checksumText = (Get-Content -LiteralPath $ChecksumPath -Raw).TrimEnd("`r", "`n")
    $expectedChecksum = '{0}  {1}' -f $archiveHash, $archiveName
    Assert-ReleaseCondition `
        -Condition ($checksumText -ceq $expectedChecksum) `
        -Message 'SHA256SUMS.txt does not exactly match the generated archive.'

    return $archiveHash
}

try {
    [void](New-Item -ItemType Directory -Path $resolvedTemporaryRoot -Force)
    $runOneRoot = Join-Path $resolvedTemporaryRoot 'run-one'
    $runTwoRoot = Join-Path $resolvedTemporaryRoot 'run-two'
    Copy-TestRepository -SourceRoot $RepositoryRoot -DestinationRoot $runOneRoot -Paths $includedPaths
    Copy-TestRepository -SourceRoot $RepositoryRoot -DestinationRoot $runTwoRoot -Paths $includedPaths

    $archiveRootName = "ChromeRamWatch-v$Version"
    $archiveName = "$archiveRootName.zip"
    $expectedFiles = Get-ExpectedArchiveFile `
        -SourceRoot $RepositoryRoot `
        -Paths $includedPaths `
        -ArchiveRootName $archiveRootName

    $buildOne = & (Join-Path $runOneRoot 'tools\Build-Release.ps1') -Version $Version
    $buildTwo = & (Join-Path $runTwoRoot 'tools\Build-Release.ps1') -Version $Version
    Assert-ReleaseCondition -Condition ($null -ne $buildOne) -Message 'First release build returned no result.'
    Assert-ReleaseCondition -Condition ($null -ne $buildTwo) -Message 'Second release build returned no result.'
    Assert-ReleaseCondition `
        -Condition ((Split-Path -Leaf $buildOne.Archive) -ceq $archiveName) `
        -Message 'First release build used the wrong archive name.'
    Assert-ReleaseCondition `
        -Condition ((Split-Path -Leaf $buildTwo.Archive) -ceq $archiveName) `
        -Message 'Second release build used the wrong archive name.'

    $hashOne = Test-ReleaseArchive `
        -ArchivePath $buildOne.Archive `
        -ChecksumPath $buildOne.ChecksumFile `
        -ExpectedFiles $expectedFiles `
        -ArchiveRootName $archiveRootName `
        -ExpectedVersion $Version
    $hashTwo = Test-ReleaseArchive `
        -ArchivePath $buildTwo.Archive `
        -ChecksumPath $buildTwo.ChecksumFile `
        -ExpectedFiles $expectedFiles `
        -ArchiveRootName $archiveRootName `
        -ExpectedVersion $Version

    Assert-ReleaseCondition `
        -Condition ($hashOne -ceq $hashTwo) `
        -Message "Two clean builds from identical inputs were not reproducible: $hashOne versus $hashTwo"

    $isWindowsPlatform = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
    if ($isWindowsPlatform) {
        $previousArchiveHash = (Get-FileHash -LiteralPath $buildOne.Archive -Algorithm SHA256).Hash
        $archiveLock = [System.IO.File]::Open(
            $buildOne.Archive,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        try {
            [void](Assert-ReleaseThrow `
                -Action { & (Join-Path $runOneRoot 'tools\Build-Release.ps1') -Version $Version } `
                -Pattern '.+' `
                -Message 'A locked final archive must make the release commit fail.')
        }
        finally {
            $archiveLock.Dispose()
        }

        $archiveHashAfterFailedCommit = (Get-FileHash -LiteralPath $buildOne.Archive -Algorithm SHA256).Hash
        Assert-ReleaseCondition `
            -Condition ($archiveHashAfterFailedCommit -ceq $previousArchiveHash) `
            -Message 'A failed release commit changed the previous final archive.'
        Assert-ReleaseCondition `
            -Condition (-not (Test-Path -LiteralPath $buildOne.ChecksumFile)) `
            -Message 'A failed release commit left a potentially stale checksum beside the archive.'

        $runOneDist = Split-Path -Parent $buildOne.Archive
        $leftoverTemporaryFiles = @(
            Get-ChildItem -LiteralPath $runOneDist -File -Force |
                Where-Object { $_.Name -match '^\..+\.tmp$' }
        )
        Assert-ReleaseCondition `
            -Condition ($leftoverTemporaryFiles.Count -eq 0) `
            -Message 'A failed release commit left temporary artifacts in dist.'

        $reparseRunRoot = Join-Path $resolvedTemporaryRoot 'run-reparse'
        Copy-TestRepository -SourceRoot $RepositoryRoot -DestinationRoot $reparseRunRoot -Paths $includedPaths
        $junctionTarget = Join-Path $resolvedTemporaryRoot 'junction-target'
        [void](New-Item -ItemType Directory -Path $junctionTarget)
        [System.IO.File]::WriteAllText(
            (Join-Path $junctionTarget 'outside.txt'),
            'This file must never enter the release archive.',
            [System.Text.Encoding]::UTF8
        )

        $sourceJunction = Join-Path $reparseRunRoot 'assets\reparse-test'
        $junctionSupported = $false
        try {
            [void](New-Item -ItemType Junction -Path $sourceJunction -Target $junctionTarget -ErrorAction Stop)
            $junctionSupported = $true
        }
        catch {
            Write-Warning "Skipping junction rejection tests because junction creation is unavailable: $($_.Exception.Message)"
        }

        if ($junctionSupported) {
            try {
                [void](Assert-ReleaseThrow `
                    -Action { & (Join-Path $reparseRunRoot 'tools\Build-Release.ps1') -Version $Version } `
                    -Pattern 'reparse point' `
                    -Message 'An included-path junction must be rejected before release creation.')
                Assert-ReleaseCondition `
                    -Condition (-not (Test-Path -LiteralPath (Join-Path $reparseRunRoot 'dist'))) `
                    -Message 'An included-path junction was rejected only after dist was created.'
            }
            finally {
                if (Test-Path -LiteralPath $sourceJunction) {
                    [System.IO.Directory]::Delete($sourceJunction)
                }
            }

            $junctionDistTarget = Join-Path $resolvedTemporaryRoot 'junction-dist-target'
            [void](New-Item -ItemType Directory -Path $junctionDistTarget)
            $distJunction = Join-Path $reparseRunRoot 'dist'
            try {
                [void](New-Item -ItemType Junction -Path $distJunction -Target $junctionDistTarget -ErrorAction Stop)
                [void](Assert-ReleaseThrow `
                    -Action { & (Join-Path $reparseRunRoot 'tools\Build-Release.ps1') -Version $Version } `
                    -Pattern 'distribution path contains a reparse point' `
                    -Message 'A reparse-point dist directory must be rejected before writing.')
                Assert-ReleaseCondition `
                    -Condition (@(Get-ChildItem -LiteralPath $junctionDistTarget -Force).Count -eq 0) `
                    -Message 'The release builder wrote through a reparse-point dist directory.'
            }
            finally {
                if (Test-Path -LiteralPath $distJunction) {
                    [System.IO.Directory]::Delete($distJunction)
                }
            }
        }
    }

    Write-Output "All Chrome RAM Watch release tests passed. SHA256: $hashOne"
}
finally {
    if (
        (Test-Path -LiteralPath $resolvedTemporaryRoot) -and
        $resolvedTemporaryRoot.StartsWith($temporaryBase, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTemporaryRoot) -like 'chrome-ram-watch-release-test-*'
    ) {
        Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force
    }
}
