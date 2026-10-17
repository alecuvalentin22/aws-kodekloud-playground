#!/usr/bin/env bash
# Shared helpers for art.sh and check.sh. Source this file; do not run it.
#
# The password is never put on a command line (command lines are visible to
# every user of the machine through `ps`). It comes from HOMELAB_ADMIN_PASSWORD,
# or is typed at a hidden prompt, and goes to curl through a config file in a
# private temp directory (mode 600) that is removed when the script exits.

ART_URL="${ART_URL:-http://artifactory.192.168.0.23.nip.io}"
ART_USER="${ART_USER:-admin}"
EX_PREFIX="${EX_PREFIX:-candidate}"

art_init() {
  if [ -z "${HOMELAB_ADMIN_PASSWORD:-}" ]; then
    if [ ! -t 0 ]; then
      echo "Set HOMELAB_ADMIN_PASSWORD, or run this in a terminal to be asked for it." >&2
      exit 2
    fi
    printf 'Shared lab password (what you type is hidden): ' >&2
    read -r -s HOMELAB_ADMIN_PASSWORD
    echo >&2
  fi
  ART_TMP="$(mktemp -d "${TMPDIR:-/tmp}/art.XXXXXX")"
  chmod 700 "$ART_TMP"
  trap 'rm -rf "$ART_TMP"' EXIT
  local esc
  # curl config syntax: inside "..." a backslash and a double quote must be escaped.
  esc="$(printf '%s' "$HOMELAB_ADMIN_PASSWORD" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
  (
    umask 077
    printf 'user = "%s:%s"\n' "$ART_USER" "$esc" > "$ART_TMP/curl.cfg"
  )
}

# art_req METHOD PATH [extra curl args]
# PATH is relative to <ART_URL>/artifactory, e.g. /api/repositories.
# Sets ART_CODE (HTTP status, 000 if the connection failed); the body is in $ART_TMP/body.
art_req() {
  local m="$1" p="$2"
  shift 2
  ART_CODE="$(curl -sS -m 180 -K "$ART_TMP/curl.cfg" -X "$m" -o "$ART_TMP/body" \
    -w '%{http_code}' "$@" "$ART_URL/artifactory$p" 2>"$ART_TMP/err")" || ART_CODE=000
}

# art_anon METHOD PATH : same, without credentials. Sets ART_CODE.
art_anon() {
  ART_CODE="$(curl -sS -m 60 -X "$1" -o "$ART_TMP/body" -w '%{http_code}' \
    "$ART_URL/artifactory$2" 2>"$ART_TMP/err")" || ART_CODE=000
}

# pj PYTHON_EXPRESSION [FILE] : evaluate an expression on the JSON document `d`
# (default file: the last response body). Prints "" if anything goes wrong.
pj() {
  python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    r = eval(sys.argv[2])
    print("" if r is None else r)
except Exception:
    print("")
' "${2:-$ART_TMP/body}" "$1"
}

# A UI session (cookie) is what the OSS edition accepts for creating repositories.
# Sets ART_CODE; the body is in $ART_TMP/body.
art_ui_login() {
  local esc
  esc="$(printf '%s' "$HOMELAB_ADMIN_PASSWORD" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  (
    umask 077
    printf '{"user":"%s","password":%s,"type":"login"}' "$ART_USER" "$esc" > "$ART_TMP/login.json"
  )
  ART_CODE="$(curl -sS -m 60 -c "$ART_TMP/cookies" -o "$ART_TMP/body" -w '%{http_code}' \
    -H 'Content-Type: application/json' -H 'X-Requested-With: XMLHttpRequest' \
    -H "Origin: $ART_URL" --data-binary "@$ART_TMP/login.json" \
    "$ART_URL/ui/api/v1/ui/auth/login" 2>"$ART_TMP/err")" || ART_CODE=000
}

# art_ui_post PATH JSON : POST to the UI API with the session cookie.
art_ui_post() {
  printf '%s' "$2" > "$ART_TMP/payload.json"
  ART_CODE="$(curl -sS -m 60 -b "$ART_TMP/cookies" -o "$ART_TMP/body" -w '%{http_code}' \
    -H 'Content-Type: application/json' -H 'X-Requested-With: XMLHttpRequest' \
    -H "Origin: $ART_URL" --data-binary "@$ART_TMP/payload.json" \
    "$ART_URL/ui/api/v1/ui$1" 2>"$ART_TMP/err")" || ART_CODE=000
}
