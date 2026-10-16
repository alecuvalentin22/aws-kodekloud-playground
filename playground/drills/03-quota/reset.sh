#!/usr/bin/env bash
source "$(dirname "$0")/../../lib/common.sh"
K -n demo-ci delete resourcequota cost-guardrails --ignore-not-found
