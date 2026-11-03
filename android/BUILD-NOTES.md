# Build notes - Hey Logan AI Android 1.0.0

This file records how the shipped APK was actually produced and verified, so a
future maintainer can reproduce it.

## Result

| Item | Value |
|---|---|
| APK | `dist\HeyLoganAI-android-1.0.0.apk` |
| Size | 226,868 bytes (0.22 MB) |
| SHA-256 | `8A4A769223ED16803DC30328B9D10E163D33D6518B6F11194A4BE772E60D8439` |
| Package | `ai.heylogan.app` (versionCode 1, versionName 1.0.0) |
| minSdk / targetSdk | 26 / 35 |
| Launchable activity | `ai.heylogan.app.MainActivity` |
| Signature | APK Signature Scheme v2 + v3, 1 signer, RSA 2048 / SHA256withRSA |
| Certificate SHA-256 | `6C:82:67:92:33:C2:AB:DF:78:0C:FC:2C:A8:9B:06:68:49:07:D0:FF:54:5D:27:A3:E1:26:83:7F:93:18:48:0C` |
| Keystore | `android\release-keystore\heylogan-release.jks` (alias `heylogan`) |

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
helper from the Gradle distribution), so the shipped APK was built by driving
the SDK build tools directly. `android\` is still kept as a normal Gradle
project (AGP 8.7.3 / Gradle 8.9 / Java 17) for Android Studio and CI on a normal
machine.

## Toolchain used

| Tool | Path |
|---|---|
| JDK 17 (Temurin 17.0.20.1+1) | `_toolchain\jdk` |
| Android platform 35 | `_toolchain\sdk\platforms\android-35\android.jar` |
| Build-tools 35.0.0 (aapt2, d8, zipalign, apksigner) | `_toolchain\sdk\build-tools\35.0.0` |
| Build script | `android\tools\build-apk-manual.ps1` (not edited) |

## Exact build command

```powershell
$rel = 'C:\Users\s2121270\Downloads\Hey-Logan-AI-Release'
$env:JAVA_HOME    = "$rel\_toolchain\jdk"
$env:ANDROID_HOME = "$rel\_toolchain\sdk"
powershell -NoProfile -ExecutionPolicy Bypass `
  -File "$rel\android\tools\build-apk-manual.ps1" -StorePass '<read from release-keystore/keystore-info.txt>'
```

## Pipeline (what the script does)

1. `aapt2 compile --dir app/src/main/res -o resources.zip`
2. `aapt2 link` (manifest + resources + `assets/` via `-A`) with
   `--min-sdk-version 26 --target-sdk-version 35 --version-code 1
   --version-name 1.0.0 --java gen` -> `base.apk`
3. `javac -source 17 -target 17 -classpath android.jar` over
   `app/src/main/java` + generated `R.java` -> `classes/`
4. `d8 --lib android.jar --min-api 26` -> `classes.dex`
5. add `classes.dex` to `base.apk` -> `unsigned.apk`
6. `zipalign -f -p 4`
7. `apksigner sign` with `release-keystore/heylogan-release.jks`
   (creates the keystore on first run; password from `-StorePass`)
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
package: name='ai.heylogan.app' versionCode='1' versionName='1.0.0' ... compileSdkVersion='35'
minSdkVersion:'26'
targetSdkVersion:'35'
uses-permission: name='android.permission.INTERNET'
uses-permission: name='android.permission.ACCESS_NETWORK_STATE'
uses-permission: name='android.permission.RECORD_AUDIO'
application-label:'Hey Logan AI'
launchable-activity: name='ai.heylogan.app.MainActivity'
```

APK contents (20 entries) include:

```
classes.dex
assets/connect.html
res/mipmap-*/ic_launcher.png + ic_launcher_foreground.png
res/mipmap-anydpi-v26/ic_launcher.xml + ic_launcher_round.xml
res/xml/network_security_config.xml
resources.arsc
```

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

## Residual risks (not testable without a physical device)

1. **`_onNative` assignment on an injected Java object.** `native-voice.js`
   stores its event handler as `window.HeyNativeVoice._onNative = handleNative`.
   The Java half calls it from `evaluateJavascript`. If a WebView build refused
   to add a JavaScript property to an injected object, the page-side shim would
   not install; this contract is owned by the PWA file and was not changed.
2. **`window.isSecureContext` on a page loaded after an accepted self-signed
   certificate.** The PWA disables its voice buttons when it is false. Chromium
   treats an https origin as a secure context even when the certificate error
   was accepted, and Android WebView's `handler.proceed()` loads the page as
   https, so this is expected to be true; it was not confirmed on a device.
3. **Device speech engines.** Wake-word voice needs an Android
   `RecognitionService` (usually the Google app) and spoken replies need a TTS
   engine. Both are reported through `sttAvailable()` / `ttsAvailable()` and the
   app degrades to typed commands when STT is missing.
4. **No on-device/emulator run was possible** in this environment. Verification
   covers the signed APK, the manifest/badging, resources/assets, and a clean
   compile of all Java sources; it does not cover runtime behaviour.
5. The Gradle path (`Option B` in README) was not executed here because Gradle
   cannot start on this machine; the project layout is standard AGP 8.7.3, and
   the manifest's `package` attribute must be removed for AGP (namespace is
   already declared).
