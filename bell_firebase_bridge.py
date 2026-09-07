"""USB 하차벨과 Firebase를 연결하는 PC 브리지.

예시:
    py -m pip install -r requirements.txt
    py bell_firebase_bridge.py --port COM5
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

import serial


DEFAULT_FIREBASE_URL = "https://bumati-default-rtdb.asia-southeast1.firebasedatabase.app"


def firebase_request(url, method, payload=None):
    body = None if payload is None else json.dumps(payload, ensure_ascii=False).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        method=method,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=5) as response:
        raw = response.read().decode("utf-8")
        return json.loads(raw) if raw else None


def read_bell_context(firebase_url):
    return firebase_request(f"{firebase_url}/radar/bell.json", "GET") or {"active": False}


def send_mode(device, context):
    if context.get("active") is True:
        mode = "HIGH" if context.get("isHighFloor") is True else "LOW"
    else:
        mode = "IDLE"
    device.write(f"MODE {mode}\n".encode("ascii"))
    device.flush()
    print(f"[장치] MODE {mode}")


def bell_event_payload(event, context):
    bus_position = {
        "x": context.get("x"),
        "y": context.get("y"),
        "z": context.get("z"),
    }
    return {
        "type": "bell_press",
        "button": event.get("button"),
        "mode": event.get("mode"),
        "deviceTimestampMs": event.get("timestampMs"),
        "receivedAtMs": int(time.time() * 1000),
        "bus": {
            "id": context.get("busId"),
            "name": context.get("busName"),
            "route": context.get("route"),
            "isHighFloor": context.get("isHighFloor") is True,
        },
        # B벨을 누른 위치는 탑승 중인 버스의 최신 월드 좌표로 자동 기록됩니다.
        "bellPosition": bus_position,
    }


def publish_bell_event(firebase_url, event, context):
    payload = bell_event_payload(event, context)
    firebase_request(f"{firebase_url}/bell/events.json", "POST", payload)
    firebase_request(f"{firebase_url}/bell/latest.json", "PUT", payload)
    print(
        "[Firebase] {button}벨 전송: {name} ({x}, {y}, {z})".format(
            button=payload["button"],
            name=payload["bus"]["name"] or "unknown",
            x=payload["bellPosition"]["x"],
            y=payload["bellPosition"]["y"],
            z=payload["bellPosition"]["z"],
        )
    )


def context_key(context):
    if context.get("active") is not True:
        return (False,)
    return (
        True,
        context.get("busId"),
        context.get("isHighFloor") is True,
    )


def run(port, baud, firebase_url, poll_interval):
    current_context = {"active": False}
    last_context_key = None

    with serial.Serial(port, baudrate=baud, timeout=0.05) as device:
        # USB 연결 때 보드가 재부팅되는 경우가 있어 준비 시간을 둡니다.
        time.sleep(1.5)
        device.reset_input_buffer()
        print(f"[시리얼] 연결됨: {port} @ {baud}")

        next_poll = 0.0
        while True:
            now = time.monotonic()
            if now >= next_poll:
                try:
                    current_context = read_bell_context(firebase_url)
                    next_key = context_key(current_context)
                    if next_key != last_context_key:
                        send_mode(device, current_context)
                        last_context_key = next_key
                except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
                    print(f"[Firebase] 하차벨 상태 읽기 실패: {error}", file=sys.stderr)
                next_poll = now + poll_interval

            raw_line = device.readline()
            if not raw_line:
                continue

            line = raw_line.decode("utf-8", errors="replace").strip()
            if line.startswith("BELL_EVENT "):
                try:
                    event = json.loads(line[len("BELL_EVENT "):])
                    if current_context.get("active") is True:
                        publish_bell_event(firebase_url, event, current_context)
                    else:
                        print("[장치] 탑승 버스가 없어 버튼 신호를 무시했습니다.")
                except (json.JSONDecodeError, urllib.error.URLError, TimeoutError) as error:
                    print(f"[하차벨] 이벤트 처리 실패: {error}", file=sys.stderr)
            elif line:
                print(f"[장치] {line}")


def parse_args():
    parser = argparse.ArgumentParser(description="MicroPython 하차벨 Firebase 브리지")
    parser.add_argument("--port", default=os.getenv("BELL_SERIAL_PORT"), help="장치 COM 포트. 예: COM5")
    parser.add_argument("--baud", default=115200, type=int)
    parser.add_argument("--firebase-url", default=DEFAULT_FIREBASE_URL)
    parser.add_argument("--poll-interval", default=0.35, type=float)
    args = parser.parse_args()
    if not args.port:
        parser.error("--port COM5 또는 BELL_SERIAL_PORT 환경 변수가 필요합니다.")
    return args


if __name__ == "__main__":
    arguments = parse_args()
    try:
        run(
            arguments.port,
            arguments.baud,
            arguments.firebase_url.rstrip("/"),
            arguments.poll_interval,
        )
    except KeyboardInterrupt:
        print("\n하차벨 브리지를 종료했습니다.")
    except serial.SerialException as error:
        print(f"시리얼 연결 실패: {error}", file=sys.stderr)
        sys.exit(1)
