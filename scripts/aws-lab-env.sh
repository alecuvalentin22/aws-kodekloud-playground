#!/usr/bin/env bash
# SOURCE this, do not execute it -- it exports into your current shell:
#
#   source scripts/aws-lab-env.sh
#
# Gets API credentials for the KodeKloud playground WITHOUT creating an access
# key, by exchanging the console session for temporary ones.
#
# DOES NOT WORK IN THE KODEKLOUD PLAYGROUND -- verified on two separate
# accounts, both of which answered:
#
#     Authentication failed
#     Invalid request
#
# The flow needs console-to-CLI federation, which the playground's boundary
# policy does not grant its IAM users. Use an access key there instead:
#   IAM -> Users -> <kk_labs_user> -> Security credentials -> Create access key
#
# This script is kept because it DOES work against a normal AWS account, and it
# is the better pattern there: no long-lived key ever exists.
#
# HOW IT WORKS
#   `aws login` (AWS CLI >= 2.31) opens a browser, you sign in with the same
#   console credentials KodeKloud gave you, and the CLI receives temporary
#   credentials plus a refresh token.
#
#   Those live in the CLI's own cache, which Terraform cannot read -- the AWS
#   Go SDK does not know about that cache. `aws configure export-credentials`
#   is the bridge: it runs the CLI's full credential resolution and prints
#   concrete AWS_ACCESS_KEY_ID / SECRET_ACCESS_KEY / SESSION_TOKEN, which
#   Terraform, Ansible and everything else understand.
#
# THEY EXPIRE. Re-source this when Terraform starts returning
# ExpiredToken -- it is one command, and the playground dies in ~3 hours anyway.

LAB_PROFILE="${LAB_PROFILE:-kklab}"
LAB_REGION="${LAB_REGION:-us-east-1}"

# Refuse to clobber a production profile that is already exported.
if [[ -n "${AWS_PROFILE:-}" && "$AWS_PROFILE" != "$LAB_PROFILE" ]]; then
  echo "AWS_PROFILE is currently '$AWS_PROFILE'." >&2
  echo "Unset it first so this cannot mix lab and non-lab credentials:" >&2
  echo "  unset AWS_PROFILE" >&2
  return 1 2>/dev/null || exit 1
fi

export AWS_DEFAULT_REGION="$LAB_REGION"
export AWS_REGION="$LAB_REGION"

# Clear any inherited static credentials so the login flow is what resolves.
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

if ! aws sts get-caller-identity --profile "$LAB_PROFILE" >/dev/null 2>&1; then
  echo "==> No valid session for profile '$LAB_PROFILE'. Opening the browser."
  echo "    Sign in with the credentials from aws-lab-creds."
  echo "    (over SSH with no browser? add --remote)"
  aws login --profile "$LAB_PROFILE" || {
    echo "aws login failed." >&2
    return 1 2>/dev/null || exit 1
  }
fi

# The bridge: CLI credential resolution -> plain environment variables.
if ! CREDS="$(aws configure export-credentials --profile "$LAB_PROFILE" --format env 2>&1)"; then
  echo "Could not export credentials:" >&2
  echo "$CREDS" >&2
  return 1 2>/dev/null || exit 1
fi
eval "$CREDS"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text)"

echo
echo "  Account  : $ACCOUNT_ID"
echo "  Identity : $CALLER_ARN"
echo "  Region   : $AWS_DEFAULT_REGION"
echo
echo "  Terraform and Ansible will now use these. If this is the lab account,"
echo "  skip tf-init.sh's confirmation prompt with:"
echo "      export LAB_ACCOUNT_IDS=$ACCOUNT_ID"
echo
