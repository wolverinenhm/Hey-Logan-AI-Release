# Build dist\HeyLoganAI-Setup-<version>-win-x64.exe with NSIS.
#
# Usage (from anywhere):
#   powershell -NoProfile -ExecutionPolicy Bypass -File windows\installer\build-setup.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File windows\installer\build-setup.ps1 -Version 1.0.0
#
# Optional parameters:
#   -Version <x.y.z>       Product version baked into the installer (default 1.1.0)
#   -PayloadDir <path>     Payload to package (default windows\payload\HeyLoganAI)
#   -OutDir <path>         Output folder (default <release root>\dist)
#   -Makensis <path>      makensis.exe to use (default: bundled _toolchain\nsis, then PATH)
#   -KeepStage             Keep windows\installer\.build\setup-stage for inspection
#   -SkipPayloadValidation Only for debugging; normally leave this off.

[CmdletBinding()]
param(
    [string]$Version = '1.1.0',
    [string]$PayloadDir = '',
    [string]$OutDir = '',
    [string]$Makensis = '',
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
Write-Host '=== Hey Logan AI - build Windows installer (NSIS) ===' -ForegroundColor Cyan
Write-Host "  release root : $root"
Write-Host "  payload      : $PayloadDir"
Write-Host "  output dir   : $OutDir"
Write-Host "  version      : $Version"

if (-not $SkipPayloadValidation) {
    $null = Assert-Payload -PayloadDir $PayloadDir -AllowAppData
}

# --- stage a clean copy: never package app\data (user settings/token/certs) --
$stageParent = Join-Path $PSScriptRoot '.build\setup-stage'
$stage = Join-Path $stageParent 'HeyLoganAI'
Write-Host ''
Write-Host "  staging payload under $stageParent" -ForegroundColor DarkGray
Copy-PayloadTree -Source $PayloadDir -Destination $stage

$payload = Assert-Payload -PayloadDir $stage
Write-Host "  payload files: $($payload.FileCount) ($(Format-Bytes $payload.TotalBytes)), app\data excluded"
Write-Host "  node runtime : $(Format-Bytes $payload.NodeSizeBytes), version $($payload.NodeVersion)"
Write-Host "  app version  : $($payload.AppPackageVersion)"

$makensisExe = Get-MakensisPath -ReleaseRoot $root -Makensis $Makensis
$nsi = Join-Path $PSScriptRoot 'installer.nsi'
$icon = Join-Path $stage 'heylogan.ico'
$outFile = Join-Path $OutDir "HeyLoganAI-Setup-$Version-win-x64.exe"

if (Test-Path -LiteralPath $outFile) { Remove-Item -LiteralPath $outFile -Force }

# Keep the compiler's temp files inside the build folder: NSIS with /SOLID
# LZMA memory-maps a large scratch file, and some locked-down agent sandboxes
# deny a workspace binary the right to write to C:\Users\...\Temp.
$buildTmp = Join-Path $PSScriptRoot '.build\tmp'
$null = New-Item -ItemType Directory -Path $buildTmp -Force
$savedTemp = $env:TEMP
$savedTmp = $env:TMP
$env:TEMP = $buildTmp
$env:TMP = $buildTmp

$arguments = @(
    '/V2',
    (Format-NsisDefine 'PRODUCT_VERSION' $Version),
    (Format-NsisDefine 'PAYLOAD_DIR' $stage),
    (Format-NsisDefine 'OUTFILE' $outFile),
    (Format-NsisDefine 'ICON_FILE' $icon),
    $nsi
)

Write-Host ''
Write-Host "  makensis     : $makensisExe"
Write-Host "  running: $makensisExe /V2 ... installer.nsi" -ForegroundColor DarkGray
try {
    & $makensisExe @arguments
    $exitCode = $LASTEXITCODE
}
finally {
    $env:TEMP = $savedTemp
    $env:TMP = $savedTmp
}
if ($exitCode -ne 0) {
    throw "makensis failed with exit code $exitCode (see the output above)."
}
if (-not (Test-Path -LiteralPath $outFile -PathType Leaf)) {
    throw "makensis reported success but did not create $outFile"
}

$artifact = Get-Item -LiteralPath $outFile
if ($artifact.Length -lt 20MB) {
    throw "The installer is unexpectedly small ($(Format-Bytes $artifact.Length)); the payload was probably not embedded."
}

$info = $artifact.VersionInfo
Write-Host ''
Write-Host '  version info embedded in Setup.exe:'
Write-Host "    ProductName     : $($info.ProductName)"
Write-Host "    FileDescription : $($info.FileDescription)"
Write-Host "    CompanyName     : $($info.CompanyName)"
Write-Host "    FileVersion     : $($info.FileVersion)"
Write-Host "    ProductVersion  : $($info.ProductVersion)"
Write-Host "    LegalCopyright  : $($info.LegalCopyright)"

$summary = Write-ArtifactInfo -Path $outFile -Label 'Setup.exe built'
Write-Host ''
Write-Host '  Next: copy the exe outside this workspace before running it (the' -ForegroundColor DarkGray
Write-Host '  agent file sandbox can block/hang GUI executables started from the' -ForegroundColor DarkGray
Write-Host '  workspace tree).' -ForegroundColor DarkGray

# --- clean up staging -------------------------------------------------------
if (-not $KeepStage) {
    Remove-Item -LiteralPath $stageParent -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $buildTmp -Recurse -Force -ErrorAction SilentlyContinue
}

return $summary
