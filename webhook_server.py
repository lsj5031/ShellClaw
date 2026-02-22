#!/usr/bin/env python3
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT_DIR = os.path.dirname(os.path.abspath(__file__))
QUEUE_PATH = os.path.join(ROOT_DIR, "runtime", "webhook_updates.jsonl")
BIND = os.environ.get("WEBHOOK_BIND", "127.0.0.1:8787")
HOST, PORT = BIND.rsplit(":", 1)
PORT = int(PORT)

os.makedirs(os.path.dirname(QUEUE_PATH), exist_ok=True)

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw.decode("utf-8"))
        except Exception:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b"bad json")
            return

        with open(QUEUE_PATH, "a", encoding="utf-8") as f:
            f.write(json.dumps(data, ensure_ascii=False) + "\n")

        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *_args):
        return

if __name__ == "__main__":
    server = HTTPServer((HOST, PORT), Handler)
    print(f"webhook server listening on {HOST}:{PORT}")
    server.serve_forever()
