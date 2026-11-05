@echo off
setlocal
cd /d "%~dp0"
set "LAUNCH=%~dp0Launch.vbs"
if not exist "%LAUNCH%" (
  echo.
  echo   Could not find Launch.vbs next to this script:
  echo     %LAUNCH%
  echo.
  pause
  exit /b 1
)
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v "HeyLoganAI" /t REG_SZ /d "\"%WINDIR%\system32\wscript.exe\" \"%LAUNCH%\"" /f >nul 2>&1
if errorlevel 1 (
  echo.
  echo   Could not update the Windows "start at login" setting.
  echo.
  pause
  exit /b 1
)
echo.
echo   Hey Logan AI will now start automatically when you sign in to Windows.
echo   It starts listening for "Hey Logan" as soon as the app window opens.
echo.
echo   Launcher: "%LAUNCH%"
echo   To undo this later, run "Start at Login Off.cmd" in this folder.
echo.
pause
exit /b 0
