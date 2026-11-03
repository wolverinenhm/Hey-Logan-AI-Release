# Build dist\HeyLoganAI-Portable-<version>-win-x64.zip.
#
# Usage (from anywhere):
#   powershell -NoProfile -ExecutionPolicy Bypass -File windows\installer\build-portable.ps1
#
# The ZIP contains one top-level folder (HeyLoganAI) holding the same payload
# as the installer plus README-FIRST.txt and "Start Hey Logan AI.cmd".
# It performs no registry writes and creates no shortcuts; the app's settings
# live in app\data inside the extracted folder.

[CmdletBinding()]
param(
    [string]$Version = '1.0.0',
    [string]$PayloadDir = '',
    [string]$OutDir = '',
    [switch]$KeepStage,
    [switch]$SkipPayloadValidation
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\build-common.ps1')

$root = Get-ReleaseRoot
if (-not $PayloadDir) { $PayloadDir = Get-PayloadDefaultPath -ReleaseRoot $root }
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }
$PayloadDir = (Resolve-Path -LiteralPath $PayloadDir).Path
$null = New-Item -ItemType Directory -Path $OutDir -Force

Write-Host ''
Write-Host '=== Hey Logan AI - build portable ZIP ===' -ForegroundColor Cyan
Write-Host "  release root : $root"
Write-Host "  payload      : $PayloadDir"
Write-Host "  output dir   : $OutDir"
Write-Host "  version      : $Version"

if (-not $SkipPayloadValidation) {
    $null = Assert-Payload -PayloadDir $PayloadDir -AllowAppData
}

# --- stage: payload (without app\data) + portable-only files ---------------
$buildRoot = Join-Path $PSScriptRoot '.build'
$stageParent = Join-Path $buildRoot 'portable'
$stage = Join-Path $stageParent 'HeyLoganAI'

Write-Host ''
Write-Host "  staging portable tree under $stageParent" -ForegroundColor DarkGray
Copy-PayloadTree -Source $PayloadDir -Destination $stage

foreach ($extra in @('README-FIRST.txt', 'Start Hey Logan AI.cmd')) {
    $source = Join-Path (Join-Path $PSScriptRoot 'portable') $extra
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Portable extra file missing: $source"
    }
    Copy-Item -LiteralPath $source -Destination (Join-Path $stage $extra) -Force
}

# Validate the staged tree and confirm app\data is absolutely absent.
$payload = Assert-Payload -PayloadDir $stage
Write-Host "  payload files: $($payload.FileCount) ($(Format-Bytes $payload.TotalBytes)), app\data excluded"

$zipPath = Join-Path $OutDir "HeyLoganAI-Portable-$Version-win-x64.zip"
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

Write-Host "  compressing to $zipPath" -ForegroundColor DarkGray
$tar = Join-Path $env:WINDIR 'System32\tar.exe'
if (Test-Path -LiteralPath $tar) {
    # bsdtar from Windows 10 1803+ writes a standard Deflate ZIP much faster
    # than Compress-Archive on a 90 MB payload; -a infers the format from .zip.
    & $tar -a -c -f $zipPath -C $stageParent 'HeyLoganAI'
    if ($LASTEXITCODE -ne 0) {
        throw "tar.exe failed while creating the portable ZIP (exit code $LASTEXITCODE)."
    }
}
else {
    Write-Host '  tar.exe not found - falling back to Compress-Archive (slower)' -ForegroundColor Yellow
    Compress-Archive -Path $stage -DestinationPath $zipPath -CompressionLevel Optimal
}

if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) {
    throw "The portable ZIP was not created: $zipPath"
}

# --- verify the archive is a readable ZIP with the expected layout ---------
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $entryNames = @($archive.Entries | ForEach-Object { $_.FullName })
}
finally {
    $archive.Dispose()
}
if ($entryNames.Count -lt 500) {
    throw "The portable ZIP only contains $($entryNames.Count) entries; the payload is probably missing."
}
$requiredEntries = @(
    'HeyLoganAI/README-FIRST.txt',
    'HeyLoganAI/Start Hey Logan AI.cmd',
    'HeyLoganAI/Launch.vbs',
    'HeyLoganAI/runtime/node.exe',
    'HeyLoganAI/app/server/index.js',
    'HeyLoganAI/tools/pair.js'
)
foreach ($entry in $requiredEntries) {
    if ($entryNames -notcontains $entry) {
        throw "The portable ZIP is missing the entry: $entry"
    }
}
if ($entryNames | Where-Object { $_ -match '(^|/)app/data/' }) {
    throw 'The portable ZIP contains app\data - user data must never be shipped.'
}
Write-Host "  zip entries  : $($entryNames.Count) (layout verified)"

$summary = Write-ArtifactInfo -Path $zipPath -Label 'Portable ZIP built'

if (-not $KeepStage) {
    Remove-Item -LiteralPath $stageParent -Recurse -Force -ErrorAction SilentlyContinue
}

return $summary
