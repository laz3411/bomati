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
MAX_CONTEXT_AGE_MS = 10_000


def auto_detect_port():
    try:
        import serial.tools.list_ports
        ports = list(serial.tools.list_ports.comports())
        if not ports:
            return None
        # MicroPython / Pico / USB Serial 장치 우선 탐색
        for p in ports:
            desc = (p.description or "").lower()
            hwid = (p.hwid or "").lower()
            if any(k in desc or k in hwid for k in ["pico", "micropython", "ch340", "cp210", "ftdi", "usb serial", "cdc"]):
                return p.device
        return ports[0].device
    except Exception:
        return None


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
    context = firebase_request(f"{firebase_url}/radar/bell.json", "GET") or {"active": False}
    timestamp = context.get("timestamp")
    is_fresh = isinstance(timestamp, (int, float)) and int(time.time() * 1000) - timestamp <= MAX_CONTEXT_AGE_MS
    if context.get("active") is not True or not is_fresh:
        return {"active": False}
    return context


def send_mode(device, context):
    if context.get("active") is True:
        mode = "HIGH" if context.get("isHighFloor") is True else "LOW"
        desc = "탑승 활성화 (" + ("고상" if mode == "HIGH" else "저상") + ")"
    else:
        mode = "IDLE"
        desc = "하차/미탑승 (소등 및 대기 리셋)"

    device.write(f"MODE {mode}\n".encode("ascii"))
    device.flush()
    print(f"[장치 전송] MODE {mode} -> {desc}")


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
        # 하차벨을 누른 위치는 탑승 중인 버스의 최신 월드 좌표로 자동 기록됩니다.
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
    last_periodic_sync = 0.0

    with serial.Serial(port, baudrate=baud, timeout=0.05) as device:
        # USB 연결 시 보드 리셋 대기
        time.sleep(1.5)
        device.reset_input_buffer()
        print(f"[시리얼] 연결됨: {port} @ {baud}")

        # 최초 실행 시 현재 모드 즉시 전송
        send_mode(device, current_context)

        next_poll = 0.0
        while True:
            now = time.monotonic()
            if now >= next_poll:
                try:
                    current_context = read_bell_context(firebase_url)
                    next_key = context_key(current_context)
                    # 상태 변경 시 즉시 모드 전송
                    if next_key != last_context_key:
                        send_mode(device, current_context)
                        last_context_key = next_key
                        last_periodic_sync = now
                    # 3초마다 정기 동기화 (보드 재부팅/선 빠짐 복구 대비)
                    elif now - last_periodic_sync >= 3.0:
                        send_mode(device, current_context)
                        last_periodic_sync = now
                except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
                    print(f"[Firebase] 하차벨 상태 읽기 실패: {error}", file=sys.stderr)
                    current_context = {"active": False}
                    if last_context_key != (False,):
                        send_mode(device, current_context)
                        last_context_key = (False,)
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
                        print("[장치] 탑승 버스가 없어 버튼 신호를 무시했습니다 (대기 중).")
                except (json.JSONDecodeError, urllib.error.URLError, TimeoutError) as error:
                    print(f"[하차벨] 이벤트 처리 실패: {error}", file=sys.stderr)
            elif "BELL_STATUS ready" in line or "BELL_STATUS reset" in line:
                print(f"[장치 상태] {line}")
                # 장치 부팅 완료 시 현재 모드로 즉시 동기화
                send_mode(device, current_context)
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
        detected = auto_detect_port()
        if detected:
            print(f"[시리얼] COM 포트를 자동 감지했습니다: {detected}")
            args.port = detected
        else:
            parser.error("--port COM5 또는 BELL_SERIAL_PORT 환경 변수가 필요합니다. (포트 자동 감지 실패)")
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
