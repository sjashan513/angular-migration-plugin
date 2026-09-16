@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0fnm-fixture.ps1" %*
exit /b %ERRORLEVEL%
