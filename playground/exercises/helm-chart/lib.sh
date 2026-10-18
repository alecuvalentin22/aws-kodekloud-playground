# shellcheck shell=bash
# Shared by the exercise's scripts. Source it; do not run it.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/common.sh"

SVC=notes-api                         # the service, the chart, the release
REL=notes-api
NS=ex-helm-notes
PROJECT="$WORK/notes-api"             # your clone-like working copy (app + chart/)
CHART_DIR="${CHART_DIR:-$PROJECT/chart/notes-api}"   # check.sh judges this chart
REG_HOST="${PLAYGROUND_REGISTRY_URL:-http://localhost:5001}"; REG_HOST="${REG_HOST#http://}"   # as seen from this machine
IMG_REPO=helm-lab/notes-api           # image  repository in the registry
CHART_REPO=helm-lab/charts            # charts live under here: oci://$REG_HOST/helm-lab/charts/notes-api
IMG_TAGS="1.0.0 1.1.0"

ok()   { PASS=$((PASS + 1)); printf '  \033[32m✓ %s\033[0m\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31m✗ %s\033[0m\n' "$1"; [ -n "${2:-}" ] && printf '      hint: %s\n' "$2"; return 0; }
info() { printf '  - %s\n' "$1"; }

# Helm against the playground, whatever the current kubectl context is.
H() { helm --kube-context "$CTX" "$@"; }

# Registry (the v2 API on the host side of the kind registry).
reg_tags() {   # reg_tags NAME -> one tag per line (empty if the repository does not exist)
  curl -fsS "http://$REG_HOST/v2/$1/tags/list" 2>/dev/null | jq -r '.tags // [] | .[]' 2>/dev/null
}
reg_delete_tag() {   # reg_delete_tag NAME TAG
  local digest
  digest=$(curl -fsSI -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json' \
    "http://$REG_HOST/v2/$1/manifests/$2" 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}')
  [[ -n $digest ]] && curl -fsS -X DELETE "http://$REG_HOST/v2/$1/manifests/$digest" >/dev/null 2>&1
}
