#!/usr/bin/env bash
# Drill state only. The PR is closed, the branch deleted and ci.yml restored by lib/reset-github.sh.
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/github.sh"
gh_state_rm drill31.pr; gh_state_rm drill31.bad-sha
