<!--
Intentionally empty (2026-05-11). Coder Agents runs on the built-in
default system prompt (chatd's DefaultSystemPrompt). We previously
maintained ~8 KiB of override rules here trying to guide Llama 70B INT4
through edge cases (spawn loops, wait_agent JSON types, sub-agent tool
palette, etc.); the overrides did not stick — Llama-INT4 follows the
default's positive instructions ("use AS MANY TOOLS") but ignores
restrictive overrides. Sonnet/Opus handle the same flows correctly
without any appendix.

Decision: ship default-only. Booth demo runs on Claude Sonnet 4.6 as the
chatd default (`coder-agent` label); sovereign Llama is opt-in via
`coder-agent:llama` with the understanding that its agentic-loop
behavior is weaker than the Bedrock models.

See docs/decisions.md §34 for the reversal write-up. To re-add targeted
overrides in the future, edit this file then re-run
scripts/render-coder-agents-configmap.sh to update the bootstrap Job's
ConfigMap; the agents-config Job will PUT the new content to
/api/experimental/chats/config/system-prompt on its next Argo sync.
-->
