# Booth ops cheat-sheet, in target form. Each target wraps a script
# under scripts/ so the canonical implementation stays there and the
# Makefile is just ergonomics.

# Run from anywhere — most scripts expect REPO_ROOT-aware paths.
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

REPO_ROOT := $(shell git rev-parse --show-toplevel)

.PHONY: help reset reset-plan promote-demoadmins register-webhook tail-bridge status

# -------- help --------------------------------------------------------------

help:
	@echo "Booth ops targets:"
	@echo ""
	@echo "  reset             Interactive reset of per-event demo state."
	@echo "                    Shows what would be deleted, prompts y/N, then deletes."
	@echo "                    Touches: Coder workspaces + chats for demo personas,"
	@echo "                    GitLab issues in demo projects."
	@echo "                    Preserves: users, projects, repo contents, IaC,"
	@echo "                    templates, vLLM, bridge."
	@echo ""
	@echo "  reset-plan        Dry-run of the reset — lists what'd be deleted."
	@echo "                    Makes no changes."
	@echo ""
	@echo "  promote-demoadmins"
	@echo "                    Re-run the Keycloak->GitLab admin promotion script"
	@echo "                    (idempotent; useful after GitLab state is reset)."
	@echo ""
	@echo "  register-webhook  Register the bridge as a GitLab webhook on demo"
	@echo "                    projects (idempotent; useful for fresh projects)."
	@echo ""
	@echo "  tail-bridge       Tail the bridge service's logs."
	@echo ""
	@echo "  status            One-screen overview of deployed apps + Coder/Llama state."
	@echo ""
	@echo "Env vars for reset / register-webhook:"
	@echo "  DEMO_PERSONAS  comma-separated (default: alice,bob,carol,dave,demoadm)"
	@echo "  DEMO_PROJECTS  comma-separated (default: alice/artemis-sim)"
	@echo "  GITLAB_DEMO_PROJECTS  alias used by the webhook helper"
	@echo ""
	@echo "All scripts require admin kube context (\`oc login\`) and, for"
	@echo "GitLab operations, SSH access to the GitLab EC2 host."

# -------- reset -------------------------------------------------------------

reset:
	@$(REPO_ROOT)/scripts/reset-demo.sh

reset-plan:
	@$(REPO_ROOT)/scripts/reset-demo.sh --plan

# -------- one-off operator helpers -----------------------------------------

promote-demoadmins:
	@$(REPO_ROOT)/scripts/gitlab-promote-demoadmins.sh

register-webhook:
	@$(REPO_ROOT)/scripts/gitlab-register-bridge-webhook.sh

# -------- observability ----------------------------------------------------

tail-bridge:
	@oc -n coder logs deploy/bridge -f --tail=50

status:
	@echo "==> Argo apps"
	@oc -n openshift-gitops get applications -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status --no-headers | column -t
	@echo ""
	@echo "==> vLLM pods"
	@oc -n ocp-ai get pods -l app.kubernetes.io/name=vllm,app.kubernetes.io/name!=vllm-experiment -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready,NODE:.spec.nodeName --no-headers 2>/dev/null | column -t || true
	@echo ""
	@echo "==> Bridge"
	@oc -n coder get pods -l app.kubernetes.io/name=bridge -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready --no-headers 2>/dev/null | column -t || true
	@echo ""
	@echo "==> Coder chatd default model"
	@CODER_TOKEN=$$(oc -n coder get secret coder-admin-token -o jsonpath='{.data.token}' | base64 -d) ; \
	  curl -sk -H "Coder-Session-Token: $$CODER_TOKEN" https://coder.apps.cluster.rhsummit.coderdemo.io/api/experimental/chats/model-configs \
	  | jq -r '.[] | select(.is_default==true) | "default: \(.display_name)  (id=\(.id))"' 2>/dev/null || true
