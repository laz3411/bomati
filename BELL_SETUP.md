# Roblox 하차벨 & 정류장 하차 예약 연동 가이드

## 1. 기본 설정 및 설치

1. `roblox_script.lua`를 로블록스 스튜디오의 `ServerScriptService` 아래에 `Script`로 붙여넣고, `TARGET_ROBLOX_USER_NAME`을 본인의 실제 Roblox 영어 사용자명(Player.Name)으로 설정합니다.
2. 로블록스 상단 메뉴 **[Game Settings] -> [Security] -> "Allow HTTP Requests"** 를 **ON**으로 활성화합니다.
3. `micropython_bell_controller.py`를 피지컬 하차벨 보드(Raspberry Pi Pico 등)의 `main.py`로 업로드합니다. (시리얼 보드레이트: 115200)
4. PC에서 의존성을 설치한 뒤 브리지를 실행합니다:
   ```bash
   py -m pip install -r requirements.txt
   py bell_firebase_bridge.py --port COM5
   ```
   *(포트 번호는 장치가 연결된 실제 포트로 지정하세요)*

---

## 2. 버스 탑승 및 고상/저상 인식 설정

1. **BUS 태그 부여**:
   - 버스 Model 또는 지도 추적용 기준 Part에 `BUS` 태그(CollectionService)를 붙입니다.
2. **비충돌(CanCollide=false, CanQuery=false) 탑승 영역 인식**:
   - 버스 내부의 바닥/발판 등 `CanCollide = false`, `CanQuery = false`로 설정된 파트에 플레이어가 닿거나 위에 서 있으면 자동으로 해당 버스 탑승으로 인식됩니다. (기존 좌석 착석도 계속 동시 지원)
3. **고상 / 저상 속성 설정 (Boolean Attribute)**:
   - 버스 Model 또는 해당 Part에 `isHighFloor` 속성을 추가합니다:
     - `isHighFloor = true` (또는 `고상 = true`): **고상버스**
     - `isHighFloor = false` (또는 `저상 = true`): **저상버스**

### 하차벨 동작 방식
- **저상버스 (`MODE LOW`)**:
  - **하차벨 A (일반벨)**: 부저 A(딩동딩동) + 릴레이 ON + LED A 점등 (독립 작동)
  - **하차벨 B (교통약자/휠체어벨)**: 부저 B(삐-) + LED B 점등 (독립 작동)
- **고상버스 (`MODE HIGH`)**:
  - **하차벨 A와 B가 함께 연동 작동**:
    - A벨을 누르든 B벨을 누르든 **부저 A(딩동딩동) + 릴레이 ON + LED A & B 동시 점등**
- **하차 및 미탑승 시 (`MODE IDLE`)**:
  - 버스에서 내리면 정확히 **1.0초 뒤 연동이 자동 해제**됩니다.
  - 모든 하차벨 불이 즉시 소등되며, 부저가 멈추고 다시 버스에 탑승할 때까지 버튼 입력이 무시됩니다.

---

## 3. 정류장 노선 폴더 및 남은 정류장 자동 필터링

1. **노선 폴더 생성**:
   - 로블록스 `Workspace` 바로 아래에 버스의 `route` 속성값(예: `100`, `720`, `M4101` 등)과 **동일한 이름의 Folder**를 생성합니다.
   - 버스 Model의 `route` Attribute와 폴더 이름이 매칭되어 정류장 목록을 읽어옵니다.
2. **정류장 파트 배치 및 자연수 번호 부여**:
   - 폴더 내부에 정류장 위치를 나타내는 Part(또는 Model)를 자연수 번호 순서대로 이름을 붙여 넣습니다:
     - 예: `1`, `2`, `3`, `4`... 또는 `Point1`, `Point2`, `Point3`...
     - 정류장 인스턴스에 `StopName` 또는 `정류장명` Attribute(속성)를 추가하면 해당 정류장 이름이 웹 지도와 UI에 표시됩니다.
3. **버스 앞/뒤 인식 파트 (`BUS_FRONT`, `BUS_BACK`)**:
   - 버스 모델 내부의 앞쪽 파트에 `BUS_FRONT`, 뒤쪽 파트에 `BUS_BACK` 태그를 지정해 두면 버스의 전진 방향 벡터가 계산됩니다.
   - 버스가 이동하면서 전진 방향과 정류장의 위치 관계(내적 및 거리)를 바탕으로, **이미 지나간 정류장과 현재 머무는 정류장은 자동 제외**되고 **다음 남은 정류장 목록**만 웹 지도 하차 예약에 노출됩니다.

---

## 4. 로블록스 인게임 하차벨 스크립트 일원화 (통합 관리)

> **기존의 각 버튼(`Point1` ~ `Point19`)마다 개별적으로 들어가 있던 스크립트를 모두 제거하셔도 됩니다!**

`roblox_script.lua`가 버스 내부의 모든 하차벨 버튼과 조명, 사운드를 중앙에서 자동으로 관리합니다:
- **자동 탐색 대상**:
  - 버스 내 모든 `ProximityPrompt` (예: `Point1.ProximityPrompt`, `Point2.ProximityPrompt` 등)
  - `Main.Bell` (하차벨 사운드)
  - `Main.Light`, `Main.Light2` (하차벨 조명 BasePart 또는 Light)
- **동작 방식**:
  - 어떤 하차벨 버튼이든 승객이 누르면:
    1. 버스 내 모든 `ProximityPrompt`가 일괄 비활성화(`Enabled = false`)됩니다.
    2. `Main.Bell:Play()`로 하차벨 사운드가 울립니다.
    3. `Main.Light` 및 `Main.Light2`의 `Transparency = 0`(또는 `Enabled = true`)으로 불이 켜집니다.
    4. Firebase `/bell/events` 및 `/bell/latest`로 이벤트가 전송되어 피지컬 하차벨 기기에도 즉시 동기화됩니다.

---

## 5. 웹 지도(`index.html`) 하차 예약 및 자동 하차벨

1. **지도에서 버스 터치 / 선택**:
   - 지도 화면에서 버스 마커를 클릭(또는 터치)하면 하단에 **하차 예약 시트**가 열립니다.
   - 현재 정류장을 제외한 **다음 남은 정류장 목록**이 표시됩니다.
2. **하차 예약 버튼 클릭**:
   - 내리고 싶은 정류장의 **[하차 예약]** 버튼을 누르면 Firebase에 예약(`radar/reservations`)이 등록되며, 지도 상의 해당 정류장에 황금빛 알림 링이 표시됩니다.
3. **예약 정류장 접근 시 자동 하차벨 작동**:
   - 버스가 이동하여 예약된 정류장의 **반경 65 studs 이내에 진입**하면:
     - 로블록스 인게임의 `Main.Bell` 사운드 및 조명 점등이 **자동으로 작동**합니다.
     - 피지컬 하차벨 기기에도 신호가 전달되어 벨이 울립니다.
     - 웹 화면 상단에 `🔔 [목표 정류장] 접근 중! 하차벨이 자동으로 울렸습니다.` 알림 배너가 뜹니다.



