"""
로블록스 스튜디오 없이도 레이더가 잘 동작하는지 테스트하는 시뮬레이터 스크립트입니다.
두 명의 가상 플레이어가 맵 위를 순환하며 좌표를 전송합니다.
실행 방법: python test_sender.py
"""

import json
import math
import time
import urllib.request

SERVER_URL = "http://localhost:8000/api/position"

# 테스트용 월드 중심 및 반경
CENTER_X = (-95 + 960) / 2
CENTER_Z = (-194 + 591) / 2
RADIUS_X = (960 - (-95)) * 0.35
RADIUS_Z = (591 - (-194)) * 0.35

print(f"가상 로블록스 클라이언트 시작! 대상: {SERVER_URL}")
print("종료하려면 Ctrl+C를 누르세요.\n")

angle1 = 0.0
angle2 = math.pi

try:
    while True:
        # 플레이어 1: 원형 궤도
        x1 = CENTER_X + math.cos(angle1) * RADIUS_X
        z1 = CENTER_Z + math.sin(angle1) * RADIUS_Z
        look1 = angle1 + math.pi / 2 # 접선 방향

        # 플레이어 2: 8자 궤도
        x2 = CENTER_X + math.sin(angle2) * (RADIUS_X * 0.8)
        z2 = CENTER_Z + math.sin(angle2 * 2) * (RADIUS_Z * 0.5)
        look2 = angle2

        payload = [
            {
                "id": 1001,
                "name": "RobloxPlayer1",
                "displayName": "루피 (Player 1)",
                "x": round(x1, 1),
                "y": 10.0,
                "z": round(z1, 1),
                "angle": look1,
                "health": 100,
                "maxHealth": 100
            },
            {
                "id": 1002,
                "name": "RobloxPlayer2",
                "displayName": "조로 (Player 2)",
                "x": round(x2, 1),
                "y": 10.0,
                "z": round(z2, 1),
                "angle": look2,
                "health": 85,
                "maxHealth": 100
            }
        ]

        data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            SERVER_URL,
            data=data,
            headers={"Content-Type": "application/json"}
        )

        try:
            with urllib.request.urlopen(req, timeout=1.0) as resp:
                pass
        except Exception as e:
            print(f"전송 실패 (서버가 켜져 있는지 확인하세요): {e}")
            time.sleep(1.0)
            continue

        angle1 += 0.05
        angle2 += 0.03
        time.sleep(0.1)

except KeyboardInterrupt:
    print("\n시뮬레이터를 종료합니다.")
