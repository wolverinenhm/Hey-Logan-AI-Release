# ===========================================================================
#  Independent QA - clean-room Windows end-to-end verification for v1.1.0
#  Hey Logan AI: hands-free "Hey Logan" launcher + start-at-login + installer
#  upgrade-in-place + Android-relevant server page.
#
#  Run from OUTSIDE the release workspace (Windows PowerShell 5.1):
#    Copy-Item _test\verify\run-v11-windows-e2e.ps1 C:\Temp\ -Force
#    powershell -NoProfile -ExecutionPolicy Bypass -File C:\Temp\run-v11-windows-e2e.ps1 `
#        -ExpectedSetupSha <sha> -ExpectedPortableSha <sha>
#
#  IMPORTANT: the machine already has the USER's real v1.0.0 installation at
#  D:\HeyLoganAI running on ports 8787/8443. This script never touches it:
#  - all test installs are under C:\Temp\hl-qa-11\e2e and use /D=;
#  - the test servers listen on 8790/8445 (8792/8447 for the portable test);
#  - the user's HKCU Add/Remove Programs key, HKCU app key, Run value,
#    Start Menu group and Desktop shortcut are backed up before the tests and
#    restored exactly afterwards.
# ===========================================================================
[CmdletBinding()]
param(
    [string]$Root = 'C:\Users\s2121270\Downloads\Hey-Logan-AI-Release',
    [string]$Work = 'C:\Temp\hl-qa-11\e2e',
    [string]$OutDir = 'C:\Users\s2121270\Downloads\Hey-Logan-AI-Release\_test\verify',
    [string]$ExpectedSetupSha = '',
    [string]$ExpectedPortableSha = '',
    [string]$ExpectedApkSha = 'CCB8FB6E2FF57D856621A0E1ACD41E90A1AF4323A364B19CBDFD31047DBE0173',
    [string]$ExpectedProjectZipSha = 'D3B945956F6041F1D3920E6F30E7AF01FE937150508C3B7D3CF4CFD1EFCE9ED9',
    [string]$NodeExe = 'C:\Users\s2121270\AppData\Local\pi-node\current\node.exe'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$script:Results = New-Object System.Collections.Generic.List[object]
$script:PassCount = 0
$script:FailCount = 0
$script:SkipCount = 0
$script:Log = New-Object System.Collections.Generic.List[string]
$script:Work = $Work
$script:Root = $Root
$script:OutDir = $OutDir
$script:TestStart = Get-Date

$HTTP_PORT = 8790
$HTTPS_PORT = 8445
$P_HTTP_PORT = 8792
$P_HTTPS_PORT = 8447
$QA_TOKEN = 'QA-V11-TOKEN-0001'

$inst = Join-Path $Work 'inst'
$inst2 = Join-Path $Work 'inst-noauto'
$old10 = Join-Path $Work 'old-v10'
$portable = Join-Path $Work 'portable'

function A { param([string]$Text) $line = ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Text); Write-Host $line; $script:Log.Add($line) }
function Check {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()]$Actual,
        [Parameter(Mandatory)][scriptblock]$Condition,
        [string]$Detail = ''
    )
    $ok = $false
    $err = ''
    try { $ok = [bool](& $Condition $Actual) } catch { $ok = $false; $err = $_.Exception.Message }
    $status = 'FAIL'
    if ($ok) { $status = 'PASS'; $script:PassCount += 1 } else { $script:FailCount += 1 }
    $shown = ''
    if (-not [string]::IsNullOrEmpty($Detail)) { $shown = $Detail }
    elseif ($null -ne $Actual -and "$Actual".Length -le 200) { $shown = "$Actual" }
    $line = ('{0,-4} {1}' -f $status, $Name)
    if ($shown) { $line += ('  [' + ($shown -replace '[\r\n]+', ' ') + ']') }
    if ($err) { $line += ('  <error: ' + $err + '>') }
    A $line
    $script:Results.Add([pscustomobject]@{ Status = $status; Name = $Name; Detail = $shown })
    return $ok
}
function Skip { param([string]$Name, [string]$Why) $script:SkipCount += 1; A ('SKIP ' + $Name + '  [' + $Why + ']'); $script:Results.Add([pscustomobject]@{ Status = 'SKIP'; Name = $Name; Detail = $Why }) }

function Get-Health { param([int]$Port = $HTTP_PORT) try { return Invoke-RestMethod -Uri ("http://127.0.0.1:" + $Port + "/api/health") -TimeoutSec 3 -UseBasicParsing } catch { return $null } }
function Wait-Health {
    param([int]$Port = $HTTP_PORT, [int]$TimeoutSec = 75)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $h = Get-Health -Port $Port
        if ($null -ne $h -and $h.ok -eq $true) { return $h }
        Start-Sleep -Milliseconds 400
    }
    return $null
}
function Wait-HealthDown {
    param([int]$Port = $HTTP_PORT, [int]$TimeoutSec = 25)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ($null -eq (Get-Health -Port $Port)) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}
function Get-NodeProcsFor { param([string]$Dir) $out = @(); Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue | ForEach-Object { if ($_.CommandLine -and $_.CommandLine.IndexOf($Dir, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $out += $_ } }; return $out }
function Get-Listeners { param([int[]]$Ports) return @(Get-NetTCPConnection -LocalPort $Ports -State Listen -ErrorAction SilentlyContinue) }
function Read-Lnk { param([string]$Path) $sh = New-Object -ComObject WScript.Shell; $sc = $sh.CreateShortcut($Path); return [pscustomobject]@{ TargetPath = $sc.TargetPath; Arguments = $sc.Arguments; IconLocation = $sc.IconLocation; Description = $sc.Description } }
function Get-RegVal { param([string]$Path, [string]$Name) try { return (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { return $null } }
function Set-RegVal { param([string]$Path, [string]$Name, [string]$Value) if ($null -eq $Value) { Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction SilentlyContinue } else { if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }; New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType String -Force | Out-Null } }

function New-CmdWrapper {
    param([string]$Name, [string[]]$Lines)
    $path = Join-Path $script:Work ('wrap-' + $Name + '.cmd')
    (@('@echo off', 'chcp 65001 >NUL') + $Lines) | Set-Content -Path $path -Encoding ASCII
    return $path
}
function Run-CmdCapture {
    param([string]$CommandLine, [string]$OutFile, [int]$TimeoutSec = 120)
    $wrapper = New-CmdWrapper -Name ([System.IO.Path]::GetFileNameWithoutExtension($OutFile)) -Lines @(('call "' + $CommandLine + '" < NUL > "' + $OutFile + '" 2>&1'))
    $p = Start-Process -FilePath $env:COMSPEC -ArgumentList @('/d', '/c', ('"' + $wrapper + '"')) -PassThru -WindowStyle Hidden
    if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }; return -1 }
    return $p.ExitCode
}
function Get-BrowserProcsForProfile {
    param([string]$ProfilePath)
    $out = @()
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -in @('msedge.exe', 'chrome.exe', 'identity_helper.exe') } | ForEach-Object {
        $cmd = "$($_.CommandLine)"
        if ($cmd -and $cmd.IndexOf($ProfilePath, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $out += $_ }
    }
    return $out
}
function Stop-BrowserForProfile {
    param([string]$ProfilePath)
    $procs = @(Get-BrowserProcsForProfile -ProfilePath $ProfilePath)
    foreach ($p in $procs) { try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
    Start-Sleep -Milliseconds 1200
    return $procs.Count
}
function Http-GetText { param([string]$Url) try { return (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 15).Content } catch { return $null } }
function Api-GetJson { param([int]$Port, [string]$Path, [string]$Token) try { $h = @{ 'X-Bridge-Token' = $Token }; return Invoke-RestMethod -Uri ("http://127.0.0.1:" + $Port + $Path) -Headers $h -TimeoutSec 20 -UseBasicParsing } catch { return $null } }
function Api-PostCommand {
    param([int]$Port, [string]$Token, [string]$Text, [int]$TimeoutSec = 120)
    $body = @{ text = $Text; sync = $true; source = 'pc'; clientId = 'qa-v11' } | ConvertTo-Json -Compress
    try { return Invoke-RestMethod -Uri ("http://127.0.0.1:" + $Port + '/api/command') -Method Post -Headers @{ 'X-Bridge-Token' = $Token } -ContentType 'application/json' -Body $body -TimeoutSec $TimeoutSec -UseBasicParsing } catch { return $null }
}

function Capture-Window {
    param([string]$TitlePattern, [string]$OutPng, [int]$TimeoutSec = 30, [int[]]$WindowPids = @())
    if (-not ('WinCap' -as [type])) {
        Add-Type -AssemblyName System.Drawing
        Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices; using System.Text;
public class WinCap {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
  public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $script:capTitlePattern = $TitlePattern
    $script:capPids = @($WindowPids)
    while ((Get-Date) -lt $deadline) {
        $script:captureCandidates = New-Object System.Collections.Generic.List[object]
        $cb = [WinCap+EnumWindowsProc]{
            param($h, $l)
            $sb = New-Object System.Text.StringBuilder 512
            [void][WinCap]::GetWindowText($h, $sb, 512)
            $t = $sb.ToString()
            if ($t -and $t -match $script:capTitlePattern -and [WinCap]::IsWindowVisible($h)) {
                $procId = [uint32]0
                [void][WinCap]::GetWindowThreadProcessId($h, [ref]$procId)
                if ($script:capPids.Count -eq 0 -or ($script:capPids -contains [int]$procId)) {
                    $script:captureCandidates.Add([pscustomobject]@{ Hwnd = $h; Title = $t; Pid = [int]$procId })
                }
            }
            return $true
        }
        [void][WinCap]::EnumWindows($cb, [IntPtr]::Zero)
        $target = $script:captureCandidates | Select-Object -First 1
        if ($target) {
            $rect = New-Object WinCap+RECT
            [void][WinCap]::GetWindowRect($target.Hwnd, [ref]$rect)
            $w = $rect.Right - $rect.Left
            $h = $rect.Bottom - $rect.Top
            if ($w -gt 100 -and $h -gt 100) {
                $bmp = New-Object System.Drawing.Bitmap $w, $h
                $g = [System.Drawing.Graphics]::FromImage($bmp)
                $hdc = $g.GetHdc()
                $ok = [WinCap]::PrintWindow($target.Hwnd, $hdc, 2)
                $g.ReleaseHdc($hdc)
                $g.Dispose()
                $bmp.Save($OutPng, [System.Drawing.Imaging.ImageFormat]::Png)
                $bmp.Dispose()
                $bytes = (Get-Item -LiteralPath $OutPng -ErrorAction SilentlyContinue).Length
                if ($bytes -ge 15000) {
                    return [pscustomobject]@{ Captured = $ok; Width = $w; Height = $h; Title = $target.Title; Path = $OutPng; Bytes = $bytes }
                }
                # The window existed but had not painted yet (blank capture): retry.
                Remove-Item -LiteralPath $OutPng -Force -ErrorAction SilentlyContinue
            }
        }
        Start-Sleep -Milliseconds 700
    }
    return $null
}

function Assert-FileHash { param([string]$Path, [string]$Expected) if (-not (Test-Path $Path)) { return $false }; return ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $Expected) }

# --- backup / restore of the USER's real v1.0.0 install state --------------
$userState = [ordered]@{}

function Backup-UserState {
    $backupDir = Join-Path $script:Work 'backup'
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    $arpKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\HeyLoganAI'
    $appKey = 'HKCU:\Software\HeyLoganAI'
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if (Test-Path $arpKey) { reg export 'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\HeyLoganAI' (Join-Path $backupDir 'arp.reg') /y 2>&1 | Out-Null }
    if (Test-Path $appKey) { reg export 'HKCU\Software\HeyLoganAI' (Join-Path $backupDir 'appkey.reg') /y 2>&1 | Out-Null }
    $script:userState = [ordered]@{
        arpExisted = (Test-Path $arpKey)
        arpDisplayVersion = (Get-RegVal $arpKey 'DisplayVersion')
        arpInstallLocation = (Get-RegVal $arpKey 'InstallLocation')
        appKeyExisted = (Test-Path $appKey)
        appKeyInstallDir = (Get-RegVal $appKey 'InstallDir')
        runValue = (Get-RegVal $runKey 'HeyLoganAI')
        smGroupPath = (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Hey Logan AI')
        smExisted = (Test-Path (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Hey Logan AI'))
        smItems = @(Get-ChildItem (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Hey Logan AI') -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        desktopLnk = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Hey Logan AI.lnk')
        desktopExisted = (Test-Path (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Hey Logan AI.lnk'))
        serverPid = 0
        serverPorts = ''
    }
    if ($script:userState.smExisted) {
        $dest = Join-Path $backupDir 'startmenu'
        if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
        Copy-Item $script:userState.smGroupPath $dest -Recurse -Force
    }
    if ($script:userState.desktopExisted) { Copy-Item $script:userState.desktopLnk (Join-Path $backupDir 'desktop-HeyLoganAI.lnk') -Force }
    $listeners = @(Get-NetTCPConnection -LocalPort 8787, 8443 -State Listen -ErrorAction SilentlyContinue)
    if ($listeners.Count -gt 0) { $script:userState.serverPid = $listeners[0].OwningProcess; $script:userState.serverPorts = (($listeners | ForEach-Object { $_.LocalPort }) -join ',') }
    A ('user state backed up: ARP=' + $script:userState.arpDisplayVersion + ' @ ' + $script:userState.arpInstallLocation + ' / Run=' + $script:userState.runValue + ' / SM items=' + $script:userState.smItems.Count + ' / desktop=' + $script:userState.desktopExisted + ' / server pid=' + $script:userState.serverPid)
}

function Import-RegFile {
    # reg.exe writes "The operation completed successfully." to a stream that
    # PowerShell 5.1 turns into a terminating error when redirected (2>&1) with
    # $ErrorActionPreference=Stop. Run it as a process and use the exit code.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return -1 }
    $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\reg.exe') -ArgumentList @('import', ('"' + $Path + '"')) -PassThru -Wait -WindowStyle Hidden
    return $p.ExitCode
}

function Restore-UserState {
    if (-not $script:userState -or -not $script:userState.Contains('arpExisted')) { A 'restore skipped: no backup was taken'; return }
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $backupDir = Join-Path $script:Work 'backup'
        $arpKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\HeyLoganAI'
        $appKey = 'HKCU:\Software\HeyLoganAI'
        $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        # remove anything the tests wrote, then re-import the user's real entries
        if (Test-Path $arpKey) { Remove-Item -Path $arpKey -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path $appKey) { Remove-Item -Path $appKey -Recurse -Force -ErrorAction SilentlyContinue }
        if ($script:userState.arpExisted) {
            $rc = Import-RegFile -Path (Join-Path $backupDir 'arp.reg')
            if ($rc -ne 0) { A ('restore warning: reg import arp.reg exit=' + $rc) }
        }
        if ($script:userState.appKeyExisted) {
            $rc = Import-RegFile -Path (Join-Path $backupDir 'appkey.reg')
            if ($rc -ne 0) { A ('restore warning: reg import appkey.reg exit=' + $rc) }
        }
        Set-RegVal $runKey 'HeyLoganAI' $script:userState.runValue
        $sm = $script:userState.smGroupPath
        if (Test-Path $sm) { Remove-Item -LiteralPath $sm -Recurse -Force -ErrorAction SilentlyContinue }
        if ($script:userState.smExisted -and (Test-Path (Join-Path $backupDir 'startmenu'))) { Copy-Item (Join-Path $backupDir 'startmenu') $sm -Recurse -Force -ErrorAction SilentlyContinue }
        $desk = $script:userState.desktopLnk
        if (Test-Path $desk) { Remove-Item -LiteralPath $desk -Force -ErrorAction SilentlyContinue }
        if ($script:userState.desktopExisted -and (Test-Path (Join-Path $backupDir 'desktop-HeyLoganAI.lnk'))) { Copy-Item (Join-Path $backupDir 'desktop-HeyLoganAI.lnk') $desk -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 500
    } catch {
        A ('restore warning: ' + $_.Exception.Message)
    } finally {
        $ErrorActionPreference = $savedEap
    }
}

function Verify-UserState {
    if (-not $script:userState -or -not $script:userState.Contains('arpExisted')) { return [pscustomobject]@{ Ok = $false; Detail = 'no backup was taken' } }
    $ok = $true
    $detail = @()
    $arpKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\HeyLoganAI'
    $appKey = 'HKCU:\Software\HeyLoganAI'
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $v = Get-RegVal $arpKey 'DisplayVersion'
    $l = Get-RegVal $arpKey 'InstallLocation'
    if ($v -ne $script:userState.arpDisplayVersion) { $ok = $false; $detail += ('ARP version=' + $v) }
    if ($l -ne $script:userState.arpInstallLocation) { $ok = $false; $detail += ('ARP location=' + $l) }
    if ((Get-RegVal $runKey 'HeyLoganAI') -ne $script:userState.runValue) { $ok = $false; $detail += ('Run=' + (Get-RegVal $runKey 'HeyLoganAI')) }
    if ((Test-Path $appKey) -ne $script:userState.appKeyExisted) { $ok = $false; $detail += 'appkey presence' }
    $smItems = @(Get-ChildItem $script:userState.smGroupPath -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object)
    if ((($smItems -join '|') -ne (($script:userState.smItems | Sort-Object) -join '|'))) { $ok = $false; $detail += ('SM=' + ($smItems -join ',')) }
    if ((Test-Path $script:userState.desktopLnk) -ne $script:userState.desktopExisted) { $ok = $false; $detail += 'desktop shortcut presence' }
    return [pscustomobject]@{ Ok = $ok; Detail = ($detail -join '; ') }
}

# ===========================================================================
#  Pre-flight
# ===========================================================================
A '====================================================================='
A ' Hey Logan AI v1.1.0 - independent clean-room Windows E2E (qa-reviewer)'
A '====================================================================='
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
if (-not (Test-Path $NodeExe)) { throw ('node.exe not found: ' + $NodeExe) }

$setupSrc = Join-Path $Root 'dist\HeyLoganAI-Setup-1.1.0-win-x64.exe'
$portableSrc = Join-Path $Root 'dist\HeyLoganAI-Portable-1.1.0-win-x64.zip'
$apkSrc = Join-Path $Root 'dist\HeyLoganAI-android-1.1.0.apk'
$projectSrc = Join-Path $Root 'dist\HeyLoganAI-Android-Project-1.1.0.zip'
$sumsSrc = Join-Path $Root 'dist\SHA256SUMS.txt'
$payloadSrc = Join-Path $Root 'windows\payload\HeyLoganAI'
foreach ($p in @($setupSrc, $portableSrc, $apkSrc, $projectSrc, $sumsSrc, $payloadSrc)) { if (-not (Test-Path $p)) { throw ('Missing required input: ' + $p) } }

$setupSha = (Get-FileHash -LiteralPath $setupSrc -Algorithm SHA256).Hash
$portableSha = (Get-FileHash -LiteralPath $portableSrc -Algorithm SHA256).Hash
$apkSha = (Get-FileHash -LiteralPath $apkSrc -Algorithm SHA256).Hash
$projectSha = (Get-FileHash -LiteralPath $projectSrc -Algorithm SHA256).Hash
$setupSize = (Get-Item $setupSrc).Length
$portableSize = (Get-Item $portableSrc).Length
A ('Setup.exe  : ' + $setupSize + ' bytes  SHA256 ' + $setupSha)
A ('Portable   : ' + $portableSize + ' bytes  SHA256 ' + $portableSha)
A ('APK        : ' + (Get-Item $apkSrc).Length + ' bytes  SHA256 ' + $apkSha)
A ('Project ZIP: ' + (Get-Item $projectSrc).Length + ' bytes  SHA256 ' + $projectSha)
if ($ExpectedSetupSha) { A ('expected setup sha: ' + $ExpectedSetupSha) }
if ($ExpectedPortableSha) { A ('expected portable sha: ' + $ExpectedPortableSha) }

# fresh work dir (safe fixed path)
if (Test-Path $script:Work) {
    # clean anything a previous aborted run left, but only our own installed trees
    foreach ($d in @($inst, $inst2, $old10, $portable)) { if (Test-Path $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } }
    if (-not (Test-Path (Join-Path $script:Work 'backup'))) { Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue }
}
New-Item -ItemType Directory -Force -Path $script:Work | Out-Null
$setupDir = Join-Path $script:Work 'setup'
New-Item -ItemType Directory -Force -Path $setupDir | Out-Null
$setupExe = Join-Path $setupDir 'HeyLoganAI-Setup-1.1.0-win-x64.exe'
Copy-Item -LiteralPath $setupSrc -Destination $setupExe -Force
$setupCopySha = (Get-FileHash -LiteralPath $setupExe -Algorithm SHA256).Hash

$phase = 'preflight'
try {
    # ----------------------------------------------------------------------
    A ''
    A '=== PHASE V11-0: pre-flight (hashes, checksums, machine, backup) ==='
    Check 'V11-0.1 copied Setup.exe SHA256 == dist SHA256' ($setupCopySha -eq $setupSha) { param($x) $x } $setupCopySha
    if ($ExpectedSetupSha) { Check 'V11-0.2 Setup.exe SHA256 == frozen hash' ($setupSha -eq $ExpectedSetupSha) { param($x) $x } $setupSha }
    else { Skip 'V11-0.2 Setup.exe SHA256 == frozen hash' 'no expected hash supplied' }
    if ($ExpectedPortableSha) { Check 'V11-0.3 Portable ZIP SHA256 == frozen hash' ($portableSha -eq $ExpectedPortableSha) { param($x) $x } $portableSha }
    else { Skip 'V11-0.3 Portable ZIP SHA256 == frozen hash' 'no expected hash supplied' }
    Check 'V11-0.4 APK SHA256 == Lead-supplied hash' ($apkSha -eq $ExpectedApkSha) { param($x) $x } $apkSha
    Check 'V11-0.5 project ZIP SHA256 == Lead-supplied hash' ($projectSha -eq $ExpectedProjectZipSha) { param($x) $x } $projectSha
    $sums = Get-Content -LiteralPath $sumsSrc -Raw
    $sumsOk = $true
    foreach ($pair in @(@($setupSha, 'HeyLoganAI-Setup-1.1.0-win-x64.exe'), @($portableSha, 'HeyLoganAI-Portable-1.1.0-win-x64.zip'), @($apkSha, 'HeyLoganAI-android-1.1.0.apk'), @($projectSha, 'HeyLoganAI-Android-Project-1.1.0.zip'))) {
        if ($sums.IndexOf($pair[0], [StringComparison]::OrdinalIgnoreCase) -lt 0) { $sumsOk = $false }
        if ($sums.IndexOf($pair[1], [StringComparison]::OrdinalIgnoreCase) -lt 0) { $sumsOk = $false }
    }
    Check 'V11-0.6 dist\SHA256SUMS.txt lists all four frozen artifacts with matching hashes' $sumsOk { param($x) $x }
    $readme = Get-Content -LiteralPath (Join-Path $Root 'README.md') -Raw
    $readmeOk = $readme.IndexOf($setupSha, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and $readme.IndexOf($portableSha, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and $readme.IndexOf($apkSha, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and $readme.IndexOf($projectSha, [StringComparison]::OrdinalIgnoreCase) -ge 0
    Check 'V11-0.7 README.md checksum table contains the four frozen hashes' $readmeOk { param($x) $x }
    $preAlt = @(Get-Listeners -Ports @($HTTP_PORT, $HTTPS_PORT, $P_HTTP_PORT, $P_HTTPS_PORT))
    Check 'V11-0.8 test ports 8790/8445/8792/8447 are free' ($preAlt.Count -eq 0) { param($x) $x } (($preAlt | ForEach-Object { $_.LocalPort }) -join ',')
    Check 'V11-0.9 no test install dir left over' ((-not (Test-Path $inst)) -and (-not (Test-Path $inst2)) -and (-not (Test-Path $old10))) { param($x) $x }

    # snapshot + backup the user's real installation
    $preArp = Get-RegVal 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\HeyLoganAI' 'InstallLocation'
    $preRun = Get-RegVal 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' 'HeyLoganAI'
    $preSm = @(Get-ChildItem (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Hey Logan AI') -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    A ('pre: user ARP InstallLocation=' + $preArp + ' / Run=' + $preRun + ' / SM=' + ($preSm -join ',') )
    Backup-UserState
    Check 'V11-0.10 user''s real v1.0.0 install backed up (ARP + Run + shortcuts + server pid)' ($script:userState.arpExisted -and $script:userState.runValue) { param($x) $x } ('server pid=' + $script:userState.serverPid + ' ports=' + $script:userState.serverPorts)
    Check 'V11-0.11 user''s server still running on 8787/8443 (not disturbed)' ((Get-Listeners -Ports @(8787, 8443)).Count -ge 1) { param($x) $x }

    # ======================================================================
    A ''
    A '=== PHASE V11-A: silent install to a scratch dir (/S /D=) ==='
    $phase = 'install'
    $payloadCount = @(Get-ChildItem -LiteralPath $payloadSrc -Recurse -File -Force).Count
    $t0 = Get-Date
    $p = Start-Process -FilePath $setupExe -ArgumentList @('/S', ('/D=' + $inst)) -PassThru -Wait
    $installSecs = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    Check 'V11-A1 /S /D= installer exit code 0' ($p.ExitCode -eq 0) { param($x) $x } ('exit=' + $p.ExitCode + ' in ' + $installSecs + 's')
    Check 'V11-A2 install dir created' (Test-Path -LiteralPath $inst) { param($x) $x } $inst
    $instFiles = @(Get-ChildItem -LiteralPath $inst -Recurse -File -Force -ErrorAction SilentlyContinue)
    Check 'V11-A3 installed file count == payload + Uninstall.exe' ($instFiles.Count -eq ($payloadCount + 1)) { param($x) $x } ('count=' + $instFiles.Count + ' expected=' + ($payloadCount + 1))
    Check 'V11-A4 Uninstall.exe present' (Test-Path -LiteralPath (Join-Path $inst 'Uninstall.exe')) { param($x) $x }
    Check 'V11-A5 no app\data before first run' (-not (Test-Path -LiteralPath (Join-Path $inst 'app\data'))) { param($x) $x }
    Check 'V11-A6 no browser-profile before first run' (-not (Test-Path -LiteralPath (Join-Path $inst 'browser-profile'))) { param($x) $x }
    $payloadFiles = @(Get-ChildItem -LiteralPath $payloadSrc -Recurse -File -Force)
    $payloadRel = @{}; foreach ($f in $payloadFiles) { $payloadRel[$f.FullName.Substring($payloadSrc.Length + 1)] = $f }
    $missing = @(); $mismatch = @()
    foreach ($rel in $payloadRel.Keys) { $target = Join-Path $inst $rel; if (-not (Test-Path -LiteralPath $target)) { $missing += $rel; continue }; if ((Get-FileHash -LiteralPath $payloadRel[$rel].FullName -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash) { $mismatch += $rel } }
    Check 'V11-A7 every payload file installed byte-identically' (($missing.Count -eq 0) -and ($mismatch.Count -eq 0)) { param($x) $x } ('missing=' + $missing.Count + ' mismatch=' + $mismatch.Count)
    $instRel = @{}; foreach ($f in $instFiles) { $instRel[$f.FullName.Substring($inst.Length + 1)] = 1 }
    $extra = @($instRel.Keys | Where-Object { -not $payloadRel.ContainsKey($_) -and $_ -ne 'Uninstall.exe' })
    Check 'V11-A8 no unexpected files in install dir' ($extra.Count -eq 0) { param($x) $x } ($extra -join ', ')

    $smGroup = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Hey Logan AI'
    $deskLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Hey Logan AI.lnk'
    $smFiles = @(Get-ChildItem $smGroup -Filter *.lnk -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object)
    Check 'V11-A9 Start Menu group created' (Test-Path $smGroup) { param($x) $x }
    Check 'V11-A10 Start Menu has exactly 8 shortcuts' ($smFiles.Count -eq 8) { param($x) $x } ($smFiles -join ' | ')
    foreach ($name in @('Hey Logan AI.lnk', 'Start Console.lnk', 'Pairing.lnk', 'Stop Server.lnk', 'Allow through Firewall.lnk', 'Start at Login On.lnk', 'Start at Login Off.lnk', 'Uninstall.lnk')) {
        Check ('V11-A11 shortcut present: ' + $name) ($smFiles -contains $name) { param($x) $x }
    }
    Check 'V11-A12 desktop shortcut created' (Test-Path $deskLnk) { param($x) $x }
    $mainLnk = Read-Lnk (Join-Path $smGroup 'Hey Logan AI.lnk')
    $expectWscript = Join-Path $env:WINDIR 'System32\wscript.exe'
    Check 'V11-A13 main shortcut target is wscript.exe' ($mainLnk.TargetPath.TrimEnd() -ieq $expectWscript) { param($x) $x } $mainLnk.TargetPath
    Check 'V11-A14 main shortcut arguments point at Launch.vbs' ($mainLnk.Arguments -like ('*' + (Join-Path $inst 'Launch.vbs') + '*')) { param($x) $x } $mainLnk.Arguments
    Check 'V11-A15 main shortcut icon is heylogan.ico' ($mainLnk.IconLocation -like '*heylogan.ico*') { param($x) $x } $mainLnk.IconLocation
    $deskLnkObj = Read-Lnk $deskLnk
    Check 'V11-A16 desktop shortcut target is wscript.exe + Launch.vbs' (($deskLnkObj.TargetPath.TrimEnd() -ieq $expectWscript) -and ($deskLnkObj.Arguments -like ('*' + (Join-Path $inst 'Launch.vbs') + '*'))) { param($x) $x } ($deskLnkObj.TargetPath + ' ' + $deskLnkObj.Arguments)
    $lStartConsole = Read-Lnk (Join-Path $smGroup 'Start Console.lnk'); Check 'V11-A17 Start Console shortcut target' ($lStartConsole.TargetPath -ieq (Join-Path $inst 'Start Console.cmd')) { param($x) $x } $lStartConsole.TargetPath
    $lPair = Read-Lnk (Join-Path $smGroup 'Pairing.lnk'); Check 'V11-A18 Pairing shortcut target' ($lPair.TargetPath -ieq (Join-Path $inst 'Pairing.cmd')) { param($x) $x } $lPair.TargetPath
    $lStop = Read-Lnk (Join-Path $smGroup 'Stop Server.lnk'); Check 'V11-A19 Stop Server shortcut target' ($lStop.TargetPath -ieq (Join-Path $inst 'Stop.cmd')) { param($x) $x } $lStop.TargetPath
    $lLoginOn = Read-Lnk (Join-Path $smGroup 'Start at Login On.lnk'); Check 'V11-A20 Start at Login On shortcut target' ($lLoginOn.TargetPath -ieq (Join-Path $inst 'Start at Login On.cmd')) { param($x) $x } $lLoginOn.TargetPath
    $lLoginOff = Read-Lnk (Join-Path $smGroup 'Start at Login Off.lnk'); Check 'V11-A21 Start at Login Off shortcut target' ($lLoginOff.TargetPath -ieq (Join-Path $inst 'Start at Login Off.cmd')) { param($x) $x } $lLoginOff.TargetPath
    $lUninst = Read-Lnk (Join-Path $smGroup 'Uninstall.lnk'); Check 'V11-A22 Uninstall shortcut target' ($lUninst.TargetPath -ieq (Join-Path $inst 'Uninstall.exe')) { param($x) $x } $lUninst.TargetPath

    $arpKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\HeyLoganAI'
    $arp = Get-ItemProperty $arpKey -ErrorAction SilentlyContinue
    Check 'V11-A23 ARP entry exists' ($null -ne $arp) { param($x) $x }
    Check 'V11-A24 ARP DisplayName' ($arp.DisplayName -eq 'Hey Logan AI') { param($x) $x } $arp.DisplayName
    Check 'V11-A25 ARP DisplayVersion 1.1.0' ($arp.DisplayVersion -eq '1.1.0') { param($x) $x } $arp.DisplayVersion
    Check 'V11-A26 ARP Publisher' ($arp.Publisher -eq 'Hey Logan AI') { param($x) $x } $arp.Publisher
    Check 'V11-A27 ARP InstallLocation == scratch dir' ($arp.InstallLocation -ieq $inst) { param($x) $x } $arp.InstallLocation
    Check 'V11-A28 ARP UninstallString' ($arp.UninstallString -like ('*' + (Join-Path $inst 'Uninstall.exe') + '*')) { param($x) $x } $arp.UninstallString
    Check 'V11-A29 ARP QuietUninstallString /S' ($arp.QuietUninstallString -like '*Uninstall.exe* /S*') { param($x) $x } $arp.QuietUninstallString
    Check 'V11-A30 ARP EstimatedSize > 0' ($arp.EstimatedSize -gt 0) { param($x) $x } ('KB=' + $arp.EstimatedSize)
    Check 'V11-A31 ARP NoModify/NoRepair = 1' (($arp.NoModify -eq 1) -and ($arp.NoRepair -eq 1)) { param($x) $x }
    Check 'V11-A32 ARP DisplayIcon heylogan.ico' ($arp.DisplayIcon -like '*heylogan.ico*') { param($x) $x } $arp.DisplayIcon
    $appKey = Get-ItemProperty 'HKCU:\Software\HeyLoganAI' -ErrorAction SilentlyContinue
    Check 'V11-A33 app key InstallDir' (($null -ne $appKey) -and ($appKey.InstallDir -ieq $inst)) { param($x) $x } $appKey.InstallDir
    Check 'V11-A34 app key Version 1.1.0' (($null -ne $appKey) -and ($appKey.Version -eq '1.1.0')) { param($x) $x } $appKey.Version
    $runVal = Get-RegVal 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' 'HeyLoganAI'
    Check 'V11-A35 installer wrote the start-at-login Run value' ($null -ne $runVal) { param($x) $x } $runVal
    $runRx = '^"(.+?wscript\.exe)"\s+"(.+?Launch\.vbs)"$'
    $runMatch = [regex]::Match("$runVal", $runRx, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    Check 'V11-A36 Run value = wscript.exe + <install>\Launch.vbs' ($runMatch.Success -and ($runMatch.Groups[2].Value -ieq (Join-Path $inst 'Launch.vbs'))) { param($x) $x } $runVal
    Check 'V11-A37 nothing installed under Program Files' (-not (Test-Path (Join-Path $env:ProgramFiles 'HeyLoganAI'))) { param($x) $x }
    $hk = @(Get-ChildItem 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -eq 'HeyLoganAI' })
    Check 'V11-A38 no HKLM Add/Remove Programs entry' ($hk.Count -eq 0) { param($x) $x }

    # ======================================================================
    A ''
    A '=== PHASE V11-B: launch via the EXACT Run-key command line (alt ports) ==='
    $phase = 'launch'
    $env:HEY_AI_HTTP_PORT = "$HTTP_PORT"
    $env:HEY_AI_HTTPS_PORT = "$HTTPS_PORT"
    $env:HEY_AI_TOKEN = $QA_TOKEN
    $mainTarget = $runMatch.Groups[1].Value
    $mainArgs = '"' + $runMatch.Groups[2].Value + '"'
    A ('Run-key command: ' + $mainTarget + ' ' + $mainArgs)
    $baselineBrowsers = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -in @('msedge.exe', 'chrome.exe') } | ForEach-Object { $_.ProcessId })
    Start-Process -FilePath $mainTarget -ArgumentList $mainArgs | Out-Null
    $health = Wait-Health -Port $HTTP_PORT -TimeoutSec 90
    Check 'V11-B1 Run-key launch -> /api/health on 8790' ($null -ne $health) { param($x) $x }
    if ($health) {
        Check 'V11-B2 health app == Hey Logan AI' ($health.app -eq 'Hey Logan AI') { param($x) $x } $health.app
        Check 'V11-B3 health version == 1.1.0' ($health.version -eq '1.1.0') { param($x) $x } $health.version
    }
    $dataDir = Join-Path $inst 'app\data'
    $cfgPath = Join-Path $dataDir 'config.json'
    Check 'V11-B4 first run created app\data\config.json' (Test-Path $cfgPath) { param($x) $x }
    Check 'V11-B5 first run created cert.pem + key.pem' ((Test-Path (Join-Path $dataDir 'certs\cert.pem')) -and (Test-Path (Join-Path $dataDir 'certs\key.pem'))) { param($x) $x }
    if (Test-Path $cfgPath) {
        $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
        Check 'V11-B6 config token is the test token' ($cfg.security.token -eq $QA_TOKEN) { param($x) $x }
        Check 'V11-B7 test ports persisted in config (8790/8445)' (($cfg.server.httpPort -eq $HTTP_PORT) -and ($cfg.server.httpsPort -eq $HTTPS_PORT)) { param($x) $x } ($cfg.server.httpPort.ToString() + '/' + $cfg.server.httpsPort.ToString())
    }
    $si = Api-GetJson -Port $HTTP_PORT -Path '/api/session-info' -Token $QA_TOKEN
    Check 'V11-B8 /api/session-info with token ok' ($null -ne $si) { param($x) $x }
    if ($si) {
        Check 'V11-B9 session-info app name/version 1.1.0' (($si.app.name -eq 'Hey Logan AI') -and ($si.app.version -eq '1.1.0')) { param($x) $x } ($si.app.name + ' ' + $si.app.version)
        Check 'V11-B10 session-info speech.autoStart == true' ($si.speech.autoStart -eq $true) { param($x) $x } ('autoStart=' + $si.speech.autoStart)
        Check 'V11-B11 session-info wake.ack == Logan here.' ($si.wake.ack -eq 'Logan here.') { param($x) $x } $si.wake.ack
        Check 'V11-B12 session-info wake.phrases contains hey logan' ((($si.wake.phrases) -join '|').ToLower().IndexOf('hey logan') -ge 0) { param($x) $x } (($si.wake.phrases) -join ', ')
        Check 'V11-B13 session-info reports 6 agents' ($si.agents.Count -eq 6) { param($x) $x } ('agents=' + $si.agents.Count)
    }
    $appJs = Http-GetText ("http://127.0.0.1:" + $HTTP_PORT + '/app.js')
    Check 'V11-B14 served app.js contains autoStartListening' ($appJs -and $appJs.IndexOf('autoStartListening') -ge 0) { param($x) $x } ('length=' + $(if ($appJs) { $appJs.Length } else { 0 }))
    $voiceJs = Http-GetText ("http://127.0.0.1:" + $HTTP_PORT + '/voice.js')
    Check 'V11-B15 served voice.js contains defaultWake' ($voiceJs -and $voiceJs.IndexOf('defaultWake') -ge 0) { param($x) $x }
    $swJs = Http-GetText ("http://127.0.0.1:" + $HTTP_PORT + '/sw.js')
    Check 'V11-B16 served sw.js is cache-busted (heyai-bridge-v1.1.0) and caches /native-voice.js' ($swJs -and ($swJs.IndexOf('heyai-bridge-v1.1.0') -ge 0) -and ($swJs.IndexOf('/native-voice.js') -ge 0)) { param($x) $x }
    $indexHtml = Http-GetText ("http://127.0.0.1:" + $HTTP_PORT + '/index.html')
    Check 'V11-B17 served index.html version label is v1.1.0' ($indexHtml -and $indexHtml.IndexOf('id="versionLabel">v1.1.0<') -ge 0) { param($x) $x }

    # routing fixes (exact app code as installed)
    $routerCheck = @'
const path = process.argv[2];
const { parseCommand } = require(path + '/server/router');
const { DEFAULT_WAKE } = require(path + '/server/agents/defs');
const opts = { defaultAgent: 'computer', defaultWake: DEFAULT_WAKE, wakeAck: 'Logan here.' };
const out = {};
out.clientRemainder = parseCommand('ask claude code to summarise the repo', opts);
out.defaultWakeAi = parseCommand('hey logan ai open downloads', opts);
out.defaultWakeOnly = parseCommand('hey logan', opts);
console.log(JSON.stringify(out));
'@
    $routerOut = Join-Path $script:Work 'router-check.js'
    $routerCheck | Set-Content -Path $routerOut -Encoding ASCII
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $routerJson = & $NodeExe $routerOut (Join-Path $inst 'app') 2>&1 | Out-String
    $ErrorActionPreference = $savedEap
    $routerData = $null
    try { $routerData = $routerJson | ConvertFrom-Json } catch { }
    Check 'V11-B18 client remainder "ask claude code to summarise the repo" routes to claude-code (task summarise the repo)' ($routerData -and ($routerData.clientRemainder.agentId -eq 'claude-code') -and ($routerData.clientRemainder.task -ieq 'summarise the repo')) { param($x) $x } $(if ($routerData) { $routerData.clientRemainder.agentId + ' / ' + $routerData.clientRemainder.task } else { $routerJson.Substring(0, [Math]::Min(160, $routerJson.Length)) })
    Check 'V11-B19 "hey logan ai open downloads" -> defaultWake + task open downloads' ($routerData -and ($routerData.defaultWakeAi.defaultWake -eq $true) -and ($routerData.defaultWakeAi.task -ieq 'open downloads')) { param($x) $x } $(if ($routerData) { $routerData.defaultWakeAi.task } else { '' })
    Check 'V11-B20 "hey logan" alone -> defaultWake + needsTask' ($routerData -and ($routerData.defaultWakeOnly.defaultWake -eq $true) -and ($routerData.defaultWakeOnly.needsTask -eq $true)) { param($x) $x }
    $cmdRemainder = Api-PostCommand -Port $HTTP_PORT -Token $QA_TOKEN -Text 'ask claude code to summarise the repo' -TimeoutSec 60
    Check 'V11-B21 POST /api/command "ask claude code ..." (sync) returned a JSON answer' ($null -ne $cmdRemainder) { param($x) $x }
    if ($cmdRemainder) {
        $cmdAll = ("" + $cmdRemainder.speech + ' ' + $cmdRemainder.text)
        Check 'V11-B22 that answer comes from the Claude Code agent (routing proof)' ($cmdAll.ToLower().IndexOf('claude') -ge 0) { param($x) $x } ($cmdAll.Substring(0, [Math]::Min(180, $cmdAll.Length)))
    }
    $cmdTyped = Api-PostCommand -Port $HTTP_PORT -Token $QA_TOKEN -Text 'hey logan list my downloads folder' -TimeoutSec 120
    Check 'V11-B23 POST /api/command "hey logan list my downloads folder" ok' ($cmdTyped -and $cmdTyped.ok -ne $false) { param($x) $x }
    if ($cmdTyped) { Check 'V11-B24 typed wake+command produced a Computer answer' (("" + $cmdTyped.speech + ' ' + $cmdTyped.text).IndexOf('Downloads', [StringComparison]::OrdinalIgnoreCase) -ge 0) { param($x) $x } ("$($cmdTyped.speech)".Substring(0, [Math]::Min(180, "$($cmdTyped.speech)".Length))) }
    $cmdBare = Api-PostCommand -Port $HTTP_PORT -Token $QA_TOKEN -Text 'hey logan' -TimeoutSec 60
    Check 'V11-B25 POST /api/command "hey logan" -> Logan here. What would you like me to do?' ($cmdBare -and ("$($cmdBare.speech)" -like 'Logan here.*What would you like me to do?*')) { param($x) $x } $(if ($cmdBare) { $cmdBare.speech } else { '' })

    # browser process: dedicated profile + exactly the intended flags
    $profilePath = Join-Path $inst 'browser-profile'
    $browserMain = $null
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        $candidates = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -in @('msedge.exe', 'chrome.exe') -and $_.CommandLine -and $_.CommandLine.IndexOf($profilePath, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and $_.CommandLine.IndexOf('--app=', [StringComparison]::OrdinalIgnoreCase) -ge 0 })
        if ($candidates.Count -gt 0) { $browserMain = $candidates[0]; break }
        Start-Sleep -Milliseconds 500
    }
    Check 'V11-B26 launcher started a browser with the dedicated profile' ($null -ne $browserMain) { param($x) $x } $(if ($browserMain) { 'pid ' + $browserMain.ProcessId } else { 'not found' })
    if ($browserMain) {
        $bcmd = "$($browserMain.CommandLine)"
        Check 'V11-B27 browser opens the app URL on the expected port with the token' (($bcmd.IndexOf(('--app=http://127.0.0.1:' + $HTTP_PORT + '/?token='), [StringComparison]::OrdinalIgnoreCase) -ge 0)) { param($x) $x } $bcmd
        Check 'V11-B28 browser cmdline has --user-data-dir=<install>\browser-profile' ($bcmd.IndexOf(('--user-data-dir="' + $profilePath + '"'), [StringComparison]::OrdinalIgnoreCase) -ge 0) { param($x) $x }
        Check 'V11-B29 browser cmdline has --autoplay-policy=no-user-gesture-required' ($bcmd.IndexOf('--autoplay-policy=no-user-gesture-required', [StringComparison]::OrdinalIgnoreCase) -ge 0) { param($x) $x }
        Check 'V11-B30 browser cmdline has --window-size=1180,840' ($bcmd.IndexOf('--window-size=1180,840', [StringComparison]::OrdinalIgnoreCase) -ge 0) { param($x) $x }
        Check 'V11-B31 browser cmdline does NOT use --use-fake-ui-for-media-stream' ($bcmd.IndexOf('--use-fake-ui-for-media-stream', [StringComparison]::OrdinalIgnoreCase) -lt 0) { param($x) $x }
    }

    # seeded microphone grant for exactly our origins
    Start-Sleep -Seconds 3
    $prefPath = Join-Path $profilePath 'Default\Preferences'
    Check 'V11-B32 seeded profile Preferences file exists' (Test-Path -LiteralPath $prefPath) { param($x) $x } $(if (Test-Path $prefPath) { (Get-Item $prefPath).Length.ToString() + ' bytes' } else { 'missing' })
    if (Test-Path -LiteralPath $prefPath) {
        $prefJson = $null
        try { $prefJson = Get-Content -LiteralPath $prefPath -Raw | ConvertFrom-Json } catch { $prefJson = $null }
        Check 'V11-B33 Preferences is valid JSON' ($null -ne $prefJson) { param($x) $x }
        $mic = $null
        try { $mic = $prefJson.profile.content_settings.exceptions.media_stream_mic } catch { $mic = $null }
        $micKeys = @()
        if ($null -ne $mic) { $micKeys = @($mic.PSObject.Properties | ForEach-Object { $_.Name }) }
        Check 'V11-B34 Preferences has a media_stream_mic grant for http://127.0.0.1:8790' ($micKeys -contains ('http://127.0.0.1:' + $HTTP_PORT + ',*')) { param($x) $x } ($micKeys -join ' | ')
        Check 'V11-B35 Preferences has a media_stream_mic grant for https://127.0.0.1:8445' ($micKeys -contains ('https://127.0.0.1:' + $HTTPS_PORT + ',*')) { param($x) $x }
        Check 'V11-B36 Preferences grant setting is ALLOW (1)' (($null -ne $mic) -and ($micKeys.Count -gt 0) -and (($mic.PSObject.Properties | Where-Object { $_.Name -eq ('http://127.0.0.1:' + $HTTP_PORT + ',*') } | ForEach-Object { $_.Value.setting }) -eq 1)) { param($x) $x }
    }

    # real app window screenshot (also: no warning bar)
    $winPng = Join-Path $OutDir 'v11-app-window.png'
    $browserPids = @(Get-BrowserProcsForProfile -ProfilePath $profilePath | ForEach-Object { $_.ProcessId })
    $winShot = Capture-Window -TitlePattern '^Hey Logan AI' -OutPng $winPng -TimeoutSec 30 -WindowPids $browserPids
    Check 'V11-B37 real app window captured' ($null -ne $winShot -and (Test-Path $winPng) -and ((Get-Item $winPng).Length -gt 20000)) { param($x) $x } $(if ($winShot) { $winShot.Width.ToString() + 'x' + $winShot.Height.ToString() + ' / ' + (Get-Item $winPng).Length + ' bytes' } else { 'not captured' })

    # deep UI probe over CDP on a second instance using the same seeded profile
    A 'Deep UI probe (CDP): microphone grant, hands-free auto-start, TTS autoplay, SpeechRecognition'
    $killed = Stop-BrowserForProfile -ProfilePath $profilePath
    A ('closed launcher browser processes: ' + $killed)
    Start-Sleep -Seconds 2
    $edge = ''
    foreach ($cand in @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe")) { if (Test-Path $cand) { $edge = $cand; break } }
    $probeOut = Join-Path $script:Work 'ui-probe.json'
    $probeOk = $false
    if ($edge) {
        $probeUrl = 'http://127.0.0.1:' + $HTTP_PORT + '/?token=' + $QA_TOKEN
        $edgeArgs = @(
            ('--app=' + $probeUrl), '--window-size=1180,840',
            ('--user-data-dir="' + $profilePath + '"'), '--no-first-run', '--no-default-browser-check',
            '--autoplay-policy=no-user-gesture-required', '--remote-debugging-port=9223'
        )
        $ep = Start-Process -FilePath $edge -ArgumentList $edgeArgs -PassThru -WindowStyle Minimized
        Start-Sleep -Seconds 5
        $savedEap2 = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $probeText = & $NodeExe (Join-Path $OutDir 'v11-ui-probe.js') 9223 "$HTTP_PORT" 2>&1 | Out-String
        $ErrorActionPreference = $savedEap2
        $probeText | Set-Content -Path $probeOut -Encoding UTF8
        $probe = $null
        try { $probe = $probeOut | Get-Content -Raw | ConvertFrom-Json } catch { $probe = $null }
        if (-not $probe) { try { $probe = $probeText | ConvertFrom-Json } catch { $probe = $null } }
        if ($probe) {
            $probeOk = $true
            Check 'V11-B38 probe: page loaded, secure context' (($probe.readyState -eq 'complete' -or $probe.readyState -eq 'interactive') -and ($probe.secureContext -eq $true)) { param($x) $x } ('ready=' + $probe.readyState + ' secure=' + $probe.secureContext)
            Check 'V11-B39 probe: microphone permission already granted (no prompt)' ($probe.microphonePermission -eq 'granted') { param($x) $x } $probe.microphonePermission
            Check 'V11-B40 probe: hands-free listening auto-started (status line)' (("$($probe.statusText)").IndexOf('Listening', [StringComparison]::OrdinalIgnoreCase) -ge 0) { param($x) $x } $probe.statusText
            Check 'V11-B41 probe: orb is in the listening state' ($probe.orbState -eq 'listening') { param($x) $x } $probe.orbState
            Check 'V11-B42 probe: UI connected to the bridge (agents ready)' (("$($probe.connLabel)").IndexOf('agents ready', [StringComparison]::OrdinalIgnoreCase) -ge 0) { param($x) $x } $probe.connLabel
            Check 'V11-B43 probe: speech synthesis works without a user gesture (autoplay flag)' ($probe.ttsProbe -in @('started', 'ended')) { param($x) $x } $probe.ttsProbe
            Check 'V11-B44 probe: SpeechRecognition.start() fires STARTED (wake engine can open the mic)' ($probe.sttProbe -eq 'STARTED') { param($x) $x } $probe.sttProbe
            Check 'V11-B45 probe: served app.js has autoStartListening' ($probe.appJsHasAutoStartListening -eq $true) { param($x) $x }
            Check 'V11-B46 probe: served sw.js is cache-busted and caches native-voice.js' ($probe.servedSwHasV110Cache -eq $true) { param($x) $x }
            Check 'V11-B47 probe: served index.html shows v1.1.0 version label' ("$($probe.servedIndexVersionLabel)" -match 'v1\.1\.0') { param($x) $x } $probe.servedIndexVersionLabel
        } else {
            Skip 'V11-B38..B47 deep UI probe assertions' 'probe JSON could not be parsed'
        }
        try { Stop-Process -Id $ep.Id -Force -ErrorAction SilentlyContinue } catch { }
        $killedProbe = Stop-BrowserForProfile -ProfilePath $profilePath
        A ('closed probe browser processes: ' + $killedProbe)
    } else {
        Skip 'V11-B38..B47 deep UI probe' 'Edge not found'
    }

    # Start at Login helpers
    $onCmd = Join-Path $inst 'Start at Login On.cmd'
    $offCmd = Join-Path $inst 'Start at Login Off.cmd'
    $offOut = Join-Path $script:Work 'login-off.txt'
    $offCode = Run-CmdCapture -CommandLine $offCmd -OutFile $offOut -TimeoutSec 60
    Check 'V11-B48 Start at Login Off.cmd exits 0 and removes the Run value' (($offCode -eq 0) -and ($null -eq (Get-RegVal 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' 'HeyLoganAI'))) { param($x) $x } ('exit=' + $offCode)
    $onOut = Join-Path $script:Work 'login-on.txt'
    $onCode = Run-CmdCapture -CommandLine $onCmd -OutFile $onOut -TimeoutSec 60
    $runAfterOn = Get-RegVal 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' 'HeyLoganAI'
    Check 'V11-B49 Start at Login On.cmd exits 0 and writes the Run value' (($onCode -eq 0) -and $runAfterOn -and ($runAfterOn -like ('*' + (Join-Path $inst 'Launch.vbs') + '*'))) { param($x) $x } ('exit=' + $onCode + ' / ' + $runAfterOn)

    # Stop.cmd (installed) and repeat use
    $stopOut = Join-Path $script:Work 'stop-installed.txt'
    $stopWrapper = New-CmdWrapper -Name 'stop-installed' -Lines @(('call "' + (Join-Path $inst 'Stop.cmd') + '" < NUL > "' + $stopOut + '" 2>&1'))
    $sp = Start-Process -FilePath $env:COMSPEC -ArgumentList @('/d', '/c', ('"' + $stopWrapper + '"')) -PassThru -Wait
    $downB = Wait-HealthDown -Port $HTTP_PORT -TimeoutSec 30
    Check 'V11-B50 installed Stop.cmd exits 0 and stops the server' (($sp.ExitCode -eq 0) -and $downB) { param($x) $x } ('exit=' + $sp.ExitCode)
    Check 'V11-B51 no node process left for the install dir' ((@(Get-NodeProcsFor -Dir $inst)).Count -eq 0) { param($x) $x }
    Start-Process -FilePath $mainTarget -ArgumentList $mainArgs | Out-Null
    $h2 = Wait-Health -Port $HTTP_PORT -TimeoutSec 90
    Check 'V11-B52 second launch via the Run value works' ($h2 -and $h2.ok -eq $true) { param($x) $x }
    $stopWrapper2 = New-CmdWrapper -Name 'stop-installed-2' -Lines @(('call "' + (Join-Path $inst 'Stop.cmd') + '" < NUL > "' + (Join-Path $script:Work 'stop-installed-2.txt') + '" 2>&1'))
    $sp2 = Start-Process -FilePath $env:COMSPEC -ArgumentList @('/d', '/c', ('"' + $stopWrapper2 + '"')) -PassThru -Wait
    Check 'V11-B53 second stop works' (($sp2.ExitCode -eq 0) -and (Wait-HealthDown -Port $HTTP_PORT -TimeoutSec 30)) { param($x) $x }
    Stop-BrowserForProfile -ProfilePath $profilePath | Out-Null

    # ======================================================================
    A ''
    A '=== PHASE V11-C: upgrade-in-place over this install (keeps token + browser profile) ==='
    $phase = 'upgrade'
    $tokenBefore = (Get-Content $cfgPath -Raw | ConvertFrom-Json).security.token
    $prefShaBefore = if (Test-Path $prefPath) { (Get-FileHash -LiteralPath $prefPath -Algorithm SHA256).Hash } else { '' }
    $prefMicBefore = $false
    if (Test-Path $prefPath) { try { $prefMicBefore = @((Get-Content $prefPath -Raw | ConvertFrom-Json).profile.content_settings.exceptions.media_stream_mic.PSObject.Properties.Name) -contains ('http://127.0.0.1:' + $HTTP_PORT + ',*') } catch { $prefMicBefore = $false } }
    Start-Process -FilePath $mainTarget -ArgumentList $mainArgs | Out-Null
    $hUp = Wait-Health -Port $HTTP_PORT -TimeoutSec 90
    Check 'V11-C0 app running before the upgrade' ($hUp -and $hUp.ok -eq $true) { param($x) $x }
    $p = Start-Process -FilePath $setupExe -ArgumentList '/S' -PassThru -Wait
    Check 'V11-C1 upgrade installer exit code 0' ($p.ExitCode -eq 0) { param($x) $x } ('exit=' + $p.ExitCode)
    Start-Sleep -Seconds 1
    Check 'V11-C2 upgrade installed into the same scratch dir (upgrade-in-place)' ((Test-Path (Join-Path $inst 'Launch.vbs')) -and (-not (Test-Path "$env:LOCALAPPDATA\Programs\HeyLoganAI"))) { param($x) $x }
    Check 'V11-C3 token unchanged after upgrade' ((Get-Content $cfgPath -Raw | ConvertFrom-Json).security.token -eq $tokenBefore) { param($x) $x } $tokenBefore
    $prefMicAfter = $false
    if (Test-Path $prefPath) { try { $prefMicAfter = @((Get-Content $prefPath -Raw | ConvertFrom-Json).profile.content_settings.exceptions.media_stream_mic.PSObject.Properties.Name) -contains ('http://127.0.0.1:' + $HTTP_PORT + ',*') } catch { $prefMicAfter = $false } }
    Check 'V11-C4 private browser profile preserved across upgrade (mic grant kept)' ($prefMicBefore -and $prefMicAfter) { param($x) $x } ('before=' + $prefMicBefore + ' after=' + $prefMicAfter)
    Check 'V11-C5 no duplicate Start Menu shortcuts after upgrade' ((@(Get-ChildItem $smGroup -Filter *.lnk -ErrorAction SilentlyContinue)).Count -eq 8) { param($x) $x }
    Check 'V11-C6 ARP DisplayVersion still 1.1.0' ((Get-RegVal $arpKey 'DisplayVersion') -eq '1.1.0') { param($x) $x }
    Check 'V11-C7 upgrade stopped the running server' (Wait-HealthDown -Port $HTTP_PORT -TimeoutSec 30) { param($x) $x }
    Start-Process -FilePath $mainTarget -ArgumentList $mainArgs | Out-Null
    $h3 = Wait-Health -Port $HTTP_PORT -TimeoutSec 90
    Check 'V11-C8 app starts again after the upgrade (version 1.1.0)' ($h3 -and $h3.version -eq '1.1.0') { param($x) $x } $(if ($h3) { $h3.version } else { '' })
    $stopWrapper3 = New-CmdWrapper -Name 'stop-after-upgrade' -Lines @(('call "' + (Join-Path $inst 'Stop.cmd') + '" < NUL > "' + (Join-Path $script:Work 'stop-after-upgrade.txt') + '" 2>&1'))
    $sp3 = Start-Process -FilePath $env:COMSPEC -ArgumentList @('/d', '/c', ('"' + $stopWrapper3 + '"')) -PassThru -Wait
    Check 'V11-C9 stop after upgrade works' (($sp3.ExitCode -eq 0) -and (Wait-HealthDown -Port $HTTP_PORT -TimeoutSec 30)) { param($x) $x }
    Stop-BrowserForProfile -ProfilePath $profilePath | Out-Null

    # ======================================================================
    A ''
    A '=== PHASE V11-D: silent uninstall (keep app\data) ==='
    $phase = 'uninstall'
    $p = Start-Process -FilePath (Join-Path $inst 'Uninstall.exe') -ArgumentList '/S' -PassThru -Wait
    Start-Sleep -Milliseconds 1200
    Check 'V11-D1 Uninstall.exe /S exit code 0' ($p.ExitCode -eq 0) { param($x) $x } ('exit=' + $p.ExitCode)
    Check 'V11-D2 Start Menu group removed' (-not (Test-Path $smGroup)) { param($x) $x }
    Check 'V11-D3 Desktop shortcut removed' (-not (Test-Path $deskLnk)) { param($x) $x }
    Check 'V11-D4 ARP entry removed' (-not (Test-Path $arpKey)) { param($x) $x }
    Check 'V11-D5 HKCU app key removed' (-not (Test-Path 'HKCU:\Software\HeyLoganAI')) { param($x) $x }
    Check 'V11-D6 Run value removed' ($null -eq (Get-RegVal 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' 'HeyLoganAI')) { param($x) $x }
    Check 'V11-D7 app\data kept as documented' (Test-Path $cfgPath) { param($x) $x }
    Check 'V11-D8 private browser profile removed by the uninstaller' (-not (Test-Path $profilePath)) { param($x) $x }
    Check 'V11-D9 program files removed' ((-not (Test-Path (Join-Path $inst 'runtime'))) -and (-not (Test-Path (Join-Path $inst 'Launch.vbs'))) -and (-not (Test-Path (Join-Path $inst 'Uninstall.exe')))) { param($x) $x }
    Check 'V11-D10 no node/listener after uninstall' (((@(Get-NodeProcsFor -Dir $inst)).Count -eq 0) -and ((Get-Listeners -Ports @($HTTP_PORT, $HTTPS_PORT)).Count -eq 0)) { param($x) $x }
    if (Test-Path $inst) { Remove-Item -LiteralPath $inst -Recurse -Force -ErrorAction SilentlyContinue }
    Check 'V11-D11 keep-data leftovers removed by QA' (-not (Test-Path $inst)) { param($x) $x }

    # ======================================================================
    A ''
    A '=== PHASE V11-E: /NOAUTOSTART + purge uninstall ==='
    $phase = 'noautostart'
    $p = Start-Process -FilePath $setupExe -ArgumentList @('/S', '/NOAUTOSTART', ('/D=' + $inst2)) -PassThru -Wait
    Check 'V11-E1 /S /NOAUTOSTART install exit code 0' ($p.ExitCode -eq 0) { param($x) $x } ('exit=' + $p.ExitCode)
    Check 'V11-E2 /NOAUTOSTART wrote NO Run value' ($null -eq (Get-RegVal 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' 'HeyLoganAI')) { param($x) $x }
    Check 'V11-E3 /NOAUTOSTART still installed the app + shortcuts' ((Test-Path (Join-Path $inst2 'Launch.vbs')) -and (Test-Path (Join-Path $smGroup 'Hey Logan AI.lnk'))) { param($x) $x }
    $p = Start-Process -FilePath (Join-Path $inst2 'Uninstall.exe') -ArgumentList @('/S', '/PURGEDATA') -PassThru -Wait
    Start-Sleep -Milliseconds 1200
    Check 'V11-E4 /S /PURGEDATA uninstall exit code 0' ($p.ExitCode -eq 0) { param($x) $x } ('exit=' + $p.ExitCode)
    Check 'V11-E5 purge removed the install folder entirely' (-not (Test-Path $inst2)) { param($x) $x }
    Check 'V11-E6 purge removed registry entries' ((-not (Test-Path $arpKey)) -and (-not (Test-Path 'HKCU:\Software\HeyLoganAI'))) { param($x) $x }
    Check 'V11-E7 purge removed the shortcuts' ((-not (Test-Path $smGroup)) -and (-not (Test-Path $deskLnk))) { param($x) $x }

    # ======================================================================
    A ''
    A '=== PHASE V11-F: upgrade over an existing v1.0.0-style custom install (fake HKCU) ==='
    $phase = 'upgrade-old'
    Check 'V11-F0 user v1.0.0 tree available to model the old install' (Test-Path 'D:\HeyLoganAI\Launch.vbs') { param($x) $x }
    if (Test-Path 'D:\HeyLoganAI') {
        if (Test-Path $old10) { Remove-Item -LiteralPath $old10 -Recurse -Force }
        # A minimal v1.0.0-style install tree is enough: the installer only needs
        # the registered folder to exist; it replaces the program files and keeps
        # the data folder. Never copy the user's real data/token.
        New-Item -ItemType Directory -Force -Path $old10 | Out-Null
        'old v1.0.0 launcher placeholder' | Set-Content -Path (Join-Path $old10 'Launch.vbs') -Encoding ASCII
        [System.IO.File]::WriteAllBytes((Join-Path $old10 'Uninstall.exe'), [byte[]](0x4D, 0x5A, 0x00, 0x00))
        New-Item -ItemType Directory -Force -Path (Join-Path $old10 'app\data') | Out-Null
        $fakeCfg = @{ security = @{ token = 'QA-OLD-TOKEN-0001' }; server = @{ httpPort = 8787; httpsPort = 8443 } } | ConvertTo-Json -Depth 4
        $fakeCfg | Set-Content -Path (Join-Path $old10 'app\data\config.json') -Encoding UTF8
        'keep-me' | Set-Content -Path (Join-Path $old10 'app\data\qa-marker.txt')
        Check 'V11-F1 fake v1.0.0 tree + data prepared' ((Test-Path (Join-Path $old10 'Launch.vbs')) -and (Test-Path (Join-Path $old10 'app\data\config.json'))) { param($x) $x } $old10
        # fake ARP/appkey entries describing the old install (backed up user state will be restored later)
        if (Test-Path $arpKey) { Remove-Item -Path $arpKey -Recurse -Force }
        New-Item -Path $arpKey -Force | Out-Null
        foreach ($pair in @(@('DisplayName', 'Hey Logan AI'), @('DisplayVersion', '1.0.0'), @('Publisher', 'Hey Logan AI'), @('InstallLocation', $old10), @('DisplayIcon', (Join-Path $old10 'heylogan.ico')), @('UninstallString', ('"' + (Join-Path $old10 'Uninstall.exe') + '"')), @('QuietUninstallString', ('"' + (Join-Path $old10 'Uninstall.exe') + '" /S')))) { New-ItemProperty -Path $arpKey -Name $pair[0] -Value $pair[1] -PropertyType String -Force | Out-Null }
        if (Test-Path 'HKCU:\Software\HeyLoganAI') { Remove-Item -Path 'HKCU:\Software\HeyLoganAI' -Recurse -Force }
        New-Item -Path 'HKCU:\Software\HeyLoganAI' -Force | Out-Null
        foreach ($pair in @(@('InstallDir', $old10), @('Version', '1.0.0'), @('DataDir', (Join-Path $old10 'app\data')))) { New-ItemProperty -Path 'HKCU:\Software\HeyLoganAI' -Name $pair[0] -Value $pair[1] -PropertyType String -Force | Out-Null }
        $p = Start-Process -FilePath $setupExe -ArgumentList '/S' -PassThru -Wait
        Check 'V11-F2 new installer (no /D=) exit code 0' ($p.ExitCode -eq 0) { param($x) $x } ('exit=' + $p.ExitCode)
        Check 'V11-F3 installer reused the registered old install folder (no second copy)' ((Test-Path (Join-Path $old10 'Launch.vbs')) -and (-not (Test-Path "$env:LOCALAPPDATA\Programs\HeyLoganAI"))) { param($x) $x }
        Check 'V11-F4 program files were upgraded (Launch.vbs == 1.1.0 payload)' ((Get-FileHash -LiteralPath (Join-Path $old10 'Launch.vbs') -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath (Join-Path $payloadSrc 'Launch.vbs') -Algorithm SHA256).Hash) { param($x) $x }
        Check 'V11-F5 app\data preserved (fake token unchanged)' ((Get-Content (Join-Path $old10 'app\data\config.json') -Raw | ConvertFrom-Json).security.token -eq 'QA-OLD-TOKEN-0001') { param($x) $x }
        Check 'V11-F6 app\data marker file preserved' (Test-Path (Join-Path $old10 'app\data\qa-marker.txt')) { param($x) $x }
        Check 'V11-F7 ARP version now 1.1.0, location still old folder' (((Get-RegVal $arpKey 'DisplayVersion') -eq '1.1.0') -and ((Get-RegVal $arpKey 'InstallLocation') -ieq $old10)) { param($x) $x } ((Get-RegVal $arpKey 'DisplayVersion') + ' @ ' + (Get-RegVal $arpKey 'InstallLocation'))
        Check 'V11-F8 Run value now points at the old folder''s new Launch.vbs' ((Get-RegVal 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' 'HeyLoganAI') -like ('*' + (Join-Path $old10 'Launch.vbs') + '*')) { param($x) $x } (Get-RegVal 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' 'HeyLoganAI')
        $p = Start-Process -FilePath (Join-Path $old10 'Uninstall.exe') -ArgumentList @('/S', '/PURGEDATA') -PassThru -Wait
        Start-Sleep -Milliseconds 1200
        Check 'V11-F9 purge uninstall of the upgraded old install exits 0' ($p.ExitCode -eq 0) { param($x) $x } ('exit=' + $p.ExitCode)
        Check 'V11-F10 old install folder removed' (-not (Test-Path $old10)) { param($x) $x }
    }
    Restore-UserState
    $verifyUser = Verify-UserState
    Check 'V11-F11 user''s real ARP/Run/Start-Menu/Desktop state restored exactly' $verifyUser.Ok { param($x) $x } $verifyUser.Detail

    # ======================================================================
    A ''
    A '=== PHASE V11-G: portable ZIP (no installer, alt ports 8792/8447) ==='
    $phase = 'portable'
    $preArpG = Get-RegVal 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\HeyLoganAI' 'InstallLocation'
    $preRunG = Get-RegVal 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' 'HeyLoganAI'
    $preSmG = (@(Get-ChildItem $smGroup -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join '|')
    $preDeskG = Test-Path $deskLnk
    New-Item -ItemType Directory -Force -Path $portable | Out-Null
    tar -xf $portableSrc -C $portable
    $portableRoot = Join-Path $portable 'HeyLoganAI'
    Check 'V11-G1 portable ZIP extracted' (Test-Path (Join-Path $portableRoot 'Launch.vbs')) { param($x) $x }
    Check 'V11-G2 portable extras present' ((Test-Path (Join-Path $portableRoot 'README-FIRST.txt')) -and (Test-Path (Join-Path $portableRoot 'Start Hey Logan AI.cmd'))) { param($x) $x }
    $env:HEY_AI_HTTP_PORT = "$P_HTTP_PORT"
    $env:HEY_AI_HTTPS_PORT = "$P_HTTPS_PORT"
    $env:HEY_AI_TOKEN = $QA_TOKEN
    Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList ('"' + (Join-Path $portableRoot 'Launch.vbs') + '"') | Out-Null
    $ph = Wait-Health -Port $P_HTTP_PORT -TimeoutSec 90
    Check 'V11-G3 portable Launch.vbs starts the server (health 1.1.0)' ($ph -and $ph.version -eq '1.1.0') { param($x) $x } $(if ($ph) { $ph.version } else { '' })
    $pProfile = Join-Path $portableRoot 'browser-profile'
    $pb = $null
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) { $c = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -in @('msedge.exe', 'chrome.exe') -and $_.CommandLine -and $_.CommandLine.IndexOf($pProfile, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and $_.CommandLine.IndexOf('--app=', [StringComparison]::OrdinalIgnoreCase) -ge 0 }); if ($c.Count -gt 0) { $pb = $c[0]; break }; Start-Sleep -Milliseconds 500 }
    Check 'V11-G4 portable launcher used the private profile + autoplay flag, no fake-UI flag' ($pb -and ("$($pb.CommandLine)").IndexOf('--autoplay-policy=no-user-gesture-required', [StringComparison]::OrdinalIgnoreCase) -ge 0 -and ("$($pb.CommandLine)").IndexOf('--use-fake-ui-for-media-stream', [StringComparison]::OrdinalIgnoreCase) -lt 0) { param($x) $x }
    $pPref = Join-Path $pProfile 'Default\Preferences'
    $pPrefJson = $null
    if (Test-Path $pPref) { try { $pPrefJson = Get-Content $pPref -Raw | ConvertFrom-Json } catch { } }
    Check 'V11-G5 portable profile seeded with the mic grant on 8792' ($null -ne $pPrefJson -and @($pPrefJson.profile.content_settings.exceptions.media_stream_mic.PSObject.Properties.Name) -contains ('http://127.0.0.1:' + $P_HTTP_PORT + ',*')) { param($x) $x }
    $pwin = Join-Path $OutDir 'v11-portable-window.png'
    $pBrowserPids = @(Get-BrowserProcsForProfile -ProfilePath $pProfile | ForEach-Object { $_.ProcessId })
    $pwinShot = Capture-Window -TitlePattern '^Hey Logan AI' -OutPng $pwin -TimeoutSec 25 -WindowPids $pBrowserPids
    Check 'V11-G6 portable app window captured' ($null -ne $pwinShot -and (Test-Path $pwin) -and ((Get-Item $pwin).Length -gt 20000)) { param($x) $x } $(if ($pwinShot) { $pwinShot.Width.ToString() + 'x' + $pwinShot.Height.ToString() + ' / ' + $pwinShot.Bytes + ' bytes' } else { 'not captured' })
    $postArpG = Get-RegVal 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\HeyLoganAI' 'InstallLocation'
    $postRunG = Get-RegVal 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' 'HeyLoganAI'
    $postSmG = (@(Get-ChildItem $smGroup -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join '|')
    $postDeskG = Test-Path $deskLnk
    Check 'V11-G7 portable run created no registry/shortcut side effects' (($preArpG -eq $postArpG) -and ($preRunG -eq $postRunG) -and ($preSmG -eq $postSmG) -and ($preDeskG -eq $postDeskG)) { param($x) $x } ('arp=' + $postArpG + ' run=' + $postRunG)
    $pStop = Join-Path $portableRoot 'tools\stop.ps1'
    $ps = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $pStop + '"')) -PassThru -Wait -WindowStyle Hidden
    Check 'V11-G8 portable tools\stop.ps1 stops the server' (($ps.ExitCode -eq 0) -and (Wait-HealthDown -Port $P_HTTP_PORT -TimeoutSec 30)) { param($x) $x } ('exit=' + $ps.ExitCode)
    Stop-BrowserForProfile -ProfilePath $pProfile | Out-Null
    # console launcher + Stop.cmd (regression check from v1.0.0)
    $consoleCmd = Join-Path $portableRoot 'Start Hey Logan AI.cmd'
    $w = New-CmdWrapper -Name 'portable-console' -Lines @(('call "' + $consoleCmd + '"'))
    $cp = Start-Process -FilePath $env:COMSPEC -ArgumentList @('/d', '/c', ('"' + $w + '"')) -PassThru -WindowStyle Hidden
    $ph2 = Wait-Health -Port $P_HTTP_PORT -TimeoutSec 90
    Check 'V11-G9 portable "Start Hey Logan AI.cmd" starts the server' ($ph2 -and $ph2.ok -eq $true) { param($x) $x }
    $pStopOut = Join-Path $script:Work 'portable-stopcmd.txt'
    $pStopCode = Run-CmdCapture -CommandLine (Join-Path $portableRoot 'Stop.cmd') -OutFile $pStopOut -TimeoutSec 60
    $pDown = Wait-HealthDown -Port $P_HTTP_PORT -TimeoutSec 30
    Check 'V11-G10 portable Stop.cmd stops a console-launched server' (($pStopCode -eq 0) -and $pDown) { param($x) $x } ('exit=' + $pStopCode)
    try { Stop-Process -Id $cp.Id -Force -ErrorAction SilentlyContinue } catch { }
    Stop-BrowserForProfile -ProfilePath $pProfile | Out-Null
    if (Test-Path $portable) { Remove-Item -LiteralPath $portable -Recurse -Force -ErrorAction SilentlyContinue }
    Check 'V11-G11 no node process / listener left after the portable test' (((@(Get-NodeProcsFor -Dir $portableRoot)).Count -eq 0) -and ((Get-Listeners -Ports @($P_HTTP_PORT, $P_HTTPS_PORT)).Count -eq 0)) { param($x) $x }

    # ======================================================================
    A ''
    A '=== PHASE V11-H: final clean-machine and user-state checks ==='
    $phase = 'final'
    Restore-UserState
    $verifyUser2 = Verify-UserState
    Check 'V11-H1 user''s real installation state restored exactly' $verifyUser2.Ok { param($x) $x } $verifyUser2.Detail
    $userListeners = @(Get-Listeners -Ports @(8787, 8443))
    Check 'V11-H2 user''s real server still running on 8787/8443 (pid preserved)' (($userListeners.Count -ge 1) -and ($userListeners[0].OwningProcess -eq $script:userState.serverPid)) { param($x) $x } (($userListeners | ForEach-Object { $_.LocalPort.ToString() + '=pid' + $_.OwningProcess }) -join ',')
    Check 'V11-H3 no listeners left on the QA ports' ((Get-Listeners -Ports @($HTTP_PORT, $HTTPS_PORT, $P_HTTP_PORT, $P_HTTPS_PORT)).Count -eq 0) { param($x) $x }
    $ourNode = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and ($_.CommandLine.IndexOf('hl-qa-11') -ge 0) })
    Check 'V11-H4 no QA node process left' ($ourNode.Count -eq 0) { param($x) $x } (($ourNode | ForEach-Object { $_.ProcessId }) -join ',')
    $browserLeft = @(Get-BrowserProcsForProfile -ProfilePath 'C:\Temp\hl-qa-11')
    Check 'V11-H5 no QA browser process left' ($browserLeft.Count -eq 0) { param($x) $x } (($browserLeft | ForEach-Object { $_.ProcessId }) -join ',')
    Check 'V11-H6 no test install dir left' ((-not (Test-Path $inst)) -and (-not (Test-Path $inst2)) -and (-not (Test-Path $old10)) -and (-not (Test-Path $portable))) { param($x) $x }
    Check 'V11-H7 no ARP/app-key entry for the QA installs left' (((Get-RegVal 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\HeyLoganAI' 'InstallLocation') -ieq 'D:\HeyLoganAI')) { param($x) $x } (Get-RegVal 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\HeyLoganAI' 'InstallLocation')
}
catch {
    A ('FATAL: ' + $_.Exception.Message)
    A ($_.ScriptStackTrace)
    $script:FailCount += 1
    $script:Results.Add([pscustomobject]@{ Status = 'FAIL'; Name = 'FATAL: ' + $_.Exception.Message; Detail = '' })
}
finally {
    A ''
    A '=== CLEANUP + restore ==='
    # best-effort cleanup of test installations (never the user's D:\ install)
    foreach ($dir in @($inst, $inst2, $old10)) {
        if (Test-Path (Join-Path $dir 'Uninstall.exe')) {
            try { Start-Process -FilePath (Join-Path $dir 'Uninstall.exe') -ArgumentList @('/S', '/PURGEDATA') -Wait -ErrorAction SilentlyContinue } catch { }
            Start-Sleep -Milliseconds 800
        }
        if (Test-Path $dir) {
            foreach ($pr in @(Get-NodeProcsFor -Dir $dir)) { try { Stop-Process -Id $pr.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
            try { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
    foreach ($prof in @((Join-Path $inst 'browser-profile'), (Join-Path $inst2 'browser-profile'), (Join-Path $old10 'browser-profile'), (Join-Path $portable 'HeyLoganAI\browser-profile'))) { Stop-BrowserForProfile -ProfilePath $prof | Out-Null }
    # restore the user's registry/shortcut state
    try { Restore-UserState } catch { A ('restore failed: ' + $_.Exception.Message) }
    $verifyFinal = $null
    try { $verifyFinal = Verify-UserState } catch { }
    try { $userFinal = @(Get-Listeners -Ports @(8787, 8443)) } catch { $userFinal = @() }
    A ('final: userStateOk=' + $(if ($verifyFinal) { $verifyFinal.Ok } else { 'unknown' }) + ' userServerListeners=' + $userFinal.Count + ' altListeners=' + ((Get-Listeners -Ports @($HTTP_PORT, $HTTPS_PORT, $P_HTTP_PORT, $P_HTTPS_PORT)).Count) + ' qaNode=' + @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf('hl-qa-11') -ge 0 }).Count)
    # write logs/summary
    $summary = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        host = $env:COMPUTERNAME
        setup = @{ path = $setupSrc; size = $setupSize; sha256 = $setupSha }
        portable = @{ path = $portableSrc; size = $portableSize; sha256 = $portableSha }
        apk = @{ path = $apkSrc; sha256 = $apkSha }
        projectZip = @{ path = $projectSrc; sha256 = $projectSha }
        checks = ($script:PassCount + $script:FailCount)
        passed = $script:PassCount
        failed = $script:FailCount
        skipped = $script:SkipCount
        failures = @($script:Results | Where-Object { $_.Status -eq 'FAIL' } | ForEach-Object { $_.Name })
        userStateRestored = $(if ($verifyFinal) { $verifyFinal.Ok } else { $false })
        userServerListeners = $userFinal.Count
        logPath = (Join-Path $OutDir 'v11-windows-e2e.log')
        probePath = (Join-Path $script:Work 'ui-probe.json')
    }
    $script:Log | Set-Content -Path (Join-Path $OutDir 'v11-windows-e2e.log') -Encoding UTF8
    $summary | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $OutDir 'v11-windows-e2e-summary.json') -Encoding UTF8
    $script:Results | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $OutDir 'v11-windows-e2e-results.json') -Encoding UTF8
    # keep the probe JSON as evidence, then remove scratch
    if (Test-Path (Join-Path $script:Work 'ui-probe.json')) { Copy-Item (Join-Path $script:Work 'ui-probe.json') (Join-Path $OutDir 'v11-ui-probe.json') -Force }
    # keep a copy of the backup outside the scratch tree (recovery safety net)
    $backupSrc = Join-Path $script:Work 'backup'
    $backupDst = Join-Path $OutDir 'v11-state-backup-auto'
    if (Test-Path $backupSrc) {
        if (Test-Path $backupDst) { Remove-Item -LiteralPath $backupDst -Recurse -Force -ErrorAction SilentlyContinue }
        Copy-Item -LiteralPath $backupSrc -Destination $backupDst -Recurse -Force -ErrorAction SilentlyContinue
        A ('backup copy kept for recovery: ' + $backupDst)
    }
    A ('SUMMARY: checks=' + ($script:PassCount + $script:FailCount) + ' PASS=' + $script:PassCount + ' FAIL=' + $script:FailCount + ' SKIP=' + $script:SkipCount)
    if (Test-Path $script:Work) { Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue }
    if ($script:FailCount -gt 0) { exit 1 } else { exit 0 }
}
