# Hey Logan AI for Android

A native Android companion app for **Hey Logan AI** (the local Node.js voice
bridge, which the PWA itself calls "Hey AI Bridge"). The phone talks to the
bridge running on your Windows PC over your home Wi-Fi: wake-word voice input,
spoken replies, agent results and the full PWA UI, inside a dark native shell.

- Package: `ai.heylogan.app` - Label: **Hey Logan AI** - Version: 1.0.0
- minSdk 26 (Android 8.0), targetSdk 35 (Android 15)
- Release APK: `..\dist\HeyLoganAI-android-1.0.0.apk` (signed)

---

## What it does

The app is a single-activity WebView client:

1. **Pairing screen** (`assets/connect.html`, first run): enter the PC address
   and access token printed by the PC app's **Pairing** shortcut, or paste the whole
   pairing link (`https://192.168.x.x:8443?token=XXXX-XXXX-XXXX`). The address
   and token are saved in `SharedPreferences`, so pairing is one-time.
2. **The WebView** then opens `https://<pc>:8443/?token=...` (or
   `http://<pc>:8787/?token=...` if that is what was paired) and the normal PWA
   runs: orb, wake words, agents, conversation log, settings.
3. **Self-signed certificate**: the PC generates its own certificate. The app
   shows a one-time explanation when the certificate is first seen and, only
   after you confirm, remembers that decision for that one PC host. Certificates
   from any other host are refused. If you installed the PC certificate as a
   user CA on the phone, the network security config also trusts user CAs.
4. **Microphone**: the app requests the Android RECORD_AUDIO runtime permission
   and grants `RESOURCE_AUDIO_CAPTURE` only to the paired PC's origin.
5. **Native speech bridge**: Android System WebView has no Web Speech API, so
   the app injects `window.HeyNativeVoice` (Java: `VoiceBridge`) before the page
   loads. The page-side shim (`app/public/native-voice.js`, served by the PC
   bridge) recreates `SpeechRecognition` and `speechSynthesis` on top of the
   phone's `SpeechRecognizer` and `TextToSpeech`. The bridge keeps a continuous
   recognition session alive (restarting after each final result / silence) so
   wake words keep working.
6. **Navigation**: Android back walks the WebView history, then exits. The
   top-bar `...` menu has **Reload**, **Change PC** and **About**. If the PC is
   unreachable, an in-app panel offers **Retry** and **Change PC** instead of a
   WebView error page.

The app is **framework-only Java** (`android.*`, `java.*`, `org.json` only): no
AndroidX, AppCompat, Material or zxing. That keeps the APK small (0.22 MB) and
lets it be built with the raw SDK tools when Gradle is unavailable.

---

## Install the APK on a phone

1. Copy `dist\HeyLoganAI-android-1.0.0.apk` to the phone (USB, email, cloud).
2. On the phone: allow installing from this source, then tap the APK.
3. Start the PC app (Start Menu -> Hey Logan AI) and keep it running; `Start Console` shows the log.
4. Open **Hey Logan AI**, paste the pairing link from the console (or type the
   address and token), tap **Connect**.
5. Confirm the self-signed certificate prompt, then allow the microphone.
6. In the app, tap the orb / **Start listening**, then say e.g.
   *"Hey Computer, find my tax PDF in Downloads."*

The phone and PC must be on the same Wi-Fi network, and Windows Firewall must
allow Node.js on **Private** networks.

---

## Build the release APK

### Option A - raw SDK tools (this machine; no Gradle needed)

Gradle cannot start on the build machine used for this release (its native
helper library fails to load), so the shipped APK was produced by the pipeline
that drives the SDK tools directly: `aapt2 compile` -> `aapt2 link` ->
`javac` -> `d8` -> zip -> `zipalign` -> `apksigner`. The script is
`tools/build-apk-manual.ps1`.

```powershell
$rel = 'C:\Users\s2121270\Downloads\Hey-Logan-AI-Release'
$env:JAVA_HOME    = "$rel\_toolchain\jdk"      # JDK 17
$env:ANDROID_HOME = "$rel\_toolchain\sdk"      # platform 35 + build-tools 35.0.0
powershell -NoProfile -ExecutionPolicy Bypass `
  -File "$rel\android\tools\build-apk-manual.ps1" -StorePass '<read from release-keystore/keystore-info.txt>'
```

Output: `dist\HeyLoganAI-android-1.0.0.apk` (signed, verified), plus the
`apksigner verify` and `aapt2 dump badging` evidence in the console. Optional
flags: `-Out <path>`, `-VersionName`, `-VersionCode`, `-DebugBuild`.

### Option B - Android Studio / Gradle (normal machine)

The project is a normal Gradle layout (AGP 8.7.3, Gradle 8.9, JDK 17,
compileSdk 35, framework-only dependencies).

1. Open the `android\` folder in Android Studio (Giraffe/Koala or newer with
   AGP 8.7 support).
2. **Important:** `AndroidManifest.xml` contains
   `package="ai.heylogan.app"` because the raw-tools pipeline needs it. AGP 8
   uses `namespace` (already set in `app/build.gradle`) and rejects the
   attribute, so remove that one line from `AndroidManifest.xml` before a
   Gradle sync. (The CI workflow does this with `sed`.)
3. Build: `gradle :app:assembleRelease` (or open the Gradle tool window). If
   there is no wrapper on the machine, `gradle wrapper --gradle-version 8.9`
   creates `gradlew`/`gradlew.bat` first.
4. Release signing: add a `signingConfigs.release` block to `app/build.gradle`
   pointing at `release-keystore/heylogan-release.jks` (alias `heylogan`) and
   the password in `release-keystore/keystore-info.txt`, then reference it from
   `buildTypes.release`.

A GitHub Actions workflow that runs the Gradle debug build (and uploads the
debug APK as an artifact) is in `.github/workflows/android-build.yml`.

---

## Signing and re-signing

| Item | Value |
|---|---|
| Keystore | `release-keystore/heylogan-release.jks` (PKCS12, not in the source zip) |
| Key alias | `heylogan` |
| Store / key password | see `release-keystore/keystore-info.txt` (not shipped in this zip) |
| Cert SHA-256 | `6C:82:67:92:33:C2:AB:DF:78:0C:FC:2C:A8:9B:06:68:49:07:D0:FF:54:5D:27:A3:E1:26:83:7F:93:18:48:0C` |

Details are in `release-keystore/keystore-info.txt`. Keep the keystore and that
file private: Android identifies updates by certificate. The keystore is
deliberately **excluded from `dist\HeyLoganAI-Android-Project-1.0.0.zip`** - it
stays only in this local source tree.

Verify the shipped APK:

```powershell
& "$rel\_toolchain\sdk\build-tools\35.0.0\apksigner.bat" verify --print-certs `
  "$rel\dist\HeyLoganAI-android-1.0.0.apk"
& "$rel\_toolchain\sdk\build-tools\35.0.0\aapt2.exe" dump badging `
  "$rel\dist\HeyLoganAI-android-1.0.0.apk"
```

Re-sign a rebuilt (aligned) APK manually:

```powershell
& "$rel\_toolchain\sdk\build-tools\35.0.0\apksigner.bat" sign `
  --ks android\release-keystore\heylogan-release.jks --ks-key-alias heylogan `
  --ks-pass pass:<password> --key-pass pass:<password> `
  --out dist\HeyLoganAI-android-1.0.0.apk android\_manual-build\aligned.apk
```

---

## Project layout

```
android/
  app/
    build.gradle                 AGP module (framework-only, empty deps)
    proguard-rules.pro
    src/main/
      AndroidManifest.xml        package/minSdk/targetSdk, permissions, queries
      java/ai/heylogan/app/
        MainActivity.java        WebView shell, pairing, SSL trust, mic, menu
        VoiceBridge.java         SpeechRecognizer + TextToSpeech <-> page bridge
      assets/connect.html        dark pairing screen (address/token/paste link)
      res/
        values/strings.xml        app label
        values/colors.xml         palette + adaptive-icon background
        xml/network_security_config.xml
        mipmap-*/                 launcher icons (legacy + adaptive foreground)
        mipmap-anydpi-v26/        adaptive icon descriptors
  tools/build-apk-manual.ps1     raw SDK tools build/sign/verify pipeline
  release-keystore/              signing material (NOT in the source zip)
  settings.gradle / build.gradle / gradle.properties
  .github/workflows/android-build.yml
  README.md / BUILD-NOTES.md
```

The page-side speech shim (`app/public/native-voice.js`) and the PWA itself
live in the PC product folder (`app\`), not in this Android project; the PC
bridge serves them to the WebView.

---

## Limitations and known risks

- **No QR scanner.** The APK has no zxing dependency (framework-only build), so
  pairing is by pasting the pairing link or typing address + token. The PC
  console still prints the QR code; scanning it with a generic QR app opens the
  URL in a browser, not in this app.
- **Pairing needs the console text.** The pairing link/token must be copied from
  the PC console; it is not discoverable automatically.
- **Self-signed certificate prompt** only applies to the paired host; if the PC's
  IP changes, pair again (Change PC) and confirm the new certificate.
- **Voice needs a speech service on the phone.** `sttAvailable()` is false when
  no Android `RecognitionService` is installed (e.g. no Google app); the PWA
  then falls back to typed commands. TTS uses the phone's installed engine and
  exposes a single "Device voice" to the PWA.
- **Wake words** rely on continuous `SpeechRecognizer` sessions restarted by the
  native bridge; some engines only deliver partial results and some stop after
  long silence - the bridge restarts them and backs off on network errors.
- **Battery/data**: continuous listening keeps the microphone active; stop with
  the orb when done. Recognition may be processed by the phone's speech service
  provider (usually Google), same as Chrome.
- **No background operation**: the WebView client only works while the app is in
  the foreground. No push, no sync, no telemetry, no cloud backend.
- The app was built and signed on this machine but not installed on a physical
  device during the build; see `BUILD-NOTES.md` for the verification that was
  actually run (signature, manifest/badging, APK contents).

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Bridge on your PC did not answer" | Is the Hey Logan AI app running on the PC? Same Wi-Fi? Did you run **Allow through Firewall** once? |
| Certificate prompt every time | Confirm "Continue" once for that host; the app remembers it. Pairing again after an IP change asks again. |
| "Microphone permission was denied" | Android Settings -> Apps -> Hey Logan AI -> Permissions -> Microphone -> Allow, then reopen the app. |
| Voice orb does nothing | The phone needs a speech recognition service. Install/enable Google from the Play Store. Typed commands still work. |
| No spoken replies | Check the phone's TTS engine (Settings -> System -> Languages & input -> Text-to-speech), media volume, and the PWA's "Speak replies on this device" setting. |
| Page loads but wake word does not trigger | Make sure the PC's `app\public\native-voice.js` is present (it ships with the PWA); older copies of the PC app do not have the native bridge. |
| Typed commands work, voice does not | Microphone permission or speech service missing; check both settings above. |
| Wrong PC / token changed | `...` menu -> **Change PC**, then pair again. |
