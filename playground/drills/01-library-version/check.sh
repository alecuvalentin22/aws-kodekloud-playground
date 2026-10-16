#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
assert_main_green_since "$DRILL_STARTED" || exit 1
jf=$(curl -fsS "$GITEA_URL/payments/demo-api/raw/branch/main/Jenkinsfile")
ver=$(grep -o "platform-lib@[^']*" <<<"$jf" | cut -d@ -f2)
if [[ -z $ver ]]; then
  c_ok "Jenkinsfile uses the library's default version"
  echo "PENALTY 5 Fine, but unpinned: this team now gets every library change the moment it lands (see drill 07)"
else
  c_ok "Jenkinsfile pins platform-lib@$ver"
fi
