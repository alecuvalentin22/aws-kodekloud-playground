#!/usr/bin/env bash
# bs.sh -- a tiny Backstage catalog client for the exercise. It signs in as
# "guest" for you and shows what the Register page in the browser does.
#
#   ./bs.sh validate FILE.yaml      is every entity in this file valid? (BEFORE you push it)
#   ./bs.sh dry-run URL             what would Backstage make of this GitHub URL? (stores nothing)
#   ./bs.sh register URL            register the URL as a catalog location (like the UI button)
#   ./bs.sh locations               locations registered through the API/UI, with their ids
#   ./bs.sh refresh ENTITY_REF      ask Backstage to re-read now, e.g. location:default/generated-abc...
#   ./bs.sh unregister URL|ID       remove a location (its entities disappear too)
#   ./bs.sh get KIND NAME           one entity: owner, system, relations, errors (e.g. get component candidate-orders)
#   ./bs.sh errors [SINCE]          processing errors from the Backstage pod log (needs kubectl; SINCE like 30m)
#
# Environment: BS_URL (rarely needed), KUBECONFIG (only for `errors`).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ $# -ge 1 ] || usage
cmd="$1"; shift

# `errors` talks to Kubernetes, not to Backstage's API: no sign-in needed.
if [ "$cmd" = errors ]; then
  command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found. Install it, or read the same log in Headlamp (namespace backstage, pod backstage-...)." >&2; exit 1; }
  since="${1:-30m}"
  kubectl -n backstage logs deploy/backstage --since="$since" 2>&1 | python3 -c '
import sys, json
n = 0
for line in sys.stdin:
    try:
        o = json.loads(line)
    except Exception:
        if "forbidden" in line.lower() or "unauthorized" in line.lower() or "error from server" in line.lower():
            print(line.rstrip()); n += 1
        continue
    if o.get("level") in ("warn", "error") and ("entity" in o or "location" in o or "Policy check" in o.get("message", "")):
        n += 1
        print("%s: %s" % (o.get("entity") or o.get("location") or "-", o.get("message", "")[:400]))
        if o.get("location") and o.get("entity"):
            print("    from: %s" % o["location"])
if n == 0:
    print("No catalog processing warnings or errors in this time window.")
'
  exit 0
fi

bs_init || exit 1

case "$cmd" in
  validate)
    f="${1:-}"; [ -f "$f" ] || usage
    # YAML -> JSON. PyYAML if present, else the Ruby that ships with macOS.
    if ! python3 -c 'import sys, json, yaml; print(json.dumps([d for d in yaml.safe_load_all(open(sys.argv[1])) if d]))' "$f" > "$BS_TMP/docs.json" 2>"$BS_TMP/err"; then
      ruby -ryaml -rjson -e 'puts JSON.generate(YAML.load_stream(File.read(ARGV[0])).compact)' "$f" > "$BS_TMP/docs.json" 2>"$BS_TMP/err" || {
        echo "Could not parse $f as YAML:"; head -n 1 "$BS_TMP/err" | sed "s/^.*(<unknown>): //"; exit 1; }
    fi
    n="$(python3 - "$BS_TMP" "$(basename "$f")" <<'EOF'
import json, sys
tmp, base = sys.argv[1], sys.argv[2]
docs = json.load(open(tmp + "/docs.json"))
for i, d in enumerate(docs):
    json.dump({"entity": d, "location": "url:https://github.com/local/validate/blob/main/" + base},
              open("%s/doc%d.json" % (tmp, i), "w"))
print(len(docs))
EOF
)"
    [ "$n" -ge 1 ] 2>/dev/null || { echo "No YAML documents found in $f"; exit 1; }
    bad=0
    i=0
    while [ "$i" -lt "$n" ]; do
      bs_req POST /api/catalog/validate-entity --data-binary "@$BS_TMP/doc$i.json"
      label="$(pj "d['entity']['kind']+' '+d['entity'].get('metadata',{}).get('name','?')" "$BS_TMP/doc$i.json")"
      if [ "$BS_CODE" = 200 ]; then
        printf '  \342\234\223 %s\n' "$label"
      else
        bad=$((bad + 1))
        printf '  \342\234\227 %s\n      %s\n' "$label" "$(err_msg | sed 's/ To learn more about catalog file format.*//')"
      fi
      i=$((i + 1))
    done
    echo
    if [ "$bad" -eq 0 ]; then
      echo "All $n entities are valid. (This checks the SHAPE only. It cannot tell whether the owner or the system you named exists.)"
    else
      echo "$bad of $n entities are invalid. Backstage reports one problem per entity at a time: fix, run again."
      exit 1
    fi
    ;;

  dry-run)
    url="${1:-}"; [ -n "$url" ] || usage
    bs_post "/api/catalog/locations?dryRun=true" "$(printf '{"type":"url","target":"%s"}' "$url")"
    if [ "$BS_CODE" = 200 ] || [ "$BS_CODE" = 201 ]; then
      echo "Backstage can read it and every entity is valid:"
      pj "'\n'.join('  %s %s' % (e['kind'], e['metadata']['name']) for e in d['entities'] if e['kind']!='Location')"
      [ "$(pj "d.get('exists')")" = True ] && echo "(this location is already registered)"
    else
      echo "Backstage refuses it (HTTP $BS_CODE):"
      echo "  $(err_msg)" | sed 's/ To learn more about catalog file format.*//'
      exit 1
    fi
    ;;

  register)
    url="${1:-}"; [ -n "$url" ] || usage
    bs_post "/api/catalog/locations" "$(printf '{"type":"url","target":"%s"}' "$url")"
    if [ "$BS_CODE" = 201 ] || [ "$BS_CODE" = 200 ]; then
      echo "Registered. location id: $(pj "d['location']['id']")"
      echo "             entity ref: $(pj "d['location']['entityRef']")"
      echo "Backstage now reads the file in the background (a few seconds). If the entity does not"
      echo "show up, the file has a problem: run './bs.sh dry-run $url' and './bs.sh errors'."
    else
      echo "Registering failed (HTTP $BS_CODE): $(err_msg)" | sed 's/ To learn more about catalog file format.*//'
      exit 1
    fi
    ;;

  locations)
    bs_req GET /api/catalog/locations
    pj "'\n'.join('%s  %s\n    %s' % (x['data']['id'], x['data']['target'], x['data']['entityRef']) for x in d) or '(none registered through the API/UI; the catalog.locations of the config are not listed here)'"
    ;;

  unregister)
    arg="${1:-}"; [ -n "$arg" ] || usage
    case "$arg" in
      http*)
        bs_req GET /api/catalog/locations
        id="$(pj "[x['data']['id'] for x in d if x['data']['target']=='$arg'][0]")"
        [ -n "$id" ] || { echo "No registered location has that URL. See './bs.sh locations'."; exit 1; } ;;
      *) id="$arg" ;;
    esac
    bs_req DELETE "/api/catalog/locations/$id"
    if [ "$BS_CODE" = 204 ]; then echo "Unregistered $id. Its entities leave the catalog within seconds."
    else echo "Unregister failed (HTTP $BS_CODE): $(err_msg)"; exit 1; fi
    ;;

  refresh)
    ref="${1:-}"; [ -n "$ref" ] || usage
    bs_post /api/catalog/refresh "$(printf '{"entityRef":"%s"}' "$ref")"
    if [ "$BS_CODE" = 200 ] || [ "$BS_CODE" = 201 ]; then echo "Refresh scheduled for $ref (give it a few seconds)."
    else echo "Refresh failed (HTTP $BS_CODE): $(err_msg)"; exit 1; fi
    ;;

  get)
    kind="${1:-}"; name="${2:-}"; [ -n "$kind" ] && [ -n "$name" ] || usage
    kind="$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')"
    bs_req GET "/api/catalog/entities/by-name/$kind/default/$name"
    if [ "$BS_CODE" != 200 ]; then
      echo "No $kind named '$name' in the catalog (HTTP $BS_CODE)."
      echo "If you registered a file for it: './bs.sh dry-run <url>' shows why Backstage may have dropped it."
      exit 1
    fi
    pj "'\n'.join([
      '%s %s' % (d['kind'], d['metadata']['name']),
      '  spec: ' + ', '.join('%s=%s' % (k, v) for k, v in d['spec'].items() if k in ('type','lifecycle','owner','system','domain','providesApis','dependsOn')),
      '  from: ' + d['metadata']['annotations'].get('backstage.io/managed-by-location','-'),
      '  relations:'] + ['    %-14s %s' % (r['type'], r['targetRef']) for r in d.get('relations',[])] +
      ['  processing status:'] + (['    %s: %s' % (i.get('level'), i.get('message','')[:300]) for i in (d.get('status') or {}).get('items',[])] or ['    (none)']))"
    ;;

  *) usage ;;
esac
