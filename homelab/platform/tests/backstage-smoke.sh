#!/usr/bin/env bash
# Run the Backstage browser smoke test in a pinned Playwright image (headless Chromium).
# Needs Docker; leaves screenshots + results.json in ./out (git-ignored, do not commit).
# BASE=http://backstage.<lan-ip>.nip.io ./backstage-smoke.sh
set -euo pipefail
PW=1.57.0
here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$here/out"
exec docker run --rm --ipc=host \
  -e BASE="${BASE:-http://backstage.192.168.0.23.nip.io}" -e OUT=/out \
  -v "$here/backstage-smoke.mjs:/work/backstage-smoke.mjs:ro" -v "$here/out:/out" \
  "mcr.microsoft.com/playwright:v${PW}-noble" \
  bash -c "cd /tmp && npm init -y >/dev/null && npm i --no-audit --no-fund playwright@${PW} >/dev/null && cp /work/backstage-smoke.mjs . && node backstage-smoke.mjs"
