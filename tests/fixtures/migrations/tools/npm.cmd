@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0npm-fixture.ps1" %*
exit /b %ERRORLEVEL%
