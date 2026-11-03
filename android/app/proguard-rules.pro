# No shrinking/obfuscation is enabled for this app. The file exists so the
# Gradle build has a stable ProGuard/R8 configuration if minify is ever turned on.
-keep class ai.heylogan.app.** { *; }
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}
