@echo off
setlocal

set "TASK_NAME=ZeroChatServerAutoStart"
set "START_BAT=%~dp0start.bat"

if not exist "%START_BAT%" (
    echo [Error] Cannot find start.bat: %START_BAT%
    exit /b 1
)

if /i "%~1"=="remove" goto remove
if /i "%~1"=="status" goto status
if /i "%~1"=="install" goto install
if /i "%~1"=="help" goto help
if /i "%~1"=="/h" goto help
if /i "%~1"=="/?" goto help

echo [Info] No action specified, using: install
goto install

:install
echo [Info] Creating startup task: %TASK_NAME%
schtasks /Create /TN "%TASK_NAME%" /TR "\"%START_BAT%\"" /SC ONLOGON /DELAY 0000:30 /F >nul 2>&1
if errorlevel 1 (
    echo [Error] Failed to create startup task.
    echo [Hint] Try running this script as Administrator.
    exit /b 1
)
echo [OK] Startup task created.
echo [Info] It will run start.bat 30 seconds after user logon.
exit /b 0

:remove
echo [Info] Removing startup task: %TASK_NAME%
schtasks /Delete /TN "%TASK_NAME%" /F >nul 2>&1
if errorlevel 1 (
    echo [Warn] Task was not found or could not be removed.
    exit /b 1
)
echo [OK] Startup task removed.
exit /b 0

:status
schtasks /Query /TN "%TASK_NAME%" >nul 2>&1
if errorlevel 1 (
    echo [Info] Startup task not found: %TASK_NAME%
    exit /b 1
)
echo [OK] Startup task exists: %TASK_NAME%
schtasks /Query /TN "%TASK_NAME%" /V /FO LIST
exit /b 0

:help
echo Usage:
echo   setup_autostart.bat install
echo   setup_autostart.bat remove
echo   setup_autostart.bat status
echo.
echo If no argument is provided, it defaults to install.
exit /b 0
