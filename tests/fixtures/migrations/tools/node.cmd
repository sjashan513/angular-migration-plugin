@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0node-fixture.ps1" %*
exit /b %ERRORLEVEL%
