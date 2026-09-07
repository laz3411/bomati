from machine import Pin, PWM
import _thread
import select
import sys
import time
import ujson

# USB serial protocol from bell_firebase_bridge.py:
#   MODE LOW\n, MODE HIGH\n, MODE IDLE\n, RESET\n
PIN_BELL_A = 14
PIN_BELL_B = 15
PIN_RELAY_IN = 16
PIN_BUZZER_A = 17
PIN_BUZZER_B = 18

relay = Pin(PIN_RELAY_IN, Pin.IN)
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


def send_event(button):
    # Python 브리지가 이 한 줄을 읽어 Firebase에 저장합니다.
    print("BELL_EVENT " + ujson.dumps({
        "button": button,
        "mode": mode,
        "timestampMs": time.ticks_ms()
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
    global led_a_on, led_b_on, sig_a, sig_b, relay, stop_all_sound
    stop_all_sound = True
    relay = Pin(PIN_RELAY_IN, Pin.IN)
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


def handle_command(command):
    command = command.strip().upper()
    if command == "MODE LOW":
        set_mode("low")
    elif command == "MODE HIGH":
        set_mode("high")
    elif command == "MODE IDLE" or command == "RESET":
        set_mode("idle")
        force_reset_all()


def poll_serial_command():
    global serial_buffer
    if not select.select([sys.stdin], [], [], 0)[0]:
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

    # 버스에 탄 상태가 아닐 때에는 신호를 무시합니다.
    if mode == "idle":
        time.sleep_ms(10)
        continue

    if not led_b_on:
        sig_b = Pin(PIN_BELL_B, Pin.IN, Pin.PULL_UP)
        if sig_b.value() == 0:
            time.sleep_ms(30)
            if sig_b.value() == 0:
                led_b_on = True
                sig_b = Pin(PIN_BELL_B, Pin.OUT, value=0)
                if mode == "low":
                    play_b_sound = True
                else:
                    relay = Pin(PIN_RELAY_IN, Pin.OUT, value=0)
                    led_a_on = True
                    play_a_sound = True
                send_event("B")

    if not led_a_on and sig_a.value() == 1:
        time.sleep_ms(50)
        if sig_a.value() == 1:
            relay = Pin(PIN_RELAY_IN, Pin.OUT, value=0)
            led_a_on = True
            play_a_sound = True
            if mode == "high":
                led_b_on = True
                sig_b = Pin(PIN_BELL_B, Pin.OUT, value=0)
            send_event("A")

    if led_b_on:
        sig_b = Pin(PIN_BELL_B, Pin.OUT, value=0)

    time.sleep_ms(10)
