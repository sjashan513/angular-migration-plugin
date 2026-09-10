@echo off
if "%~1"=="--version" (
  echo 10.2.4
  exit /b 0
)
if not "%~1"=="view" (
  echo Unsupported fixture command 1>&2
  exit /b 2
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0respond.ps1" -Key "%~2" -RawArguments "%*"