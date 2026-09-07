# Roblox 하차벨 연결

1. `roblox_script.lua`을 `ServerScriptService`의 Script에 붙여넣고, `TARGET_ROBLOX_USER_NAME`을 실제 Roblox 영어 사용자명으로 맞춥니다.
2. 버스 Model 또는 그 안의 움직이는 Part에 `BUS` 태그를 붙입니다. 버스 Model의 Boolean Attribute `isHighFloor`는 `true`면 고상, `false`면 저상입니다.
3. `micropython_bell_controller.py`을 장치의 `main.py`로 업로드합니다. USB 시리얼 속도는 115200입니다.
4. PC에서 `py -m pip install -r requirements.txt`를 한 번 실행한 뒤, 장치 포트에 맞춰 `py bell_firebase_bridge.py --port COM5`를 실행합니다.
5. 지정 플레이어가 `BUS` 태그 차량의 Seat 또는 VehicleSeat에 앉으면 장치가 자동으로 `MODE HIGH` 또는 `MODE LOW`로 전환됩니다. 하차하면 `MODE IDLE`로 리셋됩니다.

버튼을 누르면 Firebase `/bell/events`에 기록이 추가되고, `/bell/latest`에는 가장 최근 이벤트가 저장됩니다. 두 값에는 버튼 종류와 탑승 버스의 노선, 고상 여부, 최신 `x/y/z` 좌표가 들어갑니다.

Firebase 규칙은 Roblox와 브리지 PC가 `/radar`, `/bell`에 읽기·쓰기를 할 수 있어야 합니다. 실제 공개 서비스에서는 인증 기반 규칙으로 제한하세요.
