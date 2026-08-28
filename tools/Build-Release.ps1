#Requires -Version 5.1

[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string]$Version = '0.3.0'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$distributionDirectory = Join-Path $repositoryRoot 'dist'
$archiveName = "ChromeRamWatch-v$Version.zip"
$archivePath = Join-Path $distributionDirectory $archiveName
$checksumPath = Join-Path $distributionDirectory 'SHA256SUMS.txt'
$archiveRootName = "ChromeRamWatch-v$Version"
$fixedDosTime = [uint16]0
$fixedDosDate = [uint16]0x2821 # 2000-01-01 00:00:00, valid in the ZIP timestamp range.
$zipVersionMadeBy = [uint16]20
$zipVersionNeeded = [uint16]10
$utf8FileNameFlag = [uint16]0x0800
$storeCompressionMethod = [uint16]0

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

$resolvedRepositoryRoot = [System.IO.Path]::GetFullPath($repositoryRoot).TrimEnd('\', '/')
$repositoryPrefix = $resolvedRepositoryRoot + [System.IO.Path]::DirectorySeparatorChar

function Get-CheckedReleaseItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$RootPrefix
    )

    $resolvedPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if (
        -not $resolvedPath.Equals($Root, [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $resolvedPath.StartsWith($RootPrefix, [System.StringComparison]::OrdinalIgnoreCase)
    ) {
        throw "Release path is outside the repository: $Path"
    }

    $pathChain = [System.Collections.Generic.List[string]]::new()
    $pathCursor = $resolvedPath
    while (-not $pathCursor.Equals($Root, [System.StringComparison]::OrdinalIgnoreCase)) {
        $pathChain.Insert(0, $pathCursor)
        $parentPath = [System.IO.Path]::GetDirectoryName($pathCursor)
        if (
            [string]::IsNullOrWhiteSpace($parentPath) -or
            $parentPath.Equals($pathCursor, [System.StringComparison]::OrdinalIgnoreCase)
        ) {
            throw "Release path does not have the expected repository ancestor: $Path"
        }
        $pathCursor = $parentPath.TrimEnd('\', '/')
    }
    $pathChain.Insert(0, $Root)

    $checkedItem = $null
    foreach ($pathToCheck in $pathChain) {
        try {
            $checkedItem = Get-Item -LiteralPath $pathToCheck -Force -ErrorAction Stop
        }
        catch {
            throw "Required release path is missing: $pathToCheck"
        }

        if (($checkedItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Release path contains a reparse point: $pathToCheck"
        }
    }

    return $checkedItem
}

$repositoryItem = Get-CheckedReleaseItem `
    -Path $resolvedRepositoryRoot `
    -Root $resolvedRepositoryRoot `
    -RootPrefix $repositoryPrefix
if (-not $repositoryItem.PSIsContainer) {
    throw "Release repository root is not a directory: $resolvedRepositoryRoot"
}

$archiveFiles = [System.Collections.Generic.Dictionary[string, string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

foreach ($relativePath in $includedPaths) {
    $sourcePath = [System.IO.Path]::GetFullPath((Join-Path $resolvedRepositoryRoot $relativePath))
    if (-not $sourcePath.StartsWith($repositoryPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe release source path: $relativePath"
    }
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw "Required release path is missing: $relativePath"
    }

    $sourceFiles = [System.Collections.Generic.List[object]]::new()
    $pendingPaths = [System.Collections.Generic.Stack[string]]::new()
    $pendingPaths.Push($sourcePath)
    while ($pendingPaths.Count -gt 0) {
        $currentPath = $pendingPaths.Pop()
        $currentItem = Get-CheckedReleaseItem `
            -Path $currentPath `
            -Root $resolvedRepositoryRoot `
            -RootPrefix $repositoryPrefix
        if ($currentItem.PSIsContainer) {
            foreach ($childItem in @(Get-ChildItem -LiteralPath $currentItem.FullName -Force)) {
                if (($childItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Release path contains a reparse point: $($childItem.FullName)"
                }
                $pendingPaths.Push($childItem.FullName)
            }
        }
        else {
            [void]$sourceFiles.Add($currentItem)
        }
    }

    foreach ($sourceFile in $sourceFiles) {
        $resolvedSourceFile = [System.IO.Path]::GetFullPath($sourceFile.FullName)
        if (-not $resolvedSourceFile.StartsWith($repositoryPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsafe release file path: $($sourceFile.FullName)"
        }

        $relativeFile = $resolvedSourceFile.Substring($repositoryPrefix.Length).Replace('\', '/')
        if (
            [string]::IsNullOrWhiteSpace($relativeFile) -or
            $relativeFile.StartsWith('/', [System.StringComparison]::Ordinal) -or
            $relativeFile -match '(^|/)\.\.(/|$)' -or
            $relativeFile -match '^[A-Za-z]:'
        ) {
            throw "Unsafe release entry path: $relativeFile"
        }

        $entryName = "$archiveRootName/$relativeFile"
        if ($archiveFiles.ContainsKey($entryName)) {
            throw "Duplicate or case-colliding release entry: $entryName"
        }
        [void]$archiveFiles.Add($entryName, $resolvedSourceFile)
    }
}

[string[]]$entryNames = @($archiveFiles.Keys)
[System.Array]::Sort([System.Array]$entryNames, [System.StringComparer]::Ordinal)

[uint32[]]$crc32Table = New-Object 'uint32[]' 256
for ($tableIndex = 0; $tableIndex -lt $crc32Table.Length; $tableIndex++) {
    [uint32]$tableValue = $tableIndex
    for ($bit = 0; $bit -lt 8; $bit++) {
        if (($tableValue -band 1) -ne 0) {
            $tableValue = [uint32](($tableValue -shr 1) -bxor [uint32]3988292384)
        }
        else {
            $tableValue = [uint32]($tableValue -shr 1)
        }
    }
    $crc32Table[$tableIndex] = $tableValue
}

$resolvedDistributionDirectory = [System.IO.Path]::GetFullPath($distributionDirectory).TrimEnd('\', '/')
if (-not $resolvedDistributionDirectory.StartsWith($repositoryPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe release distribution path: $resolvedDistributionDirectory"
}

$distributionItem = Get-Item -LiteralPath $resolvedDistributionDirectory -Force -ErrorAction SilentlyContinue
if ($null -ne $distributionItem) {
    if (($distributionItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Release distribution path contains a reparse point: $resolvedDistributionDirectory"
    }
}
else {
    [void](Get-CheckedReleaseItem `
        -Path $resolvedRepositoryRoot `
        -Root $resolvedRepositoryRoot `
        -RootPrefix $repositoryPrefix)
    [void](New-Item -ItemType Directory -Path $resolvedDistributionDirectory)
}

$distributionItem = Get-CheckedReleaseItem `
    -Path $resolvedDistributionDirectory `
    -Root $resolvedRepositoryRoot `
    -RootPrefix $repositoryPrefix
if (-not $distributionItem.PSIsContainer) {
    throw "Release distribution path is not a directory: $resolvedDistributionDirectory"
}

$buildToken = [guid]::NewGuid().ToString('N')
$temporaryArchivePath = Join-Path $resolvedDistributionDirectory ('.{0}.{1}.tmp' -f $archiveName, $buildToken)
$temporaryChecksumPath = Join-Path $resolvedDistributionDirectory ('.SHA256SUMS.txt.{0}.tmp' -f $buildToken)
$temporaryBackupPath = Join-Path $resolvedDistributionDirectory ('.{0}.{1}.backup.tmp' -f $archiveName, $buildToken)
$archiveStream = $null
$archiveWriter = $null
$hash = $null

try {
    try {
        $archiveStream = [System.IO.File]::Open(
            $temporaryArchivePath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        $archiveWriter = [System.IO.BinaryWriter]::new(
            $archiveStream,
            [System.Text.UTF8Encoding]::new($false),
            $true
        )
        $centralDirectoryEntries = [System.Collections.Generic.List[object]]::new()
        $copyBuffer = New-Object 'byte[]' 81920

        foreach ($entryName in $entryNames) {
            $entryNameBytes = [System.Text.Encoding]::UTF8.GetBytes($entryName)
            if ($entryNameBytes.Length -gt [uint16]::MaxValue) {
                throw "Release entry name is too long for ZIP: $entryName"
            }

            $sourceFile = Get-CheckedReleaseItem `
                -Path $archiveFiles[$entryName] `
                -Root $resolvedRepositoryRoot `
                -RootPrefix $repositoryPrefix
            if ($sourceFile.PSIsContainer) {
                throw "Release file became a directory while it was being archived: $($sourceFile.FullName)"
            }
            if ($sourceFile.Length -gt [uint32]::MaxValue) {
                throw "Release file is too large for ZIP32: $($sourceFile.FullName)"
            }
            if ($archiveStream.Position -gt [uint32]::MaxValue) {
                throw 'Release archive exceeds the ZIP32 offset limit.'
            }

            [uint32]$localHeaderOffset = $archiveStream.Position
            [uint32]$fileSize = $sourceFile.Length

            $archiveWriter.Write([uint32]0x04034b50)
            $archiveWriter.Write($zipVersionNeeded)
            $archiveWriter.Write($utf8FileNameFlag)
            $archiveWriter.Write($storeCompressionMethod)
            $archiveWriter.Write($fixedDosTime)
            $archiveWriter.Write($fixedDosDate)
            $archiveWriter.Write([uint32]0)
            $archiveWriter.Write($fileSize)
            $archiveWriter.Write($fileSize)
            $archiveWriter.Write([uint16]$entryNameBytes.Length)
            $archiveWriter.Write([uint16]0)
            $archiveWriter.Write($entryNameBytes)

            $sourceStream = $null
            try {
                $sourceStream = [System.IO.File]::OpenRead($archiveFiles[$entryName])
                [uint32]$crc32 = [uint32]::MaxValue
                [uint64]$bytesWritten = 0
                while (($bytesRead = $sourceStream.Read($copyBuffer, 0, $copyBuffer.Length)) -gt 0) {
                    $archiveWriter.Write($copyBuffer, 0, $bytesRead)
                    for ($bufferIndex = 0; $bufferIndex -lt $bytesRead; $bufferIndex++) {
                        $crcIndex = [int](($crc32 -bxor [uint32]$copyBuffer[$bufferIndex]) -band [uint32]255)
                        $crc32 = [uint32](($crc32 -shr 8) -bxor $crc32Table[$crcIndex])
                    }
                    $bytesWritten += [uint64]$bytesRead
                }
                $crc32 = [uint32]($crc32 -bxor [uint32]::MaxValue)
            }
            finally {
                if ($null -ne $sourceStream) {
                    $sourceStream.Dispose()
                }
            }

            if ($bytesWritten -ne $fileSize) {
                throw "Release file changed while it was being archived: $($sourceFile.FullName)"
            }

            $endOfEntry = $archiveStream.Position
            $archiveStream.Position = [int64]$localHeaderOffset + 14
            $archiveWriter.Write($crc32)
            $archiveStream.Position = $endOfEntry

            [void]$centralDirectoryEntries.Add([pscustomobject]@{
                EntryNameBytes    = $entryNameBytes
                Crc32             = $crc32
                FileSize          = $fileSize
                LocalHeaderOffset = $localHeaderOffset
            })
        }

        if ($centralDirectoryEntries.Count -gt [uint16]::MaxValue) {
            throw 'Release archive has too many entries for ZIP32.'
        }
        if ($archiveStream.Position -gt [uint32]::MaxValue) {
            throw 'Release archive exceeds the ZIP32 central-directory offset limit.'
        }

        [uint32]$centralDirectoryOffset = $archiveStream.Position
        foreach ($centralEntry in $centralDirectoryEntries) {
            $archiveWriter.Write([uint32]0x02014b50)
            $archiveWriter.Write($zipVersionMadeBy)
            $archiveWriter.Write($zipVersionNeeded)
            $archiveWriter.Write($utf8FileNameFlag)
            $archiveWriter.Write($storeCompressionMethod)
            $archiveWriter.Write($fixedDosTime)
            $archiveWriter.Write($fixedDosDate)
            $archiveWriter.Write([uint32]$centralEntry.Crc32)
            $archiveWriter.Write([uint32]$centralEntry.FileSize)
            $archiveWriter.Write([uint32]$centralEntry.FileSize)
            $archiveWriter.Write([uint16]$centralEntry.EntryNameBytes.Length)
            $archiveWriter.Write([uint16]0)
            $archiveWriter.Write([uint16]0)
            $archiveWriter.Write([uint16]0)
            $archiveWriter.Write([uint16]0)
            $archiveWriter.Write([uint32]0)
            $archiveWriter.Write([uint32]$centralEntry.LocalHeaderOffset)
            $archiveWriter.Write([byte[]]$centralEntry.EntryNameBytes)
        }

        [uint64]$centralDirectoryLength = $archiveStream.Position - $centralDirectoryOffset
        if ($centralDirectoryLength -gt [uint32]::MaxValue) {
            throw 'Release archive exceeds the ZIP32 central-directory size limit.'
        }

        $archiveWriter.Write([uint32]0x06054b50)
        $archiveWriter.Write([uint16]0)
        $archiveWriter.Write([uint16]0)
        $archiveWriter.Write([uint16]$centralDirectoryEntries.Count)
        $archiveWriter.Write([uint16]$centralDirectoryEntries.Count)
        $archiveWriter.Write([uint32]$centralDirectoryLength)
        $archiveWriter.Write($centralDirectoryOffset)
        $archiveWriter.Write([uint16]0)
        $archiveWriter.Flush()
    }
    finally {
        if ($null -ne $archiveWriter) {
            $archiveWriter.Dispose()
            $archiveWriter = $null
        }
        if ($null -ne $archiveStream) {
            $archiveStream.Dispose()
            $archiveStream = $null
        }
    }

    $temporaryArchiveItem = Get-CheckedReleaseItem `
        -Path $temporaryArchivePath `
        -Root $resolvedRepositoryRoot `
        -RootPrefix $repositoryPrefix
    if ($temporaryArchiveItem.PSIsContainer -or $temporaryArchiveItem.Length -eq 0) {
        throw 'Temporary release archive is missing or empty.'
    }

    $hash = Get-FileHash -LiteralPath $temporaryArchivePath -Algorithm SHA256
    $checksumLine = '{0}  {1}' -f $hash.Hash.ToLowerInvariant(), $archiveName
    $checksumBytes = [System.Text.Encoding]::ASCII.GetBytes($checksumLine + "`r`n")
    $checksumStream = $null
    try {
        $checksumStream = [System.IO.File]::Open(
            $temporaryChecksumPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        $checksumStream.Write($checksumBytes, 0, $checksumBytes.Length)
        $checksumStream.Flush()
    }
    finally {
        if ($null -ne $checksumStream) {
            $checksumStream.Dispose()
        }
    }

    $verifiedChecksum = [System.IO.File]::ReadAllText(
        $temporaryChecksumPath,
        [System.Text.Encoding]::ASCII
    )
    if ($verifiedChecksum -cne ($checksumLine + "`r`n")) {
        throw 'Temporary checksum verification failed.'
    }
    $verifiedHash = (Get-FileHash -LiteralPath $temporaryArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($verifiedHash -cne $hash.Hash.ToLowerInvariant()) {
        throw 'Temporary archive hash changed during verification.'
    }

    $distributionItem = Get-CheckedReleaseItem `
        -Path $resolvedDistributionDirectory `
        -Root $resolvedRepositoryRoot `
        -RootPrefix $repositoryPrefix
    if (-not $distributionItem.PSIsContainer) {
        throw "Release distribution path is not a directory: $resolvedDistributionDirectory"
    }

    $existingArchiveItem = Get-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
    if ($null -ne $existingArchiveItem) {
        $existingArchiveItem = Get-CheckedReleaseItem `
            -Path $archivePath `
            -Root $resolvedRepositoryRoot `
            -RootPrefix $repositoryPrefix
        if ($existingArchiveItem.PSIsContainer) {
            throw "Release archive path is not a file: $archivePath"
        }
    }

    $existingChecksumItem = Get-Item -LiteralPath $checksumPath -Force -ErrorAction SilentlyContinue
    if ($null -ne $existingChecksumItem) {
        $existingChecksumItem = Get-CheckedReleaseItem `
            -Path $checksumPath `
            -Root $resolvedRepositoryRoot `
            -RootPrefix $repositoryPrefix
        if ($existingChecksumItem.PSIsContainer) {
            throw "Release checksum path is not a file: $checksumPath"
        }
        [System.IO.File]::Delete($checksumPath)
    }

    if ($null -ne $existingArchiveItem) {
        [System.IO.File]::Replace($temporaryArchivePath, $archivePath, $temporaryBackupPath)
    }
    else {
        [System.IO.File]::Move($temporaryArchivePath, $archivePath)
    }

    $committedArchiveItem = Get-CheckedReleaseItem `
        -Path $archivePath `
        -Root $resolvedRepositoryRoot `
        -RootPrefix $repositoryPrefix
    if ($committedArchiveItem.PSIsContainer) {
        throw "Committed release archive path is not a file: $archivePath"
    }
    $committedHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($committedHash -cne $hash.Hash.ToLowerInvariant()) {
        throw 'Committed release archive hash does not match the verified temporary archive.'
    }

    try {
        [System.IO.File]::Move($temporaryChecksumPath, $checksumPath)
        $committedChecksum = [System.IO.File]::ReadAllText($checksumPath, [System.Text.Encoding]::ASCII)
        if ($committedChecksum -cne ($checksumLine + "`r`n")) {
            throw 'Committed release checksum does not match the verified temporary checksum.'
        }
    }
    catch {
        if ([System.IO.File]::Exists($checksumPath)) {
            [System.IO.File]::Delete($checksumPath)
        }
        throw
    }

    [pscustomobject]@{
        Archive      = $archivePath
        SHA256       = $hash.Hash.ToLowerInvariant()
        ChecksumFile = $checksumPath
    }
}
finally {
    foreach ($temporaryPath in @($temporaryArchivePath, $temporaryChecksumPath, $temporaryBackupPath)) {
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
    }
}
