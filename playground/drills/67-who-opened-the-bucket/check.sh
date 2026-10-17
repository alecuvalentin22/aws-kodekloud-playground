#!/usr/bin/env bash
# Fixed means:
#   1. CONTAINED (live): the bucket's block public access has all four flags true and
#      the bucket policy has no unconditional Allow to Principal "*" (or no policy).
#      The bucket must still EXIST: deleting it destroys the evidence (PENALTY 30).
#   2. The incident note ~/platform-playground-aws/answers/67.md exists and is right
#      against what CloudTrail says (looked up here, by bucket name, for the calls
#      sent by the teammate-script's userAgent):
#        - names both API calls (PutBucketPolicy and PutBucketPublicAccessBlock),
#        - has the EventId of one of the culprit events (a noise event's id does not count),
#        - has the identity ARN from the event,
#        - has the userAgent marker (platform-lab-tidy-script),
#        - has a prevention keyword (block public access | SCP | Config | alert).
#      PENALTY 10 when the note has no time within 2 minutes of the culprit events (UTC).
# Hard to game: the ids and the ARN are not in the ticket or in the workspace; they
# come only from CloudTrail, and check.sh compares with a fresh LookupEvents.
# AWS API calls: s3:HeadBucket, GetPublicAccessBlock, GetBucketPolicy (read-only);
# cloudtrail:LookupEvents (read-only).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lib/common.sh"; source "$HERE/../../lib/aws.sh"; aws_env
source "$HERE/trail.sh"
REC="$STATE/drill67.env"
[[ -f $REC ]] || { c_bad "no record of the break ($REC): was the drill started with play start?"; exit 1; }
BUCKET=""; MARKER=""; T0=0
# shellcheck disable=SC1090
source "$REC"
ANS="$WORK/answers/67.md"
bad=0; pen=()

# --- 1. containment -----------------------------------------------------------------
gone=no
hb=$(aws s3api head-bucket --bucket "$BUCKET" 2>&1); hrc=$?
if (( hrc != 0 )); then
  if grep -Eq '404|Not Found|NoSuchBucket' <<<"$hb"; then
    gone=yes
    c_warn "bucket $BUCKET no longer exists: nothing is public, but the evidence went with it"
    pen+=("PENALTY 30 The bucket was deleted instead of contained. Legal and the investigation needed its configuration and contents as evidence; contain first (block public access + remove the policy), delete never, until the incident is closed.")
  else
    c_bad "cannot reach bucket $BUCKET: ${hb:0:160}"; exit 1
  fi
fi

if [[ $gone == no ]]; then
  bpa=$(aws s3api get-public-access-block --bucket "$BUCKET" --output json 2>&1); brc=$?
  if (( brc != 0 )); then
    c_bad "block public access is not configured on $BUCKET (${bpa:0:120})"; bad=1
  else
    nfalse=$(jq '[.PublicAccessBlockConfiguration | to_entries[] | select(.value != true)] | length' <<<"$bpa" 2>/dev/null)
    nkeys=$(jq '.PublicAccessBlockConfiguration | length' <<<"$bpa" 2>/dev/null)
    if [[ ${nkeys:-0} -ne 4 || ${nfalse:-1} -ne 0 ]]; then
      c_bad "block public access on $BUCKET is not fully on (all four settings must be true)"; bad=1
    else
      c_ok "block public access: all four settings are on"
    fi
  fi
  pol=$(aws s3api get-bucket-policy --bucket "$BUCKET" --query Policy --output text 2>&1); prc=$?
  if (( prc != 0 )); then
    if grep -q NoSuchBucketPolicy <<<"$pol"; then
      c_ok "no bucket policy"
    else
      c_bad "cannot read the bucket policy: ${pol:0:160}"; bad=1
    fi
  else
    npub=$(jq '[ .Statement | (if type == "array" then . else [.] end)[]
                 | select(.Effect == "Allow")
                 | select(has("Condition") | not)
                 | select(.Principal == "*"
                          or ((.Principal | type) == "object"
                              and ((.Principal.AWS == "*") or ((.Principal.AWS | type) == "array" and (.Principal.AWS | index("*") != null))))) ] | length' <<<"$pol" 2>/dev/null)
    if [[ ${npub:-1} -ne 0 ]]; then
      c_bad "the bucket policy still has a statement granting access to everyone (Principal \"*\")"; bad=1
    else
      c_ok "the bucket policy no longer grants access to everyone"
    fi
  fi
  if (( bad == 0 )); then
    code=$(curl -s -o /dev/null -w '%{http_code}' "https://$BUCKET.s3.amazonaws.com/exports/q3-summary.csv")
    if [[ $code == 200 ]]; then
      c_bad "anonymous GET of exports/q3-summary.csv still returns 200 (the change may still be propagating; try again in a few seconds)"; bad=1
    else
      c_ok "anonymous GET is refused (HTTP $code)"
    fi
  fi
fi
if (( bad )); then echo; c_dim "  (the incident note is looked at once the bucket is contained)"; exit 1; fi

# --- 2. the incident note --------------------------------------------------------------
if [[ ! -s $ANS ]]; then
  c_bad "no incident note at $ANS: the ticket asked for the API calls, EventId, identity, time (UTC), userAgent and prevention"; exit 1
fi
a=$(tr '[:upper:]' '[:lower:]' < "$ANS")
astrip=$(tr -d '_ -' <<<"$a")      # putbucketpolicy == put-bucket-policy == PutBucketPolicy

ev=$(trail_culprits "$BUCKET" $((T0 - 60)) "$MARKER") || ev=""
if [[ -z $ev ]]; then
  c_bad "CloudTrail does not show the culprit events for $BUCKET yet (events can take up to 15 min to appear, or LookupEvents is throttled): try again in a minute"; exit 1
fi
ids=$(jq -r .id <<<"$ev" | tr '[:upper:]' '[:lower:]' | sort -u)
arn=$(jq -r .arn <<<"$ev" | head -1 | tr '[:upper:]' '[:lower:]')

if ! grep -q 'putbucketpolicy' <<<"$astrip" || ! grep -q 'putbucketpublicaccessblock' <<<"$astrip"; then
  c_bad "the note must name both API calls that opened the bucket (one removed the guardrail, one granted access): PutBucketPublicAccessBlock and PutBucketPolicy"; bad=1
else
  c_ok "note names both API calls"
fi

found=""
for i in $ids; do grep -q "$i" <<<"$a" && found=$i; done
if [[ -z $found ]]; then
  if grep -Eq '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' <<<"$a"; then
    c_bad "the EventId in the note is not one of the culprit events (a call that opened the bucket was sent by the script, not by you: compare userAgent and requestParameters)"
  else
    c_bad "no CloudTrail EventId in the note (a UUID, from lookup-events: the PutBucketPolicy or PutBucketPublicAccessBlock that opened the bucket)"
  fi
  bad=1
else
  c_ok "EventId $found is a culprit event"
fi

if ! grep -qF "$arn" <<<"$a"; then
  c_bad "the identity ARN of the caller (userIdentity.arn in the event) is not in the note"; bad=1
else
  c_ok "note has the identity ARN"
fi

if ! grep -qF "$(tr '[:upper:]' '[:lower:]' <<<"$MARKER")" <<<"$a"; then
  c_bad "the userAgent marker of the caller is not in the note (read the userAgent field of the event: what did the client say it was?)"; bad=1
else
  c_ok "note has the userAgent marker"
fi

if ! grep -Eq 'block public access|blockpublicaccess|scp|service control|config rule|aws config|alert|guardduty|macie' <<<"$a"; then
  c_bad "the note has no prevention line (account-level block public access, an SCP, a Config rule / alerting on PutBucketPolicy)"; bad=1
else
  c_ok "note has a prevention line"
fi

# time: any HH:MM in the note within 2 minutes of a culprit event (UTC)
hastime=no
evmins=$(jq -r .time <<<"$ev" | sed -E 's/.*T([0-9]{2}):([0-9]{2}).*/\1 \2/' | while read -r h m; do echo $(( 10#$h * 60 + 10#$m )); done)
for t in $(grep -oE '(^|[^0-9])([01]?[0-9]|2[0-3]):[0-5][0-9]' <<<"$a" | grep -oE '([01]?[0-9]|2[0-3]):[0-5][0-9]'); do
  tm=$(( 10#${t%%:*} * 60 + 10#${t##*:} ))
  for e in $evmins; do
    d=$(( tm - e )); (( d < 0 )) && d=$(( -d ))
    (( d <= 2 )) && hastime=yes
  done
done
if [[ $hastime == yes ]]; then
  c_ok "note has the time (UTC)"
else
  c_warn "the note has no time (UTC) matching the events"
  pen+=("PENALTY 10 The note lacks the time of the change in UTC (eventTime in the CloudTrail event). An incident note without a timestamp cannot be lined up with the scanner, the deploys or the on-call log.")
fi

if (( bad )); then echo; c_dim "  (penalties are only counted once the check passes)"; exit 1; fi
(( ${#pen[@]} )) && printf '%s\n' "${pen[@]}"
c_ok "contained, and the incident note matches CloudTrail"
exit 0
