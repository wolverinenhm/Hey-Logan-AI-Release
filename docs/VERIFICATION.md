# Independent Verification Report - Hey Logan AI 1.1.0

**Verdict: READY**

| | |
|---|---|
| Reviewer | `qa-reviewer` (independent QA - did not build any of these artifacts) |
| Date | 2026-11-05 (Australia/Brisbane) |
| Release root | `C:\Users\s2121270\Downloads\Hey-Logan-AI-Release` |
| Test host | Windows 11 Enterprise 26200 x64; Windows PowerShell 5.1; Microsoft Edge 156; real microphone + speakers present; no global JDK/Android SDK on PATH (bundled `_toolchain` used) |
| Artifacts frozen at | 18:11:47 - all checks below were run against these exact hashes |
| What 1.1.0 adds | (1) no clicking "Start listening" - the app starts listening by itself: say **"Hey Logan"**, hear the spoken answer, then give the command; (2) starts with Windows and is already listening at login |
| Previous round | v1.0.0 was verified separately (retained `_test\verify\*` v1.0.0 evidence; the F-1 portable-launcher finding from that round was fixed before this release) |

This report proves or disproves that the 1.1.0 artifacts work. Every PASS below is backed by a
command that was executed on this machine against the frozen artifacts; raw transcripts,
screenshots and the two reusable scripts are in `_test\verify\`.

---

## 1. Artifact manifest (verified by independent re-hashing)

| Artifact | Size (bytes) | SHA-256 |
|---|---:|---|
| `dist\HeyLoganAI-Setup-1.1.0-win-x64.exe` | 23,607,146 | `1A9131CB90DEA921772542A0DEE329855460C8079F789CAB05ACF904640EB586` |
| `dist\HeyLoganAI-Portable-1.1.0-win-x64.zip` | 35,114,765 | `25CAA3921530039D5AAC1695FE7A6E01CC82DB49343F3A18F856CBB49ED9BB8B` |
| `dist\HeyLoganAI-android-1.1.0.apk` | 226,868 | `CCB8FB6E2FF57D856621A0E1ACD41E90A1AF4323A364B19CBDFD31047DBE0173` |
| `dist\HeyLoganAI-Android-Project-1.1.0.zip` | 236,017 | `D3B945956F6041F1D3920E6F30E7AF01FE937150508C3B7D3CF4CFD1EFCE9ED9` |

`dist\SHA256SUMS.txt` (625 bytes, SHA-256 `F6BFAFA416564C85C92B7DB389D14717B7081F4FC8EFA65F1B2489E56C6D04D1`)
lists exactly these four artifacts in `sha256sum` format, and the `README.md` checksum table
carries the same four sizes and hashes. All four hashes were recomputed independently and
match the values the release owner froze.

Payload facts: `windows\payload\HeyLoganAI\` = 571 files / 93,701,645 bytes; the installed
tree is those 571 files plus `Uninstall.exe` = 572 files, byte-identical to the payload
(V11-A7). No `app\data` is shipped.

---

## 2. Verdict summary

| Area | Result | Evidence |
|---|---|---|
| A. Windows installer (NSIS) - hands-free launcher, start-at-login, upgrade-in-place | **PASS** | Clean-room install, exact Run-key command line, browser process/flags, seeded microphone grant, real app-window screenshot, live CDP probe (mic permission, auto-start, TTS autoplay, SpeechRecognition start), health/session-info, routing checks, login helpers, stop/restart, upgrade keeping token + profile, uninstall keep-data, `/NOAUTOSTART` + purge, upgrade-over-v1.0.0, user-state restore. **167 checks, 167 PASS, 0 FAIL, 0 SKIP.** |
| A. Portable ZIP | **PASS** | Extract and run both launchers; same private-profile/autoplay design; no registry or shortcut side effects; `Stop.cmd` regression check. |
| B. Android APK 1.1.0 | **PASS** (static + cryptographic; runtime needs a phone - see section 6) | v2+v3 signatures, same release key as 1.0.0 (versionCode 2 > 1, so it updates in place); correct badging; dex byte-identical to the compiled shipped sources and contains the new microphone-permission flow; zipalign OK. |
| B. Android project ZIP 1.1.0 | **PASS** | 29 files, no keystore/build leakage, every file hash-identical to `android\`. |
| C. Docs consistency | **PASS** | README / INSTALL-WINDOWS / INSTALL-ANDROID / HELP.txt / README-FIRST / Pairing output reviewed against the artifacts; the 1.1.0 statements are true on this machine; overstatements found during QA were fixed before the freeze (section 5). |
| **Overall** | **READY** | No open blocker/high/medium/low findings. Two medium app findings found during this round (stale service-worker cache on upgrade; spoken "Hey Logan, ask <agent> ..." misrouting) and three small ones were fixed by the release owner and re-verified (section 5). |

---

## 3. Part A - Windows installer and portable ZIP (PASS)

Method: the workspace copy of `Setup.exe` is never executed (the DSH agent sandbox can hang
GUI executables launched from the workspace tree); it is copied to `C:\Temp`, the copy's
SHA-256 is asserted equal to `dist\`, and only the copy is run. The machine already runs the
user's real v1.0.0 installation at `D:\HeyLoganAI` on ports 8787/8443 (pid 20660) - it was
never stopped or modified. Test installs used scratch folders under `C:\Temp\hl-qa-11` and
the servers used test-only port overrides (`HEY_AI_HTTP_PORT=8790`, `HEY_AI_HTTPS_PORT=8445`;
portable: 8792/8447), which the 1.1.0 `Launch.vbs` documents as automation overrides.
The user's HKCU Add/Remove Programs key, HKCU app key, Run value, Start Menu group and
Desktop shortcut were backed up before the run and restored exactly afterwards.

Full run command:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Temp\hl-qa-11\run-v11-windows-e2e.ps1 `
  -ExpectedSetupSha 1A9131CB90DEA921772542A0DEE329855460C8079F789CAB05ACF904640EB586 `
  -ExpectedPortableSha 25CAA3921530039D5AAC1695FE7A6E01CC82DB49343F3A18F856CBB49ED9BB8B
```

Result: `checks=167 PASS=167 FAIL=0 SKIP=0` (2026-11-05 18:20:47-18:24:07, log
`_test\verify\v11-windows-e2e.log`). First and last check groups:

| # | Check | Observed |
|---|---|---|
| V11-0.1/.2 | Copied Setup.exe SHA-256 == dist == frozen | `1A9131CB...EB586` |
| V11-0.3/.4/.5 | Portable ZIP / APK / project ZIP == frozen hashes | all match |
| V11-0.6/.7 | `dist\SHA256SUMS.txt` and `README.md` checksum table carry the four frozen hashes | yes |
| V11-0.8 | Test ports 8790/8445/8792/8447 free before the run | yes |
| V11-0.10 | User's real v1.0.0 state backed up | ARP 1.0.0 @ `D:\HeyLoganAI`; Run `wscript.exe "D:\HeyLoganAI\Launch.vbs"`; 6 Start-Menu links; Desktop link; server pid 20660 |
| V11-0.11 | User's server still running (never disturbed) | 8787/8443 = pid 20660 |

### 3.1 Install (A) and installer behaviour

| # | Check | Observed |
|---|---|---|
| V11-A1 | `Setup.exe /S /D=<scratch>` | `exit=0` in 10.9 s |
| V11-A3 | Installed file count | 572 = 571 payload files + `Uninstall.exe` |
| V11-A4/A5/A6 | `Uninstall.exe` present / no pre-shipped `app\data` / no `browser-profile` before first run | yes / absent / absent |
| V11-A7 | Every payload file installed byte-identically | missing=0, mismatch=0 |
| V11-A8 | No unexpected files in the install dir | none |
| V11-A10 | Start Menu group `Hey Logan AI` with exactly 8 shortcuts | `Hey Logan AI`, `Start Console`, `Pairing`, `Stop Server`, `Allow through Firewall`, `Start at Login On`, `Start at Login Off`, `Uninstall` |
| V11-A12-A22 | Desktop shortcut + every shortcut target/args/icon | main + desktop: `wscript.exe "<install>\Launch.vbs"`, icon `heylogan.ico`; the six helpers point at their `.cmd`/`Uninstall.exe` in the install dir |
| V11-A24-A32 | HKCU Add/Remove Programs entry | DisplayName `Hey Logan AI`; **DisplayVersion 1.1.0**; Publisher; InstallLocation = install dir; UninstallString; QuietUninstallString `/S`; EstimatedSize 91,624 KB; NoModify/NoRepair=1; DisplayIcon |
| V11-A33/A34 | HKCU app key | InstallDir = install dir; Version **1.1.0** |
| V11-A35/A36 | Installer wrote start-with-Windows Run value | `"C:\WINDOWS\system32\wscript.exe" "<install>\Launch.vbs"` |
| V11-A37/A38 | Nothing under `Program Files`, no HKLM Add/Remove entry | confirmed |

### 3.2 Hands-free launch via the EXACT Run-key command line (B)

The launcher was started by parsing the registry Run value and executing exactly that command
line (`wscript.exe "<install>\Launch.vbs"`), with the test port/token overrides in the
environment (documented automation-only overrides in `Launch.vbs`).

| # | Check | Observed |
|---|---|---|
| V11-B1/B3 | `/api/health` after the Run-key launch | `{"ok":true,"app":"Hey Logan AI","version":"1.1.0",...}` |
| V11-B4/B5 | First run created `app\data\config.json` + `certs\cert.pem` + `key.pem` | yes |
| V11-B6/B7 | Test token/ports persisted in config | yes (`8790`/`8445`) |
| V11-B8-B13 | `GET /api/session-info` (token header) | app `Hey Logan AI 1.1.0`; **`speech.autoStart == true`**; **`wake.ack == "Logan here."`**; **`wake.phrases == ["hey logan","hi logan","hello logan","okay logan","hey logan ai"]`**; 6 agents |
| V11-B14 | Served `app.js` contains `autoStartListening` | yes |
| V11-B15 | Served `voice.js` contains `defaultWake` | yes |
| V11-B16 | Served `sw.js` is cache-busted and caches the native bridge | contains `heyai-bridge-v1.1.0` and `/native-voice.js` |
| V11-B17 | Served `index.html` version label | `v1.1.0` |
| V11-B18 | **Routing regression fix** - exact text the page posts after a spoken "Hey Logan, ask Claude Code ..." | `parseCommand('ask claude code to summarise the repo')` -> `agentId=claude-code`, `task='summarise the repo'` |
| V11-B19 | Server `hey logan ai open downloads` | `defaultWake=true`, `task='open downloads'` |
| V11-B21/B22 | `POST /api/command` (sync) with `ask claude code to summarise the repo` | JSON answer from the Claude Code agent: *"I couldn't find Claude Code on this PC. To install it: npm install -g @anthropic-ai/claude-code. ..."* (routing proof; the CLI is not installed on this machine) |
| V11-B23/B24 | `POST /api/command` (sync) with `hey logan list my downloads folder` | Computer answer: `"Downloads has 16 items. Showing the first 16."` |
| V11-B25 | `POST /api/command` (sync) with `hey logan` | `"Logan here. What would you like me to do?"` |
| V11-B26-B28 | Launcher started a browser with the dedicated profile and app URL | `--app=http://127.0.0.1:8790/?token=... --window-size=1180,840 --user-data-dir="<install>\browser-profile" --no-first-run --no-default-browser-check` |
| V11-B29 | `--autoplay-policy=no-user-gesture-required` present | yes |
| V11-B30 | `--window-size=1180,840` present | yes |
| V11-B31 | `--use-fake-ui-for-media-stream` **absent** | yes (no warning bar expected; see screenshot) |
| V11-B32-B36 | Seeded `<profile>\Default\Preferences` microphone grant | valid JSON; `media_stream_mic` exceptions for `http://127.0.0.1:8790,*`, `https://127.0.0.1:8445,*`, `https://localhost:8445,*`, each `setting=1` (ALLOW); no 8787 default entry |
| V11-B37 | Real app window screenshot | `_test\verify\v11-app-window.png`, 1180x840, 91,554 bytes; window titled "Hey Logan AI" with no yellow "unsupported command-line flag" bar |
| V11-B38-B47 | Live UI probe over CDP on the same seeded profile (`_test\verify\v11-ui-probe.js`) | secureContext `true`; **microphone permission `granted`** (no prompt); status line **"Listening for wake words..."**; orb state `listening`; "Stop listening" button (hands-free active); connected "Hey Logan AI - 2/6 agents ready"; version label `v1.1.0`; **TTS probe `started`** (speech synthesis works with no user gesture); **SpeechRecognition probe `STARTED`** (the wake engine can open the microphone); served app.js has `autoStartListening`; served sw.js is cache-busted; served index label `v1.1.0` |
| V11-B48/B49 | **Start-at-Login On/Off helpers round-trip the Run value** | `Start at Login Off.cmd` exit 0 and the Run value is gone; `Start at Login On.cmd` exit 0 and writes `"C:\WINDOWS\system32\wscript.exe" "<install>\Launch.vbs"` |
| V11-B50/B51 | Installed `Stop.cmd` | exit 0; server down; no node process left |
| V11-B52/B53 | Second launch via the Run value, then stop again | works (repeat use) |

The probe JSON is saved as `_test\verify\v11-ui-probe.json`. This is direct evidence that the
user's requested behaviour #1 works on this machine: the app starts listening by itself with no
click and no permission prompt, the wake engine opens the microphone, and the spoken-reply
pipeline is not blocked by the browser's autoplay policy.

### 3.3 Upgrade in place (C)

| # | Check | Observed |
|---|---|---|
| V11-C0 | App running before upgrade | health ok |
| V11-C1 | Re-run `Setup.exe /S` (no `/D=`) | exit 0 |
| V11-C2 | Upgrade stayed in the existing folder (no second copy) | yes |
| V11-C3 | Access token unchanged | yes |
| V11-C4 | Private browser profile / microphone grant preserved | grant present before and after |
| V11-C5/C6 | No duplicate shortcuts; ARP version 1.1.0 | 8 Start-Menu links; 1.1.0 |
| V11-C7 | Installer stopped the running server | health down |
| V11-C8/C9 | App starts again after the upgrade (1.1.0), then stops | yes / yes |

### 3.4 Uninstall, `/NOAUTOSTART`, purge, upgrade-over-1.0.0 (D-F)

| # | Check | Observed |
|---|---|---|
| V11-D1 | `Uninstall.exe /S` | exit 0 |
| V11-D2-D6 | Start Menu group, Desktop shortcut, ARP entry, app key, Run value removed | all gone |
| V11-D7 | `app\data` kept (documented keep-data default) | config.json still present |
| V11-D8 | **Private `browser-profile` removed by the uninstaller** | yes |
| V11-D9/D10 | Program files removed; no node/listener left | yes / yes |
| V11-E1-E3 | `Setup.exe /S /NOAUTOSTART /D=<scratch2>` | exit 0; **no Run value written**; app + shortcuts still installed |
| V11-E4-E7 | `Uninstall.exe /S /PURGEDATA` | exit 0; install folder and registry fully removed; shortcuts gone |
| V11-F0-F10 | **Upgrade over an existing 1.0.0-style custom install**: fake ARP/app-key pointing at an old tree in a scratch folder + old `app\data` (token `QA-OLD-TOKEN-0001` + marker file); run `Setup.exe /S` (no `/D=`) | installer read the registered `InstallLocation` and **installed into the old folder** (no second copy); program files upgraded (`Launch.vbs` == 1.1.0 payload); old `app\data` token and marker preserved; ARP now 1.1.0 @ old folder; Run value now old folder's new `Launch.vbs`; then `Uninstall.exe /S /PURGEDATA` exit 0 and the old folder was removed |
| V11-F11 | User's real registry/shortcut state restored after the test | exact match |

### 3.5 Portable ZIP (G)

| # | Check | Observed |
|---|---|---|
| V11-G1/G2 | Extract; `README-FIRST.txt` + `Start Hey Logan AI.cmd` present | yes |
| V11-G3 | `Launch.vbs` starts the server | health `1.1.0` |
| V11-G4 | Private profile + autoplay flag, no fake-UI flag | yes |
| V11-G5 | Portable profile seeded with the mic grant | `http://127.0.0.1:8792,*` |
| V11-G6 | Portable app window captured | `_test\verify\v11-portable-window.png`, 1180x840, 125,851 bytes; "Listening for wake words..." and no warning bar |
| V11-G7 | Portable run created no registry/shortcut side effects | ARP/Run/Start Menu/Desktop unchanged |
| V11-G8 | `tools\stop.ps1` stops the server | exit 0; health down |
| V11-G9/G10 | Visible-console `Start Hey Logan AI.cmd` starts the server; `Stop.cmd` stops it (1.0.0 regression re-check) | health ok / exit 0, health down |
| V11-G11 | No process/listener left | none |

### 3.6 Final state (H)

| # | Check | Observed |
|---|---|---|
| V11-H1 | User's real installation state restored exactly | ARP `1.0.0 @ D:\HeyLoganAI`; Run `wscript.exe "D:\HeyLoganAI\Launch.vbs"`; 6 Start-Menu links with correct targets; Desktop link |
| V11-H2 | User's real server still running on 8787/8443 (pid preserved) | 8787=pid20660, 8443=pid20660 |
| V11-H3-H5 | No listeners on QA ports; no QA node/browser process left | 0 / 0 / 0 |
| V11-H6/H7 | No test install dirs; no ARP/app-key for QA installs | none / ARP points at `D:\HeyLoganAI` |

---

## 4. Part B - Android APK 1.1.0 and project ZIP (PASS, static + cryptographic)

Method: the APK and project ZIP are read from `dist\`, hashed, copied outside the workspace,
and inspected with the bundled SDK build-tools 35.0.0 + JDK 17. No device or emulator is
available in this environment, so runtime behaviour on a phone was not executed (section 6);
the checks below prove the artifact is genuine, correctly signed, correctly described, and
compiled from exactly the shipped sources.

| # | Check | Command / observed |
|---|---|---|
| B1 | Frozen hashes | APK 226,868 B `CCB8FB6E...0173`; ZIP 236,017 B `D3B94595...ED9ED9` - both match the release manifest |
| B2 | Signature | `apksigner.bat verify --verbose --print-certs` -> `Verifies`; v2 `true`; v3 `true`; 1 signer; RSA 2048; DN `CN=HeyLoganAI, OU=Local, O=HeyLoganAI, L=Local, ST=Local, C=AU` |
| B3 | Same release key as 1.0.0 (updates in place) | certificate SHA-256 `6C:82:67:92:33:C2:AB:DF:78:0C:FC:2C:A8:9B:06:68:49:07:D0:FF:54:5D:27:A3:E1:26:83:7F:93:18:48:0C` == keystore cert; versionCode 2 > 1 |
| B4 | v1 JAR signature also valid | `apksigner verify --min-sdk-version 21` -> v1 `true` (the default verify hides it for minSdk 26) |
| B5 | Zipalign | `zipalign.exe -c -v 4 <apk>` -> `Verification succesful` |
| B6 | Badging | `package ai.heylogan.app`, **versionCode 2**, **versionName 1.1.0**, minSdk 26, targetSdk 35, launchable `ai.heylogan.app.MainActivity`, label `Hey Logan AI`; permissions `INTERNET`, `ACCESS_NETWORK_STATE`, `RECORD_AUDIO` only (no CAMERA - no QR scanner by design) |
| B7 | Contents | 20 entries: `AndroidManifest.xml`, `classes.dex`, `resources.arsc`, `assets/connect.html`, 10 launcher PNGs, 2 adaptive-icon XMLs, network security config, v1 META-INF files |
| B8 | Dex is the compiled output of the shipped sources | APK `classes.dex` SHA-256 `8B2A5C8BF0B9C3C3D422FDA555333B6E5006DEC3C868F40709FD969A56B16F8C` == `android\_manual-build\dex\classes.dex`; 38 classes incl. `MainActivity`, `VoiceBridge`, `MainActivity$PairBridge` |
| B9 | New permission-flow code in the dex | strings found: `RECORD_AUDIO`, `requestPermissions`, `onRequestPermissionsResult`, `hasMicrophonePermission`, `setMediaPlaybackRequiresUserGesture`, `addJavascriptInterface`, and the native voice bridge methods `sttAvailable`, `ttsAvailable`, `stopSpeaking`, `_onNative` |
| B10 | Source review of the microphone flow | `maybeRequestMicrophonePermission()` is called in `onCreate()` before/while the page loads; `microphonePermissionAsked` prevents repeated dialogs; on grant, `microphoneReloadDone` reloads the page **exactly once** (guarded by `!pairingMode && isHttpUrl(...)`), so a reload loop is impossible; denial shows guidance and does not loop |
| B11 | Manifest (compiled) | exported `.MainActivity` with MAIN/LAUNCHER; `usesCleartextTraffic=true`; network security config; framework `Theme.Material.NoActionBar` (no AppCompat); `<queries>` for `RecognitionService` + `TTS_SERVICE` |
| B12 | Project ZIP contents | 29 files, Gradle project + CI workflow + `tools/build-apk-manual.ps1` + docs; **no** `_manual-build`, `release-keystore`, `.jks`, `local.properties`, build outputs |
| B13 | No keystore secret in the ZIP | 0 occurrences of the keystore password literal; README points at `release-keystore/keystore-info.txt` (which stays out of the ZIP) |
| B14 | ZIP sources == sources that produced the APK | all 29 files SHA-256-identical to `android\`; no source file missing |
| B15 | 1.1.0 app tests | 87/87 (`node test\run.js` from a clean copy of `app\`), exit 0 |

The Android app itself is a WebView shell around the PC-served page, so the 1.1.0 wake-word UI
comes from the PC page. The phone side only had to be rebuilt for the up-front microphone
request/reload flow, which is present and reviewed above.

---

## 5. Part C - Docs consistency and findings resolved during verification

### 5.1 Findings found by this QA round (all fixed by the release owner, re-verified on the frozen artifacts)

| ID | Severity | Finding | Fix / re-verification |
|---|---|---|---|
| F-V11-1 | MEDIUM-HIGH | **Service-worker cache was not version-busted**: `app\public\sw.js` was byte-identical to v1.0.0 (`CACHE='heyai-bridge-v1'`, cache-first fetch handler) while `app.js`, `voice.js` and `index.html` changed, so an existing browser profile / installed PWA / Android WebView would keep serving the old v1.0.0 UI after the PC update - the new "no click / Hey Logan" behaviour would silently not appear there. The new dedicated `browser-profile` was unaffected (fresh cache), but the user's existing Edge PWA and the phone page were affected. | Fixed: `CACHE='heyai-bridge-v1.1.0'` and `/native-voice.js` added to `ASSETS` (payload `sw.js` SHA-256 `BD1EE83C...BEBB5D`); Android docs now say to close/reopen the phone app once. Re-verified on the frozen artifacts: V11-B16, V11-B45/B46 and the probe's `servedSwHasV110Cache` all PASS; the installed `app\public\sw.js` is hash-identical to the payload copy (V11-A7) and contains `heyai-bridge-v1.1.0` + `/native-voice.js`. |
| F-V11-2 | MEDIUM | **Spoken "Hey Logan, ask Claude Code to ..." went to the Computer agent**: the server-side router test passed on full text, but the page strips the wake word and posts only the remainder (`sendCommand(remainder)`, and the two-step path posts without agentId), so the server fell through to the default agent. | Fixed server-side: the no-wake fallback now runs weak-agent routing on the cleaned text. Re-verified: V11-B18 (direct router: `ask claude code to summarise the repo` -> `claude-code` / `summarise the repo`), V11-B19 (`hey logan ai open downloads` -> defaultWake + task), V11-B21/B22 (real `POST /api/command` answers from Claude Code), V11-B24/B25 (Computer answer, "Logan here. What would you like me to do?"). |
| F-V11-3 | LOW | Default-wake phrase order: full-text "hey logan ai open downloads" stripped only "hey logan", leaving "ai open downloads". | Fixed: phrases sorted longest-first; V11-B19 PASS. |
| F-V11-4 | LOW | `index.html` static About label still said `v1.0.0` (replaced at runtime on connect). | Fixed to `v1.1.0`; V11-B17 and probe `servedIndexVersionLabel` PASS. |
| F-V11-5 | LOW | `HELP.txt` still told users to install `HeyLoganAI-android-1.0.0.apk`. | Fixed to 1.1.0 in the payload; HELP.txt is in the installed tree (V11-A7 hash identity). |

Documentation clean-ups made before the freeze and re-checked in the final docs: README
checksum table placeholders filled with the four frozen values; `windows\installer\README.md`
version metadata corrected to 1.1.0; INSTALL-WINDOWS firewall path generalised to
`<install folder>\runtime\node.exe`; `docs\images\app-window.png` replaced with a real 1.1.0
window screenshot (1180x840, 124,350 bytes) showing "Listening for wake words..." and no
warning bar.

### 5.2 Documented limitations (correctly represented, not defects)

- The Windows installer is **not code-signed** - SmartScreen warns once ("More info -> Run
  anyway"). Expected and documented.
- The installer is per-user (no admin/UAC); the Windows Firewall rule needs admin, so it is a
  manual **Allow through Firewall** step - docs say the installer does not touch the firewall.
- The microphone pre-authorisation relies on the private Chromium profile. If a machine/browser
  ignores it, the normal "Allow microphone" popup appears **once**; hands-free works afterwards.
  Documented.
- The Android app is a companion (PC must be running, same network), has no QR scanner (camera
  permission deliberately absent), and its runtime behaviour could not be device-tested in this
  environment - both documented honestly in the docs/BUILD-NOTES.
- Chrome fallback: the launcher prefers Edge/Chrome with the dedicated profile; if neither is
  found it falls back to the default browser (that fallback cannot carry the profile/autoplay
  flags, so a one-time microphone/allowed-audio click may be needed there). Edge 156 was tested
  here; Chrome was not installed on this machine.

### 5.3 Informational observations (no action required)

- The NSIS bootstrap is a standard 32-bit stub (`PE machine 0x014C`) that installs the x64
  payload; `.onInit` refuses non-x64 / pre-Windows-10. Normal for NSIS 3.04 and works on the
  verified Windows 11 x64 host.
- The size figures in the docs are binary-style ("~22.5 MB Setup", "~33 MB ZIP", "~89 MB
  installed"); the README checksum table has the exact byte sizes.
- Ping-pong between the old v1.0.0 Edge PWA at OS login and the new start-at-login entry can
  open two windows; the installer README documents removing the old PWA autostart. Not a
  defect of 1.1.0.
- The `Start at Login On.cmd` helper writes the Run value as
  `%WINDIR%\system32\wscript.exe` (lower-case `system32`) while the installer writes
  `$SYSDIR\wscript.exe`; both are equivalent and both were verified (V11-B35 for the installer,
  V11-B49 for the helper).

---

## 6. What could not be verified here, and why

| Not verified | Why | Mitigation / evidence in this release |
|---|---|---|
| Actual spoken wake-word recognition and spoken replies through a real microphone/speaker (acoustic accuracy, "Hey Logan" detection, "Logan here." audibility) | This is an automated agent session; no human speaks into the microphone and no audio output is captured. The session machine does have a microphone and speakers. | The complete pipeline was verified non-acoustically on the frozen artifacts: seeded mic permission is present and reports `granted`; `SpeechRecognition.start()` fires **STARTED** (the wake engine opens the microphone with no prompt); TTS probe reports **started** (no user gesture needed); the app is in "Listening for wake words..." state in the real window screenshot. |
| Android app runtime on a phone (install, pairing, microphone permission dialog, native speech bridge, TTS) | No Android device and no emulator on this machine. | APK signed with the same release key (in-place update over 1.0.0), versionCode 2/versionName 1.1.0, badging correct, dex byte-identical to the build of the shipped sources, new permission-flow code present, project ZIP clean; documented residual risks in `android\BUILD-NOTES.md`. |
| Interactive wizard clicks (Welcome/Components/Directory/Finish "Run" checkbox) and the interactive uninstall Yes/No prompt | No UI automation for native NSIS dialogs in this session. | All silent-mode equivalents (`/S`, `/NOAUTOSTART`, `/D=`, `/PURGEDATA`, `/KEEPDATA`) were executed end-to-end; wizard behaviour reviewed statically in `installer.nsi`. |
| SmartScreen / antivirus prompts | Reputation prompts depend on Microsoft cloud reputation; the artifact is unsigned. | Documented limitation; the installer is a standard NSIS installer that installs and uninstalls cleanly on this host. |
| Windows 10 (host is Windows 11 26200 x64), Chrome-based window, other Edge versions | Only Windows 11 + Edge 156 available here. | `.onInit` enforces Windows 10+ x64; launcher supports Edge and Chrome; fallback to default browser documented. |
| Real phone-to-PC pairing over the LAN (certificate prompt, QR/link flow) | No phone. | `Pairing.cmd`/server pairing output is unchanged from the verified 1.0.0 flow; `/api/session-info` lists the LAN URL. |
| macOS/Linux checksum commands | Not available on this host. | All four hashes were independently recomputed with `Get-FileHash` and matched `SHA256SUMS.txt` and the README table (V11-0.6/0.7). |

Known environment note: the DSH agent sandbox can hang executables launched from the workspace
tree, so every installer run in this report used a byte-identical copy in `C:\Temp` whose
SHA-256 was asserted against `dist\` first.

---

## 7. Reproduction commands

Windows end-to-end (the script behind section 3; it copies `Setup.exe` to C:\Temp, asserts the
frozen hash, runs install / exact Run-key launch / browser+profile+Preferences / CDP probe /
health+session-info / routing / login helpers / stop+restart / upgrade / uninstall /
`/NOAUTOSTART` / purge / upgrade-over-1.0.0 / portable / restore, and cleans up after itself):

```powershell
Copy-Item _test\verify\run-v11-windows-e2e.ps1 C:\Temp\ -Force
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Temp\run-v11-windows-e2e.ps1 `
  -ExpectedSetupSha 1A9131CB90DEA921772542A0DEE329855460C8079F789CAB05ACF904640EB586 `
  -ExpectedPortableSha 25CAA3921530039D5AAC1695FE7A6E01CC82DB49343F3A18F856CBB49ED9BB8B
```

Live UI probe (optional; the E2E runs it automatically against the installed app):
`_test\verify\v11-ui-probe.js <debug-port> <http-port>` requires a Chromium started with
`--remote-debugging-port` and the launcher's flags/profile.

Minimal manual spot checks:

```powershell
Get-FileHash dist\* -Algorithm SHA256
(Get-Item dist\HeyLoganAI-Setup-1.1.0-win-x64.exe).VersionInfo
# install silently to a scratch folder (copy the exe out of the workspace first)
Copy-Item dist\HeyLoganAI-Setup-1.1.0-win-x64.exe C:\Temp\Setup.exe
& C:\Temp\Setup.exe /S /D=C:\Temp\HL-test
# run the EXACT start-at-login command line, with automation-only port overrides:
$env:HEY_AI_HTTP_PORT='8790'; $env:HEY_AI_HTTPS_PORT='8445'
$run = (Get-ItemProperty HKCU:\Software\Microsoft\Windows\CurrentVersion\Run -Name HeyLoganAI).HeyLoganAI
# start the wscript.exe command from $run with "<scratch>\Launch.vbs", then:
Invoke-RestMethod http://127.0.0.1:8790/api/health
Invoke-RestMethod http://127.0.0.1:8790/api/session-info -Headers @{ 'X-Bridge-Token' = '<token>' }
& "C:\Temp\HL-test\Stop.cmd"
& "C:\Temp\HL-test\Uninstall.exe" /S
```

Android re-verification (uses the bundled toolchain):

```powershell
$rel = (Resolve-Path .).Path
$env:JAVA_HOME = "$rel\_toolchain\jdk"
$bt = "$rel\_toolchain\sdk\build-tools\35.0.0"
& "$bt\apksigner.bat" verify --verbose --print-certs "$rel\dist\HeyLoganAI-android-1.1.0.apk"
& "$bt\aapt2.exe" dump badging "$rel\dist\HeyLoganAI-android-1.1.0.apk"
& "$bt\zipalign.exe" -c -v 4 "$rel\dist\HeyLoganAI-android-1.1.0.apk"
Expand-Archive dist\HeyLoganAI-Android-Project-1.1.0.zip C:\Temp\proj
Get-ChildItem C:\Temp\proj -Recurse -File | Select-String '<keystore-password>'   # 0 hits
```

---

## 8. Evidence files

All raw evidence is in `_test\verify\`:

| File | What it contains |
|---|---|
| `v11-windows-e2e.log` / `v11-windows-e2e-summary.json` / `v11-windows-e2e-results.json` | Authoritative final E2E run against the frozen artifacts: **167 checks, 167 PASS, 0 FAIL, 0 SKIP**, with the user-state restore and final clean-machine checks |
| `v11-app-window.png` | Real installed-app window (1180x840, "Listening for wake words...", no warning bar) |
| `v11-portable-window.png` | Real portable-edition window (1180x840, "Listening for wake words...", no warning bar) |
| `v11-ui-probe.json` | Live CDP probe results (mic permission granted, auto-start listening, TTS started, SpeechRecognition STARTED, served app.js/sw.js/index.html checks) |
| `v11-android-verify.txt` | Full Android evidence: apksigner, badging, APK entries, zipalign, dex identity/strings, keystore identity, project-ZIP cleanliness |
| `v11-run1-*`, `v11-run2-*` | Historical E2E runs during this round (run 1 exposed a user-state restore bug in the QA harness itself; run 2 exposed a blank first-paint in the QA screenshot capture; both harness issues were fixed and are not artifact findings) |
| `v11-dry-window.png` / `v11-dry-probe.json` | Pre-freeze launcher/probe dry run on the fixed payload |
| `v11-state-backup/`, `v11-state-backup-auto/` | Backups of the user's real v1.0.0 ARP/app-key/Run/Start-Menu/Desktop state used to restore it after testing |
| `run-v11-windows-e2e.ps1` | Reusable full E2E script (167 checks) |
| `v11-ui-probe.js` | Reusable CDP UI probe |
| `run-windows-e2e.ps1`, `android-verify.txt`, `windows-e2e*`, `ui-installed.png`, `F-1-evidence.txt`, ... | Retained v1.0.0-round evidence (superseded, kept for traceability) |

---

## 9. Sign-off

Every PASS above was executed against the four frozen artifacts whose SHA-256 values are in
section 1. The platform was left clean: the user's real v1.0.0 installation at `D:\HeyLoganAI`
was never modified and its server (pid 20660) kept running on 8787/8443 throughout; its HKCU
Add/Remove Programs entry, HKCU app key, start-at-login Run value, Start Menu group and Desktop
shortcut were snapshotted before testing and restored exactly afterwards (V11-F11, V11-H1/H2);
no test install dirs, no QA node processes, no QA browser processes and no listeners on the QA
ports were left behind (V11-H3-H7).

**Verdict: READY.** On this Windows 11 x64 machine the 1.1.0 installer installs cleanly, starts
listening by itself with no click and no microphone prompt, opens with a private Edge profile
that keeps the microphone grant and allows the spoken reply without a user gesture, starts with
Windows via the Run key (and the Start-at-Login On/Off helpers round-trip it), upgrades in place
from 1.0.0 (including a custom install folder) while keeping the access token and the private
profile, and uninstalls cleanly (keeping user data only when asked). The portable ZIP behaves
the same without touching the registry or shortcuts. The Android APK is a genuine, correctly
signed in-place update whose dex is the compiled output of the shipped sources and whose new
microphone flow is present; its runtime behaviour on a phone remains the one documented,
unverifiable-in-this-environment area (no device/emulator), alongside the honest limitation that
the actual acoustic test of "Hey Logan" needs a human at the microphone.
