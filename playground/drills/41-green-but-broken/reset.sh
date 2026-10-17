#!/usr/bin/env bash
# The check's throwaway branch must not outlive the drill. (The baseline
# content of demo-api is restored by `play reset` itself.)
source "$(dirname "$0")/../../lib/common.sh"; load_creds
git push -q "$(repo_url payments/demo-api)" --delete drill41-canary >/dev/null 2>&1 || true
exit 0
