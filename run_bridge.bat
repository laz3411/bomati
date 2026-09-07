@echo off
chcp 65001 > nul
title Roblox 하차벨 Firebase 브리지

echo ========================================================
echo   Roblox 하차벨 Firebase 브리지 실행 중...
echo   (USB 연결 포트를 자동으로 감지합니다)
echo ========================================================
echo.

py bell_firebase_bridge.py

if errorlevel 1 (
    echo.
    echo 실행 실패 시 python 또는 py 명령어가 설치되어 있는지,
    echo 장치가 USB에 꽂혀 있는지 확인하세요.
    echo.
    pause
)
