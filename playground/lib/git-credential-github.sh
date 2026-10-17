#!/usr/bin/env bash
# git credential helper for the GitHub tier: `git push` over HTTPS with the
# playground token, without the token ever being in a remote URL, in
# .git/config, or in a keychain. Used as
#     credential.helper = /path/to/this/file
# git calls it as `<helper> get|store|erase` with key=value lines on stdin.
# Answers `get` for github.com only; ignores store/erase (nothing is saved).
[[ ${1:-} == get ]] || exit 0
host=""
while IFS='=' read -r k v; do
  [[ -z $k ]] && break
  [[ $k == host ]] && host=$v
done
[[ $host == github.com ]] || exit 0
f="${GITHUB_PLAYGROUND_ENV:-$HOME/.config/platform-lab/github-playground.env}"
[[ -r $f ]] || exit 0
mode=$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f" 2>/dev/null)
[[ $mode == 600 || $mode == 400 ]] || exit 0
val() { awk -v k="$1" '{ sub(/^[ \t]+/, ""); sub(/^export[ \t]+/, "") }
  index($0, k "=") == 1 { sub(/^[^=]*=/, ""); v = $0 } END { print v }' "$f" \
  | sed -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"; }
tok=$(val GITHUB_TOKEN); owner=$(val GITHUB_OWNER)
[[ -n $tok ]] || exit 0
printf 'username=%s\npassword=%s\n' "${owner:-x-access-token}" "$tok"
