"""notes-api: a deliberately tiny HTTP service to practise packaging with Helm.

Standard library only (no pip, no requirements.txt). The behaviour is driven by
three environment variables, which the Helm chart will supply from a ConfigMap:

  MAX_NOTE_LENGTH  longest note accepted (default 280). Longer -> HTTP 413.
  READ_ONLY        "true" turns POST /notes into HTTP 403 (default "false").
  LOG_LEVEL        "debug" logs every request, anything else only startup.

Endpoints:
  GET  /          who am I, and the config I am running with
  GET  /healthz   {"status": "ok"}   <- the probes and `helm test` use this
  GET  /notes     the notes held in memory (per pod: no database, on purpose)
  POST /notes     {"text": "..."} -> 201, or 400 / 403 / 413
"""
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = os.environ.get("VERSION", "dev")
LEVELS = ("debug", "info", "warn", "error")


def load_config(env):
    """Parse and validate the environment. A bad value is a startup error, so a
    bad release crash-loops loudly instead of misbehaving quietly."""
    try:
        max_len = int(env.get("MAX_NOTE_LENGTH", "280"))
        if max_len < 1:
            raise ValueError
    except ValueError:
        raise SystemExit("MAX_NOTE_LENGTH must be a positive integer, got %r" % env.get("MAX_NOTE_LENGTH"))
    read_only = env.get("READ_ONLY", "false").strip().lower()
    if read_only not in ("true", "false"):
        raise SystemExit("READ_ONLY must be true or false, got %r" % env.get("READ_ONLY"))
    level = env.get("LOG_LEVEL", "info").strip().lower()
    if level not in LEVELS:
        raise SystemExit("LOG_LEVEL must be one of %s, got %r" % (", ".join(LEVELS), env.get("LOG_LEVEL")))
    return {"max_note_length": max_len, "read_only": read_only == "true", "log_level": level}


def make_handler(cfg, notes, lock):
    class Handler(BaseHTTPRequestHandler):
        server_version = "notes-api"

        def _send(self, code, body):
            data = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, fmt, *args):
            if cfg["log_level"] == "debug":
                sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

        def do_GET(self):
            if self.path == "/healthz":
                self._send(200, {"status": "ok"})
            elif self.path == "/":
                with lock:
                    count = len(notes)
                self._send(200, {"app": "notes-api", "version": VERSION, "notes": count,
                                 "max_note_length": cfg["max_note_length"], "read_only": cfg["read_only"]})
            elif self.path == "/notes":
                with lock:
                    self._send(200, {"notes": list(notes)})
            else:
                self._send(404, {"error": "not found"})

        def do_POST(self):
            if self.path != "/notes":
                return self._send(404, {"error": "not found"})
            if cfg["read_only"]:
                return self._send(403, {"error": "read-only mode"})
            try:
                length = int(self.headers.get("Content-Length", "0"))
                text = json.loads(self.rfile.read(length))["text"]
                if not isinstance(text, str) or not text:
                    raise ValueError
            except (ValueError, KeyError, TypeError):
                return self._send(400, {"error": 'body must be JSON like {"text": "..."}'})
            if len(text) > cfg["max_note_length"]:
                return self._send(413, {"error": "note longer than %d characters" % cfg["max_note_length"]})
            with lock:
                notes.append({"id": len(notes) + 1, "text": text})
                note = notes[-1]
            self._send(201, note)

    return Handler


def make_server(cfg, port):
    return ThreadingHTTPServer(("0.0.0.0", port), make_handler(cfg, [], threading.Lock()))


if __name__ == "__main__":
    config = load_config(os.environ)
    port = int(os.environ.get("PORT", "8080"))
    print("notes-api %s listening on :%d with %s" % (VERSION, port, config), flush=True)
    make_server(config, port).serve_forever()
