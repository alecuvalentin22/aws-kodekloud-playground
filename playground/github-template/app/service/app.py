"""__REPO__: the smallest service that still exercises a real pipeline."""
import os

from flask import Flask, jsonify

app = Flask(__name__)
VERSION = os.environ.get("VERSION", "dev")


@app.get("/")
def index():
    return jsonify(app="__REPO__", version=VERSION)


@app.get("/healthz")
def healthz():
    return jsonify(status="ok")
