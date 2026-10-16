#!/usr/bin/env bash
# A node "dies": rke2-a2 is powered off hard (incus stop --force = pulling the
# plug, no graceful drain). It happens to hold the local-path volumes of
# Jenkins, the image registry and Artifactory.
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"; source "$(dirname "$0")/../../lib/homelab.sh"
# Remember the volumes' identity: a "fix" that deletes and recreates a PVC
# brings the pod back with an EMPTY disk.
K get pvc -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}={.metadata.uid}{"\n"}{end}' > "$HL_STATE/21-pvc-uids"
hl_wsl incus stop --force rke2-a2
