# ubi9-node-workspace — UBI 9.7 equivalent of `codercom/enterprise-node:ubuntu`.
#
# All 4 -ocp Coder templates (ai-dev-ocp, agents-dev-ocp,
# demo-ai-gov-firewall-ocp, demo-ai-gov-no-firewall-ocp) FROM this image.
# Source upstream that we're replacing:
# https://hub.docker.com/r/codercom/enterprise-node — Ubuntu-based, with
# Node 22, npm, yarn, Coder agent prereqs. We rebuild on UBI9 so the
# workspace runtime fits the rest of the demo's "RHEL inside OpenShift"
# story (and we control the security posture / SCC compliance).
#
# Pushed to GHCR by .github/workflows/build-images.yml on changes under
# coder-templates/images/**/Dockerfile.
#
# Tag scheme:
#   ghcr.io/coder/demo-aigov-rhaiis-rhsummit-2026/ubi9-node-workspace:9.7
#   ghcr.io/coder/demo-aigov-rhaiis-rhsummit-2026/ubi9-node-workspace:9.7-<sha>
#   ghcr.io/coder/demo-aigov-rhaiis-rhsummit-2026/ubi9-node-workspace:latest

ARG WORKSPACE_BASE=ghcr.io/coder/demo-aigov-rhaiis-rhsummit-2026/ubi9-base-workspace:latest
FROM ${WORKSPACE_BASE}

USER 0

# Node.js 22 LTS via NodeSource RPM (UBI9 ships only Node 18 in default
# repos; NodeSource provides up-to-date LTS streams). yarn + pnpm are
# installed via corepack.
RUN curl -fsSL https://rpm.nodesource.com/setup_22.x | bash - \
    && dnf install -y --nodocs --setopt=install_weak_deps=False nodejs \
    && dnf clean all \
    && rm -rf /var/cache/dnf \
    && corepack enable yarn pnpm

# Common npm globals expected by Coder workspace startup scripts.
RUN npm install --global --no-fund --no-audit \
        typescript \
    && rm -rf /root/.npm

# Re-apply OCP-friendly home perms after the root-owned installs above
# (corepack writes shims to /usr/lib/node_modules, but anything that
# touched /home/coder needs to stay group-writable).
RUN chgrp -R 0 /home/coder \
    && chmod -R g=u /home/coder

USER 1001
WORKDIR /home/coder

CMD ["sleep", "infinity"]
