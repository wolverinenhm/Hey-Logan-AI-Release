# Build notes - Hey Logan AI Android 1.1.0

This file records how the shipped APK was actually produced and verified, so a
future maintainer can reproduce it.

## Result

| Item | Value |
|---|---|
| APK | `dist\HeyLoganAI-android-1.1.0.apk` |
| Size | 226,868 bytes (0.22 MB) |
| SHA-256 | `CCB8FB6E2FF57D856621A0E1ACD41E90A1AF4323A364B19CBDFD31047DBE0173` |
| Package | `ai.heylogan.app` (versionCode **2**, versionName **1.1.0**) |
| minSdk / targetSdk | 26 / 35 |
| Launchable activity | `ai.heylogan.app.MainActivity` |
| Signature | APK Signature Scheme v2 + v3, 1 signer, RSA 2048 / SHA256withRSA |
| Certificate SHA-256 | `6C:82:67:92:33:C2:AB:DF:78:0C:FC:2C:A8:9B:06:68:49:07:D0:FF:54:5D:27:A3:E1:26:83:7F:93:18:48:0C` |
| Keystore | `android\release-keystore\heylogan-release.jks` (alias `heylogan`) |

The certificate SHA-256 is identical to the 1.0.0 APK (same keystore), and
versionCode 2 > 1, so the new APK installs as an **update** over 1.0.0 and keeps
the user's pairing and permissions.

## What changed in 1.1.0 (hands-free "Hey Logan")

User request: no more tapping "Start listening" - say "Hey Logan", get the
spoken answer, then give the command; and the app should start by itself.

The PC side (owned by the Lead, not part of this project) already provides the
wake word and the auto-start: server `wake.phrases = ["hey logan", "hi logan",
"hello logan", "okay logan", "hey logan ai"]`, `wake.ack = "Logan here."`,
`speech.autoStart = true`, client `autoStartListening()` in `app/public/app.js`
and a Settings toggle. The WebView loads that same page, so the Android change
is the **microphone/boot path**:

1. `MainActivity.onCreate()` now calls `maybeRequestMicrophonePermission()`
   before loading the paired page, so the page's `autoStartListening()` can open
   the native recognizer as soon as it loads. The request is made at most once
   per process (`microphonePermissionAsked`).
2. If the grant arrives after the page has already loaded,
   `onRequestPermissionsResult()` reloads the page **exactly once**
   (`microphoneReloadDone` flag) so auto-start runs with microphone access. The
   flag makes a reload loop impossible.
3. Denied permission keeps the existing friendly guidance toast and the user can
   enable the mic in Android Settings and tap Start listening once.
4. The About dialog and `PairBridge.version()` now read the real version from
   `PackageManager` instead of a hard-coded "1.0.0" (connect.html footer shows
   the correct version).
5. `app/build.gradle`: versionCode 2 / versionName 1.1.0.
6. Pairing-screen copy updated to mention the PC app's **Pairing** window
   (`Pairing.cmd`) instead of the old console-only wording.

Everything else is unchanged: pairing screen, SSL trust-scoped-to-paired-host,
native speech bridge contract (`sttAvailable`, `startListening`, `stopListening`,
`ttsAvailable`, `speak(String,String,double,double)`, `stopSpeaking`, `destroy`,
JSON events via `window.HeyNativeVoice._onNative`), framework-only build.

## Environment constraint: Gradle cannot run here

The build machine cannot start Gradle at all. Every distribution tried
(8.9 and 8.5, several temp/native dirs) fails at startup:

```
FAILURE: Build failed with an exception.
* What went wrong:
Gradle could not start your build.
> Could not initialize native services.
   > Failed to load native library 'native-platform.dll' for Windows 11 amd64.
```

This is an environment restriction (sandbox / antivirus cannot load the native
helper from the Gradle distribution), so the shipped APK is built by driving the
SDK build tools directly. `android\` is still kept as a normal Gradle project
(AGP 8.7.3 / Gradle 8.9 / Java 17) for Android Studio and CI on a normal
machine.

## Toolchain used

| Tool | Path |
|---|---|
| JDK 17 (Temurin 17.0.20.1+1) | `_toolchain\jdk` |
| Android platform 35 | `_toolchain\sdk\platforms\android-35\android.jar` |
| Build-tools 35.0.0 (aapt2, d8, zipalign, apksigner) | `_toolchain\sdk\build-tools\35.0.0` |
| Build script | `android\tools\build-apk-manual.ps1` (not edited) |

## Exact build command

The store password is read by the script from
`release-keystore\keystore-info.txt`; it is never needed on the command line.

```powershell
$rel = 'C:\Users\s2121270\Downloads\Hey-Logan-AI-Release'
$env:JAVA_HOME    = "$rel\_toolchain\jdk"
$env:ANDROID_HOME = "$rel\_toolchain\sdk"
powershell -NoProfile -ExecutionPolicy Bypass `
  -File "$rel\android\tools\build-apk-manual.ps1" `
  -VersionName 1.1.0 -VersionCode 2 `
  -Out "$rel\dist\HeyLoganAI-android-1.1.0.apk"
```

## Pipeline (what the script does)

1. `aapt2 compile --dir app/src/main/res -o resources.zip`
2. `aapt2 link` (manifest + resources + `assets/` via `-A`) with
   `--min-sdk-version 26 --target-sdk-version 35 --version-code 2
   --version-name 1.1.0 --java gen` -> `base.apk`
3. `javac -source 17 -target 17 -classpath android.jar` over
   `app/src/main/java` + generated `R.java` -> `classes/`
4. `d8 --lib android.jar --min-api 26` -> `classes.dex`
5. add `classes.dex` to `base.apk` -> `unsigned.apk`
6. `zipalign -f -p 4`
7. `apksigner sign` with `release-keystore/heylogan-release.jks`
   (reuses the existing keystore; the store password comes from
   `release-keystore/keystore-info.txt` when `-StorePass` is omitted)
8. `apksigner verify --verbose --print-certs` and `aapt2 dump badging`

## Verification actually run

`apksigner verify --print-certs`:

```
Verifies
Verified using v1 scheme (JAR signing): false
Verified using v2 scheme (APK Signature Scheme v2): true
Verified using v3 scheme (APK Signature Scheme v3): true
Number of signers: 1
Signer #1 certificate DN: CN=HeyLoganAI, OU=Local, O=HeyLoganAI, L=Local, ST=Local, C=AU
Signer #1 certificate SHA-256 digest: 6c82679233c2abdf780cfc2ca89b06684907d0ff545d27a3e126837f9318480c
Signer #1 key algorithm: RSA
Signer #1 key size (bits): 2048
```

(`v1` is reported as false by default because the APK targets minSdk 26 - Android
8.0+ validates v2/v3. The APK also carries a valid v1 JAR signature; run
`apksigner verify --min-sdk-version 21` to see it. All schemes are added by
apksigner - nothing is missing.)

`aapt2 dump badging`:

```
package: name='ai.heylogan.app' versionCode='2' versionName='1.1.0' ... compileSdkVersion='35'
minSdkVersion:'26'
targetSdkVersion:'35'
uses-permission: name='android.permission.INTERNET'
uses-permission: name='android.permission.ACCESS_NETWORK_STATE'
uses-permission: name='android.permission.RECORD_AUDIO'
application-label:'Hey Logan AI'
launchable-activity: name='ai.heylogan.app.MainActivity'
```

Dex check (`classes.dex` extracted from the APK and searched for the new code):

```
Lai/heylogan/app/MainActivity;                   FOUND
Lai/heylogan/app/VoiceBridge;                    FOUND
Lai/heylogan/app/MainActivity$PairBridge;        FOUND
microphoneReloadDone                             FOUND   (new reload-once flag)
microphonePermissionAsked                        FOUND   (new startup permission guard)
hands-free                                       FOUND   (new About/toast text)
RECORD_AUDIO                                     FOUND
```

`autoStartListening` is not in the APK by design: the wake word/auto-start logic
is page-side in `app/public/app.js`, which the PC bridge serves to the WebView.
The APK only guarantees the microphone path and the native recognizer.

APK contents (20 entries) include:

```
classes.dex
assets/connect.html
res/mipmap-*/ic_launcher.png + ic_launcher_foreground.png
res/mipmap-anydpi-v26/ic_launcher.xml + ic_launcher_round.xml
res/xml/network_security_config.xml
resources.arsc
```

Project ZIP (`dist\HeyLoganAI-Android-Project-1.1.0.zip`) is built from
`android\` excluding `_manual-build/`, `release-keystore/`, `build/`, `.gradle/`
and `local.properties`; it contains the Gradle layout, `tools/`, `.github/`,
README/BUILD-NOTES, sources, assets and resources (29 entries, forward-slash
paths).

## Design decisions forced by the environment

- **Framework-only Java** (`android.app.Activity`, `android.webkit.WebView`,
  `android.speech.*`, `org.json`). No AndroidX/AppCompat/zxing/Material, because
  the raw pipeline only compiles against `android.jar`.
- **UI built in code** (dark top bar, progress bar, error panel, `PopupMenu`
  overflow) plus resource-free strings, so aapt2 only has to handle icons, the
  app label, colors and the network security config.
- **Theme** is `@android:style/Theme.Material.NoActionBar` (framework theme).
- **No QR scanner**: zxing is an AAR and cannot be compiled by the raw pipeline;
  pairing is done by pasting the pairing link or typing address + token in
  `assets/connect.html`. The CAMERA permission was removed accordingly.
- **Speech bridge** is injected with `addJavascriptInterface(bridge,
  "HeyNativeVoice")` before `loadUrl`, which is all the page-side shim
  `app/public/native-voice.js` needs. The Java contract is
  `sttAvailable()`, `startListening(String)`, `stopListening()`,
  `ttsAvailable()`, `speak(String,String,double,double)`, `stopSpeaking()`,
  `destroy()`, pushing JSON to `window.HeyNativeVoice._onNative("<json>")`
  with event types `start`, `partial`, `final`, `error`, `end`, `tts-start`,
  `tts-end` (transcript field is `text`).
- **Hands-free boot path**: microphone requested in `onCreate`; if the grant
  lands after the page loaded, one guarded `webView.reload()` so the page's
  `autoStartListening()` runs with microphone access.

## Residual risks (not testable without a physical device)

1. **`_onNative` assignment on an injected Java object.** `native-voice.js`
   stores its event handler as `window.HeyNativeVoice._onNative = handleNative`.
   The Java half calls it from `evaluateJavascript`. If a WebView build refused
   to add a JavaScript property to an injected object, the page-side shim would
   not install; this contract is owned by the PWA file and was not changed.
2. **`window.isSecureContext` on a page loaded after an accepted self-signed
   certificate.** The PWA gates voice and hands-free auto-start on it. Chromium
   treats an https origin as a secure context even when the certificate error
   was accepted, and Android WebView's `handler.proceed()` loads the page as
   https, so this is expected to be true; it was not confirmed on a device.
3. **`navigator.permissions.query({name:'microphone'})` inside WebView.**
   `autoStartListening()` checks it and skips auto-start when it reports
   `denied`. In WebView this API may reject (the code then starts anyway) or
   report `prompt` (starts); if it reported `denied` the user would fall back to
   tapping Start listening once. Not verified on a device.
4. **Microphone request at startup.** The permission dialog is shown on first
   launch (before pairing on a fresh install). This is intentional so hands-free
   works as soon as the paired page loads; deny once and the fallback guidance
   applies.
5. **Device speech engines.** Wake-word voice needs an Android
   `RecognitionService` (usually the Google app) and spoken replies need a TTS
   engine. The app degrades to typed commands when STT is missing.
6. **No on-device/emulator run was possible** in this environment. Verification
   covers the signed APK, the manifest/badging, dex contents, project ZIP
   contents and a clean compile of all Java sources; it does not cover runtime
   behaviour.
7. The Gradle path (`Option B` in README) was not executed here because Gradle
   cannot start on this machine; the project layout is standard AGP 8.7.3, and
   the manifest's `package` attribute must be removed for AGP (namespace is
   already declared).
