'use strict';

/**
 * Show the pairing information for this installation: the access token, the
 * local/LAN URLs the phone should use, and a QR code for the LAN HTTPS URL.
 *
 * Address selection reuses the server's own scoring (app/server/util.js
 * getLanAddresses) so the recommended URL and the QR code match what the app
 * itself reports: real home-LAN ranges first (192.168.x, 10.x, 172.16-31.x)
 * and virtual adapters (VPN / WSL / Hyper-V / Clash) last.
 *
 * Override the address with the HEYLOGAN_LAN_ADDR environment variable if the
 * automatically chosen one is still not the one your phone can reach.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');

const root = path.resolve(__dirname, '..');
const cfgPath = path.join(root, 'app', 'data', 'config.json');

let cfg = {};
try {
  cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
} catch (err) {
  cfg = {};
}

const token = (cfg.security && cfg.security.token) || '';
const serverCfg = cfg.server || {};
const httpPort = Number(serverCfg.httpPort || serverCfg.port) || 8787;
const httpsPort = Number(serverCfg.httpsPort) || 8443;

function scoreAddress(ip) {
  if (ip.startsWith('192.168.')) return 0;
  if (ip.startsWith('10.')) return 1;
  if (/^172\.(1[6-9]|2\d|3[01])\./.test(ip)) return 2;
  return 3;
}

function fallbackAddresses() {
  const out = [];
  const ifaces = os.networkInterfaces();
  for (const name of Object.keys(ifaces)) {
    for (const addr of ifaces[name] || []) {
      if (!addr || addr.family !== 'IPv4' || addr.internal) continue;
      if (addr.address.startsWith('127.') || addr.address.startsWith('169.254.')) continue;
      out.push({ name, address: addr.address });
    }
  }
  out.sort((a, b) => scoreAddress(a.address) - scoreAddress(b.address));
  return out;
}

function lanAddresses() {
  try {
    const util = require(path.join(root, 'app', 'server', 'util.js'));
    if (util && typeof util.getLanAddresses === 'function') {
      const scored = util.getLanAddresses();
      if (Array.isArray(scored) && scored.length) {
        return scored.map((entry) => ({ name: entry.name || 'network', address: entry.address }));
      }
    }
  } catch (err) {
    /* fall through to the local copy of the same scoring */
  }
  return fallbackAddresses();
}

function pad(text, width) {
  let out = String(text);
  while (out.length < width) out += ' ';
  return out;
}

console.log('');
console.log('  Hey Logan AI - pairing information');
console.log('  =================================');
console.log('');

if (!token) {
  console.log('  No access token found yet.');
  console.log('  Start Hey Logan AI once (double-click "Launch.vbs"), then run');
  console.log('  Pairing.cmd again to see the token and pairing links.');
  console.log('');
  process.exit(0);
}

const override = (process.env.HEYLOGAN_LAN_ADDR || '').trim();
const lan = lanAddresses();
let chosen = null;
if (override) chosen = { name: 'HEYLOGAN_LAN_ADDR', address: override };
else if (lan.length) chosen = lan[0];

const urls = [];
if (chosen) {
  urls.push({ label: 'Phone (same Wi-Fi, recommended) - ' + chosen.name, url: `https://${chosen.address}:${httpsPort}` });
  urls.push({ label: 'Phone (plain HTTP fallback)', url: `http://${chosen.address}:${httpPort}` });
}
urls.push({ label: 'This PC', url: `http://127.0.0.1:${httpPort}` });
for (const entry of lan.slice(1)) {
  if (chosen && entry.address === chosen.address) continue;
  urls.push({ label: 'Other network interface - ' + entry.name, url: `https://${entry.address}:${httpsPort}` });
}

console.log('  Access token:  ' + token);
console.log('');
console.log('  Addresses');
console.log('  ---------');
for (const entry of urls) console.log('    ' + pad(entry.label, 46) + entry.url);
console.log('');

const preferred = chosen
  ? `https://${chosen.address}:${httpsPort}/?token=${encodeURIComponent(token)}`
  : `http://127.0.0.1:${httpPort}/?token=${encodeURIComponent(token)}`;

if (chosen && scoreAddress(chosen.address) === 3) {
  console.log('  NOTE: ' + chosen.address + ' does not look like a normal home or office');
  console.log('  LAN address (it may belong to a VPN or virtual adapter). If your phone');
  console.log('  cannot open the link below, set the address your Wi-Fi uses, e.g.:');
  console.log('');
  console.log('      set HEYLOGAN_LAN_ADDR=192.168.0.104');
  console.log('      Pairing.cmd');
  console.log('');
}

console.log('  Pairing links (open on the phone; the token is included)');
console.log('  -------------------------------------------------------');
for (const entry of urls) console.log('    ' + entry.url + '/?token=' + encodeURIComponent(token));
console.log('');
console.log('  Android app: install the APK, then type the address + token above (or');
console.log('  paste the first pairing link). The app has no camera scanner.');
console.log('  Phone camera / Chrome: scan the QR code below, accept the certificate');
console.log('  warning, then "Add to Home screen".');
console.log('');

function printQr() {
  if (!chosen) {
    console.log('  No LAN address found - the phone can only reach this PC through a');
    console.log('  tunnel (Tailscale, Cloudflare Tunnel) or on the PC itself.');
    return;
  }
  let qrcode = null;
  try {
    qrcode = require(path.join(root, 'app', 'node_modules', 'qrcode'));
  } catch (err) {
    qrcode = null;
  }
  if (!qrcode) {
    console.log('  (QR code unavailable - the bundled qrcode module was not found.)');
    return;
  }
  qrcode
    .toString(preferred, { type: 'terminal', small: true, errorCorrectionLevel: 'M' })
    .then((text) => {
      console.log('  Scan this QR code with your phone:');
      console.log('');
      console.log(text);
    })
    .catch(() => {
      console.log('  (Could not draw the QR code - use the pairing link above.)');
    });
}

printQr();
