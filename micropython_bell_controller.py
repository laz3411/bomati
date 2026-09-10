from machine import Pin, PWM
import _thread
try:
    import uselect as select
except ImportError:
    import select
import sys
import time
import ujson

# USB serial protocol from bell_firebase_bridge.py:
#   MODE LOW\n, MODE HIGH\n, MODE IDLE\n, BELL A\n, BELL B\n, RESET\n
PIN_BELL_A = 14
PIN_BELL_B = 15
PIN_RELAY_IN = 16
PIN_BUZZER_A = 17
PIN_BUZZER_B = 18
RELAY_ON_LEVEL = 0   # 현재 배선은 active-low 릴레이 기준
RELAY_OFF_LEVEL = 1

relay = Pin(PIN_RELAY_IN, Pin.OUT, value=RELAY_OFF_LEVEL)
sig_a = Pin(PIN_BELL_A, Pin.IN, Pin.PULL_DOWN)
sig_b = Pin(PIN_BELL_B, Pin.IN, Pin.PULL_UP)
buzzer_a = PWM(Pin(PIN_BUZZER_A))
buzzer_b = PWM(Pin(PIN_BUZZER_B))
buzzer_a.duty_u16(0)
buzzer_b.duty_u16(0)

led_a_on = False
led_b_on = False
mode = "idle"  # idle, low, high
play_a_sound = False
play_b_sound = False
stop_all_sound = False
serial_buffer = ""
stdin_poll = select.poll()
stdin_poll.register(sys.stdin, select.POLLIN)


def send_event(button):
    # Python 브리지가 이 한 줄을 읽어 Firebase에 저장합니다.
    timestamp = time.ticks_ms()
    print("BELL_EVENT " + ujson.dumps({
        "button": button,
        "mode": mode,
        "source": "physical",
        "eventId": "physical-{}-{}".format(timestamp, button),
        "timestampMs": timestamp
    }))


def sound_controller_thread():
    global play_a_sound, play_b_sound, stop_all_sound

    a_step = 0
    a_timer = 0
    b_timer = 0

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

        if play_a_sound:
            if a_step == 0:
                buzzer_a.freq(784)
                buzzer_a.duty_u16(32768)
                a_timer += 10
                if a_timer >= 400:
                    a_step, a_timer = 1, 0
            elif a_step == 1:
                buzzer_a.freq(659)
                buzzer_a.duty_u16(32768)
                a_timer += 10
                if a_timer >= 500:
                    buzzer_a.duty_u16(0)
                    a_step, a_timer = 2, 0
            elif a_step == 2:
                a_timer += 10
                if a_timer >= 250:
                    a_step, a_timer = 3, 0
            elif a_step == 3:
                buzzer_a.freq(784)
                buzzer_a.duty_u16(32768)
                a_timer += 10
                if a_timer >= 400:
                    a_step, a_timer = 4, 0
            else:
                buzzer_a.freq(659)
                buzzer_a.duty_u16(32768)
                a_timer += 10
                if a_timer >= 500:
                    buzzer_a.duty_u16(0)
                    play_a_sound = False
                    a_step, a_timer = 0, 0
        else:
            buzzer_a.duty_u16(0)

        if play_b_sound:
            buzzer_b.freq(1200)
            buzzer_b.duty_u16(32768)
            b_timer += 10
            if b_timer >= 2000:
                buzzer_b.duty_u16(0)
                play_b_sound = False
                b_timer = 0
        else:
            buzzer_b.duty_u16(0)

        time.sleep_ms(10)


def force_reset_all():
    global led_a_on, led_b_on, sig_a, sig_b, play_a_sound, play_b_sound, stop_all_sound
    stop_all_sound = True
    play_a_sound = False
    play_b_sound = False
    # 릴레이는 active-low 기준: HIGH가 꺼짐입니다.
    relay.value(RELAY_OFF_LEVEL)
    sig_a = Pin(PIN_BELL_A, Pin.IN, Pin.PULL_DOWN)
    sig_b = Pin(PIN_BELL_B, Pin.IN, Pin.PULL_UP)
    led_a_on = False
    led_b_on = False
    print("BELL_STATUS reset")


def set_mode(next_mode):
    global mode
    if next_mode not in ("low", "high", "idle"):
        return
    if mode != next_mode:
        force_reset_all()
        mode = next_mode
        print("BELL_STATUS mode=" + mode)


def trigger_remote_bell(button):
    global led_a_on, led_b_on, sig_a, sig_b, relay, play_a_sound, play_b_sound, stop_all_sound

    button = button.upper()
    if mode == "idle":
        print("BELL_STATUS ignored=idle")
        return

    # MODE 변경 직후 남아 있을 수 있는 reset 플래그가 새 벨 명령을
    # 지우지 않도록 해제합니다.
    stop_all_sound = False

    if button == "B":
        led_b_on = True
        sig_b = Pin(PIN_BELL_B, Pin.OUT, value=0)
        if mode == "low":
            play_b_sound = True
        else:
            relay.value(RELAY_ON_LEVEL)
            led_a_on = True
            sig_a = Pin(PIN_BELL_A, Pin.OUT, value=0)
            play_a_sound = True
    else:
        relay.value(RELAY_ON_LEVEL)
        led_a_on = True
        sig_a = Pin(PIN_BELL_A, Pin.OUT, value=0)
        play_a_sound = True
        if mode == "high":
            led_b_on = True
            sig_b = Pin(PIN_BELL_B, Pin.OUT, value=0)

    print("BELL_STATUS remote=" + ("B" if button == "B" else "A"))


def handle_command(command):
    command = command.strip().upper()
    print("BELL_STATUS command=" + command)
    if command == "MODE LOW":
        set_mode("low")
    elif command == "MODE HIGH":
        set_mode("high")
    elif command == "BELL A":
        trigger_remote_bell("A")
    elif command == "BELL B":
        trigger_remote_bell("B")
    elif command == "MODE IDLE" or command == "RESET":
        set_mode("idle")
        force_reset_all()


def poll_serial_command():
    global serial_buffer
    if not stdin_poll.poll(0):
        return

    char = sys.stdin.read(1)
    if char == " ":
        force_reset_all()
    elif char in "\r\n":
        if serial_buffer:
            handle_command(serial_buffer)
            serial_buffer = ""
    elif char:
        serial_buffer += char
        if len(serial_buffer) > 32:
            serial_buffer = ""


_thread.start_new_thread(sound_controller_thread, ())
print("BELL_STATUS ready")

while True:
    poll_serial_command()

    # 버스에 탄 상태가 아닐 때(mode == "idle")에는 모든 하차벨 입력을 무시하고 불이 꺼진 상태를 유지합니다.
    if mode == "idle":
        time.sleep_ms(10)
        continue

    # [하차벨 B (교통약자/휠체어 하차벨)]
    # - 저상버스(mode == "low"): B벨 독립 작동 (부저 B + LED B 점등)
    # - 고상버스(mode == "high"): B벨이 A벨과 함께 작동 (부저 A + 릴레이 ON + LED A/B 동시 점등)
    if not led_b_on:
        sig_b = Pin(PIN_BELL_B, Pin.IN, Pin.PULL_UP)
        if sig_b.value() == 0:
            time.sleep_ms(30)
            if sig_b.value() == 0:
                led_b_on = True
                sig_b = Pin(PIN_BELL_B, Pin.OUT, value=0)

                if mode == "low":
                    stop_all_sound = False
                    play_b_sound = True
                elif mode == "high":
                    stop_all_sound = False
                    relay.value(RELAY_ON_LEVEL)
                    led_a_on = True
                    play_a_sound = True

                send_event("B")

    # [하차벨 A (일반 하차벨)]
    # - 저상버스(mode == "low"): A벨 독립 작동 (부저 A + 릴레이 ON + LED A 점등)
    # - 고상버스(mode == "high"): A벨 작동 시 B벨도 함께 점등 (LED A/B 동시 점등)
    if not led_a_on:
        sig_a = Pin(PIN_BELL_A, Pin.IN, Pin.PULL_DOWN)
        if sig_a.value() == 1:
            time.sleep_ms(50)
            if sig_a.value() == 1:
                stop_all_sound = False
                relay.value(RELAY_ON_LEVEL)
                led_a_on = True
                play_a_sound = True

                if mode == "high":
                    led_b_on = True
                    sig_b = Pin(PIN_BELL_B, Pin.OUT, value=0)

                send_event("A")

    # B벨 LED 유지
    if led_b_on:
        sig_b = Pin(PIN_BELL_B, Pin.OUT, value=0)

    time.sleep_ms(10)


