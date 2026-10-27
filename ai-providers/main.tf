terraform {
  required_version = ">= 1.11.0"
  required_providers {
    coderd = {
      source  = "coder/coderd"
      version = ">= 0.0.25"
    }
  }
}

variable "coder_url" { type = string }
variable "coder_token" {
  type      = string
  sensitive = true
}
variable "bedrock_region" {
  type    = string
  default = "us-east-1"
}
variable "bedrock_endpoint" {
  type    = string
  default = "https://bedrock-runtime.us-east-1.amazonaws.com"
}
# Model IDs validated against account 342934376218 / us-east-1 inference profiles.
variable "bedrock_model" {
  type    = string
  default = "global.anthropic.claude-opus-4-5-20251101-v1:0"
}
variable "bedrock_small_fast_model" {
  type    = string
  default = "global.anthropic.claude-haiku-4-5-20251001-v1:0"
}

provider "coderd" {
  url   = var.coder_url
  token = var.coder_token
}

data "coderd_organization" "default" {
  is_default = true
}

# Native AWS Bedrock provider — credentials via the coder-server pod IRSA role
# (cluster-coder-bedrock); no static keys.
resource "coderd_ai_provider" "bedrock" {
  name         = "bedrock"
  type         = "bedrock"
  display_name = "AWS Bedrock"
  base_url     = var.bedrock_endpoint
  enabled      = true

  settings = {
    bedrock = {
      region           = var.bedrock_region
      model            = var.bedrock_model
      small_fast_model = var.bedrock_small_fast_model
    }
  }
}

resource "coderd_agents_model" "claude_opus" {
  ai_provider_id = coderd_ai_provider.bedrock.id
  model          = var.bedrock_model
  display_name   = "Claude Opus 4.5"
  enabled        = true
  context_limit  = 200000
  model_config = jsonencode({
    max_output_tokens = 64000
    provider_options = {
      anthropic = {
        send_reasoning = true
      }
    }
  })
}

resource "coderd_agents_model" "claude_haiku" {
  ai_provider_id = coderd_ai_provider.bedrock.id
  model          = var.bedrock_small_fast_model
  display_name   = "Claude Haiku 4.5"
  enabled        = true
  context_limit  = 200000
  model_config = jsonencode({
    max_output_tokens = 64000
    provider_options = {
      anthropic = {
        send_reasoning = true
        thinking = {
          budget_tokens = 8192
        }
      }
    }
  })
}

resource "coderd_agents_default_model" "default" {
  model_id        = coderd_agents_model.claude_opus.id
  organization_id = data.coderd_organization.default.id
}

resource "coderd_agents_mcp_server" "aws_knowledge" {
  organization_id = data.coderd_organization.default.id
  display_name    = "AWS Knowledge"
  slug            = "aws-knowledge"
  url             = "https://knowledge-mcp.global.api.aws"
  description     = "AWS-hosted MCP server: docs, API refs, What's New, Builder Center, and Well-Architected guidance."
  icon_url        = "/icon/aws.png"
  transport       = "streamable_http"
  auth_type       = "none"
  availability    = "default_on"
  enabled         = true
  model_intent    = true
}
