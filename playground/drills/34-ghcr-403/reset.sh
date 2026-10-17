#!/usr/bin/env bash
# Drill state only; lib/reset-github.sh restores ci.yml. The images already pushed stay in GHCR (tags are per commit).
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/github.sh"
gh_state_rm drill34.bad-sha
