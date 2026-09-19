"""
하차벨 A/B 마이크로파이썬 통합 제어기 (양방향 통신 & Latch 제어)
- 피지컬 하차벨(물리 버튼) 감지 시: USB 시리얼(BELL_EVENT JSON)로 PC/Firebase/Roblox에 전송
- PC 브리지(bell_firebase_bridge.py)로부터 명령 수신:
    MODE LOW / MODE HIGH / MODE IDLE / BELL A / BELL B / RESET
- 콘솔 단독 실행(키보드) 지원:
    [1]: 저상 버스 모드
    [0]: 고상 버스 모드
    [스페이스바]: 전체 리셋
"""

from machine import Pin, PWM
import time
import sys
import _thread

try:
    import uselect as select
except ImportError:
    import select

try:
    import ujson as json
except ImportError:
    import json

# ==========================================
# 1. 핀 번호 및 하드웨어 설정
# ==========================================
PIN_BELL_A = 14    # 하차벨 A (Active High)
PIN_BELL_B = 15    # 하차벨 B (Active Low)
PIN_RELAY_IN = 16  # 5V 릴레이 제어 핀

# 부저 2개 분리
PIN_BUZZER_A = 17  # A벨 전용 부저
PIN_BUZZER_B = 18  # B벨 전용 부저

# 초기 상태: High-Z 모드 (릴레이 OFF)
relay = Pin(PIN_RELAY_IN, Pin.IN)
sig_a = Pin(PIN_BELL_A, Pin.IN, Pin.PULL_DOWN)
sig_b = Pin(PIN_BELL_B, Pin.IN, Pin.PULL_UP)

# 부저 2개 PWM 초기화
buzzer_a = PWM(Pin(PIN_BUZZER_A))
buzzer_b = PWM(Pin(PIN_BUZZER_B))
buzzer_a.duty_u16(0)
buzzer_b.duty_u16(0)

# 상태 플래그
led_a_on = False
led_b_on = False
mode = "low"  # 기본값: 저상 버스 ("low", "high", "idle")

# 소리 제어 플래그
play_a_sound = False
play_b_sound = False
stop_all_sound = False

# 시리얼 입력 버퍼
serial_buffer = ""

# stdin 논블로킹 poll 등록 시도
stdin_poll = None
try:
    stdin_poll = select.poll()
    stdin_poll.register(sys.stdin, select.POLLIN)
except Exception:
    stdin_poll = None

print("=" * 65)
print("   [하차벨 A/B Latch & Firebase/Roblox 양방향 연동 컨트롤러]")
print("   - 부저A(GP17): '솔-미' 맑은 띵동 2회 (A벨)")
print("   - 부저B(GP18): 교통약자 하차벨 1200Hz 2초 울림 (B벨)")
print("   - [1 또는 MODE LOW ]: 저상 버스 (A/B 독립 동작 및 동시 출력 가능)")
print("   - [0 또는 MODE HIGH]: 고상 버스 (A/B 벨 중 하나만 눌러도 동시 Latch)")
print("   - [MODE IDLE       ]: 미탑승/대기 (하차벨 입력 무시 및 소등)")
print("   - [BELL A / BELL B ]: 원격 하차벨 수신 및 동작")
print("   - [스페이스바/RESET]: 릴레이 강제 차단 (전체 리셋)")
print("=" * 65)
print("BELL_STATUS ready")


# ==========================================
# 2. Core 1 전담 스레드 (소리 제어)
# ==========================================
def sound_controller_thread():
    global play_a_sound, play_b_sound, stop_all_sound

    a_step = 0
    a_timer = 0
    b_timer = 0

    FREQ_SOL = 784   # A벨: '솔'
    FREQ_MI  = 659   # A벨: '미'
    FREQ_B   = 1200  # B벨: 1200Hz

    while True:
        if stop_all_sound:
            buzzer_a.duty_u16(0)
            buzzer_b.duty_u16(0)
            play_a_sound = False
            play_b_sound = False
            stop_all_sound = False
            a_step = 0
            a_timer = 0
            b_timer = 0
            time.sleep_ms(10)
            continue

        # ----------------------------------------------------
        # 1. 부저 A 제어 ('솔-미' 띵동 2회)
        # ----------------------------------------------------
        if play_a_sound:
            if a_step == 0:
                buzzer_a.freq(FREQ_SOL)
                buzzer_a.duty_u16(32768)
                a_timer += 10
                if a_timer >= 400:
                    a_step = 1
                    a_timer = 0
            elif a_step == 1:
                buzzer_a.freq(FREQ_MI)
                buzzer_a.duty_u16(32768)
                a_timer += 10
                if a_timer >= 500:
                    buzzer_a.duty_u16(0)
                    a_step = 2
                    a_timer = 0
            elif a_step == 2:
                a_timer += 10
                if a_timer >= 250:
                    a_step = 3
                    a_timer = 0
            elif a_step == 3:
                buzzer_a.freq(FREQ_SOL)
                buzzer_a.duty_u16(32768)
                a_timer += 10
                if a_timer >= 400:
                    a_step = 4
                    a_timer = 0
            elif a_step == 4:
                buzzer_a.freq(FREQ_MI)
                buzzer_a.duty_u16(32768)
                a_timer += 10
                if a_timer >= 500:
                    buzzer_a.duty_u16(0)
                    play_a_sound = False
                    a_step = 0
                    a_timer = 0
        else:
            buzzer_a.duty_u16(0)

        # ----------------------------------------------------
        # 2. 부저 B 제어 (1200Hz - 2.0초 지속)
        # ----------------------------------------------------
        if play_b_sound:
            buzzer_b.freq(FREQ_B)
            buzzer_b.duty_u16(32768)
            b_timer += 10

            if b_timer >= 2000:
                buzzer_b.duty_u16(0)
                play_b_sound = False
                b_timer = 0
        else:
            buzzer_b.duty_u16(0)

        time.sleep_ms(10)

_thread.start_new_thread(sound_controller_thread, ())


# ==========================================
# 3. 데이터 송신 함수 (보드 -> PC 브리지/Firebase)
# ==========================================
def send_event(button):
    """물리 버튼 감지 시 PC 브리지(bell_firebase_bridge.py)로 JSON 이벤트 전송"""
    try:
        timestamp = time.ticks_ms()
    except AttributeError:
        timestamp = int(time.time() * 1000)

    payload = {
        "button": button,
        "mode": mode,
        "source": "physical",
        "eventId": "physical-{}-{}".format(timestamp, button),
        "timestampMs": timestamp
    }
    print("BELL_EVENT " + json.dumps(payload))


# ==========================================
# 4. 리셋 및 모드 전환 함수
# ==========================================
def force_reset_all():
    global led_a_on, led_b_on, sig_a, sig_b, relay, play_a_sound, play_b_sound, stop_all_sound
    print("\n⚡ [리셋] 릴레이 즉시 OFF (High-Z 전환), 사운드 정지...")

    stop_all_sound = True
    play_a_sound = False
    play_b_sound = False

    relay = Pin(PIN_RELAY_IN, Pin.IN)
    sig_a = Pin(PIN_BELL_A, Pin.IN, Pin.PULL_DOWN)
    sig_b = Pin(PIN_BELL_B, Pin.IN, Pin.PULL_UP)

    time.sleep_ms(50)
    led_a_on = False
    led_b_on = False

    print("BELL_STATUS reset")
    print("✔ [리셋 완료] 대기 중...\n")


def set_mode(next_mode):
    global mode
    next_mode = next_mode.lower()
    if next_mode not in ("low", "high", "idle"):
        return
    if mode != next_mode:
        force_reset_all()
        mode = next_mode
        if mode == "low":
            print("♿ [모드 변경] 저상 버스 (A/B 독립 동작 및 동시 출력 가능)")
        elif mode == "high":
            print("🚌 [모드 변경] 고상 버스 (A/B 벨 중 하나만 눌러도 둘 다 ON)")
        elif mode == "idle":
            print("💤 [모드 변경] 미탑승/대기 (하차벨 입력 무시 및 소등)")
        print("BELL_STATUS mode=" + mode)


# ==========================================
# 5. 원격 하차벨 수신 작동 (Roblox/Firebase -> 보드)
# ==========================================
def trigger_remote_bell(button):
    global led_a_on, led_b_on, sig_b, relay, play_a_sound, play_b_sound, stop_all_sound

    button = button.upper()
    if mode == "idle":
        print("BELL_STATUS ignored=idle")
        return

    stop_all_sound = False

    if button == "B":
        led_b_on = True
        sig_b = Pin(PIN_BELL_B, Pin.OUT, value=0)

        if mode == "low":
            print("▶ [원격 수신: B벨] 저상 버스 -> B벨 Latch ON (부저 B 2초 울림)")
            play_b_sound = True
        else:
            relay = Pin(PIN_RELAY_IN, Pin.OUT, value=0)
            led_a_on = True
            print("▶ [원격 수신: B벨] 고상 버스 -> A/B벨 동시 Latch ON + 릴레이 ON (부저 A 울림)")
            play_a_sound = True
    else:  # A벨
        relay = Pin(PIN_RELAY_IN, Pin.OUT, value=0)
        led_a_on = True
        play_a_sound = True

        if mode == "high":
            led_b_on = True
            sig_b = Pin(PIN_BELL_B, Pin.OUT, value=0)
            print("▶ [원격 수신: A벨] 고상 버스 -> A/B벨 동시 Latch ON + 릴레이 ON (부저 A 울림)")
        else:
            print("▶ [원격 수신: A벨] 저상 버스 -> A벨 Latch ON + 릴레이 ON (부저 A 울림)")

    print("BELL_STATUS remote=" + ("B" if button == "B" else "A"))


def trigger_silent_bell(button="A"):
    """올라탔을 때 이미 게임 안에서 하차벨이 켜져 있는 경우: 소리(부저) 없이 램프/릴레이만 점등"""
    global led_a_on, led_b_on, sig_b, relay, play_a_sound, play_b_sound, stop_all_sound

    if mode == "idle":
        print("BELL_STATUS ignored=idle")
        return

    # 소리 즉시 차단 (부저 작동 방지)
    stop_all_sound = True
    play_a_sound = False
    play_b_sound = False

    button = button.upper() if button else "A"
    if button == "B" and mode == "low":
        led_b_on = True
        sig_b = Pin(PIN_BELL_B, Pin.OUT, value=0)
        print("▶ [무음 점등: B벨] 저상 버스 -> B벨 Latch ON (소리 없음)")
    else:
        # A벨 릴레이 ON (Active Low)
        relay = Pin(PIN_RELAY_IN, Pin.OUT, value=0)
        led_a_on = True
        if mode == "high":
            led_b_on = True
            sig_b = Pin(PIN_BELL_B, Pin.OUT, value=0)
            print("▶ [무음 점등: A/B벨] 고상 버스 -> A/B벨 동시 Latch ON + 릴레이 ON (소리 없음)")
        else:
            print("▶ [무음 점등: A벨] 저상 버스 -> A벨 Latch ON + 릴레이 ON (소리 없음)")

    print("BELL_STATUS silent=" + ("B" if button == "B" else "A"))


def handle_command(command):
    command = command.strip().upper()
    if not command:
        return

    print("BELL_STATUS command=" + command)
    if command == "MODE LOW":
        set_mode("low")
    elif command == "MODE HIGH":
        set_mode("high")
    elif command == "MODE IDLE":
        set_mode("idle")
    elif command == "BELL A":
        trigger_remote_bell("A")
    elif command == "BELL B":
        trigger_remote_bell("B")
    elif command.startswith("SILENT_BELL") or command.startswith("BELL_SILENT") or command == "BELL SILENT":
        parts = command.split()
        btn = parts[1] if len(parts) > 1 and parts[1] in ("A", "B") else "A"
        trigger_silent_bell(btn)
    elif command == "RESET":
        force_reset_all()


# ==========================================
# 6. 시리얼 및 키보드 논블로킹 수신
# ==========================================
def poll_serial_input():
    global serial_buffer

    has_data = False
    if stdin_poll is not None:
        try:
            has_data = bool(stdin_poll.poll(0))
        except Exception:
            has_data = False
    else:
        try:
            has_data = bool(select.select([sys.stdin], [], [], 0)[0])
        except Exception:
            has_data = False

    if not has_data:
        return

    while True:
        can_read = False
        if stdin_poll is not None:
            try:
                can_read = bool(stdin_poll.poll(0))
            except Exception:
                can_read = False
        else:
            try:
                can_read = bool(select.select([sys.stdin], [], [], 0)[0])
            except Exception:
                can_read = False

        if not can_read:
            break

        try:
            ch = sys.stdin.read(1)
        except Exception:
            break

        if not ch:
            break

        # 버퍼가 비어있을 때 단일 키보드 단축키 처리
        if ch == ' ' and not serial_buffer:
            force_reset_all()
        elif ch == '0' and not serial_buffer:
            set_mode("high")
        elif ch == '1' and not serial_buffer:
            set_mode("low")
        elif ch in ('\r', '\n'):
            if serial_buffer:
                handle_command(serial_buffer)
                serial_buffer = ""
        else:
            serial_buffer += ch
            if len(serial_buffer) > 40:
                serial_buffer = ""


# ==========================================
# 7. Core 0: 메인 감지 및 제어 루프
# ==========================================
while True:
    # 1. 시리얼 명령 및 키보드 입력 수신
    poll_serial_input()

    # 버스 미탑승(idle) 모드일 때는 모든 하차벨 입력을 무시하고 소등 상태 유지
    if mode == "idle":
        time.sleep_ms(10)
        continue

    # ----------------------------------------------------
    # 2. B벨 감지 (Active Low, 풀업)
    # ----------------------------------------------------
    if not led_b_on:
        sig_b = Pin(PIN_BELL_B, Pin.IN, Pin.PULL_UP)
        if sig_b.value() == 0:
            time.sleep_ms(30)
            if sig_b.value() == 0:
                led_b_on = True
                sig_b = Pin(PIN_BELL_B, Pin.OUT, value=0)
                stop_all_sound = False

                if mode == "low":
                    print("▶ [장애인 하차벨 B] 저상 버스 -> B벨 Latch ON (부저 B 2초 울림)")
                    play_b_sound = True
                else:  # 고상 버스
                    relay = Pin(PIN_RELAY_IN, Pin.OUT, value=0)
                    led_a_on = True
                    print("▶ [장애인 하차벨 B] 고상 버스 -> A/B벨 동시 Latch ON + 릴레이 ON (부저 A 울림)")
                    play_a_sound = True

                # PC 브리지 및 Firebase/Roblox로 물리 이벤트 전송
                send_event("B")

    # ----------------------------------------------------
    # 3. A벨 감지 (Active High, 풀다운)
    # ----------------------------------------------------
    if not led_a_on:
        sig_a = Pin(PIN_BELL_A, Pin.IN, Pin.PULL_DOWN)
        if sig_a.value() == 1:
            time.sleep_ms(50)
            if sig_a.value() == 1:
                stop_all_sound = False
                relay = Pin(PIN_RELAY_IN, Pin.OUT, value=0)
                led_a_on = True
                play_a_sound = True

                # 고상 버스일 때는 A벨을 눌러도 B벨 Latch까지 함께 켜짐
                if mode == "high":
                    led_b_on = True
                    sig_b = Pin(PIN_BELL_B, Pin.OUT, value=0)
                    print("▶ [하차벨 A] 고상 버스 -> A/B벨 동시 Latch ON + 릴레이 ON (부저 A 울림)")
                else:
                    print("▶ [하차벨 A] 저상 버스 -> A벨 Latch ON + 릴레이 ON (부저 A 울림)")

                # PC 브리지 및 Firebase/Roblox로 물리 이벤트 전송
                send_event("A")

    # B벨 Latch 지속 출력 유지
    if led_b_on:
        sig_b = Pin(PIN_BELL_B, Pin.OUT, value=0)

    time.sleep_ms(10)
