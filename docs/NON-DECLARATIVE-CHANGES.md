# Non-Declarative Changes — Mid-Session Mutations + Their Declarative Form

> **Purpose**: Every state change we made during booth setup via API
> (`oc patch`, Keycloak Admin API, Coder API, GitLab Admin API) instead
> of declaratively (git → Argo CD → reconcile) is listed here, along
> with **how a fresh deploy gets the same state from git alone**.
>
> If you discover a state your cluster has that doesn't trace back to
> something in git, add it here. The goal is: a fresh catalog deploy
> from `main` should land in exactly the same state without any of
> these manual interventions.

Companion to [CATALOG-READINESS.md](CATALOG-READINESS.md) (gap analysis)
and [FRESH-ACCOUNT-BOOTSTRAP.md](FRESH-ACCOUNT-BOOTSTRAP.md)
(deployer flow).

---

## Inventory

| # | Mid-session action | Original method | Declarative form | Status |
|---|---|---|---|---|
| ND1 | Created `/auditors` Keycloak group | Admin REST API | `manifests/keycloak/realm-demo.yaml` | ✅ in git (commit `1f294c6`) |
| ND2 | Moved `bob` from `/developers` to `/auditors` | Admin REST API | Same realm yaml | ✅ in git |
| ND3 | Removed `demoadm` from `/developers` | Admin REST API | Same realm yaml | ✅ in git |
| ND4 | Deleted carol/dave Keycloak users | Admin REST API | Realm yaml has 3 users only | ✅ in git |
| ND5 | Pre-created `bob`/`alice` in GitLab + linked OIDC identity | GitLab Admin API | `scripts/gitlab-bootstrap-personas.sh` | ✅ landed on `catalog-readiness` |
| ND6 | Added `bob` as Developer to `alice/artemis-sim` + `demo/sample-app` | GitLab Admin API | Same bootstrap script | ✅ landed |
| ND7 | Created Coder org-role `developers-chat` | Coder REST API | `scripts/coder-agents-provider-model-config.sh` (run as bootstrap Job) | ✅ in git |
| ND8 | Deleted stale Coder role `developers-auditor-plus` | Coder REST API | N/A — fresh deploys never create it | ✅ no action needed |
| ND9 | Set Coder OIDC role-sync `{developers: [developers-chat]}` | Coder REST API | Same bootstrap script | ✅ in git |
| ND10 | Bound `grafana-agent` SA to `privileged` SCC | `oc create rolebinding` | `manifests/cluster-config/grafana-agent-privileged-binding.yaml` | ✅ in git (commit `4ac99a3`) |
| ND11 | Patched `grafana-agent` DaemonSet container `securityContext.privileged: true` | `oc patch` (until commit `e95603c` CronJob, then chart values) | Chart values override in `gitops/apps/observability/application.yaml` | ✅ landed on `catalog-readiness` (commit `5c0ed07`) |
| ND12 | Reduced grafana-agent DS to 1 replica + nodeSelector | `oc scale` | N/A — undone manually (back to 6 pods) | ✅ no longer present |
| ND13 | Wiped Prometheus PVC (dup-sample storm) | `oc delete pvc` | N/A — fresh deploy has empty PVC | ✅ no action needed |
| ND14 | Switched chatd openai-compat provider INT4 → FP8 URL | Coder REST API | `manifests/coder-agents-config/job.yaml` (commit `68d8005`) | ✅ in git (`PROVIDER_URL` env on Job) |
| ND15 | Disabled FP8 model-config in chatd (cost) | Coder REST API | Bootstrap Job recreates `enabled: true` on every sync; runtime-disable is acceptable for catalog | ✅ tolerable |
| ND16 | Scaled both g6e MachineSets to 0 (cost) | `oc scale` | `replicas: 0` in `manifests/machinesets/gpu-l40s-tp.yaml` + `…-fp8.yaml` | ✅ in git (commit `da48a48`) |

---

## Detail per change

### ND1–ND4 — Keycloak realm structure

**What we did mid-session:**
We restructured the demo identity model live: created an `/auditors`
Keycloak group, moved `bob` into it (he was a developer originally),
removed `demoadm` from `/developers` (he was double-membered as developer
+ admin), and deleted the unused `carol` and `dave` personas.

**Declarative form:**
[`manifests/keycloak/realm-demo.yaml`](../manifests/keycloak/realm-demo.yaml)
is the source of truth. The Keycloak operator reads this CR and imports
the realm. On a fresh deploy:
- 3 groups exist: `/admins`, `/developers`, `/auditors`
- 3 users exist: `demoadm` (in `/admins`), `alice` (in `/developers`),
  `bob` (in `/auditors`)
- All 5 OIDC clients exist (`coder`, `openshift`, `gitlab`, `grafana`,
  `kubernetes-apiserver`) with `groups` claim mapper enabled

**How to verify on a fresh deploy:**
```bash
oc -n keycloak get keycloakrealmimport demo -o yaml | grep -A3 '^      groups:'
# Should list /admins, /developers, /auditors
```

If you change personas, edit `realm-demo.yaml` and commit — the operator
reconciles on a 5 min poll cycle. **Do not** edit live via the Admin UI
or your changes will be overwritten on the next reconcile.

---

### ND5–ND6 — GitLab persona bootstrap

**What we did mid-session:**
GitLab CE has no OIDC group sync, so when bob first logged in via
Keycloak SSO he was auto-created as a regular user with **no project
memberships**. He could log in but couldn't see `alice/artemis-sim`. We
manually:
1. Pre-created the users via the GitLab Admin REST API with their
   Keycloak `preferred_username` linked as `extern_uid` + `provider:
   openid_connect`. This means when they later log in via SSO,
   GitLab's `omniauth_auto_link_user` binds the SSO session to the
   existing user.
2. Added bob as Developer (access_level 30) to relevant projects.
3. Promoted demoadm to instance admin via SQL update (already scripted
   as `scripts/gitlab-promote-demoadmins.sh`).

**Declarative form:**
[`scripts/gitlab-bootstrap-personas.sh`](../scripts/gitlab-bootstrap-personas.sh)
— idempotent, run as part of the deployer flow after GitLab is up
and Keycloak is reconciled. Inputs:
- `GITLAB_ADMIN_PAT` — admin PAT minted via `gitlab-rails runner` on
  the EC2 instance
- `GITLAB_URL` — public GitLab hostname
- Optional `DEMO_PERSONAS`, `DEMO_PROJECTS`, `DEMO_EMAIL_DOMAIN`

The script handles:
- User creation (skips if exists)
- Project membership (skips if already member or namespace owner)
- demoadm promotion (delegates to `gitlab-promote-demoadmins.sh`)

**How to verify on a fresh deploy:**
```bash
curl -sk -H "PRIVATE-TOKEN: $GITLAB_ADMIN_PAT" \
  https://gitlab.<base_domain>/api/v4/users?username=bob | jq '.[0].identities'
# Should show: [{"provider":"openid_connect","extern_uid":"bob","saml_provider_id":null}]
```

**Why isn't this a Terraform `gitlab_user` resource?**
The GitLab Terraform provider can create users but not link OIDC
identities. The `extern_uid` + `provider` pair has to be set via the
admin API (or rails console). A bash script using `curl` is the
shortest path; making this a Terraform `null_resource` with a
`local-exec` provisioner would just wrap the same `curl` calls.

---

### ND7, ND9 — Coder role + role-sync

**What we did mid-session:**
Created a custom org-level Coder role called `developers-chat` that
grants `workspace.create` + `chat.message` (everything alice needs to
demo chat + spin up workspaces, nothing more). Then set Coder's OIDC
role-sync mapping so users with Keycloak group `/developers` get
auto-assigned this role on every login.

**Declarative form:**
[`scripts/coder-agents-provider-model-config.sh`](../scripts/coder-agents-provider-model-config.sh)
— run as a Kubernetes Job
([`manifests/coder-agents-config/job.yaml`](../manifests/coder-agents-config/job.yaml))
on every Argo sync. The script is idempotent: it checks for the role
+ mapping and re-creates/updates as needed.

**Critical detail** — the Coder API for org-role creation has a quirk
documented in the [memory entry][1]: POST to `/api/v2/organizations/{id}/members/roles`
creates, PUT to `/api/v2/organizations/{id}/members/roles/{name}`
updates. PUT to the collection returns 404. The script does it right;
don't refactor it to "be cleaner."

[1]: https://github.com/coder/coder/issues/somewhere — see also our
auto-memory `coder_2_33_org_roles_endpoint.md`

---

### ND8 — Stale role cleanup

**What we did mid-session:** Deleted `developers-auditor-plus` (an
earlier name for what's now `developers-chat`). This was a one-shot
cleanup that doesn't apply to fresh deploys.

**Declarative form:** None needed. Fresh deploys never create the
stale role.

---

### ND10 — grafana-agent ServiceAccount → privileged SCC

**What we did mid-session:**
Bound the `grafana-agent` ServiceAccount (in ns `coder-observability`)
to the cluster's built-in `system:openshift:scc:privileged` SCC. Without
this, the agent pods stay in `restricted-v2` and can't read `/var/log/pods`
because their SELinux context is `container_t`, not `spc_t`.

**Declarative form:**
[`manifests/cluster-config/grafana-agent-privileged-binding.yaml`](../manifests/cluster-config/grafana-agent-privileged-binding.yaml)
— a `ClusterRoleBinding` to `system:openshift:scc:privileged`. Applied
by Argo CD via the `cluster-config` Application.

```bash
oc get clusterrolebinding grafana-agent-privileged
# Should exist
```

---

### ND11 — grafana-agent DaemonSet `privileged: true`

**What we did mid-session:**
SCC binding alone (ND10) only lets the SA *use* privileged. The agent's
DaemonSet container spec still has `privileged: false` (chart default).
We had to patch the DS:
```bash
oc -n coder-observability patch ds grafana-agent --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/securityContext","value":{"privileged":true,"runAsUser":0}}]'
```

This was the single most production-breaking thing missing from git:
without it, Loki gets zero Coder logs on a fresh deploy → all LogQL
panels show "No data" → demo looks broken.

**Declarative form:**
Chart values override in
[`gitops/apps/observability/application.yaml`](../gitops/apps/observability/application.yaml):
```yaml
helm:
  values: |
    "grafana-agent":            # subchart alias from umbrella Chart.yaml
      agent:
        securityContext:
          privileged: true
          runAsUser: 0
```

The umbrella chart is `coder-observability` from `helm.coder.com/observability`;
the dependency alias for the agent subchart is `grafana-agent` (with a
dash — must be quoted in YAML). Verified by `helm pull helm.coder.com/observability`
and reading the resulting `Chart.yaml`'s `dependencies:`.

**How to verify on a fresh deploy:**
```bash
oc -n coder-observability get ds grafana-agent \
  -o jsonpath='{.spec.template.spec.containers[0].securityContext.privileged}'
# Should print: true

# And the smoke test:
oc -n coder-observability logs ds/grafana-agent --tail=5 | grep -v 'permission denied'
```

A previous attempt used a CronJob safety net
([`grafana-agent-patcher`](../manifests/observability/grafana-agent-patcher.yaml))
that re-patched the DS every 5 min. That CronJob has been removed
(commit `70c876f`) because the chart-values approach is stable and the
CronJob added noise + privilege.

---

### ND12 — Replica reduction (reverted)

**What we did mid-session:** Briefly scaled the agent DS to 1 replica
with a nodeSelector to debug a different issue. Manually undone the
same evening.

**Declarative form:** None — DS is back to default fanout.

---

### ND13 — Prometheus PVC wipe

**What we did mid-session:** Deleted Prometheus's PVC after a duplicate
sample storm corrupted its TSDB. One-shot recovery during the booth.

**Declarative form:** None — fresh deploys start with an empty PVC.

If your deploy ever hits the same TSDB corruption, the recovery is:
```bash
oc -n coder-observability scale sts prometheus --replicas=0
oc -n coder-observability delete pvc storage-prometheus-0
oc -n coder-observability scale sts prometheus --replicas=1
```

---

### ND14 — chatd provider URL switch

**What we did mid-session:** chatd's `openai-compat` provider was
originally pointed at INT4 vLLM; mid-week we briefly switched to FP8.
This is a single column in the Coder database (`provider_id.url`).

**Declarative form:**
[`manifests/coder-agents-config/job.yaml`](../manifests/coder-agents-config/job.yaml)
has env var `PROVIDER_URL` that the bootstrap script reads, and on
every Argo sync it POSTs/PATCHes the provider via Coder API. The
canonical value is whatever's in git, so flipping between quants is a
git-edit + sync.

For the catalog, the value depends on `var.rhaiis_quant`:
- `int4` → `http://vllm-planner-tp.ocp-ai.svc.cluster.local:8000/v1`
- `fp8`  → `http://vllm-planner-tp-fp8.ocp-ai.svc.cluster.local:8000/v1`
- `none` → omit the provider entirely

The catalog default is `int4` (well-tested, lower GPU floor).

---

### ND15 — FP8 model disabled (acceptable runtime drift)

**What we did mid-session:** Toggled the FP8 model entry's `enabled`
field to `false` in chatd to stop it from selecting an unreachable
backend after we scaled the FP8 MachineSet to 0.

**Declarative form:** Not captured in git. The bootstrap Job always
sets `enabled: true`, and runtime disable is a one-row DB update.

**Why this is acceptable for catalog:**
- Fresh deploys with `var.rhaiis_quant = int4` never create the FP8
  model entry → no toggle needed.
- Fresh deploys with `var.rhaiis_quant = fp8` create the FP8 entry +
  the matching MachineSet → enabled is correct.
- Fresh deploys with `var.enable_gpu = false` skip the whole local
  inference path → no chatd model entries created.

---

### ND16 — GPU MachineSet scale=0

**What we did mid-session:** After demo, scaled both g6e MachineSets to
0 (`oc scale --replicas=0`) to save cost.

**Declarative form:** Committed `replicas: 0` in
[`manifests/machinesets/gpu-l40s-tp.yaml`](../manifests/machinesets/gpu-l40s-tp.yaml)
and `…-fp8.yaml` (commit `da48a48`).

For the catalog flow, the deployer's choice is encoded via:
- `var.enable_gpu` (bool) — Terraform conditionally creates/destroys
  the MachineSet manifests via a `dynamic_machinesets` module (TODO:
  this is P2 work; today the MachineSets are static YAML and the
  deployer must `oc scale --replicas=1` to opt in).

---

## What's NOT in this inventory

These are **non-declarative by nature**, not gaps:

- **One-shot oc debug/exec sessions** for log inspection. Read-only;
  no state change.
- **Coder workspace lifecycle events** (start/stop/delete) — these are
  user actions, not config state.
- **GitLab issue creation, labels, comments** during the demo — that
  IS the demo workflow.
- **AWS Marketplace Bedrock model subscriptions** — human-only
  per-account onboarding step. Documented in
  [`bedrock-model-sub.md`](bedrock-model-sub.md).
- **OAuth app creation in GitHub UI** — human-only per-org step.
  Documented in [`FRESH-ACCOUNT-BOOTSTRAP.md`](FRESH-ACCOUNT-BOOTSTRAP.md)
  Step 5.

If anything in those categories starts to feel automatable, write it
into a script and add an entry here.

---

## How to add new entries

When you find yourself running an `oc patch`, hitting an admin API,
or `kubectl exec` to fix something, **before walking away**:

1. Reproduce the change declaratively (chart values override,
   ConfigMap edit, RBAC manifest, etc.).
2. Commit the declarative form on `main`.
3. Add a row to the table above + a Detail section below it.
4. Rerun `make reset` (or equivalent) on a non-production cluster to
   verify the declarative form actually produces the desired state.

If you can't make it declarative (e.g. a GitHub OAuth app creation),
either:
- Write a `gh`-CLI-driven script and call it out as an interactive
  bootstrap step, OR
- Document it as a human-only step in `FRESH-ACCOUNT-BOOTSTRAP.md`.

The principle: every state in your cluster should be traceable to a
git commit. If it's not, this doc is where you mark the exception.
