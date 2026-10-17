#!/usr/bin/env bash
# art.sh -- a tiny Artifactory client for the exercise. It adds the admin login
# for you (never on the command line) and prints the HTTP status on stderr.
#
#   ./art.sh GET  /api/repositories                  # any REST call: METHOD PATH [curl options]
#   ./art.sh PUT  /REPO/some/path/file.jar -T file.jar -H "X-Checksum-Sha256: <hash>"
#   ./art.sh create-repo local   KEY
#   ./art.sh create-repo remote  KEY URL
#   ./art.sh create-repo virtual KEY MEMBER1,MEMBER2 [DEPLOY_REPO]
#
# PATH is relative to http://artifactory.<ip>.nip.io/artifactory.
# Environment: HOMELAB_ADMIN_PASSWORD (asked for if unset), ART_URL (rarely needed).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ $# -ge 1 ] || usage

art_init

if [ "$1" = "create-repo" ]; then
  kind="${2:-}"; key="${3:-}"
  [ -n "$kind" ] && [ -n "$key" ] || usage
  # The REST call for this (PUT /api/repositories/KEY) is Artifactory Pro only.
  # The web UI uses a different, internal endpoint, and OSS accepts it from a
  # logged-in UI session. This does exactly what the "Create Repository" wizard does.
  case "$kind" in
    local)
      payload="$(printf '{"type":"localRepoConfig","typeSpecific":{"repoType":"Maven"},"general":{"repoKey":"%s"},"basic":{"includesPattern":"**/*","publicDescription":"exercise","layout":"maven-2-default"},"advanced":{}}' "$key")" ;;
    remote)
      url="${4:-}"; [ -n "$url" ] || usage
      payload="$(printf '{"type":"remoteRepoConfig","typeSpecific":{"repoType":"Maven"},"general":{"repoKey":"%s"},"basic":{"url":"%s","publicDescription":"exercise","layout":"maven-2-default"},"advanced":{}}' "$key" "$url")" ;;
    virtual)
      members="${4:-}"; deploy="${5:-}"; [ -n "$members" ] || usage
      list=""
      old_ifs="$IFS"; IFS=','
      for m in $members; do list="${list:+$list,}{\"repoName\":\"$m\"}"; done
      IFS="$old_ifs"
      dep=""; [ -n "$deploy" ] && dep=",\"defaultDeploymentRepo\":\"$deploy\""
      payload="$(printf '{"type":"virtualRepoConfig","typeSpecific":{"repoType":"Maven"},"general":{"repoKey":"%s"},"basic":{"selectedRepositories":[%s]%s,"publicDescription":"exercise","layout":"maven-2-default"},"advanced":{}}' "$key" "$list" "$dep")" ;;
    *) usage ;;
  esac
  art_ui_login
  [ "$ART_CODE" = 200 ] || { echo "UI login failed (HTTP $ART_CODE). Wrong password?" >&2; exit 1; }
  art_ui_post /admin/repositories "$payload"
  cat "$ART_TMP/body"; echo
  echo "-- HTTP $ART_CODE" >&2
  [ "$ART_CODE" = 200 ]
  exit
fi

method="$1"; path="${2:-}"
[ -n "$path" ] || usage
shift 2
art_req "$method" "$path" "$@"
cat "$ART_TMP/body"
# Add a final newline only when printing to the screen: when you redirect the
# output into a file (> back.jar) the bytes must stay exactly as they were sent.
if [ -t 1 ] && [ -s "$ART_TMP/body" ]; then echo; fi
echo "-- HTTP $ART_CODE" >&2
case "$ART_CODE" in 2??) exit 0 ;; *) exit 1 ;; esac
