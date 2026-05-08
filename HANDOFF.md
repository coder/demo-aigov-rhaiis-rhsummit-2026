# Handoff — 2026-05-07 (eve) → 2026-05-08 (morning)

You're switching to kiro-cli to set up AWS Bedrock. This is everything that landed in this Claude Code session, where it lives in the repo, and what to watch for.

## What's running on the cluster right now

| App | State | Notes |
|---|---|---|
| `coder` | 3/3 Running, 1 per AZ | https://coder.apps.cluster.rhsummit.coderdemo.io |
| `coder-provisioner` | 6/6 Running, 2 per AZ | All registered idle with key `rhsummit-demo` |
| `rhaiis` (vLLM) | 1/1 on GPU node | `quay.io/modh/vllm:rhoai-2.20-cuda`, ibm-granite/granite-3.1-8b-instruct loaded; `/v1/chat/completions` verified |
| `coder-observability` | 17 pods Running | https://graf-coder.apps.cluster.rhsummit.coderdemo.io |
| `sealed-secrets` | Healthy | Bitnami controller in `sealed-secrets` ns |
| `cluster-config` | Healthy | NEW — owns `Scheduler/cluster` for converged-mode |
| `group-sync-operator` | Healthy | NEW — syncs GitHub admin team into OpenShift Group |
| All others | Healthy | (cert-manager, postgres, gpu-stack, platform-secrets, root) |

A few apps still flag `OutOfSync/Healthy` (sealed-secrets, cluster-config, coder-routing, coder-observability). All cosmetic — `argocd app diff` is empty for them. Documented in MORNING_REPORT.md.

## What I built

### 1. Sealed Secrets rollout (the runbook this session opened with)
- Bitnami Sealed Secrets controller running in `sealed-secrets/`. Sealing key `sealed-secrets-key5s6vc` — you have the YAML in 1Password.
- Three sealed secrets in the repo: `manifests/secrets/{coder-secrets,coder-provisioner-key,grafana-github-oauth,github-oauth-client-secret,github-group-sync-token,secret-postgres}.yaml`. All decrypt cleanly.
- Rollout runbook `docs/sealed-secrets-rollout.md` was deleted on completion (the plan said to).

### 2. Cluster-config Argo app — converged-mode finally enforced
Decision #2 says "converged" but the cluster shipped with `mastersSchedulable: false` and master taints. Apps were papering over with tolerations.
- New `gitops/apps/cluster-config/application.yaml` (sync wave -2)
- `manifests/cluster-config/scheduler.yaml` with `mastersSchedulable: true` (SSA on the singleton CR — installer keeps the rest)
- Masters now also carry the `node-role.kubernetes.io/worker` label (cosmetic; makes node-selectors targeting `worker` work)
- Master tolerations stripped from `coder` and `coder-provisioner` chart values — single source of truth is the Scheduler CR

### 3. OpenShift GitHub IdP (decision #21)
- New OAuth app for OpenShift (separate from Coder's — single callback URL per app on GitHub)
- `manifests/cluster-config/oauth-cluster.yaml` patches the cluster `OAuth/cluster` CR with a GitHub IdP (org filter: `demo-rhsummit-users`, mappingMethod: `claim`)
- `redhat-cop/group-sync-operator` installed via OLM (Subscription + OperatorGroup in `group-sync-operator` ns) — `gitops/apps/group-sync-operator/application.yaml`
- `manifests/cluster-config/group-sync.yaml` — `GroupSync` CR polls the `admin` team every 5 min, materializes OpenShift `Group/admin`
- `manifests/cluster-config/cluster-admin-binding.yaml` — `ClusterRoleBinding` mapping `Group/admin` → `cluster-admin`
- Verified: `oc auth can-i '*' '*' --as ausbru87 --as-group admin` returns yes
- **Coder Owner role is NOT auto-synced** — Coder's GitHub OAuth doesn't have a team→role hook. Documented manual elevation step in `docs/secrets.md`: `coder users edit-roles <username> --roles owner`

### 4. coder-observability translated k3s → OCP (decision #22)
The chart was OutOfSync/Degraded for 5 hours when I started. Five distinct issues.

- **SCC compliance** — every subchart hardcoded a UID outside the namespace's `openshift.io/sa.scc.uid-range` (1000800000/10000). Two patterns applied: nullify (let SCC inject) where the chart's schema is permissive, pin to `1000800000` where the schema strict-types as integer. Detailed in `gitops/apps/observability/application.yaml` comments and decision §22.
- **DNS** — Loki's nginx gateway hardcodes `kube-dns.kube-system` as the resolver. Override `loki.global.dnsService=dns-default` / `loki.global.dnsNamespace=openshift-dns`.
- **Docker Hub rate limits** — memcached → `mirror.gcr.io/library/memcached`. memcached-exporter and `burningalchemist/sql_exporter` have no published mirror; both disabled.
- **`grafana-agent` hostPath** — restricted-v2 blocks hostPath; `manifests/observability/grafana-agent-scc.yaml` binds the agent SA to `hostmount-anyuid`.
- **GitHub OAuth into Grafana** — sealed `manifests/secrets/grafana-github-oauth.yaml`; `grafana.ini.auth.github.role_attribute_path` maps `@demo-rhsummit-users/admin` to Admin, everyone else Viewer. One team membership covers OpenShift cluster-admin AND Grafana Admin.
- **Route + Cert** — `https://graf-coder.apps.cluster.rhsummit.coderdemo.io` with cert-manager-issued LE cert via DNS-01.

Plus **two more bugs** the user (you) caught after I'd written the morning report:
- **AI Bridge dashboard wasn't loading.** Two dashboard provisioning providers (`sidecarProvider` from grafana subchart's auto-gen + `sidecar` from umbrella chart) were both reading `/tmp/dashboards`, every UID inserted twice → Grafana disabled writes for both providers → no dashboards landed. Fix: `grafana.sidecar.dashboards.SCProvider: false` to skip the auto-gen file. Single provider, dashboards land.
- **`Postgres` panel showed DOWN on the Coder Status dashboard.** It queries `pg_up` from postgres-exporter, which I'd disabled. Re-enabled `global.postgres.exporter.enabled` + `mountSecret: "secret-postgres"`. The same Sealed Secret feeds both the AI Bridge dashboard's Grafana datasource AND the postgres-exporter. `pg_up = 1` confirmed in Prometheus.

### 5. RHAIIS — already healthy, no changes needed
- Pod on the GPU worker `ip-10-0-7-41` (us-east-1a)
- Image: `quay.io/modh/vllm:rhoai-2.20-cuda` (the no-subscription path; the `registry.redhat.io` alternative needs an RHOAI SKU on the partner pull secret)
- End-to-end smoke test passed: `curl http://vllm.ocp-ai.svc.cluster.local:8000/v1/chat/completions` returns coherent output

## Where things live

```
docs/
  decisions.md          §2 (converged + scheduler patch),
                        §19 (sealed secrets + Notes for OCP compat & registry),
                        §21 (OCP GitHub IdP + group-sync),
                        §22 (observability translation)
  secrets.md            Per-secret seal/rotate workflow, plus
                        "Granting Coder Owner" manual step

gitops/apps/
  cluster-config/         NEW — scheduler + OAuth/cluster + group-sync + CRB
  coder/                  master toleration removed
  coder-provisioner/      master toleration removed; replicas=6; topology spread
  group-sync-operator/    NEW — Subscription + OperatorGroup
  observability/          k3s→OCP translation lives in application.yaml comments
  sealed-secrets/         podSecurityContext disable + GHCR image override

manifests/
  cluster-config/         Scheduler, OAuth/cluster, GroupSync, CRB
  group-sync-operator/    Namespace, OperatorGroup, Subscription
  observability/          Route, Certificate, dashboard ConfigMaps,
                          postgres-datasource ConfigMap,
                          grafana-agent-scc.yaml
  secrets/                All SealedSecrets

MORNING_REPORT.md       Written ~06:45 UTC, has verification commands
HANDOFF.md              This file
```

## Auth/credential reminders

These ended up in chat history during the session — you may want to **rotate post-demo**:

- **GitHub OAuth client secret for Coder** (`coder-secrets`) — pasted via the asterisk-input script, plaintext shredded but values were entered while the script was capturing
- **GitHub OAuth client secret for OpenShift IdP** — pasted via asterisk script, sealed
- **GitHub OAuth client secret for Grafana** (`Ov23liDH5JtpgNpNgKvn` / `f37679...`) — you pasted in chat directly
- **Coder API token** (`vTVuC...`) — pasted in chat for me to mint the provisioner key
- **Coder provisioner key plaintext** — leaked into output (the new Coder CLI prints it on a bare line; my filter missed it). Rotation: `coder provisioner keys delete rhsummit-demo` + re-mint + re-seal.
- **GitHub PAT for group-sync-operator** (`read:org`) — sealed via script

## What's deferred / still TODO

Listed here in case you want to come back to them; none block the demo:

- `sql-exporter` (Coder-specific Postgres SQL business metrics) — image is DH-only with no upstream mirror. Mirror to GHCR/Quay if you want those metrics back.
- `memcachedExporter` (loki cache self-metrics) — same story.
- `postgres-exporter` reports a benign `permission denied for function pg_ls_waldir` — the `coder` SQL user isn't a superuser, so a few WAL collectors can't run. `pg_up` and the standard postgres metrics work fine. Fix would be `GRANT pg_read_server_files TO coder` or run the exporter as a different user.
- `coder-observability` has a phantom orphan PVC named `grafana` — the chart's render produces both a standalone PVC AND a volumeClaimTemplate, the former is unbound. Functionally inert; tried deleting once and Argo recreates.
- **Bedrock IAM role + IRSA** — explicitly your next task. The Coder server is already configured with `CODER_AIBRIDGE_ENABLED=true` + `AWS_REGION=us-east-1` and the `coder-server` ServiceAccount is set up to be IRSA-annotated. AI Bridge picks Bedrock up via the AWS SDK credential chain — no static keys needed once IRSA wires the role.

## How to verify everything is still healthy after I'm gone

```bash
export KUBECONFIG=/tmp/kubeconfig

oc get applications -n openshift-gitops    # all should be Synced/Healthy or have a documented OutOfSync
oc get pods -A | grep -vE "Running|Completed"   # nothing unhealthy

curl -sf -o /dev/null -w "%{http_code}\n" https://coder.apps.cluster.rhsummit.coderdemo.io/healthz
curl -sf -o /dev/null -w "%{http_code}\n" https://graf-coder.apps.cluster.rhsummit.coderdemo.io/api/health

# Provisioners idle
coder login --token vTVuCCHlPn-wlR3uaGfBneCbKBnbCuDV5 --url https://coder.apps.cluster.rhsummit.coderdemo.io
coder provisioner list

# RHAIIS smoke (full script in MORNING_REPORT.md)
oc apply -n ocp-ai -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata: { name: vllm-smoketest, namespace: ocp-ai }
spec:
  restartPolicy: Never
  containers:
    - name: c
      image: curlimages/curl:latest
      command: ["sleep","60"]
      securityContext:
        allowPrivilegeEscalation: false
        runAsNonRoot: true
        capabilities: { drop: [ALL] }
        seccompProfile: { type: RuntimeDefault }
YAML
oc wait pod/vllm-smoketest -n ocp-ai --for=condition=Ready --timeout=30s
oc exec -n ocp-ai vllm-smoketest -- curl -sf -X POST \
  http://vllm.ocp-ai.svc.cluster.local:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"ibm-granite/granite-3.1-8b-instruct","messages":[{"role":"user","content":"hi"}],"max_tokens":10}'
oc delete pod vllm-smoketest -n ocp-ai --grace-period=1
```

## Bedrock context for the next session

When you set up IRSA → Bedrock:

- Coder ServiceAccount is `coder-server` in the `coder` namespace. The Coder Helm values already have `serviceAccount.name: coder-server`.
- The cluster runs in STS/Manual credentials mode (decision #10). `ccoctl` was used at install time. The pattern for adding a new IRSA role is: create the IAM role with a trust policy keyed to the OIDC provider + service account, then annotate the SA with `eks.amazonaws.com/role-arn=<arn>`.
- Coder env vars already set: `CODER_AIBRIDGE_ENABLED=true`, `CODER_AIBRIDGE_STRUCTURED_LOGGING=true`, `CODER_AIBRIDGE_RETENTION=30d`, `AWS_REGION=us-east-1`. AI Bridge picks Bedrock up through the standard AWS SDK chain — `AWS_WEB_IDENTITY_TOKEN_FILE` + `AWS_ROLE_ARN` are injected by the EKS pod identity webhook (which is part of the OCP install for AWS).
- After annotating + restarting the `coder` pod, AI Bridge should be able to invoke Bedrock models. If you also want to log invocations centrally, decision #17 explicitly says "Bedrock invocation logging deliberately NOT enabled" for this demo — flip that if a Bedrock CloudTrail/CloudWatch story matters at the booth.

Good luck with kiro.
