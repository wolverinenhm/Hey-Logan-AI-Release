# Add a Windows Firewall rule so your phone can reach the bridge over Wi-Fi.
# Needs administrator rights; the script re-launches itself elevated if needed.
$ErrorActionPreference = 'SilentlyContinue'
$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root 'runtime\node.exe'
$ruleName = 'Hey Logan AI'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host '  Administrator rights are required for this step.'
    Write-Host '  Approve the Windows prompt to continue...'
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"')
    ) | Out-Null
    exit 0
}

if (-not (Test-Path $exe)) {
    Write-Host ("  Could not find the Node.js runtime at: " + $exe)
    exit 1
}

netsh advfirewall firewall delete rule name="$ruleName" | Out-Null
netsh advfirewall firewall add rule name="$ruleName" dir=in action=allow program="$exe" protocol=TCP profile=private,domain enable=yes | Out-Null

Write-Host ''
Write-Host '  Windows Firewall now allows Hey Logan AI on private networks.'
Write-Host '  If your phone still cannot connect, make sure the PC and the phone are'
Write-Host '  on the same Wi-Fi network and that it is a "Private" network in Windows.'
Write-Host ''
Read-Host '  Press Enter to close this window'
