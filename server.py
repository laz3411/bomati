import http.server
import json
import os
import queue
import sys
import threading
import time

PORT = 8000
DIRECTORY = os.path.dirname(os.path.abspath(__file__))

# SSE 클라이언트 큐 관리
sse_clients = set()
sse_lock = threading.Lock()
latest_players_data = []
last_roblox_timestamp = 0

class RelayHTTPHandler(http.server.SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DIRECTORY, **kwargs)

    def log_message(self, format, *args):
        # 디버그 로그 필터링
        msg = format % args
        if "/api/status" in msg:
            return
        if "/api/" in msg or " 500 " in msg or " 404 " in msg:
            sys.stdout.write(f"[{time.strftime('%H:%M:%S')}] {msg}\n")

    def end_headers(self):
        # CORS 및 기본 헤더
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Content-Length")
        super().end_headers()

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        global sse_clients, latest_players_data, last_roblox_timestamp

        # 1. SSE 스트림 엔드포인트
        if self.path.startswith("/api/events"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-cache, no-transform")
            self.send_header("Connection", "keep-alive")
            self.send_header("X-Accel-Buffering", "no")
            self.end_headers()

            client_queue = queue.Queue(maxsize=100)
            with sse_lock:
                sse_clients.add(client_queue)
                client_count = len(sse_clients)

            print(f"[{time.strftime('%H:%M:%S')}] [PWA] 브라우저 연결됨 (총 {client_count}명 접속 중)")

            # 연결 즉시 최근 좌표가 있으면 즉시 전송
            try:
                if latest_players_data:
                    init_payload = json.dumps({"type": "update", "players": latest_players_data, "time": last_roblox_timestamp})
                    self.wfile.write(f"data: {init_payload}\n\n".encode("utf-8"))
                    self.wfile.flush()

                # 실시간 스트리밍 루프
                while True:
                    try:
                        data = client_queue.get(timeout=15.0)
                        self.wfile.write(f"data: {data}\n\n".encode("utf-8"))
                        self.wfile.flush()
                    except queue.Empty:
                        self.wfile.write(b": keepalive\n\n")
                        self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                with sse_lock:
                    sse_clients.discard(client_queue)
                    client_count = len(sse_clients)
                print(f"[{time.strftime('%H:%M:%S')}] [PWA] 브라우저 연결 종료 (남은 접속자: {client_count}명)")
            return

        # 2. 상태 확인 엔드포인트
        elif self.path.startswith("/api/status"):
            status_obj = {
                "server": "running",
                "connected_clients": len(sse_clients),
                "last_roblox_received": last_roblox_timestamp,
                "player_count": len(latest_players_data)
            }
            body = json.dumps(status_obj).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        # 3. 일반 정적 파일 서빙
        super().do_GET()

    def do_POST(self):
        global sse_clients, latest_players_data, last_roblox_timestamp

        if self.path == "/api/position" or self.path == "/position":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length)

            try:
                data = json.loads(body.decode("utf-8"))
                last_roblox_timestamp = time.time()
                latest_players_data = data if isinstance(data, list) else data.get("players", [])

                # 연결된 웹 클라이언트들에 브로드캐스트
                payload = json.dumps({"type": "update", "players": latest_players_data, "time": last_roblox_timestamp})
                with sse_lock:
                    for q in list(sse_clients):
                        try:
                            q.put_nowait(payload)
                        except queue.Full:
                            pass

                res_body = b'{"status":"ok"}'
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(res_body)))
                self.send_header("Connection", "keep-alive")
                self.end_headers()
                self.wfile.write(res_body)
                self.wfile.flush()
            except Exception as e:
                err_body = json.dumps({"error": str(e)}).encode("utf-8")
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(err_body)))
                self.end_headers()
                self.wfile.write(err_body)
                self.wfile.flush()
            return

        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()

def run_server():
    server_address = ("0.0.0.0", PORT)
    httpd = http.server.ThreadingHTTPServer(server_address, RelayHTTPHandler)
    print("=" * 60)
    print(" [로블록스 -> PWA 실시간 지도 중계 서버]")
    print(f" * 웹 브라우저 접속 주소: http://localhost:{PORT}")
    print(f" * 로블록스 데이터 수신 주소: http://127.0.0.1:{PORT}/api/position")
    print("=" * 60)
    print("서버가 백그라운드에서 정상 대기 중입니다. (종료: Ctrl + C)")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n서버를 종료합니다.")
        httpd.server_close()

if __name__ == "__main__":
    run_server()
