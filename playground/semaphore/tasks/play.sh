#!/usr/bin/env bash
# Every template except "Start drill": the play command comes from the
# template's own `arguments` (fixed in project.tf, not user input), e.g.
#   bash playground/semaphore/tasks/play.sh check
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

cmd=${1:-}
case $cmd in
  status|hint|check|close|reveal|reset|score|doctor|list) ;;
  *) echo "refused: '$cmd' is not a playground command" >&2; exit 2 ;;
esac
exec bash "$PLAY" "$cmd"
