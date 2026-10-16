#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/aws.sh"; load_creds
assert_main_green_since "$DRILL_STARTED" || exit 1
img=$(K -n demo-ci get deploy demo-api -o jsonpath='{.spec.template.spec.containers[0].image}')
[[ $img == *.dkr.ecr.*amazonaws.com/* ]] || { c_bad "running image $img is not from ECR"; exit 1; }
c_ok "running image came from ECR, so the push worked"
lib=$(curl -fsS "$GITEA_URL/platform/platform-lib/raw/branch/main/vars/buildImage.groovy")
pod=$(curl -fsS "$GITEA_URL/platform/platform-lib/raw/branch/main/resources/podtemplates/build.yaml")
if grep -Eq 'privileged: *true|runAsUser: *0([^0-9]|$)' <<<"$pod"; then
  echo "PENALTY 30 BuildKit now runs as root or privileged to read one file. That is root on the node for every build."
fi
if grep -Eq "chmod +(6[0-7][4-7]|7[0-7][0-7]|[ao]\+r)" <<<"$lib"; then
  echo "PENALTY 20 The registry token is now world-readable inside the pod. Fix ownership, not permissions."
fi
grep -q 'chown' <<<"$lib" && c_ok "ownership handed to uid 1000 again" || c_warn "no chown in buildImage -- fixed some other way; make sure you can explain why it works"
