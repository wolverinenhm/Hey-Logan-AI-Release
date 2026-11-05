/* ===========================================================================
 * v1.1.0 UI probe over the Chrome DevTools Protocol (qa-reviewer, independent QA)
 *
 * Run against a Chromium instance started with --remote-debugging-port:
 *   node _test\verify\v11-ui-probe.js 9223 <expected-http-port>
 *
 * Prints one JSON object with what the live page reports. Used to prove:
 *  - the microphone permission is already granted (seeded profile, no prompt);
 *  - hands-free listening auto-started (status line says "Listening ...");
 *  - speech synthesis works without a user gesture (autoplay flag);
 *  - SpeechRecognition.start() starts (wake engine can open the mic);
 *  - the served app.js includes autoStartListening() and sw.js is cache-busted.
 * =========================================================================== */
'use strict';

const http = require('http');

function getJson(url) {
  return new Promise((resolve, reject) => {
    http
      .get(url, (res) => {
        let body = '';
        res.on('data', (chunk) => (body += chunk));
        res.on('end', () => {
          try {
            resolve(JSON.parse(body));
          } catch (err) {
            reject(err);
          }
        });
      })
      .on('error', reject);
  });
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

(async () => {
  const debugPort = Number(process.argv[2] || 9223);
  const expectedPort = String(process.argv[3] || '8790');
  const out = { debugPort, expectedPort, targetUrl: null, targetTitle: null };

  let targets = [];
  for (let i = 0; i < 80; i += 1) {
    try {
      targets = await getJson(`http://127.0.0.1:${debugPort}/json/list`);
    } catch {
      targets = [];
    }
    const page = targets.find(
      (t) => t.type === 'page' && t.url && t.url.indexOf(`127.0.0.1:${expectedPort}`) >= 0
    );
    if (page) break;
    await delay(400);
  }
  const page = targets.find(
    (t) => t.type === 'page' && t.url && t.url.indexOf(`127.0.0.1:${expectedPort}`) >= 0
  );
  if (!page) {
    out.error = 'no page target with the expected localhost URL';
    out.definitelyNot = targets.map((t) => ({ type: t.type, url: t.url }));
    console.log(JSON.stringify(out, null, 2));
    process.exit(2);
  }
  out.targetUrl = page.url;
  out.targetTitle = page.title;

  const socket = new WebSocket(page.webSocketDebuggerUrl);
  const pending = new Map();
  let nextId = 0;
  await new Promise((resolve, reject) => {
    socket.onopen = resolve;
    socket.onerror = reject;
  });
  socket.onmessage = (event) => {
    let message;
    try {
      message = JSON.parse(event.data);
    } catch {
      return;
    }
    if (!message.id || !pending.has(message.id)) return;
    const waiter = pending.get(message.id);
    pending.delete(message.id);
    if (message.error) waiter.reject(new Error(JSON.stringify(message.error)));
    else waiter.resolve(message.result);
  };
  function send(method, params) {
    const id = ++nextId;
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      socket.send(JSON.stringify({ id, method, params: params || {} }));
    });
  }
  async function evaluate(expression, awaitPromise) {
    const result = await send('Runtime.evaluate', {
      expression,
      awaitPromise: Boolean(awaitPromise),
      returnByValue: true
    });
    if (!result || !result.result) return null;
    if ('value' in result.result) return result.result.value;
    return result.result;
  }

  out.readyState = await evaluate('document.readyState');
  out.title = await evaluate('document.title');
  out.secureContext = await evaluate('window.isSecureContext');
  out.statusText = await evaluate("(document.getElementById('statusText') || {}).textContent");
  out.connLabel = await evaluate("(document.getElementById('connLabel') || {}).textContent");
  out.orbState = await evaluate("document.getElementById('orb') ? document.getElementById('orb').dataset.state : null");
  out.listenButton = await evaluate("(document.getElementById('listenBtn') || {}).textContent");
  out.versionLabel = await evaluate("(document.getElementById('versionLabel') || {}).textContent");
  out.autoListenToggle = await evaluate(
    "document.getElementById('autoListenToggle') ? document.getElementById('autoListenToggle').checked : null"
  );
  out.srSupported = await evaluate(
    "Boolean(window.SpeechRecognition || window.webkitSpeechRecognition)"
  );
  out.synthSupported = await evaluate("Boolean(window.speechSynthesis)");
  out.microphonePermission = await evaluate(
    "navigator.permissions && navigator.permissions.query ? navigator.permissions.query({ name: 'microphone' }).then(function (p) { return p.state; }) : 'unsupported'",
    true
  );
  out.appJsHasAutoStartListening = await evaluate(
    "fetch('/app.js').then(function (r) { return r.text(); }).then(function (t) { return t.indexOf('autoStartListening') >= 0; })",
    true
  );
  out.voiceJsHasDefaultWake = await evaluate(
    "fetch('/voice.js').then(function (r) { return r.text(); }).then(function (t) { return t.indexOf('defaultWake') >= 0; })",
    true
  );
  out.servedSwHasV110Cache = await evaluate(
    "fetch('/sw.js').then(function (r) { return r.text(); }).then(function (t) { return t.indexOf('heyai-bridge-v1.1.0') >= 0 && t.indexOf('/native-voice.js') >= 0; })",
    true
  );
  out.servedIndexVersionLabel = await evaluate(
    "fetch('/').then(function (r) { return r.text(); }).then(function (t) { var m = t.match(/id=\"versionLabel\"[^>]*>([^<]*)</); return m ? m[1] : null; })",
    true
  );

  // Speech synthesis without any user gesture (what the autoplay flag is for).
  out.ttsProbe = await evaluate(
    "new Promise(function (resolve) {" +
      "  try {" +
      "    if (!window.speechSynthesis) { resolve('no-synthesis'); return; }" +
      "    var done = false;" +
      "    var finish = function (v) { if (done) return; done = true; resolve(v); };" +
      "    var u = new SpeechSynthesisUtterance('probe');" +
      "    u.onstart = function () { finish('started'); };" +
      "    u.onend = function () { finish('ended'); };" +
      "    u.onerror = function (e) { finish('error:' + (e && e.error)); };" +
      "    window.speechSynthesis.cancel();" +
      "    window.speechSynthesis.speak(u);" +
      "    setTimeout(function () { finish('timeout'); }, 6000);" +
      "  } catch (e) { resolve('throw:' + e.message); }" +
      "})",
    true
  );

  // SpeechRecognition can open the microphone without a prompt/click.
  // Stop the page's own hands-free engine first (same as the user would tap
  // "Stop listening") so two recognizers do not fight over the microphone.
  out.clickedStopListening = await evaluate(
    "(function () {" +
      "  var b = document.getElementById('listenBtn');" +
      "  if (!b) return false;" +
      "  if (b.textContent && b.textContent.indexOf('Stop') >= 0) { b.click(); return true; }" +
      "  return false;" +
      "})()"
  );
  await delay(700);
  out.sttProbe = await evaluate(
    "new Promise(function (resolve) {" +
      "  try {" +
      "    var R = window.SpeechRecognition || window.webkitSpeechRecognition;" +
      "    if (!R) { resolve('no-speech-recognition'); return; }" +
      "    var done = false;" +
      "    var r = new R();" +
      "    var finish = function (v) { if (done) return; done = true; try { r.abort(); } catch (e) {} resolve(v); };" +
      "    r.onstart = function () { finish('STARTED'); };" +
      "    r.onerror = function (e) { finish('error:' + (e && e.error)); };" +
      "    r.start();" +
      "    setTimeout(function () { finish('timeout'); }, 8000);" +
      "  } catch (e) { resolve('throw:' + e.message); }" +
      "})",
    true
  );

  console.log(JSON.stringify(out, null, 2));
  try {
    socket.close();
  } catch {
    /* ignore */
  }
  process.exit(0);
})().catch((err) => {
  console.error('PROBE ERROR: ' + (err && err.message ? err.message : String(err)));
  process.exit(1);
});
