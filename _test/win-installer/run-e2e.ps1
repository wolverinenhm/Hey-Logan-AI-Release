#=============================================================================
# Hey Logan AI v1.1.0 - Windows installer / portable ZIP end-to-end test
#
# IMPORTANT: this machine also has the USER'S REAL v1.0.0 installation at
# D:\HeyLoganAI with the app running on ports 8787/8443. This test:
#   * NEVER touches, stops or deletes D:\HeyLoganAI, its processes or its
#     Edge PWA entry;
#   * saves the real HKCU ARP entry, HKCU app key, Run value, Start Menu group
#     and Desktop shortcut BEFORE testing, and restores them EXACTLY afterwards
#     (even if a test fails);
#   * runs every test installation in C:\Temp scratch folders and every test
#     server on ports 8790/8445 (HEY_AI_HTTP_PORT / HEY_AI_HTTPS_PORT), because
#     8787/8443 belong to the user's live app.
#
# Run from a COPY outside the release workspace:
#   Copy-Item <repo>\_test\win-installer\run-e2e.ps1 C:\Temp\hl-test\
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\Temp\hl-test\run-e2e.ps1
#=============================================================================

[CmdletBinding()]
param(
    [string]$RepoRoot = 'C:\Users\s2121270\Downloads\Hey-Logan-AI-Release',
    [string]$Version = '1.1.0',
    [string]$WorkRoot = 'C:\Temp\hl-e2e',
    [string]$ReportDir = '',
    [string]$UserInstallDir = 'D:\HeyLoganAI',
    [int]$TestHttpPort = 8790,
    [int]$TestHttpsPort = 8445,
    [int]$InstallTimeoutSec = 300,
    [int]$HealthTimeoutSec = 90,
    [switch]$KeepWork
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Paths and state
# ---------------------------------------------------------------------------
$setupDist = Join-Path $RepoRoot "dist\HeyLoganAI-Setup-$Version-win-x64.exe"
$zipDist = Join-Path $RepoRoot "dist\HeyLoganAI-Portable-$Version-win-x64.zip"
$setupRun = Join-Path $WorkRoot 'setup\HeyLoganAI-Setup.exe'
$scratchA = Join-Path $WorkRoot 'install-a'
$scratchB = Join-Path $WorkRoot 'install-b'
$scratchC = Join-Path $WorkRoot 'install-c-noauto'
$oldTree = 'C:\Temp\hl-old'
$portableDir = Join-Path $WorkRoot 'portable\HeyLoganAI'
$evidenceDir = Join-Path $WorkRoot 'evidence'
$stateBackup = Join-Path $WorkRoot 'user-state-backup'
if (-not $ReportDir) { $ReportDir = Join-Path $RepoRoot '_test\win-installer' }
if (-not (Test-Path -LiteralPath $WorkRoot)) { New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null }
$null = New-Item -ItemType Directory -Path $evidenceDir -Force
$null = New-Item -ItemType Directory -Path $ReportDir -Force
$repoEvidenceDir = Join-Path $ReportDir 'evidence'
$null = New-Item -ItemType Directory -Path $repoEvidenceDir -Force
$logPath = Join-Path $ReportDir 'e2e-run.log'
$zipReport = Join-Path $ReportDir 'e2e-summary.json'

$script:CheckNum = 0
$script:Pass = 0
$script:Fail = 0
$script:Failures = New-Object System.Collections.ArrayList
$script:Wsh = New-Object -ComObject WScript.Shell

$ARP_KEY = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\HeyLoganAI'
$APP_KEY = 'HKCU:\Software\HeyLoganAI'
$RUN_KEY = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RUN_NAME = 'HeyLoganAI'
$SM_DIR = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Hey Logan AI'
$DESKTOP_LNK = Join-Path $env:USERPROFILE 'Desktop\Hey Logan AI.lnk'
$EDGE_PWA_ARP = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\b70728fd89841d6b23646628e87b05b7'

# Test servers must use 8790/8445: 8787/8443 are the user's live app.
$env:HEY_AI_HTTP_PORT = [string]$TestHttpPort
$env:HEY_AI_HTTPS_PORT = [string]$TestHttpsPort
$testBaseUrl = "http://127.0.0.1:$TestHttpPort"

# Win32 helpers for capturing the app window screenshot (warning-bar check)
Add-Type @"
using System;
using System.Drawing;
using System.Runtime.InteropServices;
public class HLSnap {
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    public static bool Save(IntPtr hwnd, string path) {
        RECT r; if (!GetWindowRect(hwnd, out r)) return false;
        int w = r.Right - r.Left, h = r.Bottom - r.Top;
        if (w <= 0 || h <= 0) return false;
        using (var bmp = new Bitmap(w, h)) {
            using (var g = Graphics.FromImage(bmp)) {
                IntPtr hdc = g.GetHdc();
                bool ok = PrintWindow(hwnd, hdc, 2);
                g.ReleaseHdc(hdc);
                if (!ok) return false;
            }
            bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
        }
        return true;
    }
}
"@ -ReferencedAssemblies System.Drawing

Set-Content -LiteralPath $logPath -Value ("Hey Logan AI v$Version E2E test - {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding UTF8

# ---------------------------------------------------------------------------
# Logging / assertions
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Color = 'Gray', [switch]$NoConsole)
    $line = ('[{0:HH:mm:ss}] {1}' -f (Get-Date), $Message)
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    if (-not $NoConsole) { Write-Host $line -ForegroundColor $Color }
}

function Write-Section {
    param([string]$Title)
    Write-Log ''
    Write-Log ("=== $Title ===") 'Cyan'
}

function Add-Check {
    param(
        [Parameter(Mandatory)][string]$Name,
        [bool]$Condition,
        [string]$Detail = ''
    )
    $script:CheckNum++
    $id = ('{0:00}' -f $script:CheckNum)
    if ($Condition) {
        $script:Pass++
        $text = "PASS $id  $Name"
        if ($Detail) { $text += "  [$Detail]" }
        Write-Log $text 'Green'
    }
    else {
        $script:Fail++
        $text = "FAIL $id  $Name"
        if ($Detail) { $text += "  [$Detail]" }
        Write-Log $text 'Red'
        [void]$script:Failures.Add([pscustomobject]@{ Id = $id; Name = $Name; Detail = $Detail })
    }
}

# ---------------------------------------------------------------------------
# Process / network / registry / shortcut helpers
# ---------------------------------------------------------------------------
function Invoke-Program {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Arguments = '',
        [int]$TimeoutSec = 120,
        [string]$WorkingDirectory = ''
    )
    $startArgs = @{ FilePath = $FilePath; PassThru = $true; WindowStyle = 'Hidden' }
    if ($Arguments -ne '') { $startArgs.ArgumentList = $Arguments }
    if ($WorkingDirectory -ne '') { $startArgs.WorkingDirectory = $WorkingDirectory }
    try { $process = Start-Process @startArgs -ErrorAction Stop }
    catch { return [pscustomobject]@{ ExitCode = $null; TimedOut = $false; Seconds = 0; Error = $_.Exception.Message } }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $exited = $process.WaitForExit($TimeoutSec * 1000)
    $sw.Stop()
    if (-not $exited) {
        try { $process.Kill() } catch { }
        return [pscustomobject]@{ ExitCode = $null; TimedOut = $true; Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
    }
    return [pscustomobject]@{ ExitCode = $process.ExitCode; TimedOut = $false; Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
}

function Start-Detached {
    param([string]$FilePath, [string]$Arguments = '', [string]$WorkingDirectory = '')
    $startArgs = @{ FilePath = $FilePath; PassThru = $true; WindowStyle = 'Hidden' }
    if ($Arguments -ne '') { $startArgs.ArgumentList = $Arguments }
    if ($WorkingDirectory -ne '') { $startArgs.WorkingDirectory = $WorkingDirectory }
    try { return (Start-Process @startArgs -ErrorAction Stop) }
    catch { Write-Log ("  Start-Detached failed: {0}" -f $_.Exception.Message) 'Red'; return $null }
}

function Start-VisibleProcess {
    param([string]$FilePath, [string]$Arguments = '')
    $startArgs = @{ FilePath = $FilePath; PassThru = $true }
    if ($Arguments -ne '') { $startArgs.ArgumentList = $Arguments }
    try { return (Start-Process @startArgs -ErrorAction Stop) }
    catch { Write-Log ("  Start-VisibleProcess failed: {0}" -f $_.Exception.Message) 'Red'; return $null }
}

function Get-Health {
    param([int]$Port = $TestHttpPort)
    try {
        $response = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/api/health" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
        if ($response.StatusCode -eq 200 -and $response.Content) { return ($response.Content | ConvertFrom-Json) }
    }
    catch { }
    return $null
}

function Wait-Health {
    param([int]$TimeoutSec = 90, [int]$Port = $TestHttpPort)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $health = Get-Health -Port $Port
        if ($health -and $health.ok -eq $true) { return $health }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

function Wait-HealthGone {
    param([int]$TimeoutSec = 20, [int]$Port = $TestHttpPort)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Health -Port $Port)) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

function Wait-Until {
    param([scriptblock]$Condition, [int]$TimeoutSec = 20)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (& $Condition) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

# Waits for the observable end state of an NSIS silent uninstall (the process
# returns before the temp re-launch has finished deleting files).
function Wait-SilentUninstallComplete {
    param(
        [Parameter(Mandatory)][string]$InstallDir,
        [switch]$KeepData,
        [int]$TimeoutSec = 120
    )
    return (Wait-Until -TimeoutSec $TimeoutSec -Condition {
            $arpGone = -not (Test-Path -LiteralPath $ARP_KEY)
            if ($KeepData) {
                $uninstallerGone = -not (Test-Path -LiteralPath (Join-Path $InstallDir 'Uninstall.exe'))
                $programGone = -not (Test-Path -LiteralPath (Join-Path $InstallDir 'Launch.vbs'))
                $profileGone = -not (Test-Path -LiteralPath (Join-Path $InstallDir 'browser-profile'))
                $dataKept = Test-Path -LiteralPath (Join-Path $InstallDir 'app\data\config.json')
                ($arpGone -and $uninstallerGone -and $programGone -and $profileGone -and $dataKept)
            }
            else {
                ($arpGone -and (-not (Test-Path -LiteralPath $InstallDir)))
            }
        })
}

function Get-NodeProcesses {
    param([string[]]$PathFilters = @())
    $all = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue)
    if ($PathFilters.Count -eq 0) { return $all }
    $matches = @()
    foreach ($proc in $all) {
        $cmd = [string]$proc.CommandLine
        if (-not $cmd) { continue }
        foreach ($filter in $PathFilters) {
            if ($cmd.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $matches += $proc; break }
        }
    }
    return $matches
}

function Stop-NodeProcesses {
    param([string[]]$PathFilters = @())
    $procs = @(Get-NodeProcesses -PathFilters $PathFilters)
    foreach ($proc in $procs) {
        try { Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
    }
    return $procs.Count
}

function Get-BrowserProcesses {
    param([Parameter(Mandatory)][string]$ProfileDir)
    $names = @('msedge.exe', 'chrome.exe')
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $names -contains $_.Name -and $_.CommandLine -and
            ($_.CommandLine.IndexOf($ProfileDir, [StringComparison]::OrdinalIgnoreCase) -ge 0)
        })
}

function Stop-BrowserProcesses {
    param([Parameter(Mandatory)][string]$ProfileDir)
    $procs = @(Get-BrowserProcesses -ProfileDir $ProfileDir)
    foreach ($proc in $procs) { try { Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
    return $procs.Count
}

# Kills every process whose command line references the profile directory
# (browser, renderer, crashpad handler, ...) and waits until they are gone.
# Without this the profile keeps file locks and the uninstaller cannot remove it.
function Stop-ProfileProcesses {
    param([Parameter(Mandatory)][string]$ProfileDir, [int]$TimeoutSec = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
                $_.CommandLine -and
                ($_.CommandLine.IndexOf($ProfileDir, [StringComparison]::OrdinalIgnoreCase) -ge 0) -and
                (@('powershell.exe', 'pwsh.exe', 'explorer.exe') -notcontains $_.Name)
            })
        if ($procs.Count -eq 0) { return $true }
        foreach ($proc in $procs) { try { Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Get-PortListeners {
    param([int[]]$Ports = @($TestHttpPort, $TestHttpsPort))
    $listeners = @()
    foreach ($port in $Ports) {
        $listeners += @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
    }
    return $listeners
}

function Get-RegValue {
    param([string]$Path, [string]$Name)
    try {
        $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        return $item.$Name
    }
    catch { return $null }
}

function Test-RegKey { param([string]$Path) return (Test-Path -LiteralPath $Path) }

function Get-ShortcutInfo {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $shortcut = $script:Wsh.CreateShortcut($Path)
        return [pscustomobject]@{
            Path             = $Path
            TargetPath       = $shortcut.TargetPath
            Arguments        = $shortcut.Arguments
            IconLocation     = $shortcut.IconLocation
            WorkingDirectory = $shortcut.WorkingDirectory
        }
    }
    catch { return $null }
}

function Get-TokenFromData {
    param([string]$InstallDir)
    $configPath = Join-Path $InstallDir 'app\data\config.json'
    if (-not (Test-Path -LiteralPath $configPath)) { return $null }
    try { return [string]((Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json).security.token) }
    catch { return $null }
}

function Read-TextFileUtf8 {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Invoke-ChildCmd {
    # Runs a .cmd with stdin redirected from NUL (so its "pause" returns) and
    # captures combined output to a log file.
    param([string]$CmdPath, [string]$LogPath, [int]$TimeoutSec = 120)
    $wrapper = Join-Path $WorkRoot ('wrap-' + [IO.Path]::GetFileNameWithoutExtension($CmdPath) + '.cmd')
    $text = "@echo off`r`ncall `"$CmdPath`" > `"$LogPath`" 2>&1 < nul`r`nexit /b %ERRORLEVEL%`r`n"
    Set-Content -LiteralPath $wrapper -Value $text -Encoding ascii
    $result = Invoke-Program -FilePath 'cmd.exe' -Arguments "/d /c `"$wrapper`"" -TimeoutSec $TimeoutSec
    return [pscustomobject]@{ ExitCode = $result.ExitCode; Output = (Read-TextFileUtf8 -Path $LogPath) }
}

# Capture the visible app window (used to prove there is no yellow
# "unsupported command-line flag" warning bar).
function Save-AppWindowScreenshot {
    param(
        [Parameter(Mandatory)][string]$ProfileDir,
        [Parameter(Mandatory)][string]$OutPath,
        [int]$TimeoutSec = 60,
        [int]$MinBytes = 20000
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $last = [pscustomobject]@{ Ok = $false; Title = ''; Pid = 0; Path = $OutPath }
    Start-Sleep -Seconds 2
    while ((Get-Date) -lt $deadline) {
        $procs = @(Get-BrowserProcesses -ProfileDir $ProfileDir)
        foreach ($proc in $procs) {
            try {
                $p = Get-Process -Id $proc.ProcessId -ErrorAction Stop
                $p.Refresh()
                $title = [string]$p.MainWindowTitle
                if ($p.MainWindowHandle -ne 0 -and $title -like '*Hey Logan*') {
                    if ([HLSnap]::Save($p.MainWindowHandle, $OutPath)) {
                        $size = 0
                        try { $size = (Get-Item -LiteralPath $OutPath).Length } catch { }
                        $last = [pscustomobject]@{ Ok = $true; Title = $title; Pid = $proc.ProcessId; Path = $OutPath; Bytes = $size }
                        if ($size -ge $MinBytes) { return $last }
                    }
                }
            }
            catch { }
        }
        Start-Sleep -Milliseconds 1000
    }
    return $last
}

# ---------------------------------------------------------------------------
# USER STATE backup / restore (the real installation at D:\HeyLoganAI)
# ---------------------------------------------------------------------------
$script:UserState = $null

function Backup-UserState {
    if (Test-Path -LiteralPath $stateBackup) { Remove-Item -LiteralPath $stateBackup -Recurse -Force }
    New-Item -ItemType Directory -Path (Join-Path $stateBackup 'startmenu') -Force | Out-Null
    $dFiles = @(Get-ChildItem -LiteralPath $UserInstallDir -Recurse -File -Force -ErrorAction SilentlyContinue)
    $state = [pscustomobject]@{
        arpExisted           = (Test-RegKey $ARP_KEY)
        appKeyExisted        = (Test-RegKey $APP_KEY)
        runExisted           = ($null -ne (Get-RegValue $RUN_KEY $RUN_NAME))
        runValue             = [string](Get-RegValue $RUN_KEY $RUN_NAME)
        smExisted            = (Test-Path -LiteralPath $SM_DIR)
        desktopExisted       = (Test-Path -LiteralPath $DESKTOP_LNK)
        userInstallExisted   = (Test-Path -LiteralPath $UserInstallDir)
        userInstallFileCount = $dFiles.Count
        userInstallBytes     = [long](($dFiles | Measure-Object Length -Sum).Sum)
        userPid              = $null
        pwaArpExisted        = (Test-RegKey $EDGE_PWA_ARP)
    }
    if ($state.arpExisted) { & reg.exe export $ARP_KEY.Replace('HKCU:\', 'HKCU\') (Join-Path $stateBackup 'arp.reg') /y | Out-Null }
    if ($state.appKeyExisted) { & reg.exe export $APP_KEY.Replace('HKCU:\', 'HKCU\') (Join-Path $stateBackup 'appkey.reg') /y | Out-Null }
    if ($state.smExisted) { Copy-Item -LiteralPath $SM_DIR -Destination (Join-Path $stateBackup 'startmenu\Hey Logan AI') -Recurse -Force }
    if ($state.desktopExisted) { Copy-Item -LiteralPath $DESKTOP_LNK -Destination (Join-Path $stateBackup 'desktop.lnk') -Force }
    $listen = @(Get-NetTCPConnection -LocalPort 8787 -State Listen -ErrorAction SilentlyContinue)
    if ($listen.Count -gt 0) { $state.userPid = $listen[0].OwningProcess }
    $script:UserState = $state
    return $state
}

function Restore-UserState {
    if (-not $script:UserState) { return }
    $state = $script:UserState
    Write-Log '  restoring the real user installation state...' 'DarkYellow'

    [void](Stop-NodeProcesses -PathFilters @($scratchA, $scratchB, $scratchC, $oldTree, $portableDir, $WorkRoot))
    foreach ($profile in @((Join-Path $scratchA 'browser-profile'), (Join-Path $scratchB 'browser-profile'), (Join-Path $scratchC 'browser-profile'), (Join-Path $oldTree 'browser-profile'), (Join-Path $portableDir 'browser-profile'))) {
        [void](Stop-ProfileProcesses -ProfileDir $profile -TimeoutSec 15)
    }

    Remove-Item -LiteralPath $ARP_KEY -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $APP_KEY -Recurse -Force -ErrorAction SilentlyContinue
    if ($state.arpExisted) { & reg.exe import (Join-Path $stateBackup 'arp.reg') | Out-Null }
    if ($state.appKeyExisted) { & reg.exe import (Join-Path $stateBackup 'appkey.reg') | Out-Null }

    if ($state.runExisted) {
        # PowerShell registry API keeps the exact string (including the quotes
        # around wscript.exe and Launch.vbs); reg.exe add would strip them.
        if (-not (Test-Path -LiteralPath $RUN_KEY)) { New-Item -Path $RUN_KEY -Force | Out-Null }
        New-ItemProperty -LiteralPath $RUN_KEY -Name $RUN_NAME -Value $state.runValue -PropertyType String -Force | Out-Null
    }
    else {
        Remove-ItemProperty -LiteralPath $RUN_KEY -Name $RUN_NAME -Force -ErrorAction SilentlyContinue
    }

    Remove-Item -LiteralPath $SM_DIR -Recurse -Force -ErrorAction SilentlyContinue
    if ($state.smExisted) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $SM_DIR) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $stateBackup 'startmenu\Hey Logan AI') -Destination $SM_DIR -Recurse -Force
    }
    Remove-Item -LiteralPath $DESKTOP_LNK -Force -ErrorAction SilentlyContinue
    if ($state.desktopExisted) { Copy-Item -LiteralPath (Join-Path $stateBackup 'desktop.lnk') -Destination $DESKTOP_LNK -Force }

    foreach ($dir in @($scratchA, $scratchB, $scratchC, $oldTree)) {
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Write-Log '  user state restored.' 'DarkYellow'
}

# ===========================================================================
# MAIN TEST BODY
# ===========================================================================
try {
    # -----------------------------------------------------------------------
    # PHASE 0 - artifacts + environment
    # -----------------------------------------------------------------------
    Write-Section 'PHASE 0 - release artifacts and user state'
    Write-Log ("host      : {0}" -f (Get-CimInstance Win32_OperatingSystem | ForEach-Object { "$($_.Caption) $($_.Version)" }))
    Write-Log ("repo      : {0}" -f $RepoRoot)
    Write-Log ("test ports: {0}/{1} (user's app keeps 8787/8443)" -f $TestHttpPort, $TestHttpsPort)

    foreach ($dir in @($scratchA, $scratchB, $scratchC, $oldTree, (Join-Path $WorkRoot 'portable'), (Join-Path $WorkRoot 'setup'), $stateBackup)) {
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $userState = Backup-UserState
    Add-Check -Name 'User state backed up before tests' -Condition ($null -ne $script:UserState)
    Write-Log ("  user install : {0} ({1} files, {2} bytes)" -f $UserInstallDir, $userState.userInstallFileCount, $userState.userInstallBytes)
    Write-Log ("  user run key : {0}" -f $userState.runValue)
    Write-Log ("  user pid 8787: {0}" -f $userState.userPid)

    Add-Check -Name 'dist Setup.exe (1.1.0) exists' -Condition (Test-Path -LiteralPath $setupDist) -Detail $setupDist
    Add-Check -Name 'dist Portable.zip (1.1.0) exists' -Condition (Test-Path -LiteralPath $zipDist) -Detail $zipDist
    if (-not (Test-Path -LiteralPath $setupDist) -or -not (Test-Path -LiteralPath $zipDist)) { throw 'Required dist artifacts are missing (run windows\installer\build-all.ps1).' }
    $setupHashDist = (Get-FileHash -LiteralPath $setupDist -Algorithm SHA256).Hash.ToLowerInvariant()
    $zipHashDist = (Get-FileHash -LiteralPath $zipDist -Algorithm SHA256).Hash.ToLowerInvariant()
    $setupDistSize = (Get-Item -LiteralPath $setupDist).Length
    $zipDistSize = (Get-Item -LiteralPath $zipDist).Length
    Write-Log ("  setup    : {0} bytes  sha256 {1}" -f $setupDistSize, $setupHashDist)
    Write-Log ("  portable : {0} bytes  sha256 {1}" -f $zipDistSize, $zipHashDist)

    Add-Check -Name 'Setup.exe size > 20 MB' -Condition ($setupDistSize -gt 20MB) -Detail "$setupDistSize bytes"
    Add-Check -Name 'Portable ZIP size > 25 MB' -Condition ($zipDistSize -gt 25MB) -Detail "$zipDistSize bytes"

    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $setupRun) -Force
    Copy-Item -LiteralPath $setupDist -Destination $setupRun -Force
    $setupHashCopy = (Get-FileHash -LiteralPath $setupRun -Algorithm SHA256).Hash.ToLowerInvariant()
    Add-Check -Name 'Setup.exe copied to C:\Temp with identical SHA256' -Condition ($setupHashCopy -eq $setupHashDist) -Detail $setupRun

    $vi = (Get-Item -LiteralPath $setupDist).VersionInfo
    Add-Check -Name 'Setup.exe ProductName is "Hey Logan AI"' -Condition ($vi.ProductName -eq 'Hey Logan AI') -Detail $vi.ProductName
    Add-Check -Name 'Setup.exe FileDescription mentions Hey Logan AI' -Condition ($vi.FileDescription -like '*Hey Logan AI*') -Detail $vi.FileDescription
    Add-Check -Name 'Setup.exe CompanyName is "Hey Logan AI"' -Condition ($vi.CompanyName -eq 'Hey Logan AI') -Detail $vi.CompanyName
    Add-Check -Name 'Setup.exe FileVersion is 1.1.0.x' -Condition ([string]$vi.FileVersion -like '1.1.0*') -Detail $vi.FileVersion
    Add-Check -Name 'Setup.exe ProductVersion is 1.1.0.x' -Condition ([string]$vi.ProductVersion -like '1.1.0*') -Detail $vi.ProductVersion
    Add-Check -Name 'Setup.exe LegalCopyright present' -Condition (-not [string]::IsNullOrWhiteSpace($vi.LegalCopyright)) -Detail $vi.LegalCopyright

    $setupBytes = [System.IO.File]::ReadAllBytes($setupDist)
    $setupAscii = [System.Text.Encoding]::ASCII.GetString($setupBytes)
    $hasAsInvoker = $setupAscii.Contains('requestedExecutionLevel level="asInvoker"')
    $hasRequireAdmin = $setupAscii.Contains('requestedExecutionLevel level="requireAdministrator"')
    $setupAscii = $null; $setupBytes = $null
    Add-Check -Name 'Setup manifest requests asInvoker (no UAC prompt)' -Condition $hasAsInvoker
    Add-Check -Name 'Setup manifest does not request administrator rights' -Condition (-not $hasRequireAdmin)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zipDist)
    try { $zipEntries = @($archive.Entries | ForEach-Object { $_.FullName }) } finally { $archive.Dispose() }
    Add-Check -Name 'Portable ZIP has > 500 entries' -Condition ($zipEntries.Count -gt 500) -Detail "$($zipEntries.Count) entries"
    Add-Check -Name 'Portable ZIP contains README-FIRST.txt' -Condition ($zipEntries -contains 'HeyLoganAI/README-FIRST.txt')
    Add-Check -Name 'Portable ZIP contains "Start Hey Logan AI.cmd"' -Condition ($zipEntries -contains 'HeyLoganAI/Start Hey Logan AI.cmd')
    Add-Check -Name 'Portable ZIP contains runtime/node.exe' -Condition ($zipEntries -contains 'HeyLoganAI/runtime/node.exe')
    Add-Check -Name 'Portable ZIP contains app/server/index.js' -Condition ($zipEntries -contains 'HeyLoganAI/app/server/index.js')
    Add-Check -Name 'Portable ZIP contains Launch.vbs and auto-start helpers' -Condition (($zipEntries -contains 'HeyLoganAI/Launch.vbs') -and ($zipEntries -contains 'HeyLoganAI/Start at Login On.cmd') -and ($zipEntries -contains 'HeyLoganAI/Start at Login Off.cmd'))
    Add-Check -Name 'Portable ZIP ships no app/data' -Condition (-not ($zipEntries | Where-Object { $_ -match '(^|/)app/data/' }))
    Add-Check -Name 'Portable ZIP ships no browser-profile' -Condition (-not ($zipEntries | Where-Object { $_ -match 'browser-profile' }))

    $sigStatus = $null
    try { $sigStatus = (Get-AuthenticodeSignature -FilePath $setupDist).Status } catch { }
    Write-Log ("  Authenticode status: {0} (expected: NotSigned)" -f $sigStatus)

    # -----------------------------------------------------------------------
    # PHASE 1 - baseline: user's live app untouched, test ports free
    # -----------------------------------------------------------------------
    Write-Section 'PHASE 1 - baseline'
    if ($userState.userPid) {
        $alive = Get-Process -Id $userState.userPid -ErrorAction SilentlyContinue
        Add-Check -Name "User's live app still running on 8787 (pid $($userState.userPid))" -Condition ($null -ne $alive)
        $userHealth = Get-Health -Port 8787
        Add-Check -Name "User's live app answers on 8787 (untouched by tests)" -Condition ($null -ne $userHealth) -Detail ($(if ($userHealth) { $userHealth | ConvertTo-Json -Compress } else { 'no response' }))
    }
    Add-Check -Name 'Test ports 8790/8445 are free' -Condition (@(Get-PortListeners).Count -eq 0)
    Add-Check -Name 'No pre-existing scratch install-a' -Condition (-not (Test-Path -LiteralPath $scratchA))
    Add-Check -Name 'User install dir exists and is not ours' -Condition (Test-Path -LiteralPath $UserInstallDir) -Detail $UserInstallDir

    # -----------------------------------------------------------------------
    # PHASE 2a - interactive wizard smoke test
    # -----------------------------------------------------------------------
    Write-Section 'PHASE 2a - interactive wizard starts'
    $wizard = Start-VisibleProcess -FilePath $setupRun
    $wizardOk = $false
    $wizardTitle = ''
    if ($wizard) {
        for ($attempt = 0; $attempt -lt 24; $attempt++) {
            Start-Sleep -Milliseconds 500
            try { $wizard.Refresh() } catch { break }
            if ($wizard.HasExited) { break }
            if ($wizard.MainWindowTitle) {
                $wizardTitle = $wizard.MainWindowTitle
                if ($wizardTitle -like '*Hey Logan AI*') { $wizardOk = $true; break }
            }
        }
        if (-not $wizard.HasExited) { try { Stop-Process -Id $wizard.Id -Force -ErrorAction SilentlyContinue } catch { } }
    }
    Start-Sleep -Milliseconds 800
    Add-Check -Name 'Interactive Setup.exe opens the Modern UI 2 wizard window' -Condition $wizardOk -Detail "window title='$wizardTitle'"
    Add-Check -Name 'Cancelled wizard left no partial install in scratch' -Condition (-not (Test-Path -LiteralPath $scratchA))

    # -----------------------------------------------------------------------
    # PHASE 2 - silent install to a scratch custom dir
    # -----------------------------------------------------------------------
    Write-Section 'PHASE 2 - silent install /S /D=<scratch>'
    $installA = Invoke-Program -FilePath $setupRun -Arguments "/S /D=$scratchA" -TimeoutSec $InstallTimeoutSec
    Add-Check -Name 'Silent install exits 0' -Condition ($installA.ExitCode -eq 0) -Detail ("exit=$($installA.ExitCode) seconds=$($installA.Seconds)")
    Add-Check -Name 'Silent install finished in < 180 s' -Condition ($installA.Seconds -lt 180) -Detail "$($installA.Seconds)s"
    Add-Check -Name 'Install dir created (custom /D scratch)' -Condition (Test-Path -LiteralPath $scratchA) -Detail $scratchA
    Add-Check -Name 'Default LOCALAPPDATA install dir not created' -Condition (-not (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'Programs\HeyLoganAI')))

    $expectedFiles = @(
        'Launch.vbs', 'Start Console.cmd', 'Stop.cmd', 'Pairing.cmd',
        'Allow through Firewall.cmd', 'HELP.txt', 'heylogan.ico', 'Uninstall.exe',
        'Start at Login On.cmd', 'Start at Login Off.cmd',
        'tools\pair.js', 'tools\stop.ps1', 'tools\firewall.ps1',
        'runtime\node.exe', 'app\package.json', 'app\server\index.js',
        'app\public\index.html', 'app\public\app.js', 'app\public\native-voice.js',
        'app\node_modules\selfsigned\index.js', 'app\node_modules\qrcode\package.json'
    )
    $missingInstalled = @()
    foreach ($relative in $expectedFiles) { if (-not (Test-Path -LiteralPath (Join-Path $scratchA $relative) -PathType Leaf)) { $missingInstalled += $relative } }
    Add-Check -Name 'All expected files installed (incl. auto-start helpers)' -Condition ($missingInstalled.Count -eq 0) -Detail ($(if ($missingInstalled.Count) { "missing: $($missingInstalled -join ', ')" } else { 'all present' }))
    Add-Check -Name 'App version in installed package.json is 1.1.0' -Condition (((Get-Content -LiteralPath (Join-Path $scratchA 'app\package.json') -Raw | ConvertFrom-Json).version) -eq '1.1.0')
    Add-Check -Name 'No app\data shipped or pre-created by installer' -Condition (-not (Test-Path -LiteralPath (Join-Path $scratchA 'app\data')))

    # launcher content: the whole point of v1.1.0
    $launchText = Read-TextFileUtf8 -Path (Join-Path $scratchA 'Launch.vbs')
    Add-Check -Name 'Launch.vbs uses a dedicated browser-profile' -Condition ($launchText -like '*browser-profile*')
    Add-Check -Name 'Launch.vbs ships --user-data-dir' -Condition ($launchText -like '*--user-data-dir=*')
    Add-Check -Name 'Launch.vbs ships --no-first-run / --no-default-browser-check' -Condition (($launchText -like '*--no-first-run*') -and ($launchText -like '*--no-default-browser-check*'))
    Add-Check -Name 'Launch.vbs ships --autoplay-policy=no-user-gesture-required' -Condition ($launchText -like '*--autoplay-policy=no-user-gesture-required*')
    Add-Check -Name 'Launch.vbs seeds the microphone permission (media_stream_mic)' -Condition ($launchText -like '*media_stream_mic*')
    Add-Check -Name 'Launch.vbs does NOT ship the unsupported --use-fake-ui-for-media-stream flag' -Condition (-not ($launchText -like '*--use-fake-ui-for-media-stream*'))

    # v1.1.0 QA fixes shipped in the payload
    $swInstalled = Read-TextFileUtf8 -Path (Join-Path $scratchA 'app\public\sw.js')
    Add-Check -Name 'Installed sw.js cache is version-busted (heyai-bridge-v1.1.0)' -Condition ($swInstalled -like '*heyai-bridge-v1.1.0*')
    Add-Check -Name 'Installed sw.js caches /native-voice.js' -Condition ($swInstalled -like '*/native-voice.js*')
    Add-Check -Name 'Installed index.html shows the v1.1.0 version label' -Condition ((Read-TextFileUtf8 (Join-Path $scratchA 'app\public\index.html')) -like '*v1.1.0*')
    Add-Check -Name 'Installed HELP.txt names the 1.1.0 Android APK' -Condition ((Read-TextFileUtf8 (Join-Path $scratchA 'HELP.txt')) -like '*android-1.1.0.apk*')

    # -----------------------------------------------------------------------
    # PHASE 3 - registry entries (test install, restored later)
    # -----------------------------------------------------------------------
    Write-Section 'PHASE 3 - Add/Remove Programs + Run value (test install)'
    Add-Check -Name 'ARP key exists (test install)' -Condition (Test-RegKey $ARP_KEY)
    Add-Check -Name 'ARP DisplayName' -Condition ((Get-RegValue $ARP_KEY 'DisplayName') -eq 'Hey Logan AI') -Detail (Get-RegValue $ARP_KEY 'DisplayName')
    Add-Check -Name 'ARP DisplayVersion 1.1.0' -Condition ((Get-RegValue $ARP_KEY 'DisplayVersion') -eq '1.1.0') -Detail (Get-RegValue $ARP_KEY 'DisplayVersion')
    Add-Check -Name 'ARP Publisher' -Condition ((Get-RegValue $ARP_KEY 'Publisher') -eq 'Hey Logan AI')
    Add-Check -Name 'ARP DisplayIcon points at installed .ico' -Condition ((Get-RegValue $ARP_KEY 'DisplayIcon') -eq (Join-Path $scratchA 'heylogan.ico'))
    Add-Check -Name 'ARP InstallLocation' -Condition ((Get-RegValue $ARP_KEY 'InstallLocation') -eq $scratchA) -Detail (Get-RegValue $ARP_KEY 'InstallLocation')
    $uninstallStr = [string](Get-RegValue $ARP_KEY 'UninstallString')
    $quietStr = [string](Get-RegValue $ARP_KEY 'QuietUninstallString')
    Add-Check -Name 'ARP UninstallString points at Uninstall.exe' -Condition ($uninstallStr -like "*$scratchA\Uninstall.exe*") -Detail $uninstallStr
    Add-Check -Name 'ARP QuietUninstallString has /S' -Condition (($quietStr -like "*$scratchA\Uninstall.exe*") -and ($quietStr -like '*/S*')) -Detail $quietStr
    Add-Check -Name 'ARP EstimatedSize >= 80000 KB' -Condition ([int](Get-RegValue $ARP_KEY 'EstimatedSize') -ge 80000) -Detail (Get-RegValue $ARP_KEY 'EstimatedSize')
    Add-Check -Name 'ARP NoModify/NoRepair = 1/1' -Condition (([int](Get-RegValue $ARP_KEY 'NoModify') -eq 1) -and ([int](Get-RegValue $ARP_KEY 'NoRepair') -eq 1))
    Add-Check -Name 'HKCU\Software\HeyLoganAI Version 1.1.0' -Condition ((Get-RegValue $APP_KEY 'Version') -eq '1.1.0') -Detail (Get-RegValue $APP_KEY 'Version')
    Add-Check -Name 'HKCU\Software\HeyLoganAI InstallDir' -Condition ((Get-RegValue $APP_KEY 'InstallDir') -eq $scratchA)

    $runValue = [string](Get-RegValue $RUN_KEY $RUN_NAME)
    Add-Check -Name 'Start-at-login default ON: HKCU Run value exists' -Condition (-not [string]::IsNullOrWhiteSpace($runValue)) -Detail $runValue
    Add-Check -Name 'Run value points at the NEW install dir Launch.vbs' -Condition (($runValue -like '*wscript.exe*') -and ($runValue -like "*$scratchA\Launch.vbs*")) -Detail $runValue

    # -----------------------------------------------------------------------
    # PHASE 4 - shortcuts
    # -----------------------------------------------------------------------
    Write-Section 'PHASE 4 - shortcuts (incl. Start at Login On/Off)'
    $expectedLnkNames = @('Hey Logan AI.lnk', 'Start Console.lnk', 'Pairing.lnk', 'Stop Server.lnk', 'Allow through Firewall.lnk', 'Start at Login On.lnk', 'Start at Login Off.lnk', 'Uninstall.lnk')
    Add-Check -Name 'Start Menu group "Hey Logan AI" exists' -Condition (Test-Path -LiteralPath $SM_DIR)
    $missingLnk = @()
    foreach ($name in $expectedLnkNames) { if (-not (Test-Path -LiteralPath (Join-Path $SM_DIR $name))) { $missingLnk += $name } }
    Add-Check -Name 'Start Menu group has all 8 shortcuts' -Condition ($missingLnk.Count -eq 0) -Detail ($(if ($missingLnk.Count) { "missing: $($missingLnk -join ', ')" } else { 'all present' }))
    $mainLnk = Get-ShortcutInfo -Path (Join-Path $SM_DIR 'Hey Logan AI.lnk')
    $desktopLnk = Get-ShortcutInfo -Path $DESKTOP_LNK
    Add-Check -Name 'Main shortcut target is wscript.exe' -Condition ($mainLnk -and ([string]$mainLnk.TargetPath -like '*wscript.exe')) -Detail ($(if ($mainLnk) { $mainLnk.TargetPath } else { 'missing' }))
    Add-Check -Name 'Main shortcut args = "<scratch>\Launch.vbs"' -Condition ($mainLnk -and ([string]$mainLnk.Arguments -like "*$scratchA\Launch.vbs*")) -Detail ($(if ($mainLnk) { $mainLnk.Arguments } else { 'missing' }))
    Add-Check -Name 'Main shortcut icon is heylogan.ico' -Condition ($mainLnk -and ([string]$mainLnk.IconLocation -like "*$scratchA\heylogan.ico*"))
    Add-Check -Name 'Desktop shortcut exists and points at the new install' -Condition ($desktopLnk -and ([string]$desktopLnk.Arguments -like "*$scratchA\Launch.vbs*")) -Detail ($(if ($desktopLnk) { $desktopLnk.Arguments } else { 'missing' }))
    $lnkChecks = @(
        @{ Name = 'Start Console.lnk'; Target = 'Start Console.cmd' },
        @{ Name = 'Pairing.lnk'; Target = 'Pairing.cmd' },
        @{ Name = 'Stop Server.lnk'; Target = 'Stop.cmd' },
        @{ Name = 'Allow through Firewall.lnk'; Target = 'Allow through Firewall.cmd' },
        @{ Name = 'Start at Login On.lnk'; Target = 'Start at Login On.cmd' },
        @{ Name = 'Start at Login Off.lnk'; Target = 'Start at Login Off.cmd' },
        @{ Name = 'Uninstall.lnk'; Target = 'Uninstall.exe' }
    )
    foreach ($entry in $lnkChecks) {
        $info = Get-ShortcutInfo -Path (Join-Path $SM_DIR $entry.Name)
        Add-Check -Name ("Shortcut {0} -> {1}" -f $entry.Name, $entry.Target) -Condition ($info -and ([string]$info.TargetPath -like "*$($entry.Target)")) -Detail ($(if ($info) { $info.TargetPath } else { 'missing' }))
    }

    # -----------------------------------------------------------------------
    # PHASE 5 - launch via the exact Run command line: hands-free app window
    # -----------------------------------------------------------------------
    Write-Section 'PHASE 5 - launch via Run value / hands-free app window'
    $runExe = $env:WINDIR + '\System32\wscript.exe'
    $runArgs = '"' + (Join-Path $scratchA 'Launch.vbs') + '"'
    Start-Detached -FilePath $runExe -Arguments $runArgs | Out-Null
    $health = Wait-Health -TimeoutSec $HealthTimeoutSec
    Add-Check -Name 'Health endpoint answers on test port 8790 within 90 s' -Condition ($null -ne $health)
    Add-Check -Name 'Health JSON ok = true' -Condition ($health -and $health.ok -eq $true) -Detail ($(if ($health) { $health | ConvertTo-Json -Compress } else { 'no response' }))
    Add-Check -Name 'Health JSON app = "Hey Logan AI"' -Condition ($health -and $health.app -eq 'Hey Logan AI') -Detail ($(if ($health) { $health.app } else { 'no response' }))
    Add-Check -Name 'Health JSON version = 1.1.0' -Condition ($health -and [string]$health.version -eq '1.1.0') -Detail ($(if ($health) { $health.version } else { 'no response' }))
    Add-Check -Name 'Health JSON requiresToken = true' -Condition ($health -and $health.requiresToken -eq $true)

    $dataDir = Join-Path $scratchA 'app\data'
    Add-Check -Name 'First run created app\data\config.json' -Condition (Test-Path -LiteralPath (Join-Path $dataDir 'config.json'))
    $token = Get-TokenFromData -InstallDir $scratchA
    Add-Check -Name 'Pairing token generated (XXXX-XXXX-XXXX)' -Condition ($token -and $token -match '^[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$') -Detail $token
    Add-Check -Name 'HTTPS certificate created in app\data\certs' -Condition ((Test-Path -LiteralPath (Join-Path $dataDir 'certs\cert.pem')) -and (Test-Path -LiteralPath (Join-Path $dataDir 'certs\key.pem')))

    # server-side hands-free configuration
    try {
        $sessionInfo = Invoke-RestMethod -Uri "$testBaseUrl/api/session-info" -Headers @{ 'x-bridge-token' = $token } -TimeoutSec 5 -ErrorAction Stop
        $wakeJson = $sessionInfo.wake | ConvertTo-Json -Depth 6 -Compress
        $speechJson = $sessionInfo.speech | ConvertTo-Json -Depth 6 -Compress
        Write-Log ("  wake   : {0}" -f $wakeJson)
        Write-Log ("  speech : {0}" -f $speechJson)
        Add-Check -Name 'Server wake word includes "hey logan"' -Condition ($wakeJson -like '*hey logan*') -Detail $wakeJson
        Add-Check -Name 'Server wake.ack is set ("Logan here.")' -Condition (($wakeJson -like '*ack*') -and ($wakeJson -like '*Logan here*')) -Detail $wakeJson
        Add-Check -Name 'Server speech.autoStart is true' -Condition ($sessionInfo.speech.autoStart -eq $true) -Detail $speechJson
    }
    catch {
        Add-Check -Name 'Server wake word includes "hey logan"' -Condition $false -Detail $_.Exception.Message
    }

    # served page/JS contains the hands-free implementation
    try {
        $pageHtml = (Invoke-WebRequest -Uri "$testBaseUrl/" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop).Content
        $appJs = (Invoke-WebRequest -Uri "$testBaseUrl/app.js" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop).Content
        Add-Check -Name 'Served page HTML contains "Hey Logan"' -Condition ($pageHtml -like '*Hey Logan*')
        Add-Check -Name 'Served app.js contains autoStartListening' -Condition ($appJs -like '*autoStartListening*')
        Add-Check -Name 'Served page HTML contains the "Always listen" voice setting' -Condition ($pageHtml -like '*Always listen*')
    }
    catch { Add-Check -Name 'Served page HTML contains "Hey Logan"' -Condition $false -Detail $_.Exception.Message }


    # served service worker must carry the new cache name (cache-bust fix)
    try {
        $swServed = (Invoke-WebRequest -Uri "$testBaseUrl/sw.js" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop).Content
        Add-Check -Name 'Served /sw.js uses cache heyai-bridge-v1.1.0' -Condition ($swServed -like '*heyai-bridge-v1.1.0*')
        Add-Check -Name 'Served /sw.js lists /native-voice.js in its assets' -Condition ($swServed -like '*/native-voice.js*')
    }
    catch { Add-Check -Name 'Served /sw.js uses cache heyai-bridge-v1.1.0' -Condition $false -Detail $_.Exception.Message }

    # /api/command routing: the client posts only the remainder after the wake
    # word, so "ask claude code to ..." must still reach the claude-code agent.
    try {
        $cmdBody = @{ text = 'ask claude code to summarise the repo'; sync = $true; source = 'pc' } | ConvertTo-Json -Compress
        $cmdResp = Invoke-RestMethod -Uri "$testBaseUrl/api/command" -Method Post -Headers @{ 'x-bridge-token' = $token } -ContentType 'application/json' -Body $cmdBody -TimeoutSec 90 -ErrorAction Stop
        Add-Check -Name '/api/command "ask claude code to summarise the repo" routes to claude-code' -Condition ($cmdResp.agentId -eq 'claude-code') -Detail ("agentId=$($cmdResp.agentId) missing=$($cmdResp.missing)")
    }
    catch { Add-Check -Name '/api/command "ask claude code to summarise the repo" routes to claude-code' -Condition $false -Detail $_.Exception.Message }

    # longest default-wake phrase stripped; the rest goes to the Computer agent
    try {
        $cmdBody2 = @{ text = 'hey logan ai open downloads'; sync = $true; source = 'pc' } | ConvertTo-Json -Compress
        $cmdResp2 = Invoke-RestMethod -Uri "$testBaseUrl/api/command" -Method Post -Headers @{ 'x-bridge-token' = $token } -ContentType 'application/json' -Body $cmdBody2 -TimeoutSec 90 -ErrorAction Stop
        Add-Check -Name '/api/command "hey logan ai open downloads" routes to Computer' -Condition ($cmdResp2.agentId -eq 'computer') -Detail ("agentId=$($cmdResp2.agentId)")
    }
    catch { Add-Check -Name '/api/command "hey logan ai open downloads" routes to Computer' -Condition $false -Detail $_.Exception.Message }

    # Exact router result through the installed app (no second Computer execution)
        $routerCheckJs = @'
const path = require('path');
const appDir = process.argv[2];
const { parseCommand } = require(path.join(appDir, 'server', 'router'));
const def = {
  defaultAgent: 'computer',
  defaultWake: ['hey logan', 'hi logan', 'hello logan', 'okay logan', 'hey logan ai'],
  wakeAck: 'Logan here.'
};
const out = {
  claude: parseCommand('ask claude code to summarise the repo', def),
  loganAi: parseCommand('hey logan ai open downloads', def)
};
console.log(JSON.stringify(out));
'@

    $routerCheck = Join-Path $WorkRoot 'router-check.js'
    Set-Content -LiteralPath $routerCheck -Value $routerCheckJs -Encoding ascii
    try {
        $routerRaw = (& (Join-Path $scratchA 'runtime\node.exe') $routerCheck (Join-Path $scratchA 'app') 2>$null | Select-Object -Last 1)
        $router = $routerRaw | ConvertFrom-Json
        Add-Check -Name 'Router unit: "ask claude code to summarise the repo" -> claude-code, task "summarise the repo"' -Condition ($router.claude.agentId -eq 'claude-code' -and $router.claude.task -eq 'summarise the repo') -Detail ("agentId=$($router.claude.agentId) task='$($router.claude.task)'")
        Add-Check -Name 'Router unit: "hey logan ai open downloads" -> defaultWake, task "open downloads", phrase "hey logan ai"' -Condition ($router.loganAi.defaultWake -eq $true -and $router.loganAi.task -eq 'open downloads' -and $router.loganAi.wakePhrase -eq 'hey logan ai') -Detail ("task='$($router.loganAi.task)' wakePhrase='$($router.loganAi.wakePhrase)' defaultWake=$($router.loganAi.defaultWake)")
    }
    catch {
        Add-Check -Name 'Router unit: "ask claude code to summarise the repo" -> claude-code, task "summarise the repo"' -Condition $false -Detail $_.Exception.Message
    }

    # the dedicated-profile browser with the autoplay flag must be running
    $profileA = Join-Path $scratchA 'browser-profile'
    Add-Check -Name 'Launcher created <install>\browser-profile' -Condition (Wait-Until -TimeoutSec 30 -Condition { Test-Path -LiteralPath $profileA }) -Detail $profileA
    $browserProc = $null
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        $candidates = @(Get-BrowserProcesses -ProfileDir $profileA)
        if ($candidates.Count -gt 0) { $browserProc = $candidates[0]; break }
        Start-Sleep -Milliseconds 500
    }
    $browserCmd = if ($browserProc) { [string]$browserProc.CommandLine } else { '' }
    Add-Check -Name 'Chromium app window running with the dedicated profile' -Condition ($browserProc -ne $null) -Detail ($(if ($browserProc) { "$($browserProc.Name) pid=$($browserProc.ProcessId)" } else { 'not found' }))
    Add-Check -Name 'Browser command line contains --user-data-dir=<install>\browser-profile' -Condition ($browserCmd -like "*--user-data-dir=*$profileA*") -Detail ($browserCmd -replace '\s+', ' ')
    Add-Check -Name 'Browser command line contains --autoplay-policy=no-user-gesture-required' -Condition ($browserCmd -like '*--autoplay-policy=no-user-gesture-required*')
    Add-Check -Name 'Browser command line contains --no-first-run / --no-default-browser-check' -Condition (($browserCmd -like '*--no-first-run*') -and ($browserCmd -like '*--no-default-browser-check*'))
    Add-Check -Name 'Browser command line does NOT contain --use-fake-ui-for-media-stream' -Condition (-not ($browserCmd -like '*--use-fake-ui-for-media-stream*'))
    Add-Check -Name 'Browser command line opens the token URL on the test port' -Condition ($browserCmd -like "*--app=$testBaseUrl/?token=*") -Detail ($browserCmd -replace '\s+', ' ')

    # seeded microphone permission (Preferences) for the dedicated profile
    $prefPath = Join-Path $profileA 'Default\Preferences'
    Add-Check -Name 'Launcher seeded browser-profile\Default\Preferences' -Condition (Test-Path -LiteralPath $prefPath) -Detail $prefPath
    $prefText = Read-TextFileUtf8 -Path $prefPath
    Add-Check -Name 'Preferences contain a media_stream_mic grant for this origin' -Condition (($prefText -like '*media_stream_mic*') -and ($prefText -like "*127.0.0.1:$TestHttpPort*"))
    Write-Log ("  preferences: {0}" -f (($prefText -replace '\s+', ' ') -replace '^(.{0,220}).*$', '$1...'))

    # screenshot of the live app window: proves there is no yellow
    # "unsupported command-line flag" warning bar
    $shotPath = Join-Path $repoEvidenceDir 'app-window-1.1.0.png'
    $shot = Save-AppWindowScreenshot -ProfileDir $profileA -OutPath $shotPath -TimeoutSec 75 -MinBytes 20000
    Add-Check -Name 'App window screenshot captured (no warning-bar check)' -Condition ($shot.Ok -and (Test-Path -LiteralPath $shotPath) -and (Get-Item -LiteralPath $shotPath).Length -gt 5000) -Detail ("title='{0}' file={1} bytes" -f $shot.Title, $(if (Test-Path $shotPath) { (Get-Item $shotPath).Length } else { 0 }))
    Add-Check -Name 'App window title is "Hey Logan AI"' -Condition ($shot.Title -like '*Hey Logan AI*') -Detail $shot.Title
    Copy-Item -LiteralPath $shotPath -Destination (Join-Path $evidenceDir 'app-window.png') -Force -ErrorAction SilentlyContinue

    [void](Stop-ProfileProcesses -ProfileDir $profileA -TimeoutSec 30)
    Write-Log '  stopped all test browser/profile processes'
    Start-Sleep -Milliseconds 500

    # -----------------------------------------------------------------------
    # PHASE 6 - Pairing.cmd / Stop.cmd on the test install
    # -----------------------------------------------------------------------
    Write-Section 'PHASE 6 - Pairing.cmd / Stop.cmd'
    $pairingLog = Join-Path $evidenceDir 'pairing-output.txt'
    $pairing = Invoke-ChildCmd -CmdPath (Join-Path $scratchA 'Pairing.cmd') -LogPath $pairingLog
    Copy-Item -LiteralPath $pairingLog -Destination (Join-Path $ReportDir 'pairing-output.txt') -Force -ErrorAction SilentlyContinue
    Add-Check -Name 'Pairing.cmd exits 0' -Condition ($pairing.ExitCode -eq 0) -Detail ("exit=$($pairing.ExitCode)")
    Add-Check -Name 'Pairing.cmd prints the access token' -Condition ($pairing.Output -like '*Access token:*' -and $token -and $pairing.Output.Contains($token))
    $lanMatch = [regex]::Match($pairing.Output, '192\.168\.\d{1,3}\.\d{1,3}')
    Add-Check -Name 'Pairing.cmd shows a 192.168.x.x LAN address' -Condition $lanMatch.Success -Detail ($(if ($lanMatch.Success) { $lanMatch.Value } else { 'not found' }))
    Add-Check -Name 'Pairing.cmd renders a QR code' -Condition (($pairing.Output -like '*Scan this QR code*') -and (($pairing.Output.Contains([char]0x2580)) -or ($pairing.Output.Contains([char]0x2584)) -or ($pairing.Output.Contains([char]0x2588))))
    Add-Check -Name 'Pairing.cmd has the "no camera scanner" footer' -Condition ($pairing.Output -like '*The app has no camera scanner*')

    $stopLog = Join-Path $evidenceDir 'stop-output.txt'
    $stop = Invoke-ChildCmd -CmdPath (Join-Path $scratchA 'Stop.cmd') -LogPath $stopLog
    Copy-Item -LiteralPath $stopLog -Destination (Join-Path $ReportDir 'stop-output.txt') -Force -ErrorAction SilentlyContinue
    Add-Check -Name 'Stop.cmd exits 0' -Condition ($stop.ExitCode -eq 0) -Detail ("exit=$($stop.ExitCode)")
    Add-Check -Name 'Stop.cmd reports the server was stopped' -Condition ($stop.Output -like '*Server stopped*') -Detail ($stop.Output.Trim())
    Add-Check -Name 'Test server is down after Stop.cmd' -Condition (Wait-HealthGone -TimeoutSec 20)
    Add-Check -Name 'No test node process left after Stop.cmd' -Condition (@(Get-NodeProcesses -PathFilters @($scratchA)).Count -eq 0)
    if ($userState.userPid) {
        $alive = Get-Process -Id $userState.userPid -ErrorAction SilentlyContinue
        Add-Check -Name "User's live app untouched by Stop.cmd (pid $($userState.userPid))" -Condition ($null -ne $alive)
    }

    # -----------------------------------------------------------------------
    # PHASE 7 - Start at Login On/Off helpers
    # -----------------------------------------------------------------------
    Write-Section 'PHASE 7 - Start at Login On.cmd / Off.cmd'
    $offLog = Join-Path $evidenceDir 'start-at-login-off.txt'
    $offRun = Invoke-ChildCmd -CmdPath (Join-Path $scratchA 'Start at Login Off.cmd') -LogPath $offLog
    Add-Check -Name 'Start at Login Off.cmd exits 0' -Condition ($offRun.ExitCode -eq 0) -Detail ("exit=$($offRun.ExitCode)")
    Add-Check -Name 'Start at Login Off removes the Run value' -Condition ($null -eq (Get-RegValue $RUN_KEY $RUN_NAME))
    $onLog = Join-Path $evidenceDir 'start-at-login-on.txt'
    $onRun = Invoke-ChildCmd -CmdPath (Join-Path $scratchA 'Start at Login On.cmd') -LogPath $onLog
    Add-Check -Name 'Start at Login On.cmd exits 0' -Condition ($onRun.ExitCode -eq 0) -Detail ("exit=$($onRun.ExitCode)")
    $runAfterOn = [string](Get-RegValue $RUN_KEY $RUN_NAME)
    Add-Check -Name 'Start at Login On writes wscript.exe "<install>\Launch.vbs"' -Condition (($runAfterOn -like '*wscript.exe*') -and ($runAfterOn -like "*$scratchA\Launch.vbs*")) -Detail $runAfterOn

    # -----------------------------------------------------------------------
    # PHASE 8 - upgrade in place keeps app\data + token + certificate
    # -----------------------------------------------------------------------
    Write-Section 'PHASE 8 - upgrade keeps app\data'
    Start-Detached -FilePath $runExe -Arguments $runArgs | Out-Null
    $health = Wait-Health -TimeoutSec $HealthTimeoutSec
    Add-Check -Name 'Server running again before upgrade' -Condition ($null -ne $health)
    $tokenBefore = Get-TokenFromData -InstallDir $scratchA
    $markerPath = Join-Path $dataDir 'e2e-upgrade-marker.txt'
    Set-Content -LiteralPath $markerPath -Value 'marker-before-upgrade' -Encoding ascii
    Add-Content -LiteralPath (Join-Path $scratchA 'app\server\index.js') -Value '// e2e-tampered-program-file'

    $upgrade = Invoke-Program -FilePath $setupRun -Arguments "/S /D=$scratchA" -TimeoutSec $InstallTimeoutSec
    Add-Check -Name 'Upgrade install exits 0' -Condition ($upgrade.ExitCode -eq 0) -Detail ("exit=$($upgrade.ExitCode) seconds=$($upgrade.Seconds)")
    Add-Check -Name 'Upgrade stopped the running server' -Condition (Wait-HealthGone -TimeoutSec 20)
    Add-Check -Name 'Upgrade replaced program files (tamper marker gone)' -Condition (-not ((Read-TextFileUtf8 (Join-Path $scratchA 'app\server\index.js')) -like '*e2e-tampered-program-file*'))
    Add-Check -Name 'Upgrade kept the access token' -Condition ((Get-TokenFromData -InstallDir $scratchA) -eq $tokenBefore) -Detail "before=$tokenBefore after=$(Get-TokenFromData -InstallDir $scratchA)"
    Add-Check -Name 'Upgrade kept app\data marker file' -Condition ((Test-Path -LiteralPath $markerPath) -and ((Read-TextFileUtf8 $markerPath) -like '*marker-before-upgrade*'))
    Add-Check -Name 'Upgrade kept the HTTPS certificate' -Condition ((Test-Path -LiteralPath (Join-Path $dataDir 'certs\cert.pem')) -and (Test-Path -LiteralPath (Join-Path $dataDir 'certs\key.pem')))
    Add-Check -Name 'Upgrade kept ARP entry' -Condition (Test-RegKey $ARP_KEY)
    Add-Check -Name 'Upgrade kept Run value' -Condition ([string](Get-RegValue $RUN_KEY $RUN_NAME) -like "*$scratchA\Launch.vbs*")
    # The Phase 8 Launch.vbs opened an app window too; close it (and any
    # crashpad helper) so the browser-profile is not locked for the uninstall.
    [void](Stop-ProfileProcesses -ProfileDir $profileA -TimeoutSec 30)
    Start-Sleep -Milliseconds 500

    # -----------------------------------------------------------------------
    # PHASE 8a - data-loss guard: locked app\data must abort, not delete
    # -----------------------------------------------------------------------
    Write-Section 'PHASE 8a - data-loss guard (locked app\data)'
    $configPath = Join-Path $dataDir 'config.json'
    $lockStream = $null
    $blocked = $null
    try {
        $lockStream = [System.IO.File]::Open($configPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $blocked = Invoke-Program -FilePath $setupRun -Arguments "/S /D=$scratchA" -TimeoutSec 120
    }
    catch { Write-Log ("  data-lock simulation could not be set up: {0}" -f $_.Exception.Message) 'Yellow' }
    finally { if ($lockStream) { $lockStream.Close(); $lockStream.Dispose() } }
    Add-Check -Name 'Upgrade aborts (non-zero exit) when app\data cannot be stashed' -Condition ($blocked -and $null -ne $blocked.ExitCode -and $blocked.ExitCode -ne 0) -Detail ($(if ($blocked) { "exit=$($blocked.ExitCode)" } else { 'not run' }))
    Add-Check -Name 'Aborted upgrade kept the access token' -Condition ((Get-TokenFromData -InstallDir $scratchA) -eq $tokenBefore)
    Add-Check -Name 'Aborted upgrade kept the HTTPS certificate' -Condition (Test-Path -LiteralPath (Join-Path $dataDir 'certs\cert.pem'))
    Add-Check -Name 'Aborted upgrade did not delete program files' -Condition (Test-Path -LiteralPath (Join-Path $scratchA 'Launch.vbs'))
    Add-Check -Name 'Aborted upgrade left no .hl-data-keep stash' -Condition (-not (Test-Path -LiteralPath (Join-Path $scratchA '.hl-data-keep')))
    $retryUpgrade = Invoke-Program -FilePath $setupRun -Arguments "/S /D=$scratchA" -TimeoutSec $InstallTimeoutSec
    Add-Check -Name 'Upgrade succeeds normally once the lock is released' -Condition ($retryUpgrade.ExitCode -eq 0) -Detail ("exit=$($retryUpgrade.ExitCode)")
    Add-Check -Name 'Token still unchanged after the retry upgrade' -Condition ((Get-TokenFromData -InstallDir $scratchA) -eq $tokenBefore)

    # -----------------------------------------------------------------------
    # PHASE 9 - uninstall keep-data: token+cert survive, only app\data left
    # -----------------------------------------------------------------------
    Write-Section 'PHASE 9 - uninstall keep-data (Uninstall.exe /S)'
    $keepRun = Invoke-Program -FilePath (Join-Path $scratchA 'Uninstall.exe') -Arguments '/S' -TimeoutSec $InstallTimeoutSec
    Add-Check -Name 'Uninstall (keep data) exits 0' -Condition ($keepRun.ExitCode -eq 0) -Detail ("exit=$($keepRun.ExitCode) seconds=$($keepRun.Seconds)")
    $keepCompleted = Wait-SilentUninstallComplete -InstallDir $scratchA -KeepData -TimeoutSec 120
    Add-Check -Name 'Keep-data uninstall completed' -Condition $keepCompleted
    Add-Check -Name 'Uninstall removed ARP entry' -Condition (-not (Test-RegKey $ARP_KEY))
    Add-Check -Name 'Uninstall removed Run value' -Condition ($null -eq (Get-RegValue $RUN_KEY $RUN_NAME))
    Add-Check -Name 'Uninstall removed Start Menu group' -Condition (-not (Test-Path -LiteralPath $SM_DIR))
    Add-Check -Name 'Uninstall removed Desktop shortcut' -Condition (-not (Test-Path -LiteralPath $DESKTOP_LNK))
    Add-Check -Name 'Uninstall removed Uninstall.exe and browser-profile' -Condition ((-not (Test-Path -LiteralPath (Join-Path $scratchA 'Uninstall.exe'))) -and (-not (Test-Path -LiteralPath (Join-Path $scratchA 'browser-profile'))))
    $leftovers = @(Get-ChildItem -LiteralPath $scratchA -Recurse -Force -ErrorAction SilentlyContinue)
    $dataPrefix = Join-Path $scratchA 'app\data'
    $appDirPath = Join-Path $scratchA 'app'
    $outsideData = @($leftovers | Where-Object { $_.FullName -notlike "$dataPrefix*" -and $_.FullName -ne $scratchA -and $_.FullName -ne $appDirPath })
    Add-Check -Name 'Only app\data left in the install folder' -Condition (($leftovers.Count -gt 0) -and ($outsideData.Count -eq 0)) -Detail ("{0} item(s), {1} outside app\data" -f $leftovers.Count, $outsideData.Count)
    Add-Check -Name 'Kept token survives the keep-data uninstall' -Condition ((Get-TokenFromData -InstallDir $scratchA) -eq $tokenBefore) -Detail (Get-TokenFromData -InstallDir $scratchA)
    Add-Check -Name 'Kept certificate survives the keep-data uninstall' -Condition (Test-Path -LiteralPath (Join-Path $dataDir 'certs\cert.pem'))

    # -----------------------------------------------------------------------
    # PHASE 10 - reinstall over kept data, then purge uninstall
    # -----------------------------------------------------------------------
    Write-Section 'PHASE 10 - reinstall over kept data + purge'
    $reinstall = Invoke-Program -FilePath $setupRun -Arguments "/S /D=$scratchA" -TimeoutSec $InstallTimeoutSec
    Add-Check -Name 'Reinstall over kept app\data exits 0' -Condition ($reinstall.ExitCode -eq 0)
    Add-Check -Name 'Reinstall preserved the token' -Condition ((Get-TokenFromData -InstallDir $scratchA) -eq $tokenBefore)
    $purgeRun = Invoke-Program -FilePath (Join-Path $scratchA 'Uninstall.exe') -Arguments '/S /PURGEDATA' -TimeoutSec $InstallTimeoutSec
    Add-Check -Name 'Silent purge uninstall exits 0' -Condition ($purgeRun.ExitCode -eq 0)
    Add-Check -Name 'Purge uninstall removed the whole install folder' -Condition (Wait-SilentUninstallComplete -InstallDir $scratchA -TimeoutSec 120)

    # -----------------------------------------------------------------------
    # PHASE 12 - /D= still wins over the registered upgrade location
    # -----------------------------------------------------------------------
    Write-Section 'PHASE 12 - /D= wins over the registered install location'
    $installA = Invoke-Program -FilePath $setupRun -Arguments "/S /D=$scratchA" -TimeoutSec $InstallTimeoutSec
    Add-Check -Name 'Reinstall A exits 0 (ARP now points at A)' -Condition ($installA.ExitCode -eq 0)
    $installB = Invoke-Program -FilePath $setupRun -Arguments "/S /D=$scratchB" -TimeoutSec $InstallTimeoutSec
    Add-Check -Name 'Install with explicit /D=<other dir> exits 0' -Condition ($installB.ExitCode -eq 0)
    Add-Check -Name 'ARP InstallLocation is the /D target' -Condition ((Get-RegValue $ARP_KEY 'InstallLocation') -eq $scratchB) -Detail (Get-RegValue $ARP_KEY 'InstallLocation')
    Add-Check -Name 'Run value points at the /D target Launch.vbs' -Condition ([string](Get-RegValue $RUN_KEY $RUN_NAME) -like "*$scratchB\Launch.vbs*")
    Add-Check -Name 'ARP-target A was not deleted by the /D run' -Condition ((Test-Path -LiteralPath (Join-Path $scratchA 'Launch.vbs')))
    $purgeB = Invoke-Program -FilePath (Join-Path $scratchB 'Uninstall.exe') -Arguments '/S /PURGEDATA' -TimeoutSec $InstallTimeoutSec
    Add-Check -Name 'Uninstall B exits 0' -Condition ($purgeB.ExitCode -eq 0)
    Add-Check -Name 'Uninstall B removed its folder' -Condition (Wait-SilentUninstallComplete -InstallDir $scratchB -TimeoutSec 120)
    # B's uninstall removed the shared registration. Re-register A through the
    # product itself (Setup.exe over the same folder) so A can then be removed
    # through its own ARP entry - exactly the normal user path.
    $registerA = Invoke-Program -FilePath $setupRun -Arguments "/S /D=$scratchA" -TimeoutSec $InstallTimeoutSec
    Add-Check -Name 'Re-register A through Setup exits 0' -Condition ($registerA.ExitCode -eq 0)
    Add-Check -Name 'A is registered again as the install location' -Condition ((Get-RegValue $ARP_KEY 'InstallLocation') -eq $scratchA) -Detail (Get-RegValue $ARP_KEY 'InstallLocation')
    $purgeA = Invoke-Program -FilePath (Join-Path $scratchA 'Uninstall.exe') -Arguments '/S /PURGEDATA' -TimeoutSec $InstallTimeoutSec
    Add-Check -Name 'Uninstall A exits 0' -Condition ($purgeA.ExitCode -eq 0)
    Add-Check -Name 'Uninstall A removed its folder' -Condition (Wait-SilentUninstallComplete -InstallDir $scratchA -TimeoutSec 120)

    # -----------------------------------------------------------------------
    # PHASE 12a - /NOAUTOSTART
    # -----------------------------------------------------------------------
    Write-Section 'PHASE 12a - /S /NOAUTOSTART /D='
    $noAuto = Invoke-Program -FilePath $setupRun -Arguments "/S /NOAUTOSTART /D=$scratchC" -TimeoutSec $InstallTimeoutSec
    Add-Check -Name '/S /NOAUTOSTART /D= install exits 0' -Condition ($noAuto.ExitCode -eq 0)
    Add-Check -Name '/NOAUTOSTART install wrote files to the /D path' -Condition (Test-Path -LiteralPath (Join-Path $scratchC 'Launch.vbs'))
    Add-Check -Name '/NOAUTOSTART leaves no HKCU Run value' -Condition ($null -eq (Get-RegValue $RUN_KEY $RUN_NAME))
    Add-Check -Name '/NOAUTOSTART still creates Start Menu shortcuts' -Condition (Test-Path -LiteralPath (Join-Path $SM_DIR 'Start at Login On.lnk'))
    $purgeC = Invoke-Program -FilePath (Join-Path $scratchC 'Uninstall.exe') -Arguments '/S /PURGEDATA' -TimeoutSec $InstallTimeoutSec
    Add-Check -Name '/NOAUTOSTART test uninstall exits 0' -Condition ($purgeC.ExitCode -eq 0)
    Add-Check -Name '/NOAUTOSTART test install removed cleanly' -Condition (Wait-SilentUninstallComplete -InstallDir $scratchC -TimeoutSec 120)

    # -----------------------------------------------------------------------
    # PHASE 13 - upgrade-in-place via ARP InstallLocation (no /D=)
    #            = the user's D:\HeyLoganAI scenario, simulated safely
    # -----------------------------------------------------------------------
    Write-Section 'PHASE 13 - upgrade-in-place via ARP InstallLocation (no /D=)'
    if (Test-Path -LiteralPath $oldTree) { Remove-Item -LiteralPath $oldTree -Recurse -Force }
    $payloadSource = Join-Path $RepoRoot 'windows\payload\HeyLoganAI'
    Copy-Item -LiteralPath $payloadSource -Destination $oldTree -Recurse -Force
    New-Item -ItemType Directory -Path (Join-Path $oldTree 'app\data\certs') -Force | Out-Null
    $fakeToken = 'OLDTEST-AAAA-BBBB'
    $fakeConfig = @{ security = @{ token = $fakeToken }; app = @{ name = 'Hey Logan AI'; version = '1.0.0' } } | ConvertTo-Json -Depth 5
    Set-Content -LiteralPath (Join-Path $oldTree 'app\data\config.json') -Value $fakeConfig -Encoding ascii
    Set-Content -LiteralPath (Join-Path $oldTree 'app\data\certs\cert.pem') -Value 'fake-old-cert' -Encoding ascii
    Remove-Item -LiteralPath $APP_KEY -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ARP_KEY -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -Path $ARP_KEY -Force | Out-Null
    Set-ItemProperty -LiteralPath $ARP_KEY -Name 'DisplayName' -Value 'Hey Logan AI'
    Set-ItemProperty -LiteralPath $ARP_KEY -Name 'DisplayVersion' -Value '1.0.0'
    Set-ItemProperty -LiteralPath $ARP_KEY -Name 'InstallLocation' -Value $oldTree
    Set-ItemProperty -LiteralPath $ARP_KEY -Name 'UninstallString' -Value ('"' + (Join-Path $oldTree 'Uninstall.exe') + '"')
    $defaultInstallDir = Join-Path $env:LOCALAPPDATA 'Programs\HeyLoganAI'
    $upgradeNoD = Invoke-Program -FilePath $setupRun -Arguments '/S' -TimeoutSec $InstallTimeoutSec
    Add-Check -Name 'Installer with NO /D= uses ARP InstallLocation (installs into old tree)' -Condition ($upgradeNoD.ExitCode -eq 0 -and (Test-Path -LiteralPath (Join-Path $oldTree 'Launch.vbs'))) -Detail ("exit=$($upgradeNoD.ExitCode)")
    Add-Check -Name 'Upgrade-in-place did NOT create the default LOCALAPPDATA copy' -Condition (-not (Test-Path -LiteralPath $defaultInstallDir))
    Add-Check -Name 'ARP InstallLocation stayed the old tree' -Condition ((Get-RegValue $ARP_KEY 'InstallLocation') -eq $oldTree) -Detail (Get-RegValue $ARP_KEY 'InstallLocation')
    Add-Check -Name 'Upgrade-in-place preserved the fake token' -Condition ((Get-TokenFromData -InstallDir $oldTree) -eq $fakeToken) -Detail (Get-TokenFromData -InstallDir $oldTree)
    Add-Check -Name 'Upgrade-in-place replaced Launch.vbs with the v1.1.0 (browser-profile) one' -Condition ((Read-TextFileUtf8 -Path (Join-Path $oldTree 'Launch.vbs')) -like '*browser-profile*')
    Add-Check -Name 'Run value points at the upgraded old tree' -Condition ([string](Get-RegValue $RUN_KEY $RUN_NAME) -like "*$oldTree\Launch.vbs*") -Detail (Get-RegValue $RUN_KEY $RUN_NAME)
    Add-Check -Name 'ARP DisplayVersion is now 1.1.0' -Condition ((Get-RegValue $ARP_KEY 'DisplayVersion') -eq '1.1.0')
    $purgeOld = Invoke-Program -FilePath (Join-Path $oldTree 'Uninstall.exe') -Arguments '/S /PURGEDATA' -TimeoutSec $InstallTimeoutSec
    Add-Check -Name 'Uninstall of the upgraded old tree exits 0' -Condition ($purgeOld.ExitCode -eq 0)
    Add-Check -Name 'Upgraded old tree removed' -Condition (Wait-SilentUninstallComplete -InstallDir $oldTree -TimeoutSec 120)

    # -----------------------------------------------------------------------
    # PHASE 14 - portable ZIP: launcher flags + server + no registry writes
    # -----------------------------------------------------------------------
    Write-Section 'PHASE 14 - portable ZIP'
    $portableParent = Join-Path $WorkRoot 'portable'
    if (Test-Path -LiteralPath $portableParent) { Remove-Item -LiteralPath $portableParent -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $portableParent -Force
    $tar = Join-Path $env:WINDIR 'System32\tar.exe'
    $extract = Invoke-Program -FilePath $tar -Arguments ("-xf `"{0}`" -C `"{1}`"" -f $zipDist, $portableParent) -TimeoutSec 180
    Add-Check -Name 'Portable ZIP extracts' -Condition ($extract.ExitCode -eq 0)
    Add-Check -Name 'Portable README-FIRST.txt present' -Condition (Test-Path -LiteralPath (Join-Path $portableDir 'README-FIRST.txt'))
    Add-Check -Name 'Portable launch/auto-start helpers present' -Condition ((Test-Path -LiteralPath (Join-Path $portableDir 'Launch.vbs')) -and (Test-Path -LiteralPath (Join-Path $portableDir 'Start at Login On.cmd')) -and (Test-Path -LiteralPath (Join-Path $portableDir 'Start at Login Off.cmd')))
    $portableLaunch = Read-TextFileUtf8 -Path (Join-Path $portableDir 'Launch.vbs')
    Add-Check -Name 'Portable Launch.vbs has the dedicated-profile + autoplay recipe' -Condition (($portableLaunch -like '*browser-profile*') -and ($portableLaunch -like '*media_stream_mic*') -and ($portableLaunch -like '*--autoplay-policy=no-user-gesture-required*') -and ($portableLaunch -like '*--no-first-run*') -and ($portableLaunch -like '*--no-default-browser-check*'))
    Add-Check -Name 'Portable Launch.vbs has no fake-ui flag' -Condition (-not ($portableLaunch -like '*--use-fake-ui-for-media-stream*'))
    Add-Check -Name 'Portable extraction ships no app\data / browser-profile' -Condition ((-not (Test-Path -LiteralPath (Join-Path $portableDir 'app\data'))) -and (-not (Test-Path -LiteralPath (Join-Path $portableDir 'browser-profile'))))

    $arpBeforePortable = (Get-RegValue $ARP_KEY 'InstallLocation')
    $runBeforePortable = [string](Get-RegValue $RUN_KEY $RUN_NAME)
    $smBeforePortable = (Test-Path -LiteralPath $SM_DIR)

    $portableNode = Join-Path $portableDir 'runtime\node.exe'
    $portableEntry = Join-Path $portableDir 'app\server\index.js'
    Start-Detached -FilePath $portableNode -Arguments ("`"{0}`"" -f $portableEntry) -WorkingDirectory (Join-Path $portableDir 'app') | Out-Null
    $portableHealth = Wait-Health -TimeoutSec $HealthTimeoutSec
    Add-Check -Name 'Portable server health ok' -Condition ($portableHealth -and $portableHealth.ok -eq $true) -Detail ($(if ($portableHealth) { $portableHealth | ConvertTo-Json -Compress } else { 'no response' }))
    Add-Check -Name 'Portable server reports "Hey Logan AI" 1.1.0' -Condition ($portableHealth -and $portableHealth.app -eq 'Hey Logan AI' -and [string]$portableHealth.version -eq '1.1.0')
    Add-Check -Name 'Portable created its own app\data' -Condition (Test-Path -LiteralPath (Join-Path $portableDir 'app\data\config.json'))
    $portableStop = Invoke-ChildCmd -CmdPath (Join-Path $portableDir 'Stop.cmd') -LogPath (Join-Path $evidenceDir 'portable-stop.txt')
    Add-Check -Name 'Portable Stop.cmd exits 0 and stops the server' -Condition ($portableStop.ExitCode -eq 0 -and (Wait-HealthGone -TimeoutSec 20))
    Add-Check -Name 'Portable run created no registry/shortcut changes' -Condition (((Get-RegValue $ARP_KEY 'InstallLocation') -eq $arpBeforePortable) -and ([string](Get-RegValue $RUN_KEY $RUN_NAME) -eq $runBeforePortable) -and ((Test-Path -LiteralPath $SM_DIR) -eq $smBeforePortable))

    # the portable Launch.vbs must also start server+browser with the recipe
    $portableProfile = Join-Path $portableDir 'browser-profile'
    Start-Detached -FilePath $runExe -Arguments ('"' + (Join-Path $portableDir 'Launch.vbs') + '"') | Out-Null
    $portableHealth2 = Wait-Health -TimeoutSec $HealthTimeoutSec
    Add-Check -Name 'Portable Launch.vbs starts the server' -Condition ($null -ne $portableHealth2)
    Add-Check -Name 'Portable Launch.vbs created its browser-profile' -Condition (Wait-Until -TimeoutSec 30 -Condition { Test-Path -LiteralPath $portableProfile })
    Add-Check -Name 'Portable Launch.vbs seeded the mic permission Preferences' -Condition (Wait-Until -TimeoutSec 30 -Condition { Test-Path -LiteralPath (Join-Path $portableProfile 'Default\Preferences') })
    $portableBrowser = $null
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        $candidates = @(Get-BrowserProcesses -ProfileDir $portableProfile)
        if ($candidates.Count -gt 0) { $portableBrowser = $candidates[0]; break }
        Start-Sleep -Milliseconds 500
    }
    $portableBrowserCmd = if ($portableBrowser) { [string]$portableBrowser.CommandLine } else { '' }
    Add-Check -Name 'Portable browser runs with the new flags (no fake-ui)' -Condition (($portableBrowserCmd -like "*--user-data-dir=*$portableProfile*") -and ($portableBrowserCmd -like '*--autoplay-policy=no-user-gesture-required*') -and (-not ($portableBrowserCmd -like '*--use-fake-ui-for-media-stream*')))
    [void](Stop-ProfileProcesses -ProfileDir $portableProfile -TimeoutSec 30)
    $null = Invoke-Program -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -Arguments ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $portableDir 'tools\stop.ps1')) -TimeoutSec 60
    Add-Check -Name 'Portable server stopped after browser test' -Condition (Wait-HealthGone -TimeoutSec 20)
    if (Test-Path -LiteralPath $portableParent) { Remove-Item -LiteralPath $portableParent -Recurse -Force -ErrorAction SilentlyContinue }
}
catch {
    Add-Check -Name 'E2E completed without a fatal exception' -Condition $false -Detail $_.Exception.Message
    Write-Log ("FATAL: {0}" -f $_.Exception.Message) 'Red'
}
finally {
    # -----------------------------------------------------------------------
    # PHASE 15 - restore the real user installation state and verify it
    # -----------------------------------------------------------------------
    Write-Section 'PHASE 15 - restore user state and final checks'
    Restore-UserState
    Start-Sleep -Milliseconds 800

    if ($script:UserState) {
        $state = $script:UserState
        $arpRestored = $true
        if ($state.arpExisted) {
            $arpRestored = (Test-RegKey $ARP_KEY) -and ((Get-RegValue $ARP_KEY 'InstallLocation') -eq $UserInstallDir) -and ((Get-RegValue $ARP_KEY 'DisplayVersion') -eq '1.0.0')
        }
        else { $arpRestored = -not (Test-RegKey $ARP_KEY) }
        Add-Check -Name 'User ARP entry restored to the D:\ install' -Condition $arpRestored -Detail (Get-RegValue $ARP_KEY 'InstallLocation')
        $runRestored = ([string](Get-RegValue $RUN_KEY $RUN_NAME) -eq $state.runValue)
        Add-Check -Name 'User Run value restored byte-for-byte' -Condition $runRestored -Detail (Get-RegValue $RUN_KEY $RUN_NAME)
        Add-Check -Name 'User Start Menu group restored' -Condition ((Test-Path -LiteralPath $SM_DIR) -eq $state.smExisted)
        if ($state.smExisted) {
            $smFiles = @(Get-ChildItem -LiteralPath $SM_DIR -File -ErrorAction SilentlyContinue)
            Add-Check -Name 'User Start Menu group has its 6 original shortcuts' -Condition ($smFiles.Count -eq 6) -Detail "$($smFiles.Count) shortcuts"
        }
        Add-Check -Name 'User Desktop shortcut restored' -Condition ((Test-Path -LiteralPath $DESKTOP_LNK) -eq $state.desktopExisted)

        $dFileCount = @(Get-ChildItem -LiteralPath $UserInstallDir -Recurse -File -Force -ErrorAction SilentlyContinue).Count
        Add-Check -Name 'D:\HeyLoganAI untouched (file count unchanged)' -Condition ($dFileCount -eq $state.userInstallFileCount) -Detail "$dFileCount vs $($state.userInstallFileCount)"
        if ($state.userPid) {
            $alive = Get-Process -Id $state.userPid -ErrorAction SilentlyContinue
            Add-Check -Name "User's live app still running on 8787 (pid $($state.userPid))" -Condition ($null -ne $alive)
            Add-Check -Name "User's live app still answers on 8787" -Condition ($null -ne (Get-Health -Port 8787)) -Detail 'untouched'
            $edgeListen = @(Get-NetTCPConnection -LocalPort 8787 -State Listen -ErrorAction SilentlyContinue)
            Add-Check -Name 'Port 8787 still owned by the user process' -Condition ($edgeListen.Count -gt 0 -and $edgeListen[0].OwningProcess -eq $state.userPid)
        }
        Add-Check -Name 'Edge PWA autostart entry untouched' -Condition ((Test-RegKey $EDGE_PWA_ARP) -eq $state.pwaArpExisted)

        foreach ($dir in @($scratchA, $scratchB, $scratchC, $oldTree)) {
            Add-Check -Name ("No test install dir left: " + (Split-Path -Leaf $dir)) -Condition (-not (Test-Path -LiteralPath $dir)) -Detail $dir
        }
        Add-Check -Name 'No test node processes left' -Condition (@(Get-NodeProcesses -PathFilters @($scratchA, $scratchB, $scratchC, $oldTree, (Join-Path $WorkRoot 'portable'))).Count -eq 0)
        Add-Check -Name 'Test ports 8790/8445 are free again' -Condition (@(Get-PortListeners).Count -eq 0)
        $testBrowsers = @(Get-BrowserProcesses -ProfileDir $WorkRoot)
        Add-Check -Name 'No test browser processes left' -Condition ($testBrowsers.Count -eq 0)
        Add-Check -Name 'Default LOCALAPPDATA install dir still absent' -Condition (-not (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'Programs\HeyLoganAI')))
    }
}

# ===========================================================================
# SUMMARY
# ===========================================================================
Write-Section 'SUMMARY'
Write-Log ''
Write-Log ("CHECKS: {0}   PASS: {1}   FAIL: {2}" -f $script:CheckNum, $script:Pass, $script:Fail) $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
if ($script:Fail -gt 0) {
    foreach ($failure in $script:Failures) { Write-Log ("  FAIL {0}: {1} {2}" -f $failure.Id, $failure.Name, $failure.Detail) 'Red' }
}

$summary = [pscustomobject]@{
    timestamp = (Get-Date).ToString('o')
    host      = [string]$env:COMPUTERNAME
    version   = $Version
    setup     = [pscustomobject]@{ path = $setupDist; size = $setupDistSize; sha256 = $setupHashDist }
    portable  = [pscustomobject]@{ path = $zipDist; size = $zipDistSize; sha256 = $zipHashDist }
    checks    = $script:CheckNum
    passed    = $script:Pass
    failed    = $script:Fail
    failures  = @($script:Failures)
    logPath   = $logPath
}
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $zipReport -Encoding UTF8

if (-not $KeepWork) {
    Start-Sleep -Milliseconds 300
    Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Fail -eq 0) { exit 0 } else { exit 1 }
