# ===========================================================================
#  Final supplementary checks for the frozen release (qa-reviewer).
#  Covers: portable ZIP content vs payload, shipped app test suite,
#  Launch.vbs browser-window behaviour, no registry side effects.
#  Run with Windows PowerShell 5.1:
#    powershell -NoProfile -ExecutionPolicy Bypass -File _test\verify\recheck-final.ps1
# ===========================================================================
$ErrorActionPreference = 'Stop'
$R = 'C:\Users\s2121270\Downloads\Hey-Logan-AI-Release'
$work = 'C:\Temp\hl-qa\finalcheck'
$out = Join-Path $R '_test\verify\portable-final-check.txt'
$log = New-Object System.Collections.Generic.List[string]
function A($t) { $script:log.Add($t); Write-Host $t }
function Check($name, $cond, $detail) {
    $s = if ($cond) { 'PASS' } else { 'FAIL' }
    A (('{0,-4} {1}  [{2}]' -f $s, $name, $detail))
}

A ('=== Final supplementary checks, qa-reviewer, ' + (Get-Date -Format 'o') + ' ===')
$zip = Join-Path $R 'dist\HeyLoganAI-Portable-1.0.0-win-x64.zip'
$payload = Join-Path $R 'windows\payload\HeyLoganAI'
A ('portable ZIP: ' + (Get-Item $zip).Length + ' bytes  SHA256 ' + (Get-FileHash $zip -Algorithm SHA256).Hash)
A ('payload tree: ' + @(Get-ChildItem $payload -Recurse -File).Count + ' files')
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Force $work | Out-Null
tar -xf $zip -C $work
$root = Join-Path $work 'HeyLoganAI'
$payloadFiles = @(Get-ChildItem $payload -Recurse -File)
$missing = @(); $mismatch = @()
foreach ($f in $payloadFiles) {
    $rel = $f.FullName.Substring($payload.Length + 1)
    $p2 = Join-Path $root $rel
    if (-not (Test-Path $p2)) { $missing += $rel; continue }
    if ((Get-FileHash $f.FullName -Algorithm SHA256).Hash -ne (Get-FileHash $p2 -Algorithm SHA256).Hash) { $mismatch += $rel }
}
Check 'payload tree extracted byte-identically from the portable ZIP' (($missing.Count -eq 0) -and ($mismatch.Count -eq 0)) ('missing=' + $missing.Count + ' mismatch=' + $mismatch.Count)
$extras = @(Get-ChildItem $root -Recurse -File | ForEach-Object { $_.FullName.Substring($root.Length + 1) } | Where-Object { -not (Test-Path (Join-Path $payload $_)) })
Check 'portable-only extra files are exactly README-FIRST + Start Hey Logan AI.cmd' ((($extras | Sort-Object) -join '|') -eq 'README-FIRST.txt|Start Hey Logan AI.cmd') (($extras | Sort-Object) -join ', ')
$startSrc = Join-Path $R 'windows\installer\portable\Start Hey Logan AI.cmd'
Check 'portable Start Hey Logan AI.cmd in ZIP == source (absolute-path fix present)' ((Get-FileHash (Join-Path $root 'Start Hey Logan AI.cmd') -Algorithm SHA256).Hash -eq (Get-FileHash $startSrc -Algorithm SHA256).Hash) ((Get-FileHash $startSrc -Algorithm SHA256).Hash)
$startText = Get-Content (Join-Path $root 'Start Hey Logan AI.cmd') -Raw
Check 'portable Start cmd launches node with absolute %~dp0 paths' (($startText -like '*"%~dp0runtime\node.exe" "%~dp0app\server\index.js"*')) ('line: ' + (($startText -split "`n" | Where-Object { $_ -match 'node\.exe' }) -join ' '))

# --- shipped app test suite from the frozen payload ---
$appDir = Join-Path $root 'app'
Push-Location $appDir
$savedEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'   # node writes benign warnings to stderr
$testOut = & (Join-Path $root 'runtime\node.exe') test\run.js 2>&1
$testCode = $LASTEXITCODE
$ErrorActionPreference = $savedEap
Pop-Location
$testTail = @($testOut | Select-Object -Last 10)
$passLine = @($testOut | Where-Object { $_ -match '^# pass ' })
$failLine = @($testOut | Where-Object { $_ -match '^# fail ' })
Check 'shipped app test suite passes (node test\run.js)' (($testCode -eq 0) -and ($failLine -match '0')) ($passLine + ' ' + $failLine)
A '  test summary: ' + (($testOut | Select-Object -Last 8) -join ' | ')

# --- registry snapshot before the portable run ---
function SnapReg {
    return [ordered]@{
        Arp = (Test-Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\HeyLoganAI')
        AppKey = (Test-Path 'HKCU:\Software\HeyLoganAI')
        Run = [bool](Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name HeyLoganAI -ErrorAction SilentlyContinue)
        Sm = (Test-Path (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Hey Logan AI'))
        Desk = (Test-Path (Join-Path $env:USERPROFILE 'Desktop\Hey Logan AI.lnk'))
    }
}
$preReg = SnapReg
A ('registry before: ' + ($preReg | ConvertTo-Json -Compress))

# --- Launch.vbs must bring the server up and open the chromeless app window ---
$edge = ''
foreach ($cand in @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe")) { if (Test-Path $cand) { $edge = $cand; break } }
$launch = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList ('"' + (Join-Path $root 'Launch.vbs') + '"') -PassThru
$health = $null
for ($i = 0; $i -lt 60; $i++) { try { $health = Invoke-RestMethod -Uri 'http://127.0.0.1:8787/api/health' -TimeoutSec 2 -UseBasicParsing } catch { $health = $null }; if ($health) { break }; Start-Sleep -Milliseconds 500 }
Check 'portable Launch.vbs -> /api/health ok' ($health -and $health.ok -eq $true) ($health | ConvertTo-Json -Compress)
Start-Sleep -Seconds 6
$browserProcs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -in @('msedge.exe', 'chrome.exe') -and $_.CommandLine -and $_.CommandLine.IndexOf('--app=http://127.0.0.1:8787', [StringComparison]::OrdinalIgnoreCase) -ge 0 })
Check 'chromeless app window opened (browser --app=http://127.0.0.1:8787)' ($browserProcs.Count -ge 1) ('processes=' + $browserProcs.Count + ' edge=' + (Split-Path $edge -Leaf))
if ($browserProcs.Count -gt 0) { A ('  window process: ' + $browserProcs[0].Name + ' pid ' + $browserProcs[0].ProcessId) }

# --- Stop.cmd must stop a Launch.vbs-started portable server ---
$stopWrapper = Join-Path $work 'run-stop.cmd'
Set-Content -Path $stopWrapper -Value @('@echo off', 'chcp 65001 >NUL', ('call "' + (Join-Path $root 'Stop.cmd') + '" < NUL > "' + (Join-Path $work 'stop.txt') + '" 2>&1')) -Encoding ASCII
$sp = Start-Process -FilePath $env:COMSPEC -ArgumentList @('/d', '/c', ('"' + $stopWrapper + '"')) -PassThru -Wait
Start-Sleep -Seconds 1
$healthAfter = $null
try { $healthAfter = Invoke-RestMethod -Uri 'http://127.0.0.1:8787/api/health' -TimeoutSec 2 -UseBasicParsing } catch { $healthAfter = $null }
$down = ($null -eq $healthAfter)
$stopText = if (Test-Path (Join-Path $work 'stop.txt')) { Get-Content (Join-Path $work 'stop.txt') -Raw } else { '' }
Check 'portable Stop.cmd stopped the Launch.vbs server' $down ('exit=' + $sp.ExitCode + ' / ' + ($stopText -replace '[\r\n]+', ' '))

# --- clean up browser windows + folder; confirm no registry/shortcut side effects ---
foreach ($b in $browserProcs) { try { Stop-Process -Id $b.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
try { Stop-Process -Id $launch.Id -Force -ErrorAction SilentlyContinue } catch { }
$postReg = SnapReg
Check 'portable run created no registry entries / shortcuts' (($postReg.Arp -eq $false) -and ($postReg.AppKey -eq $false) -and ($postReg.Run -eq $false) -and ($postReg.Sm -eq $false) -and ($postReg.Desk -eq $false)) ($postReg | ConvertTo-Json -Compress)
Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine -match 'server[\\/]index\.js' } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
Start-Sleep -Milliseconds 500
Check 'no node process / listener left after the check' (((@(Get-Process node -ErrorAction SilentlyContinue)).Count -eq 0) -and ((@(Get-NetTCPConnection -LocalPort 8787, 8443 -State Listen -ErrorAction SilentlyContinue)).Count -eq 0)) ''
if (Test-Path $work) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
$log | Set-Content -Path $out -Encoding UTF8
A ''
A ('evidence written: ' + $out)
