# Booth ops cheat-sheet, in target form. Each target wraps a script
# under scripts/ so the canonical implementation stays there and the
# Makefile is just ergonomics.

# Run from anywhere — most scripts expect REPO_ROOT-aware paths.
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

REPO_ROOT := $(shell git rev-parse --show-toplevel)

.PHONY: help reset reset-plan promote-demoadmins register-webhook tail-bridge status \
        catalog-preflight catalog-configure catalog-secrets catalog-personas \
        catalog-postdeploy catalog-deploy

# -------- help --------------------------------------------------------------

help:
	@echo "Catalog-deploy targets (fresh AWS account → demo-ready):"
	@echo ""
	@echo "  catalog-preflight   Verify tooling, AWS auth, quotas, R53 zone, OAuth org."
	@echo "                      Run before 'cd terraform && terraform apply'."
	@echo "                      See docs/FRESH-ACCOUNT-BOOTSTRAP.md Step 2."
	@echo ""
	@echo "  catalog-configure   Substitute booth hostnames for the new cluster's"
	@echo "                      values across 25 manifests + scripts. Reads"
	@echo "                      terraform/ outputs OR env vars."
	@echo ""
	@echo "  catalog-secrets     Interactive walkthrough for sealing the 14 per-deploy"
	@echo "                      secrets via kubeseal. Skips files that already exist;"
	@echo "                      use --force <name> to overwrite."
	@echo ""
	@echo "  catalog-personas    Pre-create alice/bob/demoadm in GitLab with Keycloak"
	@echo "                      OIDC identity links + project memberships."
	@echo "                      Run after GitLab is up and Keycloak is reconciled."
	@echo ""
	@echo "  catalog-postdeploy  Verify cluster + Argo health, Coder API, Bridge,"
	@echo "                      GitLab, chatd providers, Loki ingest, grafana-agent"
	@echo "                      privileged DS. Run after Argo Synced+Healthy."
	@echo ""
	@echo "  catalog-deploy      Full chained flow: preflight → reminder to run TF →"
	@echo "                      configure → secrets → root-app → personas → smoke."
	@echo "                      Idempotent."
	@echo ""
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

# -------- catalog-deploy ---------------------------------------------------

catalog-preflight:
	@$(REPO_ROOT)/scripts/catalog-preflight.sh

catalog-configure:
	@$(REPO_ROOT)/scripts/configure-manifests.sh --terraform-dir $(REPO_ROOT)/terraform

catalog-secrets:
	@$(REPO_ROOT)/scripts/bootstrap-sealed-secrets.sh

catalog-personas:
	@$(REPO_ROOT)/scripts/gitlab-bootstrap-personas.sh

catalog-postdeploy:
	@$(REPO_ROOT)/scripts/catalog-postdeploy-smoke.sh

# Orchestrates the full flow. Each step is individually idempotent so
# re-running this target after a partial failure is safe. The 'terraform
# apply' step is intentionally NOT chained — destructive infra moves
# require explicit operator review of the plan.
catalog-deploy: catalog-preflight
	@echo ""
	@echo "============================================================"
	@echo "Preflight passed. Next: run terraform apply manually:"
	@echo "    cd terraform && terraform apply"
	@echo ""
	@echo "Once cluster is up + KUBECONFIG points at it, run:"
	@echo "    make catalog-configure"
	@echo "    git commit -am 'chore: configure for new cluster' && git push"
	@echo "    oc apply -f gitops/bootstrap/root-app.yaml"
	@echo "    oc -n openshift-gitops wait --for=condition=Healthy app/sealed-secrets --timeout=180s"
	@echo "    make catalog-secrets"
	@echo "    git commit -am 'feat(secrets): seal per-deploy secrets' && git push"
	@echo "    # wait for Argo sync (5-10 min)"
	@echo "    make catalog-personas"
	@echo "    make catalog-postdeploy"
	@echo "============================================================"

# -------- legacy + observability ------------------------------------------

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
