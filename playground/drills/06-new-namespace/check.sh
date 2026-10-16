#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
SA=system:serviceaccount:jenkins:jenkins-agent
can() { K auth can-i "$@" --as="$SA" 2>/dev/null; }
fail=0
if [[ $(can '*' '*' --all-namespaces) == yes ]]; then
  c_bad "jenkins-agent is effectively cluster-admin. Any branch of any repo Jenkins builds now owns the cluster."; fail=1
fi
if [[ $(can create deployments -n kube-system) == yes ]]; then
  c_bad "jenkins-agent can deploy into kube-system"; fail=1
fi
if [[ $(can create clusterrolebindings) == yes ]]; then
  c_bad "jenkins-agent can grant itself anything (create clusterrolebindings)"; fail=1
fi
(( fail )) && exit 1
c_ok "jenkins-agent is scoped: no cluster-wide rights"
[[ $(can create deployments -n payments-staging) == yes ]] || { c_bad "jenkins-agent cannot deploy to payments-staging"; exit 1; }
c_ok "jenkins-agent can deploy to payments-staging"
assert_main_green_since "$DRILL_STARTED" payments-staging || exit 1
