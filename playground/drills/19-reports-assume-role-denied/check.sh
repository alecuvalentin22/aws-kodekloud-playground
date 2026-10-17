#!/usr/bin/env bash
# Fixed means, asked of the RUNNING pod (its log is up to 15 s old):
#   1. reports-api is rolled out and a Running pod exists,
#   2. inside that pod `aws sts get-caller-identity` is the drill19 role (not the
#      node role, not nothing): the pod really BECAME the role,
#   3. inside that pod `aws s3 cp` of the report succeeds,
#   4. the role's trust names exactly the service account the pod runs as.
# Penalties (the pod works, but the fix is unsafe):
#   40  trust widened: a wildcard (StringLike with *) in sub or aud, no sub or aud
#       condition, more than one subject, or another principal
#   30  the bucket (or S3 in general) was granted to the NODE role: every pod gets it
#   20  the role's policy is s3:* / Action "*" / Resource "*" instead of the bucket
# API calls: kube get/exec/logs, iam Get*/List*, sts via the pod. All read-only.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
NS=reports
ENVF="$STATE/drill19.env"
[[ -f $ENVF ]] || { c_bad "no $ENVF: the drill was not started here"; exit 1; }
# shellcheck disable=SC1090
source "$ENVF"

K -n $NS get deploy reports-api >/dev/null 2>&1 || { c_bad "Deployment reports-api is gone from namespace $NS"; exit 1; }
K -n $NS rollout status deploy/reports-api --timeout=60s >/dev/null 2>&1 \
  || { c_bad "reports-api is not fully rolled out yet"; exit 1; }
pod=$(K -n $NS get pods -l app=reports-api -o json 2>/dev/null | jq -r \
  '[.items[]|select(.metadata.deletionTimestamp==null and .status.phase=="Running")]|sort_by(.metadata.creationTimestamp)|last|.metadata.name // empty')
[[ -n $pod ]] || { c_bad "no Running reports-api pod"; exit 1; }
sa=$(K -n $NS get pod "$pod" -o jsonpath='{.spec.serviceAccountName}' 2>/dev/null)
c_ok "$pod runs as service account $NS/$sa"

# 2. who is the pod?
who=$(K -n $NS exec "$pod" -c app -- aws sts get-caller-identity --query Arn --output text 2>&1); rc=$?
if (( rc != 0 )); then
  c_bad "inside the pod, aws sts get-caller-identity fails: $(echo "$who" | tr '\n' ' ' | cut -c1-260)"
  exit 1
fi
case $who in
  *":assumed-role/${ROLE}/"*) c_ok "the pod IS the role: $who" ;;
  *"${NODE_ROLE}"*) c_bad "the pod is running as the NODE role ($who), not as ${ROLE}: that is every pod on the node"; exit 1 ;;
  *) c_bad "the pod is ${who}, not the role ${ROLE}"; exit 1 ;;
esac

# 3. can it read?
out=$(K -n $NS exec "$pod" -c app -- aws s3 cp "s3://${BUCKET}/daily/report.csv" - 2>&1); rc=$?
if (( rc != 0 )) || ! grep -q '^date,region,orders' <<<"$out"; then
  c_bad "the pod cannot read s3://${BUCKET}/daily/report.csv: $(echo "$out" | tr '\n' ' ' | cut -c1-260)"
  exit 1
fi
c_ok "the pod reads s3://${BUCKET}/daily/report.csv"
last=$(K -n $NS logs "$pod" -c app --tail=1 2>/dev/null)
case $last in *" OK read "*) ;; *) c_dim "  (the workload's own last log line is not OK yet: $(echo "$last" | cut -c1-120). It retries every 15 s.)" ;; esac

# 4. the trust, evaluated
trust=$(aws iam get-role --role-name "$ROLE" --query Role.AssumeRolePolicyDocument --output json 2>/dev/null)
[[ -n $trust ]] || { c_bad "cannot read the trust policy of $ROLE"; exit 1; }
verdict=$(jq -r --arg host "$HOST" --arg oidc "$OIDC_ARN" --arg sub "system:serviceaccount:${NS}:${sa}" '
  def arr: if type=="array" then . else [.] end;
  def vals($k): [ (.Condition // {}) | to_entries[] | .key as $op | .value | to_entries[]
                  | select(.key == $k) | {op: $op, vals: (.value | arr)} ];
  [ .Statement | arr | .[] | select(.Effect == "Allow") ] as $st
  | [ $st[] | (
      if ((.Principal | type) != "object") or ((.Principal | keys) != ["Federated"]) or ((.Principal.Federated | arr) != [$oidc])
        then "a principal other than the cluster OIDC provider" else empty end,
      ( vals($host + ":sub") as $s
        | if ($s | length) == 0 then "no sub condition: any service account in the cluster can assume the role"
          elif ($s | length) > 1 or ($s[0].op != "StringEquals" and $s[0].op != "StringLike") or $s[0].vals != [$sub]
            then "sub is not exactly [\($sub)] with StringEquals (found \($s | tostring))" else empty end ),
      ( vals($host + ":aud") as $a
        | if ($a | length) == 0 then "no aud condition"
          elif ($a | length) > 1 or ($a[0].op != "StringEquals" and $a[0].op != "StringLike") or $a[0].vals != ["sts.amazonaws.com"]
            then "aud is not exactly StringEquals sts.amazonaws.com" else empty end ) ) ]
  | if ($st | length) == 0 then "no Allow statement" elif length == 0 then "OK" else join("; ") end
' <<<"$trust" 2>&1)
pen=0
if [[ $verdict == OK ]]; then
  c_ok "trust is pinned to system:serviceaccount:${NS}:${sa} and aud sts.amazonaws.com"
else
  c_warn "trust is wider than one service account: $verdict"
  echo "PENALTY 40 Trust policy widened ($verdict). It must stay pinned to ONE service account and aud sts.amazonaws.com."
  pen=1
fi

# 5. the role's permissions: still one bucket?
broad=""; scoped=0
for p in $(aws iam list-attached-role-policies --role-name "$ROLE" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
  [[ $p == None ]] && continue
  case $p in
    arn:aws:iam::aws:policy/*) case $p in *S3FullAccess|*AdministratorAccess|*PowerUserAccess|*S3ReadOnlyAccess) broad="$broad ${p##*/}" ;; esac; continue ;;
  esac
  v=$(aws iam get-policy --policy-arn "$p" --query Policy.DefaultVersionId --output text 2>/dev/null)
  doc=$(aws iam get-policy-version --policy-arn "$p" --version-id "$v" --query PolicyVersion.Document --output json 2>/dev/null)
  [[ -n $doc ]] || continue
  b=$(jq -r --arg b "arn:aws:s3:::${BUCKET}" '
    def arr: if type=="array" then . else [.] end;
    [.Statement|arr|.[]|select(.Effect=="Allow")] as $s
    | (if any($s[]; (.Action|arr) | any(. == "*" or . == "s3:*")) then "Action *" else empty end),
      (if any($s[]; (.Resource|arr) | any(. == "*" or . == "arn:aws:s3:::*")) then "Resource *" else empty end),
      (if any($s[]; (.Resource|arr) | any(startswith($b))) then "scoped" else empty end)' <<<"$doc" 2>/dev/null | tr '\n' ' ')
  case $b in *scoped*) scoped=1 ;; esac
  case $b in *Action*|*Resource*) broad="$broad ${p##*/}(${b})" ;; esac
done
if [[ -n $broad ]]; then
  c_warn "the role's permissions are broader than the bucket:$broad"
  echo "PENALTY 20 Role policy is broader than the bucket (s3:* / Action * / Resource *):$broad. Grant GetObject + ListBucket on that one bucket."
else
  c_ok "the role's permissions stay on ${BUCKET}"
fi

# 6. the node role must not have gained S3
nodebad=""
for p in $(aws iam list-attached-role-policies --role-name "$NODE_ROLE" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
  [[ $p == None ]] && continue
  case $p in
    "$POLICY_ARN") nodebad="$nodebad ${p##*/}" ;;
    arn:aws:iam::aws:policy/*) case $p in *S3*|*AdministratorAccess|*PowerUserAccess) nodebad="$nodebad ${p##*/}" ;; esac ;;
    *) v=$(aws iam get-policy --policy-arn "$p" --query Policy.DefaultVersionId --output text 2>/dev/null)
       aws iam get-policy-version --policy-arn "$p" --version-id "$v" --query PolicyVersion.Document --output json 2>/dev/null \
         | grep -Eq '"s3:|"\*"' && nodebad="$nodebad ${p##*/}" ;;
  esac
done
for ip in $(aws iam list-role-policies --role-name "$NODE_ROLE" --query 'PolicyNames' --output text 2>/dev/null); do
  [[ $ip == None ]] && continue
  aws iam get-role-policy --role-name "$NODE_ROLE" --policy-name "$ip" --query PolicyDocument --output json 2>/dev/null \
    | grep -Eq '"s3:|"\*"' && nodebad="$nodebad inline:$ip"
done
if [[ -n $nodebad ]]; then
  c_warn "the node role $NODE_ROLE now carries S3 access:$nodebad"
  echo "PENALTY 30 S3 was granted to the NODE role ($NODE_ROLE:$nodebad): every pod on every node can now read it. Fix the pod's identity instead."
else
  c_ok "the node role has no S3 grant"
fi
exit 0
