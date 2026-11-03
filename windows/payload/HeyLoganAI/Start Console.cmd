@echo off
setlocal
cd /d "%~dp0app"
if not exist "%~dp0runtime\node.exe" (
  echo.
  echo   The bundled Node.js runtime is missing.
  echo   Please reinstall Hey Logan AI.
  echo.
  pause
  exit /b 1
)
echo.
echo   Hey Logan AI - server console
echo   -----------------------------
echo   Keep this window open while you use the app.
echo   Press Ctrl+C to stop the server.
echo.
"%~dp0runtime\node.exe" server\index.js %*
echo.
echo   The server has stopped.
pause
