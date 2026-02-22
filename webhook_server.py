#!/usr/bin/env python3
import fcntl
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT_DIR = os.path.dirname(os.path.abspath(__file__))
QUEUE_PATH = os.path.join(ROOT_DIR, "runtime", "webhook_updates.jsonl")
LOCK_PATH = os.path.join(ROOT_DIR, "runtime", "webhook_queue.lock")
FIFO_PATH = os.path.join(ROOT_DIR, "runtime", "webhook_notify.fifo")
BIND = os.environ.get("WEBHOOK_BIND", "127.0.0.1:8787")
HOST, PORT = BIND.rsplit(":", 1)
PORT = int(PORT)
SECRET = os.environ.get("WEBHOOK_SECRET", "")

os.makedirs(os.path.dirname(QUEUE_PATH), exist_ok=True)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        if SECRET:
            token = self.headers.get("X-Telegram-Bot-Api-Secret-Token", "")
            if token != SECRET:
                self.send_response(403)
                self.end_headers()
                self.wfile.write(b"forbidden")
                return

        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw.decode("utf-8"))
        except Exception:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b"bad json")
            return

        with open(LOCK_PATH, "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            with open(QUEUE_PATH, "a", encoding="utf-8") as f:
                f.write(json.dumps(data, ensure_ascii=False) + "\n")

        # Signal the agent loop via FIFO (non-blocking, best-effort)
        try:
            fd = os.open(FIFO_PATH, os.O_WRONLY | os.O_NONBLOCK)
            os.write(fd, b"\n")
            os.close(fd)
        except OSError:
            pass

        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *_args):
        return


if __name__ == "__main__":
    server = HTTPServer((HOST, PORT), Handler)
    print(f"webhook server listening on {HOST}:{PORT}")
    if SECRET:
        print("secret token verification enabled")
    server.serve_forever()
