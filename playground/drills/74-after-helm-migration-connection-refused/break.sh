#!/usr/bin/env bash
# A "Helm chart migration" relabels the ledger pods; the Service keeps the old selector.
#
# Creates namespace platform-lab-drill74 with a `ledger` Deployment (2 replicas, a tiny
# Python http.server) + `ledger` Service (selector app: ledger) and a `checkout`
# Deployment that polls http://ledger:8080/ and logs OK / ERROR. The baseline is applied
# and PROVEN (checkout logs OK) before the break. The break is a second commit in the
# workspace git repo (~/platform-playground-aws/drill74, author "Sam (payments)") that
# moves ledger's pod labels from `app: ledger` to the chart conventions
# `app.kubernetes.io/name|instance: ledger`. A Deployment's selector is immutable, so the
# "migration" deletes and re-creates the Deployment; the Service file is not part of the
# chart yet and keeps `selector: {app: ledger}` -> the Service has NO endpoints while both
# pods are Running and Ready. checkout then gets "Connection refused" (kube-proxy rejects
# traffic to a Service with no endpoints). Nothing in kube-system or the nodes is touched.
#
# Sizing (docs/kodekloud-limits.md): 3 pods in the namespace (cap 3), each requesting
# 20m CPU / 32Mi and limited to 100m / 128Mi; ledger rolls with maxSurge 0 and checkout
# uses Recreate, so a rollout never makes a 4th pod.
#
# API calls (kube only, nothing in AWS): create ns, apply/delete Deployments/Service, get/logs.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
mkdir -p "$STATE/logs"
REC="$STATE/drill74.env"
NS=platform-lab-drill74
DIR="$WORK/drill74"
IMG=python:3.12.7-slim-bookworm

# An earlier run of this drill in THIS state dir: clean it up first.
[[ -f $REC ]] && bash "$HERE/reset.sh"
K get ns "$NS" >/dev/null 2>&1 && { echo "namespace $NS exists and is not recorded by this lane; refusing" >&2; exit 1; }

umask 077
printf 'NS=%s\n' "$NS" > "$REC"      # recorded before anything is created
K create ns "$NS" >/dev/null
K label ns "$NS" platform-lab-drill=74 >/dev/null

rm -rf "$DIR"; mkdir -p "$DIR"
cat > "$DIR/ledger-deploy.yaml" <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ledger
  namespace: $NS
  labels: {app: ledger}
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate: {maxSurge: 0, maxUnavailable: 1}
  selector:
    matchLabels: {app: ledger}
  template:
    metadata:
      labels: {app: ledger}
    spec:
      containers:
        - name: ledger
          image: $IMG
          command: ["sh", "-c", "mkdir -p /tmp/www && echo 'ledger v1 ok' > /tmp/www/index.html && exec python -m http.server 8080 --directory /tmp/www"]
          ports:
            - containerPort: 8080
          readinessProbe:
            tcpSocket: {port: 8080}
            periodSeconds: 3
          resources:
            requests: {cpu: 20m, memory: 32Mi}
            limits: {cpu: 100m, memory: 128Mi}
YAML
cat > "$DIR/ledger-svc.yaml" <<YAML
apiVersion: v1
kind: Service
metadata:
  name: ledger
  namespace: $NS
spec:
  selector: {app: ledger}
  ports:
    - port: 8080
      targetPort: 8080
YAML
cat > "$DIR/checkout.yaml" <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: $NS
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels: {app: checkout}
  template:
    metadata:
      labels: {app: checkout}
    spec:
      containers:
        - name: checkout
          image: $IMG
          env:
            - name: LEDGER_URL
              value: http://ledger:8080/
          command:
            - python
            - -u
            - -c
            - |
              import os, time, urllib.request
              url = os.environ["LEDGER_URL"]
              while True:
                  now = time.strftime("%H:%M:%S")
                  try:
                      r = urllib.request.urlopen(url, timeout=3)
                      print(now, "OK", r.status, r.read().decode().strip(), flush=True)
                  except Exception as e:
                      print(now, "ERROR could not reach", url, "->", e, flush=True)
                  time.sleep(5)
          resources:
            requests: {cpu: 20m, memory: 32Mi}
            limits: {cpu: 100m, memory: 128Mi}
YAML
cat > "$DIR/README.md" <<'MD'
# payments / checkout + ledger (namespace platform-lab-drill74)

    set -a; . ~/.config/platform-lab/aws-lab-creds.env; set +a; unset AWS_PROFILE
    export KUBECONFIG=~/.kube/andrei-lab-eks
    kubectl apply -f ledger-deploy.yaml -f ledger-svc.yaml -f checkout.yaml
MD
git -C "$DIR" init -q
gc() { git -C "$DIR" -c user.name="$1" -c user.email="${1%% *}@payments.local" commit -q -m "$2"; }
git -C "$DIR" add -A
gc "Dana" "checkout + ledger: checkout polls ledger every 5s"

wait_log() {   # wait_log PATTERN SECONDS -> prints the matching last line
  local pat=$1 limit=$2 t0 line; t0=$(date +%s)
  while (( $(date +%s) - t0 < limit )); do
    line=$(K -n "$NS" logs deploy/checkout --tail=1 2>/dev/null || true)
    if grep -q -- "$pat" <<<"$line"; then echo "$line"; return 0; fi
    sleep 3
  done
  return 1
}

K apply -f "$DIR/ledger-deploy.yaml" -f "$DIR/ledger-svc.yaml" -f "$DIR/checkout.yaml" >/dev/null
K -n "$NS" rollout status deploy/ledger --timeout=240s >/dev/null
K -n "$NS" rollout status deploy/checkout --timeout=240s >/dev/null
base=$(wait_log ' OK 200 ledger v1 ok' 90) || { echo "baseline never worked: $(K -n "$NS" logs deploy/checkout --tail=3 2>&1)" >&2; exit 1; }
echo "baseline: $base"

# --- the "Helm chart migration" ------------------------------------------------
python3 - "$DIR/ledger-deploy.yaml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("  labels: {app: ledger}\nspec:",
              "  labels:\n    app.kubernetes.io/name: ledger\n    app.kubernetes.io/instance: ledger\n"
              "    app.kubernetes.io/managed-by: Helm\nspec:", 1)
s = s.replace("  selector:\n    matchLabels: {app: ledger}",
              "  selector:\n    matchLabels:\n      app.kubernetes.io/name: ledger\n      app.kubernetes.io/instance: ledger", 1)
s = s.replace("    metadata:\n      labels: {app: ledger}",
              "    metadata:\n      labels:\n        app.kubernetes.io/name: ledger\n        app.kubernetes.io/instance: ledger", 1)
open(p, "w").write(s)
PY
grep -q 'app.kubernetes.io/name: ledger' "$DIR/ledger-deploy.yaml"
git -C "$DIR" add -A
gc "Sam (payments)" "Helm chart migration: ledger pods use the app.kubernetes.io/* labels (name, instance); Deployment re-created (selector is immutable)"
# Deployment.spec.selector is immutable: the migration re-creates the Deployment.
K -n "$NS" delete deploy ledger --cascade=foreground --wait=true --timeout=120s >/dev/null
for _ in $(seq 1 30); do
  [[ -z $(K -n "$NS" get pods -l app=ledger -o name 2>/dev/null) ]] && break
  sleep 2
done
K apply -f "$DIR/ledger-deploy.yaml" >/dev/null
K -n "$NS" rollout status deploy/ledger --timeout=240s >/dev/null
err=$(wait_log 'ERROR' 90) || { echo "the break never produced an error: $(K -n "$NS" logs deploy/checkout --tail=3 2>&1)" >&2; exit 1; }
echo "broken: $err"
exit 0
