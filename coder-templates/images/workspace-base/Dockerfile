# Workspace base image — UBI9 + dev tooling.
#
# Used as the FROM for enterprise-node (the Node-flavored equivalent of
# upstream `codercom/enterprise-node:ubuntu`). The 4 -ocp Coder templates
# all consume enterprise-node, not this base directly.
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
# Tag scheme: ghcr.io/coder/demo-aigov-rhaiis-rhsummit-2026/workspace-base:{latest,$sha}
FROM registry.access.redhat.com/ubi9/ubi:latest

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

# 3) tmux — not in UBI9 baseos/appstream. EPEL 9's tmux depends on
#    CRB (CodeReady Builder) which UBI9 doesn't ship, so EPEL's
#    package can't install. Pull the Rocky Linux 9 AppStream RPM
#    directly — same upstream RHEL 9 source, same ABI, no CRB
#    needed.
RUN dnf install -y --nodocs \
        https://download.rockylinux.org/pub/rocky/9/AppStream/x86_64/os/Packages/t/tmux-3.2a-5.el9.x86_64.rpm \
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
