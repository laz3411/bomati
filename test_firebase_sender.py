"""
Firebase Realtime Database 좌표 전송 모의 테스트 스크립트입니다.
로블록스 스튜디오 없이도 본인의 Firebase DB와 웹앱(index.html)이 잘 연동되는지 테스트할 수 있습니다.
사용법:
    python test_firebase_sender.py [Firebase URL]
"""

import json
import math
import sys
import time
import urllib.request

DEFAULT_FIREBASE_URL = "https://bumati-default-rtdb.asia-southeast1.firebasedatabase.app"

if len(sys.argv) > 1:
    db_url = sys.argv[1].rstrip("/")
else:
    db_url = DEFAULT_FIREBASE_URL

if not db_url.startswith("http"):
    db_url = "https://" + db_url

radar_endpoint = f"{db_url}/radar.json"
players_endpoint = f"{db_url}/players.json"

# 새 맵 (realmap) 중심 좌표
# X: -2838 ~ 1108, Z: 432 ~ 2531
CENTER_X = (-2838 + 1108) / 2
CENTER_Z = (432 + 2531) / 2
RADIUS_X = (1108 - (-2838)) * 0.35
RADIUS_Z = (2531 - 432) * 0.35

print("=" * 60)
print(f"🔥 Firebase 모의 전송 시작! 대상: {radar_endpoint}")
print(" 웹 브라우저에서 index.html을 열어두고 움직임을 확인하세요. (종료: Ctrl+C)")
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

        now_ms = int(time.time() * 1000)

        players_payload = [
            {
                "id": 2001,
                "name": "laz3411",
                "displayName": "laz3411",
                "x": round(x1, 1),
                "y": 10.0,
                "z": round(z1, 1),
                "angle": look1,
                "health": 100,
                "maxHealth": 100,
                "timestamp": now_ms
            },
            {
                "id": 2002,
                "name": "beargobearman",
                "displayName": "베어맨",
                "x": round(x2, 1),
                "y": 10.0,
                "z": round(z2, 1),
                "angle": look2,
                "health": 95,
                "maxHealth": 100,
                "timestamp": now_ms
            }
        ]

        buses_payload = [
            {
                "id": "Workspace.2017 Hyundai New Super Aero City F/L CNG",
                "name": "2017 Hyundai New Super Aero City F/L CNG",
                "route": "115",
                "floorType": "low",
                "isHighFloor": False,
                "x": round(x1 + 35, 1),
                "y": 6.9,
                "z": round(z1 + 35, 1),
                "angle": look1,
                "isBellRinging": False,
                "timestamp": now_ms,
                "allStops": [
                    {"index": 1, "name": "정류장 1", "x": 1073.6, "y": 0.5, "z": 1373.9, "distance": 120.0},
                    {"index": 2, "name": "정류장 2", "x": 1073.6, "y": 0.5, "z": 758.7, "distance": 450.0}
                ],
                "upcomingStops": [
                    {"index": 2, "name": "정류장 2", "x": 1073.6, "y": 0.5, "z": 758.7, "distance": 450.0}
                ]
            }
        ]

        radar_payload = {
            "players": players_payload,
            "buses": buses_payload,
            "bell": {"active": False, "timestamp": now_ms},
            "timestamp": now_ms
        }

        # 1. /radar.json 전송 (통합 데이터)
        data = json.dumps(radar_payload).encode("utf-8")
        req = urllib.request.Request(
            radar_endpoint,
            data=data,
            headers={"Content-Type": "application/json"},
            method="PUT"
        )

        try:
            with urllib.request.urlopen(req, timeout=3.0) as resp:
                print(f"\r[OK] {time.strftime('%H:%M:%S')} 레이더 전송 성공 (플레이어 2명, 버스 1대)", end="", flush=True)
        except Exception as e:
            print(f"\n[실패] Firebase 전송 오류: {e}")
            time.sleep(2.0)
            continue

        angle1 += 0.06
        angle2 += 0.04
        time.sleep(0.35)

except KeyboardInterrupt:
    print("\n\n모의 전송을 종료합니다.")
