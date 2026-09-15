# 부마티(BUMATI) 시스템 구동 파일 정리

> 목적: PPT에 바로 옮겨 넣을 수 있도록, 저장소에서 실제 시스템 실행에 관여하는 파일과 파일 간 연결을 정리한다.
>
> 기준: 소스 코드의 참조 관계와 실행 설정을 기준으로 분류했다. Firebase Realtime Database와 Roblox Studio는 저장소 외부의 실행 요소다.

## 1. 시스템 전체 구조

```text
[Roblox 게임]
  roblox_script.lua + 보조 Lua 스크립트
          │  HTTPS(JSON)
          ▼
[Firebase Realtime Database]
  /radar, /radar/reservations, /radar/bell, /bell/latest, /bell/events
       ▲                         │
       │                         │ HTTPS 실시간 조회
       │                         ▼
[웹 지도] index.html ──────── [PC 브리지] bell_firebase_bridge.py
       │                              │ USB Serial
       │                              ▼
       │                    [MicroPython 보드]
       │                    micropython_bell_controller.py
       │
       └─ Android 빌드 시 WebView + 네이티브 알림 서비스로 패키징
          MainActivity.java / BumatiReservationService.java
```

핵심 흐름은 다음과 같다.

1. Roblox 서버 스크립트가 플레이어·버스·정류장·벨·예약 상태를 Firebase에 전송한다.
2. `index.html`이 Firebase를 실시간 구독하여 지도, 버스, 예약, 하차벨 상태를 화면에 표시한다.
3. 물리 하차벨은 MicroPython 보드가 감지하고, PC 브리지가 Firebase의 `/bell/latest`로 전달한다.
4. Roblox와 웹 앱은 `/bell/latest`의 이벤트를 받아 게임 내 벨 또는 화면 알림을 갱신한다.
5. Android 앱은 동일한 웹 화면을 WebView로 표시하고, 예약 하차 알림은 네이티브 포그라운드 서비스가 보완한다.

## 2. 실행 진입점

| 파일 | 실행 위치 | 역할 |
|---|---|---|
| [`run.bat`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/run.bat) | Windows PC | `index.html`을 기본 브라우저로 열어 웹 지도를 시작한다. 별도 Python 웹 서버는 실행하지 않는다. |
| [`index.html`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/index.html) | 브라우저 / Android WebView | 부마티의 실질적인 프론트엔드 본체. Firebase 인증·실시간 데이터·지도 렌더링·예약·벨 알림을 모두 포함한다. |
| [`bell_firebase_bridge.py`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/bell_firebase_bridge.py) | 하차벨 연결 PC | USB 시리얼과 Firebase 사이를 중계한다. `py bell_firebase_bridge.py --port COM5`로 실행한다. |
| [`micropython_bell_controller.py`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/micropython_bell_controller.py) | MicroPython 보드 | A/B 물리 버튼, LED/릴레이, 부저를 제어하고 USB 시리얼로 이벤트·명령을 주고받는다. |
| [`roblox_script.lua`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/roblox_script.lua) | Roblox Studio `ServerScriptService` | Roblox 월드의 핵심 서버 로직. Firebase 레이더 데이터 전송, 예약 처리, 게임 벨, 물리 벨 연동을 담당한다. |

## 3. 웹 앱 핵심 파일

### `index.html`

- Firebase Web SDK를 CDN에서 로드한다: `firebase-app`, `firebase-auth`, `firebase-database`.
- Firebase Authentication으로 회원가입·로그인·로그아웃·계정 삭제를 처리한다.
- Firebase Realtime Database의 주요 경로를 사용한다.
  - `/radar`: Roblox가 전송한 플레이어·버스·정류장·벨 통합 상태
  - `/radar/bell`: 현재 탑승 버스와 고상/저상 및 벨 상태
  - `/radar/reservations`: 하차 예약 저장·조회·취소·자동 처리
  - `/bell/latest`: 가장 최근 물리/게임 벨 이벤트
  - `/bell/events`: 벨 이벤트 이력
- Canvas 기반 지도에 현재 위치, 버스, 정류장, 이동 방향을 렌더링한다.
- 버스 선택, 노선·방향 식별, 고상/저상 판정, 탑승 상태, 하차 예약 UI를 제공한다.
- 예약 정류장 접근 시 화면·진동·소리 알림을 표시한다.
- Android WebView가 제공하는 `window.BumatiAndroid` 브리지를 통해 알림 권한 요청 및 백그라운드 예약 감시를 시작·종료한다.

### [`manifest.json`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/manifest.json)

- 웹 앱의 이름, 아이콘, 시작 방식, 화면 표시 모드를 정의한다.
- PWA 설치 및 Android WebView 패키징에 사용된다.

### [`sw.js`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/sw.js)

- 지도 이미지·HTML·아이콘을 브라우저 캐시에 저장한다.
- 같은 출처의 정적 파일은 캐시 우선으로 제공하고 네트워크에서 최신 파일을 갱신한다.
- Firebase 등 외부 요청은 캐시하지 않고 네트워크로 통과시킨다.
- `CACHE_NAME` 버전이 변경되면 기존 서비스워커 캐시를 정리한다.

### 웹 정적 리소스

| 파일 | 사용처 |
|---|---|
| `image/realmap.png` | 실제 지도 배경. `index.html` Canvas 렌더링 및 `sw.js` 캐시 대상 |
| `image/map.png` | 지도 관련 보조 이미지 |
| `부마티 로고.png` | 웹 로딩 화면 및 Android 웹 자산 |
| `icons/icon-192.png`, `icons/icon-512.png`, `icons/apple-touch-icon.png`, `icons/icon.svg` | PWA·런처·홈 화면 아이콘 |

## 4. Roblox 게임 서버 파일

### [`roblox_script.lua`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/roblox_script.lua) — 필수 핵심 서버 스크립트

Roblox `ServerScriptService`에 설치하는 중심 파일이다.

- `HttpService`로 Firebase Realtime Database와 HTTPS 통신한다.
- `BUS` 태그·속성·모델을 탐색하여 버스의 위치, 방향, 노선, 차량번호, 고상/저상 정보를 수집한다.
- `BUS_STOP` 계열 태그와 정류장 속성을 분석하여 정류장 목록과 순서를 만든다.
- 특정 Roblox 사용자 위치를 포함한 레이더 payload를 `/radar`에 전송한다.
- `/radar/bell`에 실제 탑승 버스 컨텍스트를 기록해 물리 벨 브리지에 제공한다.
- 게임 내 하차벨을 감지·점등·소등하고, 대상 버스의 벨 이벤트를 `/bell/latest` 및 `/bell/events`에 기록한다.
- `/bell/latest`를 고속 폴링하여 물리 하차벨 입력을 게임 내 벨로 재생한다.
- `/radar/reservations`를 폴링하여 목표 정류장 접근 시 자동 하차벨을 작동시킨다.
- `BusRouteDirectionRequest` RemoteEvent를 생성하여 운행 방향 GUI와 연결한다.
- Roblox Studio에서 `Allow HTTP Requests`를 켜야 Firebase 연동이 동작한다.

### 운행·버스 조작 보조 파일

| 파일 | Roblox 설치 위치 | 역할 | 운영상 중요도 |
|---|---|---|---|
| [`driver_route_gui.client.lua`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/driver_route_gui.client.lua) | `StarterPlayer > StarterPlayerScripts` | 운전자가 버스 운행 방향(상행/하행)을 선택하고 시작·종료한다. `roblox_script.lua`의 RemoteEvent 사용 | 기능 사용 시 필요 |
| [`bus_spawner_server.lua`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/bus_spawner_server.lua) | `ServerScriptService` | `ReplicatedStorage.BusModels`의 허용 모델만 서버에서 소환하고, 거리·쿨다운·중복 소환을 검증한다. | 버스 소환 기능 사용 시 필요 |
| [`bus_spawner_client.lua`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/bus_spawner_client.lua) | `StarterPlayer > StarterPlayerScripts` | B키 버스 선택 UI와 미리보기·소환 요청을 담당한다. | 버스 소환 기능 사용 시 필요 |
| [`stop_announcement_server.lua`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/stop_announcement_server.lua) | `ServerScriptService` | 버스가 정류장 트리거에 접촉하면 StopId에 맞는 안내 음성을 재생한다. | 정류장 안내 방송 사용 시 필요 |
| [`named_spawn_server.lua`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/named_spawn_server.lua) | `ServerScriptService` | 설정된 플레이어를 이름별 지정 Spawn Part로 이동시킨다. | 운영 편의 기능 |
| [`admin_fly_server.lua`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/admin_fly_server.lua) | `ServerScriptService` | 관리자 여부를 서버에서 검증하고 관리자 RemoteFunction·RemoteEvent를 만든다. | 관리자 기능 사용 시 필요 |
| [`admin_fly_client.lua`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/admin_fly_client.lua) | `StarterPlayer > StarterPlayerScripts` | 관리자만 비행·투명화·월드 초기화 기능을 사용하도록 입력과 UI를 처리한다. | 관리자 기능 사용 시 필요 |

## 5. 물리 하차벨 파일

### [`micropython_bell_controller.py`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/micropython_bell_controller.py)

- MicroPython 보드의 GPIO를 직접 제어한다.
- A벨·B벨 입력, A/B LED, 릴레이, A/B 부저를 분리 제어한다.
- `MODE LOW`, `MODE HIGH`, `MODE IDLE` 명령으로 저상·고상·대기 모드를 전환한다.
- `BELL A`, `BELL B`, `RESET` 명령으로 원격 벨 점등·소등을 수행한다.
- 물리 버튼을 누르면 `BELL_EVENT {JSON}` 형식으로 PC 브리지에 전송한다.
- Latch 방식으로 점등 상태를 유지하며, 고상/저상 버스에 따라 A/B 출력 조합을 다르게 처리한다.

### [`bell_firebase_bridge.py`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/bell_firebase_bridge.py)

- `pyserial`로 MicroPython 보드의 USB Serial을 읽고 쓴다.
- 물리 버튼 이벤트를 `/bell/latest`에 즉시 PUT하고 `/bell/events`에 이력으로 POST한다.
- Firebase `/bell/latest`를 고속 폴링해 Roblox에서 발생한 벨 이벤트를 보드에 전달한다.
- `/radar/bell`의 탑승 컨텍스트에 따라 보드 모드를 LOW/HIGH/IDLE로 바꾼다.
- 네트워크 지연이나 순간적인 탑승 판정 흔들림으로 벨이 오작동하지 않도록 stale grace·연속 확인·이벤트 중복 방지 로직을 둔다.
- 실행 예: `py bell_firebase_bridge.py --port COM5`

### [`requirements.txt`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/requirements.txt)

- PC 브리지 실행에 필요한 Python 외부 의존성인 `pyserial`을 선언한다.
- 웹 앱과 Roblox 스크립트는 별도의 Python 패키지를 필요로 하지 않는다.

## 6. Android 앱 파일

Android 앱은 웹 앱을 새로 구현하는 구조가 아니라, 저장소 루트의 웹 자산을 WebView에 포함하는 래퍼 구조다.

| 파일 | 역할 |
|---|---|
| [`android-app/app/src/main/java/com/bumati/app/MainActivity.java`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/android-app/app/src/main/java/com/bumati/app/MainActivity.java) | WebView 생성, JavaScript·DOM Storage 활성화, 로컬 웹 자산 로드, `BumatiAndroid` JavaScript 브리지 등록 |
| [`android-app/app/src/main/java/com/bumati/app/BumatiJavascriptBridge.java`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/android-app/app/src/main/java/com/bumati/app/BumatiJavascriptBridge.java) | Android 13 이상 알림 권한 요청과 권한 상태를 JavaScript에 제공 |
| [`android-app/app/src/main/java/com/bumati/app/BumatiReservationService.java`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/android-app/app/src/main/java/com/bumati/app/BumatiReservationService.java) | 앱이 백그라운드에 있어도 Firebase 예약 노드를 주기적으로 확인하고 도착 시 알림을 발생시키는 포그라운드 서비스 |
| [`android-app/app/src/main/java/com/bumati/app/BumatiNotifications.java`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/android-app/app/src/main/java/com/bumati/app/BumatiNotifications.java) | 예약 감시용·하차 알림용 Notification Channel과 진동·소리·알림 UI를 생성 |
| [`android-app/app/src/main/AndroidManifest.xml`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/android-app/app/src/main/AndroidManifest.xml) | 인터넷, 알림, 진동, 포그라운드 서비스 권한과 `BumatiReservationService` 등록 |
| [`android-app/app/build.gradle`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/android-app/app/build.gradle) | Android 빌드 설정. `syncWebAssets`가 루트의 `index.html`, `manifest.json`, `sw.js`, 이미지, 아이콘을 APK 자산으로 복사한다. |
| [`android-app/build-apk.bat`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/android-app/build-apk.bat) | Gradle을 이용해 Android APK를 빌드하는 실행 스크립트 |

## 7. 운영에 직접 사용하지 않는 파일

| 파일 | 구분 |
|---|---|
| [`test_firebase_sender.py`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/test_firebase_sender.py) | Firebase 데이터 송신 테스트용. 실제 운영 경로에는 포함되지 않는다. |
| [`BELL_SETUP.md`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/BELL_SETUP.md) | 하차벨 설치·설정 안내 문서. 실행 파일은 아니다. |
| [`android-app/README.md`](C:/Users/sgwcr/OneDrive/ドキュメント/GitHub/bomati/android-app/README.md) | Android 빌드 안내 문서. 실행 로직은 아니다. |
| `bu-mati_presentation_revised.md` | 발표 자료 원고. 시스템 실행에는 사용되지 않는다. |
| `bumati_four_panel_comic.png`, `부마티 로고.png`, `image/**`, `icons/**` | 일부는 실행 화면·캐시에 사용되지만, 로직을 실행하는 코드는 아니다. |
| `android-app/BOMATI-170-debug.apk` | 이미 빌드된 배포 산출물. 소스 실행 경로가 아니라 결과물이다. |

## 8. PPT용 한 장 요약

### 실제 구동 핵심 파일 8개

1. `run.bat` — 웹 앱 실행 진입점
2. `index.html` — 지도·인증·예약·벨 UI 및 Firebase 실시간 클라이언트
3. `sw.js` — 정적 자산 캐시 및 PWA 오프라인 보완
4. `roblox_script.lua` — Roblox 서버와 Firebase를 연결하는 핵심 로직
5. `bell_firebase_bridge.py` — PC와 Firebase 사이의 하차벨 중계
6. `micropython_bell_controller.py` — 물리 버튼·LED·릴레이·부저 제어
7. `MainActivity.java` + `BumatiReservationService.java` — Android WebView 및 백그라운드 예약 알림
8. `android-app/app/build.gradle` — 웹 자산을 Android 앱에 포함시키는 빌드 연결부

### 외부 실행 요소

- Firebase Realtime Database: 중앙 실시간 상태 저장소
- Roblox Studio: Lua 스크립트가 실행되는 게임 서버
- MicroPython 보드와 USB Serial: 물리 하차벨 장치
- Android OS 알림 시스템: 백그라운드 하차 알림 표시

