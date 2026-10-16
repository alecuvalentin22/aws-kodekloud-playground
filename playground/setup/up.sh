#!/usr/bin/env bash
# Build the local playground: kind + a registry + Gitea + the lab's Jenkins.
# No cloud account. Idempotent: re-run it any time; it skips what exists.
#
#   playground/setup/up.sh
#
# ~10 minutes the first time (images, Jenkins plugins, first build), ~1 after.
#
# Choosing the logins: the passwords are generated unless you export
# PLAYGROUND_ADMIN_PASSWORD, which then becomes BOTH the Jenkins and the Gitea
# password (users: admin / admin). It is read from the environment, written
# only to $STATE/creds.env (mode 600, outside git) and never printed. It is
# consulted when creds.env is first generated, or when you change an existing
# playground with:
#
#   PLAYGROUND_ADMIN_PASSWORD=... playground/setup/up.sh --set-password
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
SET_PASSWORD=0
case "${1:-}" in
  "") ;;
  --set-password) SET_PASSWORD=1 ;;
  *) die "usage: up.sh [--set-password]   (reads PLAYGROUND_ADMIN_PASSWORD)" ;;
esac
(( SET_PASSWORD == 0 )) || [[ -n "${PLAYGROUND_ADMIN_PASSWORD:-}" ]] \
  || die "--set-password needs PLAYGROUND_ADMIN_PASSWORD in the environment"
mkdir -p "$STATE/bin" "$STATE/scratch" "$STATE/logs" "$WORK"
chmod 700 "$STATE"

c_hdr "0/7 preflight"
docker info >/dev/null 2>&1 || die "Docker is not running"
for t in kubectl helm git jq curl; do command -v $t >/dev/null || die "$t not on PATH"; done
mem_gb=$(( $(docker info --format '{{.MemTotal}}') / 1024 / 1024 / 1024 ))
if (( mem_gb < 6 )); then
  c_warn "Docker has ${mem_gb} GB. It fits, but only just: raise it to 6-8 GB in"
  c_warn "Docker Desktop -> Settings -> Resources if builds get OOMKilled."
fi

c_hdr "1/7 kind $KIND_VERSION"
if [[ "$(kind version 2>/dev/null | awk '{print $2}')" != "$KIND_VERSION" ]]; then
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m); [[ $arch == x86_64 ]] && arch=amd64; [[ $arch == aarch64 ]] && arch=arm64
  base="https://github.com/kubernetes-sigs/kind/releases/download/$KIND_VERSION/kind-$os-$arch"
  curl -fsSL -o "$STATE/bin/kind.tmp" "$base"
  want=$(curl -fsSL "$base.sha256sum" | awk '{print $1}')
  # sha256sum on Linux/WSL (coreutils); shasum on macOS.
  if command -v sha256sum >/dev/null; then got=$(sha256sum "$STATE/bin/kind.tmp" | awk '{print $1}')
  else got=$(shasum -a 256 "$STATE/bin/kind.tmp" | awk '{print $1}'); fi
  [[ $want == "$got" ]] || die "kind checksum mismatch ($got != $want)"
  chmod +x "$STATE/bin/kind.tmp" && mv "$STATE/bin/kind.tmp" "$STATE/bin/kind"
fi
c_ok "$(kind version)"

c_hdr "2/7 registry (the ECR stand-in)"
if [[ "$(docker inspect -f '{{.State.Running}}' kind-registry 2>/dev/null || true)" != true ]]; then
  docker rm -f kind-registry >/dev/null 2>&1 || true
  docker run -d --restart=always -p 127.0.0.1:5001:5000 --name kind-registry "$REGISTRY_IMAGE" >/dev/null
fi
c_ok "kind-registry:5000 in the cluster, localhost:5001 from your laptop"

c_hdr "3/7 kind cluster '$CLUSTER'"
if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  kind create cluster --config "$PG_ROOT/setup/kind.yaml" --image "$KIND_NODE_IMAGE" --wait 120s
fi
# Tell containerd on the node that kind-registry:5000 is plain HTTP. The same
# name works for BuildKit pushing from a pod AND for the kubelet pulling, so
# the image reference in the Deployment is the one the pipeline pushed.
for node in $(kind get nodes --name "$CLUSTER"); do
  docker exec "$node" mkdir -p /etc/containerd/certs.d/kind-registry:5000
  printf '[host."http://kind-registry:5000"]\n' | docker exec -i "$node" cp /dev/stdin /etc/containerd/certs.d/kind-registry:5000/hosts.toml
done
[[ "$(docker inspect -f '{{json .NetworkSettings.Networks.kind}}' kind-registry)" == null ]] \
  && docker network connect kind kind-registry
c_ok "context $CTX"

c_hdr "4/7 credentials (generated once, kept in $STATE/creds.env)"
if [[ ! -f "$STATE/creds.env" ]] || (( SET_PASSWORD )); then
  umask 077
  jp=${PLAYGROUND_ADMIN_PASSWORD:-$(openssl rand -hex 12)}
  gp=${PLAYGROUND_ADMIN_PASSWORD:-$(openssl rand -hex 12)}
  {   # %q so any value survives being sourced back
    printf 'JENKINS_PASSWORD=%q\n' "$jp"
    printf 'GITEA_PASSWORD=%q\n' "$gp"
    echo "GITEA_USER=admin"
  } > "$STATE/creds.env.new"
  mv "$STATE/creds.env.new" "$STATE/creds.env"
  unset jp gp
fi
load_creds
# GNU first: on Linux `stat -f` means --file-system and prints junk, not an error.
c_ok "mode $(stat -c %a "$STATE/creds.env" 2>/dev/null || stat -f %Lp "$STATE/creds.env")"

c_hdr "5/7 Gitea (the GitHub stand-in)"
sed "s|IMAGE_PLACEHOLDER|$GITEA_IMAGE|" "$PG_ROOT/setup/gitea.yaml" | K apply -f - >/dev/null
K -n git rollout status deploy/gitea --timeout=180s >/dev/null
if ! gitea_api GET /user >/dev/null 2>&1; then
  gitea_users=$(K -n git exec deploy/gitea -- gitea admin user list 2>/dev/null | awk 'NR>1 {print $2}' || true)
  if grep -qx "$GITEA_USER" <<<"$gitea_users"; then
    # The login exists but the password in creds.env does not match: a --set-password run.
    K -n git exec deploy/gitea -- gitea admin user change-password --username "$GITEA_USER" \
      --password "$GITEA_PASSWORD" --must-change-password=false >/dev/null
  else
    K -n git exec deploy/gitea -- gitea admin user create --admin --username "$GITEA_USER" \
      --password "$GITEA_PASSWORD" --email "$GITEA_USER@playground.local" --must-change-password=false >/dev/null
  fi
fi
for org in platform payments; do
  gitea_api GET "/orgs/$org" >/dev/null 2>&1 || \
    gitea_api POST /orgs "{\"username\":\"$org\",\"visibility\":\"public\"}" >/dev/null
done
"$PG_ROOT/setup/seed.sh"
c_ok "$GITEA_URL  ($GITEA_USER / see creds.env)"

c_hdr "6/7 Jenkins (same chart + JCasC as EKS, local overlay)"
K create namespace jenkins --dry-run=client -o yaml | K apply -f - >/dev/null
K apply -f "$LAB_ROOT/ci/jenkins/rbac.yaml" >/dev/null
helm repo add jenkins https://charts.jenkins.io >/dev/null 2>&1 || true
helm repo update jenkins >/dev/null
helm upgrade --install jenkins jenkins/jenkins --kube-context "$CTX" -n jenkins \
  --version "$JENKINS_CHART" \
  -f "$LAB_ROOT/ci/jenkins/values.yaml" \
  -f "$PG_ROOT/setup/jenkins-values-local.yaml" \
  --set-string controller.admin.password="$JENKINS_PASSWORD" \
  --wait --timeout 15m >/dev/null
for _ in $(seq 1 60); do jenkins_get /api/json >/dev/null 2>&1 && break; sleep 5; done
c_ok "$JENKINS_URL  (admin / see creds.env)"

c_hdr "7/7 your workspace: $WORK"
cred_file="$STATE/git-credentials"
umask 077; printf 'http://%s:%s@localhost%%3a30300\n' "$GITEA_USER" "$GITEA_PASSWORD" > "$cred_file"
for repo in platform/platform-lib payments/demo-api; do
  d="$WORK/${repo#*/}"
  if [[ ! -d "$d/.git" ]]; then
    git clone -q "http://$GITEA_USER@localhost:30300/$repo.git" "$d" \
      -c credential.helper="store --file=$cred_file"
    git -C "$d" config user.name "You (platform team)"
    git -C "$d" config user.email "you@playground.local"
  else   # a clone from before the login was renamed still points at the old user
    git -C "$d" remote set-url origin "http://$GITEA_USER@localhost:30300/$repo.git"
  fi
  c_ok "$d"
done

c_hdr "baseline build"
jenkins_scan
"$PG_ROOT/play" wait-green 600 || die "first build did not go green -- see $JENKINS_URL/job/demo-api/job/main/lastBuild/console"
cat <<EOF

  Ready.  Next:   playground/play list
                  playground/play start

  Jenkins   $JENKINS_URL        admin
  Gitea     $GITEA_URL        $GITEA_USER
  Passwords: $STATE/creds.env (mode 600), not printed here so logs stay clean.
  Copy one:  grep JENKINS_PASSWORD $STATE/creds.env | cut -d= -f2 | pbcopy   # Linux: xclip -sel clip / wl-copy
  demo-api  http://localhost:30095
  kubectl   --context $CTX
EOF
