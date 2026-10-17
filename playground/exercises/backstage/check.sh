#!/usr/bin/env bash
# check.sh -- did you do the Backstage exercise? Read-only: it only reads the
# catalog through Backstage's API (as "guest"), it changes nothing.
#
#   EX_PREFIX=candidate ./check.sh
#
# Names it looks for (all from your prefix; override one with the variable in brackets):
#   component  <prefix>-orders        [EX_COMPONENT]   part 2, the service you onboarded
#   api        <prefix>-orders-api    [EX_API]
#   component  <prefix>-ledger        [EX_BROKEN]      part 3, the one you repaired
# Exit code 0 = every REQUIRED check passed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

P="$EX_PREFIX"
COMP="${EX_COMPONENT:-$P-orders}"
API="${EX_API:-$P-orders-api}"
BROKEN="${EX_BROKEN:-$P-ledger}"

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  \342\234\223 %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \342\234\227 %s\n' "$1"; [ -n "${2:-}" ] && printf '      hint: %s\n' "$2"; }
info() { printf '  - %s\n' "$1"; }

echo "Backstage exercise check -- prefix '$P' on $BS_URL"
echo

echo "0. Backstage and guest sign-in"
if bs_init; then ok "signed in as guest, got a token"; else
  bad "cannot sign in to Backstage" "is the PC on and are you on the home Wi-Fi? Open $BS_URL in a browser."
  echo; echo "Stopped: nothing else can be checked."; exit 1
fi
bs_req GET "/api/catalog/entity-facets?facet=kind"
total="$(pj "sum(x['count'] for x in d['facets']['kind'])")"
if [ "$BS_CODE" = 200 ]; then ok "the catalog answers ($total entities in total)"; else
  bad "the catalog does not answer (HTTP $BS_CODE)"; echo; echo "Stopped."; exit 1
fi

# exists KIND NAME -> 0 if the entity is in the catalog (kind is lower case, namespace default)
exists() {
  bs_req GET "/api/catalog/entities/by-name/$1/default/$2"
  [ "$BS_CODE" = 200 ]
}
# ref_exists "kind:ns/name" -> 0 if that entity is in the catalog
ref_exists() {
  local ref="$1" kind rest
  kind="${ref%%:*}"; rest="${ref#*:}"
  bs_req GET "/api/catalog/entities/by-name/$kind/$rest"
  [ "$BS_CODE" = 200 ]
}
# rel TYPE -> target refs of that relation type in the last body, space separated
rel() { pj "' '.join(r['targetRef'] for r in d.get('relations', []) if r['type']=='$1')"; }

# check_component NAME WITH_API(yes|no)
check_component() {
  local name="$1" with_api="$2" owner system lifecycle errs loc api_ref p_ref
  if ! exists component "$name"; then
    bad "component '$name' is not in the catalog (HTTP $BS_CODE)" \
        "it is either not registered, or Backstage dropped it because it is invalid: './bs.sh dry-run <your url>' then './bs.sh errors'"
    return 1
  fi
  cp "$BS_TMP/body" "$BS_TMP/comp.json"
  ok "component '$name' is in the catalog"

  loc="$(pj "d['metadata']['annotations'].get('backstage.io/managed-by-location','')" "$BS_TMP/comp.json")"
  case "$loc" in
    url:https://github.com/*) ok "it came from GitHub, not typed in by hand ($loc)" ;;
    *) bad "it did not come from a GitHub URL (managed-by-location is '$loc')" "register your file's github.com URL" ;;
  esac

  errs="$(pj "'; '.join(i.get('message','')[:160] for i in (d.get('status') or {}).get('items', []) if i.get('level')=='error')" "$BS_TMP/comp.json")"
  if [ -z "$errs" ]; then ok "no processing errors on the entity"; else bad "processing errors: $errs"; fi

  owner="$(pj "' '.join(r['targetRef'] for r in d.get('relations', []) if r['type']=='ownedBy')" "$BS_TMP/comp.json")"
  if [ -n "$owner" ] && ref_exists "$owner"; then ok "owner is $owner, and that Group exists in the catalog"
  elif [ -n "$owner" ]; then bad "owner is $owner, but no such entity exists" "which Groups are in the catalog? (Catalog, kind Group)"
  else bad "the entity has no owner" "spec.owner is required"; fi

  system="$(pj "' '.join(r['targetRef'] for r in d.get('relations', []) if r['type']=='partOf')" "$BS_TMP/comp.json")"
  if [ -n "$system" ] && ref_exists "$system"; then
    ok "part of $system, and that System exists"
    cp "$BS_TMP/body" "$BS_TMP/system.json"
    if [ "$(pj "'component:default/$name' in [r['targetRef'] for r in d.get('relations', []) if r['type']=='hasPart']" "$BS_TMP/system.json")" = True ]; then
      ok "the System lists the component back (hasPart): relations are two-way"
    else
      bad "the System does not list '$name' as a part yet" "wait a few seconds and run again; Backstage builds the reverse relation after the first pass"
    fi
  elif [ -n "$system" ]; then bad "part of $system, but that System does not exist" "spec.system must name a System that is in the catalog"
  else bad "the entity is not part of any System" "set spec.system"; fi

  lifecycle="$(pj "d['spec'].get('lifecycle','')" "$BS_TMP/comp.json")"
  case "$lifecycle" in
    experimental|production|deprecated) ok "lifecycle is '$lifecycle'" ;;
    *) bad "lifecycle is '$lifecycle'" "use experimental, production or deprecated, so the catalog can be filtered" ;;
  esac

  if [ "$with_api" = yes ]; then
    api_ref="$(pj "' '.join(r['targetRef'] for r in d.get('relations', []) if r['type']=='providesApi')" "$BS_TMP/comp.json")"
    if [ -z "$api_ref" ]; then
      bad "the component provides no API" "add spec.providesApis"
    else
      for p_ref in $api_ref; do
        if ref_exists "$p_ref"; then
          ok "provides $p_ref, and that API exists"
          if [ "$(pj "'component:default/$name' in [r['targetRef'] for r in d.get('relations', []) if r['type']=='apiProvidedBy']")" = True ]; then
            ok "the API points back at the component (apiProvidedBy)"
          else
            info "the API does not list the component back yet (wait a few seconds and run again)"
          fi
          [ -n "$(pj "str(d['spec'].get('definition',''))[:1]")" ] && ok "the API has a definition (so the API tab can draw it)"
        else
          bad "provides $p_ref, but that API is not in the catalog" "put an API entity in the same file, or register the file that holds it"
        fi
      done
    fi
  fi
  return 0
}

echo; echo "1. Part 2 -- the service you onboarded: $COMP"
check_component "$COMP" yes
echo; echo "2. The API: $API"
if exists api "$API"; then
  ok "API '$API' is in the catalog (type $(pj "d['spec'].get('type','')"), owner $(pj "d['spec'].get('owner','')"))"
else
  bad "API '$API' is not in the catalog (HTTP $BS_CODE)" "an API entity in your catalog-info.yaml (kind: API)"
fi

echo; echo "3. Part 3 -- the entity you repaired: $BROKEN"
check_component "$BROKEN" no

echo; echo "4. For your story (not scored)"
info "entities in the catalog now: $total"
bs_req GET "/api/catalog/entities?filter=kind=location&fields=metadata.name,spec.target"
info "locations known to the catalog: $(pj "len(d)")"

echo
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  printf '\342\234\223 All %s required checks passed. You can talk about this from experience.\n' "$TOTAL"
  exit 0
fi
printf '\342\234\227 %s of %s required checks failed. Fix the lines marked with a cross and run again.\n' "$FAIL" "$TOTAL"
exit 1
