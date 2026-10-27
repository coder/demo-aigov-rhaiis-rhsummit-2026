#!/usr/bin/env bash
# Sync the Coder AI Gateway providers + Coder Agents models to this deployment
# via Terraform (coderd provider). Mirrors the reference repo
# (greg-the-coder/partner-ai-dlc-gitops/ai-providers) but with model IDs and
# the default model tailored to what is enabled in AWS account 342934376218.
#
# Usage:  ./ai_providers_gitops.sh <coder_session_token>
#
# Environment:
#   CODER_AGENT_URL           Coder deployment URL                 (required)
#   BEDROCK_REGION            AWS region for Bedrock               (default us-east-1)
#   BEDROCK_MODEL             primary/default (native) model id
#   BEDROCK_SMALL_FAST_MODEL  small/fast (native) model id
#   BEDROCK_OPENAI_KEY        Amazon Bedrock API key (ABSK bearer) (required for openai-compat)
#
# The Amazon Bedrock API key is an IAM service-specific credential on an IAM
# *user* (SSO roles can't hold one). The user needs bedrock:CallWithBearerToken
# + bedrock:InvokeModel* and, for Marketplace models (GPT-5.6/6),
# aws-marketplace:ViewSubscriptions. Marketplace models must be subscribed once
# at the account level via a SigV4 invoke before the bearer key can use them
# (see README).
set -euo pipefail

CODER_TOKEN="${1:-}"
[ -z "$CODER_TOKEN" ] && { echo "ERROR: Coder session token required as arg 1." >&2; exit 1; }

# --- Ensure Terraform >= 1.11 (write-only arguments) -------------------------
need_tf() {
  command -v terraform >/dev/null 2>&1 || return 0
  ver=$(terraform version -json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["terraform_version"])' 2>/dev/null || echo 0.0.0)
  maj=${ver%%.*}; min=$(echo "$ver" | cut -d. -f2)
  { [ "$maj" -gt 1 ] || { [ "$maj" -eq 1 ] && [ "$min" -ge 11 ]; }; } && return 1 || return 0
}
if need_tf; then
  echo "Installing Terraform 1.13.1 (>=1.11 required for write-only args)..."
  curl -sLo /tmp/tf.zip "https://releases.hashicorp.com/terraform/1.13.1/terraform_1.13.1_linux_amd64.zip"
  mkdir -p /tmp/tfbin && unzip -q -o /tmp/tf.zip -d /tmp/tfbin && export PATH="/tmp/tfbin:$PATH"
fi
terraform version | head -1

export TF_VAR_coder_url="${CODER_AGENT_URL:?set CODER_AGENT_URL}"
export TF_VAR_coder_token="${CODER_TOKEN}"
export TF_VAR_bedrock_region="${BEDROCK_REGION:-us-east-1}"
export TF_VAR_bedrock_model="${BEDROCK_MODEL:-global.anthropic.claude-opus-4-5-20251101-v1:0}"
export TF_VAR_bedrock_small_fast_model="${BEDROCK_SMALL_FAST_MODEL:-global.anthropic.claude-haiku-4-5-20251001-v1:0}"
export TF_VAR_bedrock_openai_api_key="${BEDROCK_OPENAI_KEY:?set BEDROCK_OPENAI_KEY (ABSK bearer)}"

terraform init -input=false
terraform apply -auto-approve
echo "AI provider + model configuration applied."
