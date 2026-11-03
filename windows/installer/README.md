# Hey Logan AI - Windows packaging (NSIS installer + portable ZIP)

This folder builds the two Windows release artifacts:

| Artifact | What it is |
| --- | --- |
| `dist\HeyLoganAI-Setup-1.0.0-win-x64.exe` | NSIS / Modern UI 2 Setup wizard. Per-user install (no UAC), real uninstaller, Start Menu + Desktop shortcuts, Add/Remove Programs entry, optional start-at-login. |
| `dist\HeyLoganAI-Portable-1.0.0-win-x64.zip` | Portable edition. Extract and run; no installer, no registry writes, no shortcuts. Includes `README-FIRST.txt` and a visible-console `Start Hey Logan AI.cmd`. |
| `_test\win-installer\SHA256SUMS-windows.txt` | SHA-256 of both Windows artifacts (written by `build-all.ps1`; kept out of `dist\` so the release folder contains only the Lead's deliverables + the two Windows artifacts). |

Both artifacts are produced from the **same payload tree**:
`windows\payload\HeyLoganAI\` - the app (with `node_modules`), a private
`runtime\node.exe` (Node.js v22.23.3, x64), the launcher scripts
(`Launch.vbs`, `Start Console.cmd`, `Stop.cmd`, `Pairing.cmd`,
`Allow through Firewall.cmd`, `HELP.txt`, `tools\pair.js`, `tools\stop.ps1`,
`tools\firewall.ps1`) and `heylogan.ico`.

The build scripts stage a **clean copy** of that payload and hard-exclude
`app\data` (the user's settings, pairing token and HTTPS certificate). User
data is created on first start and is never shipped. If the staged tree still
contains `app\data` the build fails.

---

## Rebuild

Prerequisites (everything is already in this release workspace):

- Windows 10/11 **x64** (the bundled Node.js runtime is x64).
- Staged payload at `windows\payload\HeyLoganAI\` (see layout above).
- NSIS 3 with Modern UI 2. This release tree bundles it at
  `_toolchain\nsis\Bin\makensis.exe` (this build: makensis v3.04,
  electron-builder's NSIS distribution) and the build scripts use it
  automatically. If you build from a copy without that folder, install
  NSIS 3.x and either put `makensis` on PATH, pass
  `-Makensis "C:\Program Files (x86)\NSIS\makensis.exe"`, or rely on the
  `%ProgramFiles%\NSIS` / `%ProgramFiles(x86)%\NSIS` fallback.
- No Node.js and no npm are needed on the build machine: the runtime is
  bundled and the app dependencies are already inside the payload.

One command (easiest):

```bat
windows\installer\build.cmd
```

or, explicitly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File windows\installer\build-all.ps1 [-Version 1.0.0] [-Makensis <path-to-makensis.exe>]
```

Individual steps:

```powershell
# Setup.exe only
powershell -NoProfile -ExecutionPolicy Bypass -File windows\installer\build-setup.ps1 [-Version 1.0.0] [-Makensis <path>] [-KeepStage]

# Portable ZIP only
powershell -NoProfile -ExecutionPolicy Bypass -File windows\installer\build-portable.ps1 [-Version 1.0.0] [-KeepStage]
```

Notes:

- The build takes a few minutes: the 89 MB payload is compressed with solid
  LZMA into a ~22.5 MB Setup.exe, and the portable ZIP (~33 MB) is written with
  `tar.exe`.
- All intermediate staging goes to `windows\installer\.build\` and is deleted
  after a successful build (unless `-KeepStage` is given). The compiler's
  `TEMP` is redirected there as well, so the build works in environments where
  the ambient temp folder is not writable.
- `-Version` changes the version embedded in Setup.exe, the output filename and
  the Add/Remove Programs display version. Keep it in sync with
  `app\package.json`.
- `-Makensis <path>` overrides the compiler search. Without it the build tries
  the bundled toolchain first, then `%ProgramFiles%\NSIS\makensis.exe`,
  `%ProgramFiles(x86)%\NSIS\makensis.exe`, and finally `makensis` /
  `makensis.exe` on PATH.
- The build never modifies `windows\payload\HeyLoganAI\`.

Files in this folder:

```
windows\installer\
  installer.nsi          NSIS script (Modern UI 2 wizard + uninstaller)
  build-setup.ps1        builds dist\HeyLoganAI-Setup-<version>-win-x64.exe
  build-portable.ps1     builds dist\HeyLoganAI-Portable-<version>-win-x64.zip
  build-all.ps1          builds both + _test\win-installer\SHA256SUMS-windows.txt
  build.cmd              cmd wrapper (ExecutionPolicy Bypass) for build-all.ps1
  lib\build-common.ps1   shared validation / staging / hashing helpers
  portable\
    README-FIRST.txt     portable edition instructions
    Start Hey Logan AI.cmd  visible-console portable launcher
```

---

## Installer behaviour

- **Per-user install, no UAC.** `RequestExecutionLevel user`, default folder
  `%LOCALAPPDATA%\Programs\HeyLoganAI`, all registry writes under `HKCU`.
  Nothing is installed system-wide.
- **Wizard pages (Modern UI 2):** Welcome -> Components -> Install location
  (with Browse) -> Installing -> Finish (with a "Run Hey Logan AI" checkbox).
  The Components page contains the required application component and the
  optional **"Start Hey Logan AI when I sign in"** component (checked by
  default).
- **Shortcuts** in Start Menu >"Hey Logan AI":
  - `Hey Logan AI` - main shortcut: target `wscript.exe`,
    arguments `"<install>\Launch.vbs"`, icon `heylogan.ico` (starts the server
    hidden and opens the chromeless Edge/Chrome app window)
  - `Start Console` - `Start Console.cmd`
  - `Pairing` - `Pairing.cmd`
  - `Stop Server` - `Stop.cmd`
  - `Allow through Firewall` - `Allow through Firewall.cmd`
  - `Uninstall` - `Uninstall.exe`
  - plus the same main shortcut on the Desktop.
- **HKCU Add/Remove Programs entry** (`DisplayName`, `DisplayVersion`,
  `Publisher`, `DisplayIcon`, `InstallLocation`, `UninstallString`,
  `QuietUninstallString`, `EstimatedSize`, `NoModify`, `NoRepair`,
  `VersionMajor`/`VersionMinor`, `URLInfoAbout`, `HelpLink`). The uninstaller
  is written to `<install>\Uninstall.exe`.
- **Start at login:** `HKCU\...\CurrentVersion\Run\HeyLoganAI` =
  `"wscript.exe" "<install>\Launch.vbs"`, only when that component is selected.
  Re-running Setup with the component cleared removes the Run value.
- **Upgrade in place:** Setup stops a server that is running from the install
  folder (`tools\stop.ps1` matches only node processes whose command line
  points into that folder), replaces the program files and **keeps
  `<install>\app\data`** (settings, pairing token, HTTPS certificate), so a
  phone does not need to be re-paired. A stale run value is rewritten.
  If the existing `app\data` cannot be moved aside safely (e.g. a file is
  locked by another program or an antivirus scan), Setup **aborts with exit
  code 1 before deleting anything**: the old installation, registry entries and
  user data stay intact, so re-running Setup after closing the locking program
  is safe. (The move is error-checked - it can never fall through into the
  program-file cleanup and delete the token/certificates.)
- **Uninstall:** stops the server, removes shortcuts, ARP entry and Run value,
  then asks whether to keep `app\data` (interactive: Yes/No message box; silent:
  keep by default, see switches below) and removes the install folder.
  It exits 0 on success. If it was asked to keep `app\data` but cannot move that
  folder aside safely, it stops with exit code 1 **before deleting any program
  file or `app\data`** - run `Uninstall.exe` again once whatever locks the
  folder is closed.
- **Version metadata:** `VIProductVersion`/`VIFileVersion` 1.0.0.0 and
  `VIAddVersionKey` strings (ProductName `Hey Logan AI`, FileDescription
  `Hey Logan AI Setup`, CompanyName `Hey Logan AI`, LegalCopyright,
  FileVersion/ProductVersion `1.0.0`) so the exe looks legitimate in Explorer.
  All installer strings are ASCII.

### Registry keys written (HKCU only)

```
HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\HeyLoganAI
HKCU\Software\HeyLoganAI                       (InstallDir / Version / DataDir)
HKCU\Software\Microsoft\Windows\CurrentVersion\Run  value "HeyLoganAI"  (optional)
```

They are all removed by the uninstaller.

### User data

`<install>\app\data\` - created by the app on first start:

- `config.json` - settings and the private access token
- `certs\cert.pem`, `certs\key.pem` - self-signed HTTPS certificate for the phone
- `pairing.txt`, screenshots, etc.

Upgrades never touch it. Uninstall keeps it unless purged.

---

## Silent / command-line switches

| Command | Effect |
| --- | --- |
| `HeyLoganAI-Setup-1.0.0-win-x64.exe` | Interactive wizard. |
| `HeyLoganAI-Setup-1.0.0-win-x64.exe /S` | Silent install into the default folder, all default components (start-at-login **on**), no "Run" launch. Exits 0 on success. |
| `HeyLoganAI-Setup-1.0.0-win-x64.exe /S /NOAUTOSTART` | Silent install **without** the start-at-login component: no `HKCU\...\Run` value is written. Works together with `/D=`. |
| `HeyLoganAI-Setup-1.0.0-win-x64.exe /S /D=C:\Apps\HeyLoganAI` | Silent install into a custom folder. |
| `Uninstall.exe /S` | Silent uninstall, **keep** `app\data`. |
| `Uninstall.exe /S /KEEPDATA` | Same as above, explicit. |
| `Uninstall.exe /S /PURGEDATA` | Silent uninstall, **delete** `app\data` as well. |
| `Uninstall.exe` | Interactive uninstall - asks whether to keep `app\data`. |

`/D=` details: this is the standard NSIS rule - it must be the **last**
parameter and the path must **not** be wrapped in quotes, even if it contains
spaces (e.g. `/D=C:\My Apps\HeyLoganAI`). The interactive wizard's Browse
button has no such limitation.

Exit codes: `0` = success (also for a silent uninstall where there was nothing
left to delete). `1` = the installer/uninstaller aborted on purpose because of
the data-safety guard described above, or because the OS/architecture is not
supported (Windows 10+ x64 required). **In silent mode no message boxes are
shown** - unsupported-OS/architecture checks and the data-safety guard exit
with code 1 without user interaction.

**Silent uninstall timing:** NSIS uninstallers re-launch themselves from a
temporary copy, so the `Uninstall.exe` process started by a script returns
before the actual cleanup has finished (typically 2-6 s later). Automation
should poll for the state change (install folder / ARP entry gone) instead of
assuming removal is complete when the process exits. `_test\win-installer\run-e2e.ps1`
does exactly that (`Wait-SilentUninstallComplete`).

---

## Portable ZIP

Extract `dist\HeyLoganAI-Portable-1.0.0-win-x64.zip`; it contains one top-level
folder `HeyLoganAI\` with the same payload plus:

- `README-FIRST.txt` - quick start for the portable edition
- `Start Hey Logan AI.cmd` - starts the server in a visible console window

No registry entries, no shortcuts and no uninstaller: delete the folder to
remove it. Settings/token/certificate live in `<extracted>\HeyLoganAI\app\data`.
`Launch.vbs` (hidden server + app window) and all other launchers work exactly
as in the installed version.

---

## Testing

`_test\win-installer\run-e2e.ps1` runs the full real end-to-end test: silent
install, install-dir contents, shortcuts (targets + icons), ARP values, Run
value, shortcut launch -> health endpoint, `Pairing.cmd`, `Stop.cmd`, in-place
upgrade keeping the token and certificate, the **locked-`app\data` data-safety
guard** (upgrade must abort with exit code 1 and leave token + certificate
intact), `/S /NOAUTOSTART` (no Run value), uninstall keep-data and purge, silent
uninstall exit code, custom `/D=` install, portable ZIP run with no
registry/shortcut side effects, and a final clean-machine check. It writes
`e2e-run.log` and `e2e-summary.json` next to itself and leaves the machine
clean.

**Important for agents/automation:** the DSH agent file sandbox wraps
executables that live inside this workspace tree (`C:\Users\...\Downloads\...`),
which can make a GUI installer launched from here hang or fail to write. The
test harness therefore copies the built Setup.exe to `C:\Temp\hl-e2e\setup\`,
verifies the copy's SHA-256 against the `dist` file, and only then executes it.
Run the test script from a copy outside the workspace as well:

```powershell
New-Item -ItemType Directory C:\Temp\hl-test -Force | Out-Null
Copy-Item _test\win-installer\run-e2e.ps1 C:\Temp\hl-test\ -Force
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Temp\hl-test\run-e2e.ps1
```

See `_test\win-installer\TEST-RESULTS.md` for the latest recorded run
(pass/fail counts, artifact sizes and SHA-256).

---

## Known limits and user-facing caveats

- **The installer and the portable ZIP are unsigned.** There is no code-signing
  certificate in this release toolchain, so Windows SmartScreen / Defender may
  show "Windows protected your PC" (Setup.exe) or a warning for the downloaded
  ZIP. Click **More info -> Run anyway**. This is expected for an unsigned
  release; the installer itself is a standard NSIS installer, not a
  self-extractor hack.
- **Per-user install only.** No administrator rights and no UAC prompt for the
  install/uninstall. Windows Settings > Apps shows it for the installing user
  only. There is no machine-wide / all-users option.
- **Firewall is not changed by the installer** (that would need admin). For
  phone access the user must allow the bundled runtime through Windows
  Firewall: click "Allow access" on the Windows prompt the first time it
  appears, or run Start Menu >"Allow through Firewall" (one UAC prompt).
- **Windows 10/11 x64 only.** The bundled runtime is x64 and there is no
  ARM64/32-bit build. Windows 10 is the minimum (Node.js 22 requirement); the
  installer refuses to run on older Windows.
- **Default ports 8787 (HTTP) / 8443 (HTTPS).** If another program uses them the
  server will not start; run `Stop.cmd` (or close the other program) and try
  again. The installer does not pick alternate ports; they can be changed in
  `app\data\config.json`.
- **Start-at-login is on by default** (`HKCU\...\Run`). To turn it off without
  uninstalling: run Setup again and clear "Start Hey Logan AI when I sign in";
  this is an in-place update and keeps `app\data`.
- **Uninstall "keep data" leaves `<install>\app\data` on disk** and the install
  folder is intentionally not empty afterwards. Choose "No" / `/PURGEDATA` to
  remove everything.
- **Data-safety abort (by design):** if `app\data` cannot be moved aside during
  an upgrade or a keep-data uninstall (locked file / antivirus scan), Setup or
  Uninstall exits with code 1 instead of continuing - the token and
  certificates are never deleted. Close the locking program and run it again.
- **Start-at-login is on by default and can be automated off** with
  `/NOAUTOSTART` (see the silent switches table). Interactive users just clear
  the "Start Hey Logan AI when I sign in" checkbox.
- **English-only installer UI**, all strings ASCII. The application UI itself
  is part of the payload and is unchanged by the installer.
- **No auto-update.** Ship a newer Setup.exe; running it over the old install
  performs the in-place upgrade in the same folder. Installing to a *new*
  folder leaves the old copy in place (uninstall it separately).
- **~89 MB installed / ~22.5 MB Setup / ~33 MB ZIP** - the size is dominated by
  the bundled Node.js runtime; no Node.js installation is needed on the user's
  PC.
- **Antivirus:** NSIS installers are widely used and usually not flagged.
  Because the payload contains a full `node.exe`, first-run scans can take a
  few seconds on slow disks.

## Node.js runtime

The 83 MB Node.js runtime is not stored in git. Before the first build run
`fetch-node.ps1` in this folder: it downloads the pinned Node.js version from
nodejs.org into `..\payload\HeyLoganAI\runtime\node.exe` and verifies the official
SHA-256 checksum.
