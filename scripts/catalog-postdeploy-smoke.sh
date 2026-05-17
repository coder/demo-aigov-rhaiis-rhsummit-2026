#!/usr/bin/env bash
#
# scripts/catalog-postdeploy-smoke.sh
#
# Post-deploy verification. Run after Argo CD has reconciled all apps to
# Synced/Healthy. Confirms the stack is actually demo-ready, not just
# "manifests applied".
#
# The cheap, fast tests up top catch most regressions before the slow
# tests (chatd model registration, Loki ingest) run.
#
# Exit non-zero if any check fails.
#
# Usage:
#   export KUBECONFIG=<path-to-cluster-kubeconfig>
#   ./scripts/catalog-postdeploy-smoke.sh
#
# Optional env (auto-derived from cluster + tfvars otherwise):
#   CLUSTER_FQDN     e.g. demo.example.com (default: read from cluster route)
#   ENABLE_GPU       "true" or "false" (default: read by inspecting MachineSet replicas)
#   GITLAB_URL       e.g. https://gitlab.example.com
#   SKIP_BRIDGE      true to skip GitLab webhook check (e.g. if GitLab not yet bootstrapped)
#
# Requires: oc, curl, jq, python3.

set -uo pipefail

# ---------- Output helpers -------------------------------------------

if [[ -t 1 ]]; then
  G="\033[32m"; R="\033[31m"; Y="\033[33m"; B="\033[1m"; N="\033[0m"
else
  G=""; R=""; Y=""; B=""; N=""
fi
PASS=0; FAIL=0; WARN=0
pass() { echo -e "  ${G}✓${N} $1"; PASS=$((PASS+1)); }
fail() { echo -e "  ${R}✗${N} $1"; FAIL=$((FAIL+1)); }
warn() { echo -e "  ${Y}!${N} $1"; WARN=$((WARN+1)); }
section() { echo; echo -e "${B}== $1 ==${N}"; }

for t in oc curl jq python3; do
  command -v "$t" >/dev/null || { echo "missing: $t" >&2; exit 1; }
done

# ---------- Derive cluster FQDN if not provided ----------------------

if [[ -z "${CLUSTER_FQDN:-}" ]]; then
  apps_domain=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null)
  if [[ -z "$apps_domain" ]]; then
    echo "ERROR: oc not authenticated to a cluster (KUBECONFIG=$KUBECONFIG)" >&2
    exit 1
  fi
  # apps_domain looks like apps.demo.example.com → strip leading "apps."
  CLUSTER_FQDN="${apps_domain#apps.}"
fi
APPS_DOMAIN="apps.${CLUSTER_FQDN}"
echo "Cluster FQDN: $CLUSTER_FQDN"
echo "Apps domain:  $APPS_DOMAIN"

# ---------- Section 1: Cluster + Argo --------------------------------

section "Cluster + Argo health"

cv_state=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
if [[ "$cv_state" == "True" ]]; then
  pass "ClusterVersion Available=True"
else
  fail "ClusterVersion not Available (got: $cv_state)"
fi

if oc -n openshift-gitops get application root >/dev/null 2>&1; then
  apps_total=$(oc -n openshift-gitops get applications -o json | jq -r '.items | length')
  apps_synced=$(oc -n openshift-gitops get applications -o json \
    | jq -r '[.items[] | select(.status.sync.status=="Synced" and .status.health.status=="Healthy")] | length')
  if [[ "$apps_total" == "$apps_synced" ]]; then
    pass "All $apps_total Argo apps Synced + Healthy"
  else
    fail "$apps_synced / $apps_total Argo apps Synced + Healthy"
    oc -n openshift-gitops get applications -o json \
      | jq -r '.items[] | select(.status.sync.status!="Synced" or .status.health.status!="Healthy")
              | "    \(.metadata.name): sync=\(.status.sync.status) health=\(.status.health.status)"'
  fi
else
  fail "Argo root Application not present in openshift-gitops ns"
fi

# ---------- Section 2: Coder route reachable + Keycloak SSO redirect -

section "Coder + SSO"

CODER_URL="https://coder.${APPS_DOMAIN}"
KC_URL="https://keycloak.${APPS_DOMAIN}"

resp=$(curl -sk -o /dev/null -w '%{http_code}' "$CODER_URL/api/v2/buildinfo" 2>&1 || echo "000")
if [[ "$resp" == "200" ]]; then
  pass "Coder API at $CODER_URL/api/v2/buildinfo → 200"
  ver=$(curl -sk "$CODER_URL/api/v2/buildinfo" | jq -r .version 2>/dev/null || echo "?")
  pass "  Coder version: $ver"
else
  fail "Coder API at $CODER_URL/api/v2/buildinfo → HTTP $resp"
fi

# Coder /login HTML should advertise the OIDC button
if curl -sk "$CODER_URL/login" 2>/dev/null | grep -q -i "oidc\|keycloak\|sign in with"; then
  pass "Coder /login page advertises OIDC sign-in"
else
  # Fallback: check the buildinfo includes oidc auth method
  if curl -sk "$CODER_URL/api/v2/users/authmethods" 2>/dev/null | grep -q '"oidc":{[^}]*"enabled":true'; then
    pass "Coder /api/v2/users/authmethods reports OIDC enabled"
  else
    warn "Coder OIDC sign-in not detected — verify Keycloak SSO manually"
  fi
fi

kresp=$(curl -sk -o /dev/null -w '%{http_code}' "$KC_URL/realms/demo/.well-known/openid-configuration" 2>&1 || echo "000")
if [[ "$kresp" == "200" ]]; then
  pass "Keycloak realm 'demo' OIDC discovery endpoint reachable"
else
  fail "Keycloak realm 'demo' not reachable at $KC_URL (HTTP $kresp)"
fi

# ---------- Section 3: Bridge service --------------------------------

section "Bridge service"

BRIDGE_URL="https://bridge.${APPS_DOMAIN}"
br=$(curl -sk -o /dev/null -w '%{http_code}' "$BRIDGE_URL/healthz" 2>&1 || echo "000")
if [[ "$br" == "200" ]]; then
  pass "Bridge /healthz → 200"
else
  # Maybe the bridge isn't exposed on a public route — try in-cluster
  pod=$(oc -n coder get pod -l app=bridge -o name 2>/dev/null | head -1)
  if [[ -n "$pod" ]]; then
    inside=$(oc -n coder exec "$pod" -- curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/healthz 2>/dev/null || echo "000")
    if [[ "$inside" == "200" ]]; then
      pass "Bridge /healthz → 200 (in-cluster; public route may be intentional)"
    else
      fail "Bridge /healthz unreachable (public HTTP $br, in-cluster HTTP $inside)"
    fi
  else
    fail "Bridge has no public 200 and no pod found in 'coder' ns"
  fi
fi

# ---------- Section 4: GitLab + bridge webhook ----------------------

section "GitLab + bridge webhook"

if [[ "${SKIP_BRIDGE:-false}" == "true" ]]; then
  warn "SKIP_BRIDGE=true — skipping GitLab webhook check"
else
  # GitLab lives at gitlab.<base_domain> — base_domain is CLUSTER_FQDN
  # minus the first DNS component (e.g. demo.example.com → example.com).
  base_domain_default="${CLUSTER_FQDN#*.}"
  GITLAB_URL="${GITLAB_URL:-https://gitlab.${base_domain_default}}"
  # GitLab Omnibus restricts /-/health to monitoring IPs; sign-in page is the safest "reachable" probe.
  gl=$(curl -sk -o /dev/null -w '%{http_code}' "$GITLAB_URL/users/sign_in" 2>&1 || echo "000")
  if [[ "$gl" == "200" ]]; then
    pass "GitLab sign-in page reachable at $GITLAB_URL (HTTP 200)"
  else
    fail "GitLab not reachable at $GITLAB_URL/users/sign_in (HTTP $gl)"
  fi

  # personas present?
  if [[ -n "${GITLAB_ADMIN_PAT:-}" ]]; then
    found=0
    for u in alice bob demoadm; do
      ident=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_ADMIN_PAT" "$GITLAB_URL/api/v4/users?username=$u" \
        | python3 -c 'import sys, json; arr=json.load(sys.stdin); print(arr[0]["identities"][0]["provider"] if arr and arr[0].get("identities") else "")' 2>/dev/null)
      if [[ "$ident" == "openid_connect" ]]; then
        pass "  user $u present with Keycloak OIDC identity"
        found=$((found+1))
      else
        warn "  user $u missing or no OIDC identity (ident=$ident)"
      fi
    done
  else
    warn "GITLAB_ADMIN_PAT not set — skipping persona/identity check"
  fi
fi

# ---------- Section 5: chatd model registration ----------------------

section "chatd model providers"

if [[ -n "${CODER_ADMIN_TOKEN:-}" ]]; then
  models_json=$(curl -sk -H "Coder-Session-Token: $CODER_ADMIN_TOKEN" "$CODER_URL/api/v2/aibridge/configs" 2>/dev/null)
  if [[ -n "$models_json" ]] && echo "$models_json" | jq -e . >/dev/null 2>&1; then
    bedrock_count=$(echo "$models_json" | python3 -c 'import sys, json; d=json.load(sys.stdin); print(sum(1 for c in (d.get("configs") or d) if "bedrock" in (c.get("model","")+c.get("provider","")).lower()))' 2>/dev/null || echo 0)
    vllm_count=$(echo "$models_json" | python3 -c 'import sys, json; d=json.load(sys.stdin); print(sum(1 for c in (d.get("configs") or d) if "vllm" in (c.get("model","")+c.get("provider_url","")+c.get("url","")).lower()))' 2>/dev/null || echo 0)
    pass "chatd providers reachable ($bedrock_count Bedrock, $vllm_count vLLM)"
    [[ "$bedrock_count" -gt 0 ]] && pass "  Bedrock provider present" || warn "  No Bedrock provider — chat path broken"
    if [[ "${ENABLE_GPU:-false}" == "true" ]]; then
      [[ "$vllm_count" -gt 0 ]] && pass "  vLLM provider present" || warn "  No vLLM provider despite ENABLE_GPU=true"
    fi
  else
    warn "chatd configs endpoint returned non-JSON (chatd may not be enabled in this Coder version)"
  fi
else
  warn "CODER_ADMIN_TOKEN not set — skipping chatd provider check"
fi

# ---------- Section 6: Observability (Loki ingest) -------------------

section "Observability"

graf=$(curl -sk -o /dev/null -w '%{http_code}' "https://graf-coder.${APPS_DOMAIN}/api/health" 2>&1 || echo "000")
if [[ "$graf" == "200" ]]; then
  pass "Grafana /api/health → 200"
else
  fail "Grafana not reachable at https://graf-coder.${APPS_DOMAIN} (HTTP $graf)"
fi

# Loki ingest check — most important catch for ND11 regression.
# Loki containers are stripped (no curl), so we port-forward briefly.
if oc -n coder-observability get svc loki-read >/dev/null 2>&1; then
  pf_log=$(mktemp)
  oc -n coder-observability port-forward svc/loki-read 13100:3100 >"$pf_log" 2>&1 &
  pf_pid=$!
  for _ in 1 2 3 4 5; do
    sleep 1
    grep -q "Forwarding from" "$pf_log" && break
  done
  if curl -s --max-time 5 "http://localhost:13100/ready" 2>/dev/null | grep -q ready; then
    count=$(curl -s --max-time 10 --data-urlencode 'query=count_over_time({namespace="coder"}[5m])' \
      http://localhost:13100/loki/api/v1/query 2>/dev/null \
      | python3 -c 'import sys, json
try:
  d=json.load(sys.stdin); r=d.get("data",{}).get("result",[])
  print(sum(int(float(s["value"][1])) for s in r) if r else 0)
except Exception:
  print(-1)' 2>/dev/null)
    if [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )); then
      pass "Loki has $count Coder log lines in last 5m — log scrape working"
    elif [[ "$count" == "0" ]]; then
      fail "Loki has 0 Coder logs in last 5m — possible ND11 regression (grafana-agent not privileged)"
    else
      warn "Loki query unexpected result (got: $count) — check manually"
    fi
  else
    warn "Could not port-forward Loki for log-ingest probe"
  fi
  kill $pf_pid 2>/dev/null
  wait $pf_pid 2>/dev/null
  rm -f "$pf_log"
fi

# DS privileged check (direct)
priv=$(oc -n coder-observability get ds grafana-agent -o jsonpath='{.spec.template.spec.containers[0].securityContext.privileged}' 2>/dev/null)
if [[ "$priv" == "true" ]]; then
  pass "grafana-agent DS container.securityContext.privileged=true"
else
  fail "grafana-agent DS NOT privileged (got: '$priv'). G1 gap — see docs/NON-DECLARATIVE-CHANGES.md ND11."
fi

# ---------- Section 7: GPU + RHAIIS (if enabled) ---------------------

section "GPU + RHAIIS"

# Auto-detect if GPU MachineSet is at replicas>0
gpu_replicas=$(oc -n openshift-machine-api get machineset -l machine.openshift.io/cluster-api-machine-role=gpu \
  -o jsonpath='{.items[*].spec.replicas}' 2>/dev/null | tr ' ' '+' | bc 2>/dev/null || echo 0)
[[ -z "$gpu_replicas" ]] && gpu_replicas=0

ENABLE_GPU="${ENABLE_GPU:-$( [[ "$gpu_replicas" -gt 0 ]] && echo true || echo false )}"

if [[ "$ENABLE_GPU" != "true" ]]; then
  pass "ENABLE_GPU=false (no GPU MachineSet replicas) — skipping RHAIIS check"
else
  vllm_ready=$(oc -n ocp-ai get deploy -l app=vllm -o json 2>/dev/null \
    | jq -r '[.items[] | select(.status.readyReplicas==.spec.replicas and .spec.replicas>0)] | length')
  if [[ "$vllm_ready" -gt 0 ]]; then
    pass "$vllm_ready vLLM deployment(s) Ready in ocp-ai"
  else
    fail "No vLLM deployments Ready despite ENABLE_GPU=true"
  fi
fi

# ---------- Summary --------------------------------------------------

section "Summary"
echo "  pass: $PASS"
echo "  warn: $WARN"
echo "  fail: $FAIL"
echo

if (( FAIL > 0 )); then
  echo -e "${R}Post-deploy smoke FAILED.${N} See failures above. Most common: G1 (grafana-agent privileged) — see docs/NON-DECLARATIVE-CHANGES.md ND11."
  exit 1
fi
if (( WARN > 0 )); then
  echo -e "${Y}Post-deploy smoke passed with warnings.${N} Review the warnings before declaring demo-ready."
  exit 0
fi
echo -e "${G}Post-deploy smoke clean.${N} Stack looks demo-ready."
exit 0
