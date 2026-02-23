#!/usr/bin/env python3
import fcntl
import json
import os
import signal
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib import parse, request

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
QUEUE_PATH = os.path.join(ROOT_DIR, "runtime", "webhook_updates.jsonl")
LOCK_PATH = os.path.join(ROOT_DIR, "runtime", "webhook_queue.lock")
FIFO_PATH = os.path.join(ROOT_DIR, "runtime", "webhook_notify.fifo")
CANCEL_PATH = os.path.join(ROOT_DIR, "runtime", "cancel")
PID_PATH = os.path.join(ROOT_DIR, "runtime", "codex.pid")
BIND = os.environ.get("WEBHOOK_BIND", "127.0.0.1:8787")
HOST, PORT = BIND.rsplit(":", 1)
PORT = int(PORT)
SECRET = os.environ.get("WEBHOOK_SECRET", "")
BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
CHAT_ID = (os.environ.get("TELEGRAM_CHAT_ID", "") or "").strip()

os.makedirs(os.path.dirname(QUEUE_PATH), exist_ok=True)


def _signal_cancel():
    """Write cancel signal and kill running codex process."""
    try:
        with open(CANCEL_PATH, "w"):
            pass
    except OSError:
        pass
    try:
        with open(PID_PATH) as f:
            pid = int(f.read().strip())
        os.kill(pid, signal.SIGTERM)
    except (FileNotFoundError, ValueError, ProcessLookupError, PermissionError, OSError):
        pass


def _answer_callback(callback_query_id: str, text: str = ""):
    """Acknowledge Telegram callback queries to clear client-side loading state."""
    if not callback_query_id or not BOT_TOKEN:
        return
    api = f"https://api.telegram.org/bot{BOT_TOKEN}/answerCallbackQuery"
    payload = {"callback_query_id": callback_query_id}
    if text:
        payload["text"] = text
    body = parse.urlencode(payload).encode("utf-8")
    req = request.Request(api, data=body, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    try:
        with request.urlopen(req, timeout=4):
            pass
    except OSError:
        pass


def _chat_id_from_message(msg):
    if not isinstance(msg, dict):
        return ""
    chat = msg.get("chat")
    if not isinstance(chat, dict):
        return ""
    return str(chat.get("id", ""))


def _is_allowed_chat(chat_id: str):
    # Keep behavior permissive if TELEGRAM_CHAT_ID is missing in the environment.
    if not CHAT_ID:
        return True
    return chat_id == CHAT_ID


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

        # Detect /cancel command and signal cancellation
        msg = data.get("message") if isinstance(data, dict) else None
        msg_chat_id = _chat_id_from_message(msg)
        if (
            isinstance(msg, dict)
            and _is_allowed_chat(msg_chat_id)
            and (msg.get("text") or "").strip().lower() == "/cancel"
        ):
            _signal_cancel()

        # Detect cancel button callback
        cb = data.get("callback_query") if isinstance(data, dict) else None
        if isinstance(cb, dict) and cb.get("data") == "cancel":
            cb_id = cb.get("id", "")
            cb_msg = cb.get("message")
            cb_chat_id = _chat_id_from_message(cb_msg)
            if _is_allowed_chat(cb_chat_id):
                _signal_cancel()
                _answer_callback(cb_id, "Cancelled")
            else:
                _answer_callback(cb_id)

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
