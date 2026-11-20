# Hey Logan AI 1.2.0 — built-in free AI chat (no API key)

> **Status: source updated, binaries not rebuilt yet.** The app code in `app/`
> and `windows/payload/` is 1.2.0. The installer, portable zip and APK must be
> rebuilt on Windows with `windows\installer\build-all.ps1` (default version is
> now 1.2.0) and attached to a new GitHub Release. The Android APK does not
> need a rebuild: it connects to the PC server, which is where 1.2.0 changes live.

- **AI Chat agent, works out of the box.** Ask *“Hey Logan, what’s the capital
  of France?”* or say *“Hey Chat …”* / *“Hey GPT …”*. No account and no API key
  needed: it uses Pollinations.AI's free public endpoint, or free open-source
  models on your own PC through **Ollama** or **LM Studio** when they are running.
- **Optional keys, still supported.** Free-tier keys for Groq, Google Gemini,
  OpenRouter (`:free` models), Cerebras and Mistral, and paid keys for OpenAI,
  DeepSeek or any OpenAI-compatible URL. Providers are tried in order and fall
  back automatically when one is busy. Keys stay in `data\config.json` on your
  PC (or environment variables) and never reach the phone or browser.
- **Smart routing.** “Hey Logan” + a general question goes to AI Chat; file,
  app and PC commands still go to the Computer agent (`ui.smartRouting`).
- **Fixes:** API errors no longer use a dead `200 : 200` branch, screenshot 404s
  return properly, the “which agent?” prompt lists the agents you actually
  have, small UI clean-ups. The CLI agents (Claude Code, Codex, DeepSeek,
  Gemini, Workbuddy) work exactly as before.

Honest limits: Pollinations' keyless tier is best-effort and rate-limited per IP
(about one request every 30 seconds). For heavier use, install Ollama or add a
free key.

---

# Hey Logan AI 1.1.0 — hands-free “Hey Logan” + starts with Windows

This release turns Hey Logan AI into a hands-free assistant:

- **No “Start listening” button.** The app starts listening when it opens —
  call **“Hey Logan”**, hear *“Logan here.”*, then say what you want. It works
  from the moment you log in to Windows.
- **Starts with Windows** (default on, toggle any time with the
  **Start at Login On/Off** shortcuts).
- Everything else from 1.0.0 still works the same way (voice commands to your
  PC, file search, apps, screenshots, AI CLI agents, phone pairing).

## Download

| File | Size | What it is |
|---|---:|---|
| `HeyLoganAI-Setup-1.1.0-win-x64.exe` | 23,613,115 B | Windows installer (per-user, no admin, self-contained) |
| `HeyLoganAI-Portable-1.1.0-win-x64.zip` | 35,114,308 B | Portable Windows build (unzip, run `Launch.vbs`) |
| `HeyLoganAI-android-1.1.0.apk` | 226,868 B | Signed Android companion app (Android 8.0+) |
| `HeyLoganAI-Android-Project-1.1.0.zip` | 236,017 B | Android Studio project source |

SHA-256 checksums: [`dist/SHA256SUMS.txt`](dist/SHA256SUMS.txt).

## Updating from 1.0.0

Run the new installer. It detects your existing installation (including a custom
folder such as `D:\HeyLoganAI`) and upgrades it **in place** — your access token,
settings and phone pairing survive. Nothing to re-pair.

If you also installed the web page as an Edge app (“Install this site as an
app”) with *launch on OS login*, turn that off (or remove the Edge app): 1.1.0
starts itself, so otherwise you get two windows.

## How the hands-free flow works

1. The launcher starts the local server (hidden) and opens the app in its own
   window, using a **private browser profile** that has the microphone allowed
   for the app’s address — so there is no permission popup and no click.
2. It enables audio playback for that window, so the spoken answer is audible
   even straight after login.
3. The app listens continuously for **“Hey Logan”** (also “Hi Logan”, “Hello
   Logan”, “Okay Logan”).
4. On the wake word it answers *“Logan here.”*, then takes your command:
   *“find my budget PDF in Downloads”*, *“open Downloads”*, *“ask Claude Code to
   summarise the repo”* (a named agent wins; otherwise the Computer agent
   handles it).
5. Follow-ups work right after a reply (*“open it”*), and the phone app pairs
   with the same assistant.

## Verification

Independent QA verdict and evidence: [`docs/VERIFICATION.md`](docs/VERIFICATION.md).

- 84/84 app unit tests (wake-word routing, client wake matching, config).
- Windows installer end-to-end suite: install, shortcuts/registry, launch via
  the exact start-at-login command line, browser flags + seeded microphone
  permission, live `/api/health` and `/api/session-info` (wake word + autoStart),
  wake-word routing through `/api/command`, upgrade-in-place, keep-data and purge
  uninstall, custom folder, portable build.
- Android APK: signed with APK Signature Scheme v2+v3, same signing certificate
  as 1.0.0 (so it updates in place), versionCode 2 / versionName 1.1.0.

## Known limitations

- The installer is unsigned → SmartScreen shows “More info → Run anyway”.
- The Android APK is sideloaded (not on Google Play). Its runtime behaviour on a
  real phone is verified by compilation, signatures and static analysis — no
  device was available in the build environment.
- Microphone permission: the launcher pre-authorises it inside the app’s private
  browser profile. If a browser ignores that on your machine, you will see the
  normal “Allow microphone” popup **once**; after allowing, hands-free works.
- The PC must be running for the phone app to work; firewall rule may need
  **Allow through Firewall** once (needs the admin prompt).
- The release signing keystore is not in this repository — keep your local copy.

## Building

See [`README.md`](README.md) → Rebuilding. Windows: NSIS +
`windows/installer/build-setup.ps1` (run `fetch-node.ps1` first — the Node
runtime is not stored in git). Android: Android Studio/Gradle, or
`android/tools/build-apk-manual.ps1` (the pipeline used for this release).
