# Catalog Readiness — Audit + Gap Analysis

> **Status as of 2026-05-17 (end of overnight Phase 0–4)**: the repo
> is **~90% catalog-ready** on branch `catalog-readiness`. P0–P2 gaps
> closed: parameterization, sealed-secret bootstrap, persona bootstrap,
> grafana-agent privileged via chart values, preflight + postdeploy
> smoke scripts, FRESH-ACCOUNT-BOOTSTRAP and NON-DECLARATIVE-CHANGES
> docs, TF vars for GPU + RHAIIS quant.
>
> Remaining open work: one-command `make catalog-deploy` target,
> automated GitHub OAuth app creation (today still manual), proper
> R53 NS-delegation flow when the parent zone lives in another
> account. See [§7](#7-what-this-branch-adds-in-priority-order) for
> the up-to-date status.

This document is the authoritative source of "what does a fresh deploy need
that isn't yet declarative." Read alongside
[`FRESH-ACCOUNT-BOOTSTRAP.md`](FRESH-ACCOUNT-BOOTSTRAP.md) (step-by-step
deployer flow) and [`NON-DECLARATIVE-CHANGES.md`](NON-DECLARATIVE-CHANGES.md)
(every API mutation we made mid-session that needs a script equivalent).

---

## 1. Variability surface

Values that change per deployment. Most are already Terraform variables;
the gap is downstream substitution into manifests/scripts.

| # | Variable | Current booth value | TF var? | Substituted into manifests? |
|---|---|---|---|---|
| V1 | `aws_region` | `us-east-1` | ✅ `var.aws_region` | Partial — `manifests/machinesets/*.yaml` hardcode `us-east-1a/1b`, `gitops/apps/coder/application.yaml` hardcodes `us-east-1` in Bedrock URL |
| V2 | `aws_account_id` | `342934376218` | ❌ (derived from STS) | Hardcoded in `gitops/apps/coder/application.yaml`, `terraform/backend.tf` (S3 state bucket), and ~4 scripts |
| V3 | `cluster_name` (TF) | `cluster` | ✅ `var.cluster_name` | Used by IRSA role names (`${cluster_name}-coder-bedrock` etc.) — works |
| V4 | `cluster_name` (OCP infraName, install-generated) | `cluster-pqc4z` | ❌ (`pqc4z` is random) | Hardcoded in `manifests/machinesets/*.yaml` (4 files) + `manifests/rhaiis/vllm-deployment.yaml` (label selector) |
| V5 | `base_domain` | `rhsummit.coderdemo.io` | ✅ `var.base_domain` | Partial — `configure-manifests.sh` handles 7 files; 18 more hardcode `rhsummit.coderdemo.io` |
| V6 | `cluster_fqdn` (`<cluster_name>.<base_domain>`) | `cluster.rhsummit.coderdemo.io` | ✅ TF output `cluster_fqdn` | Partial — same gap as V5 |
| V7 | GitLab hostname | `gitlab.rhsummit.coderdemo.io` | ✅ TF (in `terraform/gitlab/`) | Hardcoded in ~6 scripts + manifests/keycloak/realm-demo.yaml |
| V8 | Image registry | `ghcr.io/coder/demo-aigov-rhaiis-rhsummit-2026` | Per-template `var.image_registry` default | Bridge `manifests/bridge/deployment.yaml` hardcodes; templates default but accept override |
| V9 | GitHub OAuth org | `demo-rhsummit-users` | ❌ | Hardcoded in `manifests/cluster-config/oauth-cluster.yaml`, `gitops/apps/coder/application.yaml`, `gitops/apps/observability/application.yaml` |
| V10 | GitLab Coder external_auth REGEX | `gitlab\.rhsummit\.coderdemo\.io` | ❌ | Hardcoded in `gitops/apps/coder/application.yaml` |
| V11 | Coder OIDC issuer URL (Keycloak host) | `https://keycloak.apps.cluster.rhsummit.coderdemo.io/realms/demo` | ❌ | Hardcoded in `gitops/apps/coder/application.yaml`, `gitops/apps/observability/application.yaml`, `manifests/cluster-config/oauth-cluster.yaml`, `manifests/keycloak/realm-demo.yaml` |

### Files with `rhsummit.coderdemo.io` (25 total — full list)

Already handled by `scripts/configure-manifests.sh`:
- `manifests/cert-manager/cluster-issuer.yaml`
- `manifests/cert-manager/platform-certs.yaml`
- `manifests/coder/certificate.yaml`
- `manifests/coder/route.yaml`
- `manifests/observability/certificate.yaml`
- `manifests/observability/route.yaml`
- `gitops/apps/coder/application.yaml` (partial — only the route hostname, not OIDC/wildcard)
- `gitops/apps/observability/application.yaml` (partial — only `root_url`, not OIDC URLs)

**NOT** handled by configure-manifests.sh (these are the gaps):
- `manifests/bridge/route.yaml`
- `manifests/bridge/deployment.yaml` (env vars)
- `manifests/cluster-config/oauth-cluster.yaml` (Keycloak OIDC issuer URL)
- `manifests/keycloak/keycloak.yaml` (Keycloak Operator's CR — TLS hostname)
- `manifests/keycloak/route.yaml`
- `manifests/keycloak/realm-demo.yaml` (user emails, OAuth client redirect URIs)
- `scripts/gitlab-register-bridge-webhook.sh`
- `scripts/gitlab-create-coder-oauth-app.sh`
- `scripts/fix-bedrock-irsa.sh`
- `scripts/reset-demo.sh`
- `services/bridge/internal/config/config.go` (default `CODER_PUBLIC_URL`)
- `services/bridge/internal/handler/handler.go` (any default fallback)
- `terraform/gitlab/main.tf`, `terraform/gitlab/variables.tf` (GitLab subdomain default)
- `terraform/main.tf` (Bedrock region constants?)

Plus the broader OIDC/wildcard refs in `gitops/apps/coder/application.yaml` and
`gitops/apps/observability/application.yaml` that the existing script's regex
doesn't catch.

---

## 2. Per-deploy SealedSecrets

Every redeploy needs 14 SealedSecrets created with fresh values. The current
process: deployer mints credentials, seals each one with the cluster's
sealed-secrets controller cert, commits the sealed YAML into
`manifests/secrets/`.

| Secret | Namespace | What it holds | How to mint |
|---|---|---|---|
| `coder-secrets` | `coder` | `github-client-id`, `github-client-secret`, `openai-api-key` | Create GH OAuth app (org-restricted), generate OpenAI API key |
| `github-oauth-client-secret` | `openshift-config` | OCP cluster OAuth GH client secret | Same GH OAuth app as above, OR a separate one for OCP if isolation desired |
| `keycloak-openshift-oidc-secret` | `openshift-config` | Keycloak `openshift` client secret | Reads from `realm-demo.yaml` literal (booth-grade hardcoded; OK to keep) |
| `grafana-github-oauth` | `coder-observability` | `GF_AUTH_GITHUB_CLIENT_ID/_SECRET` | Same GH OAuth app or separate |
| `keycloak-grafana-oidc-secret` | `coder-observability` | Keycloak `grafana` client secret | Reads from `realm-demo.yaml` literal |
| `secret-postgres` | `coder-observability` | `PGPASSWORD` for grafana → postgres datasource | Copy from CNPG-generated `coder-app` secret in `coder` ns |
| `ghcr-pull` | `coder-workspaces` | GHCR pull secret for workspace images | GitHub PAT with `read:packages` |
| `bridge-webhook-secret` | `coder` | GitLab → bridge shared secret | `openssl rand -hex 32` |
| `coder-admin-token` | `coder` | Coder owner session token | Mint via Coder API after Coder starts |
| `coder-provisioner-key` | `coder` | External provisioner key | Mint via Coder admin |
| `gitlab-bridge-pat` | `coder` | GitLab admin PAT (the bridge uses this to create issues/comments/users) | Manual: `gitlab-rails runner` on GitLab EC2 |
| `gitlab-coder-external-auth` | `coder` | Coder external_auth GitLab OAuth app `client_id`/`client_secret` | `scripts/gitlab-create-coder-oauth-app.sh` (automated) |
| `github-group-sync-token` | `group-sync-operator` | GH PAT for redhat-cop group-sync-operator | GitHub PAT with `read:org` |
| `redhat-pull-secret` | `ocp-ai` | Red Hat Registry pull secret for RHAIIS image | Manual: `oc create secret docker-registry redhat-pull-secret …` |

**Gap**: there's no scripted `scripts/bootstrap-sealed-secrets.sh` that walks
the operator through minting each value + sealing it. Today this is
prose-only documented in [`docs/secrets.md`](secrets.md). A catalog
deployer has to assemble all 14 inputs manually.

**Recommendation**: write `scripts/bootstrap-sealed-secrets.sh` that:
1. Prompts for / reads from env each input
2. Validates (e.g. GH OAuth app callback URL matches cluster FQDN)
3. Calls `kubeseal` to produce the sealed YAML
4. Writes to `manifests/secrets/` ready to commit

---

## 3. Non-declarative mid-session changes

These are mutations made via API during the booth that ALSO need to be
captured declaratively. Some are already in scripts; others aren't.

| # | Change | Made via | Captured in git? | Gap |
|---|---|---|---|---|
| ND1 | Created `/auditors` Keycloak group | Keycloak Admin API | ✅ in `manifests/keycloak/realm-demo.yaml` (commit `1f294c6`) | None — fresh realm import will create it |
| ND2 | Moved `bob` from `/developers` to `/auditors` | Keycloak Admin API | ✅ realm-demo.yaml has bob in `/auditors` | None — fresh import works |
| ND3 | Removed `demoadm` from `/developers` | Keycloak Admin API | ✅ realm-demo.yaml | None |
| ND4 | Deleted carol/dave from Keycloak | Keycloak Admin API | ✅ realm-demo.yaml (they're not in the import) | None |
| ND5 | Pre-created `bob` user in GitLab + linked Keycloak OIDC identity | GitLab Admin API | ❌ | **GAP**: no script. Need `scripts/gitlab-bootstrap-personas.sh` |
| ND6 | Added `bob` as `Developer` (level=30) to `alice/artemis-sim` + `demo/sample-app` | GitLab Admin API | ❌ | Same gap as ND5 |
| ND7 | Created Coder `developers-chat` org role | Coder API | ✅ in `scripts/coder-agents-provider-model-config.sh` | None — bootstrap Job creates it |
| ND8 | Deleted Coder `developers-auditor-plus` (stale name) | Coder API | ❌ | Fresh deploys never have this; no cleanup needed |
| ND9 | Set Coder OIDC role-sync mapping `{developers: [developers-chat]}` | Coder API | ✅ in `coder-agents-provider-model-config.sh` | None |
| ND10 | Bound `grafana-agent` SA to `privileged` SCC | RBAC ClusterRoleBinding | ✅ in `manifests/cluster-config/grafana-agent-privileged-binding.yaml` | None |
| ND11 | Patched `grafana-agent` DaemonSet container `securityContext.privileged: true` | `oc patch` | ❌ in git | **GAP**: chart-managed; on fresh deploy the DS won't have privileged=true → /var/log/pods unreadable → no Loki ingest → all LogQL dashboards "no data". See "Critical gaps" below. |
| ND12 | Reduced grafana-agent DS to 1 replica via nodeSelector | `oc patch` | RECTIFIED — back to 6 pods | None active |
| ND13 | Wiped Prometheus PVC (dup-sample storm cleanup) | `oc delete pvc` | N/A (one-shot recovery) | None — fresh deploy has empty PVC |
| ND14 | Switched chatd's openai-compat provider from INT4 → FP8 URL | Coder API | ✅ in `manifests/coder-agents-config/job.yaml` (commit `68d8005`) | **DECISION POINT**: catalog should probably default to INT4 (simpler, faster startup). Make a TF/env var `rhaiis_quant=int4\|fp8`. |
| ND15 | Disabled the FP8 model-config (cost) | Coder API | ❌ in git (it's a runtime DB row) | Bootstrap Job re-creates with `is_default: false` AND `enabled: true` on every sync. The "enabled=false" choice from cost-saving is purely runtime. Acceptable for catalog. |
| ND16 | Scaled both g6e MachineSets to 0 (cost) | `oc scale` + edited YAML | ✅ `replicas: 0` in committed manifests (commit `da48a48`) | None — fresh deploy starts at 0 (catalog should make GPU presence a var) |

### Critical gaps to fix before catalog-grade

The two blocking issues for "fresh deploy works end-to-end":

**G1. grafana-agent privileged DS (ND11)** — the live patch isn't in git.
Without it, on a fresh deploy:
- `/var/log/pods` is unreadable by the agent's `container_t` SELinux context
- No Coder server logs reach Loki
- The Agent Firewall dashboard and any LogQL panel reads "No data"
- Symptom indistinguishable from "the demo is broken"

**Fix**: add the chart-values override in `gitops/apps/observability/application.yaml`.
The umbrella chart's grafana-agent subchart key is unknown — see
[Investigation needed](#investigation-needed) below. If we can't find the
chart key, the fallback is a Kustomize patch in `manifests/observability/`
applied as a second source on the Argo Application.

**G2. GitLab persona bootstrap (ND5/ND6)** — no script creates `bob` in GitLab
or assigns him `Developer` on demo projects. On a fresh deploy, bob exists in
Keycloak but not in GitLab; first GitLab login auto-creates him as a regular
user with NO project membership; PM workflow breaks.

**Fix**: write `scripts/gitlab-bootstrap-personas.sh` that, given a GitLab
admin PAT:
1. Pre-creates `alice`, `bob`, `demoadm` with Keycloak OIDC identity link
2. Adds `bob` as `Developer` to all projects under the `demo` group + `alice/`
3. Promotes `demoadm` to instance admin (already exists as `gitlab-promote-demoadmins.sh`)

---

## 4. AWS resources outside Terraform

I couldn't query the live AWS account tonight (CLI creds expired), so this
section is sourced from `terraform/*.tf`. Should be re-verified once creds
are back.

Per `terraform/irsa.tf`, the **only** IAM roles outside the openshift-install
ccoctl set are:
- `aws_iam_role.cert_manager` (`{cluster_name}-cert-manager-route53`) — for cert-manager DNS-01 challenges
- `aws_iam_role.coder_bedrock` (`{cluster_name}-coder-bedrock`) — for Coder server's IRSA to Bedrock

Both have inline policies (`route53:ChangeResourceRecordSets`, `bedrock:Invoke*`).
On a fresh deploy, Terraform creates them under `/demo/` path with the
cluster_name-derived ARN. The hardcoded ARN in
`gitops/apps/coder/application.yaml:385`
(`arn:aws:iam::342934376218:role/demo/cluster-coder-bedrock`) needs to be
templated to `arn:aws:iam::${aws_account_id}:role/demo/${cluster_name}-coder-bedrock`.

**Recommendation**: extend `scripts/configure-manifests.sh` to substitute
this ARN from the Terraform output `aws_account_id` (need to add this as
an output if not present).

### Other AWS resources

- **VPC + subnets**: created by Terraform (`terraform/network.tf`). Outputs
  passed to openshift-install. No manual changes.
- **Route 53 hosted zone**: created by Terraform prereqs or pre-existing —
  documented; assume deployer brings their own zone.
- **S3 buckets**: tfstate bucket (`terraform/backend.tf`) is hardcoded
  with the demo account ID. **GAP**: needs templating + bootstrap step
  for the catalog deployer's account.
- **OIDC provider for STS**: created by `ccoctl` (openshift-install).
- **GitLab EC2 instance**: Terraform (`terraform/gitlab/`).
- **Bedrock model subscriptions**: per-account marketplace subscriptions
  needed for the inference profiles in
  `scripts/coder-agents-provider-model-config.sh`. Documented in
  `bedrock-model-sub.md`. **No declarative analog** — AWS Marketplace
  subscribe is human-only.

---

## 5. Investigation needed

Things I'd want to dig deeper into before declaring catalog-ready, but
need either AWS access or time I don't have tonight:

1. **Umbrella chart's `grafana-agent` values key**. The chart is
   `coder-observability` from `helm.coder.com/observability`. The
   subchart's name is `grafana-agent`. Need to either pull the umbrella
   chart locally (`helm pull helm.coder.com/observability`) and grep
   for the subchart's name, OR find the right top-level key in our
   existing `gitops/apps/observability/application.yaml` values block.
   This determines whether we can fix G1 via chart values vs. a
   Kustomize post-render patch.

2. **AWS Cost Explorer breakdown** — would let us validate the cost
   estimates in this doc against actual booth spend.

3. **`pkgconf-pkg-config` vs `pkg-config` on UBI9.7** — already fixed
   in `coder-templates/images/ubi9-node-workspace/Dockerfile` but worth
   verifying nothing else expects the bare `pkg-config` name.

4. **The "experimental" + plain `gpu-l40s` MachineSets** (`gpu-l40s.yaml`,
   `gpu-l40s-experiment.yaml`) at `replicas: 0`. They're vestigial from
   earlier g5/g6e iterations. Recommend deleting from the repo entirely
   in a future cleanup PR — not load-bearing.

---

## 6. Suggested catalog flow for a new deployer (target end state)

This is what we're aiming for once the gaps are closed:

```bash
# 0. Fork the repo + clone
git clone https://github.com/<your-org>/<your-fork>.git
cd <your-fork>

# 1. Fill in 8-10 values
cp catalog-config.env.example catalog-config.env
vim catalog-config.env       # base_domain, AWS profile, GH org, etc.

# 2. Bootstrap (the script handles the whole flow)
./scripts/catalog-preflight.sh       # checks creds, quotas, OAuth apps, etc.
./scripts/catalog-bootstrap.sh       # terraform + manifests + sealed-secrets + bootstrap Job
./scripts/catalog-postdeploy-smoke.sh # verifies Coder login, bridge webhook, dashboard data

# 3. Done.
```

Today's reality:
- Steps 0-1: exist (terraform/terraform.tfvars.example covers core TF
  inputs)
- Step 2: split across `terraform apply`, `scripts/configure-manifests.sh`,
  `git push`, `oc apply gitops/bootstrap/root-app.yaml`, manual
  SealedSecret sealing, manual GH OAuth app creation. Probably 2-3
  hours of operator work to get through.
- Step 3 (preflight + smoke): doesn't exist yet.

The work in this branch (`catalog-readiness`) closes those gaps.

---

## 7. What this branch adds (in priority order)

Status as of end of overnight session 2026-05-17:

1. ✅ **(P0) Extend `scripts/configure-manifests.sh`** to cover all 25
   hostname refs + AWS account ID + cluster infraName. (commit `5c0ed07`)
2. ✅ **(P0) `grafana-agent` chart values override** — DS comes up
   privileged on fresh deploy via `gitops/apps/observability/application.yaml`
   helm values block. (commit `5c0ed07`)
3. ✅ **(P0) `scripts/gitlab-bootstrap-personas.sh`** (alice, bob,
   demoadm + project membership + admin promotion). Idempotent. Tested
   against booth cluster. (commit `5c0ed07`)
4. ✅ **(P1) `scripts/bootstrap-sealed-secrets.sh`** — 14-secret
   interactive walkthrough with auto-derive of Keycloak client secrets
   from realm-demo.yaml, CNPG-password from coder/coder-app, and
   bridge-webhook-secret via openssl. (commit `b800400`)
5. ✅ **(P1) `scripts/catalog-preflight.sh`** — tooling versions, AWS
   auth, region/quota, R53 zone, GH org access, Bedrock model
   availability. Tested live. (commit `b6db0b0`)
6. ✅ **(P1) `scripts/catalog-postdeploy-smoke.sh`** — cluster +
   Argo health, Coder API + OIDC, Bridge healthz, GitLab + persona
   identities, chatd providers, Loki ingest probe (catches ND11
   grafana-agent regressions). Tested live. (commit `b6db0b0`)
7. ✅ **(P2) TF `enable_gpu` + `rhaiis_quant`** — catalog defaults
   to no GPUs (~$3/hr) for cheap deploys; opt in via tfvars.
   (commit `35b5bfd`)
8. ✅ **(P2) `docs/FRESH-ACCOUNT-BOOTSTRAP.md`** — operator-facing
   10-step deployer flow with inputs table, tooling install, OAuth
   apps, smoke test. (commit `b8f5cd2`)
9. ✅ **(P2) `docs/NON-DECLARATIVE-CHANGES.md`** — ND1–ND16 with
   declarative form + verify command for each. (commit `b8f5cd2`)
10. ⏳ **(P2) `make catalog-deploy`** wrapper target — not yet
    written; preflight → tf apply → configure-manifests → bootstrap
    secrets → root-app apply → wait → postdeploy smoke. Achievable
    in <100 LOC of Makefile + bash glue.
11. 🔻 **(P3) Delete vestigial MachineSets** (`gpu-l40s.yaml`,
    `gpu-l40s-experiment.yaml`) — deferred; their headers
    intentionally call them archival, and they cost nothing at
    `replicas: 0`. Future cleanup PR.

---

## 8. Honest assessment

With this branch landed, the catalog flow is **1-checklist** (not 1-click):
operator follows `docs/FRESH-ACCOUNT-BOOTSTRAP.md`, runs ~6 commands,
fills in ~10 values. Expected total wall time from a fresh AWS account
to "alice opens a workspace via the bridge": **~90 min**, of which
**~20 min is active typing** and the rest is `terraform apply` +
openshift-install + Argo reconcile + image pulls.

True 1-click needs item #10 (the `make catalog-deploy` wrapper),
which orchestrates preflight → tf apply → configure-manifests →
bootstrap-sealed-secrets → root-app apply → reconcile-wait →
postdeploy smoke. Reasonable to land in a follow-up; not required
for catalog viability since each step is already individually
idempotent and the docs spell out the order.

What's NOT solvable without external automation:
- **GitHub OAuth app creation** — requires a human in the GitHub UI
  unless you set up GitHub App creation manifests (which themselves
  require a user-level installation). Manual remains the right answer.
- **Bedrock Marketplace subscription** — first-time-per-account
  human flow. Documented; not automatable.
- **R53 NS delegation** when the parent zone is in a different
  account — needs cross-account credentials the catalog doesn't have.
  Documented as a pre-flight step the deployer handles out of band.
