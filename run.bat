@echo off
chcp 65001 > nul
title 로블록스 실시간 레이더 중계 서버

echo ========================================================
echo   로블록스 실시간 레이더 중계 서버 실행 중...
echo ========================================================
echo.

start http://localhost:8000

where python >nul 2>nul
if %ERRORLEVEL% equ 0 (
    python "%~dp0server.py"
) else (
    "%LOCALAPPDATA%\Programs\Python\Python312\python.exe" "%~dp0server.py"
)

pause
