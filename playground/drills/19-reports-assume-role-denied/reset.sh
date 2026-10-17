#!/usr/bin/env bash
# Back to baseline: namespace reports gone, the drill's bucket emptied and deleted
# (found by the recorded name AND by the platform-lab-drill=19 tag), the role
# drill19-reports-reader deleted after detaching everything attached to it, and the
# drill's managed policy detached from every entity (a solver may have attached it
# to the node role).
#
# NOT deleted (INTENTIONALLY): the managed policy drill19-reports-read. iam:DeletePolicy is denied
# on this sandbox (probed 2026-10-17), tagging a policy too. It costs nothing, holds
# no attachments after this script, and break.sh reuses it (rewrites its default
# version). This script still TRIES to delete it, and says so when it cannot, so on
# an account that allows it nothing is left. Extra customer-managed policies the
# solver attached to the role are deleted the same way (try, report).
# Never touched: the cluster's IAM OIDC provider (shared with drill 14), jenkins.
# Skipped silently when the AWS tier is not up.
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/aws.sh"
aws_tier_up || exit 0
aws_env
ENVF="$STATE/drill19.env"
[[ -f $ENVF ]] && source "$ENVF"
NS=reports
ROLE=${ROLE:-drill19-reports-reader}
ACCT=${ACCT:-$(aws_account)}
POLICY_ARN=${POLICY_ARN:-arn:aws:iam::${ACCT}:policy/drill19-reports-read}

# 1. the workload
K delete ns $NS --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1

# 2. buckets: the recorded one, plus any carrying the drill tag
buckets="${BUCKET:-}"
for b in $(aws s3api list-buckets --query "Buckets[?starts_with(Name, 'platform-lab-drill19-')].Name" --output text 2>/dev/null); do
  buckets="$buckets $b"
done
for b in $(echo $buckets | tr ' ' '\n' | sort -u); do
  [[ -n $b && $b != None ]] || continue
  aws s3api head-bucket --bucket "$b" >/dev/null 2>&1 || continue
  aws s3 rm "s3://$b" --recursive >/dev/null 2>&1
  aws s3 rb "s3://$b" >/dev/null 2>&1 && echo "deleted bucket $b" || echo "could not delete bucket $b"
done

# 3. the drill's policy off every entity that carries it (roles, users, groups)
for r in $(aws iam list-entities-for-policy --policy-arn "$POLICY_ARN" --query 'PolicyRoles[].RoleName' --output text 2>/dev/null); do
  [[ $r == None ]] || aws iam detach-role-policy --role-name "$r" --policy-arn "$POLICY_ARN" >/dev/null 2>&1
done

# 4. the role, and whatever the solver attached to it
if aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  extra=""
  for p in $(aws iam list-attached-role-policies --role-name "$ROLE" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$p" >/dev/null 2>&1
    case $p in "arn:aws:iam::${ACCT}:policy/"*) extra="$extra $p" ;; esac
  done
  for ip in $(aws iam list-role-policies --role-name "$ROLE" --query 'PolicyNames' --output text 2>/dev/null); do
    [[ $ip == None ]] || aws iam delete-role-policy --role-name "$ROLE" --policy-name "$ip" >/dev/null 2>&1
  done
  aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 && echo "deleted role $ROLE" || echo "could not delete role $ROLE"
  for p in $extra; do
    for v in $(aws iam list-policy-versions --policy-arn "$p" --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text 2>/dev/null); do
      aws iam delete-policy-version --policy-arn "$p" --version-id "$v" >/dev/null 2>&1
    done
    aws iam delete-policy --policy-arn "$p" >/dev/null 2>&1 || echo "left in place (delete denied): $p"
  done
fi
# the drill's own policy. DeletePolicy is denied by the playground, so it is
# INTENTIONALLY left: detached from everything, default version rolled back to a
# placeholder that grants nothing real (no bucket of that name exists), older
# versions pruned (max 5 per policy). Try the delete first, for accounts allowing it.
if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  if aws iam delete-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
    echo "deleted policy $POLICY_ARN"
  else
    for v in $(aws iam list-policy-versions --policy-arn "$POLICY_ARN" --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text 2>/dev/null); do
      aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$v" >/dev/null 2>&1
    done
    aws iam create-policy-version --policy-arn "$POLICY_ARN" --set-as-default --policy-document \
      '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::platform-lab-drill19-unused/*"}]}' >/dev/null 2>&1
    echo "left in place on purpose (iam:DeletePolicy denied by the playground; 0 attachments, placeholder version): $POLICY_ARN"
  fi
fi
rm -f "$ENVF"
exit 0
