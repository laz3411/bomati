@echo off
setlocal
cd /d "%~dp0"
if not defined JAVA_HOME (
  where java >nul 2>nul
  if errorlevel 1 (
    echo Java 17을 찾지 못했습니다. Android Studio에서 Gradle JDK 17을 설치하거나 JAVA_HOME을 설정하세요.
    exit /b 1
  )
)
call gradlew.bat :app:assembleDebug --no-daemon --console=plain
if errorlevel 1 exit /b 1
echo.
echo APK 생성 완료: app\build\outputs\apk\debug\app-debug.apk
endlocal
