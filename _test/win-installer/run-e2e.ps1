#=============================================================================
# Hey Logan AI - Windows installer / portable ZIP end-to-end test
#
# Run this script from a COPY outside the release workspace, e.g.:
#   Copy-Item <repo>\_test\win-installer\run-e2e.ps1 C:\Temp\hl-test\
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\Temp\hl-test\run-e2e.ps1
#
# Why: the DSH agent file sandbox wraps executables that live inside the
# Downloads workspace; running the built Setup.exe from C:\Temp (a byte
# identical copy, SHA256-checked) is the supported way to execute it.
#
# The script installs, exercises and removes the product on this machine and
# leaves it clean. It writes a full log + JSON summary into
# <repo>\_test\win-installer\.
#=============================================================================

[CmdletBinding()]
param(
    [string]$RepoRoot = 'C:\Users\s2121270\Downloads\Hey-Logan-AI-Release',
    [string]$Version = '1.0.0',
    [string]$WorkRoot = 'C:\Temp\hl-e2e',
    [string]$ReportDir = '',
    [int]$InstallTimeoutSec = 300,
    [int]$HealthTimeoutSec = 90,
    [switch]$KeepWork
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Paths and state
# ---------------------------------------------------------------------------
$setupDist = Join-Path $RepoRoot "dist\HeyLoganAI-Setup-$Version-win-x64.exe"
$zipDist   = Join-Path $RepoRoot "dist\HeyLoganAI-Portable-$Version-win-x64.zip"
$setupRun  = Join-Path $WorkRoot 'setup\HeyLoganAI-Setup.exe'
$defaultDir = Join-Path $env:LOCALAPPDATA 'Programs\HeyLoganAI'
$customDir  = Join-Path $WorkRoot 'custom-install'
$portableDir = Join-Path $WorkRoot 'portable\HeyLoganAI'
$evidenceDir = Join-Path $WorkRoot 'evidence'
if (-not $ReportDir) { $ReportDir = Join-Path $RepoRoot '_test\win-installer' }
if (-not (Test-Path -LiteralPath $WorkRoot)) { New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null }
$null = New-Item -ItemType Directory -Path $evidenceDir -Force
$null = New-Item -ItemType Directory -Path $ReportDir -Force
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
$psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$SM_DIR = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Hey Logan AI'
$DESKTOP_LNK = Join-Path $env:USERPROFILE 'Desktop\Hey Logan AI.lnk'

Set-Content -LiteralPath $logPath -Value ("Hey Logan AI E2E test - {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding UTF8

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

function Add-Info {
    param([string]$Name, $Value)
    Add-Check -Name $Name -Condition $true -Detail ([string]$Value)
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
    try {
        $process = Start-Process @startArgs -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{ ExitCode = $null; TimedOut = $false; Seconds = 0; Error = $_.Exception.Message }
    }
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
    try { return (Start-Process @startArgs -ErrorAction Stop) } catch { Write-Log ("  Start-Detached failed: {0}" -f $_.Exception.Message) 'Red'; return $null }
}

function Start-VisibleProcess {
    param([string]$FilePath, [string]$Arguments = '')
    $startArgs = @{ FilePath = $FilePath; PassThru = $true }
    if ($Arguments -ne '') { $startArgs.ArgumentList = $Arguments }
    try { return (Start-Process @startArgs -ErrorAction Stop) }
    catch { Write-Log ("  Start-VisibleProcess failed: {0}" -f $_.Exception.Message) 'Red'; return $null }
}

function Get-Health {
    try {
        $response = Invoke-WebRequest -Uri 'http://127.0.0.1:8787/api/health' -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
        if ($response.StatusCode -eq 200 -and $response.Content) {
            return ($response.Content | ConvertFrom-Json)
        }
    }
    catch { }
    return $null
}

function Wait-Health {
    param([int]$TimeoutSec = 90)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $health = Get-Health
        if ($health -and $health.ok -eq $true) { return $health }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

function Wait-HealthGone {
    param([int]$TimeoutSec = 20)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Health)) { return $true }
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
# NSIS silent uninstallers re-launch themselves from %TEMP% and the original
# process returns immediately, so the caller must wait for the real work to
# finish before asserting on files/registry. This waits for the observable
# end state instead of trusting the exit code alone.
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
                $dataKept = Test-Path -LiteralPath (Join-Path $InstallDir 'app\data\config.json')
                ($arpGone -and $uninstallerGone -and $programGone -and $dataKept)
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
            if ($cmd.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $matches += $proc
                break
            }
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

function Get-PortListeners {
    param([int[]]$Ports = @(8787, 8443))
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

function Test-RegKey {
    param([string]$Path)
    return (Test-Path -LiteralPath $Path)
}

function Get-ShortcutInfo {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $shortcut = $script:Wsh.CreateShortcut($Path)
        return [pscustomobject]@{
            Path            = $Path
            TargetPath      = $shortcut.TargetPath
            Arguments       = $shortcut.Arguments
            IconLocation    = $shortcut.IconLocation
            WorkingDirectory = $shortcut.WorkingDirectory
        }
    }
    catch { return $null }
}

function Get-TokenFromData {
    param([string]$InstallDir)
    $configPath = Join-Path $InstallDir 'app\data\config.json'
    if (-not (Test-Path -LiteralPath $configPath)) { return $null }
    try {
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        return [string]$config.security.token
    }
    catch { return $null }
}

function Read-TextFileUtf8 {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

# ---------------------------------------------------------------------------
# Machine clean-up helper (only touches Hey Logan AI's own paths)
# ---------------------------------------------------------------------------
function Remove-MachineState {
    param([string[]]$ExtraInstallDirs = @())
    $filters = @($defaultDir, $customDir, $WorkRoot) + $ExtraInstallDirs
    $killed = Stop-NodeProcesses -PathFilters $filters
    if ($killed -gt 0) { Write-Log "  cleanup: stopped $killed node process(es)" 'DarkYellow' }

    # Browser windows opened with the app URL
    try {
        $browserNames = @('msedge.exe', 'chrome.exe', 'firefox.exe')
        $browserProcs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
                $browserNames -contains $_.Name -and $_.CommandLine -and
                ($_.CommandLine -like '*127.0.0.1:8787*' -or $_.CommandLine -like '*--app=http://127.0.0.1*')
            })
        foreach ($proc in $browserProcs) { try { Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
    }
    catch { }

    Remove-Item -LiteralPath $SM_DIR -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $DESKTOP_LNK -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ARP_KEY -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $APP_KEY -Recurse -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -LiteralPath $RUN_KEY -Name $RUN_NAME -Force -ErrorAction SilentlyContinue

    $dirs = @($defaultDir, $customDir) + $ExtraInstallDirs
    foreach ($dir in $dirs) {
        if (Test-Path -LiteralPath $dir) {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ===========================================================================
# PHASE 0 - artifacts
# ===========================================================================
Write-Section 'PHASE 0 - release artifacts'
Write-Log ("host     : {0}" -f (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Caption) $($_.Version)" }))
Write-Log ("user     : {0}\{1}" -f $env:USERDOMAIN, $env:USERNAME)
Write-Log ("powershell: {0}" -f $PSVersionTable.PSVersion.ToString())
Write-Log ("repo     : {0}" -f $RepoRoot)
Write-Log ("work     : {0}" -f $WorkRoot)

# reset anything left behind by previous runs before we start
Remove-MachineState

Add-Check -Name 'dist Setup.exe exists' -Condition (Test-Path -LiteralPath $setupDist) -Detail $setupDist
Add-Check -Name 'dist Portable.zip exists' -Condition (Test-Path -LiteralPath $zipDist) -Detail $zipDist
if (-not (Test-Path -LiteralPath $setupDist) -or -not (Test-Path -LiteralPath $zipDist)) {
    Write-Log 'Aborting: required dist artifacts are missing (run windows\installer\build-all.ps1).' 'Red'
    exit 2
}

$setupHashDist = (Get-FileHash -LiteralPath $setupDist -Algorithm SHA256).Hash.ToLowerInvariant()
$zipHashDist = (Get-FileHash -LiteralPath $zipDist -Algorithm SHA256).Hash.ToLowerInvariant()
$setupDistSize = (Get-Item -LiteralPath $setupDist).Length
$zipDistSize = (Get-Item -LiteralPath $zipDist).Length
Write-Log ("setup    : {0} bytes  sha256 {1}" -f $setupDistSize, $setupHashDist)
Write-Log ("portable : {0} bytes  sha256 {1}" -f $zipDistSize, $zipHashDist)

Add-Check -Name 'Setup.exe size > 20 MB' -Condition ($setupDistSize -gt 20MB) -Detail "$setupDistSize bytes"
Add-Check -Name 'Portable ZIP size > 25 MB' -Condition ($zipDistSize -gt 25MB) -Detail "$zipDistSize bytes"

# copy the Setup.exe outside the workspace, verify the copy is byte-identical
$setupCopyDir = Split-Path -Parent $setupRun
$null = New-Item -ItemType Directory -Path $setupCopyDir -Force
Copy-Item -LiteralPath $setupDist -Destination $setupRun -Force
$setupHashCopy = (Get-FileHash -LiteralPath $setupRun -Algorithm SHA256).Hash.ToLowerInvariant()
Add-Check -Name 'Setup.exe copied to C:\Temp with identical SHA256' -Condition ($setupHashCopy -eq $setupHashDist) -Detail $setupRun

$vi = (Get-Item -LiteralPath $setupDist).VersionInfo
Add-Check -Name 'Setup.exe ProductName is "Hey Logan AI"' -Condition ($vi.ProductName -eq 'Hey Logan AI') -Detail $vi.ProductName
Add-Check -Name 'Setup.exe FileDescription mentions Hey Logan AI' -Condition ($vi.FileDescription -like '*Hey Logan AI*') -Detail $vi.FileDescription
Add-Check -Name 'Setup.exe CompanyName is "Hey Logan AI"' -Condition ($vi.CompanyName -eq 'Hey Logan AI') -Detail $vi.CompanyName
Add-Check -Name 'Setup.exe FileVersion is 1.0.0.x' -Condition ([string]$vi.FileVersion -like '1.0.0*') -Detail $vi.FileVersion
Add-Check -Name 'Setup.exe ProductVersion is 1.0.0.x' -Condition ([string]$vi.ProductVersion -like '1.0.0*') -Detail $vi.ProductVersion
Add-Check -Name 'Setup.exe LegalCopyright present' -Condition (-not [string]::IsNullOrWhiteSpace($vi.LegalCopyright)) -Detail $vi.LegalCopyright

# inspect the portable ZIP without extracting (layout, no app\data)
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($zipDist)
try {
    $zipEntries = @($archive.Entries | ForEach-Object { $_.FullName })
}
finally {
    $archive.Dispose()
}
Add-Check -Name 'Portable ZIP has > 500 entries' -Condition ($zipEntries.Count -gt 500) -Detail "$($zipEntries.Count) entries"
Add-Check -Name 'Portable ZIP contains README-FIRST.txt' -Condition ($zipEntries -contains 'HeyLoganAI/README-FIRST.txt')
Add-Check -Name 'Portable ZIP contains "Start Hey Logan AI.cmd"' -Condition ($zipEntries -contains 'HeyLoganAI/Start Hey Logan AI.cmd')
Add-Check -Name 'Portable ZIP contains runtime/node.exe' -Condition ($zipEntries -contains 'HeyLoganAI/runtime/node.exe')
Add-Check -Name 'Portable ZIP contains app/server/index.js' -Condition ($zipEntries -contains 'HeyLoganAI/app/server/index.js')
Add-Check -Name 'Portable ZIP ships no app/data' -Condition (-not ($zipEntries | Where-Object { $_ -match '(^|/)app/data/' }))

$setupUnsigned = $null
try {
    $sig = Get-AuthenticodeSignature -FilePath $setupDist
    $setupUnsigned = $sig.Status
}
catch { }
Write-Log ("  Authenticode status: {0} (expected: not signed - the release is unsigned)" -f $setupUnsigned)

# no-UAC manifest: RequestExecutionLevel user must produce asInvoker, never
# requireAdministrator (that is what makes this a true per-user installer).
$setupBytes = [System.IO.File]::ReadAllBytes($setupDist)
$setupAscii = [System.Text.Encoding]::ASCII.GetString($setupBytes)
$hasAsInvoker = $setupAscii.Contains('requestedExecutionLevel level="asInvoker"')
$hasRequireAdmin = $setupAscii.Contains('requestedExecutionLevel level="requireAdministrator"')
$setupAscii = $null
$setupBytes = $null
Add-Check -Name 'Setup manifest requests asInvoker (no UAC prompt)' -Condition $hasAsInvoker
Add-Check -Name 'Setup manifest does not request administrator rights' -Condition (-not $hasRequireAdmin)

$sumsPath = Join-Path $RepoRoot '_test\win-installer\SHA256SUMS-windows.txt'
Add-Check -Name 'build checksum manifest exists (_test\win-installer\SHA256SUMS-windows.txt)' -Condition (Test-Path -LiteralPath $sumsPath) -Detail $sumsPath
if (Test-Path -LiteralPath $sumsPath) {
    $sumsText = (Get-Content -LiteralPath $sumsPath -Raw)
    Add-Check -Name 'Checksum manifest matches both artifact hashes' -Condition ($sumsText.Contains($setupHashDist) -and $sumsText.Contains($zipHashDist))
}

# ===========================================================================
# PHASE 1 - clean baseline
# ===========================================================================
Write-Section 'PHASE 1 - clean machine baseline'
Add-Check -Name 'No pre-existing install dir' -Condition (-not (Test-Path -LiteralPath $defaultDir)) -Detail $defaultDir
Add-Check -Name 'No pre-existing ARP entry' -Condition (-not (Test-RegKey $ARP_KEY))
Add-Check -Name 'No pre-existing Run value' -Condition ($null -eq (Get-RegValue $RUN_KEY $RUN_NAME))
Add-Check -Name 'No pre-existing Start Menu group' -Condition (-not (Test-Path -LiteralPath $SM_DIR))
Add-Check -Name 'No pre-existing Desktop shortcut' -Condition (-not (Test-Path -LiteralPath $DESKTOP_LNK))
Add-Check -Name 'Ports 8787/8443 are free' -Condition (@(Get-PortListeners).Count -eq 0)
Add-Check -Name 'No Hey Logan AI node processes' -Condition (@(Get-NodeProcesses -PathFilters @($defaultDir, $customDir)).Count -eq 0)

# ===========================================================================
# PHASE 2a - interactive Modern UI 2 wizard (GUI smoke test, no install)
# ===========================================================================
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
    if (-not $wizard.HasExited) {
        try { Stop-Process -Id $wizard.Id -Force -ErrorAction SilentlyContinue } catch { }
    }
}
Add-Check -Name 'Interactive Setup.exe opens the Modern UI 2 wizard window' -Condition $wizardOk -Detail "window title='$wizardTitle'"
Start-Sleep -Milliseconds 1000
Add-Check -Name 'Cancelled wizard left no partial install' -Condition ((-not (Test-Path -LiteralPath $defaultDir)) -and (-not (Test-RegKey $ARP_KEY)))

# ===========================================================================
# PHASE 2 - silent install (default per-user location)
# ===========================================================================
Write-Section 'PHASE 2 - silent install /S (default location)'
$install = Invoke-Program -FilePath $setupRun -Arguments '/S' -TimeoutSec $InstallTimeoutSec
Add-Check -Name 'Silent install exits 0' -Condition ($install.ExitCode -eq 0) -Detail ("exit=$($install.ExitCode) seconds=$($install.Seconds)")
Add-Check -Name 'Silent install finished in < 180 s' -Condition ($install.Seconds -lt 180) -Detail "$($install.Seconds)s"
Add-Check -Name 'Install dir created (LOCALAPPDATA\Programs\HeyLoganAI)' -Condition (Test-Path -LiteralPath $defaultDir) -Detail $defaultDir

$expectedFiles = @(
    'Launch.vbs',
    'Start Console.cmd',
    'Stop.cmd',
    'Pairing.cmd',
    'Allow through Firewall.cmd',
    'HELP.txt',
    'heylogan.ico',
    'Uninstall.exe',
    'tools\pair.js',
    'tools\stop.ps1',
    'tools\firewall.ps1',
    'runtime\node.exe',
    'app\package.json',
    'app\server\index.js',
    'app\public\index.html',
    'app\public\native-voice.js',
    'app\node_modules\selfsigned\index.js',
    'app\node_modules\qrcode\package.json'
)
$missingInstalled = @()
foreach ($relative in $expectedFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $defaultDir $relative) -PathType Leaf)) { $missingInstalled += $relative }
}
Add-Check -Name 'All expected launcher/app/runtime files installed' -Condition ($missingInstalled.Count -eq 0) -Detail ($(if ($missingInstalled.Count) { "missing: $($missingInstalled -join ', ')" } else { 'all present' }))
Add-Check -Name 'Bundled runtime\node.exe is the 83 MB Node build' -Condition ((Get-Item -LiteralPath (Join-Path $defaultDir 'runtime\node.exe')).Length -gt 80MB) -Detail ("{0} bytes" -f (Get-Item -LiteralPath (Join-Path $defaultDir 'runtime\node.exe')).Length)
Add-Check -Name 'No app\data shipped or pre-created by installer' -Condition (-not (Test-Path -LiteralPath (Join-Path $defaultDir 'app\data')))
Add-Check -Name 'index.html loads native-voice.js (updated payload)' -Condition ((Read-TextFileUtf8 (Join-Path $defaultDir 'app\public\index.html')) -like '*native-voice.js*')
Add-Check -Name 'Installed HELP.txt carries updated pairing wording (phone camera)' -Condition ((Read-TextFileUtf8 (Join-Path $defaultDir 'HELP.txt')) -like '*phone camera*')
Add-Check -Name 'Installed tools\pair.js carries updated QR footer (no camera scanner)' -Condition ((Read-TextFileUtf8 (Join-Path $defaultDir 'tools\pair.js')) -like '*no camera scanner*')
Add-Check -Name 'Silent install does not start the server' -Condition (@(Get-NodeProcesses -PathFilters @($defaultDir)).Count -eq 0) -Detail 'no node process'

# ===========================================================================
# PHASE 3 - Add/Remove Programs + application registry
# ===========================================================================
Write-Section 'PHASE 3 - Add/Remove Programs entry (HKCU)'
Add-Check -Name 'ARP key exists' -Condition (Test-RegKey $ARP_KEY)
Add-Check -Name 'ARP DisplayName' -Condition ((Get-RegValue $ARP_KEY 'DisplayName') -eq 'Hey Logan AI') -Detail (Get-RegValue $ARP_KEY 'DisplayName')
Add-Check -Name 'ARP DisplayVersion' -Condition ((Get-RegValue $ARP_KEY 'DisplayVersion') -eq '1.0.0') -Detail (Get-RegValue $ARP_KEY 'DisplayVersion')
Add-Check -Name 'ARP Publisher' -Condition ((Get-RegValue $ARP_KEY 'Publisher') -eq 'Hey Logan AI') -Detail (Get-RegValue $ARP_KEY 'Publisher')
Add-Check -Name 'ARP DisplayIcon points at installed .ico' -Condition ((Get-RegValue $ARP_KEY 'DisplayIcon') -eq (Join-Path $defaultDir 'heylogan.ico')) -Detail (Get-RegValue $ARP_KEY 'DisplayIcon')
Add-Check -Name 'ARP InstallLocation' -Condition ((Get-RegValue $ARP_KEY 'InstallLocation') -eq $defaultDir) -Detail (Get-RegValue $ARP_KEY 'InstallLocation')
$uninstallString = [string](Get-RegValue $ARP_KEY 'UninstallString')
$quietString = [string](Get-RegValue $ARP_KEY 'QuietUninstallString')
Add-Check -Name 'ARP UninstallString points at Uninstall.exe' -Condition ($uninstallString -like "*$defaultDir\Uninstall.exe*") -Detail $uninstallString
Add-Check -Name 'ARP QuietUninstallString has /S' -Condition (($quietString -like "*$defaultDir\Uninstall.exe*") -and ($quietString -like '*/S*')) -Detail $quietString
$estimated = Get-RegValue $ARP_KEY 'EstimatedSize'
Add-Check -Name 'ARP EstimatedSize >= 80000 KB' -Condition ($null -ne $estimated -and [int]$estimated -ge 80000) -Detail $estimated
Add-Check -Name 'ARP NoModify = 1' -Condition ([int](Get-RegValue $ARP_KEY 'NoModify') -eq 1)
Add-Check -Name 'ARP NoRepair = 1' -Condition ([int](Get-RegValue $ARP_KEY 'NoRepair') -eq 1)
Add-Check -Name 'ARP VersionMajor/Minor = 1.0' -Condition (([int](Get-RegValue $ARP_KEY 'VersionMajor') -eq 1) -and ([int](Get-RegValue $ARP_KEY 'VersionMinor') -eq 0))
Add-Check -Name 'ARP is not hidden (SystemComponent absent)' -Condition ($null -eq (Get-RegValue $ARP_KEY 'SystemComponent'))
Add-Check -Name 'HKCU\Software\HeyLoganAI InstallDir' -Condition ((Get-RegValue $APP_KEY 'InstallDir') -eq $defaultDir) -Detail (Get-RegValue $APP_KEY 'InstallDir')
Add-Check -Name 'HKCU\Software\HeyLoganAI Version' -Condition ((Get-RegValue $APP_KEY 'Version') -eq '1.0.0') -Detail (Get-RegValue $APP_KEY 'Version')

# ===========================================================================
# PHASE 4 - Start Menu + Desktop shortcuts
# ===========================================================================
Write-Section 'PHASE 4 - shortcuts'
$expectedLnkNames = @('Hey Logan AI.lnk', 'Start Console.lnk', 'Pairing.lnk', 'Stop Server.lnk', 'Allow through Firewall.lnk', 'Uninstall.lnk')
Add-Check -Name 'Start Menu group "Hey Logan AI" exists' -Condition (Test-Path -LiteralPath $SM_DIR) -Detail $SM_DIR
$missingLnk = @()
foreach ($name in $expectedLnkNames) {
    if (-not (Test-Path -LiteralPath (Join-Path $SM_DIR $name))) { $missingLnk += $name }
}
Add-Check -Name 'Start Menu group has all 6 shortcuts' -Condition ($missingLnk.Count -eq 0) -Detail ($(if ($missingLnk.Count) { "missing: $($missingLnk -join ', ')" } else { 'all present' }))

$mainLnk = Get-ShortcutInfo -Path (Join-Path $SM_DIR 'Hey Logan AI.lnk')
$desktopLnk = Get-ShortcutInfo -Path $DESKTOP_LNK
$targetOk = { param($info) $info -and ([string]$info.TargetPath -like '*wscript.exe') }
Add-Check -Name 'Start Menu main shortcut target is wscript.exe' -Condition (& $targetOk $mainLnk) -Detail ($(if ($mainLnk) { $mainLnk.TargetPath } else { 'missing' }))
Add-Check -Name 'Start Menu main shortcut args = "<install>\Launch.vbs"' -Condition ($mainLnk -and ([string]$mainLnk.Arguments -like "*$defaultDir\Launch.vbs*")) -Detail ($(if ($mainLnk) { $mainLnk.Arguments } else { 'missing' }))
Add-Check -Name 'Start Menu main shortcut icon is heylogan.ico' -Condition ($mainLnk -and ([string]$mainLnk.IconLocation -like "*$defaultDir\heylogan.ico*")) -Detail ($(if ($mainLnk) { $mainLnk.IconLocation } else { 'missing' }))
Add-Check -Name 'Desktop shortcut exists' -Condition ($null -ne $desktopLnk) -Detail $DESKTOP_LNK
Add-Check -Name 'Desktop shortcut target is wscript.exe' -Condition (& $targetOk $desktopLnk) -Detail ($(if ($desktopLnk) { $desktopLnk.TargetPath } else { 'missing' }))
Add-Check -Name 'Desktop shortcut args = "<install>\Launch.vbs"' -Condition ($desktopLnk -and ([string]$desktopLnk.Arguments -like "*$defaultDir\Launch.vbs*")) -Detail ($(if ($desktopLnk) { $desktopLnk.Arguments } else { 'missing' }))
Add-Check -Name 'Desktop shortcut icon is heylogan.ico' -Condition ($desktopLnk -and ([string]$desktopLnk.IconLocation -like "*$defaultDir\heylogan.ico*")) -Detail ($(if ($desktopLnk) { $desktopLnk.IconLocation } else { 'missing' }))

$lnkChecks = @(
    @{ Name = 'Start Console.lnk'; Target = 'Start Console.cmd' },
    @{ Name = 'Pairing.lnk'; Target = 'Pairing.cmd' },
    @{ Name = 'Stop Server.lnk'; Target = 'Stop.cmd' },
    @{ Name = 'Allow through Firewall.lnk'; Target = 'Allow through Firewall.cmd' },
    @{ Name = 'Uninstall.lnk'; Target = 'Uninstall.exe' }
)
foreach ($entry in $lnkChecks) {
    $info = Get-ShortcutInfo -Path (Join-Path $SM_DIR $entry.Name)
    $ok = $info -and ([string]$info.TargetPath -like "*$($entry.Target)")
    Add-Check -Name ("Shortcut {0} -> {1}" -f $entry.Name, $entry.Target) -Condition $ok -Detail ($(if ($info) { $info.TargetPath } else { 'missing' }))
}

# ===========================================================================
# PHASE 5 - start-at-login Run value
# ===========================================================================
Write-Section 'PHASE 5 - start-at-login (HKCU Run)'
$runValue = [string](Get-RegValue $RUN_KEY $RUN_NAME)
Add-Check -Name 'HKCU Run value HeyLoganAI exists (default on)' -Condition (-not [string]::IsNullOrWhiteSpace($runValue)) -Detail $runValue
Add-Check -Name 'Run value = wscript.exe "<install>\Launch.vbs"' -Condition (($runValue -like '*wscript.exe*') -and ($runValue -like "*$defaultDir\Launch.vbs*")) -Detail $runValue

# ===========================================================================
# PHASE 6 - launch exactly like the shortcut does, then health check
# ===========================================================================
Write-Section 'PHASE 6 - launch via shortcut target / health endpoint'
if ($mainLnk) {
    Start-Detached -FilePath $mainLnk.TargetPath -Arguments $mainLnk.Arguments | Out-Null
}
$health = Wait-Health -TimeoutSec $HealthTimeoutSec
Add-Check -Name 'Health endpoint answers within 90 s' -Condition ($null -ne $health)
Add-Check -Name 'Health JSON ok = true' -Condition ($health -and $health.ok -eq $true) -Detail ($(if ($health) { $health | ConvertTo-Json -Compress } else { 'no response' }))
Add-Check -Name 'Health JSON app = "Hey Logan AI"' -Condition ($health -and $health.app -eq 'Hey Logan AI') -Detail ($(if ($health) { $health.app } else { 'no response' }))
Add-Check -Name 'Health JSON version = 1.0.0' -Condition ($health -and [string]$health.version -eq '1.0.0') -Detail ($(if ($health) { $health.version } else { 'no response' }))
Add-Check -Name 'Health JSON requiresToken = true' -Condition ($health -and $health.requiresToken -eq $true)

$dataDir = Join-Path $defaultDir 'app\data'
Add-Check -Name 'First run created app\data\config.json' -Condition (Test-Path -LiteralPath (Join-Path $dataDir 'config.json')) -Detail $dataDir
$token = Get-TokenFromData -InstallDir $defaultDir
Add-Check -Name 'Pairing token generated (XXXX-XXXX-XXXX)' -Condition ($token -and $token -match '^[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$') -Detail $token
Add-Check -Name 'HTTPS certificate created in app\data\certs' -Condition ((Test-Path -LiteralPath (Join-Path $dataDir 'certs\cert.pem')) -and (Test-Path -LiteralPath (Join-Path $dataDir 'certs\key.pem')))

# server-side pairing API (same data Pairing.cmd prints)
if ($token) {
    try {
        $pairing = Invoke-RestMethod -Uri 'http://127.0.0.1:8787/api/pairing' -Headers @{ 'x-bridge-token' = $token } -TimeoutSec 5 -ErrorAction Stop
        Add-Check -Name 'GET /api/pairing returns the token' -Condition ($pairing.token -eq $token)
        Add-Check -Name 'Pairing URL is a LAN HTTPS URL' -Condition ([string]$pairing.pairingUrl -like 'https://192.168.*') -Detail $pairing.pairingUrl
        Add-Check -Name 'Pairing QR SVG returned by API' -Condition ([string]$pairing.qrSvg -like '*<svg*') -Detail ("{0} chars" -f ([string]$pairing.qrSvg).Length)
    }
    catch {
        Add-Check -Name 'GET /api/pairing returns the token' -Condition $false -Detail $_.Exception.Message
    }
}

# ===========================================================================
# PHASE 7 - Pairing.cmd (CLI)
# ===========================================================================
Write-Section 'PHASE 7 - Pairing.cmd'
$pairingLog = Join-Path $evidenceDir 'pairing-output.txt'
$pairingWrapper = Join-Path $WorkRoot 'run-pairing.cmd'
$wrapperText = @"
@echo off
call "$defaultDir\Pairing.cmd" > "$pairingLog" 2>&1 < nul
exit /b %ERRORLEVEL%
"@
Set-Content -LiteralPath $pairingWrapper -Value $wrapperText -Encoding ascii
$pairingRun = Invoke-Program -FilePath 'cmd.exe' -Arguments "/d /c `"$pairingWrapper`"" -TimeoutSec 120
$pairingText = Read-TextFileUtf8 -Path $pairingLog
Copy-Item -LiteralPath $pairingLog -Destination (Join-Path $ReportDir 'pairing-output.txt') -Force -ErrorAction SilentlyContinue
Add-Check -Name 'Pairing.cmd exits 0' -Condition ($pairingRun.ExitCode -eq 0) -Detail ("exit=$($pairingRun.ExitCode)")
Add-Check -Name 'Pairing.cmd prints the access token' -Condition ($pairingText -like '*Access token:*' -and $token -and $pairingText.Contains($token))
$lanMatch = [regex]::Match($pairingText, '192\.168\.\d{1,3}\.\d{1,3}')
Add-Check -Name 'Pairing.cmd shows a 192.168.x.x LAN address' -Condition $lanMatch.Success -Detail ($(if ($lanMatch.Success) { $lanMatch.Value } else { 'not found' }))
Add-Check -Name 'Pairing.cmd shows the https:// phone URL' -Condition ($pairingText -like '*https://192.168.*')
Add-Check -Name 'Pairing.cmd shows the local PC URL' -Condition ($pairingText -like '*http://127.0.0.1:8787*')
Add-Check -Name 'Pairing.cmd renders a QR code' -Condition (($pairingText -like '*Scan this QR code*') -and (($pairingText.Contains([char]0x2580)) -or ($pairingText.Contains([char]0x2584)) -or ($pairingText.Contains([char]0x2588))))
Add-Check -Name 'Pairing.cmd says the Android app has no camera scanner' -Condition ($pairingText -like '*The app has no camera scanner*')
Add-Check -Name 'Pairing.cmd recommends phone camera / Chrome for the QR' -Condition ($pairingText -like '*Phone camera / Chrome*')

# ===========================================================================
# PHASE 8 - Stop.cmd
# ===========================================================================
Write-Section 'PHASE 8 - Stop.cmd'
$stopLog = Join-Path $evidenceDir 'stop-output.txt'
$stopWrapper = Join-Path $WorkRoot 'run-stop.cmd'
$stopWrapperText = @"
@echo off
call "$defaultDir\Stop.cmd" > "$stopLog" 2>&1 < nul
exit /b %ERRORLEVEL%
"@
Set-Content -LiteralPath $stopWrapper -Value $stopWrapperText -Encoding ascii
$stopRun = Invoke-Program -FilePath 'cmd.exe' -Arguments "/d /c `"$stopWrapper`"" -TimeoutSec 120
$stopText = Read-TextFileUtf8 -Path $stopLog
Copy-Item -LiteralPath $stopLog -Destination (Join-Path $ReportDir 'stop-output.txt') -Force -ErrorAction SilentlyContinue
Add-Check -Name 'Stop.cmd exits 0' -Condition ($stopRun.ExitCode -eq 0) -Detail ("exit=$($stopRun.ExitCode)")
Add-Check -Name 'Stop.cmd reports the server was stopped' -Condition ($stopText -like '*Server stopped*') -Detail ($stopText.Trim())
Add-Check -Name 'Server is down after Stop.cmd' -Condition (Wait-HealthGone -TimeoutSec 20)
Add-Check -Name 'No node process left after Stop.cmd' -Condition (@(Get-NodeProcesses -PathFilters @($defaultDir)).Count -eq 0)

# ===========================================================================
# PHASE 9 - upgrade in place keeps app\data (token / certificate / settings)
# ===========================================================================
Write-Section 'PHASE 9 - upgrade in place keeps app\data'
$health = $null
if ($mainLnk) { Start-Detached -FilePath $mainLnk.TargetPath -Arguments $mainLnk.Arguments | Out-Null }
$health = Wait-Health -TimeoutSec $HealthTimeoutSec
Add-Check -Name 'Server running again before upgrade' -Condition ($null -ne $health)
$tokenBefore = Get-TokenFromData -InstallDir $defaultDir
$markerPath = Join-Path $dataDir 'e2e-upgrade-marker.txt'
Set-Content -LiteralPath $markerPath -Value 'marker-before-upgrade' -Encoding ascii
Add-Content -LiteralPath (Join-Path $defaultDir 'app\server\index.js') -Value '// e2e-tampered-program-file'
Add-Check -Name 'Server is running during upgrade' -Condition ($null -ne (Get-Health))

$upgrade = Invoke-Program -FilePath $setupRun -Arguments '/S' -TimeoutSec $InstallTimeoutSec
Add-Check -Name 'Upgrade install exits 0' -Condition ($upgrade.ExitCode -eq 0) -Detail ("exit=$($upgrade.ExitCode) seconds=$($upgrade.Seconds)")
Add-Check -Name 'Upgrade stopped the running server' -Condition (Wait-HealthGone -TimeoutSec 20)
Add-Check -Name 'Upgrade replaced program files (tamper marker gone)' -Condition (-not ((Read-TextFileUtf8 (Join-Path $defaultDir 'app\server\index.js')) -like '*e2e-tampered-program-file*'))
Add-Check -Name 'Upgrade kept the access token' -Condition ((Get-TokenFromData -InstallDir $defaultDir) -eq $tokenBefore) -Detail "before=$tokenBefore after=$(Get-TokenFromData -InstallDir $defaultDir)"
Add-Check -Name 'Upgrade kept app\data marker file' -Condition ((Test-Path -LiteralPath $markerPath) -and ((Read-TextFileUtf8 $markerPath) -like '*marker-before-upgrade*'))
Add-Check -Name 'Upgrade kept the HTTPS certificate' -Condition ((Test-Path -LiteralPath (Join-Path $dataDir 'certs\cert.pem')) -and (Test-Path -LiteralPath (Join-Path $dataDir 'certs\key.pem')))
Add-Check -Name 'Upgrade kept ARP entry' -Condition (Test-RegKey $ARP_KEY)
Add-Check -Name 'Upgrade kept Run value' -Condition ((Get-RegValue $RUN_KEY $RUN_NAME) -eq $runValue)
Add-Check -Name 'Upgrade kept Start Menu shortcuts' -Condition (Test-Path -LiteralPath (Join-Path $SM_DIR 'Hey Logan AI.lnk'))

# the app must still work after the upgrade
if ($mainLnk) { Start-Detached -FilePath $mainLnk.TargetPath -Arguments $mainLnk.Arguments | Out-Null }
$healthAfter = Wait-Health -TimeoutSec $HealthTimeoutSec
Add-Check -Name 'App healthy after upgrade' -Condition ($healthAfter -and $healthAfter.ok -eq $true) -Detail ($(if ($healthAfter) { $healthAfter.app } else { 'no response' }))
Add-Check -Name 'Token unchanged after post-upgrade run' -Condition ((Get-TokenFromData -InstallDir $defaultDir) -eq $tokenBefore)
$null = Invoke-Program -FilePath $psExe -Arguments ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $defaultDir 'tools\stop.ps1')) -TimeoutSec 60
Add-Check -Name 'Server stopped before uninstall' -Condition (Wait-HealthGone -TimeoutSec 20)

# ===========================================================================
# PHASE 9a - data-loss guard: an upgrade must ABORT, not delete, app\data
# ===========================================================================
Write-Section 'PHASE 9a - data-loss guard (locked app\data)'
$configPath = Join-Path $dataDir 'config.json'
$lockStream = $null
$blocked = $null
try {
    # A share-deny handle on config.json makes the Rename of app\data fail,
    # exactly like a locked file / antivirus scan does on a real machine.
    $lockStream = [System.IO.File]::Open($configPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    $blocked = Invoke-Program -FilePath $setupRun -Arguments '/S' -TimeoutSec 120
}
catch {
    Write-Log ("  data-lock simulation could not be set up: {0}" -f $_.Exception.Message) 'Yellow'
}
finally {
    if ($lockStream) { $lockStream.Close(); $lockStream.Dispose() }
}
if ($blocked) {
    Add-Check -Name 'Upgrade aborts (non-zero exit) when app\data cannot be stashed' -Condition ($null -ne $blocked.ExitCode -and $blocked.ExitCode -ne 0) -Detail ("exit=$($blocked.ExitCode) seconds=$($blocked.Seconds)")
}
else {
    Add-Check -Name 'Upgrade aborts (non-zero exit) when app\data cannot be stashed' -Condition $false -Detail 'lock simulation could not be set up'
}
Add-Check -Name 'Aborted upgrade kept the access token' -Condition ((Get-TokenFromData -InstallDir $defaultDir) -eq $tokenBefore)
Add-Check -Name 'Aborted upgrade kept the HTTPS certificate' -Condition (Test-Path -LiteralPath (Join-Path $dataDir 'certs\cert.pem'))
Add-Check -Name 'Aborted upgrade did not delete program files' -Condition (Test-Path -LiteralPath (Join-Path $defaultDir 'Launch.vbs'))
Add-Check -Name 'Aborted upgrade left no .hl-data-keep stash' -Condition (-not (Test-Path -LiteralPath (Join-Path $defaultDir '.hl-data-keep')))
# The abort must not have damaged the installation: it must upgrade normally now.
$retryUpgrade = Invoke-Program -FilePath $setupRun -Arguments '/S' -TimeoutSec $InstallTimeoutSec
Add-Check -Name 'Upgrade succeeds normally once the lock is released' -Condition ($retryUpgrade.ExitCode -eq 0) -Detail ("exit=$($retryUpgrade.ExitCode)")
Add-Check -Name 'Token still unchanged after the retry upgrade' -Condition ((Get-TokenFromData -InstallDir $defaultDir) -eq $tokenBefore)

# ===========================================================================
# PHASE 10 - uninstall, keep app\data (/S default = keep)
# ===========================================================================
Write-Section 'PHASE 10 - uninstall keeping app\data (Uninstall.exe /S)'
$keepRun = Invoke-Program -FilePath (Join-Path $defaultDir 'Uninstall.exe') -Arguments '/S' -TimeoutSec $InstallTimeoutSec
Add-Check -Name 'Uninstall (keep data) exits 0' -Condition ($keepRun.ExitCode -eq 0) -Detail ("exit=$($keepRun.ExitCode) seconds=$($keepRun.Seconds)")
$keepCompleted = Wait-SilentUninstallComplete -InstallDir $defaultDir -KeepData -TimeoutSec 120
Add-Check -Name 'Keep-data uninstall completed (NSIS async temp re-launch)' -Condition $keepCompleted
Add-Check -Name 'Uninstall removed ARP entry' -Condition (-not (Test-RegKey $ARP_KEY))
Add-Check -Name 'Uninstall removed Run value' -Condition ($null -eq (Get-RegValue $RUN_KEY $RUN_NAME))
Add-Check -Name 'Uninstall removed HKCU\Software\HeyLoganAI' -Condition (-not (Test-RegKey $APP_KEY))
Add-Check -Name 'Uninstall removed Start Menu group' -Condition (-not (Test-Path -LiteralPath $SM_DIR))
Add-Check -Name 'Uninstall removed Desktop shortcut' -Condition (-not (Test-Path -LiteralPath $DESKTOP_LNK))
Add-Check -Name 'Uninstall kept the install folder (app\data only)' -Condition (Test-Path -LiteralPath $defaultDir)
Add-Check -Name 'Uninstall removed Uninstall.exe' -Condition (-not (Test-Path -LiteralPath (Join-Path $defaultDir 'Uninstall.exe')))
$leftovers = @(Get-ChildItem -LiteralPath $defaultDir -Recurse -Force -ErrorAction SilentlyContinue)
$dataPrefix = (Join-Path $defaultDir 'app\data')
$appDirPath = Join-Path $defaultDir 'app'
$outsideData = @($leftovers | Where-Object {
        $_.FullName -notlike "$dataPrefix*" -and $_.FullName -ne $defaultDir -and $_.FullName -ne $appDirPath
    })
Add-Check -Name 'Only app\data is left in the install folder' -Condition (($leftovers.Count -gt 0) -and ($outsideData.Count -eq 0)) -Detail ("{0} leftover item(s), {1} outside app\data" -f $leftovers.Count, $outsideData.Count)
Add-Check -Name 'Kept token survives the keep-data uninstall' -Condition ((Get-TokenFromData -InstallDir $defaultDir) -eq $tokenBefore) -Detail (Get-TokenFromData -InstallDir $defaultDir)

# ===========================================================================
# PHASE 11 - reinstall over the kept data, then uninstall purging data
# ===========================================================================
Write-Section 'PHASE 11 - reinstall, then purge uninstall (/S /PURGEDATA)'
$reinstall = Invoke-Program -FilePath $setupRun -Arguments '/S' -TimeoutSec $InstallTimeoutSec
Add-Check -Name 'Reinstall over kept app\data exits 0' -Condition ($reinstall.ExitCode -eq 0) -Detail ("exit=$($reinstall.ExitCode)")
Add-Check -Name 'Reinstall preserved the token' -Condition ((Get-TokenFromData -InstallDir $defaultDir) -eq $tokenBefore)
Add-Check -Name 'Reinstall restored program files' -Condition ((Test-Path -LiteralPath (Join-Path $defaultDir 'Launch.vbs')) -and (Test-Path -LiteralPath (Join-Path $defaultDir 'runtime\node.exe')))
Add-Check -Name 'Reinstall re-created ARP entry' -Condition (Test-RegKey $ARP_KEY)

$purgeRun = Invoke-Program -FilePath (Join-Path $defaultDir 'Uninstall.exe') -Arguments '/S /PURGEDATA' -TimeoutSec $InstallTimeoutSec
Add-Check -Name 'Silent purge uninstall exits 0' -Condition ($purgeRun.ExitCode -eq 0) -Detail ("exit=$($purgeRun.ExitCode) seconds=$($purgeRun.Seconds)")
$purgeCompleted = Wait-SilentUninstallComplete -InstallDir $defaultDir -TimeoutSec 120
Add-Check -Name 'Purge uninstall completed' -Condition $purgeCompleted
Add-Check -Name 'Purge uninstall removed the whole install folder' -Condition (-not (Test-Path -LiteralPath $defaultDir)) -Detail $defaultDir
Add-Check -Name 'Purge uninstall removed ARP entry' -Condition (-not (Test-RegKey $ARP_KEY))
Add-Check -Name 'Purge uninstall removed Run value' -Condition ($null -eq (Get-RegValue $RUN_KEY $RUN_NAME))
Add-Check -Name 'Purge uninstall removed shortcuts' -Condition ((-not (Test-Path -LiteralPath $SM_DIR)) -and (-not (Test-Path -LiteralPath $DESKTOP_LNK)))
Add-Check -Name 'No node process left after uninstall' -Condition (@(Get-NodeProcesses -PathFilters @($defaultDir)).Count -eq 0)

# ===========================================================================
# PHASE 12 - custom install directory (/D=)
# ===========================================================================
Write-Section 'PHASE 12 - custom install dir (/D=)'
$customRun = Invoke-Program -FilePath $setupRun -Arguments "/S /D=$customDir" -TimeoutSec $InstallTimeoutSec
Add-Check -Name 'Custom-dir silent install exits 0' -Condition ($customRun.ExitCode -eq 0) -Detail ("exit=$($customRun.ExitCode)")
Add-Check -Name 'Custom-dir install wrote files to /D path' -Condition ((Test-Path -LiteralPath (Join-Path $customDir 'Launch.vbs')) -and (Test-Path -LiteralPath (Join-Path $customDir 'runtime\node.exe')))
Add-Check -Name 'Custom-dir install did not touch default dir' -Condition (-not (Test-Path -LiteralPath $defaultDir))
Add-Check -Name 'Custom-dir ARP InstallLocation' -Condition ((Get-RegValue $ARP_KEY 'InstallLocation') -eq $customDir) -Detail (Get-RegValue $ARP_KEY 'InstallLocation')
Add-Check -Name 'Custom-dir Run value points at custom path' -Condition ([string](Get-RegValue $RUN_KEY $RUN_NAME) -like "*$customDir\Launch.vbs*") -Detail (Get-RegValue $RUN_KEY $RUN_NAME)
$customMainLnk = Get-ShortcutInfo -Path (Join-Path $SM_DIR 'Hey Logan AI.lnk')
Add-Check -Name 'Custom-dir main shortcut points at custom path' -Condition ($customMainLnk -and ([string]$customMainLnk.Arguments -like "*$customDir\Launch.vbs*")) -Detail ($(if ($customMainLnk) { $customMainLnk.Arguments } else { 'missing' }))
Add-Check -Name 'Custom-dir install kept app\data absent' -Condition (-not (Test-Path -LiteralPath (Join-Path $customDir 'app\data')))

$customUninstall = Invoke-Program -FilePath (Join-Path $customDir 'Uninstall.exe') -Arguments '/S /PURGEDATA' -TimeoutSec $InstallTimeoutSec
Add-Check -Name 'Custom-dir uninstaller finds its own install dir and exits 0' -Condition ($customUninstall.ExitCode -eq 0) -Detail ("exit=$($customUninstall.ExitCode)")
$customPurgeCompleted = Wait-SilentUninstallComplete -InstallDir $customDir -TimeoutSec 120
Add-Check -Name 'Custom-dir purge uninstall completed' -Condition $customPurgeCompleted
Add-Check -Name 'Custom-dir uninstall removed the custom folder' -Condition (-not (Test-Path -LiteralPath $customDir)) -Detail $customDir
Add-Check -Name 'Custom-dir uninstall removed ARP entry' -Condition (-not (Test-RegKey $ARP_KEY))
# ===========================================================================
# PHASE 12a - /NOAUTOSTART (works with /S and /D=)
# ===========================================================================
Write-Section 'PHASE 12a - /S /NOAUTOSTART /D= (start-at-login skipped)'
$noAutoDir = Join-Path $WorkRoot 'custom-install-noauto'
$noAutoRun = Invoke-Program -FilePath $setupRun -Arguments "/S /NOAUTOSTART /D=$noAutoDir" -TimeoutSec $InstallTimeoutSec
Add-Check -Name '/S /NOAUTOSTART /D= install exits 0' -Condition ($noAutoRun.ExitCode -eq 0) -Detail ("exit=$($noAutoRun.ExitCode)")
Add-Check -Name '/NOAUTOSTART install wrote files to the /D path' -Condition ((Test-Path -LiteralPath (Join-Path $noAutoDir 'Launch.vbs')) -and (Test-Path -LiteralPath (Join-Path $noAutoDir 'runtime\node.exe')))
Add-Check -Name '/NOAUTOSTART leaves no HKCU Run value' -Condition ($null -eq (Get-RegValue $RUN_KEY $RUN_NAME)) -Detail (Get-RegValue $RUN_KEY $RUN_NAME)
Add-Check -Name '/NOAUTOSTART ARP InstallLocation is the /D path' -Condition ((Get-RegValue $ARP_KEY 'InstallLocation') -eq $noAutoDir) -Detail (Get-RegValue $ARP_KEY 'InstallLocation')
Add-Check -Name '/NOAUTOSTART still creates Start Menu shortcuts' -Condition (Test-Path -LiteralPath (Join-Path $SM_DIR 'Uninstall.lnk'))
$noAutoUninstall = Invoke-Program -FilePath (Join-Path $noAutoDir 'Uninstall.exe') -Arguments '/S /PURGEDATA' -TimeoutSec $InstallTimeoutSec
Add-Check -Name '/NOAUTOSTART test uninstall exits 0' -Condition ($noAutoUninstall.ExitCode -eq 0) -Detail ("exit=$($noAutoUninstall.ExitCode)")
$noAutoPurged = Wait-SilentUninstallComplete -InstallDir $noAutoDir -TimeoutSec 120
Add-Check -Name '/NOAUTOSTART test install removed cleanly' -Condition $noAutoPurged

# ===========================================================================
# PHASE 13 - portable ZIP
# ===========================================================================
Write-Section 'PHASE 13 - portable ZIP (no installer, no registry)'
$portableParent = Join-Path $WorkRoot 'portable'
if (Test-Path -LiteralPath $portableParent) { Remove-Item -LiteralPath $portableParent -Recurse -Force }
$null = New-Item -ItemType Directory -Path $portableParent -Force
$tar = Join-Path $env:WINDIR 'System32\tar.exe'
$extract = Invoke-Program -FilePath $tar -Arguments ("-xf `"{0}`" -C `"{1}`"" -f $zipDist, $portableParent) -TimeoutSec 180
Add-Check -Name 'Portable ZIP extracts' -Condition ($extract.ExitCode -eq 0) -Detail ("exit=$($extract.ExitCode) seconds=$($extract.Seconds)")
Add-Check -Name 'Portable README-FIRST.txt present' -Condition (Test-Path -LiteralPath (Join-Path $portableDir 'README-FIRST.txt'))
Add-Check -Name 'Portable "Start Hey Logan AI.cmd" present' -Condition (Test-Path -LiteralPath (Join-Path $portableDir 'Start Hey Logan AI.cmd'))
$portableStartCmd = Read-TextFileUtf8 -Path (Join-Path $portableDir 'Start Hey Logan AI.cmd')
Add-Check -Name 'Portable start cmd runs runtime\node.exe on app\server\index.js' -Condition (($portableStartCmd -like '*runtime\node.exe*') -and ($portableStartCmd -like '*app\server\index.js*'))
Add-Check -Name 'Portable runtime\node.exe present' -Condition (Test-Path -LiteralPath (Join-Path $portableDir 'runtime\node.exe'))
Add-Check -Name 'Portable app files present (native-voice.js)' -Condition ((Test-Path -LiteralPath (Join-Path $portableDir 'app\server\index.js')) -and (Test-Path -LiteralPath (Join-Path $portableDir 'app\public\native-voice.js')))
Add-Check -Name 'Portable extraction ships no app\data' -Condition (-not (Test-Path -LiteralPath (Join-Path $portableDir 'app\data')))

$portableNode = Join-Path $portableDir 'runtime\node.exe'
$nodeVersionOut = (& $portableNode --version 2>$null | Select-Object -First 1)
Add-Check -Name 'Portable bundled runtime is Node v22.23.3' -Condition ([string]$nodeVersionOut -eq 'v22.23.3') -Detail $nodeVersionOut
$portableEntry = Join-Path $portableDir 'app\server\index.js'
Start-Detached -FilePath $portableNode -Arguments ("`"{0}`"" -f $portableEntry) -WorkingDirectory (Join-Path $portableDir 'app') | Out-Null
$portableHealth = Wait-Health -TimeoutSec $HealthTimeoutSec
Add-Check -Name 'Portable server health ok' -Condition ($portableHealth -and $portableHealth.ok -eq $true) -Detail ($(if ($portableHealth) { $portableHealth | ConvertTo-Json -Compress } else { 'no response' }))
Add-Check -Name 'Portable server reports "Hey Logan AI" 1.0.0' -Condition ($portableHealth -and $portableHealth.app -eq 'Hey Logan AI' -and [string]$portableHealth.version -eq '1.0.0')
Add-Check -Name 'Portable created its own app\data' -Condition (Test-Path -LiteralPath (Join-Path $portableDir 'app\data\config.json'))
Add-Check -Name 'Portable run created no ARP entry' -Condition (-not (Test-RegKey $ARP_KEY))
Add-Check -Name 'Portable run created no Run value' -Condition ($null -eq (Get-RegValue $RUN_KEY $RUN_NAME))
Add-Check -Name 'Portable run created no Start Menu group' -Condition (-not (Test-Path -LiteralPath $SM_DIR))
Add-Check -Name 'Portable run created no Desktop shortcut' -Condition (-not (Test-Path -LiteralPath $DESKTOP_LNK))

$null = Invoke-Program -FilePath $psExe -Arguments ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $portableDir 'tools\stop.ps1')) -TimeoutSec 60
Add-Check -Name 'Portable tools\stop.ps1 stops the server' -Condition (Wait-HealthGone -TimeoutSec 20)
Add-Check -Name 'Portable run left no node process' -Condition (@(Get-NodeProcesses -PathFilters @($portableDir)).Count -eq 0)

# ===========================================================================
# PHASE 14 - clean machine
# ===========================================================================
Write-Section 'PHASE 14 - final clean-up'
Remove-MachineState -ExtraInstallDirs @($portableDir)
Start-Sleep -Milliseconds 500
Add-Check -Name 'Clean: no install dir' -Condition (-not (Test-Path -LiteralPath $defaultDir))
Add-Check -Name 'Clean: no custom install dir' -Condition (-not (Test-Path -LiteralPath $customDir))
Add-Check -Name 'Clean: no ARP entry' -Condition (-not (Test-RegKey $ARP_KEY))
Add-Check -Name 'Clean: no HKCU app key' -Condition (-not (Test-RegKey $APP_KEY))
Add-Check -Name 'Clean: no Run value' -Condition ($null -eq (Get-RegValue $RUN_KEY $RUN_NAME))
Add-Check -Name 'Clean: no Start Menu group' -Condition (-not (Test-Path -LiteralPath $SM_DIR))
Add-Check -Name 'Clean: no Desktop shortcut' -Condition (-not (Test-Path -LiteralPath $DESKTOP_LNK))
Add-Check -Name 'Clean: no node processes' -Condition (@(Get-NodeProcesses -PathFilters @($defaultDir, $customDir, $WorkRoot)).Count -eq 0)
Add-Check -Name 'Clean: ports 8787/8443 free' -Condition (@(Get-PortListeners).Count -eq 0)

# ===========================================================================
# SUMMARY
# ===========================================================================
Write-Section 'SUMMARY'
Write-Log ''
Write-Log ("CHECKS: {0}   PASS: {1}   FAIL: {2}" -f $script:CheckNum, $script:Pass, $script:Fail) $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
if ($script:Fail -gt 0) {
    foreach ($failure in $script:Failures) {
        Write-Log ("  FAIL {0}: {1} {2}" -f $failure.Id, $failure.Name, $failure.Detail) 'Red'
    }
}

$summary = [pscustomobject]@{
    timestamp      = (Get-Date).ToString('o')
    host           = [string]$env:COMPUTERNAME
    version        = $Version
    setup          = [pscustomobject]@{ path = $setupDist; size = $setupDistSize; sha256 = $setupHashDist }
    portable       = [pscustomobject]@{ path = $zipDist; size = $zipDistSize; sha256 = $zipHashDist }
    checks         = $script:CheckNum
    passed         = $script:Pass
    failed         = $script:Fail
    failures       = @($script:Failures)
    logPath        = $logPath
}
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $zipReport -Encoding UTF8

# remove work tree unless asked to keep it
if (-not $KeepWork) {
    Start-Sleep -Milliseconds 300
    Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Fail -eq 0) { exit 0 } else { exit 1 }