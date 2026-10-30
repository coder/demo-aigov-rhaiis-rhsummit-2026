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
KEYCLOAK_SECRET_ARN="${keycloak_secret_arn}"
AWS_REGION_SM="${aws_region}"
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

# ── 2b. Fetch the GitLab OIDC client secret from AWS Secrets Manager ─────────
# No OIDC secret is baked into user-data or Terraform state. The instance
# profile grants read-only secretsmanager:GetSecretValue on exactly this one
# secret ARN. awscli v2 is not in the AL2023 base AMI, so install it (dnf
# package if present, else the official bundle); jq parses the JSON bundle.
dnf install -y jq unzip >/dev/null 2>&1 || true
if ! command -v aws >/dev/null 2>&1; then
  dnf install -y awscli-2 >/dev/null 2>&1 || dnf install -y awscli >/dev/null 2>&1 || {
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscliv2.zip
    (cd /tmp && unzip -q awscliv2.zip && ./aws/install)
  }
fi

# Disable xtrace around the fetch so the secret never lands in the boot log.
set +x
SECRET_JSON="$(aws secretsmanager get-secret-value --region "$${AWS_REGION_SM}" \
  --secret-id "$${KEYCLOAK_SECRET_ARN}" --query SecretString --output text)"
OIDC_CLIENT_SECRET="$(printf '%s' "$SECRET_JSON" | jq -r '.gitlab_client_secret')"
unset SECRET_JSON
if [ -z "$${OIDC_CLIENT_SECRET}" ] || [ "$${OIDC_CLIENT_SECRET}" = "null" ]; then
  echo "FATAL: could not read gitlab_client_secret from $${KEYCLOAK_SECRET_ARN}" >&2
  exit 1
fi
set -x
echo "Fetched gitlab OIDC client secret from Secrets Manager (len=$${#OIDC_CLIENT_SECRET})."

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

# TLS is terminated at the OpenShift edge Route (cert-manager). GitLab runs
# PLAIN HTTP on :80 behind the router; external_url stays https so GitLab
# generates correct https links from the X-Forwarded-* headers the router
# sends. No Let's Encrypt on the VM — that's why port 80 can be closed to the
# world and the box can live on a private subnet with no public IP.
letsencrypt['enable'] = false
nginx['listen_port'] = 80
nginx['listen_https'] = false
nginx['proxy_set_headers'] = {
  'X-Forwarded-Proto' => 'https',
  'X-Forwarded-Ssl'   => 'on'
}

# GitLab Agent Server (KAS) is unused in this demo (no agentk in-cluster, no
# projects with agents) — disable it to drop the grpcs surface.
gitlab_kas['enable'] = false

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
# Registry vhost also runs plain HTTP on :80 behind the edge Route (same single
# Omnibus nginx, routed by Host header); TLS terminates at the OpenShift router.
registry_nginx['listen_port'] = 80
registry_nginx['listen_https'] = false
EOF

# ── 5. Defer reconfigure OUT of the cloud-init boot transaction ──────────────
# `gitlab-ctl reconfigure` runs a Chef resource that does a *synchronous*
# `systemctl start gitlab-runsvdir.service`. When that runs inside
# cloud-final.service (the cloud-init boot transaction), systemd can't finish
# the start job until the boot transaction completes — but cloud-final can't
# complete until reconfigure returns. That's a job-ordering deadlock: first
# boot hangs forever at "starting gitlab-runsvdir", and the only recovery is
# `reboot` followed by a manual `gitlab-ctl reconfigure`.
#
# Fix: run reconfigure — and every step that needs GitLab services to be up —
# from a one-shot systemd unit ordered After=multi-user.target, kicked off with
# `--no-block` so cloud-final returns immediately and the boot transaction can
# complete. The unit then runs cleanly OUTSIDE that transaction, so the
# synchronous runsvdir start has nothing to deadlock against. The unit disables
# itself (and deletes its env file) on success so reboots don't re-run it.

# Values the deferred script needs, baked in at cloud-init time.
cat > /etc/gitlab-firstboot.env <<EOF
GITLAB_HOSTNAME=$${GITLAB_HOSTNAME}
GITLAB_ROOT_PASSWORD=$${GITLAB_ROOT_PASSWORD}
EOF
chmod 600 /etc/gitlab-firstboot.env

cat > /opt/gitlab-firstboot.sh <<'FIRSTBOOT'
#!/bin/bash
set -euxo pipefail
exec > >(tee /var/log/gitlab-firstboot.log | logger -t gitlab-firstboot) 2>&1

# Reconfigure (applies gitlab.rb, triggers Let's Encrypt cert request if any).
gitlab-ctl reconfigure

# Set the initial root password for emergency console access. Demo flow uses
# Keycloak SSO; root is only for "GitLab broke, I need /admin to fix it". With
# web password auth disabled below, root can only authenticate via gitlab-rails
# on this host.
gitlab-rails runner "user = User.find_by(username: 'root'); user.password = '$${GITLAB_ROOT_PASSWORD}'; user.password_confirmation = '$${GITLAB_ROOT_PASSWORD}'; user.password_automatically_set = false; user.save!"

# Lock the front door: SSO-only login + signup off. These live in the
# application_settings table (Postgres on the EBS data volume), so they survive
# reconfigure but get re-applied here so a fresh EBS comes up locked-down.
gitlab-rails runner "
  s = ApplicationSetting.current
  s.password_authentication_enabled_for_web = false
  s.signup_enabled = false
  s.save!
  puts \"SSO-only login: password_auth_for_web=#{s.password_authentication_enabled_for_web} signup=#{s.signup_enabled}\"
"

# GitLab Runner on the same VM. Registration is an operator action from the
# Admin Area UI (the token is generated by GitLab, not us).
curl -L "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.rpm.sh" | bash
dnf install -y gitlab-runner
usermod -aG docker gitlab-runner

echo "GitLab first-boot COMPLETE. URL: https://$${GITLAB_HOSTNAME}"
FIRSTBOOT
chmod 700 /opt/gitlab-firstboot.sh

cat > /etc/systemd/system/gitlab-firstboot.service <<'UNIT'
[Unit]
Description=GitLab first-boot reconfigure (deferred out of cloud-init)
After=multi-user.target cloud-final.service network-online.target
Wants=network-online.target
ConditionPathExists=/opt/gitlab-firstboot.sh

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=1800
EnvironmentFile=/etc/gitlab-firstboot.env
ExecStart=/opt/gitlab-firstboot.sh
# Run exactly once: on success disable the unit and remove the password env
# file so reboots neither re-run reconfigure nor leave the secret on disk.
ExecStartPost=/bin/bash -c 'systemctl disable gitlab-firstboot.service; rm -f /etc/gitlab-firstboot.env /opt/gitlab-firstboot.sh'

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable gitlab-firstboot.service
# Kick it off for THIS boot WITHOUT blocking cloud-final (prevents the deadlock):
# the job waits until multi-user.target is reached, by which point cloud-final
# has already returned and the boot transaction is complete.
systemctl start --no-block gitlab-firstboot.service

# ── 6. Print readiness markers ───────────────────────────────────────────────
echo "GitLab bootstrap (cloud-init phase) COMPLETE; reconfigure deferred to gitlab-firstboot.service." | tee -a /var/log/gitlab-bootstrap.log
echo "Follow it with: journalctl -u gitlab-firstboot -f  (or tail /var/log/gitlab-firstboot.log)" | tee -a /var/log/gitlab-bootstrap.log
echo "URL: https://$${GITLAB_HOSTNAME}" | tee -a /var/log/gitlab-bootstrap.log
echo "Root password: stored in TF state (terraform output -raw gitlab_root_password)" | tee -a /var/log/gitlab-bootstrap.log
echo "Next steps:" | tee -a /var/log/gitlab-bootstrap.log
echo "  1. terraform apply for terraform-gitlab-provider module (creates demo group + sample-app project + issues + webhooks)" | tee -a /var/log/gitlab-bootstrap.log
echo "  2. Register gitlab-runner from the Admin Area UI" | tee -a /var/log/gitlab-bootstrap.log
