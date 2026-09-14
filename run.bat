@echo off
chcp 65001 > nul
title Bumati GPS Radar

echo ========================================================
echo   Bumati GPS Radar 실행 중...
echo   Python 서버 없이 Firebase에서 바로 데이터를 읽습니다.
echo ========================================================
echo.

start "" "%~dp0index.html"

pause
