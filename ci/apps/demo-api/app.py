"""demo-api: the smallest service that still exercises a real pipeline.

Endpoints
  /          {"app": ..., "version": ...}  -- version is baked in at build time
  /healthz   200, or 500 when FAIL_HEALTH=true (used by the broken-deploy drill)
"""
import os

from flask import Flask, jsonify

app = Flask(__name__)
VERSION = os.environ.get("VERSION", "dev")


@app.get("/")
def index():
    return jsonify(app="demo-api", version=VERSION)


@app.get("/healthz")
def healthz():
    if os.environ.get("FAIL_HEALTH", "false").lower() == "true":
        return jsonify(status="unhealthy"), 500
    return jsonify(status="ok")
