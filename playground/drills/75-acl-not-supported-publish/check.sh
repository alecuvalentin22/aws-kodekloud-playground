#!/usr/bin/env bash
# Fixed means: publish.sh -- run here, as the candidate left it -- publishes a fresh
# set of test assets into the bucket while the bucket still has ACLs DISABLED
# (BucketOwnerEnforced) and Block Public Access fully on; the objects are not
# publicly readable (anonymous GET is 403) and a presigned URL for one works.
# If Object Ownership was changed or Block Public Access weakened or a public bucket
# policy added, the check puts the secure configuration back (so the script is judged
# against it) and takes a penalty, remembered across checks.
# AWS API calls: s3:HeadBucket, GetBucketOwnershipControls, PutBucketOwnershipControls
# and PutPublicAccessBlock / DeleteBucketPolicy (only to restore), GetPublicAccessBlock,
# GetBucketPolicy, PutObject via publish.sh, HeadObject, DeleteObject (test objects).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
REC="$STATE/drill75.env"
[[ -f $REC ]] || { c_bad "no record of the break ($REC): was the drill started with play start?"; exit 1; }
BUCKET=""
# shellcheck disable=SC1090
source "$REC"
DIR="$WORK/drill75"
[[ -f $DIR/publish.sh ]] || { c_bad "$DIR/publish.sh is gone"; exit 1; }
aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1 || { c_bad "bucket $BUCKET is gone or not reachable"; exit 1; }
TOWN="$STATE/drill75.tampered-own"; TPUB="$STATE/drill75.tampered-public"

# 1. Object Ownership: must still be BucketOwnerEnforced (ACLs disabled).
own=$(aws s3api get-bucket-ownership-controls --bucket "$BUCKET" \
        --query 'OwnershipControls.Rules[0].ObjectOwnership' --output text 2>&1) || own="(none: $(cut -c1-80 <<<"$own"))"
if [[ $own != BucketOwnerEnforced ]]; then
  printf 'ObjectOwnership was set to %s\n' "$own" > "$TOWN"
  c_warn "Object Ownership is $own: ACLs were re-enabled. Putting BucketOwnerEnforced back so publish.sh is judged against the real bucket"
  aws s3api put-bucket-ownership-controls --bucket "$BUCKET" \
    --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]' >/dev/null 2>&1 \
    || { c_bad "could not restore Object Ownership"; exit 1; }
  sleep 3
fi

# 2. Block Public Access: all four settings true, and no public bucket policy.
bpa=$(aws s3api get-public-access-block --bucket "$BUCKET" \
        --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' \
        --output text 2>&1 | tr -s '[:space:]' ' ' | sed 's/ $//')
if [[ $bpa != "True True True True" ]]; then
  printf 'Block Public Access was weakened (%s)\n' "$bpa" > "$TPUB"
  c_warn "Block Public Access is not fully on ($bpa). Turning it back on"
  aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true >/dev/null 2>&1 \
    || { c_bad "could not restore Block Public Access"; exit 1; }
fi
pol=$(aws s3api get-bucket-policy --bucket "$BUCKET" --query Policy --output text 2>/dev/null || true)
if [[ -n $pol && $pol != None ]]; then
  # An Allow to everyone (Principal "*" or {"AWS":"*"}) without a Condition is a public policy.
  pub=$(jq -r '[.Statement | (if type == "array" then . else [.] end)[]
                | select(.Effect == "Allow" and (.Principal == "*" or .Principal.AWS == "*") and (has("Condition") | not))] | length' <<<"$pol" 2>/dev/null || echo 0)
  if [[ $pub != 0 ]]; then
    printf 'a public bucket policy was added\n' > "$TPUB"
    c_warn "the bucket policy grants access to everyone. Removing it"
    aws s3api delete-bucket-policy --bucket "$BUCKET" >/dev/null 2>&1 || { c_bad "could not remove the public policy"; exit 1; }
    sleep 3
  fi
fi
[[ -f $TOWN || -f $TPUB ]] || c_ok "bucket still private by design: ACLs disabled (BucketOwnerEnforced), Block Public Access fully on"

# 3. Run the publisher, as it is, with fresh assets.
tdir=$(mktemp -d); prefix="check-$(date +%s)-$RANDOM"
printf 'console.log("%s");\n' "$prefix" > "$tdir/app.js"
printf '/* %s */\n' "$prefix" > "$tdir/style.css"
out=$(cd "$DIR" && bash ./publish.sh "$tdir" "$prefix" 2>&1); rc=$?
rm -rf "$tdir"
cleanup() { aws s3 rm "s3://$BUCKET/$prefix/" --recursive >/dev/null 2>&1; }
if (( rc != 0 )); then
  c_bad "publish.sh still fails: $(tail -n 3 <<<"$out" | tr '\n' ' ' | cut -c1-400)"
  cleanup
  exit 1
fi
c_ok "publish.sh ran: $(tail -n 1 <<<"$out")"
for f in app.js style.css; do
  aws s3api head-object --bucket "$BUCKET" --key "$prefix/$f" >/dev/null 2>&1 \
    || { c_bad "publish.sh said OK but s3://$BUCKET/$prefix/$f does not exist (does it still take ASSET_DIR PREFIX as arguments?)"; cleanup; exit 1; }
done
c_ok "the assets arrived in the bucket (owned by the bucket owner)"

# 4. Not public: an anonymous GET must be refused.
url="https://$BUCKET.s3.us-east-1.amazonaws.com/$prefix/app.js"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$url")
if [[ $code != 403 ]]; then
  c_bad "anonymous GET of the object returned HTTP $code, expected 403: the assets must not be public"
  cleanup; exit 1
fi
c_ok "anonymous GET is refused (403): the bucket is not serving the assets publicly"

# 5. The intended access path works: a presigned URL.
psu=$(aws s3 presign "s3://$BUCKET/$prefix/app.js" --expires-in 120 2>/dev/null)
body=$(curl -s --max-time 20 "$psu")
cleanup
if [[ $body != *"$prefix"* ]]; then
  c_bad "a presigned URL for the object does not return it (got: $(cut -c1-120 <<<"$body"))"; exit 1
fi
c_ok "a presigned URL serves the object: that is how the site gets its assets"

if [[ -f $TOWN ]]; then
  echo "PENALTY 40 Object Ownership was changed ($(cat "$TOWN")). That re-enables ACLs to keep a 2019 flag alive. The bucket was right: ACLs are disabled by default for a reason; the fix is in the script."
fi
if [[ -f $TPUB ]]; then
  echo "PENALTY 40 $(cat "$TPUB"). The assets must stay private (signed URLs / CDN); opening the bucket is not the fix."
fi
exit 0
