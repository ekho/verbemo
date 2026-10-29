#!/usr/bin/env python3
"""Loopback-only synthetic Ollama response for UX69; no model or outbound calls."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sys
import time


class Handler(BaseHTTPRequestHandler):
    def reply(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass  # Cancelled UI requests may close the connection first.

    def do_GET(self):
        if self.path == "/api/tags":
            self.reply(200, {"models": [{"name": "ux69-synthetic", "size": 1}]})
        else:
            self.reply(404, {"error": "Synthetic UX69: unknown route"})

    def do_POST(self):
        if self.path != "/api/chat":
            self.reply(404, {"error": "Synthetic UX69: unknown route"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 1_000_000:
                raise ValueError("invalid length")
            request = json.loads(self.rfile.read(length))
            if not isinstance(request, dict) or request.get("model") != "ux69-synthetic":
                raise ValueError("unexpected model")
        except (ValueError, UnicodeError):
            self.reply(400, {"error": "Synthetic UX69: invalid request"})
            return
        mode = self.server.mode_file.read_text().strip()
        print(f"Synthetic chat received: {mode}", flush=True)
        # shortcut: hold is time-bounded; use an HTTP test harness for concurrency tests.
        deadline = time.monotonic() + 180
        while mode == "hold" and time.monotonic() < deadline:
            time.sleep(0.1)
            mode = self.server.mode_file.read_text().strip()
        if mode == "success":
            self.reply(200, {"message": {"content": "# UX69: тестовая сводка\n\nЛокальный ответ получен. Это проверка интерфейса, не качества модели."}})
        else:
            self.reply(500, {"error": "Synthetic UX69: controlled failure"})


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: mock-summary.py MODE_FILE (hold / error / success)")
    mode_file = Path(sys.argv[1]).resolve()
    assert mode_file.read_text().strip() in {"hold", "error", "success"}
    server = ThreadingHTTPServer(("127.0.0.1", 18969), Handler)
    server.mode_file = mode_file
    print("Synthetic Ollama listening on 127.0.0.1:18969", flush=True)
    server.serve_forever()
