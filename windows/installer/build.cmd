@echo off
rem Build both Windows release artifacts (NSIS Setup.exe + portable ZIP).
rem Usage: double-click, or from a terminal:  windows\installer\build.cmd
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-all.ps1" %*
exit /b %ERRORLEVEL%
