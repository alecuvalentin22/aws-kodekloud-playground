#!/usr/bin/env bash
# A "DNS tuning" commit puts checkout on the node's resolver.
#
# Creates namespace platform-lab-drill66 with a `ledger` Deployment+Service (a tiny
# Python http.server) and a `checkout` Deployment that polls http://ledger:8080/ and
# logs OK / ERROR. The baseline is applied and PROVEN (checkout logs OK) before the
# break. The break is a second commit in the workspace git repo
# (~/platform-playground-aws/drill66, author "Sam (payments)") that adds
# `dnsPolicy: Default` to checkout's pod spec, applied to the cluster. With Default
# the kubelet gives the pod the NODE's resolv.conf (the VPC resolver), which has
# never heard of `ledger`. Nothing in CoreDNS, ledger or the nodes is touched.
#
# Sizing (docs/kodekloud-limits.md): 2 pods in the namespace (cap 3), each requesting
# 20m CPU / 32Mi and limited to 100m / 128Mi (cap 256m / 512Mi); checkout uses
# strategy Recreate so a rollout never makes a third pod.
#
# API calls (kube only, nothing in AWS): create ns, apply Deployments/Service, get/logs.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
mkdir -p "$STATE/logs"
REC="$STATE/drill66.env"
NS=platform-lab-drill66
DIR="$WORK/drill66"
IMG=python:3.12.7-slim-bookworm

# An earlier run of this drill in THIS state dir: clean it up first.
[[ -f $REC ]] && bash "$HERE/reset.sh"
K get ns "$NS" >/dev/null 2>&1 && { echo "namespace $NS exists and is not recorded by this lane; refusing" >&2; exit 1; }

umask 077
printf 'NS=%s\n' "$NS" > "$REC"      # recorded before anything is created
K create ns "$NS" >/dev/null
K label ns "$NS" platform-lab-drill=66 >/dev/null

rm -rf "$DIR"; mkdir -p "$DIR"
cat > "$DIR/ledger.yaml" <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ledger
  namespace: $NS
spec:
  replicas: 1
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
---
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
# payments / checkout + ledger (namespace platform-lab-drill66)

    set -a; . ~/.config/platform-lab/aws-lab-creds.env; set +a; unset AWS_PROFILE
    export KUBECONFIG=~/.kube/andrei-lab-eks
    kubectl apply -f ledger.yaml -f checkout.yaml
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

K apply -f "$DIR/ledger.yaml" -f "$DIR/checkout.yaml" >/dev/null
K -n "$NS" rollout status deploy/ledger --timeout=240s >/dev/null
K -n "$NS" rollout status deploy/checkout --timeout=240s >/dev/null
base=$(wait_log ' OK 200 ledger v1 ok' 90) || { echo "baseline never worked: $(K -n "$NS" logs deploy/checkout --tail=3 2>&1)" >&2; exit 1; }
echo "baseline: $base"

# --- the "DNS tuning" PR -------------------------------------------------------
python3 - "$DIR/checkout.yaml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("    spec:\n      containers:\n        - name: checkout",
              "    spec:\n      # perf: use the node's resolver, skips the CoreDNS hop (faster lookups)\n"
              "      dnsPolicy: Default\n      containers:\n        - name: checkout", 1)
open(p, "w").write(s)
PY
grep -q 'dnsPolicy: Default' "$DIR/checkout.yaml"
git -C "$DIR" add -A
gc "Sam (payments)" "DNS tuning: checkout uses the node's resolver (dnsPolicy: Default), faster lookups; + retry fix"
K apply -f "$DIR/checkout.yaml" >/dev/null
K -n "$NS" rollout status deploy/checkout --timeout=240s >/dev/null
err=$(wait_log 'ERROR' 90) || { echo "the break never produced an error: $(K -n "$NS" logs deploy/checkout --tail=3 2>&1)" >&2; exit 1; }
echo "broken: $err"
exit 0
