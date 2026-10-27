# Coder AI Gateway — Providers & Agent Models (Terraform)

Declarative config of this deployment's **AI Gateway providers** and **Coder
Agents chat models** via the [`coderd`](https://registry.terraform.io/providers/coder/coderd)
Terraform provider (≥ 0.0.25, Coder 2.37+). Adapted from
`greg-the-coder/partner-ai-dlc-gitops/ai-providers` with model IDs validated
against **AWS account 342934376218 / us-east-1**.

| Resource | Purpose |
|---|---|
| `coderd_ai_provider.bedrock` | Native Bedrock (Anthropic). Creds via the `coder-server` pod IRSA role `cluster-coder-bedrock` — no static key. |
| `coderd_ai_provider.openai_compat` | Bedrock `/openai/v1` endpoint. Auth via a write-only **Amazon Bedrock API key** (`ABSK…`). |
| `coderd_agents_model` ×17 | 2 Claude (native) + 15 OpenAI-compatible chat models. |
| `coderd_agents_default_model` | Default = Claude Opus 4.5. |
| `coderd_agents_mcp_server.aws_knowledge` | AWS Knowledge MCP server (remote, no auth). |

## Requirements
- Coder **v2.37.0+**, `coderd` provider **≥ 0.0.25**, Terraform **≥ 1.11** (write-only args). The wrapper auto-installs TF if needed.
- A Coder **admin session token** (`https://<coder-url>/cli-auth`).
- An **Amazon Bedrock API key** for `openai-compat` (see below).

## Usage
```bash
export CODER_AGENT_URL="https://coder.apps.cluster.rhsummit.coderdemo.io"
export BEDROCK_OPENAI_KEY="ABSK..."         # see "Bedrock API key" below
./ai_providers_gitops.sh "<coder-session-token>"
```
> Do **not** commit state or `*.tfvars` — the Coder token and provider config
> are sensitive (`.gitignore` covers these). The Bedrock API key is passed as a
> write-only argument and is never stored in state.

## Bedrock API key (for `openai-compat`)
The key is an IAM **service-specific credential** on an IAM **user** (SSO roles
can't hold one):
```bash
aws iam create-user --user-name coder-bedrock-openai --path /demo/
aws iam put-user-policy --user-name coder-bedrock-openai --policy-name bedrock-invoke \
  --policy-document '{"Version":"2012-10-17","Statement":[
    {"Effect":"Allow","Action":["bedrock:CallWithBearerToken","bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream","bedrock:GetInferenceProfile",
      "bedrock:ListInferenceProfiles","bedrock:GetFoundationModel",
      "bedrock:ListFoundationModels","bedrock:Converse","bedrock:ConverseStream"],"Resource":"*"},
    {"Effect":"Allow","Action":["aws-marketplace:ViewSubscriptions","aws-marketplace:Subscribe",
      "aws-marketplace:Unsubscribe"],"Resource":"*"}]}'
# ServiceCredentialSecret in the output is the ABSK bearer key:
aws iam create-service-specific-credential --user-name coder-bedrock-openai \
  --service-name bedrock.amazonaws.com --query 'ServiceSpecificCredential.ServiceCredentialSecret' --output text
```

## Marketplace models (GPT-5.6 / GPT-6, etc.)
These are **AWS Marketplace-subscription** models. The bearer-key path can only
*use* an existing subscription, not create one — so subscribe the account
**once** with a SigV4 (admin) invoke before using them via the key:
```bash
for m in us.openai.gpt-5.6-sol us.openai.gpt-5.6-terra us.openai.gpt-5.6-luna; do
  aws bedrock-runtime converse --region us-east-1 --model-id "$m" \
    --messages '[{"role":"user","content":[{"text":"ok"}]}]' --inference-config '{"maxTokens":8}'
done
```
Serverless models (GPT-OSS, Mistral, DeepSeek, Qwen, MiniMax, Nemotron, Gemma)
auto-enable on first use and need no subscription step.
