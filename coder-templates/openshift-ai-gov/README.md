# Template: `openshift-ai-gov`

Coder workspace template for the Red Hat Summit 2026 booth demo. Lands a developer in an OpenShift Pod with the AI Governance Add-On wired up out of the box:

- Browser VS Code (`code-server`) on port 13337
- `OPENAI_API_BASE` exported to the in-cluster AI Gateway URL → every model call this workspace makes is governed and audited
- `OPENAI_API_KEY` set to the user's Coder session token (AI Gateway authenticates via this)
- **Agent Firewall config** bundled with the template (`config.yaml`) and mounted to `~/.config/coder_boundary/config.yaml` at workspace start by the `boundary_config_setup` coder_script — process-level egress allowlist applies as soon as the agent runs
- Workspace base image pulled from ECR (built and pushed by `.github/workflows/build-images.yml`)

## Agent Firewall (per [Coder docs](https://coder.com/docs/ai-coder/agent-firewall))

The allowlist is **template-scoped, not cluster-wide.** Edit `config.yaml` in this directory to update what agents can reach, then push the template (`coder templates push` or via the `push-templates.yml` workflow on a `coder-templates/**` change). New workspaces pick it up immediately; existing workspaces re-mount on next restart.

Rule format reference:
- `"domain=github.com"` — domain + all subdomains
- `"domain=*.github.com"` — subdomains only
- `"method=GET,HEAD domain=api.github.com"` — restrict HTTP methods
- `"method=POST domain=api.example.com path=/users,/posts"` — method + path
- `"path=/api/v1/*,/api/v2/*"` — path-only allow

Jail type is `nsjail` (default; strong bypass resistance, needs `CAP_NET_ADMIN` via OCP SCC). `landjail` requires kernel ≥ 6.7 — RHEL 9 / OCP 4.20 nodes are kernel 5.14, so it will fail at runtime.

## Parameters

| Parameter | Default | Notes |
|---|---|---|
| `cpu` | `2` | Cores (1–8) |
| `memory_gb` | `4` | Memory in GiB (2–32) |
| `image` | `openshift-ai-gov-base:latest` | ECR image tag — bump after a Dockerfile change |

## Push variables

Set these once at template push time (`-V key=value` on `coder templates push`):

| Variable | What |
|---|---|
| `namespace` | K8s namespace for workspace pods (default `coder-workspaces`) |
| `ecr_registry` | ECR registry domain — get from `terraform output -raw ecr_repo_urls` |
| `ai_gateway_url` | AI Gateway internal URL (default `http://coder.coder.svc.cluster.local:7080/v1`) |

## Push manually

```bash
coder login https://coder.<your-cluster-fqdn>
cd coder-templates/openshift-ai-gov
coder templates push openshift-ai-gov \
  --directory . \
  --variable namespace=coder-workspaces \
  --variable ecr_registry=123456789012.dkr.ecr.us-east-1.amazonaws.com \
  --variable ai_gateway_url=http://coder.coder.svc.cluster.local:7080/v1 \
  --yes
```

## Push via GH Actions

Just commit and push:

```bash
git add coder-templates/openshift-ai-gov/
git commit -m "feat(template): tweak openshift-ai-gov"
git push origin main
```

`.github/workflows/push-templates.yml` will run.
