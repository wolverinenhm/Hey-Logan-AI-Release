# Hey Logan AI 1.0.0 — Windows installer + signed Android APK

Built from [wolverinenhm/Hey-Logan-AI](https://github.com/wolverinenhm/Hey-Logan-AI).

## Download

| File | Size | What it is |
|---|---:|---|
| `HeyLoganAI-Setup-1.0.0-win-x64.exe` | 23,607,380 B | Windows installer (per-user, no admin, bundled Node.js 22) |
| `HeyLoganAI-Portable-1.0.0-win-x64.zip` | 35,108,868 B | Portable Windows build (unzip, run `Launch.vbs`) |
| `HeyLoganAI-android-1.0.0.apk` | 226,868 B | Signed Android app (Android 8.0+) |
| `HeyLoganAI-Android-Project-1.0.0.zip` | 232,691 B | Android Studio project source |

SHA-256 checksums: [`dist/SHA256SUMS.txt`](dist/SHA256SUMS.txt).

## Windows

Run the installer. SmartScreen will warn because it is not code-signed → **More info → Run anyway**.
It installs to `%LOCALAPPDATA%\Programs\HeyLoganAI` (no admin), adds Start Menu + Desktop
shortcuts and an *Apps* entry. Start it from the **Hey Logan AI** shortcut; pair your phone with
**Start Menu → Hey Logan AI → Pairing**.

Silent switches: `/S`, `/NOAUTOSTART`, `/D=<dir>`; uninstaller: `/S`, `/PURGEDATA`, `/KEEPDATA`.

## Android

Copy `HeyLoganAI-android-1.0.0.apk` to the phone and tap it (allow *Install unknown apps*), or
`adb install -r …`. Open the app, enter the address + token from the PC's **Pairing** window
(or paste the pairing link), accept the certificate explanation and allow the microphone.

The phone app is a companion: the assistant runs on the PC, both devices on the same Wi-Fi.
It contains a native speech bridge, so wake words and spoken replies work inside the app.

## Verification

Independent QA verdict: **READY** — see [`docs/VERIFICATION.md`](docs/VERIFICATION.md).

- Windows clean-room E2E: 158 checks, 0 failures (install, shortcuts/registry, launch, real
  command execution, pairing, upgrade keeping token+certs, locked-data abort, uninstall
  keep/purge, custom dir, portable run).
- Android: signed with APK Signature Scheme v2+v3 (1 signer); `apksigner verify` passes;
  shipped `classes.dex` is the compiled output of the shipped sources.
- One bug found and fixed during verification (portable `Stop.cmd` could not find a
  console-launched server); re-tested on the final ZIP.

## Known limitations

- Installer is unsigned (SmartScreen warning; code signing needs a paid certificate).
- The APK is sideloaded, not published on Google Play.
- The Android app's runtime behaviour on a real phone was not exercised here (no device):
  it is verified by compilation, signatures and static review.
- Windows Firewall is not modified by the installer; use **Allow through Firewall** once
  (needs the admin prompt) if your phone cannot connect.
- The release signing keystore is **not** in this repository; keep your local copy safe.

## Building

See [`README.md`](README.md) → Rebuilding. Windows installer: NSIS + `windows/installer/build-setup.ps1`.
Android: Android Studio/Gradle, or the raw SDK-tools pipeline in `android/tools/build-apk-manual.ps1`.
