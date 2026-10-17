#!/usr/bin/env bash
# Drill state only; lib/reset-github.sh re-applies the baseline protection, closes the PR and restores ci.yml.
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/github.sh"
gh_state_rm drill32.pr; gh_state_rm drill32.bad-sha
