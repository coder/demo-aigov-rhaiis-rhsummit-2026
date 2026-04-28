# Team onboarding — Coder + RH Summit 2026 demo build

> Audience: Coder SE/PubSec teammates joining Austen on this demo.
> Time to first `terraform plan`: ~15 min after AWS access lands.
> Last updated 2026-04-27.

This is the demo build environment for **Red Hat Summit + AnsibleFest 2026** (Atlanta GWCC, May 11–14). You'll be helping Austen test, validate, iterate, and run the booth flow on the cluster this repo provisions.

---

## 0. Prerequisites — what you need before you start

| Access | How to get it |
|---|---|
| Coder Identity Center login (the awsapps.com SSO portal) | You probably already have this. If `aws configure sso` doesn't recognize you in step 2, ping `#it` to be added. |
| Sandbox AWS account (`342934376218`) `AWSAdministratorAccess` permission set | Comes with the SSO entitlement above. Verify with `aws --profile sandbox sts get-caller-identity` after step 2. |
| GitHub access to `coder/demo-aigov-rhaiis-rhsummit-2026` | Push access on `coder/*` repos. If you can already PR into `coder/coder`, you're set. |
| Red Hat partner pull-secret | Download from <https://console.redhat.com/openshift/install/pull-secret>. Tied to your personal RH account; everyone on the team needs their own download. |
| SSH keypair on your laptop | `~/.ssh/id_ed25519.pub` or similar. `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""` if missing. |

**Tooling on your laptop** (one-time, ~5 min via Homebrew):

```bash
brew install awscli jq gh terraform
# or: brew install awscli jq gh opentofu

# OpenShift binaries (Apple Silicon):
curl -L https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-4.21/openshift-install-mac-arm64.tar.gz | tar -xz
curl -L https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-4.21/openshift-client-mac-arm64.tar.gz | tar -xz
sudo mv openshift-install oc kubectl /usr/local/bin/
```

Verify versions:

```bash
aws --version              # v2.x
terraform version          # 1.7+
openshift-install version  # 4.21+
oc version --client        # 4.21+ recommended
gh auth status             # logged in
```

---

## 1. Clone the repo

```bash
git clone git@github.com:coder/demo-aigov-rhaiis-rhsummit-2026.git
cd demo-aigov-rhaiis-rhsummit-2026
```

The companion sample repo (cloned at workspace startup during demo flow):

```bash
git clone git@github.com:coder/demo-sbom-verifier.git ~/code/coder/demo-sbom-verifier
```

---

## 2. AWS profiles (sandbox + parent)

Configure the same SSO profiles Austen uses. The exact SSO start URL is `https://d-9066325a54.awsapps.com/start/` — this is Coder's Identity Center.

```bash
aws configure sso --profile sandbox
# Prompts:
#   SSO session name:         rh-account
#   SSO start URL:            https://d-9066325a54.awsapps.com/start/
#   SSO region:               us-east-1
#   SSO registration scopes:  sso:account:access  (default — accept)
# Browser opens. Approve.
# Account list appears — pick the sandbox account (342934376218).
# Role:                       AWSAdministratorAccess
# Default region:             us-east-1
# Output:                     json

# (Optional, only if you need to file Route 53 changes against the
# parent zone yourself instead of asking Austen. Skip otherwise.)
aws configure sso --profile parent
# Same SSO session 'rh-account'; pick account 716194723392.
```

Verify:

```bash
aws --profile sandbox sts get-caller-identity
# Account: 342934376218
```

When your token expires (8h default), `aws sso login --profile sandbox` refreshes it. No need to re-run `aws configure sso`.

---

## 3. `.env`

```bash
cp .env.example .env
# Edit .env:
#   AWS_PROFILE_SANDBOX="sandbox"
#   AWS_PROFILE_PARENT="parent"   # or "" if you skipped it in §2
#   TF_VAR_pull_secret_path="$HOME/.openshift/pull-secret.json"
#   TF_VAR_ssh_pubkey_path="$HOME/.ssh/id_ed25519.pub"
#   (the rest can stay at the locked-architecture defaults)

source .env
```

`.env` is gitignored. Don't commit yours.

Drop your Red Hat pull-secret into the path you set:

```bash
mkdir -p ~/.openshift
# Save the JSON downloaded from console.redhat.com as:
chmod 600 ~/.openshift/pull-secret.json
```

---

## 4. Verify everything is wired up

```bash
scripts/verify-aws-access.sh
```

Expected: green checks for both profiles, with `bedrock:ListFoundationModels` as a soft warning (`!`) on first run if you haven't invoked Bedrock in this account yet — that's fine.

```bash
scripts/aws-quota-bootstrap.sh check
```

Expected: all `OK` rows. The locked architecture needs 64 std vCPU + 8 GPU vCPU; the sandbox has 640 / 768.

---

## 5. Initialize Terraform (uses shared S3 remote state)

The demo's Terraform state lives in **S3 + DynamoDB locking** in the sandbox account. Anyone with sandbox SSO can plan/apply from their own laptop. The DynamoDB lock prevents two people running `terraform apply` at the same time.

```bash
cd terraform/prereqs && terraform init && cd -
cd terraform         && terraform init && cd -
```

That's it — the backend is already configured in `backend.tf` files in both directories. `init` pulls the existing state from S3 (if a teammate has already applied) or starts fresh.

Verify state is shared:

```bash
aws --profile sandbox s3 ls s3://tfstate-coder-demo-aigov-rhsummit-2026-342934376218/ --recursive
# You should see prereqs/terraform.tfstate (13K-ish, applied by Austen)
# and cluster/terraform.tfstate once the cluster install lands.
```

---

## 6. Day-to-day collaboration model

### Repo work — standard Git flow

- Branch off `main`, make changes, open a PR against `coder/demo-aigov-rhaiis-rhsummit-2026`.
- Reviews are lightweight; flag Austen on anything that touches the locked architecture (compact 3-converged + always-GPU, RH operator policy, the seed pattern for the sample repo). Smaller things (docs, scripts, config) — go ahead and merge after one review.
- `main` is what the cluster TF will deploy. Test changes locally with `terraform plan` before merging.

### TF apply / destroy — coordinate via Slack

Even with DynamoDB locking, **post in Slack before `terraform apply` or `terraform destroy`** so we're not stepping on each other:

> "Heading into `terraform apply` on the cluster TF in 5 min — back in ~75."

If you forget, the worst case is the lock blocks one of you with a clear error:

```
Error: Error acquiring the state lock
   Lock Info:
     ID:        9d1d23e9-cd61-...
     Path:      tfstate-...
     Created:   2026-04-27 ...
```

Wait it out, or break the lock if you're sure the holder is gone:
`terraform force-unlock <ID>`.

### Cluster lifecycle — destroy when not in use

- The cluster costs ~$3.65/hr while running; ~$87/day if 24/7.
- For testing windows: `terraform apply` Monday morning, `terraform destroy` Friday evening. ~$60 saved per week vs always-on.
- The sample repo (`coder/demo-sbom-verifier`) and the GHCR images survive destroy/rebuild — only the cluster itself is ephemeral.

### Common operations

```bash
# Plan only — see what would change without applying
cd terraform && terraform plan

# Apply (be in Slack first)
cd terraform && terraform apply

# Destroy when done testing
cd terraform && terraform destroy

# Rotate the cert-manager IAM access key (e.g., monthly hygiene)
cd terraform && terraform apply -replace=aws_iam_access_key.cert_manager

# Get current Coder URL after a fresh install
cd terraform && terraform output -raw coder_url

# Get the kubeconfig path (after install)
cd terraform && terraform output -raw kubeconfig_path
export KUBECONFIG=$(terraform output -raw kubeconfig_path)
oc whoami
```

### Handing the cluster off

When you finish a session and don't want to destroy (someone else might want to keep using it):

```bash
# Make sure all your changes are committed + pushed
git status
git push

# Confirm state is unlocked
aws --profile sandbox dynamodb scan --table-name tfstate-coder-demo-aigov-rhsummit-2026-tflock
# (no items = unlocked)

# Drop a Slack message: "Cluster's still up at https://coder.apps.cluster.rhsummit.coderdemo.io
# / kubeadmin password in TF state if you need it / I'm out for the day"
```

---

## 7. Where to look when something breaks

| Symptom | Where to look |
|---|---|
| AWS auth errors (`ExpiredToken`, `Unable to locate credentials`) | `aws sso login --profile sandbox` to refresh; verify with `aws --profile sandbox sts get-caller-identity` |
| `terraform apply` fails on cluster install | `./.cluster/.openshift_install.log` — the most useful log; usually shows whether it's a quota issue, IAM perm, or AWS timeout |
| OCP cluster up but Argo apps red | `oc get applications -n openshift-gitops` then `oc describe application <name>` — usually a CRD-not-yet-installed retry that will resolve on its own in a few minutes |
| RHAIIS pod won't schedule | `oc describe pod -n ocp-ai vllm-...` — most likely the GPU node isn't yet labeled `nvidia.com/gpu.present=true` (NVIDIA driver still compiling, ~3–5 min after first boot) |
| Workspace template push fails | Check `CODER_URL`/`CODER_SESSION_TOKEN` GH Actions secrets are set + valid |
| Lost track of demo state across sessions | `~/.claude/projects/.../memory/demo_repo_state.md` and `demo_repo_pending.md` are Austen's working memory — check there for the latest "where we are" |

---

## 8. Reference docs in this repo

- [`README.md`](../README.md) — top-level "what is this and how is it built"; sizing/cost/startup-time table; layout
- [`docs/aws-creds.md`](aws-creds.md) — AWS credential inventory + rotation playbook
- [`docs/aws-setup.md`](aws-setup.md) — the longer-form fresh-laptop AWS setup walkthrough Austen used (this doc is the team-flavored shorter version)
- [`docs/architecture.md`](architecture.md) — production-narrative arc + reference architecture
- [`gitops/README.md`](../gitops/README.md) — Argo CD app-of-apps wiring, sync-wave map, operator policy
- [`terraform/README.md`](../terraform/README.md) — cluster TF flow + SNO escape hatch
- [`terraform/prereqs/README.md`](../terraform/prereqs/README.md) — account-level prereqs

---

## 9. When you're stuck — Slack escalation order

1. **Repo-shape questions** (what does this manifest do, why is X structured Y way) → `#se-pubsec` or DM Austen.
2. **AWS access / IAM / SSO problems** → `#it` for access; `#se-pubsec` for "is this how it should work."
3. **OCP install / cert-manager / CNPG / GPU operator weirdness** → search Red Hat docs first; fall back to `#se-pubsec`.
4. **"This is taking 90 minutes and not finishing"** → check `./.cluster/.openshift_install.log` first; if AWS-side flakiness, sometimes a `terraform apply` re-run picks up where it left off; if cluster-side, `oc get clusterversion` / `oc get co` after grabbing kubeconfig.
