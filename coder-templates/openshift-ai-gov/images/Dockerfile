# Workspace base image for the openshift-ai-gov template.
#
# Built and pushed to ECR by .github/workflows/build-images.yml on every
# change under coder-templates/**/Dockerfile or coder-templates/**/images/**.
#
# Base image: RHEL UBI9 — gives the booth audience the "RHEL inside OpenShift"
# story. UBI is freely redistributable and works without a Red Hat
# subscription at runtime.

FROM registry.access.redhat.com/ubi9/ubi:latest

ARG USER=coder
ARG UID=1000
ARG GID=1000

# Core dev tooling
RUN dnf install -y --nodocs \
        git \
        curl \
        wget \
        jq \
        unzip \
        which \
        vim-enhanced \
        sudo \
        openssh-clients \
        ca-certificates \
        bash-completion \
        python3.11 \
        python3.11-pip \
        python3.11-devel \
        nodejs \
        npm \
        gcc \
        make \
        rust \
        cargo \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# Language toolchains — quick installs for the demo
RUN python3.11 -m pip install --no-cache-dir \
        ipython \
        anthropic \
        openai \
        httpx

# coder-style sudoers
RUN echo "$USER ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/$USER

# Set up the dev user — Coder will mount $HOME at /home/coder
RUN groupadd --gid $GID $USER \
    && useradd --create-home --uid $UID --gid $GID --shell /bin/bash $USER \
    && chmod 0700 /home/$USER

USER $USER
WORKDIR /home/$USER

# code-server is installed by the Coder agent at workspace start, not at
# image-build time, so the latest version is always picked up.

# Drop a starter prompt + AI Gateway env example for the demo
RUN cat <<'EOF' > /home/$USER/.bashrc.demo
# AI Gateway env vars are exported by the Coder agent startup script.
# Verify with: echo $OPENAI_API_BASE
EOF

CMD ["sleep", "infinity"]
