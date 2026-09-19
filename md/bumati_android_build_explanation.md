# HTML 웹 앱을 APK로 만드는 방식

## 한 줄 요약

부마티는 HTML을 APK로 변환한 것이 아니라, `index.html`과 웹 리소스를 Android 앱의 assets에 복사한 뒤 Android `WebView`로 실행하는 하이브리드 앱 방식으로 APK를 만들었다.

```text
루트 웹 앱
index.html + manifest.json + sw.js + png/
             │
             │ Gradle syncWebAssets 작업
             ▼
Android APK assets
             │
             │ MainActivity.java의 WebViewAssetLoader
             ▼
WebView에서 index.html 실행
             │
             └─ Firebase는 HTTPS로 직접 연결
                Android 알림은 Java 네이티브 코드가 담당
```

## 1. HTML 파일을 APK에 넣는 과정

핵심 설정은 [`android-app/app/build.gradle`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/android-app/app/build.gradle)의 `syncWebAssets` 작업이다.

```gradle
tasks.register('syncWebAssets', Copy) {
    from(rootProject.projectDir.parentFile) {
        include 'index.html'
        include 'manifest.json'
        include 'sw.js'
        include 'png/**'
    }
    into(generatedWebAssets)
}

android.sourceSets.main.assets.srcDir(generatedWebAssets)
tasks.named('preBuild').configure { dependsOn tasks.named('syncWebAssets') }
```

빌드 시 다음 순서로 처리된다.

1. Android 프로젝트의 상위 폴더, 즉 저장소 루트에서 웹 파일을 찾는다.
2. `index.html`, `manifest.json`, `sw.js`, 로고, 아이콘, 지도 이미지를 Android 생성 assets 폴더로 복사한다.
3. `preBuild` 전에 `syncWebAssets`가 먼저 실행되므로 APK에는 항상 최신 웹 파일이 포함된다.
4. Android Gradle Plugin이 복사된 파일과 Java 소스 코드를 하나의 APK로 패키징한다.

따라서 웹 화면을 수정한 뒤 APK를 다시 빌드하면 수정된 `index.html`이 새 APK에 포함된다.

## 2. Android에서 HTML을 실행하는 과정

[`MainActivity.java`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/android-app/app/src/main/java/com/bumati/app/MainActivity.java)가 앱 시작점이다.

- Android 네이티브 화면에 `WebView`를 생성한다.
- JavaScript, DOM Storage, Web Database를 활성화한다.
- `WebViewAssetLoader`로 APK 내부 assets를 안전한 HTTPS 형태로 제공한다.
- 다음 주소를 WebView에서 연다.

```text
https://appassets.androidplatform.net/assets/index.html
```

즉, 사용자가 보는 화면은 Android XML 화면이 아니라 APK 안에 포함된 원래의 `index.html`이다. HTML의 CSS와 JavaScript도 그대로 WebView 안에서 실행된다.

## 3. Firebase 연결 방식

`index.html`은 Android 서버를 거치지 않고 Firebase Realtime Database에 직접 연결한다.

- Firebase Web SDK를 CDN에서 로드한다.
- Firebase Authentication으로 로그인·회원가입을 처리한다.
- Firebase Realtime Database에서 `/radar`, `/radar/reservations`, `/bell/latest` 등을 실시간 조회·갱신한다.
- Android 앱에서도 동일한 HTML JavaScript가 실행되므로 웹 버전과 Android 버전의 지도·예약 기능을 공유한다.

```text
WebView의 index.html
        │ Firebase Web SDK / HTTPS
        ▼
Firebase Realtime Database
```

## 4. HTML과 Android Java의 연결

웹만으로 처리하기 어려운 Android 기능은 JavaScript 브리지를 사용한다.

[`MainActivity.java`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/android-app/app/src/main/java/com/bumati/app/MainActivity.java)는 Java 객체를 `BumatiAndroid`라는 이름으로 WebView에 노출한다.

[`BumatiJavascriptBridge.java`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/android-app/app/src/main/java/com/bumati/app/BumatiJavascriptBridge.java)는 다음 기능을 제공한다.

| HTML에서 호출하는 기능 | Android에서 수행하는 작업 |
|---|---|
| `requestNotificationPermission()` | Android 13 이상 알림 권한 요청 |
| `getNotificationPermissionState()` | 현재 알림 권한 상태 반환 |
| `showStopNotification(...)` | 네이티브 하차 알림 표시 |
| `startReservationWatch(...)` | 백그라운드 예약 감시 서비스 시작 |
| `stopReservationWatch()` | 예약 감시 서비스 종료 |

HTML에서는 다음과 같이 브리지를 호출한다.

```javascript
window.BumatiAndroid.startReservationWatch(
  reservationKey,
  stopName,
  sound,
  durationSeconds
);
```

## 5. 백그라운드 하차 알림

WebView가 백그라운드로 내려가면 JavaScript만으로 Firebase 예약을 계속 감시하기 어려울 수 있다. 이를 보완하기 위해 [`BumatiReservationService.java`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/android-app/app/src/main/java/com/bumati/app/BumatiReservationService.java)가 별도로 동작한다.

- Firebase의 예약 경로를 주기적으로 확인한다.
- 예약 정류장 도착 조건을 확인한다.
- 도착하면 [`BumatiNotifications.java`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/android-app/app/src/main/java/com/bumati/app/BumatiNotifications.java)를 통해 소리·진동·알림을 발생시킨다.
- `AndroidManifest.xml`에 인터넷, 알림, 진동, 포그라운드 서비스 권한과 서비스를 등록한다.

## 6. 실제 APK 빌드 명령

[`android-app/build-apk.bat`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/android-app/build-apk.bat)을 실행한다.

```bat
cd android-app
gradlew.bat :app:assembleDebug --no-daemon --console=plain
```

이 명령은 다음을 수행한다.

1. Gradle Wrapper가 Gradle 8.9를 사용한다.
2. Android Gradle Plugin 8.7.3으로 프로젝트를 빌드한다.
3. `preBuild` 단계에서 웹 자산을 복사한다.
4. Java 코드, Android Manifest, 리소스, 웹 자산을 APK로 묶는다.
5. Debug APK를 생성한다.

기본 생성 위치:

```text
android-app/app/build/outputs/apk/debug/app-debug.apk
```

## 7. 발표용 설명

> 부마티 앱은 HTML 웹 앱을 네이티브 앱으로 다시 개발한 것이 아니라, 기존 `index.html`을 Android WebView에 포함하는 하이브리드 구조로 제작했다. Gradle 빌드 과정에서 지도·아이콘·서비스워커 등의 웹 자산을 APK 내부 assets로 복사하고, `MainActivity`가 WebView를 통해 `index.html`을 실행한다. Firebase 통신과 지도 UI는 HTML/JavaScript가 담당하며, Android 알림 권한과 백그라운드 하차 예약 감시는 Java 네이티브 코드가 담당한다.

## 8. 관련 파일

- [`android-app/app/build.gradle`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/android-app/app/build.gradle): 웹 자산 복사 및 Android 빌드 설정
- [`android-app/build-apk.bat`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/android-app/build-apk.bat): APK 빌드 실행 파일
- [`android-app/app/src/main/java/com/bumati/app/MainActivity.java`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/android-app/app/src/main/java/com/bumati/app/MainActivity.java): WebView 실행
- [`android-app/app/src/main/java/com/bumati/app/BumatiJavascriptBridge.java`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/android-app/app/src/main/java/com/bumati/app/BumatiJavascriptBridge.java): HTML–Android 연결
- [`android-app/app/src/main/java/com/bumati/app/BumatiReservationService.java`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/android-app/app/src/main/java/com/bumati/app/BumatiReservationService.java): 백그라운드 예약 감시
- [`index.html`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/index.html): WebView에서 실제 실행되는 웹 앱
