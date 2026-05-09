# agents-config-tools — UBI 9.7 minimal + the small toolset the
# `coder-agents-config` Argo CD-managed Job needs to call the AWS
# Bedrock API (via IRSA) and the Coder chats API:
#
#   - bash  : the script's runtime
#   - curl  : Coder chats REST API
#   - jq    : JSON munging (everything in chatd is JSON)
#   - aws   : Bedrock model discovery via the AWS SDK + IRSA token file
#
# Why a dedicated image rather than amazon/aws-cli + dnf-install-jq at
# pod startup: OpenShift's `restricted-v2` SCC injects a random UID that
# can't write to /var/cache/dnf, so package installs at runtime fail.
# Pre-baking the tools at build time keeps the runtime container fully
# read-only-friendly and SCC-compliant.
#
# Pushed to GHCR by .github/workflows/build-images.yml.
#
# Tag scheme:
#   ghcr.io/coder/demo-aigov-rhaiis-rhsummit-2026/agents-config-tools:9.7
#   ghcr.io/coder/demo-aigov-rhaiis-rhsummit-2026/agents-config-tools:9.7-<sha>
#   ghcr.io/coder/demo-aigov-rhaiis-rhsummit-2026/agents-config-tools:latest
FROM registry.access.redhat.com/ubi9-minimal:9.7

ARG AWSCLI_VERSION=2.17.58

# microdnf is the UBI-minimal package manager. unzip + tar + gzip are
# needed to extract the AWS CLI bundle; ca-certificates is needed for
# TLS to the Coder API and the AWS endpoints. python3 is used by the
# script's display-name formatter (handles Bedrock inference-profile ID
# variants more reliably than pure bash/awk).
RUN microdnf install -y --nodocs \
        bash \
        ca-certificates \
        curl-minimal \
        gzip \
        jq \
        python3 \
        tar \
        unzip \
    && microdnf clean all \
    && rm -rf /var/cache/yum

# AWS CLI v2 — pinned for reproducibility. Bumping the ARG triggers a
# rebuild via the .github/workflows/build-images.yml path filter.
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWSCLI_VERSION}.zip" \
        -o /tmp/awscli.zip \
    && cd /tmp && unzip -q awscli.zip \
    && ./aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli \
    && rm -rf /tmp/awscli.zip /tmp/aws

# OpenShift `restricted-v2` SCC injects a random UID at runtime. Make
# /etc/passwd group-writable so any startup probe that calls
# `getent passwd $(id -u)` doesn't error out. (Same trick the workspace
# base image uses.)
RUN chmod g=u /etc/passwd

# Run as a non-root UID by default. OCP overrides this with whatever
# UID it has assigned to the namespace; the value here is only relevant
# when the image is pulled outside OpenShift (local testing, k3s, etc.).
USER 1001

ENTRYPOINT ["/bin/bash"]
