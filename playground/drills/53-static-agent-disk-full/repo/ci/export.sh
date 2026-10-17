#!/usr/bin/env bash
# Export the ledger (simulated: 28 MB of rows) to out/ledger-<build>.csv and
# keep a compressed copy for archiving.
set -euo pipefail
mkdir -p out
f="out/ledger-${BUILD_NUMBER:-local}.csv"
trap 'rm -f "$f" "$f.gz"' ERR    # a failed export leaves no half-written file behind
echo "exporting the ledger to $f ..."
head -c 28M /dev/zero | tr '\0' '7' > "$f"
gzip -c "$f" > "$f.gz"
echo "wrote $(du -h "$f" | cut -f1) $f and $(du -h "$f.gz" | cut -f1) $f.gz"
echo "workspace filesystem:"; df -h . | tail -1
