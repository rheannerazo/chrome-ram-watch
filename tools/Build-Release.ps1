#Requires -Version 5.1

[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string]$Version = '0.1.0'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$distributionDirectory = Join-Path $repositoryRoot 'dist'
$archiveName = "ChromeRamWatch-v$Version.zip"
$archivePath = Join-Path $distributionDirectory $archiveName
$checksumPath = Join-Path $distributionDirectory 'SHA256SUMS.txt'
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("chrome-ram-watch-" + [guid]::NewGuid().ToString('N'))
$packageRoot = Join-Path $temporaryRoot "ChromeRamWatch-v$Version"

$includedPaths = @(
    '.github',
    'assets',
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

try {
    [void](New-Item -ItemType Directory -Path $distributionDirectory -Force)
    [void](New-Item -ItemType Directory -Path $packageRoot -Force)

    foreach ($relativePath in $includedPaths) {
        $sourcePath = Join-Path $repositoryRoot $relativePath
        if (-not (Test-Path -LiteralPath $sourcePath)) {
            throw "Required release path is missing: $relativePath"
        }

        Copy-Item -LiteralPath $sourcePath -Destination $packageRoot -Recurse -Force
    }

    Compress-Archive -LiteralPath $packageRoot -DestinationPath $archivePath -Force
    $hash = Get-FileHash -LiteralPath $archivePath -Algorithm SHA256
    $checksumLine = '{0}  {1}' -f $hash.Hash.ToLowerInvariant(), $archiveName
    Set-Content -LiteralPath $checksumPath -Value $checksumLine -Encoding ascii

    [pscustomobject]@{
        Archive      = $archivePath
        SHA256       = $hash.Hash.ToLowerInvariant()
        ChecksumFile = $checksumPath
    }
}
finally {
    $resolvedTempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedTemporaryRoot = [System.IO.Path]::GetFullPath($temporaryRoot)
    if (
        (Test-Path -LiteralPath $resolvedTemporaryRoot) -and
        $resolvedTemporaryRoot.StartsWith($resolvedTempBase, [System.StringComparison]::OrdinalIgnoreCase)
    ) {
        Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force
    }
}
