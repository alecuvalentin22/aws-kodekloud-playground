#!/usr/bin/env bash
# Build the local playground: kind + a registry + Gitea + the lab's Jenkins.
# No cloud account. Idempotent: re-run it any time; it skips what exists.
#
#   playground/setup/up.sh
#
# ~10 minutes the first time (images, Jenkins plugins, first build), ~1 after.
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
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
if [[ ! -f "$STATE/creds.env" ]]; then
  umask 077
  {
    echo "JENKINS_PASSWORD=$(openssl rand -hex 12)"
    echo "GITEA_PASSWORD=$(openssl rand -hex 12)"
  } > "$STATE/creds.env"
fi
load_creds
# GNU first: on Linux `stat -f` means --file-system and prints junk, not an error.
c_ok "mode $(stat -c %a "$STATE/creds.env" 2>/dev/null || stat -f %Lp "$STATE/creds.env")"

c_hdr "5/7 Gitea (the GitHub stand-in)"
sed "s|IMAGE_PLACEHOLDER|$GITEA_IMAGE|" "$PG_ROOT/setup/gitea.yaml" | K apply -f - >/dev/null
K -n git rollout status deploy/gitea --timeout=180s >/dev/null
if ! gitea_api GET /user >/dev/null 2>&1; then
  K -n git exec deploy/gitea -- gitea admin user create --admin --username dev \
    --password "$GITEA_PASSWORD" --email dev@playground.local --must-change-password=false >/dev/null
fi
for org in platform payments; do
  gitea_api GET "/orgs/$org" >/dev/null 2>&1 || \
    gitea_api POST /orgs "{\"username\":\"$org\",\"visibility\":\"public\"}" >/dev/null
done
"$PG_ROOT/setup/seed.sh"
c_ok "$GITEA_URL  (dev / see creds.env)"

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
umask 077; printf 'http://dev:%s@localhost%%3a30300\n' "$GITEA_PASSWORD" > "$cred_file"
for repo in platform/platform-lib payments/demo-api; do
  d="$WORK/${repo#*/}"
  if [[ ! -d "$d/.git" ]]; then
    git clone -q "http://dev@localhost:30300/$repo.git" "$d" \
      -c credential.helper="store --file=$cred_file"
    git -C "$d" config user.name "You (platform team)"
    git -C "$d" config user.email "you@playground.local"
  fi
  c_ok "$d"
done

c_hdr "baseline build"
jenkins_scan
"$PG_ROOT/play" wait-green 600 || die "first build did not go green -- see $JENKINS_URL/job/demo-api/job/main/lastBuild/console"
cat <<EOF

  Ready.  Next:   playground/play list
                  playground/play start

  Jenkins   $JENKINS_URL        admin / $(grep JENKINS_PASSWORD "$STATE/creds.env" | cut -d= -f2)
  Gitea     $GITEA_URL        dev   / $(grep GITEA_PASSWORD "$STATE/creds.env" | cut -d= -f2)
  demo-api  http://localhost:30095
  kubectl   --context $CTX
EOF
