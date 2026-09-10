@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%MIGRATION_FIXTURE_TOOLS%\ng-fixture.ps1" %*
exit /b %ERRORLEVEL%
