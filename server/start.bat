@echo off
setlocal

rem Always run relative to this script so data/config paths stay in server\.
cd /d "%~dp0"

set "VENV_DIR=%~dp0.venv"
set "VENV_PYTHON=%VENV_DIR%\Scripts\python.exe"
set "DEPS_MARKER=%VENV_DIR%\.requirements-installed"

if not exist "%VENV_PYTHON%" (
    echo [ZeroChat] Creating Python virtual environment...
    where py >nul 2>nul
    if not errorlevel 1 (
        py -3 -m venv "%VENV_DIR%"
    ) else (
        where python >nul 2>nul
        if errorlevel 1 (
            echo [ZeroChat] Python 3 was not found. Install Python 3.12+ and try again.
            exit /b 1
        )
        python -m venv "%VENV_DIR%"
    )
    if errorlevel 1 (
        echo [ZeroChat] Failed to create the virtual environment.
        exit /b 1
    )
)

if not exist "%DEPS_MARKER%" (
    echo [ZeroChat] Installing server dependencies...
    "%VENV_PYTHON%" -m pip install --upgrade pip
    if errorlevel 1 (
        echo [ZeroChat] Failed to update pip.
        exit /b 1
    )
    "%VENV_PYTHON%" -m pip install -r "%~dp0requirements.txt"
    if errorlevel 1 (
        echo [ZeroChat] Failed to install dependencies.
        exit /b 1
    )
    >"%DEPS_MARKER%" echo installed
)

echo [ZeroChat] Starting server at http://127.0.0.1:8000
"%VENV_PYTHON%" "%~dp0main.py"
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" (
    echo [ZeroChat] Server stopped with exit code %EXIT_CODE%.
)
exit /b %EXIT_CODE%
