@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "SCRIPT=%SCRIPT_DIR%Setup-CodexWindows.ps1"

if not exist "%SCRIPT%" (
  echo Setup script was not found: "%SCRIPT%"
  exit /b 2
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "EXIT_CODE=%ERRORLEVEL%"

if "%EXIT_CODE%"=="3010" (
  echo.
  echo Setup completed and Windows reported that a reboot is required.
)

exit /b %EXIT_CODE%
