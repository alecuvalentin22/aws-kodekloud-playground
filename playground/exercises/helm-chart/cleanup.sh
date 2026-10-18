#!/usr/bin/env bash
# Remove everything the exercise created on the playground: the release (and its
# Secrets), the namespace, the image and chart tags in the registry, the local
# image tags. Your working copy (~/platform-playground/notes-api) is YOURS and is
# kept, unless you pass --work.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

if H -n "$NS" status "$REL" >/dev/null 2>&1; then
  H -n "$NS" uninstall "$REL" --wait >/dev/null 2>&1 && c_ok "uninstalled release $REL"
fi
if K get ns "$NS" >/dev/null 2>&1; then
  K delete ns "$NS" --ignore-not-found --timeout=120s >/dev/null 2>&1 && c_ok "deleted namespace $NS (release Secrets included)"
fi
for repo in "$IMG_REPO" "$CHART_REPO/notes-api"; do
  for tag in $(reg_tags "$repo"); do
    reg_delete_tag "$repo" "$tag" && c_ok "removed registry tag $repo:$tag" || c_warn "could not remove $repo:$tag"
  done
done
for tag in $IMG_TAGS; do docker rmi "$REG_HOST/$IMG_REPO:$tag" >/dev/null 2>&1 && c_ok "removed local image $IMG_REPO:$tag"; done
if [[ ${1:-} == --work ]]; then rm -rf "$PROJECT" && c_ok "removed $PROJECT"; elif [[ -d $PROJECT ]]; then c_dim "  (kept your working copy $PROJECT; --work removes it)"; fi
exit 0
