#!/usr/bin/env python3
import html
import os
import sqlite3
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT_DIR = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.environ.get("SQLITE_DB_PATH", os.path.join(ROOT_DIR, "state.db"))
if not os.path.isabs(DB_PATH):
    DB_PATH = os.path.join(ROOT_DIR, DB_PATH)

HOST = "0.0.0.0"
PORT = 8080

CSS = """
:root {
  --bg: #f4f6ef;
  --paper: #fffef9;
  --ink: #1f2a1f;
  --accent: #2d6a4f;
  --muted: #6b7c68;
}
body { font-family: 'IBM Plex Sans', 'Segoe UI', sans-serif; margin: 0; background: linear-gradient(160deg, var(--bg), #e6ede0); color: var(--ink); }
main { max-width: 1100px; margin: 24px auto; padding: 0 16px; }
.card { background: var(--paper); border-radius: 12px; box-shadow: 0 6px 24px rgba(31,42,31,.09); padding: 16px; }
h1 { margin: 0 0 8px 0; }
small { color: var(--muted); }
table { width: 100%; border-collapse: collapse; font-size: 14px; }
th, td { text-align: left; border-bottom: 1px solid #d8e1d3; padding: 8px; vertical-align: top; }
th { color: var(--accent); }
pre { white-space: pre-wrap; margin: 0; font-family: 'IBM Plex Mono', monospace; }
"""


def fetch_turns(limit=50):
    if not os.path.exists(DB_PATH):
        return []
    conn = sqlite3.connect(DB_PATH)
    try:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT ts, input_type, user_text, asr_text, telegram_reply, voice_reply, status
            FROM turns
            ORDER BY id DESC
            LIMIT ?
            """,
            (limit,),
        )
        return cur.fetchall()
    finally:
        conn.close()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        rows = fetch_turns(50)
        now = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%SZ")

        html_rows = []
        for ts, input_type, user_text, asr_text, text_reply, voice_reply, status in rows:
            html_rows.append(
                "<tr>"
                f"<td>{html.escape(ts or '')}</td>"
                f"<td>{html.escape(input_type or '')}</td>"
                f"<td><pre>{html.escape(user_text or '')}</pre></td>"
                f"<td><pre>{html.escape(asr_text or '')}</pre></td>"
                f"<td><pre>{html.escape(text_reply or '')}</pre></td>"
                f"<td><pre>{html.escape(voice_reply or '')}</pre></td>"
                f"<td>{html.escape(status or '')}</td>"
                "</tr>"
            )

        content = f"""
<!doctype html>
<html>
  <head>
    <meta charset=\"utf-8\" />
    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />
    <title>MinusculeClaw Dashboard</title>
    <style>{CSS}</style>
  </head>
  <body>
    <main>
      <div class=\"card\">
        <h1>MinusculeClaw</h1>
        <small>Last 50 turns from SQLite | Rendered at {now}</small>
      </div>
      <div class=\"card\" style=\"margin-top:16px\">
        <table>
          <thead>
            <tr>
              <th>Timestamp</th>
              <th>Input</th>
              <th>User Text</th>
              <th>ASR Text</th>
              <th>Telegram Reply</th>
              <th>Voice Reply</th>
              <th>Status</th>
            </tr>
          </thead>
          <tbody>
            {''.join(html_rows) if html_rows else '<tr><td colspan="7">No turns recorded yet.</td></tr>'}
          </tbody>
        </table>
      </div>
    </main>
  </body>
</html>
"""

        encoded = content.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, *_args):
        return


if __name__ == "__main__":
    server = HTTPServer((HOST, PORT), Handler)
    print(f"dashboard listening on http://{HOST}:{PORT}")
    server.serve_forever()
