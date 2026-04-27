#!/usr/bin/env bash
#
# tool-call-smoke-test.sh
#
# Verify that an OpenAI-compatible inference endpoint (e.g., RHAIIS / vLLM) is
# returning structured tool_calls — not prose. This is the single most common
# failure mode when wiring vLLM tool support: if the wrong --tool-call-parser
# is set (or --enable-auto-tool-choice is missing), the model returns text
# that looks like a tool call but parses as message content, and Coder Agents
# (or any tool-calling client) silently breaks.
#
# Usage:
#   ./tool-call-smoke-test.sh [endpoint] [model]
#
# Examples:
#   ./tool-call-smoke-test.sh
#   ./tool-call-smoke-test.sh http://vllm.ocp-ai.svc:8000/v1 granite-3.1-8b-instruct
#   ./tool-call-smoke-test.sh https://api.openai.com/v1 gpt-4o-mini
#
# Requires: curl, jq.

set -euo pipefail

ENDPOINT="${1:-http://localhost:8000/v1}"
MODEL="${2:-granite-3.1-8b-instruct}"

# Optional API key. vLLM ignores keys by default; OpenAI requires one.
AUTH_HEADER=()
if [[ -n "${OPENAI_API_KEY:-}" ]]; then
  AUTH_HEADER=(-H "Authorization: Bearer ${OPENAI_API_KEY}")
fi

echo "Endpoint:  $ENDPOINT"
echo "Model:     $MODEL"
echo "Probing tool-call support..."
echo

REQ='{
  "model": "'"$MODEL"'",
  "messages": [
    {"role":"system","content":"You are a coding assistant. When asked to perform an action, call the appropriate tool."},
    {"role":"user","content":"List the files in /tmp"}
  ],
  "tools": [{
    "type":"function",
    "function": {
      "name":"shell_exec",
      "description":"Execute a shell command and return its stdout/stderr.",
      "parameters":{
        "type":"object",
        "properties":{
          "cmd":{"type":"string","description":"Shell command to run."}
        },
        "required":["cmd"]
      }
    }
  }],
  "tool_choice": "auto"
}'

RESP="$(curl -sS "${AUTH_HEADER[@]}" \
  "$ENDPOINT/chat/completions" \
  -H 'Content-Type: application/json' \
  --data "$REQ")"

# Print the full response when -v is set
if [[ "${VERBOSE:-}" == "1" ]]; then
  echo "Full response:"
  echo "$RESP" | jq .
  echo
fi

TOOL_CALLS="$(echo "$RESP" | jq -c '.choices[0].message.tool_calls // empty')"

if [[ -z "$TOOL_CALLS" || "$TOOL_CALLS" == "null" ]]; then
  echo "❌ FAIL: model returned prose instead of tool_calls."
  echo
  echo "Likely fixes:"
  echo "  - vLLM/RHAIIS launch flags missing --enable-auto-tool-choice"
  echo "  - Wrong --tool-call-parser for this model (try: granite | hermes | llama3_json | mistral | deepseek)"
  echo "  - Model lacks instruction-following fine-tune for tool use"
  echo
  echo "Response message.content:"
  echo "$RESP" | jq -r '.choices[0].message.content'
  exit 1
fi

echo "✅ PASS: tool_calls returned"
echo
echo "$TOOL_CALLS" | jq .
