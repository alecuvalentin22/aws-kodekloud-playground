# shellcheck shell=bash
# Shared by the exercise's scripts. Source it; do not run it.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/common.sh"
load_creds

REPO=payments/cicd-demo
JOB=cicd-demo
NS_STAGING=cicd-staging
NS_PROD=cicd-prod

ok()   { PASS=$((PASS + 1)); printf '  \033[32m✓ %s\033[0m\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31m✗ %s\033[0m\n' "$1"; [ -n "${2:-}" ] && printf '      hint: %s\n' "$2"; }
info() { printf '  - %s\n' "$1"; }

# ns_images NS -- every image tag a ReplicaSet of cicd-demo in NS has used (its rollout history), one per line.
ns_images() {
  K -n "$1" get rs -l app=cicd-demo -o jsonpath='{range .items[*]}{.spec.template.spec.containers[0].image}{"\n"}{end}' 2>/dev/null | sed 's/.*://' | sort -u
}
# ns_current NS -- the tag the Deployment wants right now.
ns_current() {
  K -n "$1" get deploy cicd-demo -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | sed 's/.*://'
}
# build_sha N -- first 8 chars of the commit build N of the job checked out (cicd-demo's repo, not the library).
build_sha() {
  jenkins_get "/job/$JOB/$1/api/json?tree=actions%5BlastBuiltRevision%5BSHA1%5D,remoteUrls%5D" 2>/dev/null \
    | jq -r '[.actions[]? | select(any(.remoteUrls[]?; test("payments/cicd-demo"))) | .lastBuiltRevision.SHA1? // empty][0] // ""' | cut -c1-8
}
