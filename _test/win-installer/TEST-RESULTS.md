# Hey Logan AI v1.1.0 - Windows installer / portable ZIP: TEST RESULTS

Real end-to-end run on the release machine. Nothing in this file is estimated:
every number comes from the run log/JSON next to it.

- Date: 2026-11-05, 18:06:55 - 18:10:45 local (Australia/Brisbane)
- Host: `DESKTOP-VKJOJCR`, Windows 11 Enterprise 10.0.26200, x64
- User: `STUDENT\s2121270`, PowerShell 5.1.26100.9711
- Payload packaged: 571 files / 89.36 MB (app v1.1.0 + Node.js v22.23.3
  runtime + launchers + auto-start helpers), `app\data` excluded
- Build toolchain: NSIS 3.04 (makensis, Modern UI 2), `tar.exe` for the ZIP,
  no code-signing certificate (unsigned release)

This run covers **v1.1.0** (final QA-fix build): the hands-free "Hey Logan"
launcher (dedicated browser profile + seeded microphone grant + autoplay
flag), start-at-login helpers, upgrade-in-place via the registered install
location, the service-worker cache-bust and spoken "ask Claude Code ..."
routing fixes, and all v1.0.0 hardening.

## Special machine situation (handled by the test)

The machine also has the **user's real v1.0.0 installation at `D:\HeyLoganAI`**
with the app running on ports 8787/8443 (pid 20660), plus an Edge PWA with its
own OS-login autostart. The test therefore:

- backs up the real HKCU ARP entry, HKCU app key, Run value, Start Menu group
  and Desktop shortcut, and restores them **exactly** in a `finally` block;
- never writes to, stops or deletes `D:\HeyLoganAI` and never kills pid 20660;
- runs all test installations in `C:\Temp` scratch dirs and all test servers /
  launcher windows on ports **8790/8445** (`HEY_AI_HTTP_PORT` /
  `HEY_AI_HTTPS_PORT`), because 8787/8443 belong to the user's live app.

The restored state is asserted at the end (ARP → `D:\HeyLoganAI`, Run value
byte-for-byte, 574 files in `D:\HeyLoganAI` unchanged, pid 20660 still
listening on 8787, Edge PWA entry untouched).

## Result

```
CHECKS: 208   PASS: 208   FAIL: 0
```

Complete log: `e2e-run.log`; machine-readable summary: `e2e-summary.json`;
harness: `run-e2e.ps1`.

## Artifacts under test (final deliverables)

| Artifact | Size (bytes) | SHA-256 |
| --- | ---: | --- |
| `dist\HeyLoganAI-Setup-1.1.0-win-x64.exe` | 23,607,146 (22.52 MB) | `1a9131cb90dea921772542a0dee329855460c8079f789cab05acf904640eb586` |
| `dist\HeyLoganAI-Portable-1.1.0-win-x64.zip` | 35,114,765 (33.49 MB) | `25caa3921530039d5aac1695fe7a6e01cc82db49343f3a18f856cbb49ed9bb8b` |

Built from the frozen payload (571 files). Portable ZIP: 656 entries
(`HeyLoganAI/` + `README-FIRST.txt` + `Start Hey Logan AI.cmd`). Checksums are
also in `_test\win-installer\SHA256SUMS-windows.txt`; `dist\` intentionally has
no Windows-only `SHA256SUMS.txt` (the Lead owns that file).

## Hands-free launcher (the user's request)

Verified in the installed tree and in the portable ZIP; `Launch.vbs` ships:

```
--app="http://127.0.0.1:8787/?token=..."   (test instance: :8790)
--window-size=1180,840
--user-data-dir="<install>\browser-profile"
--no-first-run
--no-default-browser-check
--autoplay-policy=no-user-gesture-required
```

and **does not** ship `--use-fake-ui-for-media-stream` (no "unsupported
command-line flag" warning bar).

On first launch it creates `<install>\browser-profile\Default\Preferences` with
a microphone permission exception scoped to
`http://127.0.0.1:8787`, `https://127.0.0.1:8443`, `https://localhost:8443`
(test instance: the 8790/8445 equivalents). That grant is what makes
`SpeechRecognition` start without a permission prompt; the autoplay flag makes
the "Logan here." reply audible without a click.

Live evidence:

- Launched exactly like Windows logon does, using the Run value's command line.
- Browser process command line (observed):
  `"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe" --app=http://127.0.0.1:8790/?token=... --window-size=1180,840 --user-data-dir="C:\Temp\hl-e2e\install-a\browser-profile" --no-first-run --no-default-browser-check --autoplay-policy=no-user-gesture-required`
- Seeded Preferences file (observed):
  `{"profile":{"content_settings":{"exceptions":{"media_stream_mic":{"http://127.0.0.1:8790,*":{"setting":1,...},...`
- `GET /api/session-info` (token header) returns
  `wake={"phrases":["hey logan","hi logan","hello logan","okay logan","hey logan ai"],"ack":"Logan here."}`
  and `speech={"lang":"en-US","wakeWindowMs":12000,"silenceMs":1500,"autoStart":true}`.
- Served page: HTML contains `Hey Logan` and the "Always listen" voice setting;
  `/app.js` contains `autoStartListening`.
- **Screenshot of the live app window: `evidence\app-window-1.1.0.png`** - the
  window shows "Listening for wake words…" and **no yellow warning bar**. It
  was captured from the real Edge window (PrintWindow, 1180x840).

## QA-fix verification (service-worker cache-bust + spoken routing)

Both fixes are in the installed app and in the portable ZIP:

- Installed `app\public\sw.js` contains `heyai-bridge-v1.1.0` (old v1.0.0 cache
  name is gone) and lists `/native-voice.js` in its assets - PASS.
- Installed `index.html` shows the v1.1.0 version label; `HELP.txt` names
  `HeyLoganAI-android-1.1.0.apk` - PASS.
- Served `GET /sw.js` returns the new cache name and `/native-voice.js` - PASS.
- `POST /api/command` with `{"text":"ask claude code to summarise the repo",
  "sync":true}` routes to `agentId: "claude-code"` (the client only sends the
  text after the wake word; this used to fall through to the Computer agent) -
  PASS.
- `POST /api/command` with `{"text":"hey logan ai open downloads","sync":true}`
  routes to `agentId: "computer"` - PASS.
- Router result checked directly through the installed app (no side effects):
  `ask claude code to summarise the repo` -> `claude-code`, task
  `summarise the repo`; `hey logan ai open downloads` -> `defaultWake: true`,
  task `open downloads`, `wakePhrase: "hey logan ai"` (longest phrase stripped
  as one) - PASS.

## Start at login

- Default ON in silent mode: the installer writes
  `HKCU\...\Run\HeyLoganAI` = `"wscript.exe" "<install>\Launch.vbs"` pointing at
  the new install dir - PASS.
- Start Menu has `Start at Login On.lnk` / `Start at Login Off.lnk`:
  - `Start at Login Off.cmd` exits 0 and removes the Run value - PASS.
  - `Start at Login On.cmd` exits 0 and re-creates it with the current install's
    `Launch.vbs` - PASS.
- Uninstall removes the Run value - PASS.

## Upgrade in place via the registered location (user's D:\ scenario)

Simulated safely (real ARP entry backed up first, `C:\Temp\hl-old` used as the
"old custom-folder install"):

- A 1.0.0-style tree was installed in `C:\Temp\hl-old` with a fake
  `app\data\config.json` token and certificate, and
  `HKCU\...\Uninstall\HeyLoganAI\InstallLocation` was set to it.
- Running the new Setup with **no `/D=`**: exit 0, installed into
  `C:\Temp\hl-old` (NOT into `%LOCALAPPDATA%\Programs\HeyLoganAI`), fake token
  preserved, `Launch.vbs` replaced with the v1.1.0 browser-profile version, Run
  value updated, ARP `InstallLocation` stayed the old tree, `DisplayVersion`
  became 1.1.0 - all PASS.
- Explicit `/D=` still wins over the registered location - PASS.

=> On the user's machine, running `HeyLoganAI-Setup-1.1.0-win-x64.exe` will
replace `D:\HeyLoganAI` in place and keep its `app\data` (token/certificates),
so no re-pairing is needed.

## Rest of the verified matrix (all PASS)

- Artifact integrity: Setup.exe copy to `C:\Temp` SHA-256-equal to `dist\`;
  version metadata 1.1.0; `asInvoker` manifest (no UAC, no admin request);
  portable ZIP layout, helpers present, no `app/data`, no `browser-profile`.
- Interactive Modern UI 2 wizard opens (`Hey Logan AI Setup` window) and can be
  cancelled without side effects.
- Silent install `/S /D=<scratch>`: exit 0 (8.5 s), all files incl.
  `Start at Login On/Off.cmd`, app package version 1.1.0, no `app\data`.
- ARP values: `Hey Logan AI` / `1.1.0` / publisher / DisplayIcon / D:\ style
  InstallLocation / Uninstall & QuietUninstall strings / EstimatedSize 91622 KB
  / NoModify+NoRepair / VersionMajor+Minor; HKCU app key InstallDir+Version.
- Start Menu group with 8 shortcuts (main, Start Console, Pairing, Stop Server,
  Allow through Firewall, Start at Login On, Start at Login Off, Uninstall) and
  Desktop shortcut; main shortcut = `wscript.exe` + `"<install>\Launch.vbs"` +
  `heylogan.ico`.
- Health `{"ok":true,"app":"Hey Logan AI","version":"1.1.0",...}` on the test
  port; first run created token + HTTPS certificate.
- `Pairing.cmd`: exit 0, token, 192.168.x.x LAN URL, QR code, "no camera
  scanner" footer (`pairing-output.txt`).
- `Stop.cmd`: exit 0, stops the test server, leaves the user's app untouched
  (`stop-output.txt`).
- Upgrade in place (same folder): exit 0, server stopped, program files
  replaced, token + marker + certificate + ARP + Run value kept.
- Data-loss guard: locked `app\data\config.json` makes the upgrade abort with
  exit code 1, token + certificate + program files intact, no `.hl-data-keep`
  residue; a retry after unlocking succeeds and keeps the token.
- Uninstall `/S` (keep data): exit 0, ARP/Run/Start Menu/Desktop removed,
  `Uninstall.exe` + `browser-profile` removed, only `app\data` remains, token
  and certificate survive.
- Reinstall over kept data + uninstall `/S /PURGEDATA`: exit 0, folder gone.
- `/S /NOAUTOSTART /D=`: files installed, no Run value, shortcuts created,
  uninstalls cleanly.
- Portable ZIP: extracts; Launch.vbs starts the server; browser-profile +
  seeded Preferences + new flags observed; `Stop.cmd` works; no registry or
  shortcut changes.
- Final machine: all test dirs gone, ports 8790/8445 free, no test node/browser
  processes, user's state restored exactly (see above).

## Caveat for the user (please read)

- **They have two OS-login autostart mechanisms.** v1.1.0 installs the
  `HKCU\...\Run\HeyLoganAI` entry pointing at the new `Launch.vbs`, and the
  previously installed **Edge PWA** also launches at OS login
  (`--app-run-on-os-login-mode=windowed`). That can open two app windows.
  Recommendation: remove the Edge PWA (Settings → Apps → Hey Logan AI → Edge
  entry, or Edge → Apps → Hey Logan AI → Uninstall) so only the v1.1.0 launcher
  starts at logon.
- The dedicated `browser-profile` folder is created next to the app and holds
  only the local microphone-permission grant; it is deleted on uninstall.
  The user's normal browser profile is untouched.
- Upgrade: run the 1.1.0 Setup **without** choosing a new folder; it will
  replace `D:\HeyLoganAI` in place (the app is stopped first) and keep the
  pairing token/certificates. Re-pairing is not needed.
- Unsigned binaries: SmartScreen may warn ("More info → Run anyway").
- Windows 10/11 x64 only; per-user install (no UAC); firewall not modified
  (use "Allow through Firewall" once); ports 8787/8443 are fixed defaults.

## How to reproduce

```powershell
windows\installer\build.cmd          # rebuild both artifacts (default 1.1.0)

New-Item -ItemType Directory C:\Temp\hl-test -Force | Out-Null
Copy-Item _test\win-installer\run-e2e.ps1 C:\Temp\hl-test\ -Force
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Temp\hl-test\run-e2e.ps1
```

The harness backs up and restores the real installation state, writes
`e2e-run.log` / `e2e-summary.json` / screenshots next to itself, and leaves the
machine clean.
