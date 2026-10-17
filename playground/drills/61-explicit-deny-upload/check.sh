#!/usr/bin/env bash
# Fixed means: upload.sh -- run here, as the candidate left it -- puts a fresh
# test object into the bucket THROUGH the security team's guardrails, and the
# object is stored encrypted. If the bucket policy was deleted or a Deny weakened,
# the check puts the recorded policy back (so the uploader is judged against the
# real guardrail) and takes a penalty. A TLS-verification bypass is a penalty too.
# AWS API calls: s3:HeadBucket, GetBucketPolicy, PutBucketPolicy (only to restore the
# recorded policy), PutObject via upload.sh, HeadObject, DeleteObject (the test object).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
REC="$STATE/drill61.env"
[[ -f $REC ]] || { c_bad "no record of the break ($REC): was the drill started with play start?"; exit 1; }
BUCKET=""; POLICY=""
# shellcheck disable=SC1090
source "$REC"
DIR="$WORK/drill61"
[[ -f $DIR/upload.sh ]] || { c_bad "$DIR/upload.sh is gone"; exit 1; }
[[ -f $POLICY ]] || { c_bad "the recorded policy $POLICY is gone"; exit 1; }
aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1 || { c_bad "bucket $BUCKET is gone or not reachable"; exit 1; }

# 1. The guardrails. Does each recorded Deny still exist in the live policy, as strong as recorded?
#    "As strong" = same Effect/Principal/Action(s) and the same Condition. Checked per statement.
live=$(aws s3api get-bucket-policy --bucket "$BUCKET" --query Policy --output text 2>&1); prc=$?
intact=yes; why=""
if (( prc != 0 )); then
  intact=no; why="the bucket policy was deleted"
else
  # S3 may store one-element lists as strings and vice versa: normalise before comparing.
  norm='walk(if type == "array" then (sort | if length == 1 then .[0] else . end) else . end)'
  for sid in DenyUnencryptedUploads DenyInsecureTransport; do
    w=$(jq -S -c --arg s "$sid" ".Statement[] | select(.Sid == \$s) | $norm" "$POLICY")
    g=$(jq -S -c --arg s "$sid" ".Statement | (if type == \"array\" then . else [.] end)[] | select(.Sid == \$s) | $norm" <<<"$live" 2>/dev/null)
    if [[ -z $g ]]; then intact=no; why="the $sid statement was removed"; break; fi
    if [[ $g != "$w" ]]; then intact=no; why="the $sid statement was changed (weakened)"; break; fi
  done
fi
# The tampering is remembered across checks: restoring the policy must not wash the penalty away.
TAMPER="$STATE/drill61.tampered"
pen50=no
if [[ $intact == no ]]; then
  printf '%s\n' "$why" > "$TAMPER"
fi
if [[ -f $TAMPER ]]; then
  pen50=yes; why=$(cat "$TAMPER")
fi
if [[ $intact == no ]]; then
  c_warn "guardrail changed: $why. Restoring the recorded policy so the uploader is judged against it"
  aws s3api put-bucket-policy --bucket "$BUCKET" --policy "file://$POLICY" >/dev/null 2>&1 \
    || { c_bad "could not restore the bucket policy"; exit 1; }
  sleep 4
elif [[ $pen50 == yes ]]; then
  c_ok "bucket policy is the recorded one again (both Deny statements)"
else
  c_ok "bucket policy intact: both Deny statements (encryption header, TLS) are still there"
fi

# 2. Did the uploader turn TLS verification off?
pen20=no
if grep -Eq -- '--no-verify-ssl|AWS_CA_BUNDLE=|ca_bundle|verify_ssl|--no-verify' "$DIR/upload.sh" "$DIR/aws-env.sh" 2>/dev/null; then
  pen20=yes
  c_warn "upload.sh turns TLS verification off (--no-verify-ssl / CA bundle override)"
fi

# 3. Run the uploader, as it is, with a fresh object.
tmp=$(mktemp); key="releases/check-$(date +%s)-$RANDOM.txt"
echo "check $(date -u +%FT%TZ)" > "$tmp"
out=$(cd "$DIR" && bash ./upload.sh "$tmp" "$key" 2>&1); rc=$?
rm -f "$tmp"
if (( rc != 0 )); then
  c_bad "upload.sh still fails: $(tail -n 3 <<<"$out" | tr '\n' ' ' | cut -c1-400)"
  if grep -q 'explicit deny in a resource-based policy' <<<"$out"; then
    c_bad "an explicit deny in the bucket policy is still matching this request: compare the request with each Deny statement's condition"
  fi
  exit 1
fi
c_ok "upload.sh ran: $(tail -n 1 <<<"$out")"

# 4. The object is there, and stored encrypted.
head=$(aws s3api head-object --bucket "$BUCKET" --key "$key" --output json 2>&1) \
  || { c_bad "upload.sh said OK but s3://$BUCKET/$key does not exist (does it still take FILE KEY as arguments?)"; exit 1; }
sse=$(jq -r '.ServerSideEncryption // empty' <<<"$head")
aws s3api delete-object --bucket "$BUCKET" --key "$key" >/dev/null 2>&1
if [[ $sse != AES256 && $sse != aws:kms ]]; then
  c_bad "the object is not stored with server-side encryption (ServerSideEncryption: '${sse:-none}')"; exit 1
fi
c_ok "the object arrived with server-side encryption ($sse), over HTTPS"

if [[ $pen50 == yes ]]; then
  echo "PENALTY 50 The guardrail was changed ($why). It is the security team's control and it was right: the fix is on the client, not by deleting or weakening the policy."
fi
if [[ $pen20 == yes ]]; then
  echo "PENALTY 20 upload.sh disables TLS verification. The policy checks that the request uses TLS, not that the certificate is verified; turning verification off removes a protection and fixes nothing."
fi
exit 0
