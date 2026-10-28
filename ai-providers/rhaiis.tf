# In-cluster Red Hat AI Inference Server (RHAIIS / vLLM) — OpenAI-compatible.
# Serves Qwen2.5-7B-Instruct on the single NVIDIA-A10G (Deployment
# vllm-executor in namespace ocp-ai). vLLM is started without --api-key,
# so it accepts any/absent bearer; we pass a placeholder to satisfy the
# provider schema. The AI Gateway (coder-server) reaches this endpoint
# over cluster DNS, server-side.

variable "rhaiis_base_url" {
  type    = string
  default = "http://vllm-executor.ocp-ai.svc.cluster.local:8000/v1"
}

variable "rhaiis_api_key" {
  type      = string
  sensitive = true
  default   = "noauth"
}

variable "rhaiis_api_key_version" {
  type    = number
  default = 1
}

resource "coderd_ai_provider" "rhaiis" {
  name         = "rhaiis"
  type         = "openai"
  display_name = "RHAIIS (in-cluster vLLM)"
  base_url     = var.rhaiis_base_url
  enabled      = true

  api_key_wo         = var.rhaiis_api_key
  api_key_wo_version = var.rhaiis_api_key_version
}

# Qwen2.5-7B-Instruct served by vllm-executor. vLLM runs with
# --enable-auto-tool-choice --tool-call-parser hermes, so Coder Agents'
# tool-calling harness works against it. 16K context (matches
# --max-model-len 16384); cap generation at 4K tokens.
resource "coderd_agents_model" "rhaiis_qwen25_7b" {
  ai_provider_id = coderd_ai_provider.rhaiis.id
  model          = "Qwen/Qwen2.5-7B-Instruct"
  display_name   = "Qwen2.5 7B Instruct (RHAIIS / A10G)"
  enabled        = true
  context_limit  = 16384
  model_config   = jsonencode({ max_output_tokens = 4096 })
}
