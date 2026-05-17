#!/usr/bin/env bash
#
# scripts/bootstrap-sealed-secrets.sh
#
# Interactive walkthrough for minting + sealing the 14 per-deploy
# secrets this stack needs. Run AFTER the sealed-secrets controller is
# installed in the cluster (Argo applies `gitops/apps/sealed-secrets/`
# first), so `kubeseal` can fetch the controller's public sealing key.
#
# Each secret is checked, prompted for, sealed via kubeseal, and written
# to `manifests/secrets/<name>.yaml`. Existing sealed files are left
# alone unless `--force <name>` is passed.
#
# Some secrets can only be minted AFTER Coder is running
# (coder-admin-token, coder-provisioner-key). These are skipped on the
# first run with a clear message; rerun the script with
# `--include post-coder` once Coder is up.
#
# Some inputs (Keycloak client secrets) come from
# manifests/keycloak/realm-demo.yaml literals — those secrets are
# auto-sealed from the realm definition with no operator typing.
#
# Usage:
#   ./scripts/bootstrap-sealed-secrets.sh
#   ./scripts/bootstrap-sealed-secrets.sh --include post-coder
#   ./scripts/bootstrap-sealed-secrets.sh --force coder-secrets
#
# Env (anything not set is prompted for interactively):
#   GH_CLIENT_ID, GH_CLIENT_SECRET            — Coder + OCP + Grafana GH OAuth app
#   OPENAI_API_KEY                            — for AI Bridge central key
#   GHCR_PAT                                  — GitHub PAT with read:packages
#   GH_ORG_READ_PAT                           — GitHub PAT with read:org
#   GITLAB_ADMIN_PAT                          — GitLab admin PAT
#   POSTGRES_PASSWORD                         — for Grafana → CNPG datasource (optional; auto-derived if oc set)
#   REDHAT_REGISTRY_USER, REDHAT_REGISTRY_PW  — Red Hat Registry creds for RHAIIS image pull
#   GH_OAUTH_OCP_CLIENT_SECRET                — OCP GH OAuth app client_secret (separate from Coder's if you split apps)
#   KEYCLOAK_REALM_FILE                       — default manifests/keycloak/realm-demo.yaml
#
# Requires: kubeseal, oc, jq, python3.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS_DIR="$REPO_ROOT/manifests/secrets"

INCLUDE_POST_CODER=false
FORCE_LIST=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --include) [[ "${2:-}" == "post-coder" ]] && INCLUDE_POST_CODER=true; shift 2 ;;
    --force)   FORCE_LIST="$FORCE_LIST $2"; shift 2 ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -t 1 ]]; then
  G="\033[32m"; R="\033[31m"; Y="\033[33m"; B="\033[1m"; N="\033[0m"
else
  G=""; R=""; Y=""; B=""; N=""
fi

for t in kubeseal oc jq python3; do
  command -v "$t" >/dev/null || { echo "missing: $t" >&2; exit 1; }
done

# Sealed-Secrets controller must be reachable (kubeseal fetches cert from it)
if ! oc -n kube-system get deploy sealed-secrets-controller >/dev/null 2>&1 \
  && ! oc -n sealed-secrets get deploy sealed-secrets-controller >/dev/null 2>&1; then
  echo "${R}ERROR:${N} sealed-secrets-controller deployment not found." >&2
  echo "  Apply gitops/apps/sealed-secrets/application.yaml first." >&2
  exit 1
fi

mkdir -p "$SECRETS_DIR"

forced() { [[ " $FORCE_LIST " == *" $1 "* ]]; }

# Skip if file exists and not in force list
skip_if_exists() {
  local name=$1
  local path="$SECRETS_DIR/$name.yaml"
  if [[ -f "$path" ]] && ! forced "$name"; then
    echo "  ${Y}skip${N} $name — already exists (use --force $name to overwrite)"
    return 0
  fi
  return 1
}

prompt_secret() {
  local var=$1
  local prompt=$2
  local val="${!var:-}"
  if [[ -z "$val" ]]; then
    read -r -s -p "  $prompt: " val
    echo
  fi
  printf '%s' "$val"
}

prompt_value() {
  local var=$1
  local prompt=$2
  local val="${!var:-}"
  if [[ -z "$val" ]]; then
    read -r -p "  $prompt: " val
  fi
  printf '%s' "$val"
}

# Build a generic literal-Secret YAML then pipe through kubeseal
seal_to_file() {
  local name=$1; local namespace=$2; local outfile=$3; shift 3
  # Remaining args are key=value pairs
  local args=()
  while [[ $# -gt 0 ]]; do
    args+=(--from-literal="$1"); shift
  done
  if oc create secret generic "$name" -n "$namespace" "${args[@]}" --dry-run=client -o yaml \
    | kubeseal --format yaml --controller-namespace=sealed-secrets > "$outfile.tmp"; then
    mv "$outfile.tmp" "$outfile"
    echo "  ${G}sealed${N} $outfile"
  else
    rm -f "$outfile.tmp"
    echo "  ${R}FAILED${N} sealing $name (kubeseal error above)"
    return 1
  fi
}

# Extract a literal-stored client secret from realm-demo.yaml
realm_client_secret() {
  local client_id=$1
  local realm_file="${KEYCLOAK_REALM_FILE:-$REPO_ROOT/manifests/keycloak/realm-demo.yaml}"
  python3 - "$realm_file" "$client_id" <<'PY'
import sys, yaml
realm_file, client_id = sys.argv[1], sys.argv[2]
with open(realm_file) as f:
    docs = list(yaml.safe_load_all(f))
for d in docs:
    if not isinstance(d, dict): continue
    spec = d.get("spec", {})
    realm = spec.get("realm", spec)
    for c in (realm.get("clients") or realm.get("client") or []):
        if c.get("clientId") == client_id:
            sec = c.get("secret") or c.get("clientSecret")
            if sec:
                print(sec); sys.exit(0)
print("", end="")
PY
}

echo
echo "${B}== bootstrap-sealed-secrets ==${N}"
echo "Output dir: $SECRETS_DIR"
echo

# ---------- 1. coder-secrets ----------------------------------------
echo "${B}1. coder-secrets${N} (coder ns) — GitHub OAuth + OpenAI API key"
out="$SECRETS_DIR/coder-secrets.yaml"
if ! skip_if_exists coder-secrets; then
  gh_id=$(prompt_value GH_CLIENT_ID "GitHub OAuth client_id (Coder app)")
  gh_sec=$(prompt_secret GH_CLIENT_SECRET "GitHub OAuth client_secret (Coder app)")
  openai=$(prompt_secret OPENAI_API_KEY "OpenAI API key (sk-...)")
  seal_to_file coder-secrets coder "$out" \
    "github-client-id=$gh_id" \
    "github-client-secret=$gh_sec" \
    "openai-api-key=$openai" || exit 1
fi
echo

# ---------- 2. github-oauth-client-secret (OCP IdP) ------------------
echo "${B}2. github-oauth-client-secret${N} (openshift-config ns) — OCP cluster OAuth"
out="$SECRETS_DIR/github-oauth-client-secret.yaml"
if ! skip_if_exists github-oauth-client-secret; then
  gh_ocp=$(prompt_secret GH_OAUTH_OCP_CLIENT_SECRET "OCP GitHub OAuth client_secret (use the same as Coder's if you reuse 1 app)")
  seal_to_file github-oauth-client-secret openshift-config "$out" \
    "clientSecret=$gh_ocp" || exit 1
fi
echo

# ---------- 3. keycloak-openshift-oidc-secret -----------------------
echo "${B}3. keycloak-openshift-oidc-secret${N} (openshift-config ns) — Keycloak ↔ OCP"
out="$SECRETS_DIR/keycloak-openshift-oidc-secret.yaml"
if ! skip_if_exists keycloak-openshift-oidc-secret; then
  kc_ocp=$(realm_client_secret "openshift")
  if [[ -z "$kc_ocp" ]]; then
    kc_ocp=$(prompt_secret KEYCLOAK_OPENSHIFT_SECRET "Keycloak 'openshift' client secret (from realm-demo.yaml)")
  else
    echo "  ${G}auto${N} read from realm-demo.yaml"
  fi
  seal_to_file keycloak-openshift-oidc-secret openshift-config "$out" \
    "clientSecret=$kc_ocp" || exit 1
fi
echo

# ---------- 4. grafana-github-oauth ---------------------------------
echo "${B}4. grafana-github-oauth${N} (coder-observability ns) — Grafana GH OAuth"
out="$SECRETS_DIR/grafana-github-oauth.yaml"
if ! skip_if_exists grafana-github-oauth; then
  graf_id=$(prompt_value GH_CLIENT_ID "GitHub OAuth client_id (Grafana app — can reuse Coder's)")
  graf_sec=$(prompt_secret GH_CLIENT_SECRET "GitHub OAuth client_secret (Grafana app)")
  seal_to_file grafana-github-oauth coder-observability "$out" \
    "GF_AUTH_GITHUB_CLIENT_ID=$graf_id" \
    "GF_AUTH_GITHUB_CLIENT_SECRET=$graf_sec" || exit 1
fi
echo

# ---------- 5. keycloak-grafana-oidc-secret -------------------------
echo "${B}5. keycloak-grafana-oidc-secret${N} (coder-observability ns)"
out="$SECRETS_DIR/keycloak-grafana-oidc-secret.yaml"
if ! skip_if_exists keycloak-grafana-oidc-secret; then
  kc_gr=$(realm_client_secret "grafana")
  if [[ -z "$kc_gr" ]]; then
    kc_gr=$(prompt_secret KEYCLOAK_GRAFANA_SECRET "Keycloak 'grafana' client secret")
  else
    echo "  ${G}auto${N} read from realm-demo.yaml"
  fi
  seal_to_file keycloak-grafana-oidc-secret coder-observability "$out" \
    "clientSecret=$kc_gr" || exit 1
fi
echo

# ---------- 6. secret-postgres --------------------------------------
echo "${B}6. secret-postgres${N} (coder-observability ns) — Grafana → CNPG"
out="$SECRETS_DIR/secret-postgres.yaml"
if ! skip_if_exists secret-postgres; then
  pgpw="${POSTGRES_PASSWORD:-}"
  if [[ -z "$pgpw" ]]; then
    # Try to derive from running CNPG secret
    pgpw=$(oc -n coder get secret coder-app -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
  fi
  if [[ -z "$pgpw" ]]; then
    pgpw=$(prompt_secret POSTGRES_PASSWORD "CNPG postgres password for coder-app user")
  else
    echo "  ${G}auto${N} read from CNPG secret coder/coder-app"
  fi
  seal_to_file secret-postgres coder-observability "$out" \
    "PGPASSWORD=$pgpw" || exit 1
fi
echo

# ---------- 7. ghcr-pull --------------------------------------------
echo "${B}7. ghcr-pull${N} (coder-workspaces ns) — GHCR image pull"
out="$SECRETS_DIR/ghcr-pull.yaml"
if ! skip_if_exists ghcr-pull; then
  ghcr_user=$(prompt_value GHCR_USER "GHCR username (your GitHub login)")
  ghcr_pat=$(prompt_secret GHCR_PAT "GitHub PAT with read:packages")
  # dockerconfigjson secrets need a different shape
  dockercfg=$(python3 -c "
import json, base64
auth = base64.b64encode(f'$ghcr_user:$ghcr_pat'.encode()).decode()
cfg = {'auths': {'ghcr.io': {'auth': auth}}}
print(json.dumps(cfg))
")
  oc create secret docker-registry ghcr-pull -n coder-workspaces \
    --docker-server=ghcr.io \
    --docker-username="$ghcr_user" \
    --docker-password="$ghcr_pat" \
    --dry-run=client -o yaml \
    | kubeseal --format yaml --controller-namespace=sealed-secrets > "$out.tmp" \
    && mv "$out.tmp" "$out" && echo "  ${G}sealed${N} $out" \
    || { rm -f "$out.tmp"; echo "  ${R}FAILED${N} sealing ghcr-pull"; exit 1; }
fi
echo

# ---------- 8. bridge-webhook-secret --------------------------------
echo "${B}8. bridge-webhook-secret${N} (coder ns) — GitLab webhook HMAC"
out="$SECRETS_DIR/bridge-webhook-secret.yaml"
if ! skip_if_exists bridge-webhook-secret; then
  wh="${BRIDGE_WEBHOOK_SECRET:-$(openssl rand -hex 32)}"
  echo "  ${G}generated${N} (32-byte hex)"
  seal_to_file bridge-webhook-secret coder "$out" \
    "webhook-secret=$wh" || exit 1
fi
echo

# ---------- 9. github-group-sync-token ------------------------------
echo "${B}9. github-group-sync-token${N} (group-sync-operator ns)"
out="$SECRETS_DIR/github-group-sync-token.yaml"
if ! skip_if_exists github-group-sync-token; then
  gh_org=$(prompt_secret GH_ORG_READ_PAT "GitHub PAT with read:org")
  seal_to_file github-group-sync-token group-sync-operator "$out" \
    "GITHUB_TOKEN=$gh_org" || exit 1
fi
echo

# ---------- 10. gitlab-bridge-pat -----------------------------------
echo "${B}10. gitlab-bridge-pat${N} (coder ns) — bridge ↔ GitLab admin API"
out="$SECRETS_DIR/gitlab-bridge-pat.yaml"
if ! skip_if_exists gitlab-bridge-pat; then
  glpat=$(prompt_secret GITLAB_ADMIN_PAT "GitLab admin PAT (from gitlab-rails runner)")
  seal_to_file gitlab-bridge-pat coder "$out" \
    "pat=$glpat" || exit 1
fi
echo

# ---------- 11. gitlab-coder-external-auth --------------------------
echo "${B}11. gitlab-coder-external-auth${N} (coder ns) — Coder external_auth OAuth app"
out="$SECRETS_DIR/gitlab-coder-external-auth.yaml"
if ! skip_if_exists gitlab-coder-external-auth; then
  if command -v "$SCRIPT_DIR/gitlab-create-coder-oauth-app.sh" >/dev/null \
    && [[ -n "${GITLAB_ADMIN_PAT:-}" && -n "${GITLAB_URL:-}" && -n "${CODER_URL:-}" ]]; then
    echo "  ${G}invoking${N} gitlab-create-coder-oauth-app.sh"
    cid_csec=$("$SCRIPT_DIR/gitlab-create-coder-oauth-app.sh" --json 2>/dev/null) || true
    if [[ -n "$cid_csec" ]]; then
      cid=$(echo "$cid_csec" | jq -r .client_id)
      csec=$(echo "$cid_csec" | jq -r .client_secret)
    fi
  fi
  if [[ -z "${cid:-}" || -z "${csec:-}" ]]; then
    cid=$(prompt_value GITLAB_CODER_OAUTH_CLIENT_ID "GitLab Coder OAuth app client_id")
    csec=$(prompt_secret GITLAB_CODER_OAUTH_CLIENT_SECRET "GitLab Coder OAuth app client_secret")
  fi
  seal_to_file gitlab-coder-external-auth coder "$out" \
    "client-id=$cid" \
    "client-secret=$csec" || exit 1
fi
echo

# ---------- 12. redhat-pull-secret (regular Secret, not SealedSecret) ----
echo "${B}12. redhat-pull-secret${N} (ocp-ai ns) — RH Registry pull for RHAIIS"
echo "  ${Y}NOTE${N}: this is a regular docker-registry Secret applied directly via oc"
echo "         (not sealed — fresh-deploy admin applies it once with their RH creds)"
if oc -n ocp-ai get secret redhat-pull-secret >/dev/null 2>&1; then
  echo "  ${Y}skip${N} — already present in cluster"
else
  if [[ -n "${REDHAT_REGISTRY_USER:-}" && -n "${REDHAT_REGISTRY_PW:-}" ]]; then
    oc -n ocp-ai create secret docker-registry redhat-pull-secret \
      --docker-server=registry.redhat.io \
      --docker-username="$REDHAT_REGISTRY_USER" \
      --docker-password="$REDHAT_REGISTRY_PW" \
      && echo "  ${G}applied${N} to cluster"
  else
    echo "  ${Y}prompt${N} REDHAT_REGISTRY_USER + REDHAT_REGISTRY_PW not set; create manually:"
    echo "    oc -n ocp-ai create secret docker-registry redhat-pull-secret \\"
    echo "      --docker-server=registry.redhat.io \\"
    echo "      --docker-username=<user> --docker-password=<pw>"
  fi
fi
echo

# ---------- 13/14. Post-Coder secrets -------------------------------
echo "${B}13/14. coder-admin-token + coder-provisioner-key${N} (coder ns)"
if [[ "$INCLUDE_POST_CODER" != "true" ]]; then
  echo "  ${Y}skip${N} — these must be minted AFTER Coder is running."
  echo "  Re-run with --include post-coder once Coder pods are Ready."
else
  if ! skip_if_exists coder-admin-token; then
    # Mint owner token via Coder API. Requires CODER_URL + CODER_FIRST_USER auth.
    if [[ -z "${CODER_URL:-}" ]]; then
      apps_domain=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null)
      CODER_URL="https://coder.$apps_domain"
    fi
    echo "  ${B}!${N} mint a long-lived owner token in the Coder UI:"
    echo "    1. Log in to $CODER_URL as the owner user"
    echo "    2. Settings → Account → Tokens → Create token (lifetime: max)"
    echo "    3. Paste here when prompted"
    tok=$(prompt_secret CODER_ADMIN_TOKEN "Coder owner session token")
    seal_to_file coder-admin-token coder "$SECRETS_DIR/coder-admin-token.yaml" \
      "token=$tok" || exit 1
  fi
  if ! skip_if_exists coder-provisioner-key; then
    echo "  ${B}!${N} mint a provisioner key:"
    echo "    coder provisioner keys create rhsummit-key --url $CODER_URL"
    pkey=$(prompt_secret CODER_PROVISIONER_KEY "provisioner key")
    seal_to_file coder-provisioner-key coder "$SECRETS_DIR/coder-provisioner-key.yaml" \
      "key=$pkey" || exit 1
  fi
fi
echo

# ---------- Summary --------------------------------------------------
echo "${B}== done ==${N}"
echo "Sealed files in $SECRETS_DIR:"
ls -1 "$SECRETS_DIR"/*.yaml 2>/dev/null | sed 's|^|  |'
echo
echo "Next step:"
echo "  git add manifests/secrets/"
echo "  git commit -m 'feat(secrets): seal per-deploy secrets'"
echo "  git push    # Argo will reconcile + the controller decrypts into live Secrets"
