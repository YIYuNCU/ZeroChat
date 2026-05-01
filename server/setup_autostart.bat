@echo off
setlocal enabledelayedexpansion

set "TASK_NAME=ZeroChatServerAutoStart"
set "SCRIPT_DIR=%~dp0"
set "START_BAT=%SCRIPT_DIR%start.bat"
set "START_MAMBA=%SCRIPT_DIR%start_mamba.bat"
set "CHOICE_FILE=%SCRIPT_DIR%.autostart_choice"

if /i "%~1"=="remove" goto remove
if /i "%~1"=="status" goto status
if /i "%~1"=="install" goto select_method
if /i "%~1"=="/h" goto help
if /i "%~1"=="/?" goto help
if /i "%~1"=="help" goto help

echo [Info] No action specified, using: install
goto select_method

:select_method
echo ==============================
echo   Select Startup Method
echo ==============================
echo.
echo Please select which script to use for autostart:
echo.
echo   [1] start.bat (venv virtual environment)
echo   [2] start_mamba.bat (Conda/Mamba environment)
echo.
set /p "CHOICE=Enter 1 or 2: "

if "!CHOICE!"=="1" (
    set "START_SCRIPT=!START_BAT!"
    echo !START_BAT! > "%CHOICE_FILE%"
    echo [OK] Selected: start.bat
) else if "!CHOICE!"=="2" (
    set "START_SCRIPT=!START_MAMBA!"
    echo !START_MAMBA! > "%CHOICE_FILE%"
    echo [OK] Selected: start_mamba.bat
) else (
    echo [Error] Invalid choice. Please enter 1 or 2.
    pause
    exit /b 1
)

if not exist "!START_SCRIPT!" (
    echo [Error] Cannot find script: !START_SCRIPT!
    pause
    exit /b 1
)

:install
if not defined START_SCRIPT (
    if exist "%CHOICE_FILE%" (
        set /p START_SCRIPT=<"%CHOICE_FILE%"
    ) else (
        echo [Error] Please run 'setup_autostart.bat install' first.
        pause
        exit /b 1
    )
)

echo [Info] Creating startup task: %TASK_NAME%
echo [Info] Script: !START_SCRIPT!
schtasks /Create /TN "%TASK_NAME%" /TR "\"!START_SCRIPT!\"" /SC ONLOGON /DELAY 0000:30 /F
if errorlevel 1 (
    echo [Error] Failed to create task. Try running as Administrator.
    pause
    exit /b 1
)
echo [OK] Startup task created.
exit /b 0

:remove
echo [Info] Removing startup task: %TASK_NAME%
schtasks /Delete /TN "%TASK_NAME%" /F
if errorlevel 1 (
    echo [Error] Failed to remove task. Try running as Administrator.
    pause
    exit /b 1
)
echo [OK] Startup task removed.
exit /b 0

:status
schtasks /Query /TN "%TASK_NAME%" /V /FO LIST
if errorlevel 1 (
    echo [Info] No startup task found.
    exit /b 1
)
echo.
if exist "%CHOICE_FILE%" (
    set /p saved_choice=<"%CHOICE_FILE%"
    echo [Info] Current startup script: !saved_choice!
)
exit /b 0

:help
echo Usage:
echo   setup_autostart.bat install    - Select method and create task
echo   setup_autostart.bat remove     - Remove startup task
echo   setup_autostart.bat status     - Check task status
echo.
echo If no argument is provided, it defaults to install.
exit /b 0
