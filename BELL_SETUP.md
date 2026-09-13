# Roblox 하차벨 & 정류장 하차 예약 연동 가이드

## 1. 기본 설정 및 설치

1. `roblox_script.lua`를 로블록스 스튜디오의 `ServerScriptService` 아래에 `Script`로 붙여넣고, `TARGET_ROBLOX_USER_NAME`을 본인의 실제 Roblox 영어 사용자명(Player.Name)으로 설정합니다.
2. 로블록스 상단 메뉴 **[Game Settings] -> [Security] -> "Allow HTTP Requests"** 를 **ON**으로 활성화합니다.
3. 최신 `micropython_bell_controller.py`를 피지컬 하차벨 보드(Raspberry Pi Pico 등)의 `main.py`로 업로드합니다. (시리얼 보드레이트: 115200)
4. PC에서 의존성을 설치한 뒤 브리지를 실행합니다:
   ```bash
   py -m pip install -r requirements.txt
   py bell_firebase_bridge.py --port COM5
   ```
   *(포트 번호는 장치가 연결된 실제 포트로 지정하세요)*

### 인게임 버스 선택/소환

버스 선택 기능은 기존 Firebase 스크립트와 별도로 다음 두 스크립트를 추가합니다.

1. `ReplicatedStorage` 아래에 `BusModels`라는 **Folder**를 만들고, 소환할 버스 **Model**들을 그 안으로 옮깁니다.
2. 버스가 소환될 별도 파트는 필요하지 않습니다. 플레이어가 바라보는 수평 방향 앞쪽 24 studs, 약 3 studs 위에 미리보기가 나타납니다.
3. `bus_spawner_server.lua`를 `ServerScriptService` 아래의 **Script**에 붙여넣습니다.
4. `bus_spawner_client.lua`를 `StarterPlayer > StarterPlayerScripts` 아래의 **LocalScript**에 붙여넣습니다.
5. 플레이 중 **B**를 누르면 `BusModels` 안의 목록이 열립니다. 버스를 선택하면 앞쪽에 윤곽선 미리보기가 나타납니다. **R**로 15도씩 회전하고 **T**로 확정 설치합니다. **B** 또는 **Esc**로 취소할 수 있습니다. 확정하면 기존에 본인이 소환한 버스가 삭제됩니다.

각 버스 Model은 기존 레이더/하차벨 인식과 함께 사용하려면 내부에 차체 `BasePart`가 하나 이상 있어야 합니다. `BUS` 태그는 소환 서버가 자동으로 붙입니다.

### 피지컬 벨 ↔ Roblox 양방향 연동

- Roblox의 `ProximityPrompt` 또는 자동 예약 벨이 울리면 Roblox가 Firebase `/bell/latest`에 `source = roblox` 이벤트를 기록하고, PC 브리지가 보드로 `BELL A` 명령을 보냅니다.
- 피지컬 A/B 버튼을 누르면 보드가 `BELL_EVENT`를 USB 시리얼로 보내고, PC 브리지가 Firebase에 `source = physical` 이벤트를 기록합니다. Roblox가 이 이벤트를 읽어 게임 안의 탑승 버스 벨도 울립니다.
- 물리 이벤트를 Roblox에서 다시 Firebase로 되쏘지 않도록 `source`와 `eventId`로 무한 반복을 차단합니다.
- 양방향 연동을 사용하려면 `roblox_script.lua`, `micropython_bell_controller.py`, `bell_firebase_bridge.py`를 각각 최신 버전으로 적용해야 합니다. 기존에 Studio나 보드에 올린 파일은 자동으로 바뀌지 않습니다.

---

## 2. 버스 탑승 및 고상/저상 인식 설정

1. **BUS 태그 부여**:
   - 버스 Model 또는 지도 추적용 기준 Part에 `BUS` 태그(CollectionService)를 붙입니다.
2. **`BUSin` 탑승 영역 태그 또는 비충돌 파트 인식 (모델 속 모델 완벽 지원)**:
   - 버스 모델 내부의 바닥/발판 등 플레이어가 딛는 파트에 **`BUSin`** 태그(CollectionService)를 붙이면, 해당 파트에 플레이어가 닿거나 위에 서 있을 때 즉시 해당 버스 탑승으로 자동 인식됩니다.
   - **모델 안에 모델이 몇 겹으로 중첩(예: `BusModel` ➡️ `Interior` ➡️ `Floors` ➡️ `FloorPart`)되어 있어도**, 조상 트리를 자동으로 거슬러 올라가 최상위 `BUS` 차량을 찾아내므로 완벽하게 인식됩니다.
   - 기존의 `CanCollide = false`, `CanQuery = false` 바닥 파트 및 좌석(Seat) 착석도 계속 동시 지원됩니다.
3. **고상 / 저상 속성 설정 (Boolean 또는 문자열/태그 지원)**:
   - 버스 Model 또는 해당 Part에 `isHighFloor` 속성을 추가합니다:
     - `isHighFloor = true` (또는 `고상 = true`, 문자열 `"high"`, `"고상"`): **고상버스**
     - `isHighFloor = false` (또는 `저상 = true`, 문자열 `"low"`, `"저상"`): **저상버스**
     - 태그(`HIGH_FLOOR`, `고상`) 또는 Value 객체(`BoolValue`, `StringValue`)로 설정해도 완벽 인식됩니다.

### 하차벨 동작 방식
- **올라탔을 때 이미 하차벨이 켜진 상태 (무음 점등 `SILENT_BELL`)**:
  - 버스에 탑승했을 때 이미 게임 내에서 다른 승객이나 자동 예약에 의해 하차벨이 켜져 있는 경우, **부저 소리(딩동/삐-)는 울리지 않고 피지컬 램프와 릴레이만 조용히 켜집니다**.
  - 탑승 이후 새로 벨을 누르거나 울릴 때만 정상적으로 부저 소리가 납니다.
- **인게임 신호 실시간 소등 연동 (자동 30초 OFF 제거)**:
  - 승객이나 로블록스 인게임에서 하차벨이 울리면 피지컬 벨도 켜지고, **게임 안에서 하차벨 불이 꺼지면(기사석 리셋, 문 개폐 등) 피지컬 하차벨 불과 부저도 즉시 소등**됩니다.
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
   - 여러 노선에서 같은 실제 정류장을 함께 쓸 때는 각 Part/Model의 Attribute에 `StopId`(권장), `StopNumber`, `StationId`, 또는 `정류장고유번호`를 동일하게 입력하세요. 같은 고유 번호는 지도에서 핀 하나로 합쳐지며, 하차 예약도 이 번호를 기준으로 정확히 작동합니다.
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



