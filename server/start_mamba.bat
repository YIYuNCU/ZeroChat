@echo off
title ZeroChat Server (Mamba)
echo ========================================
echo   ZeroChat Server (Mamba)
echo   启动中...
echo ========================================
echo.

cd /d "%~dp0"

REM 检查 mamba
where mamba >nul 2>&1
if errorlevel 1 (
    echo [错误] 未找到 mamba，请先安装 mamba 并确保已添加到 PATH
    pause
    exit /b 1
)

REM 检查依赖
echo [信息] 检查依赖...
call mamba activate ZeroChat

echo.
echo [信息] 启动服务器...
echo.
python main.py

pause
