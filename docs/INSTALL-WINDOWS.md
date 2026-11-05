# Installing Hey Logan AI on Windows

Hey Logan AI runs a small server on your PC and opens a voice assistant in its
own window. It carries its own private Node.js runtime — nothing else has to be
installed.

**What is new in 1.1.0:** it listens for its wake word by itself, so there is no
“Start listening” button to press — just say **“Hey Logan”**, hear the answer,
then speak your command. And it starts with Windows and is already listening.

## Requirements

- 64-bit Windows 10 or Windows 11 (x64).
- About 250 MB free disk space.
- Microsoft Edge (preinstalled) or Google Chrome for the app window.
- A microphone (built-in or USB) for voice control.

## 1. Run the installer

Run **`HeyLoganAI-Setup-1.1.0-win-x64.exe`**.

Windows SmartScreen may show *“Windows protected your PC”* because the installer
is not code-signed: click **More info → Run anyway**.

The wizard:

1. Suggests the install folder. If Hey Logan AI is already installed, it reuses
   that folder (so an update **replaces the existing copy** instead of creating a
   second one); otherwise it defaults to
   `%LOCALAPPDATA%\Programs\HeyLoganAI`. No administrator rights are needed.
2. Copies the app, the private Node.js runtime, the launcher and helpers.
3. Creates a Start Menu group **Hey Logan AI** and a Desktop shortcut.
4. Registers **Hey Logan AI** in *Settings → Apps*.
5. Offers **start with Windows** (on by default — this is what makes it “just
   work” after you log in).
6. Offers to start Hey Logan AI when you finish.

### Silent / unattended

```
HeyLoganAI-Setup-1.1.0-win-x64.exe /S
```

No wizard, no prompts, the app is not launched; start-with-Windows stays on
(add `/NOAUTOSTART` to skip it). Custom folder:

```
HeyLoganAI-Setup-1.1.0-win-x64.exe /S /NOAUTOSTART /D=C:\Apps\HeyLoganAI
```

(`/D=` must be last and unquoted.) Uninstaller: `/S` (keeps `app\data`),
`/PURGEDATA` (also delete settings/token), `/KEEPDATA`.

## 2. First start — just talk to it

Open **Hey Logan AI** from the Start Menu (or wait for it at your next login).

The server starts in the background with **no console window**, the app opens in
a chromeless window, and **it starts listening immediately**.

> Say: **“Hey Logan.”**
> It answers out loud: **“Logan here.”**
> Then say: **“Find my budget PDF in Downloads.”**

That is the whole flow: wake word → spoken answer → your command. No clicking.

![The app window](images/app-window.png)

You can also say a wake word and the command in one breath
(*“Hey Logan, find my budget PDF in Downloads”*), talk to a specific agent
(*“Hey Computer, open Downloads”*, *“Hey Claude Code, summarise the repo”*), or
type anything in the bottom bar.

On first start it creates your settings, a private access token and a local
HTTPS certificate in the install folder (see *Where things live* below).

## 3. Hands-free and auto-start

- **Wake word:** “Hey Logan” (also “Hi Logan”, “Hello Logan”, “Okay Logan”).
  The assistant answers, then routes the command — name an agent inside the
  sentence (*“Hey Logan, ask Claude Code to fix the tests”*) to send it there,
  otherwise your default agent (Computer) handles it.
- **No button:** the app starts listening when it opens. The launcher gives the
  app its own private browser profile with the microphone already allowed, so
  there is no permission popup and no click.
- **Speaks without a click:** the launcher enables audio playback for the app
  window, so the “Logan here.” answer is audible even right after login.
- **Turn it off/on:** Settings (gear icon) → **Voice** → *Always listen for
  “Hey Logan”*. You can also tap **Stop listening** for the current session, or
  **Hold to talk** for a one-off command.
- **Start with Windows:** the installer adds the usual per-user start-up entry.
  Start Menu → **Hey Logan AI → Start at Login On** / **Off** toggles it later.

## 4. Pair your phone

Start Menu → **Hey Logan AI → Pairing**. A console window shows your access
token, the phone address, pairing links and a QR code.

If the phone cannot connect:

1. Same Wi-Fi network on both devices (not the guest network).
2. Start Menu → **Hey Logan AI → Allow through Firewall** (approve the Windows
   prompt), or add a rule for
   `<install folder>\runtime\node.exe` on **Private**
   networks. The installer does not change firewall settings itself.
3. The network profile must be **Private** (Settings → Network → Wi-Fi →
   Network profile).

## The Start Menu shortcuts

| Shortcut | What it does |
|---|---|
| **Hey Logan AI** | Starts the server (hidden) and opens the app window |
| **Start Console** | Starts the server with a visible console (log, URLs, errors) |
| **Pairing** | Shows the access token, phone URL, pairing links and QR code |
| **Stop Server** | Stops the background server |
| **Start at Login On** | Starts Hey Logan AI automatically when you log in |
| **Start at Login Off** | Stops it starting automatically |
| **Allow through Firewall** | Adds the Private-network firewall rule |
| **Uninstall** | Removes Hey Logan AI |

## Portable build

`HeyLoganAI-Portable-1.1.0-win-x64.zip` is the same app without an installer:

1. Extract anywhere (e.g. `D:\Tools\HeyLoganAI`).
2. Run **`Launch.vbs`** — it starts the server, allows the microphone for its own
   private profile, and opens the app window listening for “Hey Logan”.
3. No registry entries or shortcuts are created; settings live in `app\data`
   inside the extracted folder, so deleting the folder removes everything.
   Use **`Start at Login On.cmd`** in the same folder if you want it at login.

## Updating

Run a newer installer over the old one. It detects the existing installation
(including a custom folder) and **keeps `app\data`**, so your token, certificate
and settings survive and the phone stays paired.

## Uninstalling

*Settings → Apps → Installed apps → Hey Logan AI → Uninstall*, or the
**Uninstall** shortcut, or `Uninstall.exe` in the install folder.

The uninstaller stops the server, removes the shortcuts, the *Apps* entry, the
start-with-Windows value and the private browser profile, then asks whether to
keep your settings (`app\data`). Answer **No** to remove everything. (A firewall
rule added with **Allow through Firewall** is left alone; delete the
`Hey Logan AI` rule in Windows Firewall settings if you want it gone.)

Silent uninstall: `Uninstall.exe /S` keeps `app\data`; `Uninstall.exe /S
/PURGEDATA` removes everything. (The folder disappears a few seconds after the
uninstaller exits.)

## Troubleshooting

| Symptom | Fix |
|---|---|
| SmartScreen blocks the installer | **More info → Run anyway** (the exe is not code-signed) |
| The app window does not open | Start Menu → **Start Console** and read the log; check that Edge or Chrome is installed |
| It does not react to “Hey Logan” | Check the microphone (Windows Settings → Privacy → Microphone → let desktop apps listen). Click the orb once: the status line tells you whether it is listening. Settings → Voice → *Always listen for “Hey Logan”* must be on |
| No spoken reply | Check the Windows volume/output device. The launcher enables playback for the app window; if you started the app from a plain browser tab instead, click the page once and it will speak |
| A yellow “unsupported command-line flag” bar appears | It should not — the launcher deliberately avoids the microphone pre-grant flag. Reinstall 1.1.0 (or delete `<install>\browser-profile` so the profile is recreated) |
| Microphone permission popup appears once | Allow it; this only happens on a machine where the seeded browser profile was ignored. After allowing, hands-free works from then on |
| Two Hey Logan AI windows at login | You probably also installed the page as an Edge app (“Install this site as an app”) with *launch on OS login*. Remove that Edge app (or turn off its OS-login option) and keep the installer’s shortcut |
| “Port already in use” (8787 / 8443) | Run **Stop Server**, then start again; or change `server.httpPort` / `server.httpsPort` in `app\data\config.json` |
| Phone cannot connect | Same Wi-Fi? Private profile? Firewall rule? Run **Pairing** again — the address changes when the PC gets a new IP |
| Pairing shows an address the phone cannot reach | Extra network adapters (VPN/Clash/WSL) exist. Pairing lists the normal LAN address first; force one with `set HEYLOGAN_LAN_ADDR=192.168.x.x` then **Pairing** |
| Antivirus flags the installer | It is an unsigned NSIS installer that bundles Node.js; allow it, or use the portable ZIP |

## Where things live

| Path | Contents |
|---|---|
| `%LOCALAPPDATA%\Programs\HeyLoganAI\` | program files (or the folder you chose) |
| `...\app\` | server, web UI, `node_modules` |
| `...\app\data\` | your settings, access token, certificates (keep private) |
| `...\runtime\node.exe` | private Node.js 22 runtime |
| `...\browser-profile\` | private browser profile for the app window (mic permission) |
| `...\Launch.vbs` | hidden launcher used by the shortcuts and at login |
