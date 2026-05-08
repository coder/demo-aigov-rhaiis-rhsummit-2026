# Morning Report — 2026-05-08

Status as of ~06:45 UTC, after a full overnight pass on coder-observability + RHAIIS verification.

## TL;DR

- **`coder-observability` is up.** All 16 pods Running. Grafana reachable at `https://graf-coder.apps.cluster.rhsummit.coderdemo.io`. GitHub OAuth wired with admin-team → Grafana Admin role mapping. Same demo-rhsummit-users org gate as Coder (decision #20) and OpenShift (decision #21).
- **`rhaiis` was already healthy.** vLLM running on the GPU node (`ip-10-0-7-41`), `ibm-granite/granite-3.1-8b-instruct` loaded, `/v1/chat/completions` returns coherent answers. No changes needed.
- **All other Argo apps Synced/Healthy** (with two cosmetic OutOfSync flags noted below).
- **Decisions doc updated** — new §22 covers the full k3s → OCP translation work for observability.

## What Grafana looks like

- URL: **https://graf-coder.apps.cluster.rhsummit.coderdemo.io**
- Login flow: GitHub OAuth → `demo-rhsummit-users` org members admitted; `admin` team members get Grafana Admin role automatically; everyone else lands as Viewer.
- Dashboards present: the Coder bundle (coderd, provisionerd, workspaces, prebuilds, agent-boundaries, AI Bridge, status), plus Loki dashboards and the runbook viewer.
- Datasources: Prometheus (in-cluster), Loki (in-cluster), Infinity (for the AI Bridge dashboard's litellm pricing-data lookup).

## Files changed overnight

```
gitops/apps/observability/application.yaml      — comprehensive k3s→OCP translation
manifests/observability/route.yaml              — host=graf-coder, service=grafana, port=service
manifests/observability/certificate.yaml        — graf-coder.apps... (was grafana.apps...)
manifests/observability/grafana-agent-scc.yaml  — NEW; binds agent SA to hostmount-anyuid
manifests/secrets/grafana-github-oauth.yaml     — NEW; sealed OAuth client id/secret
docs/decisions.md                                — new §22 (full translation rationale)
MORNING_REPORT.md                                — this file
```

Git log overnight:

```
78bff88 fix(observability): bind grafana-agent SA to hostmount-anyuid SCC
bf98080 fix(observability): Route -> grafana svc (not coder-observability-grafana)
ec457de fix(observability): alertmanager container-level SC + minio SC + minio memory
fa954ca fix(observability): mirror memcached + disable memcached-exporter (DH limit)
9380ba9 fix(observability): point loki-gateway DNS resolver at OpenShift CoreDNS
cb2f0f5 fix(observability): pin grafana UID + disable initChownData (chart YAML error)
a29b0f3 fix(observability): pin alertmanager+kube-state-metrics UID (schema rejects null)
43e97c9 feat(observability): translate k3s coder-observability config to OCP
```

(Followed by a docs commit landing decision §22 — coming next.)

## What was wrong (in order of discovery)

The chart had been `OutOfSync/Degraded` for ~5 hours. Five distinct issues, each rejecting a different subcomponent:

1. **Restricted-v2 SCC vs hardcoded UIDs.** Every subchart hardcoded a runAsUser outside the namespace's uid-range (`grafana` 472, `prometheus.server` 65534, `prometheus.alertmanager` 65534, `prometheus.kube-state-metrics` 65534, `loki.loki` 10001, `loki.gateway` 101, `loki.minio` 1000). Two patterns to fix: nullify (the SCC mutating admission then injects a valid UID) for the schema-permissive subcharts, or pin to `1000800000` (start of the allowed range) for the schema-strict ones. Detailed per-subchart in `application.yaml` comments and decision §22.

2. **Grafana init-chown-data init container** uses `.Values.securityContext.runAsUser` *inline* in its `chown` command. With null, the rendered StatefulSet had `chown -R :  /var/lib/grafana`, which fails Helm's YAML parse. Fix: pin grafana UID + disable the init container entirely (OCP's CSI driver chgrps with the SCC-injected fsGroup; manual chown is redundant).

3. **Loki gateway DNS resolver.** The nginx config embeds `<dnsService>.<dnsNamespace>.svc.cluster.local`. Defaults are `kube-dns.kube-system` (vanilla k8s); OCP's CoreDNS is `dns-default.openshift-dns`. Override `loki.global.{dnsService,dnsNamespace}`.

4. **Docker Hub rate limits** on three images: `memcached` → `mirror.gcr.io/library/memcached`. `prom/memcached-exporter` → no published mirror, disabled. `burningalchemist/sql_exporter` → no published mirror, disabled.

5. **grafana-agent hostPath blocked by restricted-v2.** The DS ships node logs to Loki via hostPath mounts. New manifest `manifests/observability/grafana-agent-scc.yaml` binds the agent SA to `hostmount-anyuid`. Standard OCP pattern for log shippers — narrower than `privileged`, broader than `restricted-v2`.

Plus two smaller things:
- The Route was pointed at the wrong Service name (`coder-observability-grafana` vs the actual `grafana`) and wrong port name (`http-web` vs `service`).
- minio's chart-default 16Gi memory request would have blocked scheduling on the converged cluster — trimmed to 1Gi for the demo.

## What I deliberately deferred

These three things are knowingly off and called out in `application.yaml` + `docs/decisions.md` §22 → "Tradeoffs":

- **`sqlExporter.enabled: false`** — Coder-specific Postgres SQL metrics. Image is DH-only with no upstream mirror; either we mirror it ourselves to GHCR/Quay or accept the gap. Coder dashboards still work because Prometheus scrapes Coder pods directly.

- **`global.postgres.exporter.enabled: false`** — generic Postgres metrics. Chart wants `secret-postgres` with PGUSER/PGPASSWORD-shaped keys. CNPG's `coder-app` Secret has different keys (`uri`/`host`/`port`/`dbname`/`user`/`password`/`jdbc-uri`). Need a translation Secret or a small Job that materializes one. Postgres-specific Grafana panels will be empty until this is wired.

- **`loki.memcachedExporter.enabled: false`** — observability of the memcached caches themselves. Image is DH-only.

## RHAIIS

Already running, no changes required.

```
Pod:         vllm-77b6bb9dfd-2mb2l on ip-10-0-7-41.ec2.internal (us-east-1a, GPU worker)
Image:       quay.io/modh/vllm:rhoai-2.20-cuda    # no subscription needed
Model:       ibm-granite/granite-3.1-8b-instruct
Tool parser: granite (--enable-auto-tool-choice)
Endpoint:    POST http://vllm.ocp-ai.svc.cluster.local:8000/v1/chat/completions
```

End-to-end smoke test passed (`curl /v1/chat/completions` returns coherent answer). The image path uses `quay.io/modh/vllm` (Red Hat's open-access publication) rather than `registry.redhat.io` so we don't need the RHOAI subscription SKU on the partner pull secret — that was the call you flagged as "the other requires a sub I dont want to deal with."

## Argo state at handoff

```
NAME                  SYNC STATUS   HEALTH STATUS
cert-manager          Synced        Healthy
cluster-config        Synced        Healthy
coder                 Synced        Healthy
coder-observability   OutOfSync     Progressing      [see "cosmetic OutOfSync" below]
coder-provisioner     Synced        Healthy
coder-routing         OutOfSync     Healthy
gpu-stack             Synced        Healthy
group-sync-operator   Synced        Healthy
platform-secrets      Synced        Healthy
postgres              Synced        Healthy
rhaiis                Synced        Healthy
root                  Synced        Healthy
sealed-secrets        OutOfSync     Healthy
```

All workloads I touched are functionally correct.

### Cosmetic OutOfSync (won't go away on their own — none affect functionality)

- `sealed-secrets` — Argo's diff-cache shows a phantom diff on the Bitnami Helm Deployment; `argocd app diff` returns empty. Documented in earlier sealed-secrets rollout notes.
- `coder-observability` — three sub-resources flag OutOfSync:
  - **`PersistentVolumeClaim/grafana`** (Pending) — orphan PVC the chart's grafana template renders alongside the StatefulSet's volumeClaimTemplate. The SS's `storage-grafana-0` is the real Bound PVC; this leftover doesn't bind because nothing claims it. I tried deleting it, Argo recreates it (it's part of the chart's render). Functionally inert.
  - **3 StatefulSets** (alertmanager, grafana, loki-storage) — `OutOfSync Healthy` from SSA managedFields after our manual delete-and-recreate cycle. They self-heal Healthy; the OutOfSync label is cosmetic and matches the same pattern we hit on sealed-secrets.
  - **kube-state-metrics ClusterRole/ClusterRoleBinding** — Argo tracking-id label diff on cluster-scoped objects.
- `coder-routing` — pre-existing, not touched this session.

## What I would do next (if you want me to keep going)

- **Mirror sql-exporter and memcached-exporter** to GHCR (a small `Job` per image using skopeo, or commit-time CI to a registry we own). Re-enable both. Restores the metrics gap.
- **Translate `coder-app` Secret → `secret-postgres`** so the postgres-exporter can connect. Either a one-shot init Job that reads CNPG's auto-generated values and materializes a properly-shaped Secret in `coder-observability`, or extend the Coder helm install to add the translation as a Helm hook.
- **Switch grafana-agent to OpenShift Logging.** Replace the chart's agent + hostmount-anyuid SCC binding with the cluster-logging operator's Vector/LokiStack pipeline. Preserves Loki for queries; uses operator-managed SCCs.
- **Cleanup** — `git rm docs/sealed-secrets-rollout.md` (the one-shot runbook from earlier today).

## How to verify when you wake up

```bash
export KUBECONFIG=/tmp/kubeconfig

# 1. All pods running?
oc get pods -n coder-observability
# expected: 16 pods Running

# 2. Grafana login page
curl -sf -o /dev/null -w "HTTP %{http_code}\n" \
  https://graf-coder.apps.cluster.rhsummit.coderdemo.io/api/health
# expected: HTTP 200

# 3. RHAIIS smoke test
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
# expected: a JSON response with content from the model

# 4. Argo apps overview
oc get applications -n openshift-gitops
```

## Notes on credentials

- The Grafana OAuth client secret you pasted in chat for the script (`f37679...`) is now sealed in `manifests/secrets/grafana-github-oauth.yaml`. The plaintext was wiped from disk. The chat history still contains it — recommend rotating in GitHub post-demo.
- The Coder API token (`vTVuC...`) that you pasted earlier for me to mint the provisioner key — same recommendation.
- The provisioner key plaintext briefly leaked into output when I extracted it (the new Coder CLI prints it on a bare line). Sealed manifest is committed; rotation via `coder provisioner keys delete rhsummit-demo` + re-mint is a one-liner if you want to be tidy.

Sleep well.
