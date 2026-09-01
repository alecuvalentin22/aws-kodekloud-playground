#!/usr/bin/env bash
# Compare every pin in versions.env against the latest STABLE upstream release.
#
#   ./scripts/check-versions.sh        # or: make versions
#
# Exits non-zero if anything is behind, so CI can fail on it.
#
# The point is not automation for its own sake. Pinning is the right default --
# a floating tag means the cluster changes without a commit -- but a pin that
# nobody re-checks is just an unpatched version with extra steps. This makes the
# staleness visible in about ten seconds.
#
# Pre-releases and release candidates are excluded deliberately: "latest stable"
# is the target, not "latest".
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/versions.env"

STALE=0
UNKNOWN=0
row() { printf "  %-28s %-14s %-14s %s\n" "$1" "$2" "$3" "$4"; }

gh_latest() {
  # Newest non-prerelease, non-draft release tag.
  # Use a token when one is available -- 60/hour unauthenticated vs 5000/hour.
  #
  # Not an array. macOS ships bash 3.2, where expanding an EMPTY array as
  # "${arr[@]}" under `set -u` is an unbound-variable error rather than the
  # empty string it is in bash 4+. Every one of these lookups failed with
  # "auth[@]: unbound variable" until this was written as a plain string.
  local auth_hdr=""
  [[ -n "${GITHUB_TOKEN:-}" ]] && auth_hdr="Authorization: Bearer $GITHUB_TOKEN"
  curl -sL --max-time 15 ${auth_hdr:+-H "$auth_hdr"} \
    "https://api.github.com/repos/$1/releases?per_page=30" 2>/dev/null \
    | python3 -c '
import sys,json
try:
    d=json.load(sys.stdin)
    s=[x for x in d if not x.get("prerelease") and not x.get("draft")]
    print(s[0]["tag_name"] if s else "?")
except Exception: print("?")'
}

helm_latest() {
  # $1 = repo alias, $2 = repo url, $3 = chart name
  helm repo add "$1" "$2" >/dev/null 2>&1
  helm repo update "$1" >/dev/null 2>&1
  helm search repo "$1/$3" -o json 2>/dev/null | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    m=[x for x in d if x['name']=='$1/$3']
    print(m[0]['version'] if m else '?')
except Exception: print('?')"
}

check() { # name pinned latest
  # "could not check" must NOT be reported as success. GitHub rate-limits
  # unauthenticated API calls at 60/hour and this script makes five of them, so
  # an unknown here is routine -- which is exactly why it has to be counted
  # rather than glossed. A version checker that says "everything current" when
  # it failed to check is worse than no version checker.
  if [[ "$3" == "?" ]]; then row "$1" "$2" "?" "COULD NOT CHECK"; UNKNOWN=$((UNKNOWN+1))
  elif [[ "$2" == "$3" ]]; then row "$1" "$2" "$3" "ok"
  else row "$1" "$2" "$3" "** BEHIND **"; STALE=$((STALE+1)); fi
}

echo "Pinned versions vs latest stable upstream"
printf "  %-28s %-14s %-14s %s\n" COMPONENT PINNED LATEST ""
echo "  ---------------------------------------------------------------------"

check argo-cd        "$ARGOCD_VERSION"   "$(gh_latest argoproj/argo-cd)"
check flux2          "v$FLUX_VERSION"    "$(gh_latest fluxcd/flux2)"
check flux-operator  "$FLUXOP_VERSION"   "$(gh_latest controlplaneio-fluxcd/flux-operator)"
check argo-rollouts  "$ROLLOUTS_VERSION" "$(gh_latest argoproj/argo-rollouts)"
check podinfo        "$PODINFO_VERSION"  "$(gh_latest stefanprodan/podinfo)"

check flagger        "$FLAGGER_CHART"    "$(helm_latest flagger https://flagger.app flagger)"
check loadtester     "$LOADTESTER_CHART" "$(helm_latest flagger https://flagger.app loadtester)"
check ingress-nginx  "$NGINX_CHART"      "$(helm_latest ingress-nginx https://kubernetes.github.io/ingress-nginx ingress-nginx)"
check apisix         "$APISIX_CHART"     "$(helm_latest apisix https://charts.apiseven.com apisix)"
check apisix-ingress "$AIC_CHART"        "$(helm_latest apisix https://charts.apiseven.com apisix-ingress-controller)"
check kube-prom      "$KPS_VERSION"      "$(helm_latest prometheus-community https://prometheus-community.github.io/helm-charts kube-prometheus-stack)"
check sealed-secrets "$SEALED_CHART"     "$(helm_latest sealed-secrets https://bitnami.github.io/sealed-secrets sealed-secrets)"

echo
if [[ "$UNKNOWN" -gt 0 ]]; then
  echo "  $UNKNOWN component(s) COULD NOT BE CHECKED -- almost always GitHub's"
  echo "  60/hour unauthenticated rate limit. Re-run later, or:"
  echo "    GITHUB_TOKEN=\$(gh auth token) ./scripts/check-versions.sh"
fi
if [[ "$STALE" -gt 0 ]]; then
  echo "  $STALE component(s) BEHIND. Update versions.env, then:"
  echo "    grep -rn '<old-version>' scripts/ gitops/ kubernetes/   # catch inline copies"
fi
if [[ "$STALE" -gt 0 || "$UNKNOWN" -gt 0 ]]; then exit 1; fi
echo "  all checked components are current."
