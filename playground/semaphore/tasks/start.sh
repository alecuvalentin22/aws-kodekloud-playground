#!/usr/bin/env bash
# Template "Start drill". Survey: drill (01-99 | random), track, tier.
# Every value is checked against an allowlist before it reaches `play`.
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

drill=$(survey drill); track=$(survey track); tier=$(survey tier)
[[ -z $drill ]] && drill=random
[[ -z $track ]] && track=any
[[ -z $tier ]] && tier=local

args=()
if [[ $drill == random ]]; then
  case $track in any) ;; jenkins|kubernetes|terraform|aws) args+=(--track "$track") ;;
    *) echo "refused: track '$track'" >&2; exit 2 ;; esac
  case $tier in local|aws) args+=(--tier "$tier") ;;
    *) echo "refused: tier '$tier'" >&2; exit 2 ;; esac
elif [[ $drill =~ ^[0-9]{2}$ ]]; then
  ls "$(dirname "$PLAY")/drills/$drill"-* >/dev/null 2>&1 || { echo "refused: no drill $drill" >&2; exit 2; }
  args+=("$drill")
else
  echo "refused: drill '$drill'" >&2; exit 2
fi

exec bash "$PLAY" start "${args[@]}"
