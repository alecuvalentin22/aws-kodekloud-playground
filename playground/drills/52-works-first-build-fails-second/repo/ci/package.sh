#!/usr/bin/env bash
# Assemble the release: the templates plus a BUILD stamp, as release.tgz.
set -euo pipefail
mkdir -p dist
cp -R templates dist/          # copies in; nothing here ever deletes from dist/
echo "invoice-gen build ${BUILD_NUMBER:-local}" > dist/BUILD
tar czf release.tgz dist
echo "release.tgz contains:"
tar tzf release.tgz | grep -v '/$' | sort | sed 's/^/  /'
