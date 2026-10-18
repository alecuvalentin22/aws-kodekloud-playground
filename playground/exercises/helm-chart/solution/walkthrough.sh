#!/usr/bin/env bash
# REFERENCE SOLUTION -- not used by the exercise. It plays steps 5 to 7 of the
# README with the finished chart in ./chart/notes-api, so you can compare with
# what YOU typed, or see the whole sequence run once (about 3 minutes).
#
#   ./walkthrough.sh              uses ./chart/notes-api directly (does not touch your working copy)
#
# After it, ../check.sh judges THIS chart:   CHART_DIR=$PWD/chart/notes-api ../check.sh
set -euo pipefail
SOL="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib.sh
. "$SOL/../lib.sh"      # (lib.sh sets HERE to the exercise directory)
CH="$SOL/chart/notes-api"
OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

step "5. lint every environment, render, ask the API server"
H lint "$CH"; for f in "$CH"/values-*.yaml; do H lint "$CH" -f "$f"; done
H template "$REL" "$CH" -n "$NS" -f "$CH/values-staging.yaml" | grep -E '^kind:|checksum/config'
H upgrade --install "$REL" "$CH" -n "$NS" -f "$CH/values-staging.yaml" --dry-run=server >/dev/null && echo "dry-run=server: accepted"

step "6. package, push to the OCI registry, install FROM it"
V=$(sed -n 's/^version: *//p' "$CH/Chart.yaml")
H package "$CH" -d "$OUT"
H push "$OUT/notes-api-$V.tgz" "oci://$REG_HOST/$CHART_REPO" --plain-http
H show chart "oci://$REG_HOST/$CHART_REPO/notes-api" --version "$V" --plain-http | head -4
H upgrade --install "$REL" "oci://$REG_HOST/$CHART_REPO/notes-api" --version "$V" --plain-http \
  -n "$NS" -f "$CH/values-staging.yaml" --atomic --wait --timeout 90s
H -n "$NS" test "$REL" --timeout 60s

step "7a. config change: MAX_NOTE_LENGTH 280 -> 100 (the checksum rolls the pods)"
H upgrade "$REL" "oci://$REG_HOST/$CHART_REPO/notes-api" --version "$V" --plain-http \
  -n "$NS" -f "$CH/values-staging.yaml" --set config.MAX_NOTE_LENGTH=100 --atomic --wait --timeout 90s
K -n "$NS" get rs -l "app.kubernetes.io/instance=$REL"

step "7b. a broken upgrade (image tag 1.1.1 does not exist): --atomic must roll it back"
if H upgrade "$REL" "oci://$REG_HOST/$CHART_REPO/notes-api" --version "$V" --plain-http \
     -n "$NS" -f "$CH/values-staging.yaml" --set config.MAX_NOTE_LENGTH=100 --set image.tag=1.1.1 \
     --atomic --wait --timeout 60s; then
  echo "unexpected: the broken upgrade succeeded" >&2; exit 1
fi
H -n "$NS" history "$REL"
