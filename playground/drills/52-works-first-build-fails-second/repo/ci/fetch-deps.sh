#!/usr/bin/env bash
# Fetch third-party libraries into vendor/ (simulated here: no network needed).
# vendor/ is git-ignored and expensive on the real build, so it is only fetched
# when it is not there yet.
set -euo pipefail
want=$(sed -n 's/^money-lib=//p' deps.lock)
if [[ -d vendor/money-lib ]]; then
  echo "vendor/money-lib present, skipping fetch (cache hit)"
else
  echo "fetching money-lib $want ..."
  mkdir -p vendor/money-lib
  echo "$want" > vendor/money-lib/VERSION
fi
echo "vendor: money-lib $(cat vendor/money-lib/VERSION)"
