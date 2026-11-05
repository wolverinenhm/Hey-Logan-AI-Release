@echo off
setlocal
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v "HeyLoganAI" /f >nul 2>&1
if errorlevel 1 (
  echo.
  echo   Hey Logan AI is not set to start automatically when you sign in.
  echo   Nothing to do.
  echo.
  pause
  exit /b 0
)
echo.
echo   Hey Logan AI will no longer start automatically when you sign in to Windows.
echo.
echo   To turn it back on later, run "Start at Login On.cmd" in this folder.
echo.
pause
exit /b 0
