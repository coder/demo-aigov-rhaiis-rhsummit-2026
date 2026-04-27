# Reference architecture — Coder + Red Hat: governed agentic AI on OpenShift

> Booth-grade reference architecture for the Red Hat Summit + AnsibleFest 2026 demo, plus a sovereign / air-gapped narrative arc for production deployments.

## Context

| Slot | Booth demo | Sovereign / production narrative |
|---|---|---|
| Cluster | OpenShift 4.14+ on ROSA or dedicated OCP | OpenShift on AWS GovCloud, Azure Gov, on-prem, or behind a sovereign software factory pattern (e.g., Big Bang / UDS Core) |
| Classification | Unclassified | Up to IL5 with Coder's Air-Gapped Deployments Bundle |
| Scale (concurrent workspaces) | 5–25 (warm-pool of 3) | 10K reference architecture is live; 50K reference architecture is in flight |
| Cloud-side LLM provider | Anthropic (BYOK) | Anthropic, OpenAI, Bedrock, Azure OpenAI, or any OpenAI-compatible — typically routed to a sovereign provider in regulated deployments |
| Sovereign LLM provider | Red Hat AI Inference Server (RHAIIS) on a CPU node, serving Granite-3.1-8B-Instruct | RHAIIS on GPU nodes, optionally fronted by `llm-d` for distributed serving; FIPS-validated images, RHEL UBI base |
| Pillars | Modernize-led, Multiply-centerpiece (Coder Agents EA), Migrate-substrate | Same shape; Migrate substrate becomes the dominant story in air-gap |

## High-level architecture (booth shape; same shape lands in sovereign environments)

```
┌────────────────────────────────────────────────────────────────────────┐
│  Developer / Demo Driver                                               │
│  IDE: Cursor / VS Code / Claude Code (Coder Tasks)                     │
└──────────────────┬──────────────────────────────────────┬──────────────┘
                   │ (model traffic)                      │ (workspace shell / SSH / IDE proxy)
                   ▼                                      ▼
┌──────────────────────────────┐            ┌──────────────────────────────┐
│   Coder Control Plane        │            │   OpenShift Route /          │
│   (3 coderd replicas, OCP    │            │   Coder DERP (relay-only,    │
│   Routes, hardened SCC)      │            │   direct connections off)    │
│                              │◀───────────┤                              │
│  ┌────────────────────────┐  │            └──────────────┬───────────────┘
│  │ AI Gateway             │  │                          │
│  │  · Centralized auth    │  │                          │
│  │  · BYOK / central key  │  │                          │
│  │  · Per-user attribution│  │                          │
│  │  · Routes to:          │  │                          │
│  │    - Anthropic (cloud) │  │                          │
│  │    - RHAIIS (sovereign)│  │                          │
│  └────────────────────────┘  │                          │
│  ┌────────────────────────┐  │                          │
│  │ Agent Firewalls        │  │                          │
│  │  · Process-level       │  │                          │
│  │  · Domain allowlist    │  │                          │
│  │  · Landjail (no priv)  │  │                          │
│  │  · Audit → Loki/Splunk │  │                          │
│  └────────────────────────┘  │                          │
│  ┌────────────────────────┐  │                          │
│  │ Coder Agents (EA)      │  │                          │
│  │  · Loop runs HERE      │  │                          │
│  │  · No keys in workspace│  │                          │
│  │  · User identity tied  │  │                          │
│  │    to every action     │  │                          │
│  │  · Sub-agent delegation│  │                          │
│  └────────────────────────┘  │                          │
└────────────┬─────────────────┘                          │
             │ (provisioner work via signed JWT)          │
             ▼                                            ▼
┌──────────────────────────────┐            ┌──────────────────────────────┐
│ Coder External Provisioners  │            │  Coder Workspaces (OCP pods)  │
│ N replicas, dedicated nodes  │───────────▶│   - Repo cloned (Git)        │
│ Build templates, never touch │            │   - IDE process              │
│ workspace data plane         │            │   - Coder Task agent (GA)    │
└──────────────────────────────┘            │   - Prebuilt warm pool       │
                                            └────┬─────────────────────────┘
                                                 │ (model calls leave VIA control plane,
                                                 │  not the workspace pod — Coder Agents)
                                                 ▼
┌────────────────────────────────────────────────────────────────────────┐
│  Backends                                                              │
│   · Postgres (RDS, in-cluster operator, or external HA)                │
│   · Anthropic API (cloud, BYOK)                                        │
│   · RHAIIS / vLLM serving Granite-3.1-8B-Instruct (OpenAI-compatible)  │
│   · Git host (GitHub, GitLab, on-prem)                                 │
│   · Grafana Loki (Bridge + Boundaries unified audit logs)              │
│   · Prometheus + Alertmanager                                          │
└────────────────────────────────────────────────────────────────────────┘
```

## Component inventory

| Component | Customer-facing name | Status |
|---|---|---|
| Coder server (3 replicas, hardened SCC) | Coder Premium | GA |
| External provisioners (12 replicas, dedicated nodes) | — | GA |
| AI Gateway | **AI Gateway** | GA in Coder v2.30 |
| Agent Firewalls | **Agent Firewalls** | GA in Coder v2.30 |
| AI Governance Add-On | **AI Governance Add-On** | GA in Coder v2.30 (Feb 2026) — bundles AI Gateway + Agent Firewalls + audit |
| Coder Agents | **Coder Agents** | Early Access (`CODER_EXPERIMENTS="agents"`) |
| Coder Tasks | **Coder Tasks** | GA |
| Prebuilt Workspaces | **Prebuilt Workspaces** | GA |
| Workspace template | — | OpenShift / RHEL UBI base, FIPS-validated |
| RHAIIS / vLLM | **Red Hat AI Inference Server** | GA |
| Grafana Loki / Splunk / ELK | — | unified Bridge + Boundaries log format streams here |
| Prometheus + Alertmanager | — | metrics + alerts; alert thresholds in `helm/coder/values-observability.yaml` |

## Identity & access

- **IdP (recommended):** Keycloak — matches the Big Bang / UDS Core ecosystem and aligns with the sovereign narrative. Okta is the alternate for enterprise / civilian Fed.
- **Auth:** OIDC for SSO with `offline_access` scope and `access_type=offline` for refresh tokens.
- **External Auth:** Git host integration via OIDC / OAuth (single Git host for the booth; multi-host pattern in production).
- **RBAC:** Org-level + workspace-level + AI-policy-level (Agent Firewalls). Coder Agents User role granted only to demo accounts during EA.
- **Service Account:** dedicated `coder` SA with workspace permissions, scoped to `coder-workspaces` namespace.

## Networking & egress

- **DERP relay only** (`CODER_DISABLE_DIRECT_CONNECTIONS=true`) — eliminates direct WireGuard between developer and workspace; all traffic routes via the Coder server.
- **OpenShift Routes** for ingress. Helm ingress is disabled.
- **Path apps disabled** (`CODER_DISABLE_PATH_APPS=true`) — subdomain apps only.
- **Wildcard access URL:** `*.coder.<demo-domain>` for workspace subdomain apps.
- **Strict TLS** (`CODER_STRICT_TRANSPORT_SECURITY=true`).
- **Telemetry off** (`CODER_DISABLE_NETWORK_TELEMETRY=true`, `CODER_DISABLE_USAGE_STATS=true`) — required posture for any regulated customer.
- **Egress controls / DLP:** Agent Firewalls rules file with a domain allowlist; default-deny everywhere else. See `manifests/agent-firewalls/rules.example.yaml`.

## Observability & audit

- **Workspace audit + Bridge + Boundaries unified log format** → Grafana Loki (or Splunk / ELK via the same shape).
- **Prometheus metrics:** `CODER_PROMETHEUS_ENABLE=true`, with DB metrics and agent stats enabled.
- **Alert groups:** Licenses, coderd CPU/Memory, Replicas, Workspace Build Failures, provisionerd Replicas. Thresholds in `helm/coder/values-observability.yaml`.
- **Postgres exporter** for DB observability.
- **Session tracking** for AI usage — pulls into the platform admin dashboard.

## Compliance & ATO touchpoints

- **Container security context:** `runAsNonRoot: true`, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `seccompProfile.type: RuntimeDefault`, `capabilities.drop: [ALL]`. Required for STIG'd OCP clusters and OpenShift's `restricted-v2` SCC.
- **FIPS posture:** RHEL UBI base images are FIPS-validated.
- **Air-gap path:** AI Governance Add-On Air-Gapped Deployments Bundle.
- **ATO inheritance options:** Big Bang / Platform One / UDS Core / DCCSCR for DoD; FedRAMP Moderate authorization boundary inheritance from AWS GovCloud or Azure Gov for civilian Fed.

## Inference layer — RHAIIS specifics

RHAIIS exposes the OpenAI-compatible API:

- `POST /v1/chat/completions` — Chat Completions, with `tools` / `tool_choice` for tool use
- `POST /v1/completions` — legacy text completion
- `POST /v1/embeddings`
- `GET /v1/models`

**Tool-call support is model-dependent.** vLLM ships per-model tool parsers; the launch flag must match the model:

| Parser | Models |
|---|---|
| `granite` | IBM Granite-3.x-Instruct |
| `hermes` | Qwen2.5 / Qwen2.5-Coder, OpenHermes |
| `llama3_json` | Llama-3.1+ Instruct |
| `mistral` | Mistral / Mixtral Instruct |
| `deepseek` | DeepSeek-V3 / DeepSeek-Coder-V2.5+ |

For the booth demo we use **Granite-3.1-8B-Instruct** with the `granite` parser. See `manifests/rhaiis/vllm-deployment.yaml` for the launch flags.

**Always validate with `scripts/tool-call-smoke-test.sh` before going live** — wrong parser is a silent failure mode where text returns instead of structured `tool_calls`.

## Demo-day open items

The following items are tracked in the Red Hat Summit 2026 demo plan and need to be resolved before the booth opens. Status updates will land in this repo as they're closed.

1. End-to-end validation of Coder Agents EA against RHAIIS (highest-risk demo element)
2. Decision on whether to run RHAIIS on a CPU node (Granite-3.1-8B at low concurrency) or a GPU node
3. Mock sprint trigger UI implementation (GitHub Actions, Tekton, or AAP playbook)
4. Backup video of the full two-act demo for booth network failure
5. IdP confirmation (Keycloak vs Okta)
