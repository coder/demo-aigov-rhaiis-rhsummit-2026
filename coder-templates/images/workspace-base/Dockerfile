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

# Core dev tooling.
# `curl` is intentionally NOT in the dnf list — UBI9 ships `curl-minimal`
# which provides the curl binary and conflicts with the full curl package.
RUN dnf install -y --nodocs --setopt=install_weak_deps=False \
        bash-completion \
        ca-certificates \
        gcc \
        git \
        gnupg2 \
        jq \
        less \
        make \
        openssh-clients \
        procps-ng \
        python3.11 \
        python3.11-pip \
        sudo \
        tar \
        unzip \
        vim-enhanced \
        wget \
        which \
        zip \
    && dnf clean all \
    && rm -rf /var/cache/dnf

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

# Make /etc/passwd group-writable so the Coder agent's home-bootstrap step
# can append a passwd entry for the SCC-injected UID at startup. Same
# pattern Red Hat uses in their s2i base images.
RUN chmod g=u /etc/passwd

USER ${UID}
WORKDIR /home/${USER}

CMD ["sleep", "infinity"]
