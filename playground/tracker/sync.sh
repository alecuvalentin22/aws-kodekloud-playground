#!/usr/bin/env bash
# Puts the playground's drills (and the build-it-yourself exercises) on the
# Plane board, and keeps the board in step with the repo. Idempotent: re-running
# updates what changed and never duplicates (every item has a stable
# external_id under external_source=platform-lab-playground).
#
#   playground/tracker/sync.sh --check      read-only: API reachable? project there? how many of our items?
#   playground/tracker/sync.sh --dry-run    print what would be created/updated, write nothing
#   playground/tracker/sync.sh              apply
#
# What lands on the board
#   project  PREP "Interview prep" (identifier from TRACKER_PROJECT)
#   state    "Needs replay" (unstarted) besides Plane's defaults
#   labels   track:<track>  tier:<needs>  unverified  exercise  revealed
#   modules  the "epics" (Plane CE has no Epic type): one per day of GUIDE.md,
#            plus GitHub tier, More local drills, Exercises
#   items    one per drill (drills/*/drill.env + ticket.md), one per exercise
#            (exercises/*/README.md), two task items (platform tour, mock interview)
#
# On UPDATE the item's state is never touched (the board follows the candidate's
# progress) and labels this script does not manage (e.g. `revealed`) are kept.
# hints.md and solution.md are never read.
#
# Config: ${TRACKER_ENV:-~/.config/platform-lab/tracker.env} with TRACKER_URL,
# TRACKER_WORKSPACE, TRACKER_PROJECT, TRACKER_TOKEN (mode 600). Needs curl + jq.
# The token is handed to curl on a process substitution, never on a command line.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PG_ROOT="$(cd "$HERE/.." && pwd)"
DRILLS="$PG_ROOT/drills"
EXERCISES="$PG_ROOT/exercises"
SRC=platform-lab-playground
GH_BLOB=https://github.com/alecuvalentin22/aws-kodekloud-playground/blob/feat/playground/playground

MODE=apply
case "${1:-}" in
  --check) MODE=check ;;
  --dry-run|-n) MODE=dry ;;
  "") ;;
  -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  *) echo "usage: $0 [--check | --dry-run]" >&2; exit 2 ;;
esac

die() { printf '  ✗ %s\n' "$*" >&2; exit 1; }
say() { printf '  %s\n' "$*"; }
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

# --- config (variables exported in the environment win over the file) -------------
ENV_FILE=${TRACKER_ENV:-$HOME/.config/platform-lab/tracker.env}
_o_url=${TRACKER_URL:-}; _o_ws=${TRACKER_WORKSPACE:-}; _o_pj=${TRACKER_PROJECT:-}; _o_tok=${TRACKER_TOKEN:-}
# No token handed in from the environment: make sure the file holds a working one.
# token.sh is a single GET when it does, and fetches/creates it (kubectl, no browser)
# when the file is missing or Plane rejects its token.
if [[ -z $_o_tok ]]; then
  "$HERE/token.sh" || die "no working API token (see tracker/README.md, \"Set up\")"
fi
if [[ -f $ENV_FILE ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi
[[ -n $_o_url ]] && TRACKER_URL=$_o_url
[[ -n $_o_ws ]] && TRACKER_WORKSPACE=$_o_ws
[[ -n $_o_pj ]] && TRACKER_PROJECT=$_o_pj
[[ -n $_o_tok ]] && TRACKER_TOKEN=$_o_tok
TRACKER_URL=${TRACKER_URL:-}; TRACKER_TOKEN=${TRACKER_TOKEN:-}
TRACKER_WORKSPACE=${TRACKER_WORKSPACE:-interview-prep}
TRACKER_PROJECT=${TRACKER_PROJECT:-PREP}
[[ -n $TRACKER_URL && -n $TRACKER_TOKEN ]] \
  || die "no tracker config: $ENV_FILE needs TRACKER_URL and TRACKER_TOKEN"
TRACKER_URL=${TRACKER_URL%/}
API="$TRACKER_URL/api/v1/workspaces/$TRACKER_WORKSPACE"

# --- HTTP ---------------------------------------------------------------------------
CODE=; BODY=
api() {   # METHOD PATH [JSON] -> sets CODE and BODY; returns 0 on 2xx. Retries 429 with backoff.
  local m=$1 p=$2 d=${3:-} out rc try=0
  while :; do
    try=$((try + 1))
    if [[ -n $d ]]; then
      out=$(printf '%s' "$d" | curl -sS --connect-timeout 5 --max-time 60 \
        -K <(printf 'header = "X-API-Key: %s"\n' "$TRACKER_TOKEN") \
        -X "$m" -H 'Content-Type: application/json' --data-binary @- \
        -w $'\n%{http_code}' "$API/$p" 2>/dev/null); rc=$?
    else
      out=$(curl -sS --connect-timeout 5 --max-time 60 \
        -K <(printf 'header = "X-API-Key: %s"\n' "$TRACKER_TOKEN") \
        -X "$m" -w $'\n%{http_code}' "$API/$p" 2>/dev/null </dev/null); rc=$?
    fi
    if (( rc != 0 )); then CODE=000; BODY="curl exit $rc"; return 1; fi
    CODE=${out##*$'\n'}; BODY=${out%$'\n'*}
    # 429: rate limited. 502/503/504: the proxy in front of Plane hiccups now and then
    # (a retried POST that did land answers 409 for work items, which the caller handles).
    case $CODE in 429|502|503|504) if (( try < 8 )); then sleep $(( try * 4 )); continue; fi ;; esac
    break
  done
  [[ $CODE == 2?? ]]
}
apif() {   # like api, but a failure ends the run
  api "$@" || die "$1 $2 -> HTTP $CODE: $(printf '%s' "$BODY" | head -c 300)"
}
api_all() {   # PATH -> every page flattened into one JSON array on stdout
  local p=$1 sep='?' cursor='' acc='' n=0 more
  [[ $p == *\?* ]] && sep='&'
  while :; do
    n=$((n + 1))
    api GET "${p}${sep}per_page=100${cursor:+&cursor=$cursor}" \
      || { echo "api_all $p -> HTTP $CODE" >&2; return 1; }
    acc="$acc$(jq -c 'if type=="array" then . elif type=="object" and has("results") then .results else [.] end' <<<"$BODY")"$'\n'
    more=$(jq -r 'if type=="object" and .next_page_results==true then (.next_cursor // "") else "" end' <<<"$BODY")
    [[ -n $more && $n -lt 100 ]] || break
    cursor=$more
  done
  printf '%s' "$acc" | jq -sc 'add // []'
}
esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# --- 0. reachability and project (shared by every mode) ---------------------------------
if ! api GET "projects/"; then
  case $CODE in
    000) die "cannot reach $TRACKER_URL ($BODY)" ;;
    401|403) die "$TRACKER_URL answered HTTP $CODE: the token is not accepted for workspace $TRACKER_WORKSPACE" ;;
    *) die "GET projects/ answered HTTP $CODE" ;;
  esac
fi
PROJECTS=$(api_all "projects/") || die "could not list projects"
PID=$(jq -r --arg i "$TRACKER_PROJECT" 'map(select(.identifier==$i)) | .[0].id // empty' <<<"$PROJECTS")

# --- the repo side: what should be on the board ----------------------------------------
# One TSV line per drill: id dir title track level par needs verified|unverified
drill_rows() {
  local d base id
  for d in "$DRILLS"/*/; do
    [[ -f $d/drill.env ]] || continue
    base=$(basename "$d"); id=${base%%-*}
    ( # shellcheck disable=SC1091
      source "$d/drill.env" 2>/dev/null
      v=verified; case "${VERIFIED:-}" in ""|no) v=unverified ;; esac
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$base" "${TITLE:-$base}" "${TRACK:-misc}" \
        "${LEVEL:-2}" "${PAR_MIN:-15}" "${NEEDS:-local}" "$v" )
  done
}
DRILL_ROWS=$(drill_rows)
EX_DIRS=""
for d in "$EXERCISES"/*/; do [[ -f $d/README.md ]] && EX_DIRS="$EX_DIRS$(basename "$d")"$'\n'; done
N_DRILLS=$(printf '%s' "$DRILL_ROWS" | grep -c . || true)
N_EX=$(printf '%s' "$EX_DIRS" | grep -c . || true)
N_EXPECT=$(( N_DRILLS + N_EX + 2 ))

if [[ $MODE == check ]]; then
  say "✓ API reachable: $TRACKER_URL (workspace $TRACKER_WORKSPACE, token accepted)"
  if [[ -z $PID ]]; then
    say "! project $TRACKER_PROJECT does not exist yet (a plain run creates it)"
    say "  expected after a sync: $N_EXPECT items ($N_DRILLS drills + $N_EX exercises + 2 tasks)"
    exit 0
  fi
  say "✓ project $TRACKER_PROJECT exists ($PID)"
  items=$(api_all "projects/$PID/work-items/") || die "could not list work items"
  n=$(jq --arg s "$SRC" '[.[]|select(.external_source==$s)]|length' <<<"$items")
  say "  items with external_source=$SRC: $n (a full sync has $N_EXPECT: $N_DRILLS drills + $N_EX exercises + 2 tasks)"
  exit 0
fi

DRY=false; [[ $MODE == dry ]] && DRY=true
n_created=0; n_updated=0; n_unchanged=0

# --- 1. project ----------------------------------------------------------------------------
PROJ_DESC="Interview-practice drills for a DevOps / CI-CD platform engineer role: one item per drill, grouped by the day of playground/GUIDE.md."
if [[ -z $PID ]]; then
  if $DRY; then say "would create project $TRACKER_PROJECT \"Interview prep\""
  else
    apif POST "projects/" "$(jq -nc --arg id "$TRACKER_PROJECT" --arg d "$PROJ_DESC" \
      '{name:"Interview prep", identifier:$id, description:$d, module_view:true}')"
    PID=$(jq -r '.id' <<<"$BODY"); say "created project $TRACKER_PROJECT ($PID)"
  fi
else
  # modules must be enabled, or the board has no place to show the epics
  mv=$(jq -r --arg i "$TRACKER_PROJECT" 'map(select(.identifier==$i)) | .[0].module_view' <<<"$PROJECTS")
  if [[ $mv != true ]]; then
    if $DRY; then say "would enable modules on project $TRACKER_PROJECT"
    else apif PATCH "projects/$PID/" '{"module_view":true}'; say "enabled modules on project $TRACKER_PROJECT"; fi
  fi
fi

# Everything below reads project data; a project that does not exist yet (dry
# run only) has none.
if [[ -n $PID ]]; then
  STATES=$(api_all "projects/$PID/states/") || die "could not list states"
  LABELS=$(api_all "projects/$PID/labels/") || die "could not list labels"
  MODULES=$(api_all "projects/$PID/modules/") || die "could not list modules"
  ITEMS=$(api_all "projects/$PID/work-items/") || die "could not list work items"
else
  STATES='[]'; LABELS='[]'; MODULES='[]'; ITEMS='[]'
fi
ITEMS=$(jq -c --arg s "$SRC" '[.[]|select(.external_source==$s)]' <<<"$ITEMS")

# --- 2. state "Needs replay" ----------------------------------------------------------------
if [[ -z $(jq -r '.[]|select(.name=="Needs replay")|.id' <<<"$STATES") ]]; then
  if $DRY; then say "would create state \"Needs replay\""
  else
    apif POST "projects/$PID/states/" '{"name":"Needs replay","color":"#ea580c","group":"unstarted"}'
    STATES=$(jq -c --argjson n "$BODY" '. + [$n]' <<<"$STATES"); say "created state \"Needs replay\""
  fi
fi
TODO_ID=$(jq -r 'map(select(.name=="Todo"))[0].id // (map(select(.group=="unstarted"))[0].id) // empty' <<<"$STATES")
[[ -n $TODO_ID ]] || { $DRY || die "no Todo state in project $TRACKER_PROJECT"; TODO_ID=dry:Todo; }

# --- 3. labels --------------------------------------------------------------------------------
label_color() {
  case $1 in
    track:jenkins) echo "#d33d17" ;; track:kubernetes) echo "#326ce5" ;; track:terraform) echo "#7b42bc" ;;
    track:aws) echo "#ff9900" ;; track:github) echo "#24292f" ;; track:*) echo "#64748b" ;;
    tier:local) echo "#16a34a" ;; tier:homelab) echo "#0d9488" ;; tier:aws) echo "#f97316" ;; tier:github) echo "#475569" ;;
    unverified) echo "#9ca3af" ;; exercise) echo "#8b5cf6" ;; revealed) echo "#ef4444" ;; *) echo "#64748b" ;;
  esac
}
ensure_label() {
  local name=$1
  [[ -n $(jq -r --arg n "$name" '.[]|select(.name==$n)|.id' <<<"$LABELS") ]] && return 0
  if $DRY; then
    say "would create label $name"
    LABELS=$(jq -c --arg n "$name" '. + [{id:("dry:"+$n), name:$n}]' <<<"$LABELS")
  else
    apif POST "projects/$PID/labels/" "$(jq -nc --arg n "$name" --arg c "$(label_color "$name")" '{name:$n, color:$c}')"
    LABELS=$(jq -c --argjson n "$BODY" '. + [$n]' <<<"$LABELS"); say "created label $name"
  fi
}
for l in $(printf '%s\n' "$DRILL_ROWS" | awk -F'\t' 'NF{print "track:" $4; print "tier:" $7}' | sort -u) unverified exercise revealed; do
  ensure_label "$l"
done

# --- 4. modules (epics) -----------------------------------------------------------------------
MODULE_KEYS="day1 day2 day3 day4 day5 day6 day7 jenkins2 jagents aws-cloudops github more exercises"
module_name() {
  case $1 in
    day1) echo "Day 1 — Jenkins pipelines" ;;
    day2) echo "Day 2 — Terraform and Kubernetes" ;;
    day3) echo "Day 3 — Jenkins agents and safety" ;;
    day4) echo "Day 4 — Blast radius and access" ;;
    day5) echo "Day 5 — Running the platform (home-lab tier)" ;;
    day6) echo "Day 6 — AWS: CI/CD on EKS (KodeKloud session)" ;;
    day7) echo "Day 7 — Mock interview" ;;
    jenkins2) echo "Jenkins: pipelines II" ;;
    jagents) echo "Jenkins: static agents" ;;
    aws-cloudops) echo "AWS: cloud-ops" ;;
    github) echo "GitHub tier" ;;
    more) echo "More local drills" ;;
    exercises) echo "Exercises (build it yourself)" ;;
  esac
}
module_desc() {
  case $1 in
    day1) echo "Why a build can fail before its first stage and how shared-library versions are chosen, and why a red pipeline can be the system protecting you. After both: play close on each, then play reveal on the harder one and compare your words with the interview answer." ;;
    day2) echo "Reading a terraform plan as a review and changing code without destroying things, then where Kubernetes hides the reason when nothing happens." ;;
    day3) echo "How build agents get scheduled and why one change hit everyone, then saying no to a developer while still solving their problem." ;;
    day4) echo "Fixing a shared library that broke every team (revert vs force-push, releasing safely), then least privilege and proving access with kubectl auth can-i." ;;
    day5) echo "The home-lab drills break the lab itself, so run them from a Mac terminal in the repo (playground/play start 21, then 24), then give the platform tour out loud as if to an interviewer." ;;
    day6) echo "Real ECR and real IAM on EKS in one KodeKloud AWS session of about 3 hours: start the playground first, then make eks and playground/setup/up-aws.sh. play refuses to start an AWS drill with under 20 minutes left in the session." ;;
    day7) echo "play start with no number gives a random drill you have not solved, and you are not told which. Do two, talking out loud, then re-read your journal and practise each STAR story in under two minutes." ;;
    jenkins2) echo "After Day 4: writing and releasing a shared-library step (09), pipelines that cannot fail, per-stage workspaces, approvals that hold agents, credential scope, triggers, multibranch discovery, the parameter trap, downstream jobs (41-48). On the box: play start NN." ;;
    jagents) echo "Static (permanent) agents next to the dynamic pod agents: an agent that went offline, workspace leftovers between builds, a full agent disk (51-53). Needs playground/setup/static-agent.sh up." ;;
    aws-cloudops) echo "Cloud operations on the AWS account, no Jenkins needed: volumes and AZs, Terraform drift/import/locks, IAM trust and deny, S3 versioning and guardrails, CloudTrail forensics, CloudWatch alarms, ECR tags, DNS, network ACLs, STS sessions. Same KodeKloud session as Day 6." ;;
    github) echo "Real GitHub, Actions and GHCR on your own account: pull requests, required checks, shared workflows. Needs the GitHub token and playground/setup/up-github.sh (see playground/setup/GITHUB.md)." ;;
    more) echo "Extra local drills outside the 7-day plan, run on the lab box like days 1 to 4. After the plan: replay anything under 80 points (play list shows your best scores)." ;;
    exercises) echo "Not scored: nothing breaks and there is no clock. You build something by hand in the lab (Artifactory, Backstage and more) so you can say \"I have done this\"." ;;
  esac
}
module_for_drill() {   # id needs
  case $1 in
    01|02) echo day1 ;; 08|03) echo day2 ;; 05|04) echo day3 ;; 07|06) echo day4 ;;
    09|4[1-8]) echo jenkins2 ;; 5[1-3]) echo jagents ;;
    1[1-6]) echo day6 ;;
    *) case $2 in homelab) echo day5 ;; aws) echo aws-cloudops ;; github) echo github ;; *) echo more ;; esac ;;
  esac
}
module_id() { jq -r --arg e "epic-$1" --arg s "$SRC" '.[]|select(.external_id==$e and .external_source==$s)|.id' <<<"$MODULES" | head -1; }

for k in $MODULE_KEYS; do
  name=$(module_name "$k"); desc=$(module_desc "$k"); mid=$(module_id "$k")
  if [[ -z $mid ]]; then
    if $DRY; then say "would create module $name"; MODULES=$(jq -c --arg e "epic-$k" --arg s "$SRC" '. + [{id:("dry:"+$e), name:"", description:"", external_id:$e, external_source:$s}]' <<<"$MODULES")
    else
      apif POST "projects/$PID/modules/" "$(jq -nc --arg n "$name" --arg d "$desc" --arg e "epic-$k" --arg s "$SRC" \
        '{name:$n, description:$d, external_id:$e, external_source:$s}')"
      MODULES=$(jq -c --argjson n "$BODY" '. + [$n]' <<<"$MODULES"); say "created module $name"
    fi
  else
    differs=$(jq -r --arg id "$mid" --arg n "$name" --arg d "$desc" '.[]|select(.id==$id)|((.name!=$n) or ((.description // "")!=$d))' <<<"$MODULES")
    if [[ $differs == true ]]; then
      if $DRY; then say "would update module $name"
      else apif PATCH "projects/$PID/modules/$mid/" "$(jq -nc --arg n "$name" --arg d "$desc" '{name:$n, description:$d}')"; say "updated module $name"; fi
    fi
  fi
done

# Membership: one line "<module key> <issue id>" per issue currently in one of our modules.
MEMBERS=""
for k in $MODULE_KEYS; do
  mid=$(module_id "$k")
  [[ -n $mid && $mid != dry:* ]] || continue
  mi=$(api_all "projects/$PID/modules/$mid/module-issues/") || die "could not list module members"
  MEMBERS="$MEMBERS$(jq -r --arg k "$k" '.[] | (if (.issue|type)=="string" then .issue elif (.issue|type)=="object" then .issue.id else .id end) | $k + " " + .' <<<"$mi")"$'\n'
done

# --- 5. descriptions ----------------------------------------------------------------------------
# Tickets are chat-message-style plain text. They go in as a <blockquote> of
# paragraphs (runs of spaces collapsed, line breaks kept as <br>): a <pre> block
# would not wrap the long lines in Plane's editor.
ticket_html() {   # ticket.md -> HTML
  awk '
    function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); return s }
    function flush() { if (p != "") { print "<p>" p "</p>"; p = "" } }
    { line = $0; gsub(/^[ \t]+|[ \t]+$/, "", line); gsub(/[ \t]+/, " ", line)
      if (line == "") { flush(); next }
      line = esc(line)
      if (line ~ /^From:/) line = "<strong>" line "</strong>"
      p = (p == "") ? line : p "<br>" line }
    END { flush() }' "$1"
}

# README intro (everything before the first --- or the first ## heading) -> HTML.
# Handles paragraphs, `code`, **bold**, bullet lists, fenced blocks and pipe tables.
md_intro_html() {
  awk '
    function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); return s }
    function em(s,   o) {
      o = ""
      while (match(s, /\*[^* ][^*]*\*/)) {
        o = o substr(s, 1, RSTART - 1) "<em>" substr(s, RSTART + 1, RLENGTH - 2) "</em>"
        s = substr(s, RSTART + RLENGTH) }
      return o s }
    function bold(s,   n, a, i, o) {
      n = split(s, a, "\\*\\*")
      if (n % 2 == 0) return em(s)
      o = ""; for (i = 1; i <= n; i++) o = o ((i % 2 == 0) ? "<strong>" a[i] "</strong>" : em(a[i]))
      return o }
    function inl(s,   n, a, i, o) {
      s = esc(s)
      n = split(s, a, "`")
      if (n % 2 == 0) return bold(s)
      o = ""; for (i = 1; i <= n; i++) o = o ((i % 2 == 0) ? "<code>" a[i] "</code>" : bold(a[i]))
      return o }
    function flush() { if (p != "") { print "<p>" inl(p) "</p>"; p = "" } }
    function endlist() { if (inlist) { print "</ul>"; inlist = 0 } }
    function endtable() { if (intable) { print "</tbody></table>"; intable = 0; row = 0 } }
    function cells(line, tag,   n, a, i, o) {
      sub(/^[ \t]*\|/, "", line); sub(/\|[ \t]*$/, "", line)
      n = split(line, a, "|"); o = "<tr>"
      for (i = 1; i <= n; i++) { gsub(/^[ \t]+|[ \t]+$/, "", a[i]); o = o "<" tag "><p>" inl(a[i]) "</p></" tag ">" }
      return o "</tr>" }
    NR == 1 && /^# / { next }
    /^---[ \t]*$/ || /^## / { exit }
    /^```/ { if (infence) { print "</code></pre>"; infence = 0 } else { flush(); endlist(); endtable(); print "<pre><code>"; infence = 1; first = 1 } next }
    infence { print esc($0); next }
    /^[ \t]*\|/ {
      flush(); endlist()
      if ($0 ~ /^[ \t]*\|[ \t:|-]+\|?[ \t]*$/) next
      if (!intable) { print "<table><tbody>"; intable = 1; row = 0 }
      row++; print cells($0, (row == 1) ? "th" : "td"); next }
    { endtable() }
    /^[ \t]*$/ { flush(); endlist(); next }
    /^[ \t]*[-*] / { flush(); if (!inlist) { print "<ul>"; inlist = 1 }
      l = $0; sub(/^[ \t]*[-*] +/, "", l); print "<li><p>" inl(l) "</p></li>"; next }
    { endlist(); l = $0; gsub(/^[ \t]+|[ \t]+$/, "", l); p = (p == "") ? l : p " " l }
    END { flush(); endlist(); endtable(); if (infence) print "</code></pre>" }' "$1"
}

stars() { case $1 in 1) echo "●○○" ;; 2) echo "●●○" ;; *) echo "●●●" ;; esac; }

how_to_run() {   # id needs
  local id=$1 needs=$2
  echo "<h3>How to run</h3><ul>"
  case $needs in
    local) echo "<li><p>On the lab box: <code>ssh homelab-1-wsl</code>, then <code>play start $id</code>. Work in <code>~/platform-playground</code> (git pull first).</p></li>" ;;
    homelab) echo "<li><p>From a Mac terminal in the repo: <code>playground/play start $id</code>. Your answer file: <code>~/platform-playground-homelab/answers/$id.md</code>.</p></li>" ;;
    aws) echo "<li><p>Needs a KodeKloud AWS session (credentials in <code>~/.config/platform-lab/aws-lab-creds.env</code>). From the Mac: <code>make eks</code>, then <code>playground/setup/up-aws.sh</code>, then <code>playground/play start $id</code>.</p></li>" ;;
    github) echo "<li><p>Needs the GitHub token (<code>~/.config/platform-lab/github-playground.env</code>, see <code>playground/setup/GITHUB.md</code>). From the Mac: <code>playground/setup/up-github.sh</code>, then <code>playground/play start $id</code>.</p></li>" ;;
  esac
  echo "<li><p>The loop: <code>play hint</code> (-15 points each), <code>play check</code>, <code>play close</code> (write the reply), <code>play reveal</code> (give up: root cause and the interview answer).</p></li></ul>"
}

drill_desc() {   # id dir title track level par needs verified
  local id=$1 dir=$2 track=$4 level=$5 par=$6 needs=$7 ver=$8
  echo "<h3>Ticket</h3><blockquote>"
  ticket_html "$DRILLS/$dir/ticket.md"
  echo "</blockquote>"
  how_to_run "$id" "$needs"
  echo "<p>Par $par min, level $(stars "$level") · track <code>$track</code> · tier <code>$needs</code></p>"
  [[ $ver == unverified ]] && echo "<p><em>Not played end to end yet (unverified): if it misbehaves, note what happened; that is a bug in the drill, not you.</em></p>"
  echo "<p>The ticket in GitHub: <a href=\"$GH_BLOB/drills/$dir/ticket.md\" rel=\"noopener noreferrer\">$GH_BLOB/drills/$dir/ticket.md</a>. Do not open <code>hints.md</code> or <code>solution.md</code> there; use <code>play hint</code>.</p>"
}

exercise_desc() {   # dir
  md_intro_html "$EXERCISES/$1/README.md"
  echo "<h3>How to run</h3><p>From the Mac, in the repo: see <code>playground/exercises/$1/README.md</code>.</p>"
  echo "<p>The README in GitHub: <a href=\"$GH_BLOB/exercises/$1/README.md\" rel=\"noopener noreferrer\">$GH_BLOB/exercises/$1/README.md</a></p>"
}

task_tour_desc() {
  cat <<'EOF'
<p>Open the start page (http://home.192.168.0.23.nip.io) and walk through it out loud, as if to an interviewer. One or two sentences per stop (playground/GUIDE.md, section 3):</p>
<ol>
<li><p><strong>Argo CD</strong>: everything on the cluster comes from git (one app of apps, <code>homelab-platform</code>, owns all the others). Show an app's history, and what happens when someone changes something by hand (Argo puts it back).</p></li>
<li><p><strong>Grafana</strong>, folder Home lab: the Uptime dashboard checks every tool twice, from inside the cluster and through the address people use. If only the outside check fails, the app is fine and the problem is in front of it.</p></li>
<li><p><strong>Platform Jenkins</strong>: a pipeline built on a shared library (build, push the image, deploy <code>demo-api</code>). One place to fix things for every team; drill 07 is what happens when that goes wrong.</p></li>
<li><p><strong>Artifactory</strong> (free OSS edition): Maven and generic repositories yes, Docker images no, so images go to a plain registry. Knowing a tool's limits is a good interview answer.</p></li>
<li><p><strong>Backstage</strong>: the developer portal; the service catalog comes from <code>catalog-info.yaml</code> files in git.</p></li>
<li><p><strong>Headlamp</strong>: the cluster in a browser (nodes, pods, logs). Say what you would and would not give developers access to.</p></li>
<li><p><strong>Backups</strong>: etcd is snapshotted every 6 hours and copied off the machine. Drill 24 is you using one.</p></li>
</ol>
EOF
}

task_mock_desc() {
  cat <<'EOF'
<p>Run <code>play start</code> with <strong>no number</strong>: you get a random drill you have not solved, and you are not told which (like real life). Do two, talking out loud, ideally to a friend or a recording.</p>
<p>Then re-read your journal (<code>~/platform-playground/journal/</code> on the box) and practise each STAR story in under two minutes. After that: replay anything under 80 points (<code>play list</code> shows your best scores).</p>
EOF
}

# --- 6. items -----------------------------------------------------------------------------------
sync_item() {   # ext_id name desc priority "label names (one per line)" module-key
  local ext=$1 name=$2 desc=$3 pri=$4 lnames=$5 mkey=$6
  local cur iid seq="" want mg new patch what="" status mid inmod other k
  cur=$(jq -c --arg e "$ext" 'first(.[]|select(.external_id==$e)) // empty' <<<"$ITEMS")
  want=$(jq -nc --argjson L "$LABELS" --arg names "$lnames" \
    '[ ($names|split("\n")[]|select(length>0)) as $n | ($L[]|select(.name==$n)|.id) ]')
  mid=$(module_id "$mkey")

  if [[ -z $cur ]]; then
    if $DRY; then printf '  would create  %-26s %s\n' "$ext" "$name"; n_created=$((n_created + 1)); return; fi
    api POST "projects/$PID/work-items/" "$(jq -nc --arg name "$name" --arg d "$desc" --arg p "$pri" \
      --argjson l "$want" --arg st "$TODO_ID" --arg e "$ext" --arg s "$SRC" \
      '{name:$name, description_html:$d, priority:$p, labels:$l, state:$st, external_id:$e, external_source:$s}')"
    if [[ $CODE == 409 ]]; then   # raced with another run: it exists, fall through to the update path
      iid=$(jq -r '.id' <<<"$BODY"); apif GET "projects/$PID/work-items/$iid/"; cur=$BODY
    elif [[ $CODE == 2?? ]]; then
      iid=$(jq -r '.id' <<<"$BODY"); seq=$(jq -r '.sequence_id // ""' <<<"$BODY")
      api POST "projects/$PID/modules/$mid/module-issues/" "$(jq -nc --arg i "$iid" '{issues:[$i]}')" \
        || die "could not add $ext to its module (HTTP $CODE): $(printf '%s' "$BODY" | head -c 200)"
      printf '  created       %-26s %s-%s  %s\n' "$ext" "$TRACKER_PROJECT" "$seq" "$name"
      n_created=$((n_created + 1)); return
    else
      die "creating $ext -> HTTP $CODE: $(printf '%s' "$BODY" | head -c 300)"
    fi
  fi

  iid=$(jq -r '.id' <<<"$cur"); seq=$(jq -r '.sequence_id // ""' <<<"$cur")
  # labels: keep the ones this script does not manage (e.g. revealed), replace the managed ones
  mg=$(jq -c '[.[]|select((.name|test("^(track:|tier:)")) or .name=="unverified" or .name=="exercise")|.id]' <<<"$LABELS")
  new=$(jq -c --argjson mg "$mg" --argjson want "$want" '((.labels // []) | map(if type=="object" then .id else . end)) as $cur
    | (($cur - $mg) + $want | unique)' <<<"$cur")
  # Plane sanitises description_html on save (wraps it in a <div>); generated HTML is
  # already in the form it stores, so only that wrapper is stripped before comparing.
  patch=$(jq -c --arg name "$name" --arg d "$desc" --arg p "$pri" --argjson new "$new" '
    def norm: sub("^<div>\\s*";"") | sub("\\s*</div>$";"");
    ((.labels // []) | map(if type=="object" then .id else . end) | sort) as $cur
    | {}
    + (if .name != $name then {name:$name} else {} end)
    + (if ((.description_html // "") | norm) != ($d | norm) then {description_html:$d} else {} end)
    + (if .priority != $p then {priority:$p} else {} end)
    + (if ($new|sort) != $cur then {labels:$new} else {} end)' <<<"$cur")
  what=$(jq -r 'keys|join(",")' <<<"$patch")
  if [[ $patch != '{}' ]]; then
    $DRY || apif PATCH "projects/$PID/work-items/$iid/" "$patch" >/dev/null
  fi
  # module membership: in the right module, in none of our other modules
  inmod=$(printf '%s' "$MEMBERS" | grep -c "^$mkey $iid\$" || true)
  if [[ $inmod -eq 0 ]]; then
    what="${what:+$what,}module"
    $DRY || { api POST "projects/$PID/modules/$mid/module-issues/" "$(jq -nc --arg i "$iid" '{issues:[$i]}')" \
      || die "could not add $ext to its module (HTTP $CODE): $(printf '%s' "$BODY" | head -c 200)"; }
  fi
  for k in $MODULE_KEYS; do
    [[ $k == "$mkey" ]] && continue
    if printf '%s' "$MEMBERS" | grep -q "^$k $iid\$"; then
      other=$(module_id "$k"); what="${what:+$what,}leave-$k"
      $DRY || api DELETE "projects/$PID/modules/$other/module-issues/$iid/" >/dev/null || true
    fi
  done
  if [[ -n $what ]]; then
    status="updated"; $DRY && status="would update"
    printf '  %-13s %-26s %s-%s  %s [%s]\n' "$status" "$ext" "$TRACKER_PROJECT" "$seq" "$name" "$what"
    n_updated=$((n_updated + 1))
  else
    printf '  %-13s %-26s %s-%s\n' unchanged "$ext" "$TRACKER_PROJECT" "$seq"
    n_unchanged=$((n_unchanged + 1))
  fi
}

# Drills
while IFS=$'\t' read -r id dir title track level par needs ver; do
  [[ -n $id ]] || continue
  desc=$(drill_desc "$id" "$dir" "$title" "$track" "$level" "$par" "$needs" "$ver")
  case $level in 1) pri=low ;; 2) pri=medium ;; *) pri=high ;; esac
  labs="track:$track"$'\n'"tier:$needs"; [[ $ver == unverified ]] && labs="$labs"$'\n'unverified
  sync_item "drill-$id" "$id — $title" "$desc" "$pri" "$labs" "$(module_for_drill "$id" "$needs")"
done <<<"$DRILL_ROWS"

# Tasks (no drill behind them)
sync_item "task-day5-tour" "Day 5 — Platform tour (out loud)" "$(task_tour_desc)" medium "" day5
sync_item "task-day7-mock" "Day 7 — Mock interview: two random drills" "$(task_mock_desc)" medium "" day7

# Exercises
while IFS= read -r ex; do
  [[ -n $ex ]] || continue
  h=$(grep -m1 '^# ' "$EXERCISES/$ex/README.md" | sed -e 's/^# *//' -e 's/^Exercise: *//')
  sync_item "exercise-$ex" "Exercise — ${h:-$ex}" "$(exercise_desc "$ex")" low "exercise" exercises
done <<<"$EX_DIRS"

echo
if $DRY; then say "dry run, nothing written: would create $n_created, update $n_updated, leave $n_unchanged unchanged"
else say "done: created $n_created, updated $n_updated, unchanged $n_unchanged ($TRACKER_URL, project $TRACKER_PROJECT)"; fi
exit 0
