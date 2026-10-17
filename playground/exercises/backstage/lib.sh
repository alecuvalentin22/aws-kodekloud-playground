#!/usr/bin/env bash
# Shared helpers for bs.sh and check.sh. Source this file; do not run it.
#
# Backstage here lets anyone in as "guest" (no password). The guest token is
# still kept out of command lines, the same way the Artifactory scripts do it:
# it goes to curl through a config file in a private temp directory (mode 600)
# that is removed when the script exits.

BS_URL="${BS_URL:-http://backstage.192.168.0.23.nip.io}"
EX_PREFIX="${EX_PREFIX:-candidate}"

bs_init() {
  BS_TMP="$(mktemp -d "${TMPDIR:-/tmp}/bs.XXXXXX")"
  chmod 700 "$BS_TMP"
  trap 'rm -rf "$BS_TMP"' EXIT
  local code token
  # This is what the "Enter" button on the sign-in page does.
  code="$(curl -sS -m 30 -o "$BS_TMP/auth.json" -w '%{http_code}' "$BS_URL/api/auth/guest/refresh" 2>"$BS_TMP/err")" || code=000
  [ "$code" = 200 ] || { echo "Backstage guest sign-in failed (HTTP $code) at $BS_URL" >&2; return 1; }
  token="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["backstageIdentity"]["token"])' "$BS_TMP/auth.json" 2>/dev/null)"
  [ -n "$token" ] || { echo "Backstage answered, but there was no guest token in the reply." >&2; return 1; }
  (
    umask 077
    printf 'header = "Authorization: Bearer %s"\n' "$token" > "$BS_TMP/curl.cfg"
  )
}

# bs_req METHOD PATH [extra curl args]
# Sets BS_CODE (HTTP status, 000 if the connection failed); the body is in $BS_TMP/body.
bs_req() {
  local m="$1" p="$2"
  shift 2
  BS_CODE="$(curl -sS -m 90 -K "$BS_TMP/curl.cfg" -X "$m" -H 'Content-Type: application/json' \
    -o "$BS_TMP/body" -w '%{http_code}' "$@" "$BS_URL$p" 2>"$BS_TMP/err")" || BS_CODE=000
}

# bs_post PATH JSON : POST a JSON document (kept in a file, not on the command line).
bs_post() {
  printf '%s' "$2" > "$BS_TMP/payload.json"
  bs_req POST "$1" --data-binary "@$BS_TMP/payload.json"
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
' "${2:-$BS_TMP/body}" "$1"
}

# err_msg : the error message of the last failed reply, one line.
err_msg() {
  pj "d['error']['message'] if 'error' in d else (d['errors'][0]['message'] if 'errors' in d else '')"
}
