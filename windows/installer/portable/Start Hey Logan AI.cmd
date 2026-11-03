@echo off
setlocal
cd /d "%~dp0"
title Hey Logan AI (portable)

if not exist "runtime\node.exe" (
  echo.
  echo   The bundled Node.js runtime is missing:
  echo     %~dp0runtime\node.exe
  echo   Extract the ZIP again, keeping the folder structure.
  echo.
  pause
  exit /b 1
)
if not exist "app\server\index.js" (
  echo.
  echo   The application files are missing:
  echo     %~dp0app\server\index.js
  echo   Extract the ZIP again, keeping the folder structure.
  echo.
  pause
  exit /b 1
)

echo.
echo   Hey Logan AI - portable edition
echo   -------------------------------
echo   Keep this window open while you use the app.
echo   Close this window (or press Ctrl+C) to stop the server.
echo.
echo   This PC:  http://127.0.0.1:8787
echo   Phone:    run "Pairing.cmd" for the address, token and QR code.
echo            (see README-FIRST.txt if the phone cannot connect)
echo.

rem Absolute paths matter: tools\stop.ps1 finds the server by matching the
rem node.exe command line against this folder. Relative paths would make
rem "Stop.cmd" report that no server is running while the ports stay busy.
"%~dp0runtime\node.exe" "%~dp0app\server\index.js"

echo.
echo   The server has stopped.
pause
