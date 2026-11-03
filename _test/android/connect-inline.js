
(function () {
  'use strict';

  var form = document.getElementById('pairForm');
  var addr = document.getElementById('addr');
  var tokenEl = document.getElementById('token');
  var errorEl = document.getElementById('error');
  var connectBtn = document.getElementById('connectBtn');
  var foot = document.getElementById('foot');
  var bridge = null;
  try { bridge = window.HeyPairBridge || null; } catch (e) { bridge = null; }

  function showError(message) {
    errorEl.textContent = String(message || '');
    errorEl.style.display = 'block';
  }

  function clearError() {
    errorEl.textContent = '';
    errorEl.style.display = 'none';
  }

  function tokenFromUrl(text) {
    var match = /[?&]token=([^&\s#]+)/i.exec(String(text || ''));
    if (!match) return '';
    try { return decodeURIComponent(match[1]); } catch (e) { return match[1]; }
  }

  function stripTokenFromUrl(text) {
    return String(text || '')
      .replace(/([?&])token=[^&\s#]*/ig, '$1')
      .replace(/[?&]+$/, '');
  }

  function absorbPastedLink() {
    var raw = String(addr.value || '').trim();
    var token = tokenFromUrl(raw);
    if (!token) return;
    tokenEl.value = token;
    addr.value = stripTokenFromUrl(raw);
  }

  function withScheme(raw) {
    var value = String(raw || '').trim();
    if (!value) return '';
    if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(value)) value = 'https://' + value;
    return value;
  }

  function connect() {
    clearError();
    var address = withScheme(addr.value);
    var token = String(tokenEl.value || '').trim();
    if (!address) {
      showError('Enter the PC address printed by start.cmd, for example 192.168.1.20:8443');
      return;
    }
    if (!token) {
      showError('Enter the access token printed by start.cmd, or paste the whole pairing link.');
      return;
    }
    if (!bridge || typeof bridge.pair !== 'function') {
      showError('Open this screen from inside the Hey Logan AI Android app to connect.');
      return;
    }
    connectBtn.disabled = true;
    connectBtn.textContent = 'Connecting...';
    try {
      bridge.pair(address, token);
    } catch (e) {
      connectBtn.disabled = false;
      connectBtn.textContent = 'Connect';
      showError('Could not start the connection: ' + e);
    }
  }

  form.addEventListener('submit', function (event) {
    event.preventDefault();
    absorbPastedLink();
    connect();
  });

  addr.addEventListener('change', absorbPastedLink);
  addr.addEventListener('paste', function () { setTimeout(absorbPastedLink, 0); });

  window.HeyPair = {
    onNativeError: function (message) {
      showError(String(message || 'Could not pair with the PC.'));
    }
  };

  try {
    if (bridge && typeof bridge.version === 'function') {
      foot.textContent = 'Hey Logan AI for Android v' + bridge.version();
    }
  } catch (e) { /* ignore */ }
})();
