# shellcheck shell=bash
# Sourced by every playground template. Semaphore runs a bash template as
#   bash <playbook> [survey/extra vars as name=value ...]
# (services/tasks/local_executor.go getShellArgs), with cwd = the repository
# path and HOME = a per-template directory (db_lib/ShellApp.go makeCmd). So:
# nothing here may rely on $HOME, and every path comes from the environment.
set -euo pipefail

export PATH="/opt/playground/bin:$PATH"
PLAY="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/play"

for v in PLAYGROUND_STATE PLAYGROUND_WORK PLAYGROUND_JENKINS_URL PLAYGROUND_GITEA_URL KUBECONFIG; do
  [[ -n "${!v:-}" ]] || { echo "Semaphore environment is missing $v (see playground/semaphore/README.md)" >&2; exit 2; }
done
[[ -r "$KUBECONFIG" ]] || {
  echo "No kubeconfig at $KUBECONFIG. On the laptop run: playground/semaphore/kubeconfig.sh" >&2; exit 2; }
command -v kubectl >/dev/null || { echo "kubectl missing: is this the playground image?" >&2; exit 2; }

# Survey answers arrive as name=value arguments. Read only the names we know;
# anything else is ignored, never evaluated.
declare -A SURVEY=()
for arg in "$@"; do
  [[ $arg == *=* ]] || continue
  SURVEY["${arg%%=*}"]="${arg#*=}"
done
survey() { printf '%s' "${SURVEY[$1]:-}"; }
