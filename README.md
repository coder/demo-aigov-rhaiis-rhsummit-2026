# demo-aigov-rhaiis-rhsummit-2026

Reference architecture and deployable demo for the **Coder + Red Hat** booth at **Red Hat Summit + AnsibleFest 2026** (Atlanta GWCC, May 11–14).

> **Lead with AI Governance. Prove it with Developer Experience.**
> Coder + Red Hat: safe AI adoption at enterprise scale.

## What this repo is

End-to-end IaC + GitOps to stand up a governed agentic AI coding demo on **OpenShift 4.20+ (IPI install in your AWS account)** — combining:

- **Coder Workspaces** — Terraform-defined cloud development environments on OpenShift (latest RC for full Coder Agents EA functionality)
- **Coder AI Governance Add-On** — AI Gateway (centralized LLM gateway) + Agent Firewalls (process-level egress policy) + audit trails
- **Coder Agents (Early Access)** — self-hosted agent loop running inside the Coder control plane (no LLM API keys in the workspace)
- **Coder Tasks** — background agent execution interface for Claude Code, Aider, Goose, Amazon Q, and custom agents
- **Red Hat AI Inference Server (RHAIIS)** — enterprise vLLM serving an OpenAI-compatible endpoint, latest image
- **Red Hat OpenShift GitOps** (Argo CD) — manages all cluster apps via app-of-apps pattern
- **cert-manager Operator for Red Hat OpenShift** — wildcard TLS for `*.coder.apps.<fqdn>` via Let's Encrypt + Route 53 DNS-01
- **OpenShift Container Platform 4.20+** — self-managed via Installer-Provisioned Infrastructure (IPI) on AWS

### Operator policy

This demo uses **only Red-Hat-certified, RH-supported operators** where Red Hat ships one. Coder is a Red Hat partner and pulls all RH-distributed images through the partner pull-secret. Specifically:

| Component | Operator / Image | Source |
|---|---|---|
| Argo CD | `openshift-gitops-operator` | Red Hat (NOT upstream Argo CD operator) |
| cert-manager | `openshift-cert-manager-operator` | Red Hat (NOT upstream jetstack/cert-manager) |
| RHAIIS | `registry.redhat.io/rhoai/vllm-cpu-rhel9` | Red Hat AI Inference Server (NOT community vLLM build) |
| External Secrets Operator | `external-secrets-operator` (channel: `stable`) | **community-operators** — *documented exception.* Red Hat does not ship a first-party ESO; the RH-supported alternative is HashiCorp Vault, overkill for two secrets. ESO is the path RH validated-patterns recommend for AWS Secrets Manager integration. See [`gitops/operator/external-secrets-subscription.yaml`](gitops/operator/external-secrets-subscription.yaml) for full reasoning. |

> **Demo simplicity over hardening.** This is a booth demo, not an ATO baseline. STIG/FIPS posture, OCP `restricted-v2` SCC overrides, and air-gap config are intentionally **not** applied — they overcomplicate setup. Production architectures keep them; see [`docs/architecture.md`](docs/architecture.md) for the production narrative arc.

## Architecture at a glance

```
┌─── AWS account (your account, your region) ──────────────────────────────┐
│                                                                          │
│  ┌─ Terraform manages ─────────────────────────────────────────────────┐ │
│  │   VPC + subnets + NAT/IGW                                            │ │
│  │   IAM roles for OCP installer + workers                              │ │
│  │   Route 53 records (you supply hosted zone)                          │ │
│  │   RDS Aurora Postgres (Coder DB)                                     │ │
│  │   ECR repos (workspace base images)                                  │ │
│  │   OpenShift 4.20 IPI install (openshift-install via local-exec)      │ │
│  │   OpenShift GitOps operator (post-install)                           │ │
│  │   Argo CD root Application (app-of-apps bootstrap)                   │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                                                          │
│  ┌─ OpenShift cluster ────────────────────────────────────────────────┐ │
│  │                                                                     │ │
│  │  ┌─ Argo CD manages (GitOps from this repo) ─────────────────────┐ │ │
│  │  │   external-secrets/  ESO ClusterSecretStore → AWS Secrets Mgr  │ │ │
│  │  │   cert-manager/      Let's Encrypt ClusterIssuers (DNS-01/R53) │ │ │
│  │  │   coder/             Coder Helm chart (RC) + AI Gov Add-On     │ │ │
│  │  │   coder-routing/     OCP Routes + wildcard cert externalRef    │ │ │
│  │  │   rhaiis/            RHAIIS / vLLM serving Granite-3.1-8B      │ │ │
│  │  │   (future)           Monitoring, demo data seeding             │ │ │
│  │  └────────────────────────────────────────────────────────────────┘ │ │
│  │                                                                     │ │
│  │  ┌─ Workspace template (pushed by GH Actions) ───────────────────┐ │ │
│  │  │   coder-templates/openshift-ai-gov/                            │ │ │
│  │  │     - main.tf (Coder agent + code-server + Pod)                │ │ │
│  │  │     - config.yaml (Agent Firewall allowlist — process-level)   │ │ │
│  │  │     - images/Dockerfile (UBI9 base)                            │ │ │
│  │  │   Agent Firewall config mounts to                              │ │ │
│  │  │   ~/.config/coder_boundary/config.yaml at workspace start      │ │ │
│  │  └────────────────────────────────────────────────────────────────┘ │ │
│  │                                                                     │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘

       ▲
       │  GH Actions (.github/workflows/) pushes:
       │    - build-images.yml: workspace base images → ECR (on Dockerfile changes)
       │    - push-templates.yml: coder-templates/* → live Coder (on template changes)
       │
   ┌───┴────────────────────────────┐
   │  this repo (single source of   │
   │  truth — Terraform + GitOps    │
   │  manifests + templates)        │
   └────────────────────────────────┘
```

## Repository layout

```
.
├── README.md                       # this file
├── LICENSE                         # Apache-2.0
├── .gitignore
│
├── terraform/                      # AWS + OCP infra (run this first)
│   ├── README.md
│   ├── versions.tf
│   ├── providers.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── main.tf
│   ├── install-config.yaml.tftpl
│   └── terraform.tfvars.example
│
├── gitops/                         # Argo CD app-of-apps (Argo points here)
│   ├── README.md
│   ├── bootstrap/
│   │   └── root-app.yaml           # the one Application that fans out to all apps below
│   └── apps/
│       ├── coder/
│       │   └── application.yaml    # Coder Helm chart (latest RC) with AI Gov Add-On
│       ├── rhaiis/
│       │   └── application.yaml    # RHAIIS / vLLM Deployment + Service
│       └── agent-firewalls/
│           └── application.yaml    # Coder Agent Firewalls rules ConfigMap
│
├── manifests/                      # raw Kubernetes manifests (referenced by Argo CD apps)
│   ├── rhaiis/
│   │   ├── namespace.yaml
│   │   └── vllm-deployment.yaml
│   └── agent-firewalls/
│       └── rules.example.yaml
│
├── coder-templates/                # demo workspace templates pushed by GH Actions
│   ├── README.md
│   └── openshift-ai-gov/
│       ├── main.tf                 # Coder template Terraform
│       ├── README.md
│       └── images/
│           └── Dockerfile          # workspace base image
│
├── helm/                           # (WIP) supplemental Helm values for app-of-apps
│   └── coder/
│
├── scripts/
│   └── tool-call-smoke-test.sh     # validate RHAIIS tool-call parser end-to-end
│
└── .github/
    └── workflows/
        ├── build-images.yml        # build + push workspace base images to ECR
        └── push-templates.yml      # `coder templates push` against the live cluster
```

## Quickstart

### 0. Prereqs (one-time)

- An AWS account with admin perms (or scoped enough for OCP IPI)
- `awscli` configured with your account / profile
- A Red Hat **partner pull secret** → grab from <https://console.redhat.com/openshift/install/pull-secret>
- An **SSH public key** for OpenShift node access (`~/.ssh/id_ed25519.pub` or similar)
- The **`openshift-install`** binary (4.20+) on your `PATH` — download from <https://mirror.openshift.com/pub/openshift-v4/clients/ocp/>
- The **`oc`** binary on your `PATH` (same mirror)
- `terraform` ≥ 1.7 or `tofu` ≥ 1.7
- `gh` CLI authenticated (you've already done this)

### 1. Provision account-level prereqs (run once per AWS account)

```bash
cd terraform/prereqs/
cp terraform.tfvars.example terraform.tfvars
# edit: base_domain, owner_email, cluster_name, instance types
terraform init
terraform apply
```

This will:
- Validate AWS service quotas (EC2 vCPU, EIPs, VPCs, IGWs, hosted zones); **hard-fail if any is below the computed need**
- Optionally file quota-increase requests via the Service Quotas API (`request_quota_increases = true`)
- Create the public Route 53 hosted zone for `base_domain` (or import an existing one)
- Create a dedicated IAM user `ocp-installer-<cluster_name>` with admin perms + access keys (or skip and use your own creds)

If you created a new hosted zone, **delegate the printed NS records at your registrar** before continuing. Verify with `dig +short NS <base_domain>`.

### 2. Provision the cluster

```bash
cd terraform/   # not prereqs/ — the parent root
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: aws_region, cluster_name, base_domain, pull_secret_path, ssh_pubkey_path
terraform init
terraform plan
terraform apply
```

This will:
1. Create RDS Aurora Postgres (Coder DB) + ECR repos + GHA OIDC role + cert-manager Route 53 IAM user
2. Generate `install-config.yaml` from the template
3. Run `openshift-install create cluster` (~30–45 min)
4. Apply both RH-supported operator subscriptions (OpenShift GitOps + cert-manager)
5. Wait for the `cert-manager` namespace + CRDs to come up
6. Inject the Route 53 access keys into Secret `route53-credentials` in `cert-manager` namespace
7. Apply the Argo CD root Application (app-of-apps bootstrap)

After `apply` finishes you'll have:
- A live OCP 4.20 cluster with two RH-supported operators installed
- Argo CD running, with Applications for cert-manager (ClusterIssuers) + Coder + RHAIIS + Agent Firewalls + coder-routing
- Wildcard TLS cert in flight for `*.coder.apps.<fqdn>` (Let's Encrypt prod, DNS-01 over Route 53)
- Coder reachable at `https://coder.apps.<cluster-domain>`
- RHAIIS reachable cluster-internally at `http://vllm.ocp-ai.svc:8000`

### 2. Configure Coder providers (one-time)

Once Coder is up, log in as the first admin user, grab a session token, then:

```bash
gh secret set CODER_URL --body "https://coder.<your-cluster-domain>"
gh secret set CODER_SESSION_TOKEN --body "<session-token>"
```

The GH Actions workflow will use these to push template updates.

### 3. Push your first workspace template

```bash
git add coder-templates/openshift-ai-gov/
git commit -m "feat(template): initial openshift-ai-gov template"
git push origin main
```

The `push-templates.yml` workflow will run `coder templates push` against your cluster.

### 4. Set up the booth-demo sprint-ticket flow

Run once per repo to create the demo labels (`sprint-ticket`, `demo`, `rhsummit-2026`):

```bash
./scripts/setup-demo-labels.sh
```

The booth demo flow becomes:

1. Open a new GitHub Issue and pick the **🏃 Sprint Ticket (booth demo)** template
2. Fill in the summary (e.g., *"Add input validation to checkout endpoint"*) and submit
3. The `sprint-ticket` label is auto-applied → `.github/workflows/sprint-ticket.yml` fires
4. The workflow calls `coder create sprint-<issue-number> --template openshift-ai-gov`
5. The Prebuilt Workspace claim from the warm pool returns in <60s
6. The workflow comments back on the issue with the workspace URL

Stand at the booth, click **New Issue → Sprint Ticket → Submit**, and the audience watches the workspace appear in the Coder UI in real time.

### 5. Validate end-to-end

```bash
./scripts/tool-call-smoke-test.sh \
  https://vllm.<your-cluster-domain>/v1 \
  granite-3.1-8b-instruct
```

Expected: `✅ PASS: tool_calls returned ...`

### 6. Tear down

```bash
cd terraform/
terraform destroy
```

This will run `openshift-install destroy cluster` first, then the AWS infra.

## Recommended model lineup

| Slot | Model | Why |
|---|---|---|
| Cloud (AI Gateway primary) | Claude Sonnet (latest) | Strongest tool-use; fast for live demo beats |
| Sovereign (RHAIIS) | `ibm-granite/granite-3.1-8b-instruct` | RH-blessed, Apache-2.0, vLLM `granite` tool-call parser, CPU-feasible |

Alternates: `Qwen/Qwen2.5-Coder-7B-Instruct` (`hermes` parser) for stronger raw coding performance; `meta-llama/Llama-3.1-8B-Instruct` (`llama3_json` parser) if you need a Llama story.

## Status

Pre-event scaffold. Architecture, IaC, GitOps manifests, templates, and workflows are being authored in the run-up to Red Hat Summit 2026 (May 11).

## License

Licensed under the **Apache License, Version 2.0**. See [LICENSE](LICENSE).
