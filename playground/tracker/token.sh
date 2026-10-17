#!/usr/bin/env bash
# Get a Plane API token for the board WITHOUT the browser and write
# ~/.config/platform-lab/tracker.env (mode 600). Idempotent; never prints the token.
#
#   playground/tracker/token.sh            reuse the token in tracker.env if Plane still accepts it,
#                                          otherwise fetch/create the server-side one (below)
#   playground/tracker/token.sh --check    say whether tracker.env holds a working token; change nothing
#
# sync.sh runs this by itself when tracker.env is missing, so the usual entry
# point is just `playground/tracker/sync.sh`.
#
# How: Django's shell in the plane-api pod (`kubectl exec`, the home-lab
# kubeconfig), against Plane's own APIToken model (v1.4.2: label, token,
# user, workspace, is_active, expired_at). There is exactly ONE token labelled
# "platform-lab sync" for the admin user: an active, unexpired one is REUSED
# (the oldest; Plane keeps the value server-side), else one is created; extra copies with
# that label are deleted, so re-runs never pile tokens up. The value travels
# pod stdout -> a shell variable -> the file; it is never on a command line or
# on screen. Needs: the admin account (homelab/platform/plane-setup.sh admin).
#
# Env: TRACKER_ENV (file), TRACKER_URL (default http://tracker.192.168.0.23.nip.io),
#      PLANE_ADMIN_EMAIL (default admin@homelab.local), KUBECONFIG (default
#      homelab/generated/rke2-lan.kubeconfig in this repo).
# Without kubectl access: create one by hand at <TRACKER_URL>/settings/profile/api-tokens/
# and put it in the file (tracker/README.md, "Set up").
set -euo pipefail
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CONF=${TRACKER_ENV:-$HOME/.config/platform-lab/tracker.env}
URL=${TRACKER_URL:-http://tracker.192.168.0.23.nip.io}; URL=${URL%/}
WS=${TRACKER_WORKSPACE:-interview-prep}
PJ=${TRACKER_PROJECT:-PREP}
EMAIL=${PLANE_ADMIN_EMAIL:-admin@homelab.local}
LABEL="platform-lab sync"
export KUBECONFIG=${KUBECONFIG:-$REPO/homelab/generated/rke2-lan.kubeconfig}

say() { printf '  %s\n' "$*"; }
die() { printf '  ✗ token.sh: %s\n' "$*" >&2; exit 1; }
command -v curl >/dev/null || die "curl is required"

works() {   # TOKEN -> 0 if Plane accepts it (GET /api/v1/users/me/ = 200)
  local c
  c=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 15 \
    -K <(printf 'header = "X-API-Key: %s"\n' "$1") "$URL/api/v1/users/me/" 2>/dev/null) || true
  [[ $c == 200 ]]
}

existing=""
if [[ -f $CONF ]]; then
  existing=$(sed -n 's/^TRACKER_TOKEN=//p' "$CONF" | tail -1)
fi
if [[ ${1:-} == --check ]]; then
  if [[ -n $existing ]] && works "$existing"; then say "tracker.env token works ($CONF)"; exit 0; fi
  say "no working token in $CONF"; exit 1
fi
if [[ -n $existing ]] && works "$existing"; then
  say "tracker.env already holds a token Plane accepts: reused, nothing changed"
  exit 0
fi

command -v kubectl >/dev/null || die "kubectl is required (or create a token by hand, see tracker/README.md)"
[[ -f $KUBECONFIG ]] || die "no kubeconfig at $KUBECONFIG"
kubectl --request-timeout=20s -n plane get deploy plane-api-wl -o name >/dev/null 2>&1 \
  || die "cannot reach deploy/plane-api-wl in namespace plane (is the home lab up? KUBECONFIG=$KUBECONFIG)"

# No secret in this code; the e-mail, label and slug are passed as Python literals.
py=$(python3 -I -c '
import json, sys
email, label, slug = (json.dumps(a) for a in sys.argv[1:4])
print("""
from django.utils import timezone
from django.db.models import Q
from plane.db.models import User, APIToken, Workspace
u = User.objects.filter(email=%s).first()
if u is None:
    print("ERR no-admin")
else:
    live = APIToken.objects.filter(user=u, label=%s, is_active=True).filter(
        Q(expired_at__isnull=True) | Q(expired_at__gt=timezone.now())).order_by("created_at")   # the oldest: the one already handed out
    t = live.first()
    state = "reused"
    if t is None:
        t = APIToken.objects.create(user=u, label=%s, workspace=Workspace.objects.filter(slug=%s).first(),
            description="playground/tracker: sync.sh and the play hook (token.sh)", user_type=0)
        state = "created"
    extra = APIToken.objects.filter(user=u, label=%s).exclude(pk=t.pk)
    n = extra.count(); extra.delete()
    print("STATE " + state + " removed-duplicates=" + str(n))
    print("TOKEN " + t.token)
""" % (email, label, label, slug, label))
' "$EMAIL" "$LABEL" "$WS")

out=$(kubectl --request-timeout=60s -n plane exec deploy/plane-api-wl -c plane-api -- \
  python manage.py shell -c "$py" 2>/dev/null) || die "the Django shell in plane-api failed"
case $out in *"ERR no-admin"*) die "no Plane user $EMAIL: run homelab/platform/plane-setup.sh admin first" ;; esac
tok=$(printf '%s\n' "$out" | sed -n 's/^TOKEN //p' | tail -1)
state=$(printf '%s\n' "$out" | sed -n 's/^STATE //p' | tail -1)
unset out
[[ $tok == plane_api_* ]] || die "no token came back (nothing written)"
works "$tok" || die "Plane does not accept the token it returned (nothing written)"

mkdir -p "$(dirname "$CONF")"; chmod 700 "$(dirname "$CONF")"
tmp="$CONF.tmp.$$"
{
  echo "# Plane API access for playground/tracker (sync.sh and the play hook)."
  echo "# Written by playground/tracker/token.sh; mode 600, never in git."
  echo "TRACKER_URL=$URL"
  echo "TRACKER_WORKSPACE=$WS"
  echo "TRACKER_PROJECT=$PJ"
  printf 'TRACKER_TOKEN=%s\n' "$tok"
} > "$tmp"
chmod 600 "$tmp"; mv -f "$tmp" "$CONF"
unset tok
say "token \"$LABEL\" $state (server-side), checked against $URL/api/v1/users/me/ (200), written to $CONF (mode 600, not printed)"
