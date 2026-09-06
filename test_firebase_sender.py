"""
Firebase Realtime Database 좌표 전송 모의 테스트 스크립트입니다.
로블록스 스튜디오 없이도 본인의 Firebase DB와 웹앱이 잘 연동되는지 테스트할 수 있습니다.
사용법: python test_firebase_sender.py https://[내-프로젝트]-default-rtdb.firebaseio.com
"""

import json
import math
import sys
import time
import urllib.request

if len(sys.argv) > 1:
    db_url = sys.argv[1].rstrip("/")
else:
    db_url = input("Firebase Realtime Database URL을 입력하세요 (예: https://xxx-default-rtdb.firebaseio.com): ").strip().rstrip("/")

if not db_url.startswith("http"):
    db_url = "https://" + db_url

endpoint = f"{db_url}/players.json"

# 새 맵 (realmap) 중심 좌표
# X: -2838 ~ 1108, Z: 432 ~ 2531
CENTER_X = (-2838 + 1108) / 2
CENTER_Z = (432 + 2531) / 2
RADIUS_X = (1108 - (-2838)) * 0.35
RADIUS_Z = (2531 - 432) * 0.35

print("=" * 60)
print(f"🔥 Firebase 모의 전송 시작! 대상: {endpoint}")
print(" 웹 브라우저 레이더를 열어두고 움직임을 확인하세요. (종료: Ctrl+C)")
print("=" * 60)

angle1 = 0.0
angle2 = math.PI

try:
    while True:
        x1 = CENTER_X + math.cos(angle1) * RADIUS_X
        z1 = CENTER_Z + math.sin(angle1) * RADIUS_Z
        look1 = angle1 + math.PI / 2

        x2 = CENTER_X + math.sin(angle2) * (RADIUS_X * 0.8)
        z2 = CENTER_Z + math.sin(angle2 * 2) * (RADIUS_Z * 0.5)
        look2 = angle2

        payload = [
            {
                "id": 2001,
                "name": "FirebaseLuffy",
                "displayName": "루피 (가상 1)",
                "x": round(x1, 1),
                "y": 10.0,
                "z": round(z1, 1),
                "angle": look1,
                "health": 100,
                "maxHealth": 100,
                "timestamp": int(time.time())
            },
            {
                "id": 2002,
                "name": "FirebaseZoro",
                "displayName": "조로 (가상 2)",
                "x": round(x2, 1),
                "y": 10.0,
                "z": round(z2, 1),
                "angle": look2,
                "health": 90,
                "maxHealth": 100,
                "timestamp": int(time.time())
            }
        ]

        data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            endpoint,
            data=data,
            headers={"Content-Type": "application/json"},
            method="PUT"
        )

        try:
            with urllib.request.urlopen(req, timeout=3.0) as resp:
                print(f"\r[OK] {time.strftime('%H:%M:%S')} 좌표 전송 성공 (플레이어 2명)", end="", flush=True)
        except Exception as e:
            print(f"\n[실패] Firebase 전송 오류: {e}")
            print("규칙(.write: true) 및 Database URL 주소를 다시 확인하세요.")
            time.sleep(2.0)
            continue

        angle1 += 0.06
        angle2 += 0.04
        time.sleep(0.35)

except KeyboardInterrupt:
    print("\n\n모의 전송을 종료합니다.")
