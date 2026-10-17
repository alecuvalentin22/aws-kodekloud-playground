#!/usr/bin/env bash
# A log-writing StatefulSet fills its 1 Gi EBS volume and crash-loops with
# "No space left on device". Nothing is simulated: the volume really is full.
#
# Mechanism: namespace platform-lab-drill69, StatefulSet audit-writer (busybox,
# pinned) with a 1 Gi gp3 PVC at /data. The writer appends one line every 2 s to
# /data/audit.log and exits 1 when the write fails. break.sh (1) lets it write a
# few lines, (2) writes a marker file /data/audit-anchor.txt, (3) fills the rest
# of the volume with a "spool backlog" file, so the very next append fails. The
# kubelet restarts the container, which fails again: CrashLoopBackOff.
#
# API calls:
#   kube  apply ns/StatefulSet (gp3, 1 Gi); exec (write marker, fill, count lines); logs
#   ec2   DescribeVolumes (read), CreateTags (platform-lab-drill=69 on the volume)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
mkdir -p "$STATE"
NS=platform-lab-drill69
ENVF="$STATE/drill69.env"

K get ns "$NS" >/dev/null 2>&1 && die "namespace $NS already exists. Run the drill's reset first."

K apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Namespace
metadata: {name: platform-lab-drill69}
---
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: audit-writer, namespace: platform-lab-drill69}
spec:
  serviceName: audit-writer
  replicas: 1
  selector: {matchLabels: {app: audit-writer}}
  template:
    metadata: {labels: {app: audit-writer}}
    spec:
      terminationGracePeriodSeconds: 2
      containers:
        - name: writer
          image: busybox:1.37.0
          command: ["sh", "-c"]
          args:
            - |
              echo "audit-writer starting"; df -h /data | tail -n 1
              n=0
              while true; do
                if ! echo "$(date -u +%FT%TZ) seq=$n event=login actor=svc-$((n % 7)) src=10.0.$((n % 250)).17 result=ok trace=00000000000000000000000000000000" >> /data/audit.log; then
                  echo "audit-writer: cannot append to /data/audit.log, exiting" >&2
                  exit 1
                fi
                n=$((n + 1)); sleep 2
              done
          readinessProbe:
            exec:
              command: ["sh", "-c", "test $(( $(date +%s) - $(stat -c %Y /data/audit.log) )) -lt 20"]
            periodSeconds: 5
            failureThreshold: 2
          resources:
            requests: {cpu: 20m, memory: 16Mi}
            limits: {cpu: 100m, memory: 64Mi}
          volumeMounts: [{name: data, mountPath: /data}]
  volumeClaimTemplates:
    - metadata: {name: data}
      spec:
        accessModes: [ReadWriteOnce]
        storageClassName: gp3
        resources: {requests: {storage: 1Gi}}
YAML
K -n $NS rollout status sts/audit-writer --timeout=300s >/dev/null || die "audit-writer did not become Ready (image pull?)"

# --- the data that must survive -------------------------------------------------
for _ in $(seq 1 20); do
  lines=$(K -n $NS exec audit-writer-0 -- sh -c 'wc -l < /data/audit.log' 2>/dev/null | tr -d '[:space:]' || true)
  [[ ${lines:-0} -ge 3 ]] && break; sleep 2
done
MARKER="audit-anchor-$(openssl rand -hex 6)"
K -n $NS exec audit-writer-0 -- sh -c "echo $MARKER > /data/audit-anchor.txt && sync"
PVC_UID=$(K -n $NS get pvc data-audit-writer-0 -o jsonpath='{.metadata.uid}')
PV=$(K -n $NS get pvc data-audit-writer-0 -o jsonpath='{.spec.volumeName}')
VOL=$(K get pv "$PV" -o jsonpath='{.spec.csi.volumeHandle}')
aws ec2 create-tags --resources "$VOL" --tags Key=platform-lab-drill,Value=69

# --- fill the volume (the spool backlog), the writer fails on its next append ---
K -n $NS exec audit-writer-0 -- sh -c 'mkdir -p /data/spool; dd if=/dev/zero of=/data/spool/replay-backlog.ndjson bs=1M 2>/dev/null; sync; true' || true
LINES=$(K -n $NS exec audit-writer-0 -- sh -c 'wc -l < /data/audit.log' 2>/dev/null | tr -d '[:space:]' || true)
umask 077
cat > "$ENVF" <<EOF2
MARKER=$MARKER
PVC_UID=$PVC_UID
PV=$PV
VOL=$VOL
LINES=${LINES:-3}
EOF2

# --- wait for the real symptom: restarts, with the kernel's own words -----------
for _ in $(seq 1 90); do
  rc=$(K -n $NS get pod audit-writer-0 -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0)
  if [[ ${rc:-0} -ge 1 ]]; then
    echo "restarts: $rc"
    K -n $NS logs audit-writer-0 --previous 2>&1 | tail -n 4 || true
    exit 0
  fi
  sleep 3
done
die "audit-writer never started crash-looping (pod: $(K -n $NS get pod audit-writer-0 -o jsonpath='{.status.phase}' 2>/dev/null))"
