# ubi9-base-workspace — UBI 9.7 + dev tooling for Coder workspaces on OCP.
#
# Used as the FROM for ubi9-node-workspace (the Node-flavored sibling that
# replaces upstream codercom/enterprise-node:ubuntu). The 4 -ocp Coder
# templates all consume ubi9-node-workspace, not this base directly.
#
# OpenShift `restricted-v2` SCC compliance: at runtime OCP injects a random
# UID from the namespace's `openshift.io/sa.scc.uid-range`. The image's
# `USER 1001` is overridden, so anything depending on UID-1001 ownership at
# runtime breaks. The standard Red Hat pattern is to make the home dir
# group-writable by GID 0 (root group) — every restricted SCC adds GID 0 as
# a supplemental group, so the SCC-injected UID can read/write home.
#
#   chgrp -R 0 /home/coder
#   chmod -R g=u /home/coder
#
# Pushed to GHCR by .github/workflows/build-images.yml on changes under
# coder-templates/images/**/Dockerfile.
#
# Tag scheme:
#   ghcr.io/coder/demo-aigov-rhaiis-rhsummit-2026/ubi9-base-workspace:9.7
#   ghcr.io/coder/demo-aigov-rhaiis-rhsummit-2026/ubi9-base-workspace:9.7-<sha>
#   ghcr.io/coder/demo-aigov-rhaiis-rhsummit-2026/ubi9-base-workspace:latest
#
# UBI minor pinned for reproducibility — bump when Red Hat ships a new
# minor (currently RHEL 9.7).
FROM registry.access.redhat.com/ubi9/ubi:9.7

ARG USER=coder
ARG UID=1001

# Core dev tooling + dotfiles deps.
#
# `curl` is intentionally NOT in the AppStream list — UBI9 ships
# `curl-minimal` which provides the curl binary and conflicts with the
# full curl package.
#
# zsh / tmux / neovim / fzf / ripgrep / fd-find / starship are
# pre-installed so the dotfiles repo's install.sh `install_if_missing`
# checks short-circuit. Inside a restricted-v2 pod, `sudo` can't
# elevate (CAP_SETUID is dropped), so install.sh's package-install
# code path doesn't work — pre-baked tools are the workaround.
#
# fzf / ripgrep / fd-find / xclip live in EPEL on UBI9, so we enable
# EPEL once and install them in a single transaction.
# 1) Enable EPEL — done as its own layer so metadata is refreshed for
#    the next RUN. (Combining it with the package install in one RUN
#    failed for `tmux` — dnf's cache from the first transaction didn't
#    see the just-added EPEL repo.)
RUN dnf install -y --nodocs --setopt=install_weak_deps=False \
        https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm \
    && dnf makecache --refresh

# 2) Tools available in UBI9 BaseOS / AppStream + EPEL.
RUN dnf install -y --nodocs --setopt=install_weak_deps=False \
        bash-completion \
        ca-certificates \
        fd-find \
        fzf \
        gcc \
        git \
        gnupg2 \
        jq \
        less \
        make \
        neovim \
        openssh-clients \
        procps-ng \
        python3.11 \
        python3.11-pip \
        ripgrep \
        sudo \
        tar \
        unzip \
        vim-enhanced \
        wget \
        which \
        zip \
        zsh \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# 3) tmux — not in any UBI9 repo. UBI9 stripped tmux from the
#    redistributable subset. EPEL 9 doesn't ship it either (only
#    `tmux-powerline`). It IS in upstream RHEL 9's BaseOS, which
#    Rocky Linux mirrors verbatim — pull the Rocky 9 BaseOS RPM
#    directly. Same ABI, same source, no extra repo setup needed.
#    (Verified path May 2026 against `dnf info tmux` on a real
#    Rocky 9.7 container; bump the version when Rocky ships
#    `tmux-3.5a` or later for el9.)
RUN dnf install -y --nodocs \
        https://download.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/Packages/t/tmux-3.2a-5.el9.x86_64.rpm \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# Starship prompt — used by the dotfiles' .zshrc/.bashrc. Install at
# build time as root because the install.sh script writes to
# /usr/local/bin and would need sudo at workspace-startup time, which
# the SCC-dropped CAP_SETUID prevents.
RUN curl -fsSL https://starship.rs/install.sh | sh -s -- --yes --bin-dir /usr/local/bin

# Single non-root user. Only really used outside OCP (where `USER 1001`
# applies); on OCP the SCC-injected UID takes over and the named user is
# irrelevant — but `nss_wrapper` etc. are not needed because nothing in
# this image looks up the running UID in /etc/passwd.
RUN useradd --uid ${UID} --create-home --shell /bin/bash --user-group ${USER} \
    && echo "${USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USER} \
    && chmod 0440 /etc/sudoers.d/${USER}

# OpenShift-friendly home perms. Group 0 (root) is added as a supplemental
# group to every restricted-v2 pod, so the runtime UID can write here even
# though it doesn't match the image's USER.
RUN chgrp -R 0 /home/${USER} \
    && chmod -R g=u /home/${USER}

# Compatibility symlink — many smaller / quantized LLMs (notably
# Llama 3.3 70B INT4 via RHAIIS chatd) hallucinate `/home/user/...`
# as the working directory when calling Coder Agents' `execute` /
# `write_file` tools with an explicit `workdir` arg, because that
# path is common in their training data (Anthropic's computer-use
# sandbox, etc.). The Coder agent here runs as `coder` with HOME
# = /home/coder. Without this symlink, those hallucinated calls
# fail with `mkdir /home/user: permission denied` (write_file) or
# the ENOENT-disguised-as-shell-error `fork/exec /usr/bin/sh: no
# such file or directory` (execute, when chdir to a nonexistent
# workdir fails).
#
# Bigger frontier models (Sonnet/Opus) probe with `pwd` first
# and then omit `workdir` on subsequent calls, so they don't
# care about this symlink. It's a graceful-degradation patch
# for weaker models — never harms the stronger ones.
RUN ln -s /home/${USER} /home/user

# Make /etc/passwd group-writable so the entrypoint can append a passwd
# entry for the SCC-injected UID at startup. Same pattern Red Hat uses
# in their s2i base images.
RUN chmod g=u /etc/passwd

# UID entrypoint — fakes /etc/passwd + HOME for the random UID OCP's
# SCC injects, so anything that calls `getent passwd $(id -u)` /
# `os/user.Current()` (the Coder agent does both) works.
COPY uid_entrypoint.sh /usr/local/bin/uid_entrypoint
RUN chmod 0755 /usr/local/bin/uid_entrypoint

# Pre-set $SHELL=/usr/bin/zsh so the dotfiles install.sh's
# `set_default_shell` function returns early ("Default shell already
# set to zsh") instead of running `sudo chsh`, which would fail under
# restricted-v2's dropped CAP_SETUID.
ENV SHELL=/usr/bin/zsh

ENTRYPOINT ["/usr/local/bin/uid_entrypoint"]
USER ${UID}
WORKDIR /home/${USER}

CMD ["sleep", "infinity"]
