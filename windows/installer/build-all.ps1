# Build both Windows release artifacts in one command:
#   dist\HeyLoganAI-Setup-<version>-win-x64.exe
#   dist\HeyLoganAI-Portable-<version>-win-x64.zip
#   _test\win-installer\SHA256SUMS-windows.txt
#
# Usage:
#   pwsh -File windows\installer\build-all.ps1
#   pwsh -File windows\installer\build-all.ps1 -Version 1.0.0 [-Makensis <path>]

[CmdletBinding()]
param(
    [string]$Version = '1.0.0',
    [string]$Makensis = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\build-common.ps1')

$root = Get-ReleaseRoot
$dist = Join-Path $root 'dist'

$setup = & (Join-Path $PSScriptRoot 'build-setup.ps1') -Version $Version -Makensis $Makensis
$portable = & (Join-Path $PSScriptRoot 'build-portable.ps1') -Version $Version

$lines = @(
    "$($setup.Sha256)  $($setup.Name)",
    "$($portable.Sha256)  $($portable.Name)"
)
$sumsPath = Join-Path $root '_test\win-installer\SHA256SUMS-windows.txt'
Set-Content -LiteralPath $sumsPath -Value ($lines -join "`r`n") -Encoding ascii

Write-Host ''
Write-Host '=== Build complete ===' -ForegroundColor Green
Write-Host "  $($setup.Path)  ($(Format-Bytes $setup.Size))"
Write-Host "  $($portable.Path)  ($(Format-Bytes $portable.Size))"
Write-Host "  $sumsPath"
