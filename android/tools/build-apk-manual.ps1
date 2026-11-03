# ===========================================================================
#  Hey Logan AI - build a signed Android APK with the raw SDK tools.
#
#  Gradle cannot run in this build environment (its native helper library
#  cannot be loaded), so this script drives the Android build tools directly:
#     aapt2 compile  -> aapt2 link -> javac -> d8 -> zip -> zipalign -> apksigner
#
#  Requirements:
#    - JDK 17              (set JAVA_HOME or pass -JdkDir)
#    - Android SDK         (set ANDROID_HOME or pass -SdkDir) with
#      platforms;android-35 and build-tools;35.0.0
#
#  The project must be framework-only Java (no AndroidX/AAR dependencies).
#
#  Usage:
#    powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-apk-manual.ps1
#      [-ProjectDir <android project>] [-Out <apk path>]
#      [-JdkDir <jdk>] [-SdkDir <sdk>]
#      [-Keystore <jks>] [-StorePass <pw>] [-KeyPass <pw>] [-KeyAlias <alias>]
#      [-VersionName 1.0.0] [-VersionCode 1]
# ===========================================================================
param(
    [string]$ProjectDir = '',
    [string]$Out = '',
    [string]$JdkDir = '',
    [string]$SdkDir = '',
    [string]$Keystore = '',
    [string]$StorePass = '',
    [string]$KeyPass = '',
    [string]$KeyAlias = 'heylogan',
    [string]$VersionName = '1.0.0',
    [int]$VersionCode = 1,
    [switch]$DebugBuild
)

$ErrorActionPreference = 'Stop'

function Fail([string]$message) {
    Write-Host ''
    Write-Host ('BUILD FAILED: ' + $message) -ForegroundColor Red
    exit 1
}

function Step([string]$text) {
    Write-Host ('[' + (Get-Date).ToString('HH:mm:ss') + '] ' + $text)
}

function Invoke-Tool([string]$exe, [string[]]$arguments, [string]$what, [switch]$AllowFailure) {
    $log = Join-Path $script:BuildDir ($what + '.log')
    $p = Start-Process -FilePath $exe -ArgumentList $arguments -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput $log -RedirectStandardError ($log + '.err')
    if ($p.ExitCode -ne 0 -and -not $AllowFailure) {
        Write-Host ('--- ' + $what + ' (stdout) ---')
        Get-Content $log -Tail 40 -ErrorAction SilentlyContinue
        Write-Host ('--- ' + $what + ' (stderr) ---')
        Get-Content ($log + '.err') -Tail 60 -ErrorAction SilentlyContinue
        Fail ($what + ' exited with code ' + $p.ExitCode + ' (logs in ' + $script:BuildDir + ')')
    }
    return $p.ExitCode
}

# --- locate the project ------------------------------------------------------
if (-not $ProjectDir) { $ProjectDir = Split-Path -Parent $PSScriptRoot }
$ProjectDir = (Resolve-Path $ProjectDir).Path
$srcMain = Join-Path $ProjectDir 'app\src\main'
$resDir = Join-Path $srcMain 'res'
$assetsDir = Join-Path $srcMain 'assets'
$javaDirs = @(Join-Path $srcMain 'java')
$manifest = Join-Path $srcMain 'AndroidManifest.xml'
foreach ($p in @($manifest, $resDir)) { if (-not (Test-Path $p)) { Fail ('missing required path: ' + $p) } }

if (-not $Out) { $Out = Join-Path (Split-Path -Parent $ProjectDir) 'dist\HeyLoganAI-android-1.0.0.apk' }

# --- locate the toolchain ----------------------------------------------------
if (-not $JdkDir) {
    if ($env:JAVA_HOME) { $JdkDir = $env:JAVA_HOME } else { Fail 'JDK not found: set JAVA_HOME or pass -JdkDir' }
}
if (-not $SdkDir) {
    if ($env:ANDROID_HOME) { $SdkDir = $env:ANDROID_HOME }
    elseif ($env:ANDROID_SDK_ROOT) { $SdkDir = $env:ANDROID_SDK_ROOT }
    else { Fail 'Android SDK not found: set ANDROID_HOME or pass -SdkDir' }
}
$javaExe = Join-Path $JdkDir 'bin\java.exe'
$javacExe = Join-Path $JdkDir 'bin\javac.exe'
$keytoolExe = Join-Path $JdkDir 'bin\keytool.exe'
$androidJar = Join-Path $SdkDir 'platforms\android-35\android.jar'
$buildTools = Join-Path $SdkDir 'build-tools\35.0.0'
$aapt2 = Join-Path $buildTools 'aapt2.exe'
$d8Bat = Join-Path $buildTools 'd8.bat'
$zipalign = Join-Path $buildTools 'zipalign.exe'
$apksigner = Join-Path $buildTools 'apksigner.bat'
foreach ($p in @($javaExe, $javacExe, $androidJar, $aapt2, $d8Bat, $zipalign, $apksigner)) {
    if (-not (Test-Path $p)) { Fail ('toolchain file missing: ' + $p) }
}

# --- build workspace ---------------------------------------------------------
$script:BuildDir = Join-Path $ProjectDir '_manual-build'
if (Test-Path $script:BuildDir) { Remove-Item $script:BuildDir -Recurse -Force }
foreach ($d in @('res-compiled', 'gen', 'classes', 'dex', 'work')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $script:BuildDir $d) | Out-Null
}
$env:JAVA_HOME = $JdkDir
$env:PATH = (Join-Path $JdkDir 'bin') + ';' + $env:PATH

Step 'aapt2 compile (resources)'
$compiledZip = Join-Path $script:BuildDir 'resources.zip'
Invoke-Tool $aapt2 @('compile', '--dir', $resDir, '-o', $compiledZip) 'aapt2-compile' | Out-Null
if (-not (Test-Path $compiledZip)) { Fail 'aapt2 compile produced no output' }

Step 'aapt2 link (manifest + resources + assets)'
$baseApk = Join-Path $script:BuildDir 'base.apk'
$genDir = Join-Path $script:BuildDir 'gen'
$linkArgs = @(
    'link',
    '-o', $baseApk,
    '-I', $androidJar,
    '--manifest', $manifest,
    '--java', $genDir,
    '--min-sdk-version', '26',
    '--target-sdk-version', '35',
    '--version-code', "$VersionCode",
    '--version-name', $VersionName,
    '--auto-add-overlay'
)
if (Test-Path $assetsDir) { $linkArgs += @('-A', $assetsDir) }
if ($DebugBuild) { $linkArgs += '--debug-mode' }
$linkArgs += $compiledZip
Invoke-Tool $aapt2 $linkArgs 'aapt2-link' | Out-Null
if (-not (Test-Path $baseApk)) { Fail 'aapt2 link produced no apk' }

Step 'javac (sources + generated R.java)'
# Stage every .java file with its UTF-8 BOM removed: javac rejects a BOM, and
# editors on Windows like to add one.
$stageSrc = Join-Path $script:BuildDir 'src'
New-Item -ItemType Directory -Force -Path $stageSrc | Out-Null
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$sources = @()
$rootIndex = 0
foreach ($dir in @($javaDirs + $genDir)) {
    if (-not (Test-Path $dir)) { continue }
    $rootIndex += 1
    Get-ChildItem $dir -Recurse -Filter *.java | ForEach-Object {
        $rel = $_.FullName.Substring($dir.Length).TrimStart('\', '/')
        $dest = Join-Path (Join-Path $stageSrc ('r' + $rootIndex)) $rel
        $destDir = Split-Path $dest -Parent
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
        $text = [System.IO.File]::ReadAllText($_.FullName)
        $text = $text.TrimStart([char]0xFEFF)
        [System.IO.File]::WriteAllText($dest, $text, $utf8NoBom)
        $sources += $dest
    }
}
if ($sources.Count -eq 0) { Fail 'no Java sources found' }
$classesDir = Join-Path $script:BuildDir 'classes'
# javac is invoked with the sources on the command line (not an @argfile: javac
# argument files treat backslashes as escapes, which corrupts Windows paths).
$javacArgList = @('-source', '17', '-target', '17', '-encoding', 'UTF-8', '-nowarn',
                  '-classpath', $androidJar, '-d', $classesDir) + $sources
$javacQuoted = @()
foreach ($a in $javacArgList) {
    if ($a -match '[\s"]') { $javacQuoted += ('"' + ($a -replace '"', '\"') + '"') } else { $javacQuoted += $a }
}
$javacLine = ($javacQuoted -join ' ')
$javacLog = Join-Path $script:BuildDir 'javac.log'
$pJavac = Start-Process -FilePath $javacExe -ArgumentList $javacLine -Wait -PassThru -NoNewWindow `
    -RedirectStandardOutput $javacLog -RedirectStandardError ($javacLog + '.err')
if ($pJavac.ExitCode -ne 0) {
    Write-Host '--- javac (stderr) ---'
    Get-Content ($javacLog + '.err') -Tail 60 -ErrorAction SilentlyContinue
    Fail ('javac exited with code ' + $pJavac.ExitCode + ' (logs in ' + $script:BuildDir + ')')
}

Step 'd8 (classes -> classes.dex)'
$classFiles = @(Get-ChildItem $classesDir -Recurse -Filter *.class | ForEach-Object { $_.FullName })
if ($classFiles.Count -eq 0) { Fail 'javac produced no class files' }
$dexDir = Join-Path $script:BuildDir 'dex'
$d8Args = @('--lib', $androidJar, '--min-api', '26', '--output', $dexDir) + $classFiles
Invoke-Tool $d8Bat $d8Args 'd8' | Out-Null
$dexFile = Join-Path $dexDir 'classes.dex'
if (-not (Test-Path $dexFile)) { Fail 'd8 produced no classes.dex' }

Step 'package (add classes.dex to the resource apk)'
$unsigned = Join-Path $script:BuildDir 'unsigned.apk'
Copy-Item $baseApk $unsigned -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::Open($unsigned, 'Update')
try {
    $existing = $zip.GetEntry('classes.dex')
    if ($existing) { $existing.Delete() }
    [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $dexFile, 'classes.dex', [System.IO.Compression.CompressionLevel]::Optimal)
} finally { $zip.Dispose() }

Step 'zipalign'
$aligned = Join-Path $script:BuildDir 'aligned.apk'
Invoke-Tool $zipalign @('-f', '-p', '4', $unsigned, $aligned) 'zipalign' | Out-Null

# --- signing -----------------------------------------------------------------
$keystoreDir = Join-Path $ProjectDir 'release-keystore'
if (-not $Keystore) { $Keystore = Join-Path $keystoreDir 'heylogan-release.jks' }
if (-not $StorePass) {
    $info = Join-Path $keystoreDir 'keystore-info.txt'
    if (Test-Path $info) {
        $line = (Get-Content $info | Where-Object { $_ -match '^storePassword=' } | Select-Object -First 1)
        if ($line) { $StorePass = $line.Substring('storePassword='.Length).Trim() }
    }
}
if (-not $KeyPass) { $KeyPass = $StorePass }
if (-not $StorePass) { Fail 'keystore password not supplied (pass -StorePass or add release-keystore\keystore-info.txt)' }

if (-not (Test-Path $Keystore)) {
    Step 'creating release keystore'
    New-Item -ItemType Directory -Force -Path $keystoreDir | Out-Null
    $dname = 'CN=HeyLoganAI,OU=Local,O=HeyLoganAI,L=Local,ST=Local,C=AU'
    Invoke-Tool $keytoolExe @('-genkeypair', '-v', '-keystore', $Keystore, '-alias', $KeyAlias,
        '-keyalg', 'RSA', '-keysize', '2048', '-validity', '10000',
        '-storepass', $StorePass, '-keypass', $KeyPass, '-dname', $dname) 'keytool' | Out-Null
}

Step 'apksigner sign'
$outDir = Split-Path -Parent $Out
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
if (Test-Path $Out) { Remove-Item $Out -Force }
Invoke-Tool $apksigner @('sign', '--ks', $Keystore, '--ks-key-alias', $KeyAlias,
    '--ks-pass', ('pass:' + $StorePass), '--key-pass', ('pass:' + $KeyPass),
    '--out', $Out, $aligned) 'apksigner-sign' | Out-Null

Step 'apksigner verify'
Invoke-Tool $apksigner @('verify', '--verbose', '--print-certs', $Out) 'apksigner-verify' | Out-Null
Get-Content (Join-Path $script:BuildDir 'apksigner-verify.log') | ForEach-Object { '  ' + $_ }

Step 'aapt2 dump badging'
Invoke-Tool $aapt2 @('dump', 'badging', $Out) 'aapt2-badging' | Out-Null
Get-Content (Join-Path $script:BuildDir 'aapt2-badging.log') |
    Where-Object { $_ -match '^(package|sdkVersion|targetSdkVersion|application-label|launchable-activity|uses-permission)' } |
    ForEach-Object { '  ' + $_ }

$size = (Get-Item $Out).Length
$hash = (Get-FileHash $Out -Algorithm SHA256).Hash
Write-Host ''
Write-Host '================ BUILD COMPLETE ================'
Write-Host ('APK:    ' + $Out)
Write-Host ('Size:   ' + $size + ' bytes (' + [math]::Round($size / 1MB, 2) + ' MB)')
Write-Host ('SHA256: ' + $hash)
Write-Host '================================================'
