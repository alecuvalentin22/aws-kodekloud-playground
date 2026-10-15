"""${{ values.name }}: ${{ values.description }}"""
import os

from flask import Flask, jsonify

app = Flask(__name__)
VERSION = os.environ.get("VERSION", "dev")


@app.get("/")
def index():
    return jsonify(app="${{ values.name }}", version=VERSION)


@app.get("/healthz")
def healthz():
    return jsonify(status="ok")
