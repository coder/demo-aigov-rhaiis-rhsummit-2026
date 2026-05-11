#!/bin/bash
# GitLab CE Omnibus bootstrap for the RH Summit 2026 demo.
#
# Runs as the EC2 instance's cloud-init user-data on first boot.
# Idempotent — re-running this script on a healthy GitLab is safe
# (gitlab-ctl reconfigure is the only state-mutating call and it's
# itself idempotent).
#
# Templated by Terraform; placeholders ($${var}) get substituted
# at terraform apply time.
set -euxo pipefail
exec > >(tee /var/log/gitlab-bootstrap.log | logger -t gitlab-bootstrap) 2>&1

GITLAB_HOSTNAME="${gitlab_hostname}"
REGISTRY_HOSTNAME="${registry_hostname}"
KEYCLOAK_HOSTNAME="${keycloak_hostname}"
LE_EMAIL="${letsencrypt_email}"
OIDC_CLIENT_SECRET='${oidc_client_secret}'
GITLAB_ROOT_PASSWORD='${gitlab_root_password}'

# ── 1. Wait for the data volume (attached as /dev/nvme1n1 on AL2023 Nitro) ──
for i in $(seq 1 60); do
  if [ -b /dev/nvme1n1 ]; then break; fi
  echo "Waiting for /dev/nvme1n1..."
  sleep 5
done

# Format the data volume if it's not yet formatted.
if ! blkid /dev/nvme1n1 >/dev/null 2>&1; then
  mkfs.xfs /dev/nvme1n1
fi

# Mount at /var/opt/gitlab BEFORE installing GitLab (Omnibus creates
# this directory and fills it on `gitlab-ctl reconfigure`).
mkdir -p /var/opt/gitlab
UUID=$(blkid -s UUID -o value /dev/nvme1n1)
echo "UUID=$${UUID} /var/opt/gitlab xfs defaults 0 0" >> /etc/fstab
mount /var/opt/gitlab

# ── 2. AL2023 base updates + dependencies ────────────────────────────────────
# Skip `dnf update` — saves 60s; AMI is already current. Use
# `--allowerasing` so `curl` replaces the preinstalled `curl-minimal`
# (Omnibus's gitlab-ctl reconfigure wants the full curl).
dnf install -y --allowerasing curl postfix policycoreutils openssh-server perl docker

# Docker for GitLab Runner — runs on the same VM, executes pipelines
# in containers without competing with GitLab for kernel resources.
systemctl enable --now docker
usermod -aG docker ec2-user

# ── 3. GitLab CE Omnibus ─────────────────────────────────────────────────────
# Official GitLab package repo for RHEL-family. Works on AL2023 because
# AL2023 is RPM-based; the gitlab-ce.rpm built for el/9 installs cleanly.
curl -fsSL https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.rpm.sh | bash

# `EXTERNAL_URL` baked into the install bootstraps the right hostname
# in /etc/gitlab/gitlab.rb on first run. We OVERWRITE the file
# afterwards with full config including OIDC.
EXTERNAL_URL="https://$${GITLAB_HOSTNAME}" dnf install -y gitlab-ce

# ── 4. Full /etc/gitlab/gitlab.rb config (OIDC + Let's Encrypt + tuning) ────
cat > /etc/gitlab/gitlab.rb <<EOF
external_url 'https://$${GITLAB_HOSTNAME}'

# Let's Encrypt — Omnibus handles issuance + renewal via cron.
# Renews 30 days before expiry; uses HTTP-01 challenge (needs port 80
# reachable from public internet, which our SG allows).
letsencrypt['enable'] = true
letsencrypt['contact_emails'] = ['$${LE_EMAIL}']
letsencrypt['auto_renew'] = true
letsencrypt['auto_renew_hour'] = 3
letsencrypt['auto_renew_minute'] = 0

# ── OIDC against Keycloak ─────────────────────────────────────────
# The `gitlab` confidential OIDC client lives in the Keycloak demo
# realm (see manifests/keycloak/realm-demo.yaml). Users land here
# via the "Sign in with Keycloak" button on the GitLab login page.
gitlab_rails['omniauth_enabled'] = true
gitlab_rails['omniauth_allow_single_sign_on'] = ['openid_connect']
gitlab_rails['omniauth_auto_link_user'] = ['openid_connect']
gitlab_rails['omniauth_block_auto_created_users'] = false
gitlab_rails['omniauth_providers'] = [
  {
    name: 'openid_connect',
    label: 'Keycloak',
    args: {
      name: 'openid_connect',
      # NOTE: `groups` intentionally omitted from the requested scope
      # list — it isn't registered as a Keycloak client scope (only
      # as a client-level protocol mapper), and OIDC clients that
      # request unknown scopes get a hard "Invalid scopes" rejection.
      # The mapper still emits the `groups` claim on every token.
      scope: ['openid', 'profile', 'email'],
      response_type: 'code',
      issuer: 'https://$${KEYCLOAK_HOSTNAME}/realms/demo',
      discovery: true,
      client_auth_method: 'query',
      uid_field: 'preferred_username',
      send_scope_to_token_endpoint: 'true',
      client_options: {
        identifier: 'gitlab',
        secret: '$${OIDC_CLIENT_SECRET}',
        redirect_uri: 'https://$${GITLAB_HOSTNAME}/users/auth/openid_connect/callback'
      }
    }
  }
]

# Disable self-signup — only Keycloak-federated users can log in.
gitlab_rails['gitlab_signup_enabled'] = false

# ── Booth-grade resource tuning ───────────────────────────────────
# Default Omnibus is sized for ~100 users; we have 5. Trim.
puma['worker_processes'] = 2
puma['per_worker_max_memory_mb'] = 1024
sidekiq['max_concurrency'] = 10
prometheus_monitoring['enable'] = false   # we use OCP UWM Prom
gitaly['gitconfig'] = [{ key: 'pack.threads', value: '1' }]

# Keep the default GitLab Pages off (not needed for the booth flow).
# NOTE: Don't set `pages_external_url ''` — Omnibus validates the URL
# format *before* checking the enable flag, so an empty string blows
# up the reconfigure with "must include a schema and FQDN". Just
# disabling Pages is enough.
gitlab_pages['enable'] = false

# ── Container Registry ───────────────────────────────────────────
# Enabled on its own subdomain (registry.<external_url>) — this is
# the standard Omnibus pattern. Omnibus auto-requests a second
# Let's Encrypt cert for the registry FQDN (port 80 ACME challenge
# already open in the SG); registry traffic runs over 443 same as
# the main GitLab UI, so no extra SG rule is needed.
#
# Booth demo uses this for:
#   - Coder workspace template images pushed by the bridge service
#   - Anything the persona flow needs to docker push / docker pull
#     against a "their company's registry" rather than a public one.
registry_external_url 'https://$${REGISTRY_HOSTNAME}'
registry['enable'] = true
registry_nginx['letsencrypt_contact_emails'] = ['$${LE_EMAIL}']
EOF

# ── 5. Reconfigure (applies gitlab.rb, triggers Let's Encrypt cert request) ─
gitlab-ctl reconfigure

# ── 6. Set the initial root password for emergency console access ───────────
# Demo flow uses Keycloak SSO; root is only for "GitLab broke, I need
# to log in via /admin to fix something" scenarios.
gitlab-rails runner "user = User.find_by(username: 'root'); user.password = '$${GITLAB_ROOT_PASSWORD}'; user.password_confirmation = '$${GITLAB_ROOT_PASSWORD}'; user.password_automatically_set = false; user.save!"

# ── 7. GitLab Runner on the same VM ──────────────────────────────────────────
curl -L "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.rpm.sh" | bash
dnf install -y gitlab-runner

# Add gitlab-runner to docker group so it can exec into Docker
usermod -aG docker gitlab-runner

# Runner registration is a post-install step done from the GitLab UI
# (Admin Area → Runners → New instance runner → token) — leave this
# as an operator action since the token is generated by GitLab, not
# us. Doc this in the README's booth-setup section.

# ── 8. Print readiness markers ───────────────────────────────────────────────
echo "GitLab bootstrap COMPLETE." | tee -a /var/log/gitlab-bootstrap.log
echo "URL: https://$${GITLAB_HOSTNAME}" | tee -a /var/log/gitlab-bootstrap.log
echo "Root password: stored in TF state (terraform output -raw gitlab_root_password)" | tee -a /var/log/gitlab-bootstrap.log
echo "Next steps:" | tee -a /var/log/gitlab-bootstrap.log
echo "  1. terraform apply for terraform-gitlab-provider module (creates demo group + sample-app project + issues + webhooks)" | tee -a /var/log/gitlab-bootstrap.log
echo "  2. Register gitlab-runner from the Admin Area UI" | tee -a /var/log/gitlab-bootstrap.log
