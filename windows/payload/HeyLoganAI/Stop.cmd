@echo off
setlocal
echo.
echo   Stopping the Hey Logan AI server...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\stop.ps1"
if errorlevel 1 (
  echo   No running Hey Logan AI server was found.
) else (
  echo   Server stopped.
)
echo.
pause
