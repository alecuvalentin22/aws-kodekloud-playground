# shellcheck shell=bash
# Shared by `play`, setup/ and every drill. Source it; do not run it.
#
# Three locations, kept apart on purpose:
#   PG_ROOT   this directory, in the platform-lab repo  (the game; read-only)
#   STATE     ~/.local/state/platform-lab-playground     (creds, scores, scratch)
#   WORK      ~/platform-playground                      (YOUR clones -- work here)

PG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_ROOT="$(cd "$PG_ROOT/.." && pwd)"
STATE="${PLAYGROUND_STATE:-$HOME/.local/state/platform-lab-playground}"
WORK="${PLAYGROUND_WORK:-$HOME/platform-playground}"

# shellcheck disable=SC1091
source "$LAB_ROOT/versions.env"
# shellcheck disable=SC1091
source "$PG_ROOT/versions.env"

CLUSTER=playground
CTX="kind-$CLUSTER"
export PATH="$STATE/bin:$PATH"
K() { kubectl --context "$CTX" "$@"; }

# Overridable so a runner on the kind Docker network (Semaphore) can drive the
# game: there, localhost is the runner itself, and the node is
# playground-control-plane.
JENKINS_URL=${PLAYGROUND_JENKINS_URL:-http://localhost:30094}
GITEA_URL=${PLAYGROUND_GITEA_URL:-http://localhost:30300}
REGISTRY_URL=${PLAYGROUND_REGISTRY_URL:-http://localhost:5001}
GITEA_IN_CLUSTER=http://gitea.git.svc.cluster.local:3000
REGISTRY=kind-registry:5000

c_hdr()  { printf "\n\033[1m%s\033[0m\n" "$*"; }
c_ok()   { printf "\033[32m  ✓ %s\033[0m\n" "$*"; }
c_bad()  { printf "\033[31m  ✗ %s\033[0m\n" "$*"; }
c_warn() { printf "\033[33m  ! %s\033[0m\n" "$*"; }
c_dim()  { printf "\033[2m%s\033[0m\n" "$*"; }
die()    { c_bad "$*" >&2; exit 1; }

load_creds() {
  [[ -f "$STATE/creds.env" ]] || die "No playground yet. Run: playground/setup/up.sh"
  # shellcheck disable=SC1091
  source "$STATE/creds.env"
  # Older creds.env files predate GITEA_USER; their Gitea login is `dev`.
  GITEA_USER=${GITEA_USER:-dev}
}

# --- Gitea -----------------------------------------------------------------

gitea_api() {   # gitea_api METHOD PATH [JSON]
  local m=$1 p=$2 d=${3:-}
  curl -fsS -u "$GITEA_USER:$GITEA_PASSWORD" -X "$m" -H 'Content-Type: application/json' \
    ${d:+--data "$d"} "$GITEA_URL/api/v1$p"
}

# Authenticated remote URL for scripts. The candidate's own clones use a
# credential helper instead, so the password is not in their .git/config.
repo_url() { echo "${GITEA_URL/:\/\//://$GITEA_USER:$GITEA_PASSWORD@}/$1.git"; }

# Push a change as a TEAMMATE would: from a scratch clone under STATE, with a
# different author, so the candidate has to `git pull` and read the log.
#   as_teammate "Sam (payments)" payments/demo-api "commit message" <<'EOF'
#     ... shell run inside the clone ...
#   EOF
as_teammate() {
  local who=$1 repo=$2 msg=$3 dir
  dir="$STATE/scratch/$(echo "$repo" | tr / _)"
  rm -rf "$dir"
  git clone -q "$(repo_url "$repo")" "$dir"
  ( cd "$dir" && bash -euo pipefail ) || die "teammate edit failed"
  git -C "$dir" add -A
  git -C "$dir" -c user.name="$who" -c user.email="teammate@playground.local" \
    commit -q -m "$msg"
  git -C "$dir" push -q origin HEAD:main
  rm -rf "$dir"
}

head_sha() { git ls-remote "$(repo_url "$1")" "refs/heads/${2:-main}" | cut -c1-40; }

# --- Jenkins ---------------------------------------------------------------

JAR="$STATE/jenkins.cookies"
jenkins_crumb() {
  curl -fsS -c "$JAR" -u "admin:$JENKINS_PASSWORD" \
    "$JENKINS_URL/crumbIssuer/api/json" | jq -r '"\(.crumbRequestField):\(.crumb)"'
}
jenkins_get()  { curl -fsS -u "admin:$JENKINS_PASSWORD" "$JENKINS_URL$1"; }
jenkins_post() { curl -fsS -b "$JAR" -u "admin:$JENKINS_PASSWORD" -H "$(jenkins_crumb)" -X POST "$@"; }

# Run Groovy in the script console and print its output. Admin-only, which is
# exactly why the CHECKS use it and the candidate should think twice.
jenkins_groovy() {
  jenkins_post --data-urlencode "script=$1" "$JENKINS_URL/scriptText"
}

# Ask the multibranch job to rescan now instead of waiting for the 1m poll.
jenkins_scan() { jenkins_post "$JENKINS_URL/job/demo-api/build?delay=0" >/dev/null 2>&1 || true; }

# JSON of the last build of a branch, or {} if none.
last_build() {
  jenkins_get "/job/demo-api/job/${1:-main}/lastBuild/api/json?tree=number,result,building,timestamp,url" \
    2>/dev/null || echo '{}'
}

# --- shared check ------------------------------------------------------------

# The question almost every drill ends on: is main green, AFTER the incident
# started, and is that build what is actually running?
#   assert_main_green_since <epoch-seconds> [namespace]
assert_main_green_since() {
  local since=$1 ns=${2:-demo-ci} b result building ts img sha
  b=$(last_build main)
  result=$(jq -r '.result // "NONE"' <<<"$b")
  building=$(jq -r '.building // false' <<<"$b")
  ts=$(( $(jq -r '.timestamp // 0' <<<"$b") / 1000 ))
  if [[ $building == true ]]; then c_warn "main is still building -- check again when it finishes"; return 1; fi
  if (( ts < since )); then c_bad "no main build since the incident started (last one predates it)"; return 1; fi
  if [[ $result != SUCCESS ]]; then c_bad "last main build: $result"; return 1; fi
  c_ok "main build #$(jq -r .number <<<"$b") is SUCCESS"
  sha=$(head_sha payments/demo-api main | cut -c1-8)
  img=$(K -n "$ns" get deploy demo-api -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
  if [[ $img != *"-$sha-"* ]]; then c_bad "running image $img is not main's HEAD ($sha)"; return 1; fi
  K -n "$ns" rollout status deploy/demo-api --timeout=5s >/dev/null 2>&1 \
    || { c_bad "deployment in $ns is not fully rolled out"; return 1; }
  c_ok "running $img in $ns"
}
