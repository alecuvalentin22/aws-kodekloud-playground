#!/usr/bin/env bash
# cleanup.sh -- empty the repositories this exercise made for your EX_PREFIX.
#
#   EX_PREFIX=candidate ./cleanup.sh
#
# What it deletes (only these, never the shared repositories):
#   - the artifact you uploaded:   <prefix>-maven-local/com/example/<prefix>/
#   - everything Artifactory cached in <prefix>-maven-remote-cache
# What it cannot delete: the repositories themselves. The OSS edition has no
# repository delete (REST: "available only in Artifactory Pro"). Empty ones cost nothing;
# run the exercise again with the same prefix and they are simply reused.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

P="$EX_PREFIX"
case "$P" in
  ""|*[!a-z0-9-]*|-*) echo "EX_PREFIX must be lower-case letters, digits and '-' (got '$P')." >&2; exit 2 ;;
esac
art_init

LOCAL="$P-maven-local"
CACHE="$P-maven-remote-cache"

del() { # PATH
  art_req DELETE "$1"
  case "$ART_CODE" in
    204|200) echo "  deleted $1" ;;
    404)     echo "  (nothing at $1)" ;;
    *)       echo "  could not delete $1 (HTTP $ART_CODE)" ;;
  esac
}

echo "Cleaning up for prefix '$P' on $ART_URL"
del "/$LOCAL/com/example/$P"

art_req GET "/api/storage/$CACHE"
if [ "$ART_CODE" = 200 ]; then
  # the top-level folders of the cache, one per line (each starts with "/")
  pj "'\n'.join(c['uri'] for c in d.get('children', []))" > "$ART_TMP/children"
  n=0
  while IFS= read -r child; do
    [ -n "$child" ] || continue
    del "/$CACHE$child"
    n=$((n + 1))
  done < "$ART_TMP/children"
  [ "$n" -gt 0 ] || echo "  $CACHE is already empty"
else
  echo "  $CACHE does not exist (HTTP $ART_CODE), nothing to empty"
fi
echo
echo "Done. The repositories $P-maven-local, $P-maven-remote and $P-maven-virtual still exist (OSS cannot delete them)."
