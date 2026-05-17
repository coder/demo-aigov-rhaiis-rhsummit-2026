# Fresh AWS Account Bootstrap

Operator-facing step-by-step for spinning this whole stack up in a
**new AWS account** that has nothing pre-provisioned. Target state at
the end: a Coder cluster with Bridge + GitLab + Keycloak + AI Bridge
end-to-end, with demo personas (alice, bob, demoadm) able to log in.

> **Estimated time**: 90–120 min on a clean account. ~20 min of operator
> typing; rest is `terraform apply` + `openshift-install` + image pulls
> + cert issuance. Most of the time you're waiting.

> **Cost while running**: ~$3/hr (`m6i.4xlarge ×3` + GitLab `m7a.2xlarge`
> + NAT + small storage) without GPUs. ~$10/hr with one GPU node
> (`g6e.12xlarge`) for the sovereign RHAIIS Llama path. The catalog
> default ships with GPUs disabled.

Read [CATALOG-READINESS.md](CATALOG-READINESS.md) first if you want the
"what's still manual / what's a gap" picture before starting.

---

## Pre-flight

### Inputs you need before starting

| # | Input | Where it comes from | Where it goes |
|---|---|---|---|
| 1 | AWS account access (CLI creds via SSO or named profile) | Your AWS org admin | `aws` CLI + Terraform AWS provider |
| 2 | Public DNS zone (e.g. `example.com`) with Route 53 NS delegation OR a subdomain you can NS-delegate to a child hosted zone | Your DNS registrar | `var.base_domain` |
| 3 | OpenShift pull secret | <https://console.redhat.com/openshift/install/pull-secret> | `var.pull_secret_path` |
| 4 | GitHub OAuth app credentials (for Coder + OCP cluster login + Grafana admin) | GitHub org settings → OAuth apps | SealedSecrets |
| 5 | GitHub PAT with `read:packages` (for GHCR pull) | <https://github.com/settings/tokens> | `ghcr-pull` SealedSecret |
| 6 | GitHub PAT with `read:org` (for redhat-cop group-sync-operator) | Same | `github-group-sync-token` SealedSecret |
| 7 | OpenAI API key (for AI Bridge's central org key) | <https://platform.openai.com/api-keys> | `coder-secrets` SealedSecret |
| 8 | Red Hat Registry pull secret (for RHAIIS vLLM image) | <https://access.redhat.com/terms-based-registry/> | `redhat-pull-secret` Secret in `ocp-ai` |
| 9 | SSH public key (for bootstrap-node access) | Your `~/.ssh/id_*.pub` | `var.ssh_pubkey_path` |

You can defer #4–#8 until after the cluster is up; the bootstrap
script will pause to mint them.

### Tooling required on your workstation

| Tool | Version | Why |
|---|---|---|
| `aws` CLI | v2 | Terraform + ccoctl |
| `terraform` | 1.6+ | Infra provisioning |
| `openshift-install` | 4.21+ | Cluster install |
| `oc` | 4.21+ | Cluster ops |
| `kubeseal` | 0.30+ | Seal secrets |
| `helm` | 3.14+ | Optional (debugging chart values) |
| `gh` | optional | GitHub OAuth app create flow if you automate it |
| `jq` + `python3` | system | Various scripts |

```bash
# macOS quickstart (adjust for your OS)
brew install awscli terraform openshift-cli kubeseal helm gh jq
# openshift-install — pin the version matching your target OCP minor
curl -fsSL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-4.21/openshift-install-mac.tar.gz \
  | tar -xz -C /usr/local/bin openshift-install
```

---

## Step 1 — Fork the repo + collect inputs (5 min)

```bash
# Fork via GitHub UI to your-org/<fork-name>, then:
git clone git@github.com:<your-org>/<fork-name>.git
cd <fork-name>

# Stay on main; the catalog-readiness branch is where the
# parameterization work lives. Once merged, main is the catalog source.
```

Copy + edit the config files:

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
cp .env.example .env

vim terraform/terraform.tfvars   # cluster_name, base_domain, region, ...
vim .env                          # SSO profile, owner_email, ...
```

Minimum-bar `terraform.tfvars`:
```hcl
aws_region   = "us-east-1"        # any region with g6e.12xlarge if GPUs enabled
aws_profile  = "your-profile"     # SSO profile name (or null)
owner_email  = "you@example.com"
cluster_name = "demo01"           # short, DNS-safe; affects IRSA role names
base_domain  = "your-zone.example.com"   # YOUR Route 53 zone

control_plane_count         = 3
control_plane_instance_type = "m6i.4xlarge"
worker_count                = 0
gpu_count                   = 0   # ← set 1 for sovereign Llama; 0 for Bedrock-only (cheaper)

# Pull-secret + SSH-key paths
pull_secret_path = "~/.openshift/pull-secret.json"
ssh_pubkey_path  = "~/.ssh/id_ed25519.pub"
```

---

## Step 2 — AWS pre-flight (5 min)

```bash
# Authenticate (whatever flow your org uses)
aws sso login --profile your-profile

# Sanity: account, region, key quotas
./scripts/catalog-preflight.sh

# Bootstrap the tfstate S3 bucket + DynamoDB lock table for THIS account
# (one-time per AWS account)
./scripts/bootstrap-tf-backend.sh

# Bootstrap quota requests if needed (m6i + g6e + ELB headroom).
# Idempotent — exits 0 if you already have headroom.
./scripts/aws-quota-bootstrap.sh
```

The preflight will tell you which quotas are tight; for the demo footprint
you typically need at least:
- 16 × `vCPU` for m6i family (3 × m6i.4xlarge = 48 vCPU)
- 48 × `vCPU` for g family (only if GPUs enabled)
- 5 × NAT Gateway elastic IPs
- 5 × Application/Network LBs

---

## Step 3 — Terraform infra + OpenShift install (35–45 min)

```bash
cd terraform

terraform init -backend-config="bucket=tfstate-${cluster_name}-$(aws sts get-caller-identity --query Account --output text)"
terraform plan -out plan.tfplan
terraform apply plan.tfplan
```

This creates:
- VPC + subnets + NAT GWs + route tables
- IAM roles (cert-manager-route53, coder-bedrock IRSA via STS OIDC)
- Hosted zone child (`<cluster_name>.<base_domain>`) with NS records in
  the parent zone (parent zone must be in your account OR you do
  manual NS delegation; see `docs/aws-creds.md`)
- S3 bucket for the cluster OIDC provider
- GitLab EC2 instance (`m7a.2xlarge`) with auto-installed Omnibus + cert
- Generates `install-config.yaml` + runs `openshift-install create cluster`
- Outputs kubeconfig at `terraform/.cluster/auth/kubeconfig`

Total apply time: 30–40 min (cluster install dominates).

```bash
export KUBECONFIG=$(pwd)/.cluster/auth/kubeconfig
oc get nodes        # should show 3× master+worker converged, GPU node if gpu_count>0
oc get clusterversion  # COMPLETED, AVAILABLE=True
```

---

## Step 4 — Configure manifests for YOUR cluster (2 min)

The repo's manifests/scripts ship with the booth's hardcoded hostnames.
This script substitutes your values:

```bash
cd ..   # back to repo root

./scripts/configure-manifests.sh
# Reads terraform outputs + AWS STS for account_id + oc for infraName.

git diff --stat   # review (a lot of files; all just hostname/account substitutions)
git add -A && git commit -m "chore: configure manifests for <cluster_name>"
git push
```

Now `main` (or your branch) has all 25 hostname-bearing files pointing at
your cluster.

---

## Step 5 — Mint + seal the 14 per-deploy secrets (15 min)

```bash
# kubeseal needs the cluster's sealed-secrets controller cert
# (this is installed by the root Argo app in step 6, but we need it
#  earlier — apply the sealed-secrets controller manually first):
oc apply -f gitops/apps/sealed-secrets/application.yaml
oc -n openshift-gitops wait --for=condition=Healthy application/sealed-secrets --timeout=120s

# Now run the bootstrap script (interactive — prompts for each value)
./scripts/bootstrap-sealed-secrets.sh

# It will:
#   1. Walk through each of the 14 secrets
#   2. Prompt for the value (or read from env if set)
#   3. Validate (GH OAuth app callback URL = https://oauth-openshift.apps.<your-fqdn>/oauth2callback/github, etc.)
#   4. Seal with kubeseal → manifests/secrets/<name>.yaml
#   5. git add the sealed YAML

git diff --stat manifests/secrets/
git commit -m "feat(secrets): seal per-deploy secrets for <cluster_name>"
git push
```

The OAuth apps you'll need to create:

| OAuth App | Callback URL | Used by |
|---|---|---|
| GitHub: `coder-<cluster>` (org-restricted) | `https://coder.apps.<fqdn>/api/v2/users/oauth2/github/callback` AND `https://coder.apps.<fqdn>/external-auth/github/callback` | Coder login + Coder external_auth |
| GitHub: `openshift-<cluster>` (org-restricted) | `https://oauth-openshift.apps.<fqdn>/oauth2callback/github` | OCP console login |
| GitHub: `grafana-<cluster>` (org-restricted) | `https://graf-coder.apps.<fqdn>/login/github` | Grafana login |
| (GitLab Coder external_auth app is created automatically — `scripts/gitlab-create-coder-oauth-app.sh` runs during bootstrap) | | |
| (Keycloak clients are declared in `manifests/keycloak/realm-demo.yaml` — already there) | | |

---

## Step 6 — Apply the root Argo app (5 min)

```bash
oc apply -f gitops/bootstrap/root-app.yaml

oc get applications -n openshift-gitops -w
# Wait until all apps show Synced + Healthy. Typical order:
#   sync-wave -1: root
#   sync-wave 0:  sealed-secrets, platform-secrets, cluster-config, cert-manager, postgres, gpu-stack, group-sync-operator
#   sync-wave 1:  coder, keycloak
#   sync-wave 2:  coder-routing, coder-workspaces, coder-provisioner, rhaiis (if GPU enabled), bridge
#   sync-wave 3:  observability, coder-agents-config
```

Common stalls to watch for:
- **CrashLoopBackOff on coder pods** → almost always missing/wrong SealedSecret
- **cert-manager OrderFailed** → Route 53 IRSA role + DNS-01 zone permissions mismatch
- **Keycloak realm import stuck** → operator's PostgreSQL backend not ready (check `cnpg-cluster/cluster-keycloak` state)
- **RHAIIS vllm pod Pending** → no GPU node yet, or `redhat-pull-secret` missing

---

## Step 7 — Bootstrap GitLab personas (3 min)

```bash
# After GitLab EC2 is up + Keycloak is reconciled
GITLAB_ADMIN_PAT=$(ssh ec2-user@<gitlab-ip> "sudo gitlab-rails runner 'puts User.find_by_username(\"root\").personal_access_tokens.create!(scopes: [:api, :sudo], name: \"bootstrap\").token'")

GITLAB_ADMIN_PAT=$GITLAB_ADMIN_PAT \
GITLAB_URL=https://gitlab.<base_domain> \
  ./scripts/gitlab-bootstrap-personas.sh
```

This pre-creates alice/bob/demoadm in GitLab with Keycloak OIDC identity
links, adds bob as Developer on the demo projects (so first-day-of-demo
flows work), and promotes demoadm to instance admin.

---

## Step 8 — Register the bridge webhook (2 min)

The bridge service receives GitLab issue webhooks. Register the webhook
on each project that should drive workspaces:

```bash
DEMO_PROJECTS="alice/artemis-sim,demo/sample-app" \
GITLAB_URL=https://gitlab.<base_domain> \
GITLAB_ADMIN_PAT=$GITLAB_ADMIN_PAT \
  ./scripts/gitlab-register-bridge-webhook.sh
```

---

## Step 9 — Smoke test (3 min)

```bash
./scripts/catalog-postdeploy-smoke.sh
```

This verifies:
- Coder login page returns 200
- Bridge `/healthz` returns 200
- Loki has data (Coder logs reaching it = grafana-agent privileged SCC working)
- chatd has both Sonnet 4 (Bedrock) and the sovereign Llama (if GPU enabled) registered
- A `curl` to `https://coder.<fqdn>` redirects to Keycloak SSO
- (Optional) A test workspace can be created via bridge by toggling a label

---

## Step 10 — Hand it off

Tell the booth presenter:

- Coder UI: `https://coder.apps.<fqdn>/`
- GitLab UI: `https://gitlab.<base_domain>/`
- Grafana UI: `https://graf-coder.apps.<fqdn>/`
- OCP console: `https://console-openshift-console.apps.<fqdn>/`
- Demo persona passwords: `Demo2026!` for alice/bob; demoadm has the
  longer one in `manifests/keycloak/realm-demo.yaml`

Day-of label vocabulary (on GitLab issues):
- `coder-workspace` → bridge creates a workspace from default template
- `coder-workspace:<template-slug>` → from named template
- `coder-agent[:<model-slug>]` → workspace + autonomous Coder Agents chat

---

## Teardown (when the demo's over)

```bash
cd terraform
terraform destroy
# ~15 min. Cleans up all AWS resources except:
#   - the parent Route 53 zone (you keep)
#   - the S3 tfstate bucket (you decide whether to nuke; see backend.tf)
```

If GitHub OAuth apps + tokens are scoped to this deployment alone,
delete them in the GitHub UI after destroy.

---

## What if something goes wrong?

The repo has incident-recovery / debugging history in `docs/decisions.md`.
The most useful sections for catalog-readiness troubleshooting:
- §32 — GitLab external_auth recipe (4 landmines)
- §35 — Workspace base image symlinks for hallucinated paths
- §36 — FP8 attempt abort (capacity blocker + AZ swap workaround)
- §37 — Three-persona identity model
- §39 — Boundary on OCP must use `--jail-type landjail`, NOT nsjail
- §40 — Coder external_auth REGEX format

For real-time debugging, the `Makefile`'s `make status` shows Argo state
+ pod states + chatd default model in one screen.

---

## Known gaps in catalog-readiness (Phase 1 work)

See [CATALOG-READINESS.md §Critical gaps](CATALOG-READINESS.md#critical-gaps-to-fix-before-catalog-grade)
for the up-to-date list. The two that would block a fresh deploy entirely
are landed on `catalog-readiness` branch:
- G1: grafana-agent privileged chart values
- G2: `scripts/gitlab-bootstrap-personas.sh`

Plus the extended `scripts/configure-manifests.sh` that covers all 25
hostname-bearing files.

Other open items (see audit doc): TF variable for GPU presence,
`scripts/bootstrap-sealed-secrets.sh`, and a `make catalog-deploy`
target that runs the whole flow.
