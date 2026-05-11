#!/usr/bin/env bash
# Promote Keycloak `admins`-group personas to GitLab instance admin.
#
# Why this script exists
# ----------------------
# GitLab CE doesn't auto-promote OIDC users to instance admin based on
# group claims (that's a Premium feature via SAML required_groups +
# admin_groups). The booth demo runs CE, so the first time `demoadm`
# (or anyone added to the Keycloak /admins group) signs in via the
# Keycloak button, GitLab creates them as a regular user. We then
# promote them with this script — runs idempotently so re-invoking
# after a `make reset` is a single command.
#
# What it does
# ------------
# 1. SSH to the EC2 host that runs GitLab (IP discovered from
#    terraform output `gitlab_public_ip`).
# 2. Runs `gitlab-rails runner` for each username in $DEMO_ADMIN_USERNAMES
#    (default "demoadm") and sets `user.admin = true`. Idempotent —
#    re-promoting an already-admin user is a no-op.
# 3. Skips usernames whose User row doesn't exist yet (i.e., they
#    haven't signed in via Keycloak yet). Prints a hint when this
#    happens so the operator knows to have the persona sign in first.
#
# Usage
# -----
#   ./scripts/gitlab-promote-demoadmins.sh                  # promote 'demoadm'
#   DEMO_ADMIN_USERNAMES="demoadm,alice" ./scripts/...      # promote multiple
#
# Requires SSH access to the GitLab EC2 host with the cluster's SSH
# key (~/.ssh/id_ed25519 or whatever's wired into the rhsummit-gitlab
# EC2 KeyPair) and AWS creds to read TF state for the public IP.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"
USERNAMES="${DEMO_ADMIN_USERNAMES:-demoadm}"

# Discover the GitLab EC2 IP from Terraform state.
GITLAB_IP=$(cd "${TF_DIR}" && env -u AWS_ENDPOINT_URL AWS_PROFILE=ocp-deploy-acct \
  terraform output -raw gitlab_public_ip 2>/dev/null || echo "")
if [ -z "${GITLAB_IP}" ]; then
  echo "ERROR: terraform output gitlab_public_ip is empty. Apply the gitlab module first." >&2
  exit 1
fi
echo "==> GitLab host: ${GITLAB_IP}"
echo "==> Promoting: ${USERNAMES}"

# Build the Rails one-liner — receives the comma-separated list as a
# Ruby literal so all usernames are handled in a single runner
# invocation (faster than N SSH+runner round-trips).
RUBY_SNIPPET="
names = %q(${USERNAMES}).split(',').map(&:strip).reject(&:empty?)
names.each do |n|
  u = User.find_by(username: n)
  if u.nil?
    puts %Q(SKIP: #{n} — no User row yet \\(sign in via Keycloak first\\))
  elsif u.admin?
    puts %Q(OK:   #{n} — already admin)
  else
    u.admin = true
    u.save!
    puts %Q(OK:   #{n} — promoted to instance admin)
  end
end
"

ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o UserKnownHostsFile=/dev/null \
  ec2-user@"${GITLAB_IP}" "sudo gitlab-rails runner '${RUBY_SNIPPET//\'/\'\\\'\'}'"
