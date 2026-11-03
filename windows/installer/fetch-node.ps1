# ===========================================================================
#  Fetch the Node.js Windows x64 runtime used by the installer payload.
#
#  The runtime (~83 MB) is NOT stored in git; run this once before building:
#
#      powershell -NoProfile -ExecutionPolicy Bypass -File windows\installer\fetch-node.ps1
#
#  It downloads node.exe for the pinned version from nodejs.org, verifies it
#  against the official SHASUMS256.txt, and writes it to
#  windows\payload\HeyLoganAI\runtime\node.exe
# ===========================================================================
param(
    [string]$Version = '22.23.3',
    [string]$PayloadDir = ''
)

$ErrorActionPreference = 'Stop'

if (-not $PayloadDir) {
    $releaseRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $PayloadDir = Join-Path $releaseRoot 'windows\payload\HeyLoganAI'
}
$runtimeDir = Join-Path $PayloadDir 'runtime'
$target = Join-Path $runtimeDir 'node.exe'

if ((Test-Path -LiteralPath $target) -and ((Get-Item -LiteralPath $target).Length -gt 10MB)) {
    Write-Host ('node.exe already present: ' + $target + ' (' + [math]::Round((Get-Item -LiteralPath $target).Length / 1MB, 1) + ' MB)')
    Write-Host 'Delete it first if you want to re-download.'
    exit 0
}

New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
$ProgressPreference = 'SilentlyContinue'
$base = 'https://nodejs.org/dist/v' + $Version
$nodeUrl = $base + '/win-x64/node.exe'
$shasumsUrl = $base + '/SHASUMS256.txt'

Write-Host ('Downloading ' + $nodeUrl)
Invoke-WebRequest -Uri $nodeUrl -OutFile $target -TimeoutSec 600 -UseBasicParsing

Write-Host 'Verifying checksum against SHASUMS256.txt ...'
$shasums = (Invoke-WebRequest -Uri $shasumsUrl -TimeoutSec 120 -UseBasicParsing).Content
$line = ($shasums -split "`n" | Where-Object { $_ -match '\snode\.exe\s*$' } | Select-Object -First 1)
if (-not $line) { throw 'Could not find node.exe in SHASUMS256.txt' }
$expected = ($line.Trim() -split '\s+')[0].ToLowerInvariant()
$actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $expected) {
    Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
    throw ('Checksum mismatch: expected ' + $expected + ', got ' + $actual)
}

$size = (Get-Item -LiteralPath $target).Length
Write-Host ''
Write-Host ('node.exe v' + $Version + ' ready: ' + $target)
Write-Host ('  size   : ' + [math]::Round($size / 1MB, 1) + ' MB')
Write-Host ('  sha256 : ' + $actual)
Write-Host ''
Write-Host 'You can now run windows\installer\build-setup.ps1 / build-portable.ps1.'
