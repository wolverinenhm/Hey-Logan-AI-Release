HEY LOGAN AI - PORTABLE EDITION (Windows 10/11, 64-bit)
========================================================

This ZIP is the portable edition: nothing is installed, no registry entries
are written and no shortcuts are created. Everything runs from this folder.

QUICK START
-----------
1. Extract the whole ZIP to a normal folder (for example C:\HeyLoganAI).
   Do not run it from inside the ZIP file.
2. Open the folder and double-click "Start Hey Logan AI.cmd".
   A console window opens, the local server starts, and the console shows the
   local URLs plus pairing information. Keep that window open while you use
   the app.
   Prefer no console window? Double-click "Launch.vbs" instead - it starts the
   server hidden and opens the app in a chromeless Edge/Chrome window.
3. To use your phone: run "Pairing.cmd" (or scan the QR code shown in the
   console). The phone must be on the same Wi-Fi network. If the firewall
   asks for permission, click "Allow access"; otherwise run
   "Allow through Firewall.cmd" once (it asks for administrator approval).
4. To stop the app: close the console window, or run "Stop.cmd".

YOUR DATA
---------
Your settings, access token and HTTPS certificate live in app\data inside this
folder. Keep the folder together when you move it, or copy app\data with it.
There is no "uninstall": stop the server and delete the folder to remove
everything.

TROUBLESHOOTING
---------------
- Nothing happens: run "Start Hey Logan AI.cmd" and read the error message in
  the console window.
- "Port 8787 or 8443 already in use": another copy is already running - run
  "Stop.cmd" first, then start again.
- The phone cannot connect: same Wi-Fi? Is the network "Private" in Windows?
  Did the firewall rule get added? Run "Pairing.cmd" again for the current
  address (the address changes when the router gives the PC a new IP).
- Voice input on the phone needs the https:// pairing link, and you must
  accept the certificate warning the first time.
- The folder includes its own Node.js runtime (v22.23.3); no Node.js
  installation is required.

Hey Logan AI runs entirely on your own machine. No cloud account and no
subscription. See HELP.txt and app\README.md for the full documentation.
