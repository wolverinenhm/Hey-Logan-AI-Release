# Independent Verification Report - Hey Logan AI 1.0.0

**Verdict: READY**

| | |
|---|---|
| Reviewer | `qa-reviewer` (independent QA - did not build any of these artifacts) |
| Date | 2026-11-03 (Australia/Brisbane) |
| Release root | `C:\Users\s2121270\Downloads\Hey-Logan-AI-Release` |
| Test host | Windows 11 Enterprise 26200 x64, Windows PowerShell 5.1, no global JDK/Android SDK on PATH (bundled `_toolchain` used) |
| Artifacts frozen at | 21:41:58 - all checks below were run against these exact hashes |
| Machine state after testing | clean: no install dir, no Start Menu/Desktop shortcuts, no HKCU ARP/app/Run entries, no node processes, no listeners on 8787/8443 |

This report proves or disproves that the shipped artifacts work. It is evidence-based: every
PASS below is backed by a command that was actually executed on this machine against the
frozen artifacts, and the raw transcripts are in `_test\verify\`.

---

## 1. Artifact manifest (verified by independent re-hashing)

| Artifact | Size (bytes) | SHA-256 |
|---|---:|---|
| `dist\HeyLoganAI-Setup-1.0.0-win-x64.exe` | 23,607,380 | `8209B35898FF990C460E492E1F4DAE7F7F189E8751E22021FF3A5F9845CED9FC` |
| `dist\HeyLoganAI-Portable-1.0.0-win-x64.zip` | 35,108,868 | `94BF5051C5369F7F0F797EF3FBF9DB5042BC098AEDB3A7FC58F0A6E2C72FD6B9` |
| `dist\HeyLoganAI-android-1.0.0.apk` | 226,868 | `4C571B7C43D677A0CE92F691F92D8CDC3D3D85D131791939DA48EB1278448D80` |
| `dist\HeyLoganAI-Android-Project-1.0.0.zip` | 232,691 | `F8C42754E413AFC415356A6AE703680EE9388A7F82A61A7451D0F932B1EF6FD6` |

`dist\SHA256SUMS.txt` (625 bytes, SHA-256 `CB90555C6AC7FAA0B0710017AE48377814C04EA6EFD2DF8198386C30D3228C4E`)
contains exactly these four lines in `sha256sum` format and matches the recomputed values above.
The same four hashes are in `README.md` section "Checksums (SHA-256)".

There is one non-frozen artifact in `dist\`: `SHA256SUMS.txt` itself (it cannot contain its own hash).

---

## 2. Verdict summary

| Area | Result | Evidence |
|---|---|---|
| A. Windows installer (NSIS) | **PASS** | Clean-room silent install, shortcuts, ARP, start-at-login, launch via shortcut, real command through the HTTP API, UI screenshot, pairing output, stop/restart, in-place upgrade, locked-data abort test, keep-data uninstall, purge uninstall, custom-directory install, final clean machine. 158 PASS / 0 FAIL / 1 SKIP (159 checks; the SKIP is the interactive uninstall dialog). |
| A. Portable ZIP | **PASS** | Extracted and run without installation: `Launch.vbs` and the visible-console launcher both start the server; no registry entries or shortcuts created; `Stop.cmd` now stops both launch modes. Payload is byte-identical to `windows\payload\HeyLoganAI\`. |
| B. Android APK | **PASS** (static + cryptographic) | Signed APK verifies (v2 + v3, 1 signer RSA-2048); manifest/badging correct (`ai.heylogan.app`, 1.0.0, minSdk 26, targetSdk 35, launchable `.MainActivity`, 3 permissions); dex contains the expected classes and native-bridge surface; APK dex is byte-identical to the build output of the shipped sources; launcher icons/resources present; zipalign OK. Runtime behaviour on a phone could not be executed here (no device/emulator) - see section 6. |
| B. Android project ZIP | **PASS** | 29 files; no `_manual-build`, `release-keystore`, `local.properties`, `.jks` or keystore password literal; every file SHA-256-identical to `android\` sources; CI workflow builds the debug APK for the delivered layout. |
| C. Docs consistency | **PASS** | `README.md`, `docs\INSTALL-WINDOWS.md`, `docs\INSTALL-ANDROID.md`, `windows\installer\README.md`, `HELP.txt`, `Pairing.cmd` output and `android\README.md` were reviewed statement-by-statement against the artifacts. Overstatements found during QA were corrected by the release owner before the freeze (see section 5), the final pass found no remaining false claim. |
| **Overall** | **READY** | One medium finding (F-1) was found during verification, fixed by the release owner, and re-verified on the final frozen ZIP. No open blocker/high/medium/low findings. |

The two risks that caused the previous release to be rejected are directly disproved:
the installer is a real NSIS installer that was installed and uninstalled end-to-end, and
the APK is a real, signed, installable artifact whose signature chain verifies.

---

## 3. Part A - Windows installer and portable ZIP (PASS)

Method: the workspace copy of `Setup.exe` is never executed (the DSH agent sandbox can hang
GUI executables launched from the workspace tree). It is copied to `C:\Temp`, the copy's
SHA-256 is asserted equal to `dist\`, and only the copy is run. The machine state is snapshotted
before/after (install dir, HKCU/HKLM Add/Remove Programs, Run key, Start Menu, Desktop, node
processes, listeners, firewall rule). The full run is reproducible with
`_test\verify\run-windows-e2e.ps1` (see section 7).

### 3.1 Structural checks (A1)

| # | Check | Command | Observed |
|---|---|---|---|
| A1.1 | Setup.exe hash matches freeze | `Get-FileHash dist\HeyLoganAI-Setup-1.0.0-win-x64.exe -Algorithm SHA256` | `8209B35898FF990C...CED9FC` (23,607,380 B) |
| A1.2 | PE executable | read `MZ`/PE header bytes | `MZ`, `PE\0\0`, PE offset 216 |
| A1.3 | PE machine | `[BitConverter]::ToUInt16($b,$peOffset+4)` | `0x014C` = 32-bit NSIS stub. Standard for NSIS 3.04: the bootstrap runs as a 32-bit process on 64-bit Windows and installs the x64 payload. `.onInit` enforces `RunningX64` and Windows 10+ before installing. |
| A1.4 | NSIS markers | ASCII scan of the binary | `Nullsoft Install System` @115118, `NullsoftInst` @116232, `NSIS` @115077 |
| A1.5 | Version metadata | `(Get-Item $exe).VersionInfo` | ProductName `Hey Logan AI`, FileDescription `Hey Logan AI Setup`, CompanyName `Hey Logan AI`, FileVersion/ProductVersion `1.0.0`, LegalCopyright `Copyright (c) 2026 Hey Logan AI` |
| A1.6 | Signature state | `Get-AuthenticodeSignature $exe` | `NotSigned` (expected and documented: no code-signing certificate) |
| A1.7 | No pre-created user data in the package | after silent install, before first run: `Test-Path <inst>\app\data` | `False`; installed tree is exactly 570 files = 569 payload files + `Uninstall.exe` |
| A1.8 | Portable ZIP layout | `tar -tf dist\HeyLoganAI-Portable-1.0.0-win-x64.zip` | 654 entries, one top folder `HeyLoganAI\`; contains `README-FIRST.txt`, `Start Hey Logan AI.cmd`, `Launch.vbs`, `runtime\node.exe`, `app\`, `tools\`, `HELP.txt`, icon; **zero** `app/data` entries |
| A1.9 | Portable payload integrity | extract + hash-compare all files against `windows\payload\HeyLoganAI` | 569/569 payload files present and SHA-256-identical; only extras are `README-FIRST.txt` + `Start Hey Logan AI.cmd` |
| A1.10 | No machine-specific data shipped | grep shipped text files for user name / absolute user paths | 0 hits |
| A1.11 | SHA256SUMS.txt content | re-hash + compare | all four artifact lines match |

### 3.2 Clean-room silent install (A2) - `/S`

Command: `C:\Temp\hl-qa\...\HeyLoganAI-Setup-1.0.0-win-x64.exe /S` (copy hash asserted first).

| # | Check | Observed |
|---|---|---|
| A2.1 | Copied Setup.exe SHA-256 == dist SHA-256 | equal |
| A2.2 | Exit code 0 | `exit=0` in 14.8 s |
| A2.3 | Install dir | `%LOCALAPPDATA%\Programs\HeyLoganAI` created |
| A2.4 | Installed file count | 570 = 569 payload files + `Uninstall.exe` |
| A2.5 | `Uninstall.exe` present | yes |
| A2.6 | No `app\data` before first run | absent (user data is created on first start) |
| A2.7 | Every payload file byte-identical after install | missing=0, hash mismatch=0 (569 files) |
| A2.8 | No unexpected installed files | extra = none |
| A2.9 | Required files: `Launch.vbs`, `Start Console.cmd`, `Stop.cmd`, `Pairing.cmd`, `Allow through Firewall.cmd`, `HELP.txt`, `heylogan.ico`, `runtime\node.exe`, `tools\{pair.js,stop.ps1,firewall.ps1}`, `app\server\index.js`, `app\public\index.html`, `app\public\native-voice.js` | all present |
| A2.10 | Start Menu group | `...\Start Menu\Programs\Hey Logan AI` created |
| A2.11 | Exactly 6 Start Menu shortcuts | `Hey Logan AI.lnk`, `Start Console.lnk`, `Pairing.lnk`, `Stop Server.lnk`, `Allow through Firewall.lnk`, `Uninstall.lnk` |
| A2.12/A2.14 | Main + uninstall shortcuts present | yes / `Uninstall.lnk` |
| A2.15 | Desktop shortcut | `Desktop\Hey Logan AI.lnk` |
| A2.16-A2.18 | Main shortcut target/args/icon | target `C:\Windows\System32\wscript.exe`; args `"<install>\Launch.vbs"`; icon `<install>\heylogan.ico,0` |
| A2.19-A2.22 | Other shortcut targets | `Start Console.cmd`, `Pairing.cmd`, `Stop.cmd`, `Allow through Firewall.cmd` |
| A2.23 | Desktop shortcut target | `wscript.exe "<install>\Launch.vbs"` |
| A2.24-A2.33 | HKCU Add/Remove Programs entry | DisplayName `Hey Logan AI`; DisplayVersion `1.0.0`; Publisher `Hey Logan AI`; InstallLocation = install dir; UninstallString `"<install>\Uninstall.exe"`; QuietUninstallString `"<install>\Uninstall.exe" /S`; EstimatedSize `91,605 KB`; NoModify=1; NoRepair=1; DisplayIcon `heylogan.ico` |
| A2.34 | `HKCU\Software\HeyLoganAI` | InstallDir = install dir (Version/DataDir also written per NSIS source) |
| A2.35/A2.36 | Start-at-login Run value (default component) | `"C:\WINDOWS\system32\wscript.exe" "<install>\Launch.vbs"` |
| A2.37 | No HKLM Add/Remove Programs entry added | confirmed |
| A2.38 | Nothing under `C:\Program Files` | confirmed |
| A2.39 | Only `HeyLoganAI` added under `%LOCALAPPDATA%\Programs` | confirmed |
| A2.40 | No firewall rule added | confirmed (`Get-NetFirewallRule -DisplayName 'Hey Logan AI'` empty; this also holds at the end of the run - A8.10) |

### 3.3 Functional test of the installed app (A3)

The app was started the way a user starts it: by resolving the **shortcut's own target and
arguments** (`wscript.exe "<install>\Launch.vbs"`), not by running node directly.

| # | Check | Observed |
|---|---|---|
| A3.1-A3.4 | `GET http://127.0.0.1:8787/api/health` after shortcut launch | `{"ok":true,"app":"Hey Logan AI","version":"1.0.0","time":"...","requiresToken":true}` |
| A3.5 | First run created `app\data\config.json` | yes |
| A3.6 | First run created `app\data\certs\cert.pem` + `key.pem` | yes |
| A3.7 | Token format | 14-char grouped token, e.g. `QE4C-MT2U-8TEL` (matches docs example format) |
| A3.8/A3.9 | Default ports | `server.httpPort=8787`, `server.httpsPort=8443` |
| A3.10-A3.13 | `GET /api/session-info` with `X-Bridge-Token` | `ok:true`; app `Hey Logan AI 1.0.0`; 6 agents; LAN URL `https://192.168.0.104:8443` |
| A3.14/A3.15 | One real command: `POST /api/command` `{"text":"hey computer list my downloads folder","sync":true}` with token header | `ok:true`, spoken answer `"Downloads has 15 items. Showing the first 15."` |
| A3.16 | Headless-Edge screenshot of the real running UI | captured, 84,261 bytes -> `_test\verify\ui-installed.png` (1280x900) |
| A3.17 | `Pairing.cmd` exits 0 | `exit=0` |
| A3.18 | Pairing output shows the access token | yes |
| A3.19 | Pairing output shows a `192.168.*` LAN address | `https://192.168.0.104:8443` (recommended) and `http://192.168.0.104:8787` (fallback) |
| A3.20 | Pairing output shows a QR code | `Scan this QR code with your phone:` + 47 lines of block art |
| A3.21-A3.24 | `Stop.cmd` stops it | exit 0; health goes down; node process count 1 -> 0; no listener on 8787/8443 |
| A3.25/A3.26 | Start again -> stop again (repeat use) | health up; second stop exit 0 |
| A3b.1-A3b.3 | Installed **"Start Console.cmd"** launch mode (visible console) | server up; live node command line contains the absolute install dir; `Stop.cmd` stops it (exit 0, 0 processes left) |

Browser window: `Launch.vbs` is scripted to open a chromeless Edge/Chrome app window and to
fall back to the default browser. On this machine Edge was already running with many processes;
`Launch.vbs` started a new `msedge.exe` process and a new Edge renderer immediately after the
shortcut launch (observed process spawn), but a *visible* window cannot be asserted in this
non-interactive agent session. The UI itself was captured independently with headless Edge
(A3.16). See section 6.

### 3.4 In-place upgrade (A4) - `/S` over a running installation

| # | Check | Observed |
|---|---|---|
| A4.0 | App running before upgrade | health ok |
| A4.1 | Upgrade exit code 0 | yes |
| A4.2 | Access token unchanged | `QE4C-MT2U-8TEL` before and after |
| A4.3 | Whole `config.json` unchanged | yes |
| A4.4/A4.5 | No duplicate shortcuts | 6 Start Menu links, 1 Desktop link |
| A4.6 | Single ARP entry | yes |
| A4.7 | `app\data` kept | yes |
| A4.8/A4.9 | Installer stopped the running server | health down; no node process left |

### 3.5 Data-safety guard - locked `app\data` during upgrade (A4b)

This is the highest-value assertion of the release. A share-deny handle
(`[System.IO.File]::Open(...,'Open','ReadWrite','None')`) was opened on
`<install>\app\data\config.json`, then the installer was run with `/S`.

| # | Check | Observed |
|---|---|---|
| A4b.1 | Silent upgrade aborts, exit code 1 | `exit=1` (deliberate abort, no dialog in silent mode) |
| A4b.2 | Access token intact | unchanged |
| A4b.3 | Certificate files intact | present |
| A4b.4 | No `.hl-data-keep` stash left behind | absent |
| A4b.5/A4b.6/A4b.7 | Program files untouched | `Launch.vbs`, `runtime\node.exe` and `Uninstall.exe` hashes/sizes unchanged |
| A4b.8 | Install still registered (ARP entry intact) | yes |
| A4b.9 | Normal upgrade after releasing the lock | exit 0 |
| A4b.10 | Token still unchanged | yes |

### 3.6 Uninstall (A5), custom directory + ARP uninstall (A7), switches (A5b)

| # | Check | Observed |
|---|---|---|
| A5.2 | `Uninstall.exe /S` exit code 0 | `exit=0` |
| A5.3-A5.7 | Shortcuts, ARP entry, `HKCU\Software\HeyLoganAI`, Run value removed | all gone |
| A5.8 | `app\data` kept (documented keep-data default) | `config.json` still present |
| A5.9/A5.10 | Program files removed | `runtime\` gone; `Launch.vbs` and `Uninstall.exe` gone |
| A5.11 | No node process/listener after uninstall | confirmed |
| A7.1-A7.3 | `Setup.exe /S /D=C:\Temp\...\custom-install` | exit 0, files installed in the custom dir |
| A7.4 | ARP InstallLocation | custom dir |
| A7.5 | Main shortcut arguments | point at the custom dir's `Launch.vbs` |
| A7.6/A7.7 | ARP `UninstallString` points at custom `Uninstall.exe`; invoked with `/S` | exit 0 |
| A7.8-A7.10 | Custom dir, ARP entry, shortcuts removed | confirmed |
| A5b.1-A5b.4 | `Setup.exe /S /NOAUTOSTART` | exit 0; **no** `HKCU\...\Run\HeyLoganAI` value; app + shortcuts still installed |
| A5b.5-A5b.7 | `Uninstall.exe /S /PURGEDATA` | exit 0; install folder and registry fully removed (no `app\data` left) |
| A5b.8 | Interactive uninstall Yes/No message box | SKIP - no interactive clicks possible in this session (documented; silent switches cover the same decision) |

### 3.7 Portable ZIP (A6)

| # | Check | Observed |
|---|---|---|
| A6.1-A6.3 | Extract ZIP; `README-FIRST.txt` + `Start Hey Logan AI.cmd`; no `app\data` | yes / yes / none |
| A6.4/A6.5 | `Launch.vbs` starts the server; creates its own `app\data` | health ok; config created |
| A6.6-A6.8 | No ARP entry, no Run value, no Start Menu/Desktop shortcut created | confirmed |
| A6.9-A6.11 | `tools\stop.ps1` stops the Launch.vbs server; no process/listener left | confirmed |
| A6.12 | `Start Hey Logan AI.cmd` (visible console) starts the server | health ok |
| A6.13 | `Stop.cmd` stops the console-launched server | `Stopped server process 21972` / `Server stopped.` exit 0; health down |
| A6.14 | No leftover process/listener after the portable run | confirmed |
| A6.15 | Final portable payload vs `windows\payload` | 569/569 files SHA-256-identical; only extras are `README-FIRST.txt` and `Start Hey Logan AI.cmd` |
| A6.16 | Portable-only launcher carries the absolute-path fix | `"%~dp0runtime\node.exe" "%~dp0app\server\index.js"` (ZIP file SHA-256 `1D7264EA...E6519` == source) |
| A6.17 | Shipped app self-tests from the frozen payload (`runtime\node.exe test\run.js`) | `# tests 75 / # pass 75 / # fail 0`, exit 0 |

### 3.8 Final machine-clean check (A8)

| # | Check | Observed |
|---|---|---|
| A8.1-A8.7 | No install dir, no custom dir, no ARP entry, no HKCU app key, no Run value, no Start Menu group, no Desktop shortcut | all absent |
| A8.8/A8.9 | No node processes; no listener on 8787/8443 | 0 / 0 |
| A8.10 | No firewall rule added | yes |
| A8.11/A8.12 | No leftovers in Start Menu Programs / Desktop | none |
| A8.13 | No HKLM Add/Remove Programs changes | none |

---

## 4. Part B - Android APK and project ZIP (PASS, static + cryptographic)

### 4.1 Signature and identity

| # | Check | Command | Observed |
|---|---|---|---|
| B1 | APK signature verifies | `apksigner.bat verify --verbose --print-certs dist\HeyLoganAI-android-1.0.0.apk` | `Verifies`; v2 `true`, v3 `true`; **1 signer**; RSA 2048; DN `CN=HeyLoganAI, OU=Local, O=HeyLoganAI, L=Local, ST=Local, C=AU` |
| B2 | v1 scheme present too | `apksigner.bat verify --min-sdk-version 21 --verbose <apk>` | v1 `true` (the default verify reports v1 `false` because minSdk 26 only requires v2/v3; the APK still carries a valid v1 JAR signature) |
| B3 | Signer certificate == release keystore | `keytool -list -v -keystore android\release-keystore\heylogan-release.jks` vs apksigner | both `6C:82:67:92:33:C2:AB:DF:78:0C:FC:2C:A8:9B:06:68:49:07:D0:FF:54:5D:27:A3:E1:26:83:7F:93:18:48:0C` |
| B4 | zipalign | `zipalign.exe -c -v 4 <apk>` | `Verification succesful` |
| B5 | Badging | `aapt2.exe dump badging <apk>` | `package: ai.heylogan.app`, versionCode 1, versionName **1.0.0**, `minSdkVersion 26`, `targetSdkVersion 35`, `launchable-activity ai.heylogan.app.MainActivity`, label `Hey Logan AI`; permissions: `INTERNET`, `ACCESS_NETWORK_STATE`, `RECORD_AUDIO` only (no CAMERA - QR scanning is a documented design limitation) |

### 4.2 Contents and dex

| # | Check | Observed |
|---|---|---|
| B6 | APK entries | 20 entries: `AndroidManifest.xml`, `classes.dex`, `resources.arsc`, `assets/connect.html`, 10 launcher-icon PNGs (5 densities x legacy + adaptive foreground), 2 adaptive-icon XMLs, `res/xml/network_security_config.xml`, 3 v1-signing META-INF files |
| B7 | Dex size/version | 44,152 bytes, `dex\n038\0` |
| B8 | Dex classes | 38 class definitions incl. `Lai/heylogan/app/MainActivity;`, `Lai/heylogan/app/VoiceBridge;`, `Lai/heylogan/app/MainActivity$PairBridge;`, R classes |
| B9 | Native-bridge surface in the dex | strings found: `sttAvailable`, `startListening`, `stopListening`, `ttsAvailable`, `speak`, `stopSpeaking`, `destroy`, `_onNative`, `HeyNativeVoice`, `HeyPairBridge`, `addJavascriptInterface`, `evaluateJavascript`; event types `start`, `partial`, `final`, `end`, `tts-start`, `tts-end`; error codes `not-allowed`, `audio-capture`, `service-not-allowed`, `network` |
| B10 | APK dex == build output of the shipped sources | APK `classes.dex` SHA-256 `5F074B3A3BB553ECB71AE44B2F73D1DC520CA197FFBE301B625821077B8CCCC3` == `android\_manual-build\dex\classes.dex`; the staged Java sources in `_manual-build\src\r1` are SHA-256-identical to `android\app\src\main\java\...` (MainActivity.java, VoiceBridge.java), and `assets/connect.html` inside the APK is identical to the source file |
| B11 | Runtime manifest (compiled) | `uses-sdk 26/35`; 3 permissions; `<queries>` for `android.speech.RecognitionService` + `android.intent.action.TTS_SERVICE`; `application`: theme `@android:style/Theme.Material.NoActionBar` (framework, no AppCompat), `usesCleartextTraffic=true`, `networkSecurityConfig`, `allowBackup=false`; activity `.MainActivity` `exported=true` with MAIN/LAUNCHER |

### 4.3 Source review of the WebView shell + speech bridge

| # | Check | Observed |
|---|---|---|
| B12 | `@JavascriptInterface` methods exposed before the page loads | `webView.addJavascriptInterface(voiceBridge, "HeyNativeVoice")` and `...("HeyPairBridge")` in `onCreate` **before** any `loadUrl(...)` (MainActivity.java) |
| B13 | Page-side bridge contract | `app\public\native-voice.js` calls `sttAvailable()`, `startListening(lang)`, `stopListening()`, `speak(text,lang,rate,pitch)`, `stopSpeaking()`; Java exposes those plus `ttsAvailable()`/`destroy()` (harmless superset). Event JSON shapes and `resultIndex`/`results[i].isFinal`/`[0].transcript` match exactly what `app\public\voice.js` consumes. `index.html` loads `native-voice.js` (line 206) before `voice.js` (line 208), so the shim exists when the voice engine initialises. In a normal browser the shim is a no-op. |
| B14 | Self-signed TLS handling | `onReceivedSslError` cancels immediately when `pairingMode` or host != paired host (loopback aliases accepted only if the paired host is also loopback); proceeds only after a one-time confirmation, remembered per host. |
| B15 | Microphone permission | `RECORD_AUDIO` requested at runtime (`requestPermissions(..., REQUEST_MIC)`); `onPermissionRequest` grants `RESOURCE_AUDIO_CAPTURE` only when the requesting origin host == paired host and the runtime permission is granted; everything else is denied. |
| B16 | No crash-prone/out-of-range APIs spotted | framework-only Java (`android.*`, `java.*`, `org.json`), all imports used, `minSdk 26` guarded by the platform APIs used; UI built in code (no missing resource layouts); theme resolves to a framework theme; `onBackPressed` walks WebView history then exits. |
| B17 | The project compiles | proven by construction: the shipped `classes.dex` is the byte-identical output of `javac`/`d8` over the sources that are in `android\` (B10), and `apksigner` verified the resulting APK. |

Residual Android risks that cannot be executed here (also stated in `android\BUILD-NOTES.md`):
the `_onNative` function is stored as a property on the injected Java object; Chromium's
`isSecureContext` on a page loaded after accepting a self-signed certificate; and the actual
behaviour of the phone's `SpeechRecognizer`/`TextToSpeech` engines. These are documented
limitations, not defects, and required a physical phone to confirm.

### 4.4 Project ZIP

| # | Check | Observed |
|---|---|---|
| B18 | Contents | 29 files, Gradle project layout + `.github/workflows/android-build.yml` + `tools/build-apk-manual.ps1` + README/BUILD-NOTES |
| B19 | No forbidden entries | 0 matches for `_manual-build`, `release-keystore`, `.jks`, `local.properties`, `/build/`, `.gradle/`, `.idsig` |
| B20 | No keystore secret | 0 occurrences of the keystore password literal; README says the password is in `release-keystore/keystore-info.txt` (which stays in `android\` and is not in the ZIP) |
| B21 | ZIP sources == the sources that produced the APK | all 29 files SHA-256-identical to `android\`; no source file missing from the ZIP |
| B22 | Build/CI instructions are valid for the delivered layout | workflow placed at ZIP root and runs `gradle :app:assembleDebug` without any `android/` prefix; README documents the AGP 8 `package="..."` removal step; `gradle wrapper --gradle-version 8.9` documented because no wrapper JAR is shipped |

---

## 5. Part C - Docs consistency and the resolved finding

### 5.1 Resolved during verification: F-1 (medium) - portable launcher / Stop.cmd

**Finding (found by this QA, fixed by the release owner, re-verified here):** in the first
frozen build, a server started with the documented portable launcher `Start Hey Logan AI.cmd`
could not be stopped by the documented `Stop.cmd`.

- Evidence from E2E run 1: `FAIL A6.13 portable console launcher stopped cleanly`; the server
  was still listening on 8787/8443 and the live process was
  `"runtime\node.exe"  "app\server\index.js"` (relative command line).
- Root cause: `windows\installer\portable\Start Hey Logan AI.cmd` used relative paths, while
  `windows\payload\HeyLoganAI\tools\stop.ps1` only matches node processes whose command line
  contains the **absolute** install folder (stop.ps1 lines 5-11). `README-FIRST.txt:21` promised
  "close the console window, or run \"Stop.cmd\"". The installed edition was not affected (its
  `Start Console.cmd` uses an absolute `%~dp0runtime\node.exe` path).
- Fix: the portable launcher now uses absolute paths:
  `"%~dp0runtime\node.exe" "%~dp0app\server\index.js"`; the portable ZIP was rebuilt
  (35,108,868 B, `94BF5051C5369F7F0F797EF3FBF9DB5042BC098AEDB3A7FC58F0A6E2C72FD6B9`); the other
  three artifacts are unchanged.
- Re-verification on the final frozen ZIP: `PASS A6.13` with `Stop.cmd` output
  `Stopped server process 21972 / Server stopped.` (exit 0), health down, no process/listener
  left; `PASS` payload identity (569/569 files), `PASS` launcher SHA-256 == source, `PASS` no
  registry/shortcut side effects. Full sequence in `_test\verify\F-1-evidence.txt`.

### 5.2 Docs review result

`README.md`, `docs\INSTALL-WINDOWS.md`, `docs\INSTALL-ANDROID.md`, `windows\installer\README.md`,
`windows\payload\HeyLoganAI\HELP.txt`, the `Pairing.cmd`/`pair.js` output, and `android\README.md`
were reviewed statement-by-statement against the artifacts. The following overstatements were
found by QA during this release cycle and were corrected by the release owner before the freeze;
the final pass found no remaining false claim:

1. "The installer/uninstaller adds/removes a Windows Firewall rule" - false: the NSIS installer
   never touches the firewall (it cannot without admin). Final docs correctly say it does not,
   and tell the user to run **Allow through Firewall** once; the uninstaller leaves a manually
   added rule alone.
2. "Scan the QR code with the Android app" - the APK has no camera/QR scanner. Final `HELP.txt`,
   `pair.js` output and docs now say to scan with the phone camera (browser) or paste the
   pairing link into the app.
3. Rebuild instructions promised `gradlew` although no wrapper is shipped - final docs explain
   the wrapper must be generated (or Android Studio creates it), and the AGP 8
   `package="ai.heylogan.app"` removal step is documented.
4. Silent-mode wording "no auto-start" was ambiguous - final docs explicitly say the app is not
   launched but start-at-login is still enabled by default, with `/NOAUTOSTART` to skip it.
   Verified empirically: `/S` writes the Run value, `/S /NOAUTOSTART` does not.
5. `SHA256SUMS.txt` missing/partial - final `dist\SHA256SUMS.txt` lists all four frozen
   artifacts and the README repeats the same four hashes.
6. The Start Menu uninstall shortcut name - final script, docs and verified installation agree
   on `Uninstall.lnk`.
7. `BUILD-NOTES.md` v1-signature explanation - corrected; verified: v1 is valid (while the
   default verify hides it for minSdk 26).

Documented limitations that were checked and are correctly represented, not bugs: no code
signing (SmartScreen warning expected), per-user install with no admin/UAC, no QR scanning in
the Android app, no on-device Android test in the build environment, and the firewall step
requiring admin.

Non-blocking documentation observations (informational, no action required): the approximate
size figures in the docs are in MiB-style units ("~22.5 MB Setup", "~33 MB ZIP") while the
README checksum table has exact byte sizes; the README suggests `sha256sum -c` for "Linux/macOS"
- stock macOS ships `shasum -a 256 -c` instead (the Windows `Get-FileHash` instruction is
correct).

---

## 6. What could not be verified here, and why

| Not verified | Why | Mitigation in this release |
|---|---|---|
| Install/launch/pairing/voice of the APK on a real Android phone | No Android device and no emulator on this machine; Android runtime cannot be exercised offline | APK signature chain verified with `apksigner`; badging/manifest/dex/resources verified; dex proven to be the compiled output of the shipped sources; voice bridge contract checked statically against `app\public\native-voice.js`/`voice.js` and documented residual risks in `android\BUILD-NOTES.md` |
| Interactive wizard pages (Welcome/Components/Directory/Finish "Run" checkbox) and the interactive uninstall Yes/No prompt | Agent session has no interactive desktop/UI automation; clicking through a GUI wizard cannot be automated here | Static review of `installer.nsi` MUI2 pages + all shortcuts/registry/files asserted after a real silent install; every behaviour the wizard controls is also available silently (`/S`, `/NOAUTOSTART`, `/D=`, `/PURGEDATA`, `/KEEPDATA`) and was exercised |
| SmartScreen / antivirus behaviour | Reputation prompts depend on Microsoft's cloud reputation and the user's network | Documented limitation ("not code-signed -> More info -> Run anyway"); the installer is a standard NSIS installer, not a self-extractor wrapper |
| Visible chromeless browser window opened by `Launch.vbs` | Edge was already running in this non-interactive session; the launcher spawns a new `msedge.exe`/renderer (observed) but the visible window cannot be asserted programmatically without UI automation | `Launch.vbs` code reviewed; health endpoint reached via the launcher; the identical UI was captured with headless Edge (`_test\verify\ui-installed.png`); default-browser fallback is documented |
| Real phone-to-PC LAN pairing (certificate prompt, microphone over HTTPS, QR/link flow) | No phone | Server pairing output verified (`Pairing.cmd`: token, `https://192.168.0.104:8443`, QR); PWA token handling and SSL flow reviewed; Android app pre-requisites documented |
| Windows 10 (this host is Windows 11 26200 x64) | No Windows 10 machine available | `.onInit` enforces Windows 10+/x64; Node.js 22 and the app code are the same; not claimed beyond "Windows 10 or newer (x64)" |
| 32-bit Windows / Windows on ARM | Not supported/claimed by the release | installer refuses non-x64 via `.onInit` |
| `sha256sum -c` on Linux/macOS | Not available on this Windows host | All four hashes were independently recomputed with `Get-FileHash` and compared to `SHA256SUMS.txt` and `README.md` |

Known environment note: the DSH agent sandbox can hang executables launched from the workspace
tree, so every installer run in this report used a byte-identical copy in `C:\Temp` whose
SHA-256 was asserted against `dist\` first.

---

## 7. Reproduction commands

Windows end-to-end (this is the script that produced section 3; it copies Setup.exe to C:\Temp,
asserts the hash, runs all install/upgrade/locked-data/uninstall/custom-dir/portable checks,
writes logs to `_test\verify\` and cleans the machine):

```powershell
Copy-Item _test\verify\run-windows-e2e.ps1 C:\Temp\ -Force
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Temp\run-windows-e2e.ps1
```

Supplementary checks (payload identity, shipped app test suite, browser launch, no side effects):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File _test\verify\recheck-final.ps1
```

Minimal manual spot checks:

```powershell
# frozen hashes
Get-FileHash dist\* -Algorithm SHA256
# installer structural facts
(Get-Item dist\HeyLoganAI-Setup-1.0.0-win-x64.exe).VersionInfo
# install silently into C:\Temp (never run the exe from the workspace tree)
Copy-Item dist\HeyLoganAI-Setup-1.0.0-win-x64.exe C:\Temp\Setup.exe
& C:\Temp\Setup.exe /S
Invoke-RestMethod http://127.0.0.1:8787/api/health
# stop + uninstall (keep data)
& "$env:LOCALAPPDATA\Programs\HeyLoganAI\Stop.cmd"
& "$env:LOCALAPPDATA\Programs\HeyLoganAI\Uninstall.exe" /S
```

Android re-verification (uses the bundled toolchain):

```powershell
$rel = (Resolve-Path .).Path
$env:JAVA_HOME = "$rel\_toolchain\jdk"
$bt = "$rel\_toolchain\sdk\build-tools\35.0.0"
& "$bt\apksigner.bat" verify --verbose --print-certs "$rel\dist\HeyLoganAI-android-1.0.0.apk"
& "$bt\aapt2.exe" dump badging "$rel\dist\HeyLoganAI-android-1.0.0.apk"
& "$bt\zipalign.exe" -c -v 4 "$rel\dist\HeyLoganAI-android-1.0.0.apk"
# project ZIP: no secrets / sources match
Expand-Archive dist\HeyLoganAI-Android-Project-1.0.0.zip C:\Temp\proj
Get-ChildItem C:\Temp\proj -Recurse -File | Select-String '<the-keystore-password>'   # 0 hits
```

---

## 8. Evidence files

All raw evidence is in `_test\verify\` (produced by the commands above):

| File | What it contains |
|---|---|
| `windows-e2e.log` / `windows-e2e-summary.json` / `windows-e2e-results.json` | Authoritative full E2E run against the frozen artifacts: 158 checks, 158 PASS, 0 FAIL, 1 SKIP |
| `run1-windows-e2e.log` / `run2-windows-e2e.log` (+ summaries/results) | Historical runs: run 1 found F-1 (pre-fix portable ZIP), run 2 was an intermediate run |
| `windows-structural.txt` | Setup.exe/portable structural evidence (hashes, version info, PE/NSIS markers, payload comparison) |
| `android-verify.txt` | Full Android evidence: apksigner, badging, entries, zipalign, dex classes/strings, keystore comparison, project-ZIP checks, manifest xmltree |
| `pairing-output.txt`, `stop-output.txt`, `stop-output-installed-console.txt` | `Pairing.cmd` / `Stop.cmd` console evidence |
| `portable-console-stop-output.txt` | `Stop.cmd` stopping a console-launched portable server (post-fix) |
| `portable-final-check.txt` | Frozen portable ZIP: payload identity, launcher fix, app tests 75/75, browser launch, no registry/shortcut side effects |
| `payload-app-tests.txt` | `node test\run.js` from the frozen portable payload: 75/75 pass |
| `browser-window-check.txt` | `Launch.vbs` browser process-spawn evidence and the non-interactive-session caveat |
| `F-1-evidence.txt` | F-1 discovery evidence, root cause with file/line references, fix and re-verification |
| `ui-installed.png` | Headless-Edge screenshot of the real installed UI |

---

## 9. Sign-off

Every check in the PASS tables above was executed against the four frozen artifacts whose
SHA-256 values are listed in section 1. The platform could not be left dirty: the final
snapshot shows no install directory, no shortcuts, no Add/Remove Programs/app/Run registry
entries, no node processes and no listeners on ports 8787/8443 (section 3.8, and the evidence
logs record the same final state after each run).

**Verdict: READY.** The release installs, runs, upgrades (including the data-loss guard under a
locked `app\data`), stops and uninstalls cleanly on this Windows 11 x64 machine; the portable
ZIP runs without touching the registry or shortcuts; the Android APK is a genuine signed
artifact whose dex is the compiled output of the shipped sources; and the user documentation
matches what the artifacts actually do, with its remaining claims marked as documented
limitations. The one medium issue found during verification was fixed before the final freeze
and re-verified (section 5.1).
