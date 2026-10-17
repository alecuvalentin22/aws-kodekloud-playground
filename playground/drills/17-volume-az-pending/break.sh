#!/usr/bin/env bash
# A stateful workload loses the only node in its volume's availability zone.
# The pod comes back Pending (PersistentVolume node affinity).
#
# HONEST PART: a real node replacement (ASG scale-in, spot reclaim, AMI roll) is
# not done here. KodeKloud allows 5 x t3.medium in total and the ASG must stay at 3,
# so no instance is terminated or launched. The same scheduler state is made with
# kubectl: cordon + drain the node(s) in the volume's AZ. In production the ASG
# would put the replacement wherever it has capacity, possibly in another AZ.
# One difference in the event: with a node GONE the scheduler counts it out
# silently; with it cordoned it says "1 node(s) were unschedulable" next to the
# affinity message of the other zones. The wording of that message depends on the
# Kubernetes version: 1.33 says "node(s) didn't match PersistentVolume's node
# affinity", older ones "had volume node affinity conflict". Both are matched.
#
# Mechanism: cluster has one node per AZ. The AZ to lose is one where no
# PVC-backed pod runs (so Jenkins and Gitea, whose EBS volumes pin them to their
# own zones, are NOT drained). The StatefulSet is created while the nodes of the
# other zones are cordoned, so its pod and volume land in that zone without any
# nodeSelector in the manifest. Then the other nodes are uncordoned, this zone's
# nodes are cordoned and drained.
#
# API calls:
#   kube  get nodes/pods; cordon/uncordon/drain; apply ns ledger (Service,
#         StatefulSet with 1 Gi gp3 PVC); exec psql to write the marker
#   ec2   DescribeVolumes (read), CreateTags (tags the volume platform-lab-drill=17)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
mkdir -p "$STATE"
NS=ledger
ENVF="$STATE/drill17.env"
PG_IMAGE=postgres:17.6-alpine   # pushed 2025; pinned, nothing newer than two weeks

K get ns "$NS" >/dev/null 2>&1 && die "namespace $NS already exists. Run play reset first."
[[ -z "$(K get nodes -o json | jq -r '.items[]|select(.spec.unschedulable==true)|.metadata.name')" ]] \
  || die "a node is already cordoned. Run play reset first."
[[ $(K get nodes -o json | jq '[.items[]|select(any(.status.conditions[]; .type=="Ready" and .status=="True"))]|length') -ge 2 ]] \
  || die "fewer than 2 Ready nodes."

# --- 1. which AZ to lose: one with no PVC-backed pod on any of its nodes --------
nodes_json=$(K get nodes -o json)
busy_nodes=$(K get pods -A -o json | jq -r '[.items[]|select(any(.spec.volumes[]?; has("persistentVolumeClaim")))|.spec.nodeName//empty]|unique|.[]')
ZONE=""
for z in $(jq -r '[.items[].metadata.labels["topology.kubernetes.io/zone"]]|unique|.[]' <<<"$nodes_json"); do
  zn=$(jq -r --arg z "$z" '.items[]|select(.metadata.labels["topology.kubernetes.io/zone"]==$z)|.metadata.name' <<<"$nodes_json")
  clash=0; for n in $zn; do grep -qx "$n" <<<"$busy_nodes" && clash=1; done
  (( clash )) && continue
  ZONE=$z; break
done
[[ -n $ZONE ]] || die "every AZ has a node running a PVC-backed pod; draining one would break Jenkins/Gitea. Nothing to simulate safely."
ZONE_NODES=$(jq -r --arg z "$ZONE" '.items[]|select(.metadata.labels["topology.kubernetes.io/zone"]==$z)|.metadata.name' <<<"$nodes_json")
OTHER_NODES=$(jq -r --arg z "$ZONE" '.items[]|select(.metadata.labels["topology.kubernetes.io/zone"]!=$z)|.metadata.name' <<<"$nodes_json")

uncordon_others() { for n in $OTHER_NODES; do K uncordon "$n" >/dev/null 2>&1 || true; done; }
trap uncordon_others EXIT

# --- 2. the workload, placed in that zone by capacity alone ---------------------
for n in $OTHER_NODES; do K cordon "$n" >/dev/null; done
K apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Namespace
metadata: {name: $NS}
---
apiVersion: v1
kind: Service
metadata: {name: ledger-db, namespace: $NS}
spec:
  clusterIP: None
  selector: {app: ledger-db}
  ports: [{name: pg, port: 5432}]
---
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: ledger-db, namespace: $NS}
spec:
  serviceName: ledger-db
  replicas: 1
  selector: {matchLabels: {app: ledger-db}}
  template:
    metadata: {labels: {app: ledger-db}}
    spec:
      terminationGracePeriodSeconds: 30
      containers:
        - name: postgres
          image: $PG_IMAGE
          env:
            - {name: POSTGRES_HOST_AUTH_METHOD, value: trust}
            - {name: PGDATA, value: /var/lib/postgresql/data/pgdata}
          ports: [{containerPort: 5432}]
          readinessProbe:
            exec: {command: ["pg_isready", "-U", "postgres", "-h", "127.0.0.1"]}
            periodSeconds: 5
            failureThreshold: 6
          resources:
            requests: {cpu: 100m, memory: 192Mi}
            limits: {cpu: 250m, memory: 512Mi}
          volumeMounts: [{name: data, mountPath: /var/lib/postgresql/data}]
  volumeClaimTemplates:
    - metadata: {name: data}
      spec:
        accessModes: [ReadWriteOnce]
        storageClassName: gp3
        resources: {requests: {storage: 1Gi}}
YAML
K -n $NS rollout status sts/ledger-db --timeout=300s >/dev/null || die "ledger-db did not become Ready (image pull? $PG_IMAGE)"
placed=$(K -n $NS get pod ledger-db-0 -o jsonpath='{.spec.nodeName}')
grep -qx "$placed" <<<"$ZONE_NODES" || die "ledger-db landed on $placed, outside $ZONE"

# --- 3. the data we must not lose ----------------------------------------------
MARKER="ledger-$(openssl rand -hex 6)"
K -n $NS exec ledger-db-0 -- psql -U postgres -v ON_ERROR_STOP=1 -q \
  -c "create table marker(v text)" -c "insert into marker values ('$MARKER')" \
  -c "create table entries(id serial primary key, memo text)" \
  -c "insert into entries(memo) select 'month-end line '||g from generate_series(1,250) g" \
  -c "checkpoint" >/dev/null

PVC_UID=$(K -n $NS get pvc data-ledger-db-0 -o jsonpath='{.metadata.uid}')
PV=$(K -n $NS get pvc data-ledger-db-0 -o jsonpath='{.spec.volumeName}')
VOL=$(K get pv "$PV" -o jsonpath='{.spec.csi.volumeHandle}')
VAZ=$(aws ec2 describe-volumes --volume-ids "$VOL" --query 'Volumes[0].AvailabilityZone' --output text)
[[ $VAZ == "$ZONE" ]] || die "volume $VOL is in $VAZ, expected $ZONE"
aws ec2 create-tags --resources "$VOL" --tags Key=platform-lab-drill,Value=17
umask 077
cat > "$ENVF" <<EOF2
MARKER=$MARKER
PV=$PV
VOL=$VOL
VAZ=$VAZ
PVC_UID=$PVC_UID
ZONE_NODES="$(echo $ZONE_NODES)"
EOF2

# --- 4. "the node in that AZ was replaced and the new one came up elsewhere" ----
for n in $ZONE_NODES; do
  K cordon "$n" >/dev/null
  K annotate node "$n" platform-lab/drill17=simulated-node-loss --overwrite >/dev/null
done
uncordon_others; trap - EXIT
for n in $ZONE_NODES; do
  K drain "$n" --ignore-daemonsets --delete-emptydir-data --timeout=240s >/dev/null 2>&1 \
    || die "could not drain $n"
done
K -n $NS delete pod ledger-db-0 --ignore-not-found --wait=false >/dev/null 2>&1 || true

# --- 5. wait for the real scheduler event -------------------------------------
for _ in $(seq 1 40); do
  msg=$(K -n $NS get events --field-selector reason=FailedScheduling -o json 2>/dev/null \
        | jq -r '[.items[].message|select(test("volume node affinity conflict|match PersistentVolume.s node affinity"))]|last // empty')
  if [[ -n $msg ]]; then echo "event: $msg"; exit 0; fi
  sleep 3
done
die "no PersistentVolume node-affinity FailedScheduling event appeared (pod: $(K -n $NS get pod ledger-db-0 -o jsonpath='{.status.phase}' 2>/dev/null))"
