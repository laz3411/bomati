# BUMATI Android APK

이 폴더는 저장소 루트의 `index.html`, `manifest.json`, `sw.js`, `image/`, `icons/`, `부마티 로고.png`를 APK 안에 자동 포함하는 Android Studio 프로젝트입니다.

최소 지원 버전은 Android 8(API 26)이며 Android 10(API 29)을 포함합니다. Android 10에서는 별도의 알림 런타임 권한창 없이 알림 채널 설정이 유지됩니다.

## APK 빌드

1. Android Studio에서 `android-app` 폴더를 엽니다.
2. Gradle 동기화가 끝나면 `Build > Build APK(s)`를 실행합니다.
3. 생성 파일은 `android-app/app/build/outputs/apk/debug/app-debug.apk`에 있습니다.

명령줄에서는 `build-apk.bat`을 실행하면 포함된 Gradle Wrapper가 필요한 Gradle을 자동으로 준비하고 APK를 빌드합니다. Android Studio의 Gradle JDK는 17을 선택하세요.

## 알림과 백그라운드 동작

- Android 13 이상에서는 첫 하차 예약 때 알림 권한을 한 번만 요청합니다.
- 승인된 권한은 Android가 유지하므로 예약할 때마다 다시 묻지 않습니다.
- 예약 중에는 `BUMATI 하차 예약 감시 중` 포그라운드 알림이 표시됩니다.
- 앱을 다른 화면으로 전환하거나 최근 앱 화면에서 닫아도 서비스가 Firebase 예약 상태를 계속 확인합니다.
- 예약 상태가 `triggered`가 되면 네이티브 알림음과 진동을 발생시킵니다.
- 사용자가 Android 설정에서 알림 권한을 거부하거나 앱을 강제 종료하면 백그라운드 알림은 동작하지 않습니다.

Android 15 이상에서 `dataSync` 포그라운드 서비스는 시스템 시간 제한을 적용받습니다. 일반적인 버스 하차 예약 시간에는 충분하지만, 여러 시간 이상 연속 감시하는 운영 서비스는 Firebase Cloud Messaging 전환이 권장됩니다.
