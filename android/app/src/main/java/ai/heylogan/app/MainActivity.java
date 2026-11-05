package ai.heylogan.app;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.ActivityNotFoundException;
import android.content.DialogInterface;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.net.http.SslError;
import android.os.Bundle;
import android.text.TextUtils;
import android.util.Log;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.MenuItem;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowInsets;
import android.view.WindowManager;
import android.webkit.JavascriptInterface;
import android.webkit.PermissionRequest;
import android.webkit.SslErrorHandler;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.PopupMenu;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.Toast;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.Locale;

/**
 * Single-activity companion client for "Hey Logan AI".
 *
 * A dark WebView shell around the bridge that the user runs with Pairing.cmd on
 * their Windows PC. It pairs once (address + access token, or a pasted pairing
 * link), remembers the pairing, accepts the PC's self-signed TLS certificate
 * for that host only after an explicit confirmation, grants microphone access
 * to the page, and exposes the native speech bridge (VoiceBridge) so wake-word
 * voice and spoken replies work inside the WebView.
 *
 * Framework-only Java (android.* / java.* / org.json) because the shipping APK
 * is built with the raw SDK tools (tools/build-apk-manual.ps1); no AndroidX.
 */
public class MainActivity extends Activity {

    private static final String TAG = "HeyLoganMain";

    private static final String PREFS = "heylogan";
    private static final String KEY_SCHEME = "scheme";
    private static final String KEY_HOST = "host";
    private static final String KEY_PORT = "port";
    private static final String KEY_TOKEN = "token";
    private static final String KEY_SSL_TRUSTED_HOST = "ssl_trusted_host";

    private static final String CONNECT_PAGE = "file:///android_asset/connect.html";
    private static final String JS_VOICE_NAME = "HeyNativeVoice";
    private static final String JS_PAIR_NAME = "HeyPairBridge";
    private static final int REQUEST_MIC = 4101;
    private static final int DEFAULT_HTTPS_PORT = 8443;
    private static final int DEFAULT_HTTP_PORT = 8787;

    private static final int MENU_RELOAD = 1;
    private static final int MENU_CHANGE_PC = 2;
    private static final int MENU_ABOUT = 3;

    private static final int COLOR_BG = 0xFF070B16;
    private static final int COLOR_SURFACE = 0xFF0D1424;
    private static final int COLOR_BORDER = 0xFF1E2E4A;
    private static final int COLOR_ACCENT = 0xFF22D3EE;
    private static final int COLOR_ACCENT_LIGHT = 0xFF7FF3FF;
    private static final int COLOR_TEXT = 0xFFE6F1FF;
    private static final int COLOR_TEXT_MUTED = 0xFF8FA3C0;
    private static final int COLOR_DARK_TEXT = 0xFF041018;

    private WebView webView;
    private ProgressBar progressBar;
    private LinearLayout errorPanel;
    private TextView errorMessage;
    private LinearLayout rootLayout;

    private SharedPreferences prefs;
    private VoiceBridge voiceBridge;
    private PairBridge pairBridge;

    private boolean pairingMode = false;
    private boolean sslDialogShowing = false;

    /* Hands-free "Hey Logan" (v1.1.0): the microphone is requested as soon as
       the app starts so the page's autoStartListening() can start the native
       recognizer without the user pressing anything. If the grant arrives after
       the page has already loaded, the page is reloaded exactly once so its
       auto-start runs with microphone access (the flag can never loop). */
    private boolean microphonePermissionAsked = false;
    private boolean microphoneReloadDone = false;

    /* ============================================================
       Lifecycle
       ============================================================ */

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        prefs = getSharedPreferences(PREFS, MODE_PRIVATE);

        Window window = getWindow();
        window.setBackgroundDrawable(new ColorDrawable(COLOR_BG));
        window.setStatusBarColor(COLOR_BG);
        window.setNavigationBarColor(COLOR_BG);
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
        window.addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS);

        buildUi();
        configureWebView();

        voiceBridge = new VoiceBridge(this, webView);
        pairBridge = new PairBridge();
        webView.addJavascriptInterface(voiceBridge, JS_VOICE_NAME);
        webView.addJavascriptInterface(pairBridge, JS_PAIR_NAME);

        // Ask for the microphone up front (before/while the page loads) so the
        // page's hands-free auto-start can actually open the native recognizer.
        maybeRequestMicrophonePermission();

        if (hasPairing()) {
            connectToPairedPc();
        } else {
            showPairingScreen();
        }
    }

    @Override
    protected void onDestroy() {
        if (voiceBridge != null) {
            voiceBridge.destroy();
            voiceBridge.releaseAll();
            voiceBridge = null;
        }
        if (webView != null) {
            try {
                webView.removeJavascriptInterface(JS_VOICE_NAME);
                webView.removeJavascriptInterface(JS_PAIR_NAME);
                webView.loadUrl("about:blank");
            } catch (Throwable ignored) {
                /* ignore */
            }
            webView.destroy();
            webView = null;
        }
        super.onDestroy();
    }

    @SuppressWarnings("deprecation")
    @Override
    public void onBackPressed() {
        if (pairingMode || webView == null || !webView.canGoBack()) {
            super.onBackPressed();
            return;
        }
        webView.goBack();
    }

    /* ============================================================
       UI (built in code: framework-only, no resource layouts)
       ============================================================ */

    private int dp(int value) {
        return Math.round(getResources().getDisplayMetrics().density * value);
    }

    private void buildUi() {
        rootLayout = new LinearLayout(this);
        rootLayout.setOrientation(LinearLayout.VERTICAL);
        rootLayout.setBackgroundColor(COLOR_BG);
        setContentView(rootLayout);

        rootLayout.addView(buildTopBar(), new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(48)));

        FrameLayout content = new FrameLayout(this);
        rootLayout.addView(content, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        webView = new WebView(this);
        webView.setBackgroundColor(COLOR_BG);
        content.addView(webView, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        progressBar = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        progressBar.setMax(100);
        progressBar.setProgressTintList(android.content.res.ColorStateList.valueOf(COLOR_ACCENT));
        progressBar.setVisibility(View.GONE);
        FrameLayout.LayoutParams progressParams = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(3), Gravity.TOP);
        content.addView(progressBar, progressParams);

        errorPanel = buildErrorPanel();
        errorPanel.setVisibility(View.GONE);
        FrameLayout.LayoutParams errorParams = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER);
        errorParams.setMargins(dp(24), 0, dp(24), 0);
        content.addView(errorPanel, errorParams);

        rootLayout.setOnApplyWindowInsetsListener(new View.OnApplyWindowInsetsListener() {
            @Override
            public WindowInsets onApplyWindowInsets(View view, WindowInsets insets) {
                if (insets == null) return null;
                int top = insets.getSystemWindowInsetTop();
                int bottom = insets.getSystemWindowInsetBottom();
                int left = insets.getSystemWindowInsetLeft();
                int right = insets.getSystemWindowInsetRight();
                view.setPadding(left, top, right, bottom);
                return insets;
            }
        });
    }

    private View buildTopBar() {
        LinearLayout bar = new LinearLayout(this);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        bar.setBackgroundColor(COLOR_SURFACE);
        bar.setPadding(dp(18), 0, dp(6), 0);

        TextView title = new TextView(this);
        title.setText("Hey Logan AI");
        title.setTextColor(COLOR_ACCENT_LIGHT);
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 17);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        title.setSingleLine(true);
        bar.addView(title, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        TextView menuButton = new TextView(this);
        menuButton.setText("...");
        menuButton.setTextColor(COLOR_TEXT_MUTED);
        menuButton.setTextSize(TypedValue.COMPLEX_UNIT_SP, 20);
        menuButton.setGravity(Gravity.CENTER);
        menuButton.setPadding(dp(16), dp(8), dp(16), dp(8));
        menuButton.setContentDescription("More options");
        menuButton.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                showOverflowMenu(view);
            }
        });
        bar.addView(menuButton, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        return bar;
    }

    private LinearLayout buildErrorPanel() {
        LinearLayout panel = new LinearLayout(this);
        panel.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(22);
        panel.setPadding(pad, pad, pad, pad);

        GradientDrawable background = new GradientDrawable();
        background.setColor(COLOR_SURFACE);
        background.setCornerRadius(dp(20));
        background.setStroke(dp(1), COLOR_BORDER);
        panel.setBackground(background);

        TextView title = new TextView(this);
        title.setText("Can't reach your PC");
        title.setTextColor(COLOR_TEXT);
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 19);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        panel.addView(title, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        errorMessage = new TextView(this);
        errorMessage.setTextColor(COLOR_TEXT_MUTED);
        errorMessage.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        errorMessage.setLineSpacing(dp(3), 1f);
        LinearLayout.LayoutParams messageParams = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        messageParams.topMargin = dp(8);
        panel.addView(errorMessage, messageParams);

        LinearLayout buttons = new LinearLayout(this);
        buttons.setOrientation(LinearLayout.HORIZONTAL);
        LinearLayout.LayoutParams buttonsParams = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        buttonsParams.topMargin = dp(20);
        panel.addView(buttons, buttonsParams);

        Button retryButton = makeButton("Retry", true);
        retryButton.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                hideError();
                if (pairingMode) {
                    if (webView != null) webView.reload();
                } else {
                    connectToPairedPc();
                }
            }
        });
        buttons.addView(retryButton, new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        Button changePcButton = makeButton("Change PC", false);
        changePcButton.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                forgetPairing();
            }
        });
        LinearLayout.LayoutParams changeParams = new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        changeParams.leftMargin = dp(10);
        buttons.addView(changePcButton, changeParams);
        return panel;
    }

    private Button makeButton(String label, boolean primary) {
        Button button = new Button(this);
        button.setText(label);
        button.setAllCaps(false);
        button.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        button.setTypeface(Typeface.DEFAULT_BOLD);
        button.setTextColor(primary ? COLOR_DARK_TEXT : COLOR_ACCENT_LIGHT);
        button.setMinHeight(0);
        button.setMinimumHeight(0);
        button.setPadding(0, dp(11), 0, dp(11));

        GradientDrawable background = new GradientDrawable();
        background.setCornerRadius(dp(12));
        if (primary) {
            background.setColor(COLOR_ACCENT);
        } else {
            background.setColor(0x00000000);
            background.setStroke(dp(1), 0x5522D3EE);
        }
        button.setBackground(background);
        return button;
    }

    private void showOverflowMenu(View anchor) {
        PopupMenu popup = new PopupMenu(this, anchor);
        popup.getMenu().add(0, MENU_RELOAD, 0, "Reload");
        popup.getMenu().add(0, MENU_CHANGE_PC, 1, "Change PC");
        popup.getMenu().add(0, MENU_ABOUT, 2, "About");
        popup.setOnMenuItemClickListener(new PopupMenu.OnMenuItemClickListener() {
            @Override
            public boolean onMenuItemClick(MenuItem item) {
                return handleMenuSelection(item.getItemId());
            }
        });
        popup.show();
    }

    private boolean handleMenuSelection(int itemId) {
        if (itemId == MENU_RELOAD) {
            hideError();
            if (pairingMode) {
                if (webView != null) webView.reload();
            } else {
                connectToPairedPc();
            }
            return true;
        }
        if (itemId == MENU_CHANGE_PC) {
            confirmForgetPairing();
            return true;
        }
        if (itemId == MENU_ABOUT) {
            showAboutDialog();
            return true;
        }
        return false;
    }

    private void showProgress() {
        if (progressBar == null) return;
        progressBar.setVisibility(View.VISIBLE);
        if (progressBar.getProgress() < 5) progressBar.setProgress(5);
    }

    private void hideProgress() {
        if (progressBar == null) return;
        progressBar.setProgress(0);
        progressBar.setVisibility(View.GONE);
    }

    private void showError(String message) {
        if (errorPanel == null) return;
        errorMessage.setText(message);
        errorPanel.setVisibility(View.VISIBLE);
        errorPanel.bringToFront();
        hideProgress();
    }

    private void hideError() {
        if (errorPanel != null) errorPanel.setVisibility(View.GONE);
    }

    private void toast(String message) {
        if (TextUtils.isEmpty(message)) return;
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show();
    }

    /* ============================================================
       Pairing state
       ============================================================ */

    private boolean hasPairing() {
        return !TextUtils.isEmpty(prefs.getString(KEY_HOST, null))
                && !TextUtils.isEmpty(prefs.getString(KEY_TOKEN, null));
    }

    private String pairedScheme() {
        String scheme = prefs.getString(KEY_SCHEME, "https");
        return TextUtils.isEmpty(scheme) ? "https" : scheme;
    }

    private String pairedHost() {
        return prefs.getString(KEY_HOST, "");
    }

    private int pairedPort() {
        String scheme = pairedScheme();
        int fallback = "https".equals(scheme) ? DEFAULT_HTTPS_PORT : DEFAULT_HTTP_PORT;
        return prefs.getInt(KEY_PORT, fallback);
    }

    private String pairedToken() {
        return prefs.getString(KEY_TOKEN, "");
    }

    private String buildPairUrl() {
        return pairedScheme() + "://" + pairedHost() + ":" + pairedPort()
                + "/?token=" + Uri.encode(pairedToken());
    }

    private void showPairingScreen() {
        pairingMode = true;
        if (voiceBridge != null) voiceBridge.pauseForPageChange();
        hideError();
        hideProgress();
        if (webView == null) return;
        try {
            webView.getSettings().setAllowFileAccess(true);
            webView.loadUrl(CONNECT_PAGE);
        } catch (Throwable t) {
            Log.w(TAG, "Could not open the pairing screen", t);
        }
    }

    private void connectToPairedPc() {
        if (!hasPairing()) {
            showPairingScreen();
            return;
        }
        pairingMode = false;
        hideError();
        if (voiceBridge != null) voiceBridge.pauseForPageChange();
        try {
            webView.getSettings().setAllowFileAccess(false);
        } catch (Throwable ignored) {
            /* ignore */
        }
        maybeRequestMicrophonePermission();
        webView.loadUrl(buildPairUrl());
    }

    private void confirmForgetPairing() {
        new AlertDialog.Builder(this)
                .setTitle("Change PC?")
                .setMessage("This removes the saved PC address and access token from the app. "
                        + "You can pair again with the pairing link printed by Pairing.cmd.")
                .setPositiveButton("Change PC", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface dialog, int which) {
                        forgetPairing();
                    }
                })
                .setNegativeButton("Cancel", null)
                .show();
    }

    private void forgetPairing() {
        prefs.edit()
                .remove(KEY_SCHEME)
                .remove(KEY_HOST)
                .remove(KEY_PORT)
                .remove(KEY_TOKEN)
                .remove(KEY_SSL_TRUSTED_HOST)
                .apply();
        if (webView != null) {
            webView.clearHistory();
            webView.clearCache(true);
        }
        if (voiceBridge != null) voiceBridge.pauseForPageChange();
        showPairingScreen();
    }

    private void onPairingRequested(String address, String token) {
        String raw = address == null ? "" : address.trim();
        if (raw.length() == 0) {
            toast("Enter the PC address first.");
            return;
        }
        if (!raw.contains("://")) {
            raw = "https://" + raw;
        }
        String scheme;
        String host;
        int port;
        String tokenFromUrl = "";
        try {
            Uri uri = Uri.parse(raw);
            scheme = uri.getScheme() == null ? "" : uri.getScheme().toLowerCase(Locale.US);
            host = uri.getHost();
            port = uri.getPort();
            tokenFromUrl = uri.getQueryParameter("token");
        } catch (Throwable t) {
            toast("That PC address could not be understood. Use the pairing link from Pairing.cmd.");
            return;
        }
        if (!"http".equals(scheme) && !"https".equals(scheme)) {
            toast("That PC address could not be understood. Use the pairing link from Pairing.cmd.");
            return;
        }
        if (TextUtils.isEmpty(host)) {
            toast("That PC address could not be understood. Use the pairing link from Pairing.cmd.");
            return;
        }
        if (port <= 0) {
            port = "https".equals(scheme) ? DEFAULT_HTTPS_PORT : DEFAULT_HTTP_PORT;
        }

        String resolvedToken = token == null ? "" : token.trim();
        if (resolvedToken.length() == 0) {
            resolvedToken = tokenFromUrl == null ? "" : tokenFromUrl.trim();
        }
        if (resolvedToken.length() == 0) {
            toast("Enter the access token first.");
            return;
        }

        String previousHost = prefs.getString(KEY_HOST, null);
        SharedPreferences.Editor editor = prefs.edit()
                .putString(KEY_SCHEME, scheme)
                .putString(KEY_HOST, host)
                .putInt(KEY_PORT, port)
                .putString(KEY_TOKEN, resolvedToken);
        if (previousHost == null || !previousHost.equalsIgnoreCase(host)) {
            editor.remove(KEY_SSL_TRUSTED_HOST);
        }
        editor.apply();

        connectToPairedPc();
    }

    /* ============================================================
       WebView setup
       ============================================================ */

    private void configureWebView() {
        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setMediaPlaybackRequiresUserGesture(false);
        settings.setSupportZoom(false);
        settings.setBuiltInZoomControls(false);
        settings.setDisplayZoomControls(false);
        settings.setLoadWithOverviewMode(true);
        settings.setUseWideViewPort(true);
        settings.setTextZoom(100);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        settings.setAllowContentAccess(false);
        settings.setAllowFileAccess(true);
        settings.setDatabaseEnabled(false);
        settings.setCacheMode(WebSettings.LOAD_DEFAULT);
        settings.setJavaScriptCanOpenWindowsAutomatically(false);
        settings.setSupportMultipleWindows(false);

        webView.setBackgroundColor(COLOR_BG);
        webView.setOverScrollMode(View.OVER_SCROLL_NEVER);
        webView.setVerticalScrollBarEnabled(false);
        webView.setWebViewClient(new AppWebViewClient());
        webView.setWebChromeClient(new AppWebChromeClient());
    }

    /* ============================================================
       Permissions
       ============================================================ */

    private boolean hasMicrophonePermission() {
        return checkSelfPermission(Manifest.permission.RECORD_AUDIO)
                == PackageManager.PERMISSION_GRANTED;
    }

    private void maybeRequestMicrophonePermission() {
        if (hasMicrophonePermission()) return;
        if (microphonePermissionAsked) return;
        microphonePermissionAsked = true;
        requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO}, REQUEST_MIC);
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode != REQUEST_MIC) return;

        if (grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            toast("Microphone ready - hands-free \"Hey Logan\" is on.");
            // The page may already have loaded while the dialog was open, in which
            // case its autoStartListening() could not get the microphone. Reload
            // it once so auto-start runs with access. microphoneReloadDone makes
            // a reload loop impossible.
            if (!pairingMode && !microphoneReloadDone && webView != null
                    && isHttpUrl(webView.getUrl())) {
                microphoneReloadDone = true;
                hideError();
                try {
                    webView.reload();
                } catch (Throwable t) {
                    Log.w(TAG, "Could not reload the page after the microphone grant", t);
                }
            }
        } else {
            toast("Microphone permission was denied. Hands-free needs it - enable it in "
                    + "Android Settings, then tap Start listening once.");
        }
    }

    /* ============================================================
       Host helpers
       ============================================================ */

    private static String normaliseHost(String host) {
        if (host == null) return "";
        String value = host.trim().toLowerCase(Locale.US);
        if (value.startsWith("[") && value.endsWith("]")) {
            value = value.substring(1, value.length() - 1);
        }
        return value;
    }

    private static boolean isLoopbackHost(String host) {
        String value = normaliseHost(host);
        return "127.0.0.1".equals(value)
                || "localhost".equals(value)
                || "::1".equals(value)
                || "10.0.2.2".equals(value);
    }

    private boolean isPairedHost(String host) {
        String candidate = normaliseHost(host);
        String paired = normaliseHost(pairedHost());
        if (candidate.length() == 0 || paired.length() == 0) return false;
        if (candidate.equals(paired)) return true;
        return isLoopbackHost(candidate) && isLoopbackHost(paired);
    }

    private boolean isHttpUrl(String url) {
        if (url == null) return false;
        String lower = url.toLowerCase(Locale.US);
        return lower.startsWith("http://") || lower.startsWith("https://");
    }

    private void openExternally(Uri uri) {
        try {
            startActivity(new Intent(Intent.ACTION_VIEW, uri));
        } catch (ActivityNotFoundException e) {
            toast("No app can open that link.");
        } catch (Throwable t) {
            Log.w(TAG, "Could not open link externally", t);
        }
    }

    private String appVersionName() {
        try {
            String version = getPackageManager()
                    .getPackageInfo(getPackageName(), 0).versionName;
            if (!TextUtils.isEmpty(version)) return version;
        } catch (Throwable ignored) {
            /* fall through */
        }
        return "1.1.0";
    }

    private void showAboutDialog() {
        new AlertDialog.Builder(this)
                .setTitle("Hey Logan AI " + appVersionName())
                .setMessage("Companion client for the Hey Logan AI (Hey AI Bridge) server running on your PC.\n\n"
                        + "- Hands-free: just say \"Hey Logan\" - no button press. The app asks for the "
                        + "microphone once at startup and starts listening as soon as the page opens.\n"
                        + "- Pair once with the address and access token printed by Pairing.cmd.\n"
                        + "- The PC's self-signed certificate is trusted only for the paired PC, after your confirmation.\n"
                        + "- Voice input and spoken replies use the phone's own speech engines; the PC only receives transcripts.\n\n"
                        + "Source, build script and signing information are in the project archive.")
                .setPositiveButton("OK", null)
                .show();
    }

    /* ============================================================
       SSL handling
       ============================================================ */

    private void handleSslError(final SslErrorHandler handler, final SslError error) {
        String url = error == null ? null : error.getUrl();
        String host = null;
        if (url != null) {
            try {
                host = Uri.parse(url).getHost();
            } catch (Throwable ignored) {
                /* ignore */
            }
        }

        if (pairingMode || !isPairedHost(host)) {
            try {
                handler.cancel();
            } catch (Throwable ignored) {
                /* ignore */
            }
            if (!pairingMode) {
                toast("Blocked an untrusted certificate from "
                        + (host == null ? "an unknown host" : host) + ".");
            }
            return;
        }

        String trustedHost = prefs.getString(KEY_SSL_TRUSTED_HOST, null);
        if (trustedHost != null && normaliseHost(trustedHost).equals(normaliseHost(host))) {
            try {
                handler.proceed();
            } catch (Throwable ignored) {
                /* ignore */
            }
            return;
        }

        if (sslDialogShowing) {
            try {
                handler.cancel();
            } catch (Throwable ignored) {
                /* ignore */
            }
            return;
        }
        sslDialogShowing = true;
        final String sslHost = host == null ? "" : host;

        new AlertDialog.Builder(this)
                .setTitle("Trust this PC's certificate?")
                .setMessage("The PC at " + sslHost + " uses a certificate it generated itself. "
                        + "The connection is encrypted, but there is no certificate authority to vouch for it.\n\n"
                        + "Continue only if this is your own PC and the address matches the one printed by Pairing.cmd.\n\n"
                        + "The app remembers this choice for this PC.")
                .setPositiveButton("Continue", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface dialog, int which) {
                        sslDialogShowing = false;
                        prefs.edit().putString(KEY_SSL_TRUSTED_HOST, sslHost).apply();
                        try {
                            handler.proceed();
                        } catch (Throwable ignored) {
                            /* ignore */
                        }
                    }
                })
                .setNegativeButton("Cancel", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface dialog, int which) {
                        sslDialogShowing = false;
                        try {
                            handler.cancel();
                        } catch (Throwable ignored) {
                            /* ignore */
                        }
                        showError("Connection cancelled. The PC certificate was not trusted.");
                    }
                })
                .setCancelable(false)
                .show();
    }

    /* ============================================================
       WebView clients
       ============================================================ */

    private final class AppWebViewClient extends WebViewClient {

        @Override
        public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
            if (request == null || request.getUrl() == null) return true;
            Uri uri = request.getUrl();
            String scheme = uri.getScheme() == null ? "" : uri.getScheme().toLowerCase(Locale.US);

            if ("file".equals(scheme)) {
                return !uri.toString().startsWith("file:///android_asset/");
            }
            if (!"http".equals(scheme) && !"https".equals(scheme)) {
                return true;
            }
            if (!pairingMode && isPairedHost(uri.getHost())) {
                return false;
            }
            openExternally(uri);
            return true;
        }

        @Override
        public void onPageStarted(WebView view, String url, Bitmap favicon) {
            if (!pairingMode && isHttpUrl(url) && voiceBridge != null) {
                voiceBridge.pauseForPageChange();
            }
            showProgress();
            hideError();
        }

        @Override
        public void onPageFinished(WebView view, String url) {
            hideProgress();
        }

        @Override
        public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
            if (request == null || !request.isForMainFrame()) return;
            String url = request.getUrl() == null ? null : request.getUrl().toString();
            if (!isHttpUrl(url)) return;
            CharSequence description = error == null ? "" : error.getDescription();
            showError("The bridge on your PC did not answer.\n\n"
                    + (description == null ? "" : description.toString())
                    + "\n\nCheck that Pairing.cmd is running, that the phone is on the same Wi-Fi "
                    + "network, and that Windows Firewall allows Node.js on private networks.");
        }

        @Override
        public void onReceivedSslError(WebView view, SslErrorHandler handler, SslError error) {
            handleSslError(handler, error);
        }
    }

    private final class AppWebChromeClient extends WebChromeClient {

        @Override
        public void onProgressChanged(WebView view, int newProgress) {
            if (progressBar == null) return;
            if (newProgress >= 100) {
                hideProgress();
            } else {
                progressBar.setProgress(newProgress);
                progressBar.setVisibility(View.VISIBLE);
            }
        }

        @Override
        public void onPermissionRequest(final PermissionRequest request) {
            runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    try {
                        if (request == null || request.getOrigin() == null) {
                            if (request != null) request.deny();
                            return;
                        }
                        boolean originAllowed = isPairedHost(request.getOrigin().getHost());
                        boolean wantsAudio = false;
                        String[] resources = request.getResources();
                        if (resources != null) {
                            for (String resource : resources) {
                                if (PermissionRequest.RESOURCE_AUDIO_CAPTURE.equals(resource)) {
                                    wantsAudio = true;
                                }
                            }
                        }
                        if (originAllowed && wantsAudio && hasMicrophonePermission()) {
                            request.grant(new String[]{PermissionRequest.RESOURCE_AUDIO_CAPTURE});
                        } else {
                            request.deny();
                        }
                    } catch (Throwable t) {
                        Log.w(TAG, "Could not answer a WebView permission request", t);
                    }
                }
            });
        }

        @Override
        public void onPermissionRequestCanceled(PermissionRequest request) {
            /* nothing to do */
        }
    }

    /* ============================================================
       JavaScript pairing bridge (connect.html)
       ============================================================ */

    public final class PairBridge {

        @JavascriptInterface
        public void pair(String address, String token) {
            runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    onPairingRequested(address, token);
                }
            });
        }

        @JavascriptInterface
        public String version() {
            return appVersionName();
        }
    }
}
