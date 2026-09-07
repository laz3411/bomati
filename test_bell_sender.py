"""하차벨 Firebase 연동 테스트 스크립트.
로블록스를 켜지 않고도 탑승/하차 신호를 전송하여
마이크로파이썬 하차벨의 점등, 소등, 리셋 작동을 테스트할 수 있습니다.
사용법: py test_bell_sender.py
"""
import json
import time
import urllib.request

FIREBASE_URL = "https://bumati-default-rtdb.asia-southeast1.firebasedatabase.app"
ENDPOINT = f"{FIREBASE_URL}/radar/bell.json"

def send_bell_state(active, is_high_floor=False, bus_name="테스트 버스"):
    payload = {
        "active": active,
        "mode": "high" if is_high_floor else "low",
        "busId": "Workspace.TestBus",
        "busName": bus_name,
        "route": "100",
        "isHighFloor": is_high_floor,
        "x": 100.0,
        "y": 15.0,
        "z": 200.0,
        "timestamp": int(time.time() * 1000)
    }
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(ENDPOINT, data=data, method="PUT", headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=5) as resp:
        state_str = "하차벨 활성화 (탑승)" if active else "하차벨 소등/리셋 (하차)"
        print(f"[전송 완료] active={active}, mode={payload['mode']} -> {state_str}")

print("=" * 60)
print("  하차벨 탑승/하차 모의 테스트 도구")
print("  1: 저상버스 탑승 (하차벨 ON - B벨 소리/불)")
print("  2: 고상버스 탑승 (하차벨 ON - A벨 소리/릴레이 불)")
print("  3: 버스 하차 (하차벨 OFF - 모든 불 소등 및 대기 리셋)")
print("  q: 종료")
print("=" * 60)

while True:
    try:
        cmd = input("\n선택 (1: 저상탑승, 2: 고상탑승, 3: 하차/소등, q: 종료): ").strip().lower()
        if cmd == "1":
            send_bell_state(True, False, "현대 저상버스")
        elif cmd == "2":
            send_bell_state(True, True, "대우 고상버스")
        elif cmd == "3":
            send_bell_state(False)
        elif cmd in ("q", "exit"):
            break
    except KeyboardInterrupt:
        break
