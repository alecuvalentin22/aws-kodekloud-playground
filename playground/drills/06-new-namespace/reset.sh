#!/usr/bin/env bash
source "$(dirname "$0")/../../lib/common.sh"
K delete namespace payments-staging --ignore-not-found --wait=false
for crb in $(K get clusterrolebindings -o json | jq -r '.items[] | select(any(.subjects[]?; .name=="jenkins-agent")) | .metadata.name'); do
  K delete clusterrolebinding "$crb"
done
