#!/usr/bin/env bash
# The cloud team's "tidy-up": the node role loses ECR push. drills/18 section 2
# was reproduced exactly this way.
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/aws.sh"; load_creds
aws iam detach-role-policy --role-name "$NODE_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser
# IAM is eventually consistent; give the detach time to land before building.
sleep 20
as_teammate "Sam (payments)" payments/demo-api "api: report the owning team on /" <<'SH'
sed -i.bak 's/return jsonify(app="demo-api", version=VERSION)/return jsonify(app="demo-api", version=VERSION, team="payments")/' app.py && rm app.py.bak
grep -q 'team="payments"' app.py
SH
jenkins_scan
