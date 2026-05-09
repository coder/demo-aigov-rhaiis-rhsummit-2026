#!/usr/bin/env bash
# Configure Coder Agents (chatd) providers and model-configs for the
# Bedrock + RHAIIS booth demo.
#
# What it creates / updates (idempotent — PATCH on existing rows so
# chat_messages FKs to model_config_id stay intact):
#
#   Provider 1 — AWS Bedrock
#     provider:    "bedrock"
#     api_key:     <none — uses IRSA on the coder-server SA>
#     base_url:    https://bedrock-runtime.<region>.amazonaws.com
#
#   Provider 2 — RHAIIS (sovereign Granite, OpenAI-compatible vLLM)
#     provider:    "openai-compat"   (NOT "openai" — chatd treats them
#                                     as distinct types; "openai-compat"
#                                     is the right type for any vLLM /
#                                     LM Studio / Ollama style upstream)
#     api_key:     "EMPTY" (RHAIIS has no auth)
#     base_url:    http://vllm.ocp-ai.svc.cluster.local:8000/v1
#
#   Models
#     - Every Anthropic Opus and Sonnet inference profile available in
#       the configured AWS region (discovered at runtime via
#       `aws bedrock list-inference-profiles`). Each is registered with
#       a friendly display name; the newest Opus is the default.
#     - One RHAIIS Granite model.
#
# Why inference profiles, not raw foundation model IDs:
#   Anthropic Claude 4+ models on Bedrock require an inference profile
#   (cross-region, e.g. `us.anthropic.claude-opus-4-...-v1:0`). The
#   profile IDs are stable and the right thing to put in the
#   `model_config.model` field. Older Claude 3.x foundation model IDs
#   still work via on-demand throughput, but for forward compatibility
#   we use profiles when available and fall back to foundation models.
#
# Usage (laptop, ad-hoc):
#   export CODER_URL=https://coder.apps.<cluster-domain>
#   export CODER_TOKEN=<owner-session-token>
#   export AWS_REGION=us-east-1
#   ./scripts/coder-agents-provider-model-config.sh
#
# Usage (in-cluster, via the Argo CD-managed Job):
#   The Job pod injects CODER_URL, CODER_TOKEN (from a SealedSecret),
#   AWS_REGION, RHAIIS_BASE_URL, and assumes the IRSA role on the
#   `coder-server` ServiceAccount so `aws bedrock list-...` works.
#
# Falling back to AI-Bridge-fronted Bedrock (if chatd's `bedrock`
# provider type doesn't work in your Coder build):
#   set BEDROCK_PROVIDER_MODE=aibridge
#   The script will then create/update an `anthropic`-type provider
#   pointing at ${CODER_URL}/api/v2/aibridge/anthropic, bootstrapping a
#   `chatd-aibridge` Coder service-account token for AI Bridge auth (the
#   same pattern as the k3s-infra reference script).

set -euo pipefail

: "${CODER_URL:?CODER_URL must be set}"
: "${CODER_TOKEN:?CODER_TOKEN must be set}"
: "${AWS_REGION:=us-east-1}"
: "${RHAIIS_BASE_URL:=http://vllm.ocp-ai.svc.cluster.local:8000/v1}"
: "${RHAIIS_MODEL_ID:=ibm-granite/granite-3.1-8b-instruct}"
: "${RHAIIS_DISPLAY_NAME:=Granite 3.1 8B Instruct (RHAIIS sovereign)}"
: "${BEDROCK_PROVIDER_MODE:=native}"   # native | aibridge

BASE="${CODER_URL%/}/api/experimental/chats"
V2="${CODER_URL%/}/api/v2"
AUTH="Coder-Session-Token: ${CODER_TOKEN}"

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' is required on PATH" >&2; exit 1; }
}
require curl
require jq
require aws

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

patch_provider() {
  local id="$1" payload="$2"
  curl -sf -X PATCH -H "$AUTH" -H "Content-Type: application/json" \
    -d "$payload" "${BASE}/providers/${id}" \
    | jq '{id,provider,display_name,base_url,has_api_key}'
}

create_provider() {
  local payload="$1"
  curl -sf -X POST -H "$AUTH" -H "Content-Type: application/json" \
    -d "$payload" "${BASE}/providers" \
    | jq '{id,provider,display_name,base_url,has_api_key}'
}

upsert_provider() {
  # Match on (provider type, source=database) so chart-injected providers
  # don't collide with the rows we own.
  local provider_type="$1" payload="$2"
  local existing_id
  existing_id=$(echo "$EXISTING_PROVIDERS" \
    | jq -r --arg p "$provider_type" '.[] | select(.provider == $p and .source == "database") | .id' \
    | head -1)

  if [ -n "$existing_id" ]; then
    echo "    Updating ${provider_type} provider (${existing_id})..."
    patch_provider "$existing_id" "$payload"
  else
    echo "    Creating ${provider_type} provider..."
    create_provider "$payload"
  fi
}

upsert_model_by_name() {
  # Keyed on display_name — the same Bedrock model ID can show up more
  # than once (e.g. with and without extended-thinking provider_options),
  # so display_name is the stable, human-meaningful key.
  local display_name="$1" payload="$2"
  local existing_uuid
  existing_uuid=$(echo "$EXISTING_MODELS" \
    | jq -r --arg n "$display_name" '.[] | select(.display_name == $n) | .id' \
    | head -1)

  if [ -n "$existing_uuid" ]; then
    echo "    Updating \"${display_name}\" (${existing_uuid})..."
    curl -sf -X PATCH -H "$AUTH" -H "Content-Type: application/json" \
      -d "$payload" "${BASE}/model-configs/${existing_uuid}" \
      | jq '{id,provider,model,display_name,is_default}'
  else
    echo "    Creating \"${display_name}\"..."
    curl -sf -X POST -H "$AUTH" -H "Content-Type: application/json" \
      -d "$payload" "${BASE}/model-configs" \
      | jq '{id,provider,model,display_name,is_default}'
  fi
}

# Friendly name from a Bedrock inference-profile or foundation-model ID.
#   us.anthropic.claude-opus-4-20250514-v1:0  -> "Claude Opus 4 (2025-05-14, US)"
#   anthropic.claude-3-5-haiku-20241022-v1:0  -> "Claude 3.5 Haiku (2024-10-22)"
format_display_name() {
  local id="$1"
  local region_prefix=""
  case "$id" in
    us\.*)  region_prefix=" (US)";   id="${id#us.}"   ;;
    eu\.*)  region_prefix=" (EU)";   id="${id#eu.}"   ;;
    apac\.*) region_prefix=" (APAC)"; id="${id#apac.}" ;;
  esac
  # Strip "anthropic." vendor prefix and ":0" version tail.
  id="${id#anthropic.}"
  id="${id%:0}"
  # claude-opus-4-20250514-v1
  local family model_part date_part version
  family=$(echo "$id" | awk -F- '{print $1}')                   # claude
  model_part=$(echo "$id" | awk -F- '{print $2}')               # opus / sonnet / 3
  if echo "$id" | grep -qE -- '-[0-9]{8}-v[0-9]+$'; then
    date_part=$(echo "$id" | awk -F- '{print $(NF-1)}')         # 20250514
    version=$(echo "$id" | awk -F- '{print $NF}')               # v1
    local middle
    middle=$(echo "$id" | awk -F- '{for (i=2;i<NF-1;i++) printf "%s ", $i}')
    local pretty_middle
    pretty_middle=$(echo "$middle" | sed -E 's/\b([a-z])/\u\1/g; s/[ ]+$//')
    local pretty_date="${date_part:0:4}-${date_part:4:2}-${date_part:6:2}"
    echo "Claude ${pretty_middle} (${pretty_date}${region_prefix:+, }${region_prefix# })"
  else
    # Fallback: capitalize words, drop trailing -v* if present
    id=$(echo "$id" | sed -E 's/-v[0-9]+$//; s/-/ /g; s/\b([a-z])/\u\1/g')
    echo "${id}${region_prefix}"
  fi
}

# Sort key so the newest model becomes the default. Strips everything
# except the date stamp; missing dates sort lowest.
date_key() {
  echo "$1" | grep -oE '[0-9]{8}' | head -1 || echo "00000000"
}

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------

echo "==> Coder API reachable?"
curl -sf -o /dev/null -H "$AUTH" "${V2}/users/me" \
  || { echo "ERROR: ${V2}/users/me returned non-200 — check CODER_URL/CODER_TOKEN" >&2; exit 1; }
echo "    OK"

echo ""
echo "==> Bedrock reachable in region ${AWS_REGION}?"
aws bedrock list-foundation-models --region "$AWS_REGION" --max-results 1 >/dev/null \
  || { echo "ERROR: aws bedrock failed — check IRSA / AWS_REGION / SSO" >&2; exit 1; }
echo "    OK"

# ---------------------------------------------------------------------------
# Optional AI-Bridge SA bootstrap (only when BEDROCK_PROVIDER_MODE=aibridge)
# ---------------------------------------------------------------------------

SVC_TOKEN=""
if [ "$BEDROCK_PROVIDER_MODE" = "aibridge" ]; then
  echo ""
  echo "==> Ensuring chatd-aibridge service account (BEDROCK_PROVIDER_MODE=aibridge)..."
  SVC_USER_ID=$(curl -sf -H "$AUTH" "${V2}/users/chatd-aibridge" 2>/dev/null | jq -r '.id // empty')
  if [ -z "$SVC_USER_ID" ]; then
    echo "    Creating service account..."
    ORG_ID=$(curl -sf -H "$AUTH" "${V2}/organizations" | jq -r '.[0].id')
    SVC_USER_ID=$(curl -sf -X POST -H "$AUTH" -H "Content-Type: application/json" \
      -d "$(jq -n --arg org "$ORG_ID" '{
        username:"chatd-aibridge",
        email:"chatd-aibridge@coder.local",
        name:"chatd AI Bridge",
        login_type:"none",
        organization_ids:[$org]
      }')" "${V2}/users" | jq -r '.id')
    echo "    Created ${SVC_USER_ID}"
  else
    echo "    Exists: ${SVC_USER_ID}"
  fi
  echo "    Minting long-lived token..."
  SVC_TOKEN=$(curl -sf -X POST -H "$AUTH" -H "Content-Type: application/json" \
    -d '{"lifetime": 3155760000000000000, "token_name": "chatd-aibridge-token"}' \
    "${V2}/users/chatd-aibridge/keys/tokens" | jq -r '.key')

  HTTP=$(curl -so /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $SVC_TOKEN" \
    "${CODER_URL%/}/api/v2/aibridge/anthropic/v1/models" || true)
  if [ "$HTTP" != "200" ]; then
    echo "WARN: AI Bridge anthropic /v1/models returned HTTP ${HTTP} — continuing, models may still work" >&2
  else
    echo "    Token validated against AI Bridge"
  fi
fi

# ---------------------------------------------------------------------------
# Provider configuration
# ---------------------------------------------------------------------------

echo ""
echo "==> Fetching existing providers..."
EXISTING_PROVIDERS=$(curl -sf -H "$AUTH" "${BASE}/providers")

echo ""
case "$BEDROCK_PROVIDER_MODE" in
  native)
    echo "==> Configuring Bedrock provider (native, IRSA-backed)..."
    # The chatd `bedrock` provider type uses the AWS SDK credential
    # chain. Setting base_url is how chatd learns the region; the chats
    # API silently drops `provider_options.bedrock.region`, so we encode
    # the region in the URL exactly the way AI Bridge does.
    BEDROCK_PROVIDER_PAYLOAD=$(jq -n --arg url "https://bedrock-runtime.${AWS_REGION}.amazonaws.com" '{
      provider: "bedrock",
      display_name: "AWS Bedrock (IRSA)",
      base_url: $url,
      central_api_key_enabled: true,
      allow_user_api_key: false
    }')
    upsert_provider "bedrock" "$BEDROCK_PROVIDER_PAYLOAD"
    ;;
  aibridge)
    echo "==> Configuring Bedrock provider (via AI Bridge anthropic endpoint)..."
    BEDROCK_PROVIDER_PAYLOAD=$(jq -n \
      --arg url "${CODER_URL%/}/api/v2/aibridge/anthropic" \
      --arg key "$SVC_TOKEN" '{
      provider: "anthropic",
      display_name: "AWS Bedrock (via AI Bridge)",
      base_url: $url,
      api_key: $key,
      central_api_key_enabled: true,
      allow_user_api_key: false
    }')
    upsert_provider "anthropic" "$BEDROCK_PROVIDER_PAYLOAD"
    ;;
  *)
    echo "ERROR: BEDROCK_PROVIDER_MODE must be 'native' or 'aibridge'" >&2
    exit 1
    ;;
esac

echo ""
echo "==> Configuring RHAIIS provider (direct, OpenAI-compatible)..."
RHAIIS_PROVIDER_PAYLOAD=$(jq -n --arg url "$RHAIIS_BASE_URL" '{
  provider: "openai-compat",
  display_name: "RHAIIS (Sovereign Granite)",
  base_url: $url,
  api_key: "EMPTY",
  central_api_key_enabled: true,
  allow_user_api_key: false
}')
upsert_provider "openai-compat" "$RHAIIS_PROVIDER_PAYLOAD"

# ---------------------------------------------------------------------------
# Discover Bedrock Anthropic Opus + Sonnet models
# ---------------------------------------------------------------------------

echo ""
echo "==> Discovering Anthropic Opus/Sonnet inference profiles in ${AWS_REGION}..."

# Inference profiles (preferred — required for Claude 4+).
PROFILES=$(aws bedrock list-inference-profiles --region "$AWS_REGION" \
  --type-equals SYSTEM_DEFINED --output json 2>/dev/null || echo '{"inferenceProfileSummaries":[]}')

PROFILE_IDS=$(echo "$PROFILES" \
  | jq -r '.inferenceProfileSummaries[]
      | select(.models | length > 0)
      | select(.models[0].modelArn | contains("anthropic"))
      | select(.inferenceProfileId | test("opus|sonnet"))
      | .inferenceProfileId' \
  | sort -u)

# Foundation models that are on-demand-capable (still useful for older
# Claude 3.x families that don't require a profile).
FM=$(aws bedrock list-foundation-models --region "$AWS_REGION" \
  --by-provider anthropic --output json)

FM_IDS=$(echo "$FM" \
  | jq -r '.modelSummaries[]
      | select(.modelLifecycle.status == "ACTIVE")
      | select(.inferenceTypesSupported | index("ON_DEMAND"))
      | select(.modelId | test("opus|sonnet"))
      | .modelId' \
  | sort -u)

# Combine: profile IDs first (newest path), foundation model IDs second.
ALL_IDS=$( { echo "$PROFILE_IDS"; echo "$FM_IDS"; } | awk 'NF' | sort -u )

if [ -z "$ALL_IDS" ]; then
  echo "WARN: no Opus/Sonnet models discovered. Check Bedrock model access in the AWS console." >&2
fi

echo "    Found:"
echo "$ALL_IDS" | sed 's/^/      /'

# Pick the newest Opus profile/model as the default. Falls back to
# newest sonnet if no opus is available.
NEWEST_OPUS=$(echo "$ALL_IDS" | grep opus | while read -r id; do echo "$(date_key "$id") $id"; done | sort -r | head -1 | awk '{print $2}')
NEWEST_SONNET=$(echo "$ALL_IDS" | grep sonnet | while read -r id; do echo "$(date_key "$id") $id"; done | sort -r | head -1 | awk '{print $2}')
DEFAULT_MODEL_ID="${NEWEST_OPUS:-$NEWEST_SONNET}"
echo ""
echo "    Default model will be: ${DEFAULT_MODEL_ID:-<none>}"

# ---------------------------------------------------------------------------
# Create / update model-configs
# ---------------------------------------------------------------------------

echo ""
echo "==> Fetching existing model-configs..."
EXISTING_MODELS=$(curl -sf -H "$AUTH" "${BASE}/model-configs")

# Bedrock Anthropic pricing (per Anthropic's published rates; AWS bills
# at the same per-token rate via Bedrock).
OPUS_COST='{"input_price_per_million_tokens":15,"output_price_per_million_tokens":75,"cache_read_price_per_million_tokens":1.5,"cache_write_price_per_million_tokens":18.75}'
SONNET_COST='{"input_price_per_million_tokens":3,"output_price_per_million_tokens":15,"cache_read_price_per_million_tokens":0.3,"cache_write_price_per_million_tokens":3.75}'
HAIKU_COST='{"input_price_per_million_tokens":0.8,"output_price_per_million_tokens":4,"cache_read_price_per_million_tokens":0.08,"cache_write_price_per_million_tokens":1}'

bedrock_provider_for_model() {
  # Returns the chatd provider type to assign to a Bedrock model.
  case "$BEDROCK_PROVIDER_MODE" in
    native)   echo "bedrock"   ;;
    aibridge) echo "anthropic" ;;
  esac
}

cost_for_model() {
  case "$1" in
    *opus*)   echo "$OPUS_COST"   ;;
    *sonnet*) echo "$SONNET_COST" ;;
    *haiku*)  echo "$HAIKU_COST"  ;;
    *)        echo "$SONNET_COST" ;;
  esac
}

context_for_model() {
  # Claude 3.5/4/4.5/4.6/4.7 are 200K base; the 1M-context Sonnet 4 / Opus 4
  # tier exists but isn't always enabled per-account. Stick with 200K to be
  # safe. Adjust if your Bedrock account has the 1M-context inference
  # profile enabled.
  echo 200000
}

provider_options_for_model() {
  # Extended-thinking flag for Opus/Sonnet models. Field name is
  # `effort: "max"` under the provider's sub-key:
  #   - "anthropic" provider: provider_options.anthropic.effort = "max"
  #   - "bedrock"   provider: provider_options.bedrock.effort   = "max"
  # Returns "{}" when no options apply (chatd accepts an empty object).
  local model_id="$1" effort="$2" provider_type="$3"
  if [ -n "$effort" ]; then
    jq -n --arg p "$provider_type" --arg e "$effort" '{ ($p): { effort: $e } }'
  else
    echo '{}'
  fi
}

echo ""
echo "==> Configuring Bedrock Anthropic models..."
PROVIDER_TYPE=$(bedrock_provider_for_model)

for model_id in $ALL_IDS; do
  base_name=$(format_display_name "$model_id")
  cost=$(cost_for_model "$model_id")
  context=$(context_for_model "$model_id")
  is_default="false"
  [ "$model_id" = "$DEFAULT_MODEL_ID" ] && is_default="true"

  # Two entries per model: one with extended thinking on, one off.
  for variant in "extended" "standard"; do
    if [ "$variant" = "extended" ]; then
      display="${base_name} (Extended Thinking)"
      effort="max"
      variant_default="false"
    else
      display="${base_name}"
      effort=""
      variant_default="$is_default"
    fi

    options=$(provider_options_for_model "$model_id" "$effort" "$PROVIDER_TYPE")

    payload=$(jq -n \
      --arg provider "$PROVIDER_TYPE" \
      --arg model "$model_id" \
      --arg display "$display" \
      --argjson context "$context" \
      --argjson cost "$cost" \
      --argjson is_default "$variant_default" \
      --argjson options "$options" '{
        provider: $provider,
        model: $model,
        display_name: $display,
        context_limit: $context,
        enabled: true,
        is_default: $is_default,
        model_config: {
          max_output_tokens: 32000,
          cost: $cost,
          provider_options: $options
        }
      }')

    upsert_model_by_name "$display" "$payload"
  done
done

# ---------------------------------------------------------------------------
# RHAIIS Granite model
# ---------------------------------------------------------------------------

echo ""
echo "==> Configuring RHAIIS Granite model..."

GRANITE_COST='{"input_price_per_million_tokens":0,"output_price_per_million_tokens":0,"cache_read_price_per_million_tokens":0}'

GRANITE_PAYLOAD=$(jq -n \
  --arg model "$RHAIIS_MODEL_ID" \
  --arg display "$RHAIIS_DISPLAY_NAME" \
  --argjson cost "$GRANITE_COST" '{
    provider: "openai-compat",
    model: $model,
    display_name: $display,
    context_limit: 8192,
    enabled: true,
    is_default: false,
    model_config: {
      max_output_tokens: 4096,
      cost: $cost
    }
  }')

upsert_model_by_name "$RHAIIS_DISPLAY_NAME" "$GRANITE_PAYLOAD"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "Done."
echo "  Verify: ${CODER_URL%/}/admin/ai-governance"
echo "  Or via API: curl -H \"$AUTH\" ${BASE}/model-configs | jq '.[] | {provider,model,display_name,enabled,is_default}'"
