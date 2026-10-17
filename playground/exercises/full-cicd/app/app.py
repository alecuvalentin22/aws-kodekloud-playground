"""cicd-demo: the smallest service that still exercises a real release pipeline.

Endpoints
  /          {"app": ..., "version": ..., "mode": ...}  -- version is the git sha baked in at build time
  /healthz   200, or 500 when MODE=strict and KNOWN_BAD=true

MODE comes from a ConfigMap that each environment has (relaxed in staging,
strict in prod). KNOWN_BAD is how the exercise ships a deliberately bad release:
an image that is healthy everywhere except where the environment is strict.
"""
import os

from flask import Flask, jsonify

app = Flask(__name__)
VERSION = os.environ.get("VERSION", "dev")


def known_bad_in_strict_mode():
    return (os.environ.get("MODE") == "strict"
            and os.environ.get("KNOWN_BAD", "false").lower() == "true")


@app.get("/")
def index():
    return jsonify(app="cicd-demo", version=VERSION, mode=os.environ.get("MODE", "unset"))


@app.get("/healthz")
def healthz():
    if known_bad_in_strict_mode():
        return jsonify(status="unhealthy"), 500
    return jsonify(status="ok")
