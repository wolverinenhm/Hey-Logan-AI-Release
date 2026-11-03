# Hey Logan AI - Windows installer / portable ZIP: TEST RESULTS

Real end-to-end run on the release machine. Nothing in this file is estimated:
every number comes from the run log/JSON next to it.

- Date: 2026-11-03, 21:25:07 - 21:27:33 local (Australia/Brisbane)
- Host: `DESKTOP-VKJOJCR`, Windows 11 Enterprise 10.0.26200, x64
- User: `STUDENT\s2121270`, PowerShell 5.1.26100.9711
- Payload packaged: 569 files / 89.34 MB (app + Node.js v22.23.3 runtime +
  launchers), `app\data` excluded
- Build toolchain: NSIS 3.04 (makensis, Modern UI 2), `tar.exe` for the ZIP,
  no code-signing certificate (unsigned release)

This run covers the **hardened** installer (task-8): data-loss guard on both
keep-data paths, no dialogs in silent mode, `/NOAUTOSTART`, `Uninstall.lnk`,
and portable build-script compiler discovery.

## Result

```
CHECKS: 181   PASS: 181   FAIL: 0
```

The complete 181-assertion log is `e2e-run.log`; the machine-readable summary is
`e2e-summary.json` (both in this folder). Harness: `run-e2e.ps1`.

## Artifacts under test (final deliverables)

| Artifact | Size (bytes) | SHA-256 |
| --- | ---: | --- |
| `dist\HeyLoganAI-Setup-1.0.0-win-x64.exe` | 23,607,380 (22.51 MB) | `8209b35898ff990c460e492e1f4dae7f7f189e8751e22021ff3a5f9845ced9fc` |
| `dist\HeyLoganAI-Portable-1.0.0-win-x64.zip` | 35,108,753 (33.48 MB) | `18fa9938946f2b14d58c5f8425bf3a3a7e97172c4c6cb1cafdc0c5db30cb5cf6` |

Both were built from the frozen `windows\payload\HeyLoganAI\` tree (569 files,
`app\data` absent). The portable ZIP contains the same payload plus
`README-FIRST.txt` and `Start Hey Logan AI.cmd` (654 archive entries).
Checksums are recorded in `_test\win-installer\SHA256SUMS-windows.txt`
(`dist\` intentionally has no `SHA256SUMS.txt` - the Lead owns that file).

Method: the built Setup.exe is copied to `C:\Temp\hl-e2e\setup\` and the copy's
SHA-256 is asserted equal to the `dist\` file before anything is executed (the
DSH agent file sandbox wraps executables that live inside the workspace tree;
running the copy from `C:\Temp` is the supported path). The portable ZIP is
extracted to `C:\Temp\hl-e2e\portable\` and run from there.

## Hardening items verified in this run

### 1. Data-loss guard on the keep-data paths (critical)

- An upgrade was run while a share-deny handle was held on
  `<install>\app\data\config.json` (real-world equivalent: a locked file or an
  antivirus scan). The installer **aborted with exit code 1 in 4 s**, without a
  dialog (silent mode), instead of continuing into the program-file cleanup:
  - PASS `Upgrade aborts (non-zero exit) when app\data cannot be stashed` (exit=1)
  - PASS `Aborted upgrade kept the access token`
  - PASS `Aborted upgrade kept the HTTPS certificate`
  - PASS `Aborted upgrade did not delete program files`
  - PASS `Aborted upgrade left no .hl-data-keep stash`
- After releasing the handle, the same upgrade succeeded normally (exit 0) and
  the token was still unchanged - the aborted attempt left the installation
  fully usable.
- The uninstall keep-data path uses the same guard (same `ClearErrors; Rename;
  ${If} ${Errors}; Abort` pattern, code-reviewed; every normal keep-data
  uninstall below passes).
- Both keep-data paths also recover a stash left by a previously interrupted
  run instead of deleting it.

### 2. No dialogs in silent mode

- The two `.onInit` MessageBoxes (unsupported architecture / Windows older than
  10) are wrapped in `${IfNot} ${Silent} ... ${EndIf}`; silent mode keeps
  `SetErrorLevel 1` + `Quit` only - code-reviewed in `installer.nsi`.
  (Cannot be executed on this Windows 10+ x64 host, so this item is asserted by
  code review; it can no longer block `/S` on an unsupported host.)
- The locked-data abort above proves a silent failure path returns exit code 1
  without waiting for a dialog.

### 3. `/NOAUTOSTART`

- `Setup.exe /S /NOAUTOSTART /D=C:\Temp\hl-e2e\custom-install-noauto` exits 0,
  installs to the `/D=` folder, creates all Start Menu shortcuts, and leaves
  **no** `HKCU\...\Run\HeyLoganAI` value - PASS (checks 149-155).
- Plain `/S` still writes the Run value by default (checks 70/71) - the switch
  is strictly opt-out.
- `/S /NOAUTOSTART /D=` uninstall (`/S /PURGEDATA`) removes the install cleanly.

### 4. `Uninstall.lnk`

- Start Menu group contains `Uninstall.lnk` -> `<install>\Uninstall.exe`
  (check 69); shown as "Uninstall" in the Start Menu. No
  `Uninstall Hey Logan AI.lnk` is created anymore.

### 5. Portable rebuild (compiler discovery)

- `lib\build-common.ps1` accepts `-Makensis <path>` and searches: bundled
  `_toolchain\nsis\Bin\makensis.exe` -> `_toolchain\nsis\makensis.exe` ->
  `%ProgramFiles%\NSIS\makensis.exe` -> `%ProgramFiles(x86)%\NSIS\makensis.exe`
  -> `makensis`/`makensis.exe` on PATH, and throws a clear error listing
  everything it tried.
- Verified by unit test: auto-detection returns the bundled compiler; explicit
  `-Makensis` returns the same; an invalid explicit path throws
  `The -Makensis path does not exist: ...`; a simulated empty release root
  throws the full "was not found. Tried:" list.
- `build-setup.ps1` and `build-all.ps1` expose `-Makensis`; the final artifacts
  were built through `build-all.ps1` (bundled compiler path logged).

## What was verified, with observed values

### Artifact integrity / metadata

- Setup.exe copy SHA-256 == `dist` SHA-256 (`8209b358...`) - PASS.
- Version info embedded in Setup.exe: ProductName `Hey Logan AI`,
  FileDescription `Hey Logan AI Setup`, CompanyName `Hey Logan AI`,
  FileVersion/ProductVersion `1.0.0`, LegalCopyright
  `Copyright (c) 2026 Hey Logan AI` - all PASS.
- Setup.exe PE manifest requests `asInvoker` and does **not** request
  `requireAdministrator` (per-user install, no UAC) - PASS.
- Portable ZIP layout: `README-FIRST.txt`, `Start Hey Logan AI.cmd`,
  `runtime/node.exe`, `app/server/index.js` present; **no** `app/data/`
  (user data never shipped) - all PASS.
- Exactly 4 files in `dist\`: the two Windows artifacts above plus the Lead's
  `HeyLoganAI-android-1.0.0.apk` (226,868 B) and
  `HeyLoganAI-Android-Project-1.0.0.zip` (232,691 B), neither touched by this
  task. No `_compilecheck.exe`, no tiny test exes, no `.idsig`, no
  `dist\SHA256SUMS.txt`.

### Interactive wizard (Modern UI 2)

- Launching Setup.exe opens a real wizard window titled `Hey Logan AI Setup`
  (asserted from the live window title) - PASS.
- Closing it before installing leaves no install folder / no ARP entry - PASS.
- Page screenshots captured from the final binary (PrintWindow, no installation
  performed) in `evidence\`:
  - `wizard-1-welcome.png` - Welcome page
  - `wizard-2-components.png` - Components page: "Hey Logan AI (required)"
    (checked, read-only) + "Start Hey Logan AI when I sign in" (checked by
    default), Space required 89.6 MB
  - `wizard-3-directory.png` - Install location page, default
    `C:\Users\s2121270\AppData\Local\Programs\HeyLoganAI`, Browse button,
    per-user note

### Silent install (`/S`, default location)

- `Setup.exe /S` exit code 0 in 12.1 s - PASS.
- Installed to `%LOCALAPPDATA%\Programs\HeyLoganAI` - PASS.
- All expected files present: `Launch.vbs`, `Start Console.cmd`, `Stop.cmd`,
  `Pairing.cmd`, `Allow through Firewall.cmd`, `HELP.txt`, `heylogan.ico`,
  `Uninstall.exe`, `tools\{pair.js,stop.ps1,firewall.ps1}`,
  `runtime\node.exe` (86,973,768 bytes), `app\...\native-voice.js` - PASS.
- No `app\data` shipped or created by the installer - PASS.
- Installed text is the frozen payload: `HELP.txt` contains the new
  "phone camera" wording; `tools\pair.js` contains the new
  "The app has no camera scanner." footer - PASS.
- Silent install does not start the app (no node.exe process) - PASS.

### Add/Remove Programs (HKCU) and registry

| Value | Observed |
| --- | --- |
| DisplayName | `Hey Logan AI` |
| DisplayVersion | `1.0.0` |
| Publisher | `Hey Logan AI` |
| DisplayIcon | `<install>\heylogan.ico` |
| InstallLocation | `C:\Users\s2121270\AppData\Local\Programs\HeyLoganAI` |
| UninstallString | `"<install>\Uninstall.exe"` |
| QuietUninstallString | `"<install>\Uninstall.exe" /S` |
| EstimatedSize | 91,605 KB |
| NoModify / NoRepair | 1 / 1 |
| VersionMajor / VersionMinor | 1 / 0 |
| SystemComponent | absent (visible in Apps & features) |

- `HKCU\Software\HeyLoganAI` -> `InstallDir`, `Version=1.0.0` - PASS.
- The installer performs HKCU-only writes (static inspection of `installer.nsi`:
  no HKLM registry commands; `RequestExecutionLevel user`).
- Start-at-login default on: `HKCU\...\Run\HeyLoganAI` =
  `"C:\WINDOWS\system32\wscript.exe" "...\Launch.vbs"` - PASS.
  `/NOAUTOSTART` removes this (see above).

### Shortcuts

- Start Menu group `Hey Logan AI` with 6 shortcuts - PASS.
- Main shortcut target `C:\Windows\System32\wscript.exe`, arguments
  `"...\Launch.vbs"`, icon `...\heylogan.ico,0` - PASS.
- Desktop shortcut: same target/arguments/icon - PASS.
- `Start Console.lnk` -> `Start Console.cmd`, `Pairing.lnk` -> `Pairing.cmd`,
  `Stop Server.lnk` -> `Stop.cmd`, `Allow through Firewall.lnk` ->
  `Allow through Firewall.cmd`, `Uninstall.lnk` -> `Uninstall.exe` - PASS.

### Launch exactly like the shortcut / health endpoint

- Executed the main shortcut's target + arguments (`wscript.exe
  "...\Launch.vbs"`), server came up hidden - PASS.
- `GET http://127.0.0.1:8787/api/health` ->
  `{"ok":true,"app":"Hey Logan AI","version":"1.0.0","time":"...","requiresToken":true}` - PASS.
- First run created `app\data\config.json`, a `XXXX-XXXX-XXXX` access token
  (observed `RXEY-WCG6-YCZV`) and `app\data\certs\{cert.pem,key.pem}` - PASS.
- `GET /api/pairing` (with token header) returns the token, a LAN HTTPS pairing
  URL `https://192.168.0.104:8443?token=...` and a QR SVG - PASS.

### Pairing.cmd

- Exit code 0; prints the access token, `192.168.0.104` LAN address,
  `https://192.168.0.104:8443` phone URL, `http://127.0.0.1:8787` PC URL and a
  scannable QR code (block-art rendered) - all PASS.
- Frozen-payload footer text present:
  - `The app has no camera scanner.`
  - `Phone camera / Chrome: scan the QR code below, accept the certificate`
  - both PASS. Full captured output: `pairing-output.txt`.

### Stop.cmd

- Exit code 0; printed `Stopped server process ..., Server stopped.` - PASS.
- Health endpoint stopped answering and no node.exe process remained - PASS.
  Captured output: `stop-output.txt`.

### In-place upgrade (server running, data preserved)

- Re-ran `Setup.exe /S` while the server was running: exit 0 in 18.6 s - PASS.
- Upgrade stopped the running server - PASS.
- Upgrade replaced program files (a marker appended to the installed
  `app\server\index.js` was gone after the upgrade) - PASS.
- Upgrade kept the access token (`RXEY-WCG6-YCZV` before == after) and the
  HTTPS certificate - PASS.
- Upgrade kept the `app\data` marker file - PASS.
- Upgrade kept ARP entry, Run value and Start Menu shortcuts - PASS.
- App was healthy again after the upgrade - PASS.

### Uninstall - keep data (`Uninstall.exe /S`)

- Exit code 0 (cleanup completes ~5 s later in the NSIS uninstaller's temp
  re-launch; the harness waits for the end state) - PASS.
- ARP entry, Run value, `HKCU\Software\HeyLoganAI`, Start Menu group and
  Desktop shortcut all removed - PASS.
- `Uninstall.exe` removed; install folder kept and contains only `app\data`
  (8 leftover items, 0 outside `app\data`) - PASS.
- Kept token still readable in `app\data\config.json` - PASS.

### Reinstall over kept data + uninstall purge (`/S /PURGEDATA`)

- Reinstall over the kept `app\data`: exit 0, token preserved, program files
  restored, ARP re-created - PASS.
- `Uninstall.exe /S /PURGEDATA`: exit code 0; install folder, ARP, Run value and
  shortcuts gone; no node.exe left - PASS.

### Custom install directory (`/D=`)

- `Setup.exe /S /D=C:\Temp\hl-e2e\custom-install`: exit 0, files written there,
  default folder untouched - PASS.
- ARP `InstallLocation`, Run value and shortcuts point at the custom folder -
  PASS.
- Uninstaller launched from the custom folder found its own install dir
  (registry-based), exited 0, removed the folder and the ARP entry - PASS.

### Portable ZIP

- Extract: exit 0 in 1.2 s - PASS.
- `README-FIRST.txt`, `Start Hey Logan AI.cmd` (runs `runtime\node.exe` on
  `app\server\index.js`), `runtime\node.exe`, app files including
  `native-voice.js`; no `app\data` - PASS.
- Bundled runtime `runtime\node.exe --version` -> `v22.23.3` - PASS.
- Server from the extracted tree: health ok, app `Hey Logan AI` 1.0.0 - PASS.
- Portable created its own `app\data`, and created **no** ARP entry, **no** Run
  value, **no** Start Menu group and **no** Desktop shortcut - all PASS.
- Portable `tools\stop.ps1` stopped the server; no node.exe left - PASS.
- ZIP entry hashes for `tools/pair.js` and `HELP.txt` equal the frozen payload
  files (updated text is really inside the ZIP) - verified separately.

### Final machine state

After the run: no install dir, no custom install dir, no ARP entry, no
`HKCU\Software\HeyLoganAI`, no Run value, no Start Menu group, no Desktop
shortcut, no node.exe processes and ports 8787/8443 free - all PASS.

## Silent switches supported by the final binary

| Command | Verified |
| --- | --- |
| `HeyLoganAI-Setup-1.0.0-win-x64.exe /S` | exit 0, default dir, start-at-login on, app not started |
| `HeyLoganAI-Setup-1.0.0-win-x64.exe /S /NOAUTOSTART` | no HKCU Run value written |
| `HeyLoganAI-Setup-1.0.0-win-x64.exe /S /NOAUTOSTART /D=<dir>` | exit 0, custom dir honored, no Run value |
| `HeyLoganAI-Setup-1.0.0-win-x64.exe /S /D=<dir>` | exit 0, custom dir honored |
| `Uninstall.exe /S` or `/S /KEEPDATA` | exit 0, keeps `app\data` |
| `Uninstall.exe /S /PURGEDATA` | exit 0, deletes `app\data` and the folder |
| `HeyLoganAI-Setup-1.0.0-win-x64.exe` (no args) | Modern UI 2 wizard window opens (Welcome -> Components -> Directory) |

Exit code `1` is used for an intentional abort: the data-safety guard (could not
move `app\data` aside) or an unsupported OS/architecture in silent mode. Silent
mode never shows a dialog.

## Limits / caveats

- Unsigned binaries: SmartScreen may show "Windows protected your PC" for
  Setup.exe (and a warning for the downloaded ZIP) - "More info -> Run anyway".
- Per-user install only (no UAC, no Program Files, no all-users install).
- Windows 10/11 x64 only (bundled x64 Node.js 22).
- The installer does not modify Windows Firewall; phone access uses the
  "Allow through Firewall" shortcut (UAC) or the Windows prompt.
- Silent uninstall's file deletion finishes asynchronously after the
  `Uninstall.exe` process returns; scripts should poll for the end state.
- Default ports 8787/8443; the installer does not choose alternate ports.
- Start-at-login defaults on; `/NOAUTOSTART` (silent) or clearing the component
  (interactive) removes it without touching `app\data`.

## How to reproduce

```powershell
# rebuild (from the release root; payload must exist under windows\payload\HeyLoganAI)
windows\installer\build.cmd
# or with an external NSIS:
#   windows\installer\build.cmd -Makensis "C:\Program Files (x86)\NSIS\makensis.exe"

# run the E2E from a copy outside the workspace (agent sandbox requirement)
New-Item -ItemType Directory C:\Temp\hl-test -Force | Out-Null
Copy-Item _test\win-installer\run-e2e.ps1 C:\Temp\hl-test\ -Force
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Temp\hl-test\run-e2e.ps1
```

The harness writes `e2e-run.log` and `e2e-summary.json` next to itself, recreates
all install/uninstall cycle evidence above, and removes all installed state at
the end.
