#!/usr/bin/env bash
# Put your KodeKloud AWS keys where the AWS tier reads them -- without ever
# touching ~/.aws/credentials (AGENTS.md section 2).
#
#   playground/setup/aws-creds.sh                       asks for the key id, the secret (hidden) and a region
#   printf '%s\n%s\n' "$ID" "$SECRET" | playground/setup/aws-creds.sh --stdin
#                                                       non-interactive (line 3, optional: region)
#   --out FILE     write FILE instead of ~/.config/platform-lab/aws-lab-creds.env (for tests)
#   --region R     region without asking (default us-east-1)
#
# Run it on the machine that will play (the home-lab box, or a Mac). The keys are
# checked with `aws sts get-caller-identity` using environment variables of that
# one command only; the file is written only if they work. An existing file is
# copied to <file>.prev-<timestamp> first. Mode 600. Nothing is ever printed
# except the account number.
set -euo pipefail

OUT="${AWS_CREDS_FILE:-$HOME/.config/platform-lab/aws-lab-creds.env}"
REGION=""
STDIN=no
while (($#)); do
  case $1 in
    --stdin) STDIN=yes ;;
    --out) OUT=${2:?--out needs a file}; shift ;;
    --region) REGION=${2:?--region needs a value}; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; sed -n '2,10p' "$0" >&2; exit 2 ;;
  esac
  shift
done

command -v aws >/dev/null || { echo "aws CLI not found (on the home-lab box: ansible --tags awscli, see homelab/README.md)" >&2; exit 1; }

if [[ $STDIN == yes ]]; then
  IFS= read -r KEY_ID || true
  IFS= read -r SECRET || true
  IFS= read -r line3 || true
  [[ -n $REGION ]] || REGION=$line3
else
  [[ -t 0 ]] || { echo "not a terminal: pipe the values and use --stdin" >&2; exit 2; }
  read -r -p "AWS access key id (AKIA... / ASIA...): " KEY_ID
  read -r -s -p "AWS secret access key (hidden): " SECRET; echo
  if [[ -z $REGION ]]; then read -r -p "Region [us-east-1]: " REGION; fi
fi
REGION=${REGION:-us-east-1}
# Pasted values often carry spaces, CR or quotes.
KEY_ID=$(printf '%s' "$KEY_ID" | tr -d '[:space:]"'"'")
SECRET=$(printf '%s' "$SECRET" | tr -d '[:space:]"'"'")
[[ $KEY_ID =~ ^[A-Z0-9]{16,128}$ ]] || { echo "the access key id does not look like one (letters and digits, e.g. AKIA...)" >&2; exit 1; }
[[ -n $SECRET ]] || { echo "empty secret" >&2; exit 1; }
[[ $REGION =~ ^[a-z]{2}(-[a-z]+)+-[0-9]+$ ]] || { echo "region '$REGION' does not look like one (us-east-1)" >&2; exit 1; }

# Validate: the values live in this one command's environment, never in a file
# or ~/.aws. env -u drops anything inherited that would win over them.
if acct=$(AWS_ACCESS_KEY_ID=$KEY_ID AWS_SECRET_ACCESS_KEY=$SECRET AWS_DEFAULT_REGION=$REGION \
          env -u AWS_PROFILE -u AWS_SESSION_TOKEN \
          aws sts get-caller-identity --query Account --output text 2>/dev/null); then
  echo "keys accepted: account $acct"
else
  echo "AWS rejected these keys (typo, or the KodeKloud session is over): nothing written" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
chmod 700 "$(dirname "$OUT")" 2>/dev/null || true
if [[ -e $OUT ]]; then
  bak="$OUT.prev-$(date +%Y-%m-%dT%H%M%S)"
  cp -p "$OUT" "$bak" && chmod 600 "$bak"
  echo "previous file kept as $(basename "$bak")"
fi
(
  umask 077
  tmp=$(mktemp "$OUT.XXXXXX")
  printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\nAWS_DEFAULT_REGION=%s\nAWS_REGION=%s\n' \
    "$KEY_ID" "$SECRET" "$REGION" "$REGION" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$OUT"
)
echo "wrote $OUT (mode 600)"
