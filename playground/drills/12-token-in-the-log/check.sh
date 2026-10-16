#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/aws.sh"; load_creds
fail=0

# 1. The source: the ECR login step must turn tracing off before it mints anything.
lib=$(curl -fsS "$GITEA_URL/platform/platform-lib/raw/branch/main/vars/buildImage.groovy")
if python3 - "$lib" <<'PY'
import sys
s = sys.argv[1]
i = s.find("get-login-password")
blk = s[s.rfind('sh """', 0, i):i] if i > 0 else ""
sys.exit(0 if "set +x" in blk else 1)
PY
then c_ok "the ECR login step starts with set +x again"
else c_bad "the ECR login step still runs with tracing on"; fail=1; fi

# 2. Pipelines still push (a fix that stops the login is not a fix).
assert_main_green_since "$DRILL_STARTED" || fail=1

# 3. The evidence: no build record kept by Jenkins still holds a registry token.
#    ECR tokens are base64 JSON, so they start with eyJ and are long.
leaky=()
for br in $(jenkins_get "/job/demo-api/api/json?tree=jobs%5Bname%5D" | jq -r '.jobs[].name'); do
  for n in $(build_numbers "$br"); do
    build_console "$n" "$br" | grep -Eq 'eyJ[A-Za-z0-9+/=_-]{200,}' && leaky+=("$br#$n")
  done
done
if (( ${#leaky[@]} )); then
  c_bad "build log(s) still holding a token: ${leaky[*]} (anyone with Job/Read can copy it)"; fail=1
else
  c_ok "no retained build log contains a registry token"
fi
exit $fail
