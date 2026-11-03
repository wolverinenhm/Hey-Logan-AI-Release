@echo off
setlocal
cd /d "%~dp0app"
if not exist "%~dp0runtime\node.exe" (
  echo   The bundled Node.js runtime is missing.
  pause
  exit /b 1
)
"%~dp0runtime\node.exe" "%~dp0tools\pair.js"
echo.
pause
