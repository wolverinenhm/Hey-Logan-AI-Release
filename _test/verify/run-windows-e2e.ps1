# ===========================================================================
#  Independent QA - clean-room Windows end-to-end verification
#  Hey Logan AI 1.0.0 (NSIS installer + portable ZIP)
#
#  Written by qa-reviewer. Covers task-7 part A (A1 structural evidence is
#  collected separately; this script covers A2-A7).
#
#  Run it from OUTSIDE the release workspace:
#    Copy-Item <release>\_test\verify\run-windows-e2e.ps1 C:\Temp\hl-qa\ -Force
#    pwsh -NoProfile -File C:\Temp\hl-qa\run-windows-e2e.ps1
#
#  The Setup.exe is copied to C:\Temp first (the DSH sandbox can hang GUI
#  executables launched from the workspace tree) and the copy's SHA-256 is
#  asserted against the dist file before anything runs.
#
#  It leaves the machine clean: no install dir, shortcuts, HKCU entries, node
#  processes/listeners. Logs are written to _test\verify\.
# ===========================================================================
[CmdletBinding()]
param(
    [string]$Root    = 'C:\Users\s2121270\Downloads\Hey-Logan-AI-Release',
    [string]$Work    = 'C:\Temp\hl-qa\e2e',
    [string]$OutDir  = 'C:\Users\s2121270\Downloads\Hey-Logan-AI-Release\_test\verify'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$script:Results   = New-Object System.Collections.Generic.List[object]
$script:PassCount = 0
$script:FailCount = 0
$script:SkipCount = 0
$script:Log       = New-Object System.Collections.Generic.List[string]
$script:Work      = $Work
$script:Root      = $Root

function Log {
    param([string]$Message)
    $line = ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message)
    Write-Host $line
    $script:Log.Add($line)
}

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
    $status = if ($ok) { 'PASS' } else { 'FAIL' }
    if ($ok) { $script:PassCount += 1 } else { $script:FailCount += 1 }
    $shown = ''
    if (-not [string]::IsNullOrEmpty($Detail)) { $shown = $Detail }
    elseif ($null -ne $Actual -and "$Actual".Length -le 180) { $shown = "$Actual" }
    $line = ('{0,-4} {1}' -f $status, $Name)
    if ($shown) { $line += ('  [' + ($shown -replace '[\r\n]+', ' ') + ']') }
    if ($err) { $line += ('  <error: ' + $err + '>') }
    Log $line
    $script:Results.Add([pscustomobject]@{ Status = $status; Name = $Name; Detail = $(if ($shown) { $shown } else { '' }) })
    return $ok
}

function Skip {
    param([string]$Name, [string]$Why)
    $script:SkipCount += 1
    Log ('SKIP ' + $Name + '  [' + $Why + ']')
    $script:Results.Add([pscustomobject]@{ Status = 'SKIP'; Name = $Name; Detail = $Why })
}

# --- small helpers ----------------------------------------------------------
function Get-Health {
    try {
        return Invoke-RestMethod -Uri 'http://127.0.0.1:8787/api/health' -TimeoutSec 3 -UseBasicParsing
    } catch { return $null }
}

function Wait-Health {
    param([int]$TimeoutSec = 60)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $h = Get-Health
        if ($null -ne $h -and $h.ok -eq $true) { return $h }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

function Wait-HealthDown {
    param([int]$TimeoutSec = 20)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ($null -eq (Get-Health)) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

function Get-NodeProcsFor {
    param([string]$Dir)
    $out = @()
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.CommandLine -and $_.CommandLine.IndexOf($Dir, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $out += $_ }
    }
    return $out
}

function Get-Listeners8787 {
    return @(Get-NetTCPConnection -LocalPort 8787,8443 -State Listen -ErrorAction SilentlyContinue)
}

function Get-PortableProcPids {
    param([string[]]$Markers)
    $pids = @()
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -ne 'msedge.exe' -and $_.Name -ne 'chrome.exe') { return }
        $cmd = "$($_.CommandLine)"
        foreach ($m in $Markers) {
            if ($cmd -and $cmd.IndexOf($m, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $pids += $_.ProcessId; break }
        }
    }
    return $pids
}

function Read-Lnk {
    param([string]$Path)
    $sh = New-Object -ComObject WScript.Shell
    $sc = $sh.CreateShortcut($Path)
    return [pscustomobject]@{
        TargetPath   = $sc.TargetPath
        Arguments    = $sc.Arguments
        IconLocation = $sc.IconLocation
        Description  = $sc.Description
    }
}

function Get-RegVal {
    param([string]$Path, [string]$Name)
    try { return (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { return $null }
}

function New-CmdWrapper {
    param([string]$Name, [string[]]$Lines)
    $path = Join-Path $script:Work ('wrap-' + $Name + '.cmd')
    $content = @('@echo off', 'chcp 65001 >NUL') + $Lines
    $content | Set-Content -Path $path -Encoding ASCII
    return $path
}

function Run-CmdCapture {
    param([string]$CommandLine, [string]$OutFile, [int]$TimeoutSec = 120)
    # Run the .cmd through a tiny wrapper file (avoids nested-quote hell) and feed
    # stdin from NUL so the script's trailing `pause` returns immediately.
    $wrapper = New-CmdWrapper -Name ([System.IO.Path]::GetFileNameWithoutExtension($OutFile)) -Lines @(
        ('call "' + $CommandLine + '" < NUL > "' + $OutFile + '" 2>&1')
    )
    $p = Start-Process -FilePath $env:COMSPEC -ArgumentList @('/d', '/c', ('"' + $wrapper + '"')) -PassThru -WindowStyle Hidden
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
        return -1
    }
    return $p.ExitCode
}

function Snapshot-Machine {
    $snap = [ordered]@{
        InstallDir   = (Test-Path "$env:LOCALAPPDATA\Programs\HeyLoganAI")
        CustomDir    = (Test-Path (Join-Path $script:Work 'custom-install'))
        ArpKey       = (Test-Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\HeyLoganAI')
        AppKey       = (Test-Path 'HKCU:\Software\HeyLoganAI')
        RunValue     = [bool](Get-RegVal 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' 'HeyLoganAI')
        SmGroup      = (Test-Path (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Hey Logan AI'))
        DesktopLnk   = (Test-Path (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Hey Logan AI.lnk'))
        NodeProcs    = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue).Count
        Listeners    = @(Get-NetTCPConnection -LocalPort 8787,8443 -State Listen -ErrorAction SilentlyContinue).Count
        HklmArpNames = @(Get-ChildItem 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName })
        HkcuArpNames = @(Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName })
        SmPrograms   = @(Get-ChildItem (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs') -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        DesktopFiles = @(Get-ChildItem ([Environment]::GetFolderPath('Desktop')) -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        LocalPrograms= @(Get-ChildItem "$env:LOCALAPPDATA\Programs" -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        FwRule       = [bool](Get-NetFirewallRule -DisplayName 'Hey Logan AI' -ErrorAction SilentlyContinue)
    }
    return $snap
}

function Stop-ServerViaCmd {
    param([string]$Dir, [string]$OutFile)
    $before = @(Get-NodeProcsFor -Dir $Dir).Count
    $code = Run-CmdCapture -CommandLine (Join-Path $Dir 'Stop.cmd') -OutFile $OutFile -TimeoutSec 60
    $down = Wait-HealthDown -TimeoutSec 20
    $after = @(Get-NodeProcsFor -Dir $Dir).Count
    return [pscustomobject]@{ ExitCode = $code; HealthDown = $down; ProcsBefore = $before; ProcsAfter = $after }
}

# ===========================================================================
#  Preconditions: clean machine, artifact hashes
# ===========================================================================
Log '=================================================================='
Log ' Hey Logan AI - independent Windows E2E verification (qa-reviewer)'
Log '=================================================================='

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$setupSrc     = Join-Path $Root 'dist\HeyLoganAI-Setup-1.0.0-win-x64.exe'
$portableSrc  = Join-Path $Root 'dist\HeyLoganAI-Portable-1.0.0-win-x64.zip'
$payloadSrc   = Join-Path $Root 'windows\payload\HeyLoganAI'
foreach ($p in @($setupSrc, $portableSrc, $payloadSrc)) {
    if (-not (Test-Path $p)) { throw "Missing required input: $p" }
}

$setupSha    = (Get-FileHash $setupSrc -Algorithm SHA256).Hash
$portableSha = (Get-FileHash $portableSrc -Algorithm SHA256).Hash
$setupSize   = (Get-Item $setupSrc).Length
$portableSize= (Get-Item $portableSrc).Length
Log ("Setup.exe    : $setupSrc")
Log ("               $setupSize bytes  SHA256 $setupSha")
Log ("Portable ZIP : $portableSrc")
Log ("               $portableSize bytes  SHA256 $portableSha")

$pre = Snapshot-Machine
$dirty = @()
if ($pre.InstallDir) { $dirty += 'install dir exists' }
if ($pre.CustomDir)  { $dirty += 'custom dir exists' }
if ($pre.ArpKey -or $pre.AppKey -or $pre.RunValue) { $dirty += 'HKCU entries exist' }
if ($pre.SmGroup -or $pre.DesktopLnk) { $dirty += 'shortcuts exist' }
if ($pre.NodeProcs -gt 0 -or $pre.Listeners -gt 0) { $dirty += 'node process/listener running' }
$cleanPre = ($dirty.Count -eq 0)
if (-not $cleanPre) {
    Log ('PRE-FLIGHT DIRTY MACHINE: ' + ($dirty -join '; '))
    Log 'Aborting without touching anything - another test is still using the machine.'
    $summary = [ordered]@{
        timestamp = (Get-Date).ToString('o'); aborted = $true; reason = ($dirty -join '; ')
        setup = @{ path = $setupSrc; size = $setupSize; sha256 = $setupSha }
        portable = @{ path = $portableSrc; size = $portableSize; sha256 = $portableSha }
    }
    $summary | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutDir 'windows-e2e-summary.json')
    Log ('log: ' + (Join-Path $OutDir 'windows-e2e.log'))
    exit 3
}
Check 'A2.0 machine is clean before the test' $true { param($x) $x } 'no install dir / shortcuts / HKCU / node procs / listeners'

# Fresh work dir (path is fixed and safe: C:\Temp\hl-qa\e2e)
if (Test-Path $script:Work) { Remove-Item -LiteralPath $script:Work -Recurse -Force }
New-Item -ItemType Directory -Force -Path $script:Work | Out-Null
$setupDir = Join-Path $script:Work 'setup'
New-Item -ItemType Directory -Force -Path $setupDir | Out-Null
$setupExe = Join-Path $setupDir 'HeyLoganAI-Setup-1.0.0-win-x64.exe'
Copy-Item -LiteralPath $setupSrc -Destination $setupExe -Force
$setupCopySha = (Get-FileHash $setupExe -Algorithm SHA256).Hash
Check 'A2.1 copied Setup.exe SHA256 == dist SHA256' ($setupCopySha -eq $setupSha) { param($x) $x } "$setupCopySha"

$inst    = "$env:LOCALAPPDATA\Programs\HeyLoganAI"
$custom  = Join-Path $script:Work 'custom-install'
$token   = $null

$spawnedBrowserPids = @()
$phase = 'start'

try {
    # =======================================================================
    #  A2 - clean silent install
    # =======================================================================
    Log ''
    Log '=== PHASE A2: silent install (/S) into the default per-user folder ==='
    $t0 = Get-Date
    $p = Start-Process -FilePath $setupExe -ArgumentList '/S' -PassThru -Wait
    $installSecs = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    Check 'A2.2 /S installer exit code 0' ($p.ExitCode -eq 0) { param($x) $x } ('exit=' + $p.ExitCode + ' in ' + $installSecs + 's')
    Check 'A2.3 install dir created' (Test-Path -LiteralPath $inst) { param($x) $x } $inst

    $instFiles = @(Get-ChildItem -LiteralPath $inst -Recurse -File -Force -ErrorAction SilentlyContinue)
    $relSet = @{}
    foreach ($f in $instFiles) { $relSet[$f.FullName.Substring($inst.Length + 1)] = $f }
    $payloadFileCount = @(Get-ChildItem -LiteralPath $payloadSrc -Recurse -File -Force).Count
    Check 'A2.4 installed file count == payload + Uninstall.exe' ($instFiles.Count -eq ($payloadFileCount + 1)) { param($x) $x } ('count=' + $instFiles.Count + ' (expected ' + ($payloadFileCount + 1) + ' = ' + $payloadFileCount + ' payload files + Uninstall.exe)')
    Check 'A2.5 Uninstall.exe present' (Test-Path -LiteralPath (Join-Path $inst 'Uninstall.exe')) { param($x) $x }
    Check 'A2.6 installed tree contains NO app\data before first run' (-not (Test-Path -LiteralPath (Join-Path $inst 'app\data'))) { param($x) $x }

    $payloadFiles = @(Get-ChildItem -LiteralPath $payloadSrc -Recurse -File -Force)
    $payloadRel = @{}
    foreach ($f in $payloadFiles) { $payloadRel[$f.FullName.Substring($payloadSrc.Length + 1)] = $f }
    $missing = @(); $mismatch = @()
    foreach ($rel in $payloadRel.Keys) {
        if (-not $relSet.ContainsKey($rel)) { $missing += $rel; continue }
        $h1 = (Get-FileHash -LiteralPath $payloadRel[$rel].FullName -Algorithm SHA256).Hash
        $h2 = (Get-FileHash -LiteralPath (Join-Path $inst $rel) -Algorithm SHA256).Hash
        if ($h1 -ne $h2) { $mismatch += $rel }
    }
    Check 'A2.7 every payload file installed byte-identically' (($missing.Count -eq 0) -and ($mismatch.Count -eq 0)) { param($x) $x } ('missing=' + $missing.Count + ' mismatch=' + $mismatch.Count)
    $extra = @($relSet.Keys | Where-Object { -not $payloadRel.ContainsKey($_) -and $_ -ne 'Uninstall.exe' })
    Check 'A2.8 no unexpected files in install dir' ($extra.Count -eq 0) { param($x) $x } ('extra=' + ($extra -join ', '))
    foreach ($rel in @('Launch.vbs', 'Start Console.cmd', 'Stop.cmd', 'Pairing.cmd', 'Allow through Firewall.cmd', 'HELP.txt', 'heylogan.ico', 'runtime\node.exe', 'tools\pair.js', 'tools\stop.ps1', 'tools\firewall.ps1', 'app\server\index.js', 'app\public\index.html', 'app\public\native-voice.js')) {
        Check ("A2.9 installed item: " + $rel) (Test-Path -LiteralPath (Join-Path $inst $rel)) { param($x) $x }
    }

    Log ''
    Log '=== PHASE A2: shortcuts, Add/Remove Programs, start-at-login, keys ==='
    $smGroup  = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Hey Logan AI'
    $deskLnk  = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Hey Logan AI.lnk'
    $smFiles  = @()
    if (Test-Path $smGroup) { $smFiles = @(Get-ChildItem $smGroup -Filter *.lnk | ForEach-Object { $_.Name } | Sort-Object) }
    Check 'A2.10 Start Menu group created' (Test-Path $smGroup) { param($x) $x } $smGroup
    Check 'A2.11 Start Menu group has exactly 6 shortcuts' ($smFiles.Count -eq 6) { param($x) $x } ($smFiles -join ' | ')
    Check 'A2.12 Start Menu main shortcut present' ($smFiles -contains 'Hey Logan AI.lnk') { param($x) $x }
    Check 'A2.13 Start Menu has Start Console / Pairing / Stop Server / Allow through Firewall' (($smFiles -contains 'Start Console.lnk') -and ($smFiles -contains 'Pairing.lnk') -and ($smFiles -contains 'Stop Server.lnk') -and ($smFiles -contains 'Allow through Firewall.lnk')) { param($x) $x }
    Check 'A2.14 Start Menu uninstall shortcut present' (($smFiles -contains 'Uninstall.lnk') -or ($smFiles -contains 'Uninstall Hey Logan AI.lnk')) { param($x) $x } (($smFiles | Where-Object { $_ -like 'Uninstall*' }) -join ' ')
    Check 'A2.15 Desktop shortcut created' (Test-Path $deskLnk) { param($x) $x } $deskLnk

    $mainLnk = $null
    if ($smFiles -contains 'Hey Logan AI.lnk') { $mainLnk = Read-Lnk (Join-Path $smGroup 'Hey Logan AI.lnk') }
    if ($mainLnk) {
        $expectWscript = (Join-Path $env:WINDIR 'System32\wscript.exe')
        Check 'A2.16 main shortcut target is wscript.exe' ($mainLnk.TargetPath.TrimEnd() -ieq $expectWscript) { param($x) $x } $mainLnk.TargetPath
        Check 'A2.17 main shortcut arguments point at Launch.vbs' ($mainLnk.Arguments -like ('*' + (Join-Path $inst 'Launch.vbs') + '*')) { param($x) $x } $mainLnk.Arguments
        Check 'A2.18 main shortcut icon is heylogan.ico' ($mainLnk.IconLocation -like ('*heylogan.ico*')) { param($x) $x } $mainLnk.IconLocation
    } else { Skip 'A2.16-A2.18 main shortcut target/args/icon' 'main shortcut not found' }

    if ($smFiles -contains 'Start Console.lnk') {
        $l = Read-Lnk (Join-Path $smGroup 'Start Console.lnk')
        Check 'A2.19 Start Console shortcut target' ($l.TargetPath -ieq (Join-Path $inst 'Start Console.cmd')) { param($x) $x } $l.TargetPath
    }
    if ($smFiles -contains 'Pairing.lnk') {
        $l = Read-Lnk (Join-Path $smGroup 'Pairing.lnk')
        Check 'A2.20 Pairing shortcut target' ($l.TargetPath -ieq (Join-Path $inst 'Pairing.cmd')) { param($x) $x } $l.TargetPath
    }
    if ($smFiles -contains 'Stop Server.lnk') {
        $l = Read-Lnk (Join-Path $smGroup 'Stop Server.lnk')
        Check 'A2.21 Stop Server shortcut target' ($l.TargetPath -ieq (Join-Path $inst 'Stop.cmd')) { param($x) $x } $l.TargetPath
    }
    if ($smFiles -contains 'Allow through Firewall.lnk') {
        $l = Read-Lnk (Join-Path $smGroup 'Allow through Firewall.lnk')
        Check 'A2.22 Allow through Firewall shortcut target' ($l.TargetPath -ieq (Join-Path $inst 'Allow through Firewall.cmd')) { param($x) $x } $l.TargetPath
    }
    $d = Read-Lnk $deskLnk
    Check 'A2.23 Desktop shortcut target is wscript.exe + Launch.vbs' (($d.TargetPath.TrimEnd() -ieq (Join-Path $env:WINDIR 'System32\wscript.exe')) -and ($d.Arguments -like ('*' + (Join-Path $inst 'Launch.vbs') + '*'))) { param($x) $x } ($d.TargetPath + ' ' + $d.Arguments)

    $arpKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\HeyLoganAI'
    $arp = Get-ItemProperty $arpKey -ErrorAction SilentlyContinue
    Check 'A2.24 ARP entry exists' ($null -ne $arp) { param($x) $x }
    if ($arp) {
        Check 'A2.25 ARP DisplayName' ($arp.DisplayName -eq 'Hey Logan AI') { param($x) $x } $arp.DisplayName
        Check 'A2.26 ARP DisplayVersion is 1.0.0' ($arp.DisplayVersion -eq '1.0.0') { param($x) $x } $arp.DisplayVersion
        Check 'A2.27 ARP Publisher' ($arp.Publisher -eq 'Hey Logan AI') { param($x) $x } $arp.Publisher
        Check 'A2.28 ARP InstallLocation == install dir' ($arp.InstallLocation -ieq $inst) { param($x) $x } $arp.InstallLocation
        Check 'A2.29 ARP UninstallString points at Uninstall.exe' ($arp.UninstallString -like ('*' + (Join-Path $inst 'Uninstall.exe') + '*')) { param($x) $x } $arp.UninstallString
        Check 'A2.30 ARP QuietUninstallString has /S' ($arp.QuietUninstallString -like '*Uninstall.exe* /S*') { param($x) $x } $arp.QuietUninstallString
        Check 'A2.31 ARP EstimatedSize > 0' ($arp.EstimatedSize -gt 0) { param($x) $x } ('EstimatedSize=' + $arp.EstimatedSize + ' KB')
        Check 'A2.32 ARP NoModify/NoRepair = 1' (($arp.NoModify -eq 1) -and ($arp.NoRepair -eq 1)) { param($x) $x }
        Check 'A2.33 ARP DisplayIcon is heylogan.ico' ($arp.DisplayIcon -like '*heylogan.ico*') { param($x) $x } $arp.DisplayIcon
    }
    $appKey = Get-ItemProperty 'HKCU:\Software\HeyLoganAI' -ErrorAction SilentlyContinue
    Check 'A2.34 HKCU\Software\HeyLoganAI InstallDir' (($null -ne $appKey) -and ($appKey.InstallDir -ieq $inst)) { param($x) $x } $(if ($appKey) { $appKey.InstallDir } else { '(missing)' })
    $runVal = Get-RegVal 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' 'HeyLoganAI'
    Check 'A2.35 start-at-login Run value exists (default component)' ($null -ne $runVal) { param($x) $x } $runVal
    if ($runVal) {
        Check 'A2.36 Run value = wscript.exe + Launch.vbs' (($runVal -like '*wscript.exe*') -and ($runVal -like ('*' + (Join-Path $inst 'Launch.vbs') + '*'))) { param($x) $x } $runVal
    }
    Check 'A2.37 no HKLM Add/Remove Programs entry added' ((@(Compare-Object $pre.HklmArpNames @(Get-ChildItem 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall' | ForEach-Object { $_.PSChildName }) -ErrorAction SilentlyContinue | Where-Object SideIndicator -eq '=>')).Count -eq 0) { param($x) $x }
    $pfx = Join-Path $env:ProgramFiles 'HeyLoganAI'
    Check 'A2.38 nothing installed under Program Files' (-not (Test-Path $pfx)) { param($x) $x } $pfx
    $localAdded = @(Compare-Object $pre.LocalPrograms @(Get-ChildItem "$env:LOCALAPPDATA\Programs" -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) | Where-Object SideIndicator -eq '=>' | ForEach-Object { $_.InputObject })
    Check 'A2.39 only HeyLoganAI added under %LOCALAPPDATA%\Programs' ((($localAdded -join ',') -eq 'HeyLoganAI')) { param($x) $x } ('added=' + ($localAdded -join ', '))

    # =======================================================================
    #  A3 - functional test of the installed app
    # =======================================================================
    Log ''
    Log '=== PHASE A3: launch via the shortcut, health, command, UI, pairing, stop ==='
    $mainTarget = (Join-Path $env:WINDIR 'System32\wscript.exe')
    $mainArgs   = '"' + (Join-Path $inst 'Launch.vbs') + '"'
    Log ('Launching shortcut target: ' + $mainTarget + ' ' + $mainArgs)
    $spawnedBrowserPids = @(Get-PortableProcPids -Markers @('--app=http://127.0.0.1:8787'))
    Start-Process -FilePath $mainTarget -ArgumentList $mainArgs | Out-Null
    $health = Wait-Health -TimeoutSec 75
    Check 'A3.1 /api/health after shortcut launch (<=75 s)' ($null -ne $health) { param($x) $x }
    if ($health) {
        Check 'A3.2 health ok:true' ($health.ok -eq $true) { param($x) $x }
        Check 'A3.3 health app == Hey Logan AI' ($health.app -eq 'Hey Logan AI') { param($x) $x } $health.app
        Check 'A3.4 health version == 1.0.0' ($health.version -eq '1.0.0') { param($x) $x } $health.version
    }
    $dataDir = Join-Path $inst 'app\data'
    $cfgPath = Join-Path $dataDir 'config.json'
    Check 'A3.5 first run created app\data\config.json' (Test-Path $cfgPath) { param($x) $x } $cfgPath
    Check 'A3.6 first run created app\data\certs\cert.pem + key.pem' ((Test-Path (Join-Path $dataDir 'certs\cert.pem')) -and (Test-Path (Join-Path $dataDir 'certs\key.pem'))) { param($x) $x }
    if (Test-Path $cfgPath) {
        $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
        $token = $cfg.security.token
        Check 'A3.7 config token is a 14-char XXXX-XXXX-XXXX token' ($token -match '^[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$') { param($x) $x } $token
        Check 'A3.8 config http port is 8787' ($cfg.server.httpPort -eq 8787) { param($x) $x }
        Check 'A3.9 config https port is 8443' ($cfg.server.httpsPort -eq 8443) { param($x) $x }
    }
    if ($token) {
        $hdr = @{ 'X-Bridge-Token' = $token }
        $si = Invoke-RestMethod -Uri 'http://127.0.0.1:8787/api/session-info' -Headers $hdr -TimeoutSec 10 -UseBasicParsing
        Check 'A3.10 /api/session-info with token ok' ($si.ok -eq $true) { param($x) $x }
        Check 'A3.11 session-info app name / version' (($si.app.name -eq 'Hey Logan AI') -and ($si.app.version -eq '1.0.0')) { param($x) $x } ($si.app.name + ' ' + $si.app.version)
        Check 'A3.12 session-info reports agents' ($si.agents.Count -ge 1) { param($x) $x } ('agents=' + $si.agents.Count)
        Check 'A3.13 session-info lists LAN https URL' (($si.server.urls.lan -join ',') -match 'https://') { param($x) $x } (($si.server.urls | ConvertTo-Json -Compress))
        # one real command through the API
        $cmdBody = @{ text = 'hey computer list my downloads folder'; sync = $true; source = 'pc'; clientId = 'qa-reviewer' } | ConvertTo-Json -Compress
        $cmdResp = Invoke-RestMethod -Uri 'http://127.0.0.1:8787/api/command' -Method Post -Headers $hdr -ContentType 'application/json' -Body $cmdBody -TimeoutSec 120 -UseBasicParsing
        $cmdText = if ($cmdResp.speech) { $cmdResp.speech } else { $cmdResp.text }
        Check 'A3.14 POST /api/command returned ok' ($cmdResp.ok -ne $false) { param($x) $x } ('ok=' + $cmdResp.ok)
        Check 'A3.15 command produced a spoken answer' (($null -ne $cmdText) -and ("$cmdText".Length -gt 0)) { param($x) $x } ("$cmdText".Substring(0, [Math]::Min(220, "$cmdText".Length)))
    } else { Skip 'A3.10-A3.15 token API checks' 'no token captured' }

    # headless Edge screenshot of the real UI
    $edge = ''
    foreach ($cand in @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe")) {
        if (Test-Path $cand) { $edge = $cand; break }
    }
    if ($edge -and $token) {
        $png = Join-Path $script:Work 'ui-installed.png'
        $prof = Join-Path $script:Work 'edge-profile'
        $edgeArgs = @(
            '--headless=new', '--disable-gpu', '--no-sandbox', '--hide-scrollbars', '--no-first-run',
            '--disable-extensions', '--disable-sync', "--user-data-dir=$prof",
            '--window-size=1280,900', "--screenshot=$png",
            ("http://127.0.0.1:8787/?token=" + $token)
        )
        $ep = Start-Process -FilePath $edge -ArgumentList $edgeArgs -PassThru -WindowStyle Hidden
        $deadline = (Get-Date).AddSeconds(40)
        while (-not $ep.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 400 }
        if (-not $ep.HasExited) { try { Stop-Process -Id $ep.Id -Force -ErrorAction SilentlyContinue } catch { } }
        Start-Sleep -Milliseconds 500
        $shotOk = (Test-Path $png) -and ((Get-Item $png -ErrorAction SilentlyContinue).Length -gt 5000)
        Check 'A3.16 headless-Edge screenshot of the running UI captured' $shotOk { param($x) $x } $(if (Test-Path $png) { (Get-Item $png).Length.ToString() + ' bytes' } else { 'missing' })
        if ($shotOk) { Copy-Item -LiteralPath $png -Destination (Join-Path $OutDir 'ui-installed.png') -Force }
    } else { Skip 'A3.16 headless-Edge screenshot' 'Edge or token unavailable' }

    # Pairing.cmd
    Log 'Running Pairing.cmd (captured, stdin NUL)'
    $pairOut = Join-Path $script:Work 'pairing-output.txt'
    $pairCode = Run-CmdCapture -CommandLine (Join-Path $inst 'Pairing.cmd') -OutFile $pairOut -TimeoutSec 90
    Start-Sleep -Milliseconds 800
    $pairText = ''
    if (Test-Path $pairOut) { $pairText = Get-Content $pairOut -Raw -Encoding UTF8 }
    Copy-Item -LiteralPath $pairOut -Destination (Join-Path $OutDir 'pairing-output.txt') -Force -ErrorAction SilentlyContinue
    Check 'A3.17 Pairing.cmd exits 0' ($pairCode -eq 0) { param($x) $x } ('exit=' + $pairCode)
    Check 'A3.18 Pairing output shows the access token' ($pairText -like ('*' + $token + '*')) { param($x) $x }
    Check 'A3.19 Pairing output shows a 192.168.* LAN address' ($pairText -match 'https://192\.168\.\d+\.\d+:8443') { param($x) $x } (($pairText -split "`n" | Where-Object { $_ -match '192\.168\.' } | Select-Object -First 2) -join ' / ')
    Check 'A3.20 Pairing output shows a QR code block' (($pairText -match 'Scan this QR code') -and (($pairText -split "`n").Count -gt 15)) { param($x) $x } ('lines=' + (($pairText -split "`n").Count))

    # Stop.cmd stops it
    Log 'Running Stop.cmd'
    $stopOut = Join-Path $script:Work 'stop-output.txt'
    $stop = Stop-ServerViaCmd -Dir $inst -OutFile $stopOut
    Copy-Item -LiteralPath $stopOut -Destination (Join-Path $OutDir 'stop-output.txt') -Force -ErrorAction SilentlyContinue
    Check 'A3.21 Stop.cmd exits 0' ($stop.ExitCode -eq 0) { param($x) $x } ('exit=' + $stop.ExitCode)
    Check 'A3.22 Stop.cmd stopped the server (health down)' ($stop.HealthDown -eq $true) { param($x) $x }
    Check 'A3.23 no node process left for the install dir' ($stop.ProcsAfter -eq 0) { param($x) $x } ('before=' + $stop.ProcsBefore + ' after=' + $stop.ProcsAfter)
    Check 'A3.24 no listener left on 8787/8443' ((Get-Listeners8787).Count -eq 0) { param($x) $x }

    # start again -> repeat use
    Log 'Restarting via the shortcut target to prove repeat use'
    Start-Process -FilePath $mainTarget -ArgumentList $mainArgs | Out-Null
    $health2 = Wait-Health -TimeoutSec 75
    Check 'A3.25 second launch works (/api/health again)' ($health2 -and $health2.ok -eq $true) { param($x) $x }
    $stop2 = Stop-ServerViaCmd -Dir $inst -OutFile (Join-Path $script:Work 'stop-output-2.txt')
    Check 'A3.26 second stop works' (($stop2.ExitCode -eq 0) -and $stop2.HealthDown) { param($x) $x } ('exit=' + $stop2.ExitCode)

    # --- installed "Start Console.cmd" launch mode (documented Start-Menu shortcut) ---
    Log 'Testing installed "Start Console.cmd" launch mode + Stop.cmd'
    $consoleWrapper = New-CmdWrapper -Name 'installed-console' -Lines @(('call "' + (Join-Path $inst 'Start Console.cmd') + '"'))
    $ic = Start-Process -FilePath $env:COMSPEC -ArgumentList @('/d', '/c', ('"' + $consoleWrapper + '"')) -PassThru -WindowStyle Hidden
    $hConsole = Wait-Health -TimeoutSec 75
    Check 'A3b.1 installed Start Console.cmd brings the server up' ($hConsole -and $hConsole.ok -eq $true) { param($x) $x }
    $instConsoleNodes = @(Get-NodeProcsFor -Dir $inst)
    $instConsoleCmd = if ($instConsoleNodes.Count -gt 0) { $instConsoleNodes[0].CommandLine } else { '(none)' }
    Log ('installed console-mode node command line: ' + $instConsoleCmd)
    $stopConsoleInst = Stop-ServerViaCmd -Dir $inst -OutFile (Join-Path $script:Work 'stop-output-installed-console.txt')
    Copy-Item -LiteralPath (Join-Path $script:Work 'stop-output-installed-console.txt') -Destination (Join-Path $OutDir 'stop-output-installed-console.txt') -Force -ErrorAction SilentlyContinue
    Check 'A3b.2 installed console-mode server is stopped by Stop.cmd' (($stopConsoleInst.ExitCode -eq 0) -and $stopConsoleInst.HealthDown) { param($x) $x } ('exit=' + $stopConsoleInst.ExitCode + ' procsAfter=' + $stopConsoleInst.ProcsAfter)
    Check 'A3b.3 installed console mode left no node process' ($stopConsoleInst.ProcsAfter -eq 0) { param($x) $x }
    try { Stop-Process -Id $ic.Id -Force -ErrorAction SilentlyContinue } catch { }

    # close browser windows that Launch.vbs opened (only ours)
    foreach ($bpid in $spawnedBrowserPids) { } # (baseline)
    $appBrowser = @(Get-PortableProcPids -Markers @('--app=http://127.0.0.1:8787'))
    if ($appBrowser.Count -gt 0) {
        Log ('Closing ' + $appBrowser.Count + ' app-window browser process(es) opened by Launch.vbs')
        foreach ($bpid in $appBrowser) { try { Stop-Process -Id $bpid -Force -ErrorAction SilentlyContinue } catch { } }
    }

    # =======================================================================
    #  A4 - upgrade in place
    # =======================================================================
    Log ''
    Log '=== PHASE A4: re-run the installer (/S) over the existing install ==='
    $tokenBefore = $token
    $cfgBefore = Get-Content $cfgPath -Raw | ConvertFrom-Json
    # A real user upgrades while the app is running: start it via the shortcut target first.
    Start-Process -FilePath $mainTarget -ArgumentList $mainArgs | Out-Null
    $hUp = Wait-Health -TimeoutSec 60
    Check 'A4.0 app running before the upgrade' ($hUp -and $hUp.ok -eq $true) { param($x) $x }
    $p = Start-Process -FilePath $setupExe -ArgumentList '/S' -PassThru -Wait
    Check 'A4.1 upgrade installer exit code 0' ($p.ExitCode -eq 0) { param($x) $x } ('exit=' + $p.ExitCode)
    Start-Sleep -Seconds 1
    $cfgAfter = Get-Content $cfgPath -Raw | ConvertFrom-Json
    Check 'A4.2 access token unchanged after upgrade' ($cfgAfter.security.token -eq $tokenBefore) { param($x) $x } $cfgAfter.security.token
    Check 'A4.3 config settings unchanged after upgrade' (($cfgAfter | ConvertTo-Json -Depth 8) -eq ($cfgBefore | ConvertTo-Json -Depth 8)) { param($x) $x }
    $smFiles2 = @(Get-ChildItem $smGroup -Filter *.lnk -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    Check 'A4.4 upgrade did not duplicate Start Menu shortcuts' ($smFiles2.Count -eq 6) { param($x) $x } ('count=' + $smFiles2.Count)
    Check 'A4.5 desktop shortcut still single' (@(Get-ChildItem ([Environment]::GetFolderPath('Desktop')) -Filter 'Hey Logan AI*.lnk' -ErrorAction SilentlyContinue).Count -eq 1) { param($x) $x }
    Check 'A4.6 ARP entry still single after upgrade' ((Test-Path $arpKey) -and (@(Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' | Where-Object { $_.PSChildName -eq 'HeyLoganAI' }).Count -eq 1)) { param($x) $x }
    Check 'A4.7 upgrade kept app\data (config.json still present)' (Test-Path $cfgPath) { param($x) $x }
    Check 'A4.8 upgrade stopped the running server' (Wait-HealthDown -TimeoutSec 30) { param($x) $x }
    Check 'A4.9 upgrade left no node process behind' ((@(Get-NodeProcsFor -Dir $inst)).Count -eq 0) { param($x) $x }
    $appBrowserUp = @(Get-PortableProcPids -Markers @('--app=http://127.0.0.1:8787'))
    foreach ($bpid in $appBrowserUp) { try { Stop-Process -Id $bpid -Force -ErrorAction SilentlyContinue } catch { } }

    # =======================================================================
    #  A4b - upgrade must ABORT (not delete data) when app\data cannot be stashed
    # =======================================================================
    Log ''
    Log '=== PHASE A4b: locked app\data\config.json -> silent upgrade aborts, data + program files intact ==='
    $tokenPreLock    = (Get-Content $cfgPath -Raw | ConvertFrom-Json).security.token
    $launchHashBefore = (Get-FileHash -LiteralPath (Join-Path $inst 'Launch.vbs') -Algorithm SHA256).Hash
    $nodeHashBefore   = (Get-FileHash -LiteralPath (Join-Path $inst 'runtime\node.exe') -Algorithm SHA256).Hash
    $uninstHashBefore = (Get-FileHash -LiteralPath (Join-Path $inst 'Uninstall.exe') -Algorithm SHA256).Hash
    $uninstSizeBefore = (Get-Item -LiteralPath (Join-Path $inst 'Uninstall.exe')).Length
    $lock = [System.IO.File]::Open($cfgPath, 'Open', 'ReadWrite', 'None')
    $pAbort = $null
    try {
        $pAbort = Start-Process -FilePath $setupExe -ArgumentList '/S' -PassThru -Wait
    }
    finally {
        $lock.Close()
    }
    Check 'A4b.1 locked-data silent upgrade aborts with exit code 1' ($pAbort.ExitCode -eq 1) { param($x) $x } ('exit=' + $pAbort.ExitCode)
    Check 'A4b.2 access token intact after the aborted upgrade' ((Get-Content $cfgPath -Raw | ConvertFrom-Json).security.token -eq $tokenPreLock) { param($x) $x }
    Check 'A4b.3 certificate files intact after the aborted upgrade' ((Test-Path (Join-Path $dataDir 'certs\cert.pem')) -and (Test-Path (Join-Path $dataDir 'certs\key.pem'))) { param($x) $x }
    Check 'A4b.4 no stashed .hl-data-keep left behind' (-not (Test-Path -LiteralPath (Join-Path $inst '.hl-data-keep'))) { param($x) $x }
    Check 'A4b.5 Launch.vbs untouched after abort' ((Get-FileHash -LiteralPath (Join-Path $inst 'Launch.vbs') -Algorithm SHA256).Hash -eq $launchHashBefore) { param($x) $x }
    Check 'A4b.6 runtime\node.exe untouched after abort' ((Get-FileHash -LiteralPath (Join-Path $inst 'runtime\node.exe') -Algorithm SHA256).Hash -eq $nodeHashBefore) { param($x) $x }
    Check 'A4b.7 Uninstall.exe untouched after abort' (((Get-FileHash -LiteralPath (Join-Path $inst 'Uninstall.exe') -Algorithm SHA256).Hash -eq $uninstHashBefore) -and ((Get-Item -LiteralPath (Join-Path $inst 'Uninstall.exe')).Length -eq $uninstSizeBefore)) { param($x) $x }
    Check 'A4b.8 ARP entry intact after abort (install still registered)' (Test-Path $arpKey) { param($x) $x }
    # once the lock is gone, the normal upgrade path must still work
    $p = Start-Process -FilePath $setupExe -ArgumentList '/S' -PassThru -Wait
    Check 'A4b.9 normal silent upgrade after the lock is released (exit 0)' ($p.ExitCode -eq 0) { param($x) $x } ('exit=' + $p.ExitCode)
    Check 'A4b.10 token still unchanged after the successful upgrade' ((Get-Content $cfgPath -Raw | ConvertFrom-Json).security.token -eq $tokenPreLock) { param($x) $x }

    # =======================================================================
    #  A5 - uninstall /S (keep data)
    # =======================================================================
    Log ''
    Log '=== PHASE A5: silent uninstall (keep app\data) ==='
    $uninstExe = Join-Path $inst 'Uninstall.exe'
    Check 'A5.1 Uninstall.exe exists before uninstall' (Test-Path $uninstExe) { param($x) $x }
    $p = Start-Process -FilePath $uninstExe -ArgumentList '/S' -PassThru -Wait
    Check 'A5.2 Uninstall.exe /S exit code 0' ($p.ExitCode -eq 0) { param($x) $x } ('exit=' + $p.ExitCode)
    Start-Sleep -Milliseconds 800
    Check 'A5.3 shortcuts removed (Start Menu group)' (-not (Test-Path $smGroup)) { param($x) $x }
    Check 'A5.4 Desktop shortcut removed' (-not (Test-Path $deskLnk)) { param($x) $x }
    Check 'A5.5 ARP entry removed' (-not (Test-Path $arpKey)) { param($x) $x }
    Check 'A5.6 HKCU app key removed' (-not (Test-Path 'HKCU:\Software\HeyLoganAI')) { param($x) $x }
    Check 'A5.7 Run value removed' ($null -eq (Get-RegVal 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' 'HeyLoganAI')) { param($x) $x }
    Check 'A5.8 app\data kept as documented' (Test-Path $cfgPath) { param($x) $x } $cfgPath
    Check 'A5.9 runtime\node.exe removed' (-not (Test-Path (Join-Path $inst 'runtime'))) { param($x) $x }
    Check 'A5.10 Launch.vbs / Uninstall.exe removed' ((-not (Test-Path (Join-Path $inst 'Launch.vbs'))) -and (-not (Test-Path (Join-Path $inst 'Uninstall.exe')))) { param($x) $x }
    Check 'A5.11 no node process/listener after uninstall' (((@(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue)).Count -eq 0) -and ((Get-Listeners8787).Count -eq 0)) { param($x) $x }
    # remove leftovers (kept app\data) so the next cycle starts clean
    if (Test-Path $inst) { Remove-Item -LiteralPath $inst -Recurse -Force -ErrorAction SilentlyContinue }
    Check 'A5.12 leftover install folder removed by QA' (-not (Test-Path $inst)) { param($x) $x }

    # =======================================================================
    #  A7 - custom /D= install + ARP UninstallString
    # =======================================================================
    Log ''
    Log '=== PHASE A7: custom-directory install (/S /D=) + uninstall via ARP UninstallString ==='
    $p = Start-Process -FilePath $setupExe -ArgumentList '/S', ("/D=" + $custom) -PassThru -Wait
    Check 'A7.1 /S /D= custom-dir installer exit code 0' ($p.ExitCode -eq 0) { param($x) $x } ('exit=' + $p.ExitCode)
    Check 'A7.2 custom dir created with Launch.vbs' (Test-Path (Join-Path $custom 'Launch.vbs')) { param($x) $x } $custom
    Check 'A7.3 custom dir has runtime\node.exe' (Test-Path (Join-Path $custom 'runtime\node.exe')) { param($x) $x }
    $arpCustom = Get-ItemProperty $arpKey -ErrorAction SilentlyContinue
    Check 'A7.4 ARP InstallLocation is the custom dir' ($arpCustom -and ($arpCustom.InstallLocation -ieq $custom)) { param($x) $x } $(if ($arpCustom) { $arpCustom.InstallLocation } else { '(missing)' })
    $customMain = Read-Lnk (Join-Path $smGroup 'Hey Logan AI.lnk')
    Check 'A7.5 main shortcut points at the custom dir Launch.vbs' ($customMain.Arguments -like ('*' + (Join-Path $custom 'Launch.vbs') + '*')) { param($x) $x } $customMain.Arguments
    $unstr = $arpCustom.UninstallString
    Check 'A7.6 ARP UninstallString points at custom Uninstall.exe' ($unstr -like ('*' + (Join-Path $custom 'Uninstall.exe') + '*')) { param($x) $x } $unstr
    # invoke exactly the ARP UninstallString (silent, so no message box is clicked)
    $exePath = $unstr.Trim()
    if ($exePath.StartsWith('"')) { $exePath = $exePath.Substring(1); $quote = $exePath.IndexOf('"'); if ($quote -ge 0) { $exePath = $exePath.Substring(0, $quote) } }
    Log ('Invoking ARP UninstallString (with /S): ' + $exePath + ' /S')
    $p = Start-Process -FilePath $exePath -ArgumentList '/S' -PassThru -Wait
    Start-Sleep -Milliseconds 800
    Check 'A7.7 ARP UninstallString /S exit code 0' ($p.ExitCode -eq 0) { param($x) $x } ('exit=' + $p.ExitCode)
    Check 'A7.8 custom install dir removed' (-not (Test-Path $custom)) { param($x) $x }
    Check 'A7.9 ARP entry removed after custom uninstall' (-not (Test-Path $arpKey)) { param($x) $x }
    Check 'A7.10 shortcuts removed after custom uninstall' ((-not (Test-Path $smGroup)) -and (-not (Test-Path $deskLnk))) { param($x) $x }
    if (Test-Path $custom) { Remove-Item -LiteralPath $custom -Recurse -Force -ErrorAction SilentlyContinue }

    # =======================================================================
    #  A5b - /NOAUTOSTART + purge uninstall
    # =======================================================================
    Log ''
    Log '=== PHASE A5b: /S /NOAUTOSTART install (no Run value) + /PURGEDATA uninstall ==='
    $p = Start-Process -FilePath $setupExe -ArgumentList '/S', '/NOAUTOSTART' -PassThru -Wait
    Check 'A5b.1 silent install with /NOAUTOSTART exit code 0' ($p.ExitCode -eq 0) { param($x) $x } ('exit=' + $p.ExitCode)
    Check 'A5b.2 /NOAUTOSTART wrote NO start-at-login Run value' ($null -eq (Get-RegVal 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' 'HeyLoganAI')) { param($x) $x }
    Check 'A5b.3 /NOAUTOSTART still installed the app (Launch.vbs present)' (Test-Path (Join-Path $inst 'Launch.vbs')) { param($x) $x }
    Check 'A5b.4 /NOAUTOSTART still created the shortcuts' ((Test-Path $smGroup) -and (Test-Path $deskLnk)) { param($x) $x }
    $p = Start-Process -FilePath (Join-Path $inst 'Uninstall.exe') -ArgumentList '/S', '/PURGEDATA' -PassThru -Wait
    Start-Sleep -Milliseconds 800
    Check 'A5b.5 Uninstall.exe /S /PURGEDATA exit code 0' ($p.ExitCode -eq 0) { param($x) $x } ('exit=' + $p.ExitCode)
    Check 'A5b.6 install folder fully removed (no app\data left)' (-not (Test-Path $inst)) { param($x) $x }
    Check 'A5b.7 registry fully removed after purge' ((-not (Test-Path $arpKey)) -and (-not (Test-Path 'HKCU:\Software\HeyLoganAI'))) { param($x) $x }
    Skip 'A5b.8 interactive uninstall keep/delete message box' 'no interactive clicks possible in this agent session (documented limitation)'

    # =======================================================================
    #  A6 - portable ZIP
    # =======================================================================
    Log ''
    Log '=== PHASE A6: portable ZIP (extract, run, no registry/shortcut side effects) ==='
    $portable = Join-Path $script:Work 'portable'
    New-Item -ItemType Directory -Force -Path $portable | Out-Null
    $prePortable = Snapshot-Machine
    tar -xf $portableSrc -C $portable
    $portableRoot = Join-Path $portable 'HeyLoganAI'
    Check 'A6.1 portable ZIP extracted (exit 0)' (Test-Path (Join-Path $portableRoot 'Launch.vbs')) { param($x) $x } $portableRoot
    Check 'A6.2 portable README-FIRST.txt + Start Hey Logan AI.cmd present' ((Test-Path (Join-Path $portableRoot 'README-FIRST.txt')) -and (Test-Path (Join-Path $portableRoot 'Start Hey Logan AI.cmd'))) { param($x) $x }
    Check 'A6.3 portable payload has no app\data before first run' (-not (Test-Path (Join-Path $portableRoot 'app\data'))) { param($x) $x }
    # launch via Launch.vbs
    $plTarget = (Join-Path $env:WINDIR 'System32\wscript.exe')
    $plArgs = '"' + (Join-Path $portableRoot 'Launch.vbs') + '"'
    Start-Process -FilePath $plTarget -ArgumentList $plArgs | Out-Null
    $ph = Wait-Health -TimeoutSec 75
    Check 'A6.4 portable Launch.vbs brings the server up' ($ph -and $ph.ok -eq $true) { param($x) $x }
    Check 'A6.5 portable run created its own app\data' (Test-Path (Join-Path $portableRoot 'app\data\config.json')) { param($x) $x }
    $postPortableReg = Snapshot-Machine
    Check 'A6.6 portable run created no ARP entry' (-not $postPortableReg.ArpKey) { param($x) $x }
    Check 'A6.7 portable run created no Run value' (-not $postPortableReg.RunValue) { param($x) $x }
    Check 'A6.8 portable run created no Start Menu group / desktop shortcut' ((-not $postPortableReg.SmGroup) -and (-not $postPortableReg.DesktopLnk)) { param($x) $x }
    # stop portable server with its own stop script
    $plStop = Join-Path $portableRoot 'tools\stop.ps1'
    $ps = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $plStop + '"')) -PassThru -Wait -WindowStyle Hidden
    $downP = Wait-HealthDown -TimeoutSec 25
    Check 'A6.9 portable tools\stop.ps1 stops the server' (($ps.ExitCode -eq 0) -and $downP) { param($x) $x } ('exit=' + $ps.ExitCode)
    Check 'A6.10 no node process left for the portable folder' ((@(Get-NodeProcsFor -Dir $portableRoot)).Count -eq 0) { param($x) $x }
    Check 'A6.11 no listener left after portable stop' ((Get-Listeners8787).Count -eq 0) { param($x) $x }
    # also prove the visible-console portable launcher starts the server
    $consoleCmd = Join-Path $portableRoot 'Start Hey Logan AI.cmd'
    $cp = Start-Process -FilePath $env:COMSPEC -ArgumentList @('/d', '/c', ('"' + (New-CmdWrapper -Name 'portable-console' -Lines @(('call "' + $consoleCmd + '"'))) + '"')) -PassThru -WindowStyle Hidden
    $ph2 = Wait-Health -TimeoutSec 75
    Check 'A6.12 portable Start Hey Logan AI.cmd brings the server up' ($ph2 -and $ph2.ok -eq $true) { param($x) $x }
    # Documented portable stop path for a console-launched server: portable
    # README-FIRST.txt says "close the console window, or run Stop.cmd".
    $plStopOut = Join-Path $script:Work 'portable-console-stop-output.txt'
    $stopConsole = Stop-ServerViaCmd -Dir $portableRoot -OutFile $plStopOut
    Copy-Item -LiteralPath $plStopOut -Destination (Join-Path $OutDir 'portable-console-stop-output.txt') -Force -ErrorAction SilentlyContinue
    $consoleNodes = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine -match 'server[\\/]index\.js' })
    $consoleNodeCmd = if ($consoleNodes.Count -gt 0) { $consoleNodes[0].CommandLine } else { '(none)' }
    $downConsole = Wait-HealthDown -TimeoutSec 20
    Check 'A6.13 portable Stop.cmd stops a console-launched portable server' (($stopConsole.ExitCode -eq 0) -and $downConsole) { param($x) $x } ('Stop.cmd exit=' + $stopConsole.ExitCode + ' / server still running: ' + $consoleNodeCmd)
    # QA cleanup: kill the server the documented Stop.cmd did not stop, so the
    # final clean-machine assertions are meaningful (the failure above is the finding).
    foreach ($np in $consoleNodes) { try { Stop-Process -Id $np.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
    try { Stop-Process -Id $cp.Id -Force -ErrorAction SilentlyContinue } catch { }
    Start-Sleep -Milliseconds 800
    Check 'A6.14 QA cleanup of the console-launched portable server' ((Get-Listeners8787).Count -eq 0) { param($x) $x }
    # close any browser windows the portable Launch.vbs opened
    $appBrowser = @(Get-PortableProcPids -Markers @('--app=http://127.0.0.1:8787'))
    foreach ($bpid in $appBrowser) { try { Stop-Process -Id $bpid -Force -ErrorAction SilentlyContinue } catch { } }

    # =======================================================================
    #  Final clean-machine checks
    # =======================================================================
    Log ''
    Log '=== PHASE A8: final clean-machine check ==='
    if (Test-Path $portableRoot) { Remove-Item -LiteralPath $portableRoot -Recurse -Force -ErrorAction SilentlyContinue }
    $post = Snapshot-Machine
    Check 'A8.1 no install dir' (-not $post.InstallDir) { param($x) $x }
    Check 'A8.2 no custom install dir' (-not $post.CustomDir) { param($x) $x }
    Check 'A8.3 no ARP entry' (-not $post.ArpKey) { param($x) $x }
    Check 'A8.4 no HKCU app key' (-not $post.AppKey) { param($x) $x }
    Check 'A8.5 no Run value' (-not $post.RunValue) { param($x) $x }
    Check 'A8.6 no Start Menu group' (-not $post.SmGroup) { param($x) $x }
    Check 'A8.7 no desktop shortcut' (-not $post.DesktopLnk) { param($x) $x }
    Check 'A8.8 no node processes' ($post.NodeProcs -eq 0) { param($x) $x } ('count=' + $post.NodeProcs)
    Check 'A8.9 no listeners on 8787/8443' ($post.Listeners -eq 0) { param($x) $x } ('count=' + $post.Listeners)
    Check 'A8.10 no firewall rule added' ($post.FwRule -eq $false) { param($x) $x }
    $newSm = @(Compare-Object $pre.SmPrograms $post.SmPrograms -ErrorAction SilentlyContinue | Where-Object SideIndicator -eq '=>' | ForEach-Object { $_.InputObject })
    Check 'A8.11 no leftover entries in Start Menu Programs' ($newSm.Count -eq 0) { param($x) $x } ($newSm -join ', ')
    $newDesk = @(Compare-Object $pre.DesktopFiles $post.DesktopFiles -ErrorAction SilentlyContinue | Where-Object SideIndicator -eq '=>' | ForEach-Object { $_.InputObject })
    Check 'A8.12 no leftover files on the Desktop' ($newDesk.Count -eq 0) { param($x) $x } ($newDesk -join ', ')
    $newHklm = @(Compare-Object $pre.HklmArpNames $post.HklmArpNames -ErrorAction SilentlyContinue | Where-Object SideIndicator -eq '=>' | ForEach-Object { $_.InputObject })
    Check 'A8.13 no HKLM Add/Remove Programs changes' ($newHklm.Count -eq 0) { param($x) $x } ($newHklm -join ', ')
}
catch {
    Log ('FATAL: ' + $_.Exception.Message)
    Log ($_.ScriptStackTrace)
    $script:FailCount += 1
    $script:Results.Add([pscustomobject]@{ Status = 'FAIL'; Name = 'FATAL: ' + $_.Exception.Message; Detail = '' })
}
finally {
    Log ''
    Log '=== CLEANUP ==='
    # Kill any node.exe that the tests started (a console-launched server has a
    # relative command line that tools\stop.ps1 cannot match - see finding).
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.CommandLine -and ($_.CommandLine -match 'server[\\/]index\.js')) {
            try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
    # best effort: uninstall/remove anything this script may have left
    foreach ($dir in @($inst, $custom)) {
        if (Test-Path (Join-Path $dir 'Uninstall.exe')) {
            try { Start-Process -FilePath (Join-Path $dir 'Uninstall.exe') -ArgumentList '/S', '/PURGEDATA' -Wait -ErrorAction SilentlyContinue } catch { }
            Start-Sleep -Milliseconds 500
        }
        if (Test-Path $dir) {
            $procs = @(Get-NodeProcsFor -Dir $dir)
            foreach ($pr in $procs) { try { Stop-Process -Id $pr.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
            try { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
    foreach ($k in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\HeyLoganAI', 'HKCU:\Software\HeyLoganAI')) {
        if (Test-Path $k) { Remove-Item -Path $k -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if ($null -ne (Get-RegVal $runKey 'HeyLoganAI')) { Remove-ItemProperty -Path $runKey -Name 'HeyLoganAI' -Force -ErrorAction SilentlyContinue }
    $smG = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Hey Logan AI'
    if (Test-Path $smG) { Remove-Item -LiteralPath $smG -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $deskLnk) { Remove-Item -LiteralPath $deskLnk -Force -ErrorAction SilentlyContinue }
    $appBrowser = @(Get-PortableProcPids -Markers @('--app=http://127.0.0.1:8787'))
    foreach ($bpid in $appBrowser) { try { Stop-Process -Id $bpid -Force -ErrorAction SilentlyContinue } catch { } }
    Get-CimInstance Win32_Process -Filter "Name='wscript.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.CommandLine -and $_.CommandLine -like '*Launch.vbs*' -and ($_.CommandLine -like ('*' + $script:Work + '*') -or $_.CommandLine -like ('*' + $inst + '*'))) {
            try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
    $portableDir = Join-Path $script:Work 'portable'
    if (Test-Path $portableDir) { Remove-Item -LiteralPath $portableDir -Recurse -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
    # remove the scratch tree (logs/evidence already live in _test\verify)
    if (Test-Path $script:Work) { Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue }
    $final = Snapshot-Machine
    Log ('clean after cleanup: installDir=' + $final.InstallDir + ' custom=' + $final.CustomDir + ' arp=' + $final.ArpKey + ' appKey=' + $final.AppKey + ' run=' + $final.RunValue + ' sm=' + $final.SmGroup + ' desk=' + $final.DesktopLnk + ' node=' + $final.NodeProcs + ' listeners=' + $final.Listeners)

    # write logs + summary (do this after cleanup so the summary reflects the final state)
    $summary = [ordered]@{
        timestamp   = (Get-Date).ToString('o')
        host        = $env:COMPUTERNAME
        setup       = @{ path = $setupSrc; size = $setupSize; sha256 = $setupSha }
        portable    = @{ path = $portableSrc; size = $portableSize; sha256 = $portableSha }
        checks      = ($script:PassCount + $script:FailCount)
        passed      = $script:PassCount
        failed      = $script:FailCount
        skipped     = $script:SkipCount
        failures    = @($script:Results | Where-Object { $_.Status -eq 'FAIL' } | ForEach-Object { $_.Name })
        finalState  = [ordered]@{ installDir = $final.InstallDir; arp = $final.ArpKey; run = $final.RunValue; sm = $final.SmGroup; desk = $final.DesktopLnk; node = $final.NodeProcs; listeners = $final.Listeners }
        logPath     = (Join-Path $OutDir 'windows-e2e.log')
    }
    $script:Log | Set-Content -Path (Join-Path $OutDir 'windows-e2e.log') -Encoding UTF8
    $summary | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $OutDir 'windows-e2e-summary.json') -Encoding UTF8
    $script:Results | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $OutDir 'windows-e2e-results.json') -Encoding UTF8

    Log ''
    Log ('SUMMARY: checks=' + ($script:PassCount + $script:FailCount) + ' PASS=' + $script:PassCount + ' FAIL=' + $script:FailCount + ' SKIP=' + $script:SkipCount)
    Log ('log: ' + (Join-Path $OutDir 'windows-e2e.log'))
    if ($script:FailCount -gt 0) { exit 1 } else { exit 0 }
}
