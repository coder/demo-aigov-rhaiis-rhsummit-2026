# OpenAI-compatible provider via Amazon Bedrock's native /openai/v1 endpoint.
# Authenticated with a write-only Amazon Bedrock API key (ABSK bearer), an IAM
# service-specific credential on user demo/coder-bedrock-openai.

variable "bedrock_openai_endpoint" {
  type    = string
  default = "https://bedrock-runtime.us-east-1.amazonaws.com/openai/v1"
}

variable "bedrock_openai_api_key" {
  type      = string
  sensitive = true
}

variable "bedrock_openai_api_key_version" {
  type    = number
  default = 1
}

resource "coderd_ai_provider" "openai_compat" {
  name         = "openai-compat"
  type         = "openai"
  display_name = "OpenAI-compatible (AWS Bedrock)"
  base_url     = var.bedrock_openai_endpoint
  enabled      = true

  api_key_wo         = var.bedrock_openai_api_key
  api_key_wo_version = var.bedrock_openai_api_key_version
}

# --- OpenAI GPT-5.6 family (cross-region) -----------------------------------
resource "coderd_agents_model" "gpt_5_6_sol" {
  ai_provider_id = coderd_ai_provider.openai_compat.id
  model          = "us.openai.gpt-5.6-sol"
  display_name   = "OpenAI GPT-5.6 Sol"
  enabled        = true
  context_limit  = 400000
  model_config   = jsonencode({ max_output_tokens = 128000 })
}
resource "coderd_agents_model" "gpt_5_6_terra" {
  ai_provider_id = coderd_ai_provider.openai_compat.id
  model          = "us.openai.gpt-5.6-terra"
  display_name   = "OpenAI GPT-5.6 Terra"
  enabled        = true
  context_limit  = 1000000
  model_config   = jsonencode({ max_output_tokens = 128000 })
}
resource "coderd_agents_model" "gpt_5_6_luna" {
  ai_provider_id = coderd_ai_provider.openai_compat.id
  model          = "us.openai.gpt-5.6-luna"
  display_name   = "OpenAI GPT-5.6 Luna"
  enabled        = true
  context_limit  = 1000000
  model_config   = jsonencode({ max_output_tokens = 128000 })
}

# --- OpenAI GPT-OSS (open-source, in-region) --------------------------------
resource "coderd_agents_model" "gpt_oss_120b" {
  ai_provider_id = coderd_ai_provider.openai_compat.id
  model          = "openai.gpt-oss-120b-1:0"
  display_name   = "OpenAI GPT-OSS 120B"
  enabled        = true
  context_limit  = 128000
  model_config   = jsonencode({ max_output_tokens = 16000 })
}
resource "coderd_agents_model" "gpt_oss_20b" {
  ai_provider_id = coderd_ai_provider.openai_compat.id
  model          = "openai.gpt-oss-20b-1:0"
  display_name   = "OpenAI GPT-OSS 20B"
  enabled        = true
  context_limit  = 128000
  model_config   = jsonencode({ max_output_tokens = 16000 })
}

# --- xAI --------------------------------------------------------------------
resource "coderd_agents_model" "grok_4_6" {
  ai_provider_id = coderd_ai_provider.openai_compat.id
  model          = "us.xai.grok-4.6"
  display_name   = "xAI Grok 4.6"
  enabled        = true
  context_limit  = 256000
  model_config   = jsonencode({ max_output_tokens = 32000 })
}

# --- Mistral ----------------------------------------------------------------
resource "coderd_agents_model" "mistral_large_3" {
  ai_provider_id = coderd_ai_provider.openai_compat.id
  model          = "mistral.mistral-large-3-675b-instruct"
  display_name   = "Mistral Large 3 (675B)"
  enabled        = true
  context_limit  = 128000
  model_config   = jsonencode({ max_output_tokens = 32000 })
}
resource "coderd_agents_model" "mistral_devstral_2" {
  ai_provider_id = coderd_ai_provider.openai_compat.id
  model          = "mistral.devstral-2-123b"
  display_name   = "Mistral Devstral 2 (123B)"
  enabled        = true
  context_limit  = 128000
  model_config   = jsonencode({ max_output_tokens = 32000 })
}

# --- DeepSeek ---------------------------------------------------------------
resource "coderd_agents_model" "deepseek_v3_2" {
  ai_provider_id = coderd_ai_provider.openai_compat.id
  model          = "deepseek.v3.2"
  display_name   = "DeepSeek V3.2"
  enabled        = true
  context_limit  = 128000
  model_config   = jsonencode({ max_output_tokens = 32000 })
}

# --- Qwen -------------------------------------------------------------------
resource "coderd_agents_model" "qwen3_coder_next" {
  ai_provider_id = coderd_ai_provider.openai_compat.id
  model          = "qwen.qwen3-coder-next"
  display_name   = "Qwen3 Coder Next"
  enabled        = true
  context_limit  = 128000
  model_config   = jsonencode({ max_output_tokens = 32000 })
}
resource "coderd_agents_model" "qwen3_32b" {
  ai_provider_id = coderd_ai_provider.openai_compat.id
  model          = "qwen.qwen3-32b-v1:0"
  display_name   = "Qwen3 32B"
  enabled        = true
  context_limit  = 128000
  model_config   = jsonencode({ max_output_tokens = 32000 })
}

# --- Moonshot ---------------------------------------------------------------
resource "coderd_agents_model" "kimi_k2_thinking" {
  ai_provider_id = coderd_ai_provider.openai_compat.id
  model          = "moonshot.kimi-k2-thinking"
  display_name   = "Moonshot Kimi K2 Thinking"
  enabled        = true
  context_limit  = 128000
  model_config   = jsonencode({ max_output_tokens = 32000 })
}

# --- MiniMax ----------------------------------------------------------------
resource "coderd_agents_model" "minimax_m2_5" {
  ai_provider_id = coderd_ai_provider.openai_compat.id
  model          = "minimax.minimax-m2.5"
  display_name   = "MiniMax M2.5"
  enabled        = true
  context_limit  = 128000
  model_config   = jsonencode({ max_output_tokens = 32000 })
}

# --- NVIDIA -----------------------------------------------------------------
resource "coderd_agents_model" "nemotron_super_3_120b" {
  ai_provider_id = coderd_ai_provider.openai_compat.id
  model          = "nvidia.nemotron-super-3-120b"
  display_name   = "NVIDIA Nemotron Super 3 120B"
  enabled        = true
  context_limit  = 262000
}

# --- Google -----------------------------------------------------------------
resource "coderd_agents_model" "gemma_3_12b" {
  ai_provider_id = coderd_ai_provider.openai_compat.id
  model          = "google.gemma-3-12b-it"
  display_name   = "Google Gemma 3 12B IT"
  enabled        = true
  context_limit  = 128000
}
