# demo-aigov-rhaiis-rhsummit-2026

Reference architecture and deployable demo for the **Coder + Red Hat** booth at **Red Hat Summit + AnsibleFest 2026** (Atlanta GWCC, May 11–14).

> **Lead with AI Governance. Prove it with Developer Experience.**
> Coder + Red Hat: safe AI adoption at enterprise scale.

## What this demo proves

1. **AI agents can be governed at enterprise scale** — every model call goes through AI Gateway and every workspace egress goes through Agent Firewalls; both are auditable and policy-controlled.
2. **You can run the same architecture sovereign or cloud** — RHAIIS (Granite-3.1-8B) and Bedrock (Claude Sonnet) sit behind the same gateway; the workspace doesn't know or care which one answers.
3. **The whole stack lands on OpenShift with operators and GitOps** — no AWS-only patterns in the cluster; this same shape installs on Azure, vSphere, bare-metal, or air-gap.

## What this repo is

End-to-end IaC + GitOps to stand up a governed agentic AI coding demo on **OpenShift 4.20+ (IPI install in your AWS account)** — combining:

- **Coder Workspaces** — Terraform-defined cloud development environments on OpenShift (latest RC for full Coder Agents EA functionality)
- **Coder AI Governance Add-On** — AI Gateway (centralized LLM gateway) + Agent Firewalls (process-level egress policy) + audit trails
- **Coder Agents (Early Access)** — self-hosted agent loop running inside the Coder control plane (no LLM API keys in the workspace)
- **Coder Tasks** — background agent execution interface for Claude Code, Aider, Goose, Amazon Q, and custom agents
- **Red Hat AI Inference Server (RHAIIS)** — enterprise vLLM serving an OpenAI-compatible endpoint, latest image. (RHAIIS can also be deployed as a `ServingRuntime` inside the full Red Hat OpenShift AI [RHOAI] stack; this demo deploys the standalone RHAIIS image directly to keep operator surface area small for the booth.)
- **CloudNativePG** — in-cluster, multi-AZ Postgres for Coder via the `cloudnative-pg` operator. No RDS — the demo stays on-prem-portable.
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
| CloudNativePG | `cloudnative-pg` (channel: `stable-v1.24`) | **community-operators** — *documented exception.* Red Hat does not ship a first-party in-cluster Postgres operator; CNPG is the de facto Kubernetes-native Postgres operator (CNCF Sandbox). We pick it over RDS to keep the cluster apps on-prem-portable: the same `Cluster` CR runs on Azure / vSphere / bare-metal / air-gap with no AWS dependency. See [`gitops/operator/cnpg-subscription.yaml`](gitops/operator/cnpg-subscription.yaml) for full reasoning. |

> **Demo simplicity over hardening.** This is a booth demo, not an ATO baseline. STIG/FIPS posture, OCP `restricted-v2` SCC overrides, and air-gap config are intentionally **not** applied — they overcomplicate setup. Production architectures keep them; see [`docs/architecture.md`](docs/architecture.md) for the production narrative arc.

## Architecture at a glance

```
┌─── AWS account (your account, your region) ──────────────────────────────┐
│                                                                          │
│  ┌─ Terraform manages ─────────────────────────────────────────────────┐ │
│  │   VPC + subnets + NAT/IGW                                            │ │
│  │   IAM users (cert-manager → R53; Coder → Bedrock)                    │ │
│  │   Route 53 records (you supply hosted zone)                          │ │
│  │   OpenShift 4.20 IPI install (openshift-install via local-exec)      │ │
│  │   Operator subscriptions: GitOps + cert-manager + CloudNativePG      │ │
│  │   Cluster Secrets bootstrap (route53, bedrock, redhat-pull-secret)   │ │
│  │   Argo CD root Application (app-of-apps bootstrap)                   │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                                                          │
│  ┌─ OpenShift cluster ────────────────────────────────────────────────┐ │
│  │                                                                     │ │
│  │  ┌─ Argo CD manages (GitOps from this repo) ─────────────────────┐ │ │
│  │  │   postgres/          CNPG Cluster CR (3 instances, multi-AZ)   │ │ │
│  │  │                       → auto-generates `coder-app` Secret      │ │ │
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
       │    - build-images.yml: workspace base images → GHCR (uses GITHUB_TOKEN, no AWS creds)
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
│   ├── operator/                   # Subscriptions applied by TF before Argo CD runs
│   │   ├── openshift-gitops-subscription.yaml
│   │   ├── cert-manager-subscription.yaml
│   │   └── cnpg-subscription.yaml
│   ├── bootstrap/
│   │   └── root-app.yaml           # the one Application that fans out to all apps below
│   └── apps/
│       ├── postgres/
│       │   └── application.yaml    # CNPG Cluster CR (auto-generates `coder-app` Secret)
│       ├── cert-manager/
│       │   └── application.yaml
│       ├── coder/
│       │   └── application.yaml    # Coder Helm chart (latest RC) with AI Gov Add-On
│       ├── coder-routing/
│       │   └── application.yaml
│       └── rhaiis/
│           └── application.yaml    # RHAIIS / vLLM Deployment + Service
│
├── manifests/                      # raw Kubernetes manifests (referenced by Argo CD apps)
│   ├── postgres/
│   │   ├── namespace.yaml
│   │   └── cluster.yaml            # CNPG Cluster CR (3 instances, multi-AZ)
│   ├── cert-manager/
│   │   └── cluster-issuer.yaml
│   ├── coder/
│   │   ├── certificate.yaml
│   │   ├── ingress-wildcard-policy.yaml
│   │   └── route.yaml
│   └── rhaiis/
│       ├── namespace.yaml
│       └── vllm-deployment.yaml
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
│   ├── tool-call-smoke-test.sh        # validate RHAIIS tool-call parser end-to-end
│   ├── bootstrap-r53-delegation.sh    # cross-account R53 subdomain delegation
│   ├── aws-quota-bootstrap.sh         # compute / request / track AWS quotas
│   └── setup-demo-labels.sh           # GH labels for the sprint-ticket flow
│
└── .github/
    └── workflows/
        ├── build-images.yml        # build + push workspace base images to GHCR
        └── push-templates.yml      # `coder templates push` against the live cluster
```

## Sizing, cost, and startup time

### Recommended cluster shape: 3-node converged + optional GPU 4th node

The default we ship is a **compact 3-node OpenShift cluster** — three control-plane nodes that are also schedulable for workloads, no separate worker MachineSet (`compute.replicas: 0` in `install-config.yaml`). It preserves the full multi-AZ HA narrative (3 control-plane replicas + CNPG `instances: 3` spread across `topology.kubernetes.io/zone`) at roughly 30% of the cost of a 6-node cluster, and it's what every other reference architecture in this demo assumes.

For booth days (and on-demand testing) you can add a **4th GPU worker** to host a CUDA build of RHAIIS. Off-days, the GPU node stays at `replicas: 0` and RHAIIS runs on a CPU image on the converged nodes — no GPU charges, no demo behavior change.

| Shape | Compute (us-east-1, on-demand) | NAT GW | ~$/24h | Multi-AZ HA story | Notes |
|---|---|---|---|---|---|
| **Compact 3-node converged (recommended)** — 3 × m6i.2xlarge as CP+worker | $1.152/hr | $0.135/hr | **~$31** | ✓ | CNPG instances=3 still works; no dedicated provisioner pool |
| Compact 3 + 1 × g5.2xlarge GPU (booth days) | $2.364/hr | $0.135/hr | **~$60** | ✓ | RHAIIS on `vllm-cuda-rhel9` + `nvidia.com/gpu: 1` |
| SNO (1 × m6i.4xlarge) | $0.768/hr | $0.045/hr | ~$20 | ✗ | No HA; CNPG must collapse to instances=1; one bad node = demo dead |
| Full HA (current 3 CP + 3 worker) | $1.728/hr | $0.135/hr | ~$45 | ✓ | Dedicated provisioner pool; biggest footprint |

> **GPU vCPU is a separate AWS quota.** New accounts often start at 0 in `Running On-Demand G and VT instances vCPU` (quota code `L-DB2E81BA`). File the increase request at least a week before booth — case-based approval, not auto. `scripts/aws-quota-bootstrap.sh` files and tracks it for you.

### Lifecycle: declarative tear-down / rebuild, never `ec2 stop`

OCP doesn't tolerate `ec2 stop/start` cleanly (etcd quorum, kubelet TLS rot, IPI-managed ELBs). The right pattern for "off-hours" is `terraform destroy` + `terraform apply` on a schedule. Because nothing in `gitops/`, `manifests/`, or `coder-templates/` is account-state-dependent, every rebuild lands in the same place — Bedrock model access, R53 delegation, and GHCR images all survive a destroy.

Practical cadence for booth-prep weeks:
- **Up** — Monday morning, `terraform apply` (~60 min cold start, see table below)
- **Down** — Friday EOD, `terraform destroy` (~10 min)
- ~50 hr/week uptime on compact-3 ≈ **$65/week**, vs ~$215/week if left running 24/7.

A future commit can wrap this in `make cluster-up` / `make cluster-down` plus a GHA cron — call it out when you want it.

### Startup time (cold start to first usable workspace)

| Phase | Tool | Approx time | Notes |
|---|---|---|---|
| Quota requests (one-time, run a week ahead) | `scripts/aws-quota-bootstrap.sh request` | minutes – days | Standard vCPU often auto-approves; GPU vCPU is case-based |
| R53 cross-account delegation (one-time) | `scripts/bootstrap-r53-delegation.sh` | ~2 min total + propagation | <60s for resolver pickup once parent applies |
| Account-level prereqs (one-time per account) | `terraform/prereqs apply` | ~3–5 min | IAM users + (optional) hosted-zone create |
| Cluster install — VPC + IAM | `terraform/main.tf` (early stages) | ~3 min | BYO-VPC, NAT gateways per AZ |
| Cluster install — `openshift-install create cluster` | `terraform/main.tf` (local-exec) | **~30–45 min** | The single biggest line item; AWS image pull + bootstrap + CP nodes |
| Operator subscriptions + CRD wait | `terraform/main.tf` (gitops_bootstrap) | ~3–5 min | OpenShift GitOps + cert-manager + CNPG |
| Cluster Secrets bootstrap | same step | ~30 sec | route53-credentials, bedrock-credentials, redhat-pull-secret |
| Argo CD app-of-apps sync | Argo (autonomous) | ~3–5 min | postgres (CNPG Cluster reconcile) → coder Helm → coder-routing → rhaiis |
| TLS cert issuance (Let's Encrypt DNS-01) | cert-manager | ~2–5 min | After Coder Route exists |
| First Coder admin login + GH Actions secrets | manual + `gh secret set` | ~2 min | `CODER_URL`, `CODER_SESSION_TOKEN` |
| First template push | `.github/workflows/push-templates.yml` | ~2 min | Triggered by any `coder-templates/**` change |
| Prebuilt-Workspace warm pool ready | Coder | ~3–5 min | One-time per template |
| **First usable workspace from a fresh AWS account** | end-to-end | **~60–75 min** | Mostly the OCP installer |
| **GPU node added (booth day)** | `oc scale machineset/...` | +4–5 min | EC2 spin-up + NVIDIA driver install |

Subsequent booth-week rebuilds skip the one-time rows and land in **~50–60 min** end-to-end.

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
1. Create the BYO-VPC + IAM users (cert-manager → Route 53; Coder → Bedrock)
2. Generate `install-config.yaml` from the template
3. Run `openshift-install create cluster` (~30–45 min)
4. Apply operator subscriptions (OpenShift GitOps + cert-manager + CloudNativePG)
5. Wait for cert-manager + CNPG CRDs
6. Bootstrap cluster Secrets (`route53-credentials`, `bedrock-credentials`, `redhat-pull-secret`)
7. Apply the Argo CD root Application (app-of-apps bootstrap)

After `apply` finishes you'll have:
- A live OCP 4.20 cluster with three operators installed (GitOps + cert-manager + CNPG)
- Argo CD running, with Applications for `postgres` (CNPG Cluster) + cert-manager (ClusterIssuers) + Coder + RHAIIS + coder-routing
- Coder using a CNPG-generated `coder-app` Secret for its DB connection — no manual DB-URL plumbing
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
