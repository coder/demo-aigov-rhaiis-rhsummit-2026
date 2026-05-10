# manifests/secrets/

SealedSecret manifests, encrypted offline by `kubeseal` against the
in-cluster Bitnami Sealed Secrets controller. Safe to commit — only the
controller (which holds the per-cluster sealing key) can decrypt them.

The full workflow — `kubeseal` install, sealing key backup, per-secret
invocations — lives in [`docs/secrets.md`](../../docs/secrets.md).

## What lives here

| File | Namespace | Consumed by |
|---|---|---|
| `coder-secrets.yaml` | `coder` | Coder server (`gitops/apps/coder/application.yaml`) — GitHub OAuth ID/secret for the `demo-rhsummit-users` org **plus the central `openai-api-key`** for AI Bridge (`CODER_AIBRIDGE_OPENAI_KEY`, `CODER_AIBRIDGE_ALLOW_BYOK=false`) |
| `coder-provisioner-key.yaml` | `coder` | Coder external provisioner (`gitops/apps/coder-provisioner/application.yaml`) — daemon auth key issued by `coder provisioner keys create` |
| `coder-admin-token.yaml` | `coder` | `coder-agents-config` Job (`gitops/apps/coder-agents-config/application.yaml`) — Owner-role API token used to call `/api/experimental/chats/...` and register Bedrock + RHAIIS providers/models |
| `secret-postgres.yaml` | `coder-observability` | postgres-exporter (Grafana datasource); CloudNativePG-style postgres URI |
| `grafana-github-oauth.yaml` | `coder-observability` | Grafana auth — GitHub OAuth client ID/secret; admin team mapping via `role_attribute_path` |
| `ghcr-pull.yaml` | `coder-workspaces` | Workspace pull secret for `ghcr.io/coder/demo-aigov-rhaiis-rhsummit-2026/*` images |
| `github-oauth-client-secret.yaml` | `openshift-config` | OpenShift IdP — GitHub OAuth client secret (paired with `OAuth/cluster.spec.identityProviders[0].github`) |
| `github-group-sync-token.yaml` | `group-sync-operator` | redhat-cop/group-sync-operator — GitHub `read:org` PAT used to sync the `demo-rhsummit-users:admin` team into a Kubernetes Group bound to `cluster-admin` |

(Plus this README and a `.gitkeep`, which exist so Argo CD can resolve
the path before the first SealedSecret is committed.)

## Adding a new secret

```bash
# 1. Generate plaintext (do NOT commit this temp file)
kubectl create secret generic <name> \
  --namespace=<ns> \
  --from-literal=key1='value1' \
  --from-literal=key2='value2' \
  --dry-run=client -o yaml > /tmp/<name>.yaml

# 2. Seal against the in-cluster controller
kubeseal --controller-namespace=sealed-secrets \
  --format yaml \
  < /tmp/<name>.yaml \
  > manifests/secrets/<name>.yaml

# 3. Clean up the plaintext, commit the cipher
rm /tmp/<name>.yaml
git add manifests/secrets/<name>.yaml
git commit -m "secrets: add <name>"
git push
```

Argo CD picks up the new SealedSecret on the next sync; the controller
decrypts it into a regular `Secret` in the target namespace.
