#!/usr/bin/env bash
# A working IRSA setup, then a teammate's "cleanup" breaks it:
#   baseline  Deployment reports-api runs as ServiceAccount reports-reader; the role
#             drill19-reports-reader trusts exactly system:serviceaccount:reports:reports-reader
#             (aud sts.amazonaws.com) and its policy reads ONE bucket. The pod logs OK.
#   break     the manifest is "tidied": the Deployment now runs as ServiceAccount
#             `reports` (annotated with the SAME role). The role's permissions are
#             untouched and still right; the token's `sub` no longer matches the
#             trust, so the pod never becomes the role:
#             AccessDenied when calling the AssumeRoleWithWebIdentity operation.
#
# Account facts this relies on (probed 2026-10-17, KodeKloud 339712991953):
#   iam:CreateRole (tagged), CreatePolicy, AttachRolePolicy, CreatePolicyVersion,
#   DeletePolicyVersion allowed; DeletePolicy, UpdateAssumeRolePolicy, TagPolicy,
#   PutRolePolicy DENIED. So the managed policy is created ONCE and reused (its
#   default version is rewritten for each run's bucket); reset.sh cannot delete it.
# The cluster's IAM OIDC provider already exists (shared with drill 14): never touched.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; load_creds
NS=reports; ROLE=drill19-reports-reader; POLICY_NAME=drill19-reports-read
ORIG_SA=reports-reader; BROKEN_SA=reports
ENVF="$STATE/drill19.env"

# A clean slate: a previous run's bucket, role, namespace.
bash "$HERE/reset.sh" >/dev/null 2>&1 || true

ACCT=$(aws_account)
ISSUER=$(aws eks describe-cluster --name "$EKS_CLUSTER" --query cluster.identity.oidc.issuer --output text)
HOST=${ISSUER#https://}
OIDC_ARN="arn:aws:iam::${ACCT}:oidc-provider/${HOST}"
if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" >/dev/null 2>&1; then
  aws iam create-open-id-connect-provider --url "$ISSUER" --client-id-list sts.amazonaws.com >/dev/null
fi
BUCKET="platform-lab-drill19-${ACCT}-$(openssl rand -hex 3)"
POLICY_ARN="arn:aws:iam::${ACCT}:policy/${POLICY_NAME}"
ROLE_ARN="arn:aws:iam::${ACCT}:role/${ROLE}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# --- the bucket ------------------------------------------------------------
aws s3api create-bucket --bucket "$BUCKET" >/dev/null
aws s3api put-bucket-tagging --bucket "$BUCKET" --tagging 'TagSet=[{Key=platform-lab-drill,Value=19}]'
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
printf 'date,region,orders\n2026-10-16,emea,1284\n2026-10-16,amer,2310\n' \
  | aws s3 cp - "s3://${BUCKET}/daily/report.csv" >/dev/null

# --- the permissions policy (right, and it stays right) -------------------
cat > "$T/policy.json" <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":"s3:ListBucket","Resource":"arn:aws:s3:::${BUCKET}"},
 {"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::${BUCKET}/*"}]}
EOF
if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  for v in $(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
               --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text); do
    aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$v"
  done
  aws iam create-policy-version --policy-arn "$POLICY_ARN" --policy-document "file://$T/policy.json" \
    --set-as-default >/dev/null
else
  aws iam create-policy --policy-name "$POLICY_NAME" --policy-document "file://$T/policy.json" >/dev/null
fi

# --- the role: trust pinned to ONE service account + audience ---------------
cat > "$T/trust.json" <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"Federated":"${OIDC_ARN}"},
 "Action":"sts:AssumeRoleWithWebIdentity",
 "Condition":{"StringEquals":{
   "${HOST}:sub":"system:serviceaccount:${NS}:${ORIG_SA}",
   "${HOST}:aud":"sts.amazonaws.com"}}}]}
EOF
aws iam create-role --role-name "$ROLE" --assume-role-policy-document "file://$T/trust.json" \
  --description "platform-lab drill 19: reports-api reads one bucket" \
  --tags Key=platform-lab-drill,Value=19 >/dev/null
aws iam attach-role-policy --role-name "$ROLE" --policy-arn "$POLICY_ARN"

# What check.sh needs later.
cat > "$ENVF" <<EOF
ACCT=$ACCT
BUCKET=$BUCKET
ROLE=$ROLE
ROLE_ARN=$ROLE_ARN
POLICY_ARN=$POLICY_ARN
HOST=$HOST
OIDC_ARN=$OIDC_ARN
ORIG_SA=$ORIG_SA
BROKEN_SA=$BROKEN_SA
EOF

# --- the workload ------------------------------------------------------------
# alpine/k8s is already on the nodes (the Jenkins agent's deploy image) and has the
# aws CLI v2. 256Mi: the CLI is OOM-killed below that, which would log a failure for
# the wrong reason (see drill 14).
manifest() {   # manifest <serviceaccount> <change-cause>
  cat <<YAML
apiVersion: v1
kind: Namespace
metadata: {name: ${NS}}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $1
  namespace: ${NS}
  annotations: {eks.amazonaws.com/role-arn: "${ROLE_ARN}"}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: reports-api
  namespace: ${NS}
  annotations: {kubernetes.io/change-cause: "$2"}
spec:
  replicas: 1
  selector: {matchLabels: {app: reports-api}}
  template:
    metadata: {labels: {app: reports-api}}
    spec:
      serviceAccountName: $1
      containers:
        - name: app
          image: alpine/k8s:1.33.13
          env:
            - {name: AWS_DEFAULT_REGION, value: us-east-1}
            - {name: S3_URI, value: "s3://${BUCKET}/daily/report.csv"}
          command: [sh, -c]
          args:
            - |
              while true; do
                if out=\$(aws s3 cp "\$S3_URI" - 2>&1); then
                  echo "\$(date -u +%FT%TZ) OK read \$S3_URI (\$(echo "\$out" | wc -c) bytes)"
                else
                  echo "\$(date -u +%FT%TZ) FAILED reading \$S3_URI: \$(echo "\$out" | tr '\n' ' ' | head -c 400)"
                fi
                sleep 15
              done
          resources:
            requests: {cpu: 50m, memory: 128Mi}
            limits: {memory: 256Mi}
YAML
}

wait_log() {   # wait_log <regex> <seconds>
  local i
  for i in $(seq 1 $(( $2 / 5 ))); do
    K -n "$NS" logs deploy/reports-api --tail=1 2>/dev/null | grep -Eq "$1" && return 0
    sleep 5
  done
  return 1
}

# Baseline: prove it works (a new role can take a few seconds to be usable).
manifest "$ORIG_SA" "initial deploy" | K apply -f - >/dev/null
wait_log ' OK read ' 180 || die "baseline never read the report (not your fault): $(K -n $NS logs deploy/reports-api --tail=2 2>&1 | head -c 400)"

# The teammate's cleanup: one SA called `reports`, same role annotation. The old
# ServiceAccount stays behind (kubectl apply does not prune).
manifest "$BROKEN_SA" "cleanup: run as SA reports instead of reports-reader" | K apply -f - >/dev/null
K -n "$NS" rollout status deploy/reports-api --timeout=180s >/dev/null
wait_log 'AssumeRoleWithWebIdentity' 120 || die "the break did not produce the AssumeRoleWithWebIdentity error: $(K -n $NS logs deploy/reports-api --tail=2 2>&1 | head -c 400)"
