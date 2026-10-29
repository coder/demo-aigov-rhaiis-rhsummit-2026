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

# C++ build tooling — pre-installed here so the artemis-sim-dev-ocp template
# (and any other C++-flavored workspace consumers) doesn't have to `dnf
# install` these at workspace startup. That matters because:
#   1. Faster cold starts: ~50MB of RPMs avoided on every workspace boot.
#   2. SCC compliance: at startup the pod runs under restricted-v2 with a
#      random non-root UID and CAP_SETUID dropped, so `sudo dnf install`
#      from the agent's startup script fails. Installing at build time
#      (here, as root, before any SCC applies) sidesteps that entirely.
#
# Package notes:
#   - `gcc` + `make` are already in ubi9-base-workspace; we add `clang` as
#     an alternate compiler and `gdb` for debugging.
#   - `clang-tools-extra` provides `clangd` — the LSP server VSCode /
#     code-server uses for C++ IntelliSense.
#   - `pkg-config` on UBI9 is packaged as `pkgconf-pkg-config` (the
#     pkgconf reimplementation provides the `pkg-config` binary via a
#     compat shim). Plain `pkg-config` is NOT a valid package name on UBI9.
RUN dnf install -y --nodocs --setopt=install_weak_deps=False \
        cmake \
        gdb \
        clang \
        clang-tools-extra \
        pkgconf-pkg-config \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# code-server — pre-baked so workspaces don't download it from code-server.dev
# on every start. That runtime download is flaky (transient TLS resets have
# left workspaces with a missing /tmp/code-server/bin/code-server and code-server
# never starting) and it violates this demo's air-gapped posture (the cluster
# should not reach the public internet for workspace software). Installed via
# the official standalone method to a fixed, read-only system prefix. The
# coder/code-server module in every -ocp template is configured with
#   offline = true, install_prefix = "/usr/lib/code-server"
# so it runs THIS copy and never fetches from the internet. Pin the version to
# the module's previous default (v4.144.0); bump this ARG to upgrade.
ARG CODE_SERVER_VERSION=4.144.0
RUN curl -fsSL https://code-server.dev/install.sh \
      | sh -s -- --method=standalone --prefix=/usr/lib/code-server --version="${CODE_SERVER_VERSION}" \
    && chmod -R a+rX /usr/lib/code-server \
    && /usr/lib/code-server/bin/code-server --version

# Unlink GitHub Copilot from the code-server (VS Code) CORE. This build's
# product.json hardcodes `defaultChatAgent` -> GitHub.copilot, which is what
# makes the built-in Chat panel / "Set up Copilot" surface appear regardless of
# installed extensions. Strip it so Copilot is not wired into core at all. The
# templates ALSO set `chat.disableAIFeatures = true` (user setting) to hide the
# chat UI entirely; this is the air-gapped, belt-and-suspenders half.
RUN PJ="$(find /usr/lib/code-server -name product.json -path '*/vscode/*' | head -1)" \
    && test -n "$PJ" \
    && jq 'del(.defaultChatAgent)' "$PJ" > "$PJ.tmp" \
    && mv "$PJ.tmp" "$PJ" \
    && ! jq -e 'has("defaultChatAgent")' "$PJ" >/dev/null \
    && echo "Removed defaultChatAgent from $PJ"

# Re-apply OCP-friendly home perms after the root-owned installs above
# (corepack writes shims to /usr/lib/node_modules, but anything that
# touched /home/coder needs to stay group-writable).
RUN chgrp -R 0 /home/coder \
    && chmod -R g=u /home/coder

USER 1001
WORKDIR /home/coder

CMD ["sleep", "infinity"]
