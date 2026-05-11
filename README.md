# demo-aigov-rhaiis-rhsummit-2026

Reference architecture + deployable demo for the **Coder + Red Hat** booth at **Red Hat Summit + AnsibleFest 2026** (Atlanta GWCC, May 11–14).

> **Lead with AI Governance. Prove it with Developer Experience.**
> Coder + Red Hat: safe AI adoption at enterprise scale.

---

## What this demo proves

1. **AI agents can be governed at enterprise scale** — every model call goes through Coder's AI Bridge (audited, policy-controlled). Every workspace egress goes through Agent Firewalls.
2. **You can run the same architecture sovereign or cloud** — RHAIIS (Llama 3.3 70B INT4, tensor-parallel) and AWS Bedrock (Claude Sonnet/Opus) sit behind the same gateway; the workspace neither knows nor cares which one answers.
3. **The whole stack lands on OpenShift with operators + GitOps** — same shape installs on Azure, vSphere, bare-metal, or air-gap.
4. **Identity is enterprise-grade** — Keycloak (RHBK) for demo personas, GitHub OAuth for admins, dual-IdP into Coder, OpenShift Console, Grafana, and GitLab.
5. **The "ticket → workspace → agent" loop is the whole demo** — open a GitLab issue, label it `coder-agent`, the bridge spawns a workspace and a Coder Agents chat that drives Llama (or Claude) to investigate and open an MR. Sub-1-minute from click to working agent.

---

## Stack at a glance

| Concern | What's deployed |
|---|---|
| **Cluster** | OpenShift 4.21 IPI on AWS, 3× `m6i.4xlarge` converged control-plane+worker, 1× `g6e.12xlarge` GPU node (4× L40S 48 GiB) |
| **GitOps** | Red Hat OpenShift GitOps (Argo CD), app-of-apps from `gitops/apps/` |
| **Coder** | Helm chart **2.33.2**, image `v2.33.2` (Coder Agents beta promoted) |
| **AI Bridge** | Centralized LLM proxy at `/api/v2/aibridge/{anthropic,openai}`. Anthropic → Bedrock via IRSA. OpenAI → central org key (`ALLOW_BYOK=false`) |
| **RHAIIS (sovereign LLM)** | vLLM 0.8.4 V0 engine on RHAIIS image `rhoai-2.20-cuda`, `RedHatAI/Llama-3.3-70B-Instruct-quantized.w4a16`, tensor-parallel-2, **32K context** — `vllm-planner-tp.ocp-ai.svc.cluster.local:8000` |
| **chatd** (Coder Agents) | Default model: Claude Sonnet 4 (Bedrock). Sovereign opt-in via `coder-agent:llama` label on issues |
| **Identity** | **Dual IdP**. Keycloak (RHBK) — `demo` realm hosts personas (alice/bob/carol/dave/demoadm). GitHub OAuth — admin tier (gated to `demo-rhsummit-users` org). |
| **SCM** | **Self-hosted GitLab CE** (`gitlab.rhsummit.coderdemo.io`, EC2 `m7a.2xlarge`, Omnibus + container registry at `registry.gitlab.rhsummit.coderdemo.io`). SSO-only login via Keycloak. GitHub login disabled, GitHub external_auth retained as optional secondary for workspaces. |
| **Issue → workspace bridge** | Go service in `services/bridge/`. GitLab Issues webhook → matches `coder-hitl` or `coder-agent[:slug]` label → spawns workspace + (optionally) Coder Agents chat. Posts comment back with URLs. |
| **Postgres** | CloudNativePG (CNPG) `Cluster` CR, 3 instances, multi-AZ. Used by Coder + Keycloak. |
| **TLS** | cert-manager + Let's Encrypt (DNS-01 via Route 53 IRSA). |
| **Observability** | coder-observability Helm umbrella: Grafana, Prometheus, Loki, Alertmanager. GPU + vLLM dashboards live in **OCP Console** (decision §29). |

Deeper architectural narrative + every decision behind these choices: [`docs/architecture.md`](docs/architecture.md), [`docs/decisions.md`](docs/decisions.md).

---

## Architecture at a glance

```
┌─── AWS account (your account, your region) ────────────────────────────────────┐
│                                                                                │
│  ┌─ Terraform (terraform/) manages ────────────────────────────────────────┐   │
│  │   VPC + subnets + NAT/IGW                                                │   │
│  │   IAM roles for IRSA (cert-manager→R53, Coder→Bedrock)                   │   │
│  │   Route 53 records                                                       │   │
│  │   OpenShift 4.21 IPI install (openshift-install)                         │   │
│  │   Operator subscriptions (GitOps, cert-manager, CNPG, NFD, NVIDIA, RHBK) │   │
│  │   GPU MachineSets (gpu-l40s-tp.yaml → 4× L40S g6e.12xlarge)              │   │
│  │   GitLab CE on EC2 (terraform/gitlab/ submodule)                         │   │
│  │   Argo CD root Application                                               │   │
│  └─────────────────────────────────────────────────────────────────────────┘   │
│                                                                                │
│  ┌─ OpenShift cluster ────────────────────────────────────────────────────┐    │
│  │                                                                        │    │
│  │  ┌─ Argo CD apps (gitops/apps/) ────────────────────────────────────┐ │    │
│  │  │   sealed-secrets       Bitnami SealedSecret controller            │ │    │
│  │  │   platform-secrets     Every sealed secret (coder/gitlab/idp/…)   │ │    │
│  │  │   cluster-config       OAuth/cluster CR (GitHub + Keycloak IdPs), │ │    │
│  │  │                        cluster-reader + monitoring-view CRBs for  │ │    │
│  │  │                        the developers group, GroupSync            │ │    │
│  │  │   keycloak-operator    RHBK operator subscription                 │ │    │
│  │  │   keycloak             Keycloak CR + demo realm (5 personas)      │ │    │
│  │  │   cert-manager         ClusterIssuers (LE + R53 DNS-01)           │ │    │
│  │  │   postgres             CNPG Cluster (3 instances, multi-AZ)       │ │    │
│  │  │   gpu-stack            NFD + NVIDIA ClusterPolicy                 │ │    │
│  │  │   rhaiis               vllm-planner-tp (Llama 70B INT4, TP-2)     │ │    │
│  │  │   coder                Helm chart 2.33.2 — dual-IdP (GitHub OAuth │ │    │
│  │  │                        + Keycloak OIDC), dual external_auth       │ │    │
│  │  │                        (slot 0 gitlab, slot 1 github)             │ │    │
│  │  │   coder-provisioner    External provisioner Deployment            │ │    │
│  │  │   coder-routing        OCP Routes + wildcard cert                 │ │    │
│  │  │   coder-workspaces     Namespace + RBAC + ghcr-pull (sealed)      │ │    │
│  │  │   coder-agents-config  Job: chatd providers + model-configs +    │ │    │
│  │  │                        system prompt + plan-mode + custom        │ │    │
│  │  │                        DemoUser role + OIDC role sync            │ │    │
│  │  │   bridge               Go service — GitLab webhook → Coder       │ │    │
│  │  │                        workspace + chat per assignee             │ │    │
│  │  │   observability        Grafana / Prom / Loki / Alertmanager      │ │    │
│  │  │                        (auth.github + auth.generic_oauth = both  │ │    │
│  │  │                        IdPs)                                     │ │    │
│  │  └──────────────────────────────────────────────────────────────────┘ │    │
│  │                                                                        │    │
│  │  Workspace templates pushed by GH Actions (push-templates.yml):       │    │
│  │   ai-dev-ocp / agents-dev-ocp / demo-ai-gov-firewall-ocp /            │    │
│  │   demo-ai-gov-no-firewall-ocp   (all four declare both external_auth) │    │
│  └────────────────────────────────────────────────────────────────────────┘    │
│                                                                                │
│  ┌─ External (same VPC, EC2) ─────────────────────────────────────────────┐   │
│  │   GitLab CE — Omnibus on m7a.2xlarge, terraform/gitlab/ module.        │   │
│  │     * gitlab.rhsummit.coderdemo.io           (UI + git)                │   │
│  │     * registry.gitlab.rhsummit.coderdemo.io  (container registry)      │   │
│  │   SSO via Keycloak realm `demo`; password login disabled.              │   │
│  └────────────────────────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────────────────────┘

   ┌────────────────────────────────┐    ┌────────────────────────────────────┐
   │  this repo                     │    │  GH Actions                        │
   │  (Terraform + GitOps mani-     │───▶│  build-images / build-bridge /     │
   │  fests + templates + bridge    │    │  push-templates                    │
   │  service + scripts)            │    │  → ghcr.io/coder/demo-aigov-rhaiis │
   └────────────────────────────────┘    └────────────────────────────────────┘
```

---

## Repository layout

```
.
├── README.md                            (you are here)
├── Makefile                             booth ops cheat sheet (reset, status, ...)
├── LICENSE                              Apache-2.0
│
├── terraform/                           AWS + OCP infra (run first)
│   ├── main.tf / network.tf / irsa.tf   VPC, IAM, OCP IPI install
│   ├── gitlab.tf + gitlab/              EC2 + EBS + Route 53 for GitLab Omnibus
│   └── prereqs/                         account-level pre-flight (R53 hosted zone, IAM)
│
├── gitops/
│   ├── operator/                        operator Subscriptions applied by TF
│   └── apps/                            Argo CD Applications (one dir per app)
│       └── application.yaml             auto-discovered by root app
│
├── manifests/                           raw YAML referenced by Argo apps
│   ├── bridge/                          bridge Deployment + Service + Route
│   ├── cluster-config/                  OAuth CR (dual IdP), RBAC bindings, GroupSync
│   ├── coder-agents-config/             chatd config Job + ConfigMap + prompts
│   ├── keycloak/                        Keycloak CR + KeycloakRealmImport (demo realm)
│   ├── machinesets/                     GPU MachineSet definitions (TP + deprecated)
│   ├── rhaiis/                          vLLM Deployments (TP prod, deprecated singles)
│   ├── secrets/                         every SealedSecret (gitops-tracked, encrypted)
│   └── observability/  cert-manager/  postgres/  gpu-stack/  ...
│
├── services/
│   └── bridge/                          Go HTTP service — GitLab webhook → Coder
│       ├── cmd/bridge/main.go
│       ├── internal/{config,webhook,coder,gitlab,handler}/
│       └── Dockerfile                   distroless static, multi-stage Go build
│
├── coder-templates/                     workspace templates pushed by push-templates.yml
│   ├── ai-dev-ocp/                      Claude/Codex/Gemini/Kiro CLIs + AI Bridge env
│   ├── agents-dev-ocp/                  Coder Agents driving server-side chatd
│   ├── demo-ai-gov-firewall-ocp/        with Boundary egress firewall
│   ├── demo-ai-gov-no-firewall-ocp/     open egress (the ungoverned story)
│   └── images/                          shared UBI9 base images + agents-config-tools
│
├── scripts/                             booth-ops helpers
│   ├── reset-demo.sh                    wipe per-event demo state (used by `make reset`)
│   ├── gitlab-create-coder-oauth-app.sh setup: Coder external_auth OAuth app in GitLab
│   ├── gitlab-register-bridge-webhook.sh setup: register bridge webhook per project
│   ├── gitlab-promote-demoadmins.sh     idempotent: promote Keycloak admins to GL admin
│   ├── render-coder-agents-configmap.sh regenerate the chatd config ConfigMap
│   └── coder-agents-provider-model-config.sh   the Job's bootstrap script (sourced)
│
├── docs/                                deeper docs (not strictly necessary to bootstrap)
│   ├── architecture.md
│   ├── decisions.md                     §1–§33 architectural decision log
│   ├── identity-architecture.md
│   ├── demo-flow-persona-setup.md       what alice runs at the booth
│   ├── maas-and-self-hosted-options.md  MaaS comparison reference reading
│   ├── aws-setup.md  /  aws-creds.md  /  secrets.md  /  team-onboarding.md
│
└── .github/workflows/                   GH Actions
    ├── build-images.yml                 UBI9 workspace base images → GHCR
    ├── build-bridge.yml                 bridge Go service → GHCR (distroless)
    └── push-templates.yml               coder templates push (all four -ocp templates)
```

---

## The booth demo flow

1. **PM (or anyone)** opens a GitLab issue in a demo project (e.g. `alice/artemis-sim`).
2. **PM assigns** the issue to a Keycloak persona (alice, bob, carol, dave).
3. **PM labels** the issue with one of:
   - `coder-hitl` → bridge spawns a workspace owned by the assignee. They open it and work manually.
   - `coder-agent` → bridge spawns a workspace AND creates a Coder Agents chat owned by the assignee, pre-seeded with the issue title + description and instructions to push a branch + open an MR.
   - `coder-agent:llama` / `:sonnet` / `:opus` → as above, but pinning the chat to that model (latest matching version wins).
4. **Bridge** sees the webhook, validates both conditions (label AND assignee), fetches issue body via its admin PAT, embeds it in the chat seed prompt, mints a per-user Coder token, creates the chat as the assignee, comments back on the issue with the workspace + chat URLs.
5. **Booth audience watches** the workspace + agent appear in the Coder UI in real time. Agent investigates, edits, pushes a branch, opens an MR.

Full walkthrough including alice's first-login steps: [`docs/demo-flow-persona-setup.md`](docs/demo-flow-persona-setup.md).
Troubleshooting matrix (the four bridge no-op reasons + their fixes): same doc.

---

## Identity

**Dual IdP** — Keycloak for demo personas, GitHub OAuth for admins. Both wired into every surface that needs auth.

| Surface | Keycloak path | GitHub path |
|---|---|---|
| Coder login | "Sign in with Keycloak" → demo realm | "Sign in with GitHub" → `demo-rhsummit-users` org |
| OpenShift Console | OAuth IdP `keycloak` (OpenID) | OAuth IdP `github` (org-filtered) |
| Grafana | `auth.generic_oauth` block | `auth.github` block |
| GitLab login | "Sign in with Keycloak" (only option — password form disabled) | n/a |
| Coder external_auth (workspace git push) | slot 0 `gitlab` (primary, demo path) | slot 1 `github` (optional secondary) |

Demo personas (`/tmp/demo-creds.md` — never in git):
- `alice / bob / carol / dave` — group `/developers` — password `Demo2026!`
- `demoadm` — groups `/developers + /admins` — password `Z7U0jeJ1m7SaYQlvGJ!K2026`

**RBAC scoping for the `developers` group:**
- **OpenShift**: `cluster-reader` + `cluster-monitoring-view` ClusterRoleBindings — see all dashboards (Observe → Dashboards including GPU + vLLM), all workloads, all events; no mutations.
- **Coder**: site-level OIDC mapping to built-in `auditor` role + per-org custom role `developers-auditor-plus` adding `workspace.create/start/stop/ssh/app_connect` + `chat.*`. (Premium-gated; both `custom_roles` and `user_role_management` license features required.)
- **Grafana**: `role_attribute_path` evaluates Keycloak `groups` claim — `admins` → Admin, anything else → Viewer.
- **GitLab**: instance admin promoted via `scripts/gitlab-promote-demoadmins.sh` (idempotent; CE has no native OIDC-group-to-admin mapping).

Full design: [`docs/identity-architecture.md`](docs/identity-architecture.md).

---

## Ops cheat sheet (`make help` for full list)

```
make reset             # interactive: list what'd be deleted, prompt y/N, then delete
make reset-plan        # dry run only
make status            # Argo apps + vLLM pods + bridge + chatd default model
make tail-bridge       # follow the bridge logs
make promote-demoadmins  # idempotent — re-promote Keycloak admins to GitLab admin
make register-webhook    # register bridge webhook on a GitLab project (DEMO_PROJECTS env)
```

`make reset` (the canonical between-visitors action):
- Deletes every Coder workspace + chat owned by the demo personas (`DEMO_PERSONAS` env, default `alice,bob,carol,dave,demoadm`).
- Deletes every GitLab issue in `DEMO_PROJECTS` env (default `alice/artemis-sim`) so the iid counter starts fresh.
- Idempotently re-promotes Keycloak admins to GitLab admin.
- Does NOT touch: Keycloak users (they live in the realm YAML), GitLab projects/repos, IaC, templates, vLLM, bridge, chatd config.

---

## Sizing + cost

| Component | Instance | Hourly | Monthly | Note |
|---|---|---|---|---|
| 3× converged control-plane + worker | m6i.4xlarge | $2.30 | $1,680 | multi-AZ |
| GPU production | g6e.12xlarge (4× L40S) | $7.45 | $5,440 | hosts Llama 70B TP-2 |
| GitLab self-hosted | m7a.2xlarge | $0.40 | $290 | Omnibus + registry + runner |
| NAT gateways (3) | — | $0.14 | $98 | one per AZ |
| EBS gp3 (~1 TiB across nodes) | — | ~$0.10 | ~$73 | |
| **Total (always-on)** | | **~$10.40/hr** | **~$7,600/mo** | |

Per-event tear-down + rebuild cadence costs ~$870/wk (50 hrs Mon–Fri uptime).

Retired (kept in git for fast-revert, scaled to 0): two single-L40S MachineSets (Qwen 32B planner + Llama experiment), `vllm-executor` (Qwen 7B on A10G). Reactivation = bump `replicas: 1` in the deprecated manifests + their MachineSets.

---

## Quickstart (fresh AWS account → live demo)

```bash
# 0. Prereqs (per AWS account, one-time)
cd terraform/prereqs/ && terraform init && terraform apply

# 1. Cluster + GitLab
cd ../ && terraform init && terraform apply         # ~45 min (OCP install + ~10 min GitLab Omnibus)

# 2. GitOps activation (after Argo CD operator is up)
./scripts/configure-manifests.sh --terraform-dir ./terraform
git commit -am "chore: configure for ${CLUSTER_FQDN}" && git push

# 3. Identity setup (after Keycloak + GitLab are healthy)
./scripts/gitlab-create-coder-oauth-app.sh             # OAuth app + sealed creds for Coder external_auth
./scripts/gitlab-promote-demoadmins.sh                 # promote demoadm to GitLab instance admin
./scripts/gitlab-register-bridge-webhook.sh            # bridge webhook on demo project(s)

# 4. Validate
make status                                            # Argo + vLLM + chatd default model
```

End-to-end from fresh AWS account: **~70–85 min** (OCP install is the long pole).
Subsequent booth-week rebuilds: ~50–60 min.

---

## Where to read next

- [`docs/decisions.md`](docs/decisions.md) — §1–§33, the architectural decision log. Start here for the "why" behind any specific choice.
- [`docs/architecture.md`](docs/architecture.md) — narrative arc of the deployed stack.
- [`docs/identity-architecture.md`](docs/identity-architecture.md) — the dual-IdP design (Keycloak + GitHub) and the demo persona role bindings.
- [`docs/demo-flow-persona-setup.md`](docs/demo-flow-persona-setup.md) — what alice (or any persona) runs end-to-end. Includes the bridge no-op matrix.
- [`docs/maas-and-self-hosted-options.md`](docs/maas-and-self-hosted-options.md) — customer-facing reading on Red Hat's MaaS path + OSS alternatives + air-gap considerations.
- [`services/bridge/README.md`](services/bridge/README.md) — bridge service reference (env vars, smoke tests, build).

---

## Status

**Booth-ready** ahead of Red Hat Summit 2026 (May 11). Live cluster running:
- Coder 2.33.2, 3× replicas, dual-IdP login (Keycloak + GitHub), dual external_auth (GitLab + GitHub).
- Llama 3.3 70B INT4 tensor-parallel-2 on the production `vllm-planner-tp` Deployment (32K context, 2× L40S).
- chatd default = Claude Sonnet 4 (Bedrock). Sovereign opt-in via `coder-agent:llama` label.
- Bridge service end-to-end functional: GitLab Issues webhook → Coder workspace + chat creation under the assignee's name.
- Identity-1 through Identity-8 complete. `make reset` flow committed.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
