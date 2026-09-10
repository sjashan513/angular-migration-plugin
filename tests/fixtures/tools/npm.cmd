@echo off
if "%~1"=="--version" (
  echo 10.2.4
  exit /b 0
)
if "%~1"=="ci" echo install>>.fixture-trace
if "%~1"=="ls" echo dependency-tree>>.fixture-trace
if "%~1"=="run" (
  if "%~2"=="test:unit" (echo unit-test>>.fixture-trace) else (echo %~2>>.fixture-trace)
)
if exist .fixture-empty exit /b 0
echo fixture stdout
echo fixture stderr 1>&2
if "%~2"=="build" if exist .fixture-fail exit /b 1
exit /b 0