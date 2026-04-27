# demo-aigov-rhaiis-rhsummit-2026

Reference architecture and demo materials for the **Coder + Red Hat** booth at **Red Hat Summit + AnsibleFest 2026** (Atlanta GWCC, May 11–14).

> **Lead with AI Governance. Prove it with Developer Experience.**
> Coder + Red Hat: safe AI adoption at enterprise scale.

## What this repo is

A reproducible reference for running a governed agentic AI coding workflow on Red Hat OpenShift — combining:

- **Coder Workspaces** — Terraform-defined cloud development environments on OpenShift
- **Coder AI Governance Add-On** — AI Gateway (centralized LLM gateway) + Agent Firewalls (process-level egress policy) + audit trails
- **Coder Agents (Early Access)** — self-hosted agent loop running inside the Coder control plane (no LLM API keys in the workspace)
- **Coder Tasks** — background agent execution interface for Claude Code, Aider, Goose, Amazon Q, and custom agents
- **Red Hat AI Inference Server (RHAIIS)** — enterprise vLLM serving an OpenAI-compatible endpoint on OpenShift, FIPS-validated, RHEL UBI base
- **OpenShift 4.14+** — RHEL UBI workspaces, OCP Routes, hardened SCCs

The demo's primary message: every developer's AI coding agent is *already* in your environment. Whether you can see it, control it, and prove it to your auditors is what's open.

## Components at a glance

| Layer | Product | Status (as of repo seed) |
|---|---|---|
| Workspace orchestration | Coder Premium on OpenShift | GA |
| LLM gateway (BYOK, audit, multi-provider) | **AI Gateway** | GA in Coder v2.30 |
| Process-level agent egress policy | **Agent Firewalls** | GA in Coder v2.30 |
| Bundled per-user license | **AI Governance Add-On** | GA in Coder v2.30 (Feb 2026) |
| Control-plane agent loop | **Coder Agents** | Early Access (`CODER_EXPERIMENTS="agents"`) |
| Background agent execution | **Coder Tasks** | GA |
| Sovereign / on-cluster inference | **Red Hat AI Inference Server (RHAIIS)** | GA |
| Substrate | **Red Hat OpenShift** 4.14+ | GA |

For up-to-date roadmap status of any specific feature, see [coder.com](https://coder.com) and the Coder release notes.

## Demo storyline (two acts, ~5 min)

**Act 1 — Governed Agentic AI (3 min)**
1. AI Gateway demo — centralized provider config (Anthropic + RHAIIS as backends), per-user token attribution, prompt audit log
2. Agent Firewalls demo — agent attempts to reach an unapproved domain, real-time deny + audit row, developer in the same workspace stays unaffected
3. Coder Agents live — control-plane agent loop, no API keys in the workspace, sub-agent delegation, user-identity attribution on every action

**Act 2 — Developer experience proof (2 min)**
1. Sprint planning automation triggers a Coder API call → Prebuilt Workspace claimed from warm pool in <60s
2. IDE launches with the right repo cloned and a Coder Task ready, governed by the Act 1 policies
3. Platform admin view: template governance, workspace observability, AI usage metrics

## Repository layout

```
.
├── README.md                  # this file
├── LICENSE                    # Apache-2.0
├── .gitignore
├── docs/
│   └── architecture.md        # reference architecture (booth + sovereign/IL5 narrative)
├── manifests/
│   ├── rhaiis/                # RHAIIS Deployment + Service exposing OpenAI-compatible API
│   │   ├── namespace.yaml
│   │   └── vllm-deployment.yaml
│   └── agent-firewalls/       # example rules file (process-level egress allowlist)
│       └── rules.example.yaml
├── helm/                      # (WIP) sanitized Helm values for Coder control plane
│   └── coder/                 # values-coderd / values-provisioners / values-observability
└── scripts/
    └── tool-call-smoke-test.sh  # verify RHAIIS tool-call parser is wired correctly
```

## Pre-flight

Before running the demo end-to-end, validate:

1. **OCP cluster** at 4.14+, with RHAIIS pull secret in the target namespace
2. **Coder v2.30+** with the AI Governance Add-On enabled
3. **Coder Agents Early Access** enabled via `CODER_EXPERIMENTS="agents"` and at least one LLM provider configured in Admin → Agents
4. **AI Gateway** configured with two providers — a cloud provider (e.g., Anthropic) and a sovereign provider pointing at RHAIIS
5. **Agent Firewalls** rules file deployed; pre-stage a deny scenario
6. **Prebuilt Workspaces** warm pool of 3 instances
7. **Tool-call smoke test:** `./scripts/tool-call-smoke-test.sh http://vllm.ocp-ai.svc:8000/v1 granite-3.1-8b-instruct` returns a non-null `tool_calls` array

## Recommended model lineup (booth defaults)

| Slot | Model | Why |
|---|---|---|
| Cloud (AI Gateway primary) | Claude Sonnet (latest) | Strongest tool-use on Chat Completions; fast for live demo beats |
| Sovereign (RHAIIS) | `ibm-granite/granite-3.1-8b-instruct` | RH-blessed, Apache-2.0, native vLLM `granite` tool-call parser, CPU-feasible |

Alternates: `Qwen/Qwen2.5-Coder-7B-Instruct` with the `hermes` parser for stronger raw coding performance; `meta-llama/Llama-3.1-8B-Instruct` with the `llama3_json` parser if you need a Llama story.

## License

Licensed under the **Apache License, Version 2.0**. See [LICENSE](LICENSE).

## Status

Pre-event scaffold. Architecture, manifests, and scripts are being authored in the run-up to Red Hat Summit 2026.
