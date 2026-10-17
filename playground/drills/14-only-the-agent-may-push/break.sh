#!/usr/bin/env bash
# Nothing is broken -- that is the finding. The sandbox pod demonstrates that
# the node role reaches every pod: it mints an ECR token once a minute, as
# whatever principal IMDS hands it.
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/aws.sh"; load_creds
mkdir -p "$WORK/evidence"
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
            who=$(aws sts get-caller-identity --query Arn --output text 2>&1)
            if aws ecr get-login-password --region us-east-1 >/dev/null 2>&1; then
              echo "$(date -u +%FT%TZ) ECR token minted as $who"
            else
              echo "$(date -u +%FT%TZ) NO ECR token: $who"
            fi
            sleep 60
          done
      resources:
        requests: {cpu: 10m, memory: 32Mi}
        limits: {memory: 64Mi}
YAML
