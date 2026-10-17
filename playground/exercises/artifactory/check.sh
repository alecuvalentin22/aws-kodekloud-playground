#!/usr/bin/env bash
# check.sh -- did you do the Artifactory exercise? Read-only: it only asks
# Artifactory questions (GET and a search), it changes nothing.
#
#   EX_PREFIX=candidate ./check.sh        # your prefix; default: candidate
#
# Needs the lab password in HOMELAB_ADMIN_PASSWORD (or it asks for it, hidden).
# Exit code 0 = every REQUIRED step passed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

P="$EX_PREFIX"
LOCAL="$P-maven-local"
REMOTE="$P-maven-remote"
CACHE="$P-maven-remote-cache"
VIRTUAL="$P-maven-virtual"
GROUP_PATH="com/example/$P"          # groupId com.example.$P
ART_PATH="$GROUP_PATH/hello/1.0.0/hello-1.0.0.jar"
DEP_JAR="${EX_DEP_JAR:-commons-lang3-3.14.0.jar}"   # the dependency the README resolves

art_init
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  \342\234\223 %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \342\234\227 %s\n' "$1"; [ -n "${2:-}" ] && printf '      hint: %s\n' "$2"; }
info() { printf '  - %s\n' "$1"; }

echo "Artifactory exercise check -- prefix '$P' on $ART_URL"
echo

# 0. server and login ---------------------------------------------------------
echo "0. Server and login"
art_req GET /api/system/ping
if [ "$ART_CODE" = 200 ]; then ok "Artifactory answers ping"; else
  bad "Artifactory does not answer (HTTP $ART_CODE)" "is the PC on and are you on the home Wi-Fi? Artifactory is the last tool to come back after a reboot (about 20 min)"
  echo; echo "Stopped: nothing else can be checked."; exit 1
fi
art_req GET /api/repositories
if [ "$ART_CODE" = 200 ]; then
  ok "login works (admin can list repositories)"
  cp "$ART_TMP/body" "$ART_TMP/repos.json"
else
  bad "cannot list repositories (HTTP $ART_CODE)" "wrong password? Check HOMELAB_ADMIN_PASSWORD"
  echo; echo "Stopped: nothing else can be checked."; exit 1
fi

repo_field() { # KEY FIELD -> value from the repository list
  pj "[r.get('$2','') for r in d if r['key']=='$1'][0] if any(r['key']=='$1' for r in d) else ''" "$ART_TMP/repos.json"
}

# 1. local ---------------------------------------------------------------------
echo; echo "1. Local repository (a) -- your own artifacts live here"
t="$(repo_field "$LOCAL" type)"; k="$(repo_field "$LOCAL" packageType)"
if [ "$t" = LOCAL ] && [ "$k" = Maven ]; then ok "$LOCAL exists (LOCAL, Maven)"
else bad "$LOCAL is missing or not a local Maven repo (type='$t' package='$k')" "./art.sh create-repo local $LOCAL"; fi

# 2. remote --------------------------------------------------------------------
echo; echo "2. Remote repository (a) -- the caching proxy of Maven Central"
t="$(repo_field "$REMOTE" type)"; k="$(repo_field "$REMOTE" packageType)"; u="$(repo_field "$REMOTE" url)"
if [ "$t" = REMOTE ] && [ "$k" = Maven ]; then
  ok "$REMOTE exists (REMOTE, Maven)"
  case "$u" in
    *repo1.maven.org*|*repo.maven.apache.org*) ok "it proxies Maven Central ($u)" ;;
    *) bad "it proxies '$u', not Maven Central" "the URL should be https://repo1.maven.org/maven2" ;;
  esac
else
  bad "$REMOTE is missing or not a remote Maven repo (type='$t' package='$k')" "./art.sh create-repo remote $REMOTE https://repo1.maven.org/maven2"
fi

# 3. virtual -------------------------------------------------------------------
echo; echo "3. Virtual repository (b) -- one address for both"
t="$(repo_field "$VIRTUAL" type)"; k="$(repo_field "$VIRTUAL" packageType)"
if [ "$t" = VIRTUAL ] && [ "$k" = Maven ]; then ok "$VIRTUAL exists (VIRTUAL, Maven)"
else bad "$VIRTUAL is missing or not a virtual Maven repo (type='$t' package='$k')" "./art.sh create-repo virtual $VIRTUAL $LOCAL,$REMOTE $LOCAL"; fi
info "which repositories it contains cannot be read on OSS (the config REST call is Pro-only);"
info "steps 4 and 5 prove it by behaviour: it serves what is in BOTH of them."

# 4. dependency resolved through the virtual repo and cached --------------------
echo; echo "4. A dependency resolved through the virtual repo and cached (c)"
art_req POST /api/search/aql -H 'Content-Type: text/plain' \
  --data-binary "items.find({\"repo\":\"$CACHE\",\"type\":\"file\",\"name\":{\"\$match\":\"*.jar\"}})"
n="$(pj "d['range']['total']")"
if [ "$ART_CODE" = 200 ] && [ -n "$n" ] && [ "$n" -ge 1 ] 2>/dev/null; then
  ok "$CACHE holds $n cached .jar file(s) (Artifactory fetched them from Maven Central for you)"
  # Prefer the jar the README asks for; otherwise show the first one found.
  jar_path="$(pj "[r['path']+'/'+r['name'] for r in d['results'] if r['name']=='$DEP_JAR'][0] if any(r['name']=='$DEP_JAR' for r in d['results']) else d['results'][0]['path']+'/'+d['results'][0]['name']")"
  info "for example: $jar_path"
  art_req GET "/api/storage/$CACHE/$jar_path"
  sha1="$(pj "d['checksums']['sha1']")"; osha1="$(pj "d['originalChecksums']['sha1']")"
  rurl="$(pj "d.get('remoteUrl','')")"
  if [ -n "$sha1" ] && [ "$sha1" = "$osha1" ]; then
    ok "checksum: sha1 computed by Artifactory == sha1 published by Maven Central ($sha1)"
  else
    bad "checksums differ or are missing (computed '$sha1', original '$osha1')" "this should never happen; re-download the file"
  fi
  [ -n "$rurl" ] && info "it came from: $rurl"
  art_req GET "/api/storage/$VIRTUAL/$jar_path"
  if [ "$ART_CODE" = 200 ]; then ok "the same file is visible through $VIRTUAL (the virtual repo includes the remote)"
  else bad "the virtual repo does not show the cached file (HTTP $ART_CODE)" "is $REMOTE one of the members of $VIRTUAL?"; fi
else
  bad "nothing cached in $CACHE yet" "step 4 of the README: ask for a jar through $VIRTUAL (curl or the Maven container)"
fi

# 5. deploy your own artifact and download it back -------------------------------
echo; echo "5. Your own artifact in the local repo, with a checksum, downloaded back (d)"
art_req GET "/api/storage/$LOCAL/$ART_PATH"
if [ "$ART_CODE" = 200 ]; then
  ok "$ART_PATH is in $LOCAL"
  s256="$(pj "d['checksums']['sha256']")"; s1="$(pj "d['checksums']['sha1']")"; o1="$(pj "d.get('originalChecksums',{}).get('sha1','')")"
  if [ -n "$s256" ] && [ -n "$s1" ]; then ok "Artifactory stored checksums: sha1 $s1"; info "sha256 $s256"
  else bad "no checksums on the stored file"; fi
  if [ -n "$o1" ] && [ "$o1" = "$s1" ]; then
    ok "you sent the checksum with the upload and it matched (originalChecksums == checksums)"
  else
    bad "no client-sent checksum on the file (originalChecksums.sha1 is '$o1')" "upload again with -H \"X-Checksum-Sha1: <sha1>\" (README step 5)"
  fi
  art_req GET "/api/storage/$VIRTUAL/$ART_PATH"
  if [ "$ART_CODE" = 200 ]; then ok "it is also served through $VIRTUAL (so a build using the virtual repo can resolve it)"
  else bad "not visible through $VIRTUAL (HTTP $ART_CODE)"; fi
  art_req GET "/api/storage/$LOCAL/$ART_PATH?stats"
  dc="$(pj "d.get('downloadCount',0)")"
  if [ -n "$dc" ] && [ "$dc" -ge 1 ] 2>/dev/null; then ok "downloaded back $dc time(s) (download counter)"
  else bad "never downloaded back (download count is '$dc')" "README step 5: download it through $VIRTUAL and compare sha256"; fi
else
  bad "$ART_PATH is not in $LOCAL (HTTP $ART_CODE)" "README step 5: upload hello-1.0.0.jar to that exact path"
fi

# 6. things to look at, not required ----------------------------------------------
echo; echo "6. For your story (not scored)"
art_anon GET "/$LOCAL/$ART_PATH"
case "$ART_CODE" in
  401) info "anonymous download answers 401: nobody gets in without credentials (permissions)" ;;
  200) info "anonymous download WORKS: anonymous access is switched on in this Artifactory" ;;
  *)   info "anonymous download answered HTTP $ART_CODE" ;;
esac
art_req GET /api/system/version
info "edition: $(pj "d.get('license','?')+' '+d.get('version','')")"

echo
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  printf '\342\234\223 All %s required checks passed. You can talk about this from experience.\n' "$TOTAL"
  exit 0
fi
printf '\342\234\227 %s of %s required checks failed. Fix the lines marked with a cross and run again.\n' "$FAIL" "$TOTAL"
exit 1
