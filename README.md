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
- **OpenShift Container Platform 4.20+** — self-managed via Installer-Provisioned Infrastructure (IPI) on AWS

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
│  │  │   coder/        Coder Helm chart (latest RC) + AI Gov Add-On   │ │ │
│  │  │   rhaiis/       RHAIIS / vLLM serving Granite-3.1-8B-Instruct  │ │ │
│  │  │   agent-firewalls/  Process-level egress allowlist             │ │ │
│  │  │   (future)      Monitoring, demo data seeding                   │ │ │
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
- A **public Route 53 hosted zone** for the cluster's parent domain (e.g., `aws.example.com`)
- A Red Hat account → grab your **pull secret** from <https://console.redhat.com/openshift/install/pull-secret>
- An **SSH public key** for OpenShift node access (`~/.ssh/id_ed25519.pub` or similar)
- The **`openshift-install`** binary (4.20+) on your `PATH` — download from <https://mirror.openshift.com/pub/openshift-v4/clients/ocp/>
- The **`oc`** binary on your `PATH` (same mirror)
- `terraform` ≥ 1.7 or `tofu` ≥ 1.7
- `gh` CLI authenticated (you've already done this)

### 1. Provision the cluster

```bash
cd terraform/
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: aws_region, cluster_name, base_domain, pull_secret_path, ssh_pubkey_path
terraform init
terraform plan
terraform apply
```

This will:
1. Create the VPC, subnets, IAM, Route 53 records, RDS Aurora Postgres, ECR repos
2. Generate `install-config.yaml` from the template
3. Run `openshift-install create cluster` (~30–45 min)
4. Install the OpenShift GitOps operator
5. Apply the Argo CD root Application (app-of-apps bootstrap)

After `apply` finishes you'll have:
- A live OCP 4.20 cluster
- Argo CD running, with Applications for Coder + RHAIIS + Agent Firewalls
- Coder reachable at `https://coder.<cluster-domain>`
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

### 4. Validate end-to-end

```bash
./scripts/tool-call-smoke-test.sh \
  https://vllm.<your-cluster-domain>/v1 \
  granite-3.1-8b-instruct
```

Expected: `✅ PASS: tool_calls returned ...`

### 5. Tear down

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
