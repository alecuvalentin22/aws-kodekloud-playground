#!/usr/bin/env bash
# Nothing is broken -- that is the finding. The sandbox pod demonstrates that
# the node role reaches every pod: once a minute it asks ECR for an upload
# session (ecr:InitiateLayerUpload, a PUSH-only action: minting a token proves
# nothing, because the pull-only ReadOnly policy mints tokens too -- drill 13).
# It writes down which principal IMDS handed it and whether the push was accepted.
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/aws.sh"; load_creds
mkdir -p "$WORK/evidence"
# A leftover pod from an earlier run cannot be updated in place (args are immutable).
K -n sandbox delete pod curious-intern --ignore-not-found >/dev/null 2>&1 || true
K apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: sandbox
---
apiVersion: v1
kind: Pod
metadata:
  name: curious-intern
  namespace: sandbox
  labels: {app: pentest-pt07}
spec:
  restartPolicy: Always
  containers:
    - name: probe
      image: alpine/k8s:1.33.13      # already on the nodes: the agent's deploy image
      command: [sh, -c]
      args:
        - |
          while true; do
            who=$(aws sts get-caller-identity --query Arn --output text 2>&1 | head -c 200)
            if out=$(aws ecr initiate-layer-upload --region us-east-1 \
                       --repository-name platform-lab/demo-api --query uploadId --output text 2>&1); then
              echo "$(date -u +%FT%TZ) CAN PUSH to ECR platform-lab/demo-api as $who"
            else
              echo "$(date -u +%FT%TZ) cannot push as $who: $(echo "$out" | head -c 160)"
            fi
            sleep 60
          done
      resources:
        requests: {cpu: 10m, memory: 32Mi}
        # 64Mi OOM-kills the aws CLI mid-call, and the log would then read
        # "cannot push" for the wrong reason. 256Mi is what the agent's own
        # deploy container (same image, same CLI) gets.
        limits: {memory: 256Mi}
YAML
