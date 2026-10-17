#!/usr/bin/env bash
# Drill state only; lib/reset-github.sh restores the shared repo's tree, deletes release tags
# the candidate cut, and puts v1.0.0 back if it was moved.
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/github.sh"
gh_state_rm drill33.bad-sha
