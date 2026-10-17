#!/usr/bin/env bash
# Optional board sync: moves a drill's ticket on the Plane board as the game
# progresses. Called by `play`, or by hand:
#
#   lib/tracker.sh start    NN                 -> In Progress + comment
#   lib/tracker.sh solved   NN "<text>"        -> Done + comment
#   lib/tracker.sh journal  NN <file|text>     -> comment with the journal (skipped while it is the empty template)
#   lib/tracker.sh revealed NN "<text>"        -> Needs replay + label `revealed` + comment
#
# NEVER fatal and never slow: every request has a 3 s connect / 5 s total limit,
# the first failure stops the run with ONE line on stderr, and the exit status is
# always 0, so the game is unaffected by the board being down, misconfigured or
# absent. With no config at all it prints nothing.
#
# Config: ${TRACKER_ENV:-~/.config/platform-lab/tracker.env} (TRACKER_URL,
# TRACKER_WORKSPACE, TRACKER_PROJECT, TRACKER_TOKEN; mode 600, never in git).
# Variables already exported in the environment win over the file.
#
# The token only ever travels in a curl config on a process substitution, never
# on a command line (ps would show it) and never on screen.
set -uo pipefail

SRC=platform-lab-playground
EVENT=${1:-}
ID=${2:-}
ARG=${3:-}

# --- config -----------------------------------------------------------------
ENV_FILE=${TRACKER_ENV:-$HOME/.config/platform-lab/tracker.env}
_o_url=${TRACKER_URL:-}; _o_ws=${TRACKER_WORKSPACE:-}; _o_pj=${TRACKER_PROJECT:-}; _o_tok=${TRACKER_TOKEN:-}
if [[ -f $ENV_FILE ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE" 2>/dev/null
fi
[[ -n $_o_url ]] && TRACKER_URL=$_o_url
[[ -n $_o_ws ]] && TRACKER_WORKSPACE=$_o_ws
[[ -n $_o_pj ]] && TRACKER_PROJECT=$_o_pj
[[ -n $_o_tok ]] && TRACKER_TOKEN=$_o_tok
TRACKER_URL=${TRACKER_URL:-}
TRACKER_TOKEN=${TRACKER_TOKEN:-}
TRACKER_WORKSPACE=${TRACKER_WORKSPACE:-interview-prep}
TRACKER_PROJECT=${TRACKER_PROJECT:-PREP}

[[ -n $TRACKER_URL ]] || exit 0                       # not configured: silent
note() { printf '\033[2m  tracker: %s\033[0m\n' "$*"; }
fail() { printf '  ! tracker: %s (the game is unaffected)\n' "$*" >&2; exit 0; }
[[ -n $TRACKER_TOKEN ]] || fail "TRACKER_TOKEN is not set"
command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || fail "needs curl and jq"
case $EVENT in start|solved|journal|revealed) ;; *) fail "usage: tracker.sh start|solved|journal|revealed NN [text|file]" ;; esac
[[ $ID =~ ^[0-9]+$ ]] || fail "bad drill id '$ID'"

# --- id cache -----------------------------------------------------------------
# Plane answers in ~1 s per request, so five lookups before every write would put
# 5 s on each play command. The ids that never change (project, states, the
# `revealed` label, a drill's work item) are remembered in a small file; a warm
# run is one or two requests. A stale id (instance rebuilt) makes a write fail
# with 4xx: the cache is dropped and the run repeats once with fresh lookups.
CACHE_DIR=${XDG_CACHE_HOME:-$HOME/.cache}/platform-lab
CACHE_FILE="$CACHE_DIR/tracker-ids.$(printf '%s' "$TRACKER_URL/$TRACKER_WORKSPACE/$TRACKER_PROJECT" | cksum | cut -d' ' -f1)"
USED_CACHE=0
cget() { [[ -f $CACHE_FILE ]] && sed -n "s/^$1=//p" "$CACHE_FILE" | tail -1; }
cset() { ( umask 077; mkdir -p "$CACHE_DIR" && printf '%s=%s\n' "$1" "$2" >> "$CACHE_FILE" ) 2>/dev/null; return 0; }
slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9\n' _; }

# --- HTTP -------------------------------------------------------------------
API="${TRACKER_URL%/}/api/v1/workspaces/$TRACKER_WORKSPACE"
CODE=; BODY=; ALLOW404=0
api() {   # METHOD PATH [JSON]  -> sets CODE and BODY; stops the run on a transport error or an HTTP error
  local m=$1 p=$2 d=${3:-} out rc
  if [[ -n $d ]]; then
    out=$(printf '%s' "$d" | curl -sS --connect-timeout 3 --max-time 5 \
      -K <(printf 'header = "X-API-Key: %s"\n' "$TRACKER_TOKEN") \
      -X "$m" -H 'Content-Type: application/json' --data-binary @- \
      -w $'\n%{http_code}' "$API/$p" 2>/dev/null); rc=$?
  else
    out=$(curl -sS --connect-timeout 3 --max-time 5 \
      -K <(printf 'header = "X-API-Key: %s"\n' "$TRACKER_TOKEN") \
      -X "$m" -w $'\n%{http_code}' "$API/$p" 2>/dev/null </dev/null); rc=$?
  fi
  (( rc == 0 )) || fail "cannot reach $TRACKER_URL (curl exit $rc)"
  CODE=${out##*$'\n'}
  BODY=${out%$'\n'*}
  case $CODE in
    2??) ;;
    401|403) fail "token rejected (HTTP $CODE)" ;;
    429) fail "rate limited (HTTP 429)" ;;
    404) (( ALLOW404 )) && return 0
         stale_or_fail "$m $p answered HTTP 404" ;;
    4??) stale_or_fail "$m $p answered HTTP $CODE" ;;
    *) fail "$m $p answered HTTP $CODE" ;;
  esac
}
stale_or_fail() {
  if (( USED_CACHE )) && [[ -z ${TRACKER_RETRY:-} ]]; then
    rm -f "$CACHE_FILE" 2>/dev/null
    TRACKER_RETRY=1 exec "$0" "$EVENT" "$ID" "$ARG"
  fi
  fail "$1"
}

esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# --- journal: skip while it is still the empty template -----------------------
JOURNAL_HTML=
if [[ $EVENT == journal ]]; then
  if [[ -f $ARG ]]; then
    if ! grep -v '^[[:space:]]*#' "$ARG" | grep -q '[^[:space:]]'; then
      note "journal for $ID is still the empty template, not posted"
      exit 0
    fi
    # markdown -> comment HTML: headings become <h3>, each text line a paragraph
    JOURNAL_HTML=$(esc < "$ARG" | awk '
      /^[ \t]*$/ { next }
      /^#+[ \t]/ { sub(/^#+[ \t]+/, ""); print "<h3>" $0 "</h3>"; next }
      { print "<p>" $0 "</p>" }')
  else
    fail "journal file not found: $ARG"
  fi
fi

# --- lookups ------------------------------------------------------------------
PID=$(cget pid)
if [[ -n $PID ]]; then USED_CACHE=1
else
  api GET "projects/"
  PID=$(jq -r --arg i "$TRACKER_PROJECT" '(if type=="array" then . else .results // [] end)
    | map(select(.identifier==$i)) | .[0].id // empty' <<<"$BODY")
  [[ -n $PID ]] || fail "project $TRACKER_PROJECT not found (run playground/tracker/sync.sh)"
  cset pid "$PID"
fi

ITEM=
IID=$(cget "item_$ID"); SEQ=$(cget "seq_$ID")
if [[ -n $IID && -n $SEQ ]]; then USED_CACHE=1
else
  ALLOW404=1
  api GET "projects/$PID/work-items/?external_id=drill-$ID&external_source=$SRC"
  ALLOW404=0
  [[ $CODE == 404 ]] && fail "drill $ID is not on the board (run playground/tracker/sync.sh)"
  ITEM=$(jq -c 'if type=="object" and has("results") then .results[0] else . end // empty' <<<"$BODY")
  IID=$(jq -r '.id // empty' <<<"$ITEM" 2>/dev/null)
  [[ -n $IID ]] || fail "drill $ID is not on the board (run playground/tracker/sync.sh)"
  SEQ=$(jq -r '.sequence_id // empty' <<<"$ITEM")
  cset "item_$ID" "$IID"; cset "seq_$ID" "$SEQ"
fi
REF="$TRACKER_PROJECT-$SEQ"

# These set a global instead of printing: fail() must run in the main shell to
# end the run, and a $(...) subshell would swallow it.
SID=; LID=
state_id() {   # NAME -> $SID
  SID=$(cget "st_$(slug "$1")")
  if [[ -n $SID ]]; then USED_CACHE=1; return; fi
  api GET "projects/$PID/states/"
  SID=$(jq -r --arg n "$1" '(if type=="array" then . else .results // [] end) | map(select(.name==$n)) | .[0].id // empty' <<<"$BODY")
  [[ -n $SID ]] || fail "state '$1' not found (run playground/tracker/sync.sh)"
  cset "st_$(slug "$1")" "$SID"
}

label_id() {   # NAME -> $LID (created when missing)
  LID=$(cget "lb_$(slug "$1")")
  if [[ -n $LID ]]; then USED_CACHE=1; return; fi
  api GET "projects/$PID/labels/"
  LID=$(jq -r --arg n "$1" '(if type=="array" then . else .results // [] end) | map(select(.name==$n)) | .[0].id // empty' <<<"$BODY")
  if [[ -z $LID ]]; then
    api POST "projects/$PID/labels/" "$(jq -nc --arg n "$1" '{name:$n, color:"#ef4444"}')"
    LID=$(jq -r '.id // empty' <<<"$BODY")
  fi
  [[ -n $LID ]] || fail "label '$1' unavailable"
  cset "lb_$(slug "$1")" "$LID"
}

comment() {   # HTML
  api POST "projects/$PID/work-items/$IID/comments/" "$(jq -nc --arg h "$1" '{comment_html:$h}')"
}

move() {   # STATE-NAME [JSON-extra]
  local body
  state_id "$1"
  body=$(jq -nc --arg s "$SID" '{state:$s}')
  [[ -n ${2:-} ]] && body=$(jq -c --argjson x "$2" '. + $x' <<<"$body")
  api PATCH "projects/$PID/work-items/$IID/" "$body"
}

TXT=$(printf '%s' "$ARG" | esc)
case $EVENT in
  start)
    move "In Progress"
    comment "<p>Started with <code>play start</code> at $(date '+%Y-%m-%d %H:%M')</p>"
    note_msg="$REF -> In Progress" ;;
  solved)
    move "Done"
    comment "<p>$TXT</p>"
    note_msg="$REF -> Done" ;;
  journal)
    comment "$JOURNAL_HTML"
    note_msg="$REF: journal posted as a comment" ;;
  revealed)
    label_id revealed
    api GET "projects/$PID/work-items/$IID/"          # current labels: keep them, add `revealed`
    labels=$(jq -c --arg l "$LID" '(.labels // []) | map(if type=="object" then .id else . end) | . + [$l] | unique' <<<"$BODY")
    move "Needs replay" "$(jq -nc --argjson l "$labels" '{labels:$l}')"
    comment "<p>Revealed (gave up): $TXT</p>"
    note_msg="$REF -> Needs replay" ;;
esac
printf '\033[32m  ✓ tracker: %s\033[0m\n' "$note_msg"
exit 0
