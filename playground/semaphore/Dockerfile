FROM alpine:3.20 AS tools

# Pinned tools for the playground's Semaphore templates, verified against the
# official release checksums before installation -- the same pattern as
# gcp-setup/local/semaphore/Dockerfile. TARGETARCH supports amd64 and arm64.
#
# kubectl: within one minor of the kind node (v1.34.11).
# terraform: must EQUAL the terraform on the candidate's laptop. Drill 08 keeps
# local state, and Terraform refuses state written by a newer version, so a
# drill broken in the terminal and checked from Semaphore needs one version.
ARG TARGETARCH
ARG KUBECTL_VERSION=v1.34.11
ARG TERRAFORM_VERSION=1.14.4
RUN apk add --no-cache curl coreutils unzip
RUN set -eu; \
    case "$TARGETARCH" in amd64) arch=amd64 ;; arm64) arch=arm64 ;; *) echo "unsupported architecture: $TARGETARCH" >&2; exit 1 ;; esac; \
    base="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl"; \
    curl -fsSLo /tmp/kubectl "$base"; \
    expected="$(curl -fsSL "${base}.sha256")"; \
    test -n "$expected"; printf '%s  /tmp/kubectl\n' "$expected" | sha256sum -c -; \
    mkdir -p /opt/playground/bin; install -m 0755 /tmp/kubectl /opt/playground/bin/kubectl; rm -f /tmp/kubectl
RUN set -eu; \
    case "$TARGETARCH" in amd64) arch=amd64 ;; arm64) arch=arm64 ;; *) echo "unsupported architecture: $TARGETARCH" >&2; exit 1 ;; esac; \
    file="terraform_${TERRAFORM_VERSION}_linux_${arch}.zip"; \
    curl -fsSLo "/tmp/$file" "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/${file}"; \
    curl -fsSLo /tmp/terraform_SHA256SUMS "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_SHA256SUMS"; \
    expected="$(awk -v f="$file" '$2 == f {gsub("*", "", $2); print $1}' /tmp/terraform_SHA256SUMS)"; \
    test "$(printf '%s\n' "$expected" | wc -l)" -eq 1; test -n "$expected"; \
    printf '%s  /tmp/%s\n' "$expected" "$file" | sha256sum -c -; \
    unzip -q "/tmp/$file" -d /tmp/terraform; install -m 0755 /tmp/terraform/terraform /opt/playground/bin/terraform; rm -rf /tmp/terraform "/tmp/$file" /tmp/terraform_SHA256SUMS

# Extends the image the instance already runs (built by gcp-setup), so this is
# the SAME Semaphore with more tools, not a second one. bash, git, curl and jq
# are already in it.
FROM valensys-semaphore:2.19.12
# A separate directory, put on PATH only by playground/semaphore/tasks/_env.sh:
# gcp-setup's templates keep their own terraform (1.10.5), unaffected.
COPY --from=tools /opt/playground/bin/ /opt/playground/bin/
