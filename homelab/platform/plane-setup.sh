#!/usr/bin/env bash
# Plane (the interview tracker, apps/80-plane.yaml): the parts that are not in git.
# Run from the Mac, in this repo.
#
#   homelab/platform/plane-setup.sh check     read-only: Secrets present? pods ready? HTTP codes
#   homelab/platform/plane-setup.sh secrets   create the 5 Secrets in ns plane (random values,
#                                             ONLY those that are absent; never rotates anything)
#   HOMELAB_ADMIN_PASSWORD=... homelab/platform/plane-setup.sh admin
#                                             create/refresh the admin login, workspace, signup off
#   homelab/platform/plane-setup.sh token     a new API token for admin, written straight to
#                                             ~/.config/platform-lab/tracker.env (mode 600)
#
# Order on a fresh cluster: secrets -> (Argo syncs, ~5 min) -> admin -> token -> sync.sh.
#
# admin: Plane logs in by e-mail, so "admin" is admin@homelab.local (PLANE_ADMIN_EMAIL to
# change it). It runs Django's shell in the api pod; the password goes over the exec's
# STDIN, never argv, and is set with Django's set_password (Plane's sign-up form would
# refuse a short password; the shared one is the user's choice, 2026-10-16). Also:
# the instance admin role (god-mode at /god-mode/), instance setup marked done,
# public sign-up switched OFF (the page is on the whole Wi-Fi), the workspace
# "Interview prep" (slug interview-prep) with admin as owner, onboarding skipped.
# Re-run it to change the password.
#
# Secrets (all in namespace plane; the chart's external_secrets.* in values/plane.yaml):
#   plane-pgdb       POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB
#   plane-rabbitmq   RABBITMQ_DEFAULT_USER RABBITMQ_DEFAULT_PASS
#   plane-app-env    SECRET_KEY LIVE_SERVER_SECRET_KEY REDIS_URL DATABASE_URL AMQP_URL
#   plane-live-env   LIVE_SERVER_SECRET_KEY REDIS_URL
#   plane-doc-store  USE_MINIO MINIO_ROOT_USER MINIO_ROOT_PASSWORD AWS_ACCESS_KEY_ID
#                    AWS_SECRET_ACCESS_KEY AWS_S3_ENDPOINT_URL AWS_S3_BUCKET_NAME FILE_SIZE_LIMIT
# SECRET_KEY encrypts Plane's instance-configuration rows: never change it on a running
# instance. Values are generated here and go to kubectl as JSON on stdin; none is printed.
set -euo pipefail
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS=plane
HOST="${PLANE_HOST:-tracker.192.168.0.23.nip.io}"
EMAIL="${PLANE_ADMIN_EMAIL:-admin@homelab.local}"
WS_SLUG=interview-prep
WS_NAME="Interview prep"
CONF="${TRACKER_ENV:-$HOME/.config/platform-lab/tracker.env}"
export KUBECONFIG="${KUBECONFIG:-$HERE/../generated/rke2-lan.kubeconfig}"

die() { echo "plane-setup.sh: $*" >&2; exit 2; }
K() { kubectl --request-timeout=30s -n "$NS" "$@"; }
have() { K get secret "$1" -o name >/dev/null 2>&1; }
secret_value() { K get secret "$1" -o "jsonpath={.data.$2}" 2>/dev/null | base64 -d 2>/dev/null || true; }

cmd_check() {
  local s
  for s in plane-pgdb plane-rabbitmq plane-app-env plane-live-env plane-doc-store; do
    printf '  Secret %-16s %s\n' "$s" "$(have "$s" && echo present || echo ABSENT)"
  done
  K get pods --no-headers 2>/dev/null | awk '{printf "  pod %-40s %s %s\n", $1, $2, $3}' || true
  printf '  http://%s/               -> %s\n' "$HOST" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://$HOST/" || true)"
  printf '  http://%s/api/instances/ -> %s\n' "$HOST" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://$HOST/api/instances/" || true)"
}

# One Secret from environment variables: put_secret NAME KEY=ENVVAR...
put_secret() {
  local name=$1; shift
  python3 -I -c '
import base64, json, os, sys
name, ns = sys.argv[1], sys.argv[2]
data = {}
for kv in sys.argv[3:]:
    k, _, env = kv.partition("=")
    data[k] = base64.b64encode(os.environ[env].encode()).decode()
print(json.dumps({"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
                  "metadata": {"name": name, "namespace": ns,
                               "labels": {"app.kubernetes.io/part-of": "plane"}},
                  "data": data}))' "$name" "$NS" "$@" | K create -f - >/dev/null
  echo "  created $name"
}

cmd_secrets() {
  kubectl get ns "$NS" -o name >/dev/null 2>&1 || kubectl create ns "$NS" >/dev/null
  # Re-use what exists, so a half-created set stays consistent (DATABASE_URL must
  # carry the password PostgreSQL was initialised with).
  P_PG=$(secret_value plane-pgdb POSTGRES_PASSWORD);        P_PG=${P_PG:-$(openssl rand -hex 24)}
  P_MQ=$(secret_value plane-rabbitmq RABBITMQ_DEFAULT_PASS); P_MQ=${P_MQ:-$(openssl rand -hex 24)}
  P_MINIO=$(secret_value plane-doc-store MINIO_ROOT_PASSWORD); P_MINIO=${P_MINIO:-$(openssl rand -hex 24)}
  P_LIVE=$(secret_value plane-live-env LIVE_SERVER_SECRET_KEY)
  [[ -n $P_LIVE ]] || P_LIVE=$(secret_value plane-app-env LIVE_SERVER_SECRET_KEY)
  P_LIVE=${P_LIVE:-$(openssl rand -hex 24)}
  P_KEY=$(secret_value plane-app-env SECRET_KEY);           P_KEY=${P_KEY:-$(openssl rand -hex 32)}
  local svc=svc.cluster.local
  export U_PG=plane DB=plane U_MQ=plane U_MINIO=plane-minio P_PG P_MQ P_MINIO P_LIVE P_KEY
  export REDIS_URL="redis://plane-redis.$NS.$svc:6379/"
  export DATABASE_URL="postgresql://plane:$P_PG@plane-pgdb.$NS.$svc/plane"
  export AMQP_URL="amqp://plane:$P_MQ@plane-rabbitmq.$NS.$svc/"
  export USE_MINIO=1 S3_URL="http://plane-minio:9000" BUCKET=uploads LIMIT=5242880
  have plane-pgdb || put_secret plane-pgdb POSTGRES_USER=U_PG POSTGRES_PASSWORD=P_PG POSTGRES_DB=DB
  have plane-rabbitmq || put_secret plane-rabbitmq RABBITMQ_DEFAULT_USER=U_MQ RABBITMQ_DEFAULT_PASS=P_MQ
  have plane-app-env || put_secret plane-app-env SECRET_KEY=P_KEY LIVE_SERVER_SECRET_KEY=P_LIVE \
    REDIS_URL=REDIS_URL DATABASE_URL=DATABASE_URL AMQP_URL=AMQP_URL
  have plane-live-env || put_secret plane-live-env LIVE_SERVER_SECRET_KEY=P_LIVE REDIS_URL=REDIS_URL
  have plane-doc-store || put_secret plane-doc-store USE_MINIO=USE_MINIO MINIO_ROOT_USER=U_MINIO \
    MINIO_ROOT_PASSWORD=P_MINIO AWS_ACCESS_KEY_ID=U_MINIO AWS_SECRET_ACCESS_KEY=P_MINIO \
    AWS_S3_ENDPOINT_URL=S3_URL AWS_S3_BUCKET_NAME=BUCKET FILE_SIZE_LIMIT=LIMIT
  echo "  Secrets in place (existing ones left untouched)."
}

# Django code run in the api pod. No secret in it: the password is the first line of stdin.
ADMIN_PY='
import sys
from django.utils import timezone
from plane.db.models import User, Profile, Workspace, WorkspaceMember
from plane.license.models import Instance, InstanceAdmin, InstanceConfiguration
email, slug, wsname = @@EMAIL@@, @@SLUG@@, @@WSNAME@@
pw = sys.stdin.readline().rstrip("\n")
assert pw, "empty password on stdin"
u = User.objects.filter(email=email).first()
created = u is None
if created:
    u = User(email=email, username="admin")
u.display_name = "admin"; u.first_name = "Admin"
u.is_active = True; u.is_password_autoset = False
if hasattr(u, "is_email_verified"): u.is_email_verified = True
u.set_password(pw); u.save()
inst = Instance.objects.first()
assert inst, "no Instance row yet: is the api pod past register_instance?"
InstanceAdmin.objects.get_or_create(user=u, instance=inst, defaults={"role": 20})
for f in ("is_setup_done", "is_signup_screen_visited"):
    if hasattr(inst, f): setattr(inst, f, True)
inst.save()
for key, val in (("ENABLE_SIGNUP", "0"), ("ENABLE_EMAIL_PASSWORD", "1")):
    c, _ = InstanceConfiguration.objects.get_or_create(key=key, defaults={"category": "AUTHENTICATION"})
    c.value = val; c.save()
ws = Workspace.objects.filter(slug=slug).first()
if ws is None:
    ws = Workspace.objects.create(name=wsname, slug=slug, owner=u)
WorkspaceMember.objects.get_or_create(workspace=ws, member=u, defaults={"role": 20})
p, _ = Profile.objects.get_or_create(user=u)
if hasattr(p, "is_onboarded"): p.is_onboarded = True
if hasattr(p, "is_tour_completed"): p.is_tour_completed = True
if hasattr(p, "onboarding_step"):
    p.onboarding_step = {"profile_complete": True, "workspace_create": True, "workspace_invite": True, "workspace_join": True}
if hasattr(p, "last_workspace_id"): p.last_workspace_id = ws.id
p.save()
print("admin %s, instance admin, setup done, signup off, workspace %s" % ("created" if created else "updated", slug))
'

py_with_args() {   # inline the non-secret arguments as Python literals
  python3 -I -c 'import sys,json; s=sys.stdin.read(); print(s.replace("@@EMAIL@@", json.dumps(sys.argv[1])).replace("@@SLUG@@", json.dumps(sys.argv[2])).replace("@@WSNAME@@", json.dumps(sys.argv[3])))' \
    "$EMAIL" "$WS_SLUG" "$WS_NAME"
}

cmd_admin() {
  [[ -n ${HOMELAB_ADMIN_PASSWORD:-} ]] || die "set HOMELAB_ADMIN_PASSWORD (never printed, never stored in git)"
  case "$HOMELAB_ADMIN_PASSWORD" in *$'\n'*) die "the password must not contain a newline" ;; esac
  K rollout status deploy/plane-api-wl --timeout=600s >/dev/null || die "deploy/plane-api-wl is not ready"
  local code; code=$(printf '%s' "$ADMIN_PY" | py_with_args)
  printf '%s\n' "$HOMELAB_ADMIN_PASSWORD" | K exec -i deploy/plane-api-wl -c plane-api -- python manage.py shell -c "$code" 2>&1 \
    | grep -v -i 'warning\|^$' | tail -3
  # Proof, without printing anything secret: sign in over the front door.
  local jar; jar=$(mktemp -d); trap 'rm -rf "$jar"' RETURN
  curl -s --max-time 15 -c "$jar/c" -o "$jar/csrf" "http://$HOST/auth/get-csrf-token/"
  local csrf; csrf=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["csrf_token"])' "$jar/csrf")
  # The form body comes from the environment through python, not argv.
  python3 -I -c 'import os,sys,urllib.parse as u; sys.stdout.write(u.urlencode({"csrfmiddlewaretoken":sys.argv[1],"email":sys.argv[2],"password":os.environ["HOMELAB_ADMIN_PASSWORD"]}))' \
    "$csrf" "$EMAIL" > "$jar/body"
  local loc; loc=$(curl -s --max-time 15 -b "$jar/c" -c "$jar/c" -o /dev/null -w '%{http_code} %{redirect_url}' \
    -H "Referer: http://$HOST/" -H "Origin: http://$HOST" --data-binary "@$jar/body" "http://$HOST/auth/sign-in/")
  local me; me=$(curl -s --max-time 15 -b "$jar/c" -o /dev/null -w '%{http_code}' "http://$HOST/api/users/me/")
  echo "  sign-in over http://$HOST: POST /auth/sign-in/ -> ${loc%% *} (redirect ${loc#* }), GET /api/users/me/ -> $me"
  [[ $me == 200 ]] || die "login check failed"
}

TOKEN_PY='
import secrets
from plane.db.models import User, APIToken, Workspace
u = User.objects.get(email=@@EMAIL@@)
ws = Workspace.objects.filter(slug=@@SLUG@@).first()
t = APIToken.objects.create(user=u, label="playground-tracker", description="playground/tracker (sync.sh, play hook)", workspace=ws, user_type=0)
print(t.token)
'

cmd_token() {
  mkdir -p "$(dirname "$CONF")"; chmod 700 "$(dirname "$CONF")"
  local code; code=$(printf '%s' "$TOKEN_PY" | py_with_args)
  local tok
  tok=$(K exec deploy/plane-api-wl -c plane-api -- python manage.py shell -c "$code" 2>/dev/null | tail -1)
  [[ $tok == plane_api_* ]] || die "token creation failed (nothing written)"
  {
    echo "# Plane API access for playground/tracker (sync.sh and the play hook). Mode 600, never in git."
    echo "TRACKER_URL=http://$HOST"
    echo "TRACKER_WORKSPACE=$WS_SLUG"
    echo "TRACKER_PROJECT=PREP"
    printf 'TRACKER_TOKEN=%s\n' "$tok"
  } > "$CONF"
  chmod 600 "$CONF"
  echo "  token written to $CONF (mode 600; not printed). Check: playground/tracker/sync.sh --check"
}

for t in kubectl python3 curl openssl base64; do command -v "$t" >/dev/null || die "$t not found"; done
case "${1:-check}" in
  check) cmd_check ;;
  secrets) cmd_secrets ;;
  admin) cmd_admin ;;
  token) cmd_token ;;
  *) sed -n '2,13p' "$0"; exit 2 ;;
esac
