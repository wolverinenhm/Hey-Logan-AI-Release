package ai.heylogan.app;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.speech.RecognitionListener;
import android.speech.RecognizerIntent;
import android.speech.SpeechRecognizer;
import android.speech.tts.TextToSpeech;
import android.speech.tts.UtteranceProgressListener;
import android.util.Log;
import android.webkit.JavascriptInterface;
import android.webkit.WebView;

import org.json.JSONObject;

import java.util.ArrayList;
import java.util.Locale;

/**
 * Native speech bridge for the WebView shell.
 *
 * Android System WebView has no Web Speech API. The page-side shim
 * (app/public/native-voice.js, served by the PC bridge) detects this object as
 * {@code window.HeyNativeVoice}, saves its native-event callback on
 * {@code window.HeyNativeVoice._onNative} and recreates SpeechRecognition /
 * speechSynthesis for the PWA. This class is the Java half of that contract:
 *
 *   sttAvailable()                       -> boolean
 *   startListening(String lang)          -> starts a continuous recognition session
 *   stopListening()                      -> stops it
 *   ttsAvailable()                       -> boolean
 *   speak(String text, String lang, double rate, double pitch)
 *   stopSpeaking()
 *   destroy()
 *
 * Events are pushed to JS as JSON through window.HeyNativeVoice._onNative(...):
 *
 *   {"type":"start"}
 *   {"type":"partial","text":"..."}
 *   {"type":"final","text":"..."}
 *   {"type":"error","error":"not-allowed|audio-capture|service-not-allowed|no-speech|aborted|network"}
 *   {"type":"end"}
 *   {"type":"tts-start"}
 *   {"type":"tts-end"}
 *
 * Framework-only Java (android.* / java.* / org.json): the shipping APK is
 * built with the raw SDK tools, so there are no AndroidX dependencies.
 */
public final class VoiceBridge {

    private static final String TAG = "HeyLoganVoice";
    private static final long RESTART_DELAY_MS = 250L;
    private static final long RESTART_DELAY_NETWORK_MS = 1200L;
    private static final long RESTART_DELAY_BUSY_MS = 700L;
    private static final long START_FALLBACK_MS = 1200L;
    private static final long TTS_INIT_TIMEOUT_MS = 6000L;
    private static final int MAX_CONSECUTIVE_FAILURES = 8;

    private final Activity activity;
    private final WebView webView;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final boolean sttAvailable;

    /* ---------------- speech recognition state ---------------- */

    private SpeechRecognizer recognizer;
    private boolean recognizing = false;
    private boolean userStopped = true;
    private boolean destroyed = false;
    private boolean startEventSent = false;
    private String language = "en-US";
    private int consecutiveFailures = 0;
    private Runnable restartTask;
    private Runnable startFallbackTask;

    /* ---------------- text to speech state ---------------- */

    private TextToSpeech tts;
    private boolean ttsReady = false;
    private boolean ttsInitAttempted = false;
    private boolean ttsInitFinished = false;
    private String currentSpeechId = "";
    private int speechCounter = 0;
    private SpeakRequest queuedSpeak;

    public VoiceBridge(Activity activity, WebView webView) {
        this.activity = activity;
        this.webView = webView;
        boolean available;
        try {
            available = SpeechRecognizer.isRecognitionAvailable(activity);
        } catch (Throwable t) {
            available = false;
        }
        this.sttAvailable = available;
        initTts();
    }

    /* ============================================================
       JavaScript interface
       ============================================================ */

    @JavascriptInterface
    public boolean sttAvailable() {
        return sttAvailable;
    }

    @JavascriptInterface
    public boolean ttsAvailable() {
        return ttsReady;
    }

    @JavascriptInterface
    public void startListening(final String lang) {
        main.post(new Runnable() {
            @Override
            public void run() {
                if (destroyed) return;
                language = normaliseLanguage(lang);
                userStopped = false;
                consecutiveFailures = 0;
                startEventSent = false;
                cancelRestart();
                cancelStartFallback();
                releaseRecognizer();
                startInternal();
                scheduleStartFallback();
            }
        });
    }

    @JavascriptInterface
    public void stopListening() {
        main.post(new Runnable() {
            @Override
            public void run() {
                userStopped = true;
                cancelRestart();
                cancelStartFallback();
                releaseRecognizer();
            }
        });
    }

    @JavascriptInterface
    public void speak(final String text, final String lang, final double rate, final double pitch) {
        main.post(new Runnable() {
            @Override
            public void run() {
                if (destroyed) return;
                SpeakRequest request = new SpeakRequest(text, lang, (float) rate, (float) pitch);
                if (ttsReady) {
                    doSpeakNow(request);
                    return;
                }
                queuedSpeak = request;
                initTts();
                if (ttsInitFinished && !ttsReady) {
                    failQueuedSpeak();
                    return;
                }
                scheduleTtsInitTimeout(request);
            }
        });
    }

    @JavascriptInterface
    public void stopSpeaking() {
        main.post(new Runnable() {
            @Override
            public void run() {
                queuedSpeak = null;
                currentSpeechId = "";
                if (tts == null) return;
                try {
                    tts.stop();
                } catch (Throwable ignored) {
                    /* ignore */
                }
            }
        });
    }

    @JavascriptInterface
    public void destroy() {
        main.post(new Runnable() {
            @Override
            public void run() {
                releaseAll();
            }
        });
    }

    /** Called by the Activity (and by the JavaScript destroy()) when the page goes away. */
    public void releaseAll() {
        destroyed = true;
        userStopped = true;
        cancelRestart();
        cancelStartFallback();
        releaseRecognizer();
        queuedSpeak = null;
        currentSpeechId = "";
        if (tts != null) {
            try {
                tts.stop();
            } catch (Throwable ignored) {
                /* ignore */
            }
            try {
                tts.shutdown();
            } catch (Throwable ignored) {
                /* ignore */
            }
            tts = null;
        }
        ttsReady = false;
    }

    /** The page is navigating/reloading: release the microphone and stop speaking. */
    public void pauseForPageChange() {
        main.post(new Runnable() {
            @Override
            public void run() {
                userStopped = true;
                cancelRestart();
                cancelStartFallback();
                releaseRecognizer();
                queuedSpeak = null;
                currentSpeechId = "";
                if (tts != null) {
                    try {
                        tts.stop();
                    } catch (Throwable ignored) {
                        /* ignore */
                    }
                }
            }
        });
    }

    /* ============================================================
       Speech recognition
       ============================================================ */

    private void startInternal() {
        if (destroyed || userStopped) return;

        if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO)
                != PackageManager.PERMISSION_GRANTED) {
            failRecognition("not-allowed");
            return;
        }
        if (!sttAvailable) {
            failRecognition("service-not-allowed");
            return;
        }
        if (recognizer == null) {
            try {
                recognizer = SpeechRecognizer.createSpeechRecognizer(activity);
                recognizer.setRecognitionListener(recognitionListener);
            } catch (Throwable t) {
                Log.w(TAG, "Could not create SpeechRecognizer", t);
                recognizer = null;
                failRecognition("service-not-allowed");
                return;
            }
        }
        startSession();
    }

    private void startSession() {
        if (destroyed || userStopped || recognizer == null) return;
        try {
            Intent intent = new Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH);
            intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                    RecognizerIntent.LANGUAGE_MODEL_FREE_FORM);
            intent.putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true);
            intent.putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3);
            intent.putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, activity.getPackageName());
            if (language != null && language.length() > 0) {
                intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE, language);
            }
            recognizer.startListening(intent);
            recognizing = true;
        } catch (Throwable t) {
            Log.w(TAG, "startListening failed", t);
            recognizing = false;
            scheduleRestart(RESTART_DELAY_MS);
        }
    }

    private void scheduleRestart(long delayMs) {
        if (destroyed || userStopped) return;
        cancelRestart();
        restartTask = new Runnable() {
            @Override
            public void run() {
                restartTask = null;
                if (destroyed || userStopped || recognizing) return;
                releaseRecognizer();
                startInternal();
            }
        };
        main.postDelayed(restartTask, delayMs);
    }

    private void cancelRestart() {
        if (restartTask != null) {
            main.removeCallbacks(restartTask);
            restartTask = null;
        }
    }

    private void scheduleStartFallback() {
        cancelStartFallback();
        startFallbackTask = new Runnable() {
            @Override
            public void run() {
                startFallbackTask = null;
                if (destroyed || userStopped || startEventSent) return;
                startEventSent = true;
                emitType("start");
            }
        };
        main.postDelayed(startFallbackTask, START_FALLBACK_MS);
    }

    private void cancelStartFallback() {
        if (startFallbackTask != null) {
            main.removeCallbacks(startFallbackTask);
            startFallbackTask = null;
        }
    }

    private void releaseRecognizer() {
        recognizing = false;
        startEventSent = false;
        if (recognizer == null) return;
        SpeechRecognizer old = recognizer;
        recognizer = null;
        try {
            old.cancel();
        } catch (Throwable ignored) {
            /* ignore */
        }
        try {
            old.destroy();
        } catch (Throwable ignored) {
            /* ignore */
        }
    }

    private final RecognitionListener recognitionListener = new RecognitionListener() {
        @Override
        public void onReadyForSpeech(Bundle params) {
            consecutiveFailures = 0;
            if (!startEventSent) {
                startEventSent = true;
                cancelStartFallback();
                emitType("start");
            }
        }

        @Override
        public void onBeginningOfSpeech() {
            consecutiveFailures = 0;
        }

        @Override
        public void onRmsChanged(float rmsdB) {
            /* not used by the page */
        }

        @Override
        public void onBufferReceived(byte[] buffer) {
            /* not used by the page */
        }

        @Override
        public void onEndOfSpeech() {
            /* the engine delivers onResults next */
        }

        @Override
        public void onError(int error) {
            handleRecognitionError(error);
        }

        @Override
        public void onResults(Bundle results) {
            recognizing = false;
            consecutiveFailures = 0;
            String text = firstResult(results);
            if (text != null && text.length() > 0) {
                emitText("final", text);
            }
            if (!userStopped) {
                scheduleRestart(RESTART_DELAY_MS);
            }
        }

        @Override
        public void onPartialResults(Bundle partialResults) {
            consecutiveFailures = 0;
            String text = firstResult(partialResults);
            if (text != null && text.length() > 0) {
                emitText("partial", text);
            }
        }

        @Override
        public void onEvent(int eventType, Bundle params) {
            /* not used by the page */
        }
    };

    private void handleRecognitionError(int error) {
        recognizing = false;
        if (userStopped || destroyed) return;

        switch (error) {
            case SpeechRecognizer.ERROR_NO_MATCH:
            case SpeechRecognizer.ERROR_SPEECH_TIMEOUT:
                consecutiveFailures = 0;
                scheduleRestart(RESTART_DELAY_MS);
                return;
            case SpeechRecognizer.ERROR_NETWORK:
            case SpeechRecognizer.ERROR_NETWORK_TIMEOUT:
            case SpeechRecognizer.ERROR_SERVER:
                consecutiveFailures += 1;
                if (consecutiveFailures > MAX_CONSECUTIVE_FAILURES) {
                    failRecognition("network");
                    return;
                }
                scheduleRestart(RESTART_DELAY_NETWORK_MS);
                return;
            case SpeechRecognizer.ERROR_RECOGNIZER_BUSY:
                consecutiveFailures += 1;
                if (consecutiveFailures > MAX_CONSECUTIVE_FAILURES) {
                    failRecognition("service-not-allowed");
                    return;
                }
                scheduleRestart(RESTART_DELAY_BUSY_MS);
                return;
            case SpeechRecognizer.ERROR_CLIENT:
                scheduleRestart(RESTART_DELAY_MS);
                return;
            case SpeechRecognizer.ERROR_AUDIO:
                failRecognition("audio-capture");
                return;
            case SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS:
                failRecognition("not-allowed");
                return;
            case SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED:
            case SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE:
                failRecognition("service-not-allowed");
                return;
            default:
                failRecognition("service-not-allowed");
        }
    }

    private void failRecognition(String code) {
        if (destroyed) return;
        userStopped = true;
        cancelRestart();
        cancelStartFallback();
        releaseRecognizer();
        emitError(code);
        emitType("end");
    }

    private static String firstResult(Bundle bundle) {
        if (bundle == null) return null;
        ArrayList<String> matches = bundle.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION);
        if (matches == null || matches.isEmpty()) return null;
        String best = matches.get(0);
        if (best == null) return null;
        return best.trim();
    }

    /* ============================================================
       Text to speech
       ============================================================ */

    private void scheduleTtsInitTimeout(final SpeakRequest request) {
        main.postDelayed(new Runnable() {
            @Override
            public void run() {
                if (queuedSpeak == request && !ttsReady && !destroyed) {
                    queuedSpeak = null;
                    emitTtsEnd();
                }
            }
        }, TTS_INIT_TIMEOUT_MS);
    }

    private void initTts() {
        if (ttsInitAttempted || destroyed) return;
        ttsInitAttempted = true;
        try {
            tts = new TextToSpeech(activity.getApplicationContext(), new TextToSpeech.OnInitListener() {
                @Override
                public void onInit(int status) {
                    main.post(new Runnable() {
                        @Override
                        public void run() {
                            onTtsInitialised(status);
                        }
                    });
                }
            });
        } catch (Throwable t) {
            Log.w(TAG, "TextToSpeech could not be created", t);
            tts = null;
            ttsReady = false;
            ttsInitFinished = true;
            failQueuedSpeak();
        }
    }

    private void onTtsInitialised(int status) {
        if (destroyed) return;
        ttsInitFinished = true;
        boolean ok = status == TextToSpeech.SUCCESS && tts != null;
        if (!ok) {
            ttsReady = false;
            failQueuedSpeak();
            return;
        }
        ttsReady = true;
        try {
            tts.setOnUtteranceProgressListener(utteranceProgressListener);
        } catch (Throwable ignored) {
            /* ignore */
        }
        if (queuedSpeak != null) {
            SpeakRequest request = queuedSpeak;
            queuedSpeak = null;
            doSpeakNow(request);
        }
    }

    private void doSpeakNow(SpeakRequest request) {
        if (destroyed || request == null) return;
        if (tts == null || !ttsReady) {
            emitTtsEnd();
            return;
        }
        String text = request.text == null ? "" : request.text.trim();
        if (text.length() == 0) {
            emitTtsEnd();
            return;
        }

        Locale locale = localeFrom(request.lang);
        int languageResult;
        try {
            languageResult = tts.setLanguage(locale);
        } catch (Throwable t) {
            languageResult = TextToSpeech.LANG_NOT_SUPPORTED;
        }
        if (languageResult == TextToSpeech.LANG_MISSING_DATA
                || languageResult == TextToSpeech.LANG_NOT_SUPPORTED) {
            try {
                tts.setLanguage(Locale.getDefault());
            } catch (Throwable ignored) {
                /* ignore */
            }
        }

        try {
            tts.setSpeechRate(clamp(request.rate, 0.5f, 2.0f));
        } catch (Throwable ignored) {
            /* ignore */
        }
        try {
            tts.setPitch(clamp(request.pitch, 0.5f, 2.0f));
        } catch (Throwable ignored) {
            /* ignore */
        }

        speechCounter += 1;
        currentSpeechId = "hey-tts-" + speechCounter;
        emitType("tts-start");

        int result;
        try {
            result = tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, currentSpeechId);
        } catch (Throwable t) {
            result = TextToSpeech.ERROR;
        }
        if (result != TextToSpeech.SUCCESS) {
            currentSpeechId = "";
            emitTtsEnd();
        }
    }

    private final UtteranceProgressListener utteranceProgressListener = new UtteranceProgressListener() {
        @Override
        public void onStart(String utteranceId) {
            /* tts-start is emitted eagerly by doSpeakNow */
        }

        @Override
        public void onDone(final String utteranceId) {
            notifySpeechFinished(utteranceId);
        }

        @Override
        public void onStop(final String utteranceId, final boolean interrupted) {
            notifySpeechFinished(utteranceId);
        }

        @Override
        public void onError(final String utteranceId) {
            notifySpeechFinished(utteranceId);
        }
    };

    private void notifySpeechFinished(final String utteranceId) {
        main.post(new Runnable() {
            @Override
            public void run() {
                if (destroyed) return;
                if (utteranceId == null || !utteranceId.equals(currentSpeechId)) return;
                currentSpeechId = "";
                emitTtsEnd();
            }
        });
    }

    private void failQueuedSpeak() {
        queuedSpeak = null;
        emitTtsEnd();
    }

    /* ============================================================
       Native -> page event pump
       ============================================================ */

    private void emitText(String type, String text) {
        try {
            JSONObject event = new JSONObject();
            event.put("type", type);
            event.put("text", text);
            emitJson(event);
        } catch (Throwable ignored) {
            /* ignore */
        }
    }

    private void emitType(String type) {
        try {
            JSONObject event = new JSONObject();
            event.put("type", type);
            emitJson(event);
        } catch (Throwable ignored) {
            /* ignore */
        }
    }

    private void emitError(String code) {
        try {
            JSONObject event = new JSONObject();
            event.put("type", "error");
            event.put("error", code);
            emitJson(event);
        } catch (Throwable ignored) {
            /* ignore */
        }
    }

    private void emitTtsEnd() {
        try {
            JSONObject event = new JSONObject();
            event.put("type", "tts-end");
            emitJson(event);
        } catch (Throwable ignored) {
            /* ignore */
        }
    }

    /**
     * Delivers one JSON event to app/public/native-voice.js, which stores its
     * handler as window.HeyNativeVoice._onNative(jsonString).
     */
    private void emitJson(JSONObject event) {
        if (event == null) return;
        final String script = "(function(){try{var b=window.HeyNativeVoice;"
                + "if(b&&typeof b._onNative==='function'){b._onNative("
                + JSONObject.quote(event.toString()) + ");}}catch(e){}})();";
        main.post(new Runnable() {
            @Override
            public void run() {
                if (destroyed || webView == null) return;
                try {
                    webView.evaluateJavascript(script, null);
                } catch (Throwable ignored) {
                    /* ignore */
                }
            }
        });
    }

    /* ============================================================
       Helpers
       ============================================================ */

    private static String normaliseLanguage(String lang) {
        if (lang == null) return "en-US";
        String value = lang.trim().replace('_', '-');
        if (value.length() == 0) return "en-US";
        return value;
    }

    private static Locale localeFrom(String lang) {
        String value = normaliseLanguage(lang);
        try {
            Locale locale = Locale.forLanguageTag(value);
            if (locale.getLanguage() != null && locale.getLanguage().length() > 0) return locale;
        } catch (Throwable ignored) {
            /* ignore */
        }
        return Locale.US;
    }

    private static float clamp(float value, float min, float max) {
        if (Float.isNaN(value)) return 1.0f;
        if (value < min) return min;
        if (value > max) return max;
        return value;
    }

    private static final class SpeakRequest {
        final String text;
        final String lang;
        final float rate;
        final float pitch;

        SpeakRequest(String text, String lang, float rate, float pitch) {
            this.text = text;
            this.lang = lang;
            this.rate = rate;
            this.pitch = pitch;
        }
    }
}
