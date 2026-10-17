#!/usr/bin/env bash
# Set ONE admin password everywhere in the home-lab platform: the Secrets the
# charts read, and the tools that keep the password somewhere else (Grafana's and
# Artifactory's databases, Argo CD's argocd-secret). Run it from the Mac.
#
#   homelab/platform/secrets.sh                 --check: read-only report (default)
#   homelab/platform/secrets.sh --check
#   HOMELAB_ADMIN_PASSWORD='...' homelab/platform/secrets.sh --apply
#   homelab/platform/secrets.sh --selftest      local only: no cluster, dummy password
#
# User is `admin` everywhere (Argo CD, Grafana, Jenkins, Artifactory). Backstage has
# no login (guest sign-in).
#
# --check   changes nothing and never reads a secret VALUE: for each tool it lists
#           the Secret/account it would set, whether that Secret exists, whether the
#           workload is running, and the HTTP code of its API through the ingress.
# --apply   needs HOMELAB_ADMIN_PASSWORD (refuses without it; warns under 12 characters).
#           Re-runnable: a tool that already accepts the password is left alone.
#   Grafana      Secret observability/grafana-admin (admin-user, admin-password).
#                The password is in Grafana's database after its first start, so it is
#                changed there first (REST with the OLD password from the Secret; if
#                that fails, `grafana cli admin reset-admin-password` in the pod), then
#                the Secret is updated and Grafana restarted.
#   Jenkins      Secret jenkins/jenkins-admin (jenkins-admin-user, jenkins-admin-password),
#                the one values/jenkins.yaml names in controller.admin.existingSecret
#                (already so: nothing to sync in Argo). JCasC builds the admin user from
#                it at start-up, so the StatefulSet is restarted.
#   Argo CD      argocd-secret admin.password = bcrypt hash (htpasswd -B, cost 10, $2a$)
#                and admin.passwordMtime; argocd-server restarted; the now-stale
#                argocd-initial-admin-secret is deleted.
#   Artifactory  Secret artifactory/artifactory-admin: key bootstrap.creds
#                (`admin@*=<password>`, what values/artifactory.yaml's dataKey reads, applied
#                by Access at every pod start) and key password. If Artifactory answers, the
#                password is also changed over REST (current one from the Secret). If it
#                does not answer (crash-looping), only the Secret is set and this is said:
#                the next successful start bootstraps `admin` with it.
#                artifactory-keys (master/join key) and artifactory-postgresql are created
#                with random values ONLY if absent and never rotated.
#   Then every login is verified over the LAN through the ingress and only HTTP codes
#   are printed (Jenkins also says whether /whoAmI reports `admin` authenticated).
#
# The password: read from the environment only. Never an argument, never echoed, no
# `set -x`. It reaches curl through a mode-600 config file and kubectl through a
# mode-600 JSON file in a private temp dir (removed on exit), so it is not in `ps`
# output. The one place it ends up is where it has to: the Secrets in the cluster.
#
# Kubernetes access, first match wins:
#   $KUBECONFIG                          as you set it
#   homelab/generated/rke2-lan.kubeconfig  over the LAN, no tunnel (homelab/mac/lan-kube-api.sh)
#   homelab/generated/rke2.kubeconfig      needs `homelab/mac/kube-tunnel.sh` running
# A candidate that does not answer is skipped for the next one.
#
# HOMELAB_INGRESS_IP    where the ingress answers   (default: 192.168.0.23, the PC's LAN address)
# HOMELAB_INGRESS_PORT  its HTTPS port              (default: 443; 8443 with the ssh tunnel
#                       in homelab/platform/README.md and HOMELAB_INGRESS_IP=127.0.0.1)
# HOMELAB_WAIT          seconds to wait for each login to work after a restart (default: 180)
#
# Pick a password you would be happy to see guessed: the ingress answers on the home
# LAN, and Argo CD / Jenkins admin are cluster-admin-grade in practice.
# shellcheck disable=SC2089,SC2090  # the selftest's dummy password has quotes on purpose
set -euo pipefail
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$(cd "$HERE/.." && pwd)/generated"
IP="${HOMELAB_INGRESS_IP:-192.168.0.23}"
PORT="${HOMELAB_INGRESS_PORT:-443}"
WAIT="${HOMELAB_WAIT:-180}"
HOST_GRAFANA=grafana.127.0.0.1.nip.io
HOST_JENKINS=jenkins.127.0.0.1.nip.io
HOST_ARGOCD=argocd.127.0.0.1.nip.io
HOST_ARTIFACTORY=artifactory.127.0.0.1.nip.io

die() { echo "secrets.sh: $*" >&2; exit 2; }
say() { printf '\n== %s\n' "$*"; }
usage() { sed -n '6,9p' "${BASH_SOURCE[0]}" >&2; exit 2; }

MODE=check
case "${1:-}" in
  ""|--check) MODE=check ;;
  --apply) MODE=apply ;;
  --selftest) MODE=selftest ;;
  -h|--help) usage ;;
  *) echo "secrets.sh: unknown argument '$1'" >&2; usage ;;
esac
[[ $# -le 1 ]] || usage

# --- private temp dir (mode 700), removed on exit -----------------------------------
T="$(mktemp -d "${TMPDIR:-/tmp}/homelab-secrets.XXXXXX")"
chmod 700 "$T"
trap 'rm -rf "$T"' EXIT

# --- helpers that never put the password in argv -------------------------------------
# bcrypt hash of $HOMELAB_ADMIN_PASSWORD for argocd-secret. htpasswd -i reads the
# password from stdin; Argo CD wants $2a$ (htpasswd prints $2y$).
bcrypt_of_pw() {
  printf '%s' "$HOMELAB_ADMIN_PASSWORD" | htpasswd -niBC 10 '' | tr -d ':\n' | sed 's/^\$2y/$2a/'
}

# curl config file with the credentials (read with -K, so not in ps). In a curl
# config file a quoted value treats \ and " specially.
write_auth() {   # $1 = file, $2 = user, $3 = password
  local p=$3
  p=${p//\\/\\\\}
  p=${p//\"/\\\"}
  printf 'user = "%s:%s"\n' "$2" "$p" >"$1"
}

# JSON bodies, built from environment variables by python (the values are never in argv).
json_login() {   # {"username":"admin","password":$HOMELAB_ADMIN_PASSWORD}
  python3 -I -c 'import json,os;print(json.dumps({"username":"admin","password":os.environ["HOMELAB_ADMIN_PASSWORD"]}))'
}
json_grafana_chpw() {   # needs HL_OLD
  python3 -I -c 'import json,os;n=os.environ["HOMELAB_ADMIN_PASSWORD"];print(json.dumps({"oldPassword":os.environ["HL_OLD"],"newPassword":n,"confirmNew":n}))'
}
json_artifactory_chpw() {   # needs HL_OLD
  python3 -I -c 'import json,os;n=os.environ["HOMELAB_ADMIN_PASSWORD"];print(json.dumps({"userName":"admin","oldPassword":os.environ["HL_OLD"],"newPassword1":n,"newPassword2":n}))'
}
# A Secret (create) or a merge patch (patch) whose values come from environment
# variables named on the command line: key=ENV or key=ENV+prefix.
secret_json() {   # $1 create|patch, $2 namespace, $3 name, then key=ENV[+prefix]...
  python3 -I -c '
import base64, json, os, sys
mode, ns, name = sys.argv[1:4]
data = {}
for kv in sys.argv[4:]:
    key, _, spec = kv.partition("=")
    env, _, prefix = spec.partition("+")
    data[key] = base64.b64encode((prefix + os.environ[env]).encode()).decode()
if mode == "patch":
    print(json.dumps({"data": data}))
else:
    print(json.dumps({"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
                      "metadata": {"name": name, "namespace": ns}, "data": data}))
' "$@"
}

# --- selftest: everything that needs neither the cluster nor the ingress -------------
if [[ $MODE == selftest ]]; then
  for tool in python3 htpasswd curl; do command -v "$tool" >/dev/null || die "$tool not found"; done
  export HOMELAB_ADMIN_PASSWORD='Dummy "pw" with \ and $x 1'
  fail=0
  h="$(bcrypt_of_pw)"
  [[ $h == '$2a$10$'* && ${#h} -eq 60 ]] || { echo "selftest: bcrypt hash has the wrong shape"; fail=1; }
  printf 'u:%s\n' "$h" | sed 's/^\(u:\$2\)a/\1y/' >"$T/ht"
  htpasswd -vb "$T/ht" u "$HOMELAB_ADMIN_PASSWORD" >/dev/null 2>&1 || { echo "selftest: hash does not verify"; fail=1; }
  if htpasswd -vb "$T/ht" u "wrong" >/dev/null 2>&1; then echo "selftest: a wrong password verified"; fail=1; fi
  write_auth "$T/auth" admin "$HOMELAB_ADMIN_PASSWORD"
  [[ "$(stat -f %Lp "$T/auth" 2>/dev/null || stat -c %a "$T/auth")" == 600 ]] || { echo "selftest: auth file is not mode 600"; fail=1; }
  json_login | python3 -I -c 'import json,os,sys;d=json.load(sys.stdin);sys.exit(0 if d=={"username":"admin","password":os.environ["HOMELAB_ADMIN_PASSWORD"]} else 1)' \
    || { echo "selftest: login JSON does not round-trip"; fail=1; }
  # shellcheck disable=SC2209
  HL_USER=admin secret_json create ns n admin-user=HL_USER 'bootstrap.creds=HOMELAB_ADMIN_PASSWORD+admin@*=' \
    | python3 -I -c 'import base64,json,os,sys;d=json.load(sys.stdin)["data"];sys.exit(0 if base64.b64decode(d["bootstrap.creds"]).decode()=="admin@*="+os.environ["HOMELAB_ADMIN_PASSWORD"] and base64.b64decode(d["admin-user"])==b"admin" else 1)' \
    || { echo "selftest: Secret JSON does not round-trip"; fail=1; }
  # \ and " are escaped for curl's config-file syntax; $ is not special there.
  [[ "$(cat "$T/auth")" == 'user = "admin:Dummy \"pw\" with \\ and $x 1"' ]] || { echo "selftest: curl config escaping is off"; fail=1; }
  [[ $fail -eq 0 ]] && echo "selftest: ok (bcrypt, htpasswd verify, auth file mode 600 and escaping, JSON round-trips; nothing contacted)"
  exit "$fail"
fi

# --- password: needed by --apply; --check only reports whether it is set --------------
PW_SET=no
if [[ -n ${HOMELAB_ADMIN_PASSWORD:-} ]]; then PW_SET=yes; fi
if [[ $MODE == apply ]]; then
  [[ $PW_SET == yes ]] || die "set HOMELAB_ADMIN_PASSWORD (it is never printed or stored in git). Example:
    HOMELAB_ADMIN_PASSWORD='...' homelab/platform/secrets.sh --apply"
  case "$HOMELAB_ADMIN_PASSWORD" in *$'\n'*|*$'\r'*) die "the password must not contain a newline" ;; esac
  # The user's choice wins (2026-10-16: a short shared password, accepted with
  # the LAN exposure). Warn, don't refuse; a tool that enforces its own minimum
  # (Artifactory may) fails on its own line below with its own message.
  [[ ${#HOMELAB_ADMIN_PASSWORD} -ge 12 ]] || echo "secrets.sh: WARNING: ${#HOMELAB_ADMIN_PASSWORD} characters; anyone on the Wi-Fi who guesses it is admin on every tool." >&2
  export HOMELAB_ADMIN_PASSWORD
fi

for tool in kubectl python3 curl; do command -v "$tool" >/dev/null || die "$tool not found"; done
if [[ $MODE == apply ]]; then
  for tool in htpasswd openssl base64; do command -v "$tool" >/dev/null || die "$tool not found (htpasswd ships with macOS in /usr/sbin)"; done
fi

# --- which kubeconfig ---------------------------------------------------------------------
KC=""
KC_HOW=""
try_kc() {   # $1 = path (or KUBECONFIG list), $2 = description
  if KUBECONFIG="$1" kubectl --request-timeout=10s get ns kube-system -o name >/dev/null 2>&1; then
    KC=$1; KC_HOW=$2; return 0
  fi
  echo "  kubeconfig not usable: $2" >&2
  return 1
}
if [[ -n ${KUBECONFIG:-} ]]; then
  try_kc "$KUBECONFIG" "\$KUBECONFIG" || true
fi
if [[ -z $KC && -f $GEN/rke2-lan.kubeconfig ]]; then
  try_kc "$GEN/rke2-lan.kubeconfig" "LAN kubeconfig, no tunnel" || true
fi
if [[ -z $KC && -f $GEN/rke2.kubeconfig ]]; then
  try_kc "$GEN/rke2.kubeconfig" "tunnel kubeconfig (is homelab/mac/kube-tunnel.sh running?)" || true
fi
[[ -n $KC ]] || die "no kubeconfig reaches the cluster. Either run homelab/mac/lan-kube-api.sh once (then no tunnel is needed) or start homelab/mac/kube-tunnel.sh in another terminal."
export KUBECONFIG="$KC"
K() { kubectl --request-timeout=30s "$@"; }

secret_exists() { K -n "$1" get secret "$2" -o name >/dev/null 2>&1; }
workload_ready() {   # $1 ns, $2 kind/name -> "ready/desired" or "absent"
  local r d
  if ! K -n "$1" get "$2" -o name >/dev/null 2>&1; then echo absent; return; fi
  r=$(K -n "$1" get "$2" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
  d=$(K -n "$1" get "$2" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
  echo "${r:-0}/${d:-?}"
}

# --- HTTPS through the ingress, Host routing via --resolve ------------------------------
CODE=000
req() {   # $1 host, $2 method, $3 path, [$4 curl -K auth file], [$5 JSON body file]; sets CODE, body in $T/body
  local host=$1 method=$2 path=$3 auth=${4:-} data=${5:-}
  local a=(-sk --max-time 30 -o "$T/body" -w '%{http_code}' --resolve "$host:$PORT:$IP" -X "$method")
  [[ -z $auth ]] || a+=(-K "$auth")
  [[ -z $data ]] || a+=(-H 'Content-Type: application/json' --data-binary "@$data")
  CODE=$(curl "${a[@]}" "https://$host:$PORT$path" 2>/dev/null) || true
  CODE=${CODE:-000}
}
api_up() {   # $1 host, $2 path: 200 without credentials?
  req "$1" GET "$2"; [[ $CODE == 200 ]]
}

# =========================================================================================
# --check
# =========================================================================================
if [[ $MODE == check ]]; then
  echo "secrets.sh --check: read-only. Nothing is changed and no secret value is read."
  echo "kubernetes : $KC_HOW"
  echo "ingress    : https://<host>:$PORT via $IP"
  echo "password   : HOMELAB_ADMIN_PASSWORD set: $PW_SET$([[ $PW_SET == yes ]] || echo ' (--apply will refuse without it)')"
  row() {   # label, ns, secret, workload, host, path, what --apply sets
    local s w c
    if secret_exists "$2" "$3"; then s="exists"; else s="ABSENT (--apply creates it)"; fi
    w=$(workload_ready "$2" "$4")
    req "$5" GET "$6"; c=$CODE
    printf '\n%s\n  Secret    %s/%s: %s\n  workload  %s: %s\n  API       %s%s -> HTTP %s%s\n  --apply   %s\n' \
      "$1" "$2" "$3" "$s" "$4" "$w" "$5" "$6" "$c" "$([[ $c == 200 ]] || echo ' (not answering)')" "$7"
  }
  row Grafana observability grafana-admin deploy/kube-prometheus-stack-grafana "$HOST_GRAFANA" /api/health \
    "REST password change in Grafana's database (old one from the Secret), update the Secret, restart Grafana"
  row Jenkins jenkins jenkins-admin sts/jenkins "$HOST_JENKINS" /login \
    "update the Secret, restart the StatefulSet (JCasC rebuilds the admin user)"
  row "Artifactory" artifactory artifactory-admin sts/artifactory "$HOST_ARTIFACTORY" /artifactory/api/system/ping \
    "REST password change if it answers; always set the Secret (bootstrap.creds + password)"
  s=$(secret_exists argocd argocd-secret && echo exists || echo ABSENT)
  w=$(workload_ready argocd deploy/argocd-server)
  req "$HOST_ARGOCD" GET /api/version
  printf '\nArgo CD\n  Secret    argocd/argocd-secret: %s (admin.password, admin.passwordMtime; initial-admin-secret: %s)\n  workload  deploy/argocd-server: %s\n  API       %s/api/version -> HTTP %s\n  --apply   bcrypt hash into argocd-secret, restart argocd-server, delete argocd-initial-admin-secret\n' \
    "$s" "$(secret_exists argocd argocd-initial-admin-secret && echo present || echo absent)" "$w" "$HOST_ARGOCD" "$CODE"
  printf '\nArtifactory also: artifactory-keys %s, artifactory-postgresql %s (created with random values only if absent, never rotated)\n' \
    "$(secret_exists artifactory artifactory-keys && echo exists || echo ABSENT)" "$(secret_exists artifactory artifactory-postgresql && echo exists || echo ABSENT)"
  echo
  echo "To change the password everywhere:  HOMELAB_ADMIN_PASSWORD='...' homelab/platform/secrets.sh --apply"
  exit 0
fi

# =========================================================================================
# --apply
# =========================================================================================
FAILED=0
fail() { echo "  FAILED: $*" >&2; FAILED=$((FAILED + 1)); }

write_auth "$T/auth-new" admin "$HOMELAB_ADMIN_PASSWORD"
echo "secrets.sh --apply  (kubernetes: $KC_HOW; ingress https://<host>:$PORT via $IP)"

# Create or merge-patch a Secret. A merge patch (not `kubectl apply`) so that no
# last-applied-configuration annotation copies the password into the object.
put_secret() {   # ns name key=ENV[+prefix]...
  local ns=$1 name=$2
  shift 2
  if secret_exists "$ns" "$name"; then
    secret_json patch "$ns" "$name" "$@" >"$T/secret.json"
    K -n "$ns" patch secret "$name" --type merge --patch-file "$T/secret.json" >/dev/null
  else
    secret_json create "$ns" "$name" "$@" >"$T/secret.json"
    K create -f "$T/secret.json" >/dev/null
  fi
  rm -f "$T/secret.json"
}
secret_value() {   # ns name key (no dots in key) -> value on stdout, empty if absent
  K -n "$1" get secret "$2" -o "jsonpath={.data.$3}" 2>/dev/null | base64 -d 2>/dev/null || true
}
restart_and_wait() {   # ns kind/name
  K -n "$1" rollout restart "$2" >/dev/null
  K -n "$1" rollout status "$2" --timeout=600s >/dev/null 2>&1 || echo "  note: $2 not ready after 600 s; the login check below says whether it matters"
}

export HL_USER=admin
for ns in jenkins observability artifactory argocd; do
  K get ns "$ns" -o name >/dev/null 2>&1 || K create ns "$ns" >/dev/null
done

# --- Grafana ------------------------------------------------------------------------------
say "Grafana"
grafana_ok=no
if api_up "$HOST_GRAFANA" /api/health; then
  req "$HOST_GRAFANA" GET /api/user "$T/auth-new"
  if [[ $CODE == 200 ]]; then
    echo "  already accepts the password"; grafana_ok=yes
  else
    old="$(secret_value observability grafana-admin admin-password)"
    if [[ -n $old && $old != "$HOMELAB_ADMIN_PASSWORD" ]]; then
      write_auth "$T/auth-old" admin "$old"
      HL_OLD="$old" json_grafana_chpw >"$T/body-in"
      req "$HOST_GRAFANA" PUT /api/user/password "$T/auth-old" "$T/body-in"
      echo "  REST password change (old password from the Secret): HTTP $CODE"
      [[ $CODE == 200 ]] && grafana_ok=yes
      rm -f "$T/auth-old" "$T/body-in"
    fi
    if [[ $grafana_ok == no ]]; then
      echo "  trying grafana cli admin reset-admin-password in the pod"
      if printf '%s' "$HOMELAB_ADMIN_PASSWORD" | K -n observability exec -i deploy/kube-prometheus-stack-grafana -c grafana -- \
           grafana cli admin reset-admin-password --password-from-stdin >/dev/null 2>&1; then
        grafana_ok=yes
      fi
    fi
  fi
else
  echo "  Grafana is not answering (HTTP $CODE): only the Secret is set; its first start uses it"
  grafana_ok=yes
fi
if [[ $grafana_ok == yes ]]; then
  put_secret observability grafana-admin admin-user=HL_USER admin-password=HOMELAB_ADMIN_PASSWORD
  echo "  Secret observability/grafana-admin set"
  if K -n observability get deploy kube-prometheus-stack-grafana -o name >/dev/null 2>&1; then
    restart_and_wait observability deploy/kube-prometheus-stack-grafana
    echo "  Grafana restarted"
  fi
else
  fail "Grafana: could not change the password (Secret left as it was). Reset it by hand: kubectl -n observability exec -it deploy/kube-prometheus-stack-grafana -c grafana -- grafana cli admin reset-admin-password"
fi

# --- Jenkins ------------------------------------------------------------------------------
say "Jenkins"
put_secret jenkins jenkins-admin jenkins-admin-user=HL_USER jenkins-admin-password=HOMELAB_ADMIN_PASSWORD
echo "  Secret jenkins/jenkins-admin set (values/jenkins.yaml already reads it: controller.admin.existingSecret)"
if K -n jenkins get sts jenkins -o name >/dev/null 2>&1; then
  restart_and_wait jenkins sts/jenkins
  echo "  StatefulSet restarted (JCasC builds the admin user from the Secret)"
else
  echo "  no StatefulSet yet: Argo CD's first sync starts Jenkins with this Secret"
fi

# --- Argo CD -------------------------------------------------------------------------------
say "Argo CD"
if secret_exists argocd argocd-secret; then
  HL_BCRYPT="$(bcrypt_of_pw)"
  HL_MTIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  export HL_BCRYPT HL_MTIME
  put_secret argocd argocd-secret admin.password=HL_BCRYPT admin.passwordMtime=HL_MTIME
  unset HL_BCRYPT
  K -n argocd delete secret argocd-initial-admin-secret --ignore-not-found >/dev/null
  restart_and_wait argocd deploy/argocd-server
  echo "  argocd-secret admin.password (bcrypt) set, argocd-server restarted, argocd-initial-admin-secret deleted"
else
  fail "Argo CD: secret argocd/argocd-secret does not exist (Argo CD is not installed; see homelab/argocd/README.md)"
fi

# --- Artifactory -----------------------------------------------------------------------------
say "Artifactory"
if ! secret_exists artifactory artifactory-keys; then
  HL_MASTER_KEY="$(openssl rand -hex 32)" HL_JOIN_KEY="$(openssl rand -hex 32)" \
    put_secret artifactory artifactory-keys master-key=HL_MASTER_KEY join-key=HL_JOIN_KEY
  echo "  created artifactory-keys (random; back it up: losing it makes Artifactory's data unreadable)"
fi
if ! secret_exists artifactory artifactory-postgresql; then
  HL_PG_PASSWORD="$(openssl rand -hex 16)" HL_PG_POSTGRES="$(openssl rand -hex 16)" \
    put_secret artifactory artifactory-postgresql password=HL_PG_PASSWORD postgres-password=HL_PG_POSTGRES
  echo "  created artifactory-postgresql (random)"
fi
art_ok=yes
ART_UP=no
if api_up "$HOST_ARTIFACTORY" /artifactory/api/system/ping; then
  ART_UP=yes
  req "$HOST_ARTIFACTORY" GET /artifactory/api/system/version "$T/auth-new"
  if [[ $CODE == 200 ]]; then
    echo "  already accepts the password"
  else
    old="$(secret_value artifactory artifactory-admin password)"
    art_ok=no
    if [[ -n $old && $old != "$HOMELAB_ADMIN_PASSWORD" ]]; then
      write_auth "$T/auth-old" admin "$old"
      HL_OLD="$old" json_artifactory_chpw >"$T/body-in"
      req "$HOST_ARTIFACTORY" POST /artifactory/api/security/users/authorization/changePassword "$T/auth-old" "$T/body-in"
      echo "  REST password change (current password from the Secret): HTTP $CODE"
      [[ $CODE == 200 ]] && art_ok=yes
      rm -f "$T/auth-old" "$T/body-in"
    else
      echo "  no usable current password in the Secret to authenticate the REST change"
    fi
  fi
else
  echo "  Artifactory is not answering (ping HTTP $CODE; it may be crash-looping): skipped the REST change."
  echo "  The Secret is set below, so the next successful start bootstraps admin with it."
fi
# bootstrap.creds is what the chart mounts (dataKey), `password` is the plain value other tooling reads.
put_secret artifactory artifactory-admin password=HOMELAB_ADMIN_PASSWORD 'bootstrap.creds=HOMELAB_ADMIN_PASSWORD+admin@*='
echo "  Secret artifactory/artifactory-admin set (bootstrap.creds + password)"
if [[ $art_ok == no ]]; then
  fail "Artifactory: REST password change failed. The Secret now holds the new password; 'kubectl -n artifactory rollout restart sts/artifactory' makes Access apply it from bootstrap.creds (slow: ~10 min)"
fi

# --- verify every login over the ingress; codes only -------------------------------------------
say "Verify logins (https://<host>:$PORT via $IP; HTTP codes only; up to ${WAIT}s each)"
json_login >"$T/login.json"
verify() {   # label host method path [json body file]
  local label=$1 host=$2 method=$3 path=$4 body=${5:-} waited=0 extra=""
  while :; do
    req "$host" "$method" "$path" "$T/auth-new" "$body"
    [[ $CODE == 200 ]] && break
    [[ $waited -ge $WAIT ]] && break
    sleep 5; waited=$((waited + 5))
  done
  if [[ $label == jenkins ]]; then
    if grep -Eq '"authenticated" *: *true' "$T/body" 2>/dev/null && grep -Eq '"name" *: *"admin"' "$T/body" 2>/dev/null; then
      extra="  (whoAmI: authenticated as admin)"
    else
      extra="  (whoAmI: NOT authenticated as admin)"; [[ $CODE != 200 ]] || CODE="200-but-anonymous"
    fi
  fi
  printf '  %-12s %s %s -> %s%s\n' "$label" "$method" "$path" "$CODE" "$extra"
  [[ $CODE == 200 ]] || fail "$label login check returned $CODE"
}
verify grafana "$HOST_GRAFANA" GET /api/user
verify jenkins "$HOST_JENKINS" GET /whoAmI/api/json
# Argo CD: POST /api/v1/session returns a token in the body; the body is discarded.
verify argocd "$HOST_ARGOCD" POST /api/v1/session "$T/login.json"
if [[ $ART_UP == yes && $art_ok == yes ]]; then
  api_up "$HOST_ARTIFACTORY" /artifactory/api/system/ping && printf '  %-12s GET /artifactory/api/system/ping -> %s\n' artifactory "$CODE"
  verify artifactory "$HOST_ARTIFACTORY" GET /artifactory/api/system/version
else
  printf '  %-12s skipped (not answering or password change failed; see above)\n' artifactory
fi

echo
if [[ $FAILED -eq 0 ]]; then
  echo "secrets.sh: done. Login: admin / the password you set, in all four tools."
else
  echo "secrets.sh: finished with $FAILED problem(s) listed above." >&2
  exit 1
fi
