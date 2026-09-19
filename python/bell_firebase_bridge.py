"""USB 하차벨과 Firebase를 연결하는 초저지연 PC 브리지.
- Persistent HTTPS Keep-Alive 세션 적용 (TLS Handshake 오버헤드 300ms -> 60ms 단축)
- 시리얼 수신 전담 스레드 분리: 버튼 누르는 즉시 Firebase /bell/latest.json PUT 전송
- 원격 하차벨 전담 고속 폴러 (약 0.12초 주기): 로블록스 벨 작동 즉시 보드 신호 전달

예시:
    py python/bell_firebase_bridge.py --port COM5
"""

import argparse
import http.client
import json
import os
import sys
import threading
import time
import urllib.parse

import serial


DEFAULT_FIREBASE_URL = "https://bumati-default-rtdb.asia-southeast1.firebasedatabase.app"
MAX_CONTEXT_AGE_MS = 4_000
REMOTE_BELL_MAX_AGE_MS = 5_000
MODE_REFRESH_INTERVAL_SEC = 2.0
# /bell/latest은 하차벨 켜짐/명시적 RESET 전용 고속 채널입니다.
# 위치 지도 폴링과 분리해 약 20회/초로 처리합니다.
REMOTE_BELL_POLL_SEC = 0.05
# Firebase의 짧은 지연/일시 실패를 미탑승으로 오인해 MODE IDLE(전체 리셋)를
# 보내지 않도록, 마지막으로 확인한 탑승 상태를 이 시간만큼 유지합니다.
CONTEXT_STALE_GRACE_SEC = 20.0
# 위치 판정은 탑승 경계에서 한 번 정도 흔들릴 수 있으므로, 정상 timestamp의
# 미탑승 상태도 연속 확인된 뒤에만 보드를 IDLE로 전환합니다.
INACTIVE_CONTEXT_CONFIRM_SEC = 2.0
# bell_reset 이벤트를 놓쳤을 때 쓰는 상태 폴링 보조 해제의 디바운스 시간입니다.
BELL_OFF_CONFIRM_SEC = 0.8


class FirebaseFastClient:
    """HTTP/1.1 Keep-Alive 연결을 재사용하여 통신 지연을 극소화하는 클라이언트"""

    def __init__(self, base_url):
        self.parsed = urllib.parse.urlparse(base_url)
        self.host = self.parsed.netloc
        self.base_path = self.parsed.path.rstrip("/")
        self.conn = None
        self.lock = threading.Lock()
        self._ensure_connection()

    def _ensure_connection(self):
        if self.conn is None:
            self.conn = http.client.HTTPSConnection(self.host, timeout=3.0)

    def request(self, endpoint, method="GET", payload=None):
        path = self.base_path + endpoint
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8") if payload is not None else None
        headers = {"Content-Type": "application/json", "Connection": "keep-alive"}

        with self.lock:
            for attempt in range(2):
                try:
                    self._ensure_connection()
                    self.conn.request(method, path, body=body, headers=headers)
                    res = self.conn.getresponse()
                    raw = res.read().decode("utf-8")
                    if not raw or raw == "null":
                        return None
                    return json.loads(raw)
                except Exception:
                    if self.conn:
                        try:
                            self.conn.close()
                        except Exception:
                            pass
                    self.conn = None
                    if attempt == 1:
                        raise


serial_lock = threading.Lock()


def write_device_command(device, command):
    """MicroPython USB CDC에 한 줄 명령을 스레드 안전하게 전송합니다."""
    with serial_lock:
        device.write((command + "\r\n").encode("ascii"))
        device.flush()


def send_mode(device, context):
    if context.get("active") is True:
        mode = "HIGH" if context.get("isHighFloor") is True else "LOW"
    else:
        mode = "IDLE"
    write_device_command(device, f"MODE {mode}")
    print(f"[장치] MODE {mode}")


def send_silent_bell(device, context, button="A"):
    """올라탔을 때 이미 하차벨이 켜져 있는 상태인 경우: 종류를 유지해 무음 점등합니다."""
    button = "B" if str(button).upper() == "B" else "A"
    command = f"SILENT_BELL {button}"
    write_device_command(device, command)
    print(f"[장치] 이미 하차벨 켜짐 상태 -> 소리 없이 점등 명령 전송: {command}")


def handle_remote_bell_event(device, event):
    """Roblox에서 발생한 벨 울림 또는 소등 이벤트를 MicroPython 보드에 전달합니다."""
    event_type = str(event.get("type") or "").lower()
    button = str(event.get("button") or "A").upper()

    if event_type == "bell_reset" or button == "RESET":
        write_device_command(device, "RESET")
        print("[장치] 원격 하차벨 소등 신호 수신 -> RESET 전송")
        return

    command = "BELL B" if button == "B" else "BELL A"
    write_device_command(device, command)
    print(f"[장치] 원격 벨 {command}")


def bell_event_payload(event, context):
    bus_position = {
        "x": context.get("x"),
        "y": context.get("y"),
        "z": context.get("z"),
    }
    return {
        "type": "bell_press",
        "source": "physical",
        "eventId": event.get("eventId") or f"physical-{event.get('timestampMs')}-{event.get('button')}",
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
        "bellPosition": bus_position,
    }


def publish_bell_event_fast(firebase_client, event, context):
    """실시간성이 가장 중요한 /bell/latest.json을 최우선으로 즉시 전송"""
    payload = bell_event_payload(event, context)

    # 1. 로블록스가 즉각 감지할 수 있도록 최신 벨 노드를 즉시 PUT (약 70ms)
    firebase_client.request("/bell/latest.json", "PUT", payload)
    print(
        "[Firebase] {button}벨 실시간 전송완료: {name} ({x}, {y}, {z})".format(
            button=payload["button"],
            name=payload["bus"]["name"] or "unknown",
            x=payload["bellPosition"]["x"],
            y=payload["bellPosition"]["y"],
            z=payload["bellPosition"]["z"],
        )
    )

    # 2. 이력 로그(/bell/events)는 백그라운드 비동기로 처리하여 지연 방지
    def _log_history():
        try:
            firebase_client.request("/bell/events.json", "POST", payload)
        except Exception:
            pass

    threading.Thread(target=_log_history, daemon=True).start()


def context_key(context):
    if context.get("active") is not True:
        return (False,)
    return (
        True,
        context.get("busId"),
        context.get("isHighFloor") is True,
    )


def run(port, baud, firebase_url, poll_interval):
    client = FirebaseFastClient(firebase_url)
    current_context = {"active": False}
    context_lock = threading.Lock()

    last_context_key = None
    last_remote_event_id = None
    last_boarded_bus = None
    # /bell/latest 수신 직후에는 Roblox의 /radar/bell 상태 반영까지 짧은 지연이
    # 있습니다. 게임이 실제로 켜짐을 한 번 확인하기 전의 false는 절대 RESET으로
    # 해석하지 않습니다. 그래야 벨이 랜덤하게 바로 꺼지지 않습니다.
    game_bell_confirmed_on = False
    last_game_bell_button = "A"
    last_mode_sent_at = 0.0
    last_fresh_context = {"active": False}
    last_fresh_context_at = 0.0
    inactive_context_since = None
    bell_off_since = None

    running = True

    with serial.Serial(port, baudrate=baud, timeout=0.1) as device:
        time.sleep(1.2)
        device.reset_input_buffer()
        print(f"[시리얼] 고속 연결됨: {port} @ {baud} (Keep-Alive 활성화)")

        # ----------------------------------------------------
        # 1. 시리얼 수신 전담 스레드 (물리 버튼 누르는 즉시 감지)
        # ----------------------------------------------------
        def serial_reader_thread():
            while running:
                try:
                    raw_line = device.readline()
                    if not raw_line:
                        continue
                    line = raw_line.decode("utf-8", errors="replace").strip()
                    if line.startswith("BELL_EVENT "):
                        try:
                            event = json.loads(line[len("BELL_EVENT "):])
                            with context_lock:
                                ctx = dict(current_context)
                            if ctx.get("active") is True:
                                event.setdefault("source", "physical")
                                publish_bell_event_fast(client, event, ctx)
                            else:
                                print("[장치] 탑승 버스가 없어 버튼 신호를 무시했습니다.")
                        except Exception as error:
                            print(f"[하차벨] 이벤트 처리 오류: {error}", file=sys.stderr)
                    elif line:
                        print(f"[장치] {line}")
                except serial.SerialException:
                    break
                except Exception:
                    time.sleep(0.01)

        t_serial = threading.Thread(target=serial_reader_thread, daemon=True)
        t_serial.start()

        # ----------------------------------------------------
        # 2. 메인 스레드: Firebase 고속 폴링 (초당 6~8회)
        # ----------------------------------------------------
        next_context_poll = 0.0
        while running:
            now = time.monotonic()

            # A. 원격 하차벨(로블록스 -> 장치) 초고속 폴링
            try:
                latest_bell = client.request("/bell/latest.json", "GET")
                if latest_bell and isinstance(latest_bell, dict):
                    received_at = latest_bell.get("receivedAtMs") or latest_bell.get("deviceTimestampMs")
                    if isinstance(received_at, (int, float)) and (int(time.time() * 1000) - int(received_at) <= REMOTE_BELL_MAX_AGE_MS):
                        source = latest_bell.get("source")
                        latest_button = "B" if str(latest_bell.get("button") or "").upper() == "B" else "A"
                        event_id = str(
                            latest_bell.get("eventId")
                            or f"{source}-{received_at}-{latest_bell.get('button')}"
                        )
                        # 물리/원격 이벤트 모두 마지막 벨 종류를 기억합니다. 탑승 중
                        # 이미 점등된 B벨을 무음 동기화할 때 A로 바뀌는 것을 막습니다.
                        if str(latest_bell.get("type") or "").lower() != "bell_reset":
                            last_game_bell_button = latest_button
                        if source != "physical" and event_id != last_remote_event_id:
                            handle_remote_bell_event(device, latest_bell)
                            last_remote_event_id = event_id
                            if str(latest_bell.get("type") or "").lower() == "bell_reset" or latest_bell.get("button") == "RESET":
                                game_bell_confirmed_on = False
                                bell_off_since = None
                            else:
                                # BELL 명령은 우선 보드에 유지하고, 이후 게임의 켜짐
                                # 상태가 확인되어야만 /radar/bell false로 해제합니다.
                                game_bell_confirmed_on = False
                                bell_off_since = None
            except Exception:
                pass

            # B. 탑승 버스 컨텍스트(/radar/bell.json) 주기적 폴링 (약 0.35초)
            if now >= next_context_poll:
                next_context_poll = now + poll_interval
                try:
                    received_context = client.request("/radar/bell.json", "GET") or {"active": False}
                    ts = received_context.get("timestamp")
                    is_fresh = isinstance(ts, (int, float)) and int(time.time() * 1000) - ts <= MAX_CONTEXT_AGE_MS
                    if is_fresh and received_context.get("active") is True:
                        # active=False도 정상적으로 갱신된 값이면 실제 하차/미탑승으로
                        # 처리해야 하지만, 위치 감지의 한 번짜리 흔들림은 아래에서
                        # 확인 시간을 거쳐 처리합니다.
                        ctx = received_context
                        last_fresh_context = dict(ctx)
                        last_fresh_context_at = now
                        inactive_context_since = None
                    elif is_fresh:
                        # 정상 수신된 미탑승이라도 마지막 상태가 탑승 중이었다면
                        # 2초 연속 확인 전에는 기존 버스 모드/래치를 유지합니다.
                        if last_fresh_context.get("active") is True:
                            if inactive_context_since is None:
                                inactive_context_since = now
                            if now - inactive_context_since < INACTIVE_CONTEXT_CONFIRM_SEC:
                                ctx = dict(last_fresh_context)
                            else:
                                ctx = received_context
                                last_fresh_context = dict(ctx)
                                last_fresh_context_at = now
                                inactive_context_since = None
                        else:
                            ctx = received_context
                            last_fresh_context = dict(ctx)
                            last_fresh_context_at = now
                    elif (
                        last_fresh_context.get("active") is True
                        and now - last_fresh_context_at < CONTEXT_STALE_GRACE_SEC
                    ):
                        # 네트워크·Firebase 지연 중에는 하차벨 래치와 릴레이를 유지합니다.
                        ctx = dict(last_fresh_context)
                    else:
                        ctx = {"active": False}

                    with context_lock:
                        current_context.clear()
                        current_context.update(ctx)

                    is_active = ctx.get("active") is True
                    bus_id = ctx.get("busId")
                    is_bell_ringing = ctx.get("isBellRinging") is True
                    just_boarded = is_active and (last_boarded_bus != bus_id)

                    next_key = context_key(ctx)
                    if next_key != last_context_key or now - last_mode_sent_at >= MODE_REFRESH_INTERVAL_SEC:
                        send_mode(device, ctx)
                        last_context_key = next_key
                        last_mode_sent_at = now

                        # 탑승하는 순간 이미 게임 안에서 하차벨이 켜져 있다면 부저 없이 램프만 켬
                        if just_boarded and is_bell_ringing:
                            time.sleep(0.04)
                            send_silent_bell(device, ctx, last_game_bell_button)
                            game_bell_confirmed_on = True
                            bell_off_since = None
                            if latest_bell and isinstance(latest_bell, dict):
                                last_remote_event_id = str(latest_bell.get("eventId") or "")

                    if is_active:
                        last_boarded_bus = bus_id
                        # 게임에서 점등 상태가 실제로 확인된 뒤에만 상태 폴링을
                        # 보조 해제 수단으로 씁니다. 원격 명령 직후의 false는
                        # Roblox 반영 지연일 수 있으므로 RESET을 보내지 않습니다.
                        if is_bell_ringing:
                            game_bell_confirmed_on = True
                            bell_off_since = None
                        elif game_bell_confirmed_on:
                            if bell_off_since is None:
                                bell_off_since = now
                            elif now - bell_off_since >= BELL_OFF_CONFIRM_SEC:
                                write_device_command(device, "RESET")
                                print("[장치] 게임 내 하차벨 소등 감지 -> RESET 전송")
                                game_bell_confirmed_on = False
                                bell_off_since = None
                    else:
                        last_boarded_bus = None
                        game_bell_confirmed_on = False
                        bell_off_since = None
                except Exception:
                    pass

            # 하차벨 켜짐/RESET은 약 0.05초마다 확인합니다.
            time.sleep(REMOTE_BELL_POLL_SEC)


def parse_args():
    parser = argparse.ArgumentParser(description="MicroPython 하차벨 고속 Firebase 브리지")
    parser.add_argument("--port", default=os.getenv("BELL_SERIAL_PORT"), help="장치 COM 포트. 예: COM5")
    parser.add_argument("--baud", default=115200, type=int)
    parser.add_argument("--firebase-url", default=DEFAULT_FIREBASE_URL)
    parser.add_argument("--poll-interval", default=0.20, type=float)
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
