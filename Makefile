GREEN := \033[0;32m
RED   := \033[0;31m
CYAN  := \033[0;36m
NC    := \033[0m

# Positional argument support: make a2a-agent-card [agent-name]
ifeq (a2a-agent-card,$(firstword $(MAKECMDGOALS)))
  _A2A_ARGS := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
  $(eval $(_A2A_ARGS):;@:)
endif

.PHONY: help run tools tofu apply secrets check-env down push test-api test-openai test-openai-direct test-openai-via-agentgateway a2a-agent-card inventory-agents inventory-servers governance-score governance-servers governance-ui qdrant-info qdrant-collections sandbox-status sandbox-list phoenix-ui phoenix-otel-demo sandbox-demo-run sandbox-demo-clean apikey-test-unauth apikey-test-auth guardrails-test-block guardrails-test-mask guardrails-test-pass nw-policy-demo-apply nw-policy-demo-status nw-policy-demo-clean

help:
	@echo "Available targets:"
	@echo "  run     - Bootstrap the full environment (install tools, provision cluster)"
	@echo "  down    - Destroy the cluster and all resources"
	@echo "  push    - Bump patch version, tag, and push to trigger CI"
	@echo "  tools   - Install necessary tools only"
	@echo "  tofu    - Initialize OpenTofu"
	@echo "  apply   - Apply OpenTofu configuration and create secrets"
	@echo "  secrets                      - Create openai-secret from OPENAI_API_KEY and github-mcp-secret from GITHUB_TOKEN"
	@echo "  test-api                     - Run all API checks (OpenAI direct + via agentgateway)"
	@echo "  test-openai                  - Run all OpenAI checks (direct + via agentgateway)"
	@echo "  test-openai-direct           - Curl OpenAI API directly (requires OPENAI_API_KEY)"
	@echo "  test-openai-via-agentgateway - Curl OpenAI via agentgateway (port-forward auto)"
	@echo "  a2a-agent-card [agent]       - Fetch Agent Card(s) via Well-Known URI (A2A, port-forward auto)"
	@echo "                                 no arg: fetches aire-agent, github-agent, conductor-agent"
	@echo "                                 agent: fetch a single card, e.g. make a2a-agent-card github-agent"
	@echo "  inventory-agents             - List AI agents discovered by agentregistry-inventory (port-forward auto)"
	@echo "  inventory-servers            - List MCP servers discovered by agentregistry-inventory (port-forward auto)"
	@echo "  governance-score             - Fetch MCPG overall governance score (port-forward auto)"
	@echo "  governance-servers           - Fetch MCPG per-MCP-server security findings (port-forward auto)"
	@echo "  governance-ui                - Open MCPG dashboard in browser (port-forward auto)"
	@echo "  qdrant-info                  - Show Qdrant cluster info (port-forward auto)"
	@echo "  qdrant-collections           - List Qdrant collections (port-forward auto)"
	@echo ""
	@echo "Lab 5 — Agent Sandbox + Phoenix Observability:"
	@echo "  sandbox-status               - Show agent-sandbox controller health and CRD list"
	@echo "  sandbox-list                 - List all Sandbox resources in the cluster"
	@echo "  sandbox-demo-run             - Apply Lab 5 sandbox demo resources (SandboxTemplate, SandboxClaim)"
	@echo "  sandbox-demo-clean           - Delete Lab 5 sandbox demo resources"
	@echo "  phoenix-ui                   - Open Arize Phoenix UI in browser (port-forward :6006)"
	@echo "  phoenix-otel-demo            - Trigger the OTEL sandbox demo Job (sends traces to Phoenix)"
	@echo ""
	@echo "Network-policy composition (KRO + Sandbox):"
	@echo "  nw-policy-demo-apply         - Apply AgenticSandbox demo (Sandbox + Service + NetworkPolicy via KRO)"
	@echo "  nw-policy-demo-status        - Show AgenticSandbox, Sandbox, Service, NetworkPolicy status"
	@echo "  nw-policy-demo-clean         - Delete AgenticSandbox demo resources"
	@echo ""
	@echo "Additional tasks — Agentgateway security & guardrails:"
	@echo "  apikey-test-unauth           - Call agentgateway without API key (expect 401)"
	@echo "  apikey-test-auth             - Call agentgateway with valid API key (expect 200)"
	@echo "  guardrails-test-block        - Send prompt with 'block' keyword (expect 403 from guardrail)"
	@echo "  guardrails-test-mask         - Send prompt with 'mask' keyword (expect masked content)"
	@echo "  guardrails-test-pass         - Send normal prompt (expect unmodified LLM response)"

run: check-env
	@bash scripts/setup.sh

tools:
	@curl -fsSL https://get.opentofu.org/install-opentofu.sh | sh -s -- --install-method standalone
	@curl -sS https://webi.sh/k9s | bash

tofu:
	@cd bootstrap && tofu init

apply: check-env
	@cd bootstrap && tofu apply -auto-approve
	@$(MAKE) secrets

secrets: check-env
	@deadline=$$((SECONDS + 300)); \
	if ! kubectl get namespace agentgateway-system >/dev/null 2>&1; then \
		echo "Waiting for namespace agentgateway-system (up to 5 min)..."; \
		until kubectl get namespace agentgateway-system >/dev/null 2>&1; do \
			if [ $$SECONDS -ge $$deadline ]; then \
				echo "Timeout: namespace agentgateway-system not found after 5 minutes"; \
				exit 1; \
			fi; \
			sleep 5; \
		done; \
		echo "Namespace agentgateway-system is ready"; \
	fi; \
	if kubectl get secret openai-secret -n agentgateway-system >/dev/null 2>&1; then \
		echo "Secret openai-secret already exists, skipping"; \
	else \
		kubectl create secret generic openai-secret \
			--from-literal=Authorization="Bearer $$OPENAI_API_KEY" \
			-n agentgateway-system; \
	fi; \
	deadline=$$((SECONDS + 300)); \
	if ! kubectl get namespace mcp >/dev/null 2>&1; then \
		echo "Waiting for namespace mcp (up to 5 min)..."; \
		until kubectl get namespace mcp >/dev/null 2>&1; do \
			if [ $$SECONDS -ge $$deadline ]; then \
				echo "Timeout: namespace mcp not found after 5 minutes"; \
				exit 1; \
			fi; \
			sleep 5; \
		done; \
		echo "Namespace mcp is ready"; \
	fi; \
	if kubectl get secret github-mcp-secret -n mcp >/dev/null 2>&1; then \
		echo "Secret github-mcp-secret already exists, skipping"; \
	else \
		kubectl create secret generic github-mcp-secret \
			--from-literal=GITHUB_PERSONAL_ACCESS_TOKEN="$$GITHUB_TOKEN" \
			-n mcp; \
	fi

check-env:
	@if [ -z "$$OPENAI_API_KEY" ]; then \
		echo "Error: OPENAI_API_KEY is not set"; \
		exit 1; \
	fi
	@if [ -z "$$GITHUB_TOKEN" ]; then \
		echo "Error: GITHUB_TOKEN is not set (GitHub Personal Access Token required for github-mcp-secret)"; \
		exit 1; \
	fi

down:
	@cd bootstrap && tofu destroy -auto-approve

push:
	@git fetch origin --tags --force
	$(eval TAG=$(shell git tag --list 'v*' | sort -V | tail -1 | sed 's/^v//' || echo "0.0.0"))
	$(eval MAJOR=$(shell echo $(TAG) | cut -d. -f1))
	$(eval MINOR=$(shell echo $(TAG) | cut -d. -f2))
	$(eval PATCH=$(shell echo $(TAG) | cut -d. -f3))
	$(eval NEW_TAG=v$(MAJOR).$(MINOR).$(shell echo $$(($(PATCH)+1))))
	@git tag $(NEW_TAG)
	@git push origin main $(NEW_TAG)
	@echo "Tagged and pushed $(NEW_TAG)"

test-api: test-openai

test-openai: test-openai-direct test-openai-via-agentgateway

test-openai-direct: check-env
	@set -e; \
	RESP=$$(curl -sS https://api.openai.com/v1/chat/completions \
	  -H "Authorization: Bearer $$OPENAI_API_KEY" \
	  -H 'Content-Type: application/json' \
	  -d '{"model":"gpt-5.4-mini","messages":[{"role":"user","content":"Say hello from direct OpenAI test"}]}' \
	  -w '\nHTTP_STATUS:%{http_code}'); \
	STATUS=$$(printf '%s\n' "$$RESP" | sed -n 's/^HTTP_STATUS://p' | tail -n1); \
	BODY=$$(printf '%s\n' "$$RESP" | sed '$$d'); \
	if [ "$$STATUS" -ge 200 ] && [ "$$STATUS" -lt 300 ]; then \
	  printf '$(GREEN)[PASS]$(NC) openai-direct (HTTP %s)\n' "$$STATUS"; \
	else \
	  printf '$(RED)[FAIL]$(NC) openai-direct (HTTP %s)\n' "$$STATUS"; \
	fi; \
	printf '$(CYAN)Response:$(NC) %s\n' "$$BODY"; \
	[ "$$STATUS" -ge 200 ] && [ "$$STATUS" -lt 300 ]

test-openai-via-agentgateway:
	@set -e; \
	kubectl port-forward deployment/agentgateway-external -n agentgateway-system 8080:80 >/dev/null 2>&1 & \
	PF_PID=$$!; \
	trap 'kill $$PF_PID >/dev/null 2>&1 || true' EXIT; \
	sleep 2; \
	RESP=$$(curl -sS http://localhost:8080/v1beta/openai/openai/chat/completions \
	  -H 'Content-Type: application/json' \
	  -d '{"model":"gpt-5.4-mini","messages":[{"role":"user","content":"Say hello from OpenAI via agentgateway"}]}' \
	  -w '\nHTTP_STATUS:%{http_code}'); \
	STATUS=$$(printf '%s\n' "$$RESP" | sed -n 's/^HTTP_STATUS://p' | tail -n1); \
	BODY=$$(printf '%s\n' "$$RESP" | sed '$$d'); \
	if [ "$$STATUS" -ge 200 ] && [ "$$STATUS" -lt 300 ]; then \
	  printf '$(GREEN)[PASS]$(NC) openai-via-agentgateway (HTTP %s)\n' "$$STATUS"; \
	else \
	  printf '$(RED)[FAIL]$(NC) openai-via-agentgateway (HTTP %s)\n' "$$STATUS"; \
	fi; \
	printf '$(CYAN)Response:$(NC) %s\n' "$$BODY"; \
	[ "$$STATUS" -ge 200 ] && [ "$$STATUS" -lt 300 ]

a2a-agent-card:
	@if [ -z "$(_A2A_ARGS)" ]; then \
	  AGENTS="aire-agent github-agent conductor-agent"; \
	else \
	  AGENTS="$(_A2A_ARGS)"; \
	fi; \
	kubectl port-forward svc/kagent-controller 8083:8083 -n kagent >/dev/null 2>&1 & \
	PF_PID=$$!; \
	trap 'kill $$PF_PID >/dev/null 2>&1 || true' EXIT; \
	sleep 2; \
	OVERALL=0; \
	for agent in $$AGENTS; do \
	  RESP=$$(curl -sS "http://localhost:8083/api/a2a/kagent/$$agent/.well-known/agent.json" \
	    -w '\nHTTP_STATUS:%{http_code}'); \
	  STATUS=$$(printf '%s\n' "$$RESP" | sed -n 's/^HTTP_STATUS://p' | tail -n1); \
	  BODY=$$(printf '%s\n' "$$RESP" | sed '$$d'); \
	  if [ "$$STATUS" -ge 200 ] && [ "$$STATUS" -lt 300 ]; then \
	    printf "$(GREEN)[PASS]$(NC) $$agent (HTTP %s)\n" "$$STATUS"; \
	  else \
	    printf "$(RED)[FAIL]$(NC) $$agent (HTTP %s)\n" "$$STATUS"; \
	    OVERALL=1; \
	  fi; \
	  printf "$(CYAN)Agent Card [$$agent]:$(NC)\n"; \
	  printf '%s\n' "$$BODY" | jq --sort-keys .; \
	done; \
	exit $$OVERALL

inventory-agents:
	@set -e; \
	kubectl port-forward svc/agentregistry-api 8080:8080 -n agentregistry >/dev/null 2>&1 & \
	PF_PID=$$!; \
	trap 'kill $$PF_PID >/dev/null 2>&1 || true' EXIT; \
	sleep 2; \
	RESP=$$(curl -sS http://localhost:8080/v0/agents \
	  -w '\nHTTP_STATUS:%{http_code}'); \
	STATUS=$$(printf '%s\n' "$$RESP" | sed -n 's/^HTTP_STATUS://p' | tail -n1); \
	BODY=$$(printf '%s\n' "$$RESP" | sed '$$d'); \
	if [ "$$STATUS" -ge 200 ] && [ "$$STATUS" -lt 300 ]; then \
	  printf '$(GREEN)[PASS]$(NC) inventory-agents (HTTP %s)\n' "$$STATUS"; \
	else \
	  printf '$(RED)[FAIL]$(NC) inventory-agents (HTTP %s)\n' "$$STATUS"; \
	fi; \
	printf '$(CYAN)Agents:$(NC)\n'; \
	printf '%s\n' "$$BODY" | jq --sort-keys .; \
	[ "$$STATUS" -ge 200 ] && [ "$$STATUS" -lt 300 ]

inventory-servers:
	@set -e; \
	kubectl port-forward svc/agentregistry-api 8080:8080 -n agentregistry >/dev/null 2>&1 & \
	PF_PID=$$!; \
	trap 'kill $$PF_PID >/dev/null 2>&1 || true' EXIT; \
	sleep 2; \
	RESP=$$(curl -sS http://localhost:8080/v0/servers \
	  -w '\nHTTP_STATUS:%{http_code}'); \
	STATUS=$$(printf '%s\n' "$$RESP" | sed -n 's/^HTTP_STATUS://p' | tail -n1); \
	BODY=$$(printf '%s\n' "$$RESP" | sed '$$d'); \
	if [ "$$STATUS" -ge 200 ] && [ "$$STATUS" -lt 300 ]; then \
	  printf '$(GREEN)[PASS]$(NC) inventory-servers (HTTP %s)\n' "$$STATUS"; \
	else \
	  printf '$(RED)[FAIL]$(NC) inventory-servers (HTTP %s)\n' "$$STATUS"; \
	fi; \
	printf '$(CYAN)MCP Servers:$(NC)\n'; \
	printf '%s\n' "$$BODY" | jq --sort-keys .; \
	[ "$$STATUS" -ge 200 ] && [ "$$STATUS" -lt 300 ]

governance-score:
	@set -e; \
	kubectl port-forward svc/mcp-governance-controller 8090:8090 -n mcp-governance >/dev/null 2>&1 & \
	PF_PID=$$!; \
	trap 'kill $$PF_PID >/dev/null 2>&1 || true' EXIT; \
	sleep 2; \
	RESP=$$(curl -sS http://localhost:8090/api/governance/score \
	  -w '\nHTTP_STATUS:%{http_code}'); \
	STATUS=$$(printf '%s\n' "$$RESP" | sed -n 's/^HTTP_STATUS://p' | tail -n1); \
	BODY=$$(printf '%s\n' "$$RESP" | sed '$$d'); \
	if [ "$$STATUS" -ge 200 ] && [ "$$STATUS" -lt 300 ]; then \
	  printf '$(GREEN)[PASS]$(NC) governance-score (HTTP %s)\n' "$$STATUS"; \
	else \
	  printf '$(RED)[FAIL]$(NC) governance-score (HTTP %s)\n' "$$STATUS"; \
	fi; \
	printf '$(CYAN)Governance Score:$(NC)\n'; \
	printf '%s\n' "$$BODY" | jq --sort-keys .; \
	[ "$$STATUS" -ge 200 ] && [ "$$STATUS" -lt 300 ]

governance-servers:
	@set -e; \
	kubectl port-forward svc/mcp-governance-controller 8090:8090 -n mcp-governance >/dev/null 2>&1 & \
	PF_PID=$$!; \
	trap 'kill $$PF_PID >/dev/null 2>&1 || true' EXIT; \
	sleep 2; \
	RESP=$$(curl -sS http://localhost:8090/api/governance/mcp-servers \
	  -w '\nHTTP_STATUS:%{http_code}'); \
	STATUS=$$(printf '%s\n' "$$RESP" | sed -n 's/^HTTP_STATUS://p' | tail -n1); \
	BODY=$$(printf '%s\n' "$$RESP" | sed '$$d'); \
	if [ "$$STATUS" -ge 200 ] && [ "$$STATUS" -lt 300 ]; then \
	  printf '$(GREEN)[PASS]$(NC) governance-servers (HTTP %s)\n' "$$STATUS"; \
	else \
	  printf '$(RED)[FAIL]$(NC) governance-servers (HTTP %s)\n' "$$STATUS"; \
	fi; \
	printf '$(CYAN)MCP Server Findings:$(NC)\n'; \
	printf '%s\n' "$$BODY" | jq --sort-keys .; \
	[ "$$STATUS" -ge 200 ] && [ "$$STATUS" -lt 300 ]

governance-ui:
	@echo "Port-forwarding MCPG dashboard to http://localhost:3000 — press Ctrl+C to stop"; \
	kubectl port-forward svc/mcp-governance-dashboard 3000:3000 -n mcp-governance

qdrant-info:
	@set -e; \
	kubectl port-forward svc/qdrant 6333:6333 -n qdrant >/dev/null 2>&1 & \
	PF_PID=$$!; \
	trap 'kill $$PF_PID >/dev/null 2>&1 || true' EXIT; \
	sleep 2; \
	RESP=$$(curl -sS http://localhost:6333 \
	  -w '\nHTTP_STATUS:%{http_code}'); \
	STATUS=$$(printf '%s\n' "$$RESP" | sed -n 's/^HTTP_STATUS://p' | tail -n1); \
	BODY=$$(printf '%s\n' "$$RESP" | sed '$$d'); \
	if [ "$$STATUS" -ge 200 ] && [ "$$STATUS" -lt 300 ]; then \
	  printf '$(GREEN)[PASS]$(NC) qdrant-info (HTTP %s)\n' "$$STATUS"; \
	else \
	  printf '$(RED)[FAIL]$(NC) qdrant-info (HTTP %s)\n' "$$STATUS"; \
	fi; \
	printf '$(CYAN)Qdrant Info:$(NC)\n'; \
	printf '%s\n' "$$BODY" | jq --sort-keys .; \
	[ "$$STATUS" -ge 200 ] && [ "$$STATUS" -lt 300 ]

qdrant-collections:
	@set -e; \
	kubectl port-forward svc/qdrant 6333:6333 -n qdrant >/dev/null 2>&1 & \
	PF_PID=$$!; \
	trap 'kill $$PF_PID >/dev/null 2>&1 || true' EXIT; \
	sleep 2; \
	RESP=$$(curl -sS http://localhost:6333/collections \
	  -w '\nHTTP_STATUS:%{http_code}'); \
	STATUS=$$(printf '%s\n' "$$RESP" | sed -n 's/^HTTP_STATUS://p' | tail -n1); \
	BODY=$$(printf '%s\n' "$$RESP" | sed '$$d'); \
	if [ "$$STATUS" -ge 200 ] && [ "$$STATUS" -lt 300 ]; then \
	  printf '$(GREEN)[PASS]$(NC) qdrant-collections (HTTP %s)\n' "$$STATUS"; \
	else \
	  printf '$(RED)[FAIL]$(NC) qdrant-collections (HTTP %s)\n' "$$STATUS"; \
	fi; \
	printf '$(CYAN)Collections:$(NC)\n'; \
	printf '%s\n' "$$BODY" | jq --sort-keys .; \
	[ "$$STATUS" -ge 200 ] && [ "$$STATUS" -lt 300 ]

# =============================================================================
# Lab 5 — Agent Sandbox + Arize Phoenix Observability
# =============================================================================

sandbox-status:
	@echo "$(CYAN)=== Agent Sandbox Controller ===$(NC)"
	@kubectl rollout status deployment/agent-sandbox-controller -n agent-sandbox-system 2>/dev/null \
	  && printf '$(GREEN)[PASS]$(NC) agent-sandbox-controller is ready\n' \
	  || printf '$(RED)[FAIL]$(NC) agent-sandbox-controller not ready (is agent-sandbox.yaml deployed?)\n'
	@echo ""
	@echo "$(CYAN)CRDs installed:$(NC)"
	@kubectl get crds | grep -E 'agents.x-k8s.io|extensions.agents.x-k8s.io' || echo "  (none found)"

sandbox-list:
	@echo "$(CYAN)=== Sandboxes in all namespaces ===$(NC)"
	@kubectl get sandboxes -A 2>/dev/null || echo "  (no sandboxes or CRD not installed)"
	@echo ""
	@echo "$(CYAN)=== SandboxClaims ===$(NC)"
	@kubectl get sandboxclaims -A 2>/dev/null || echo "  (none)"
	@echo ""
	@echo "$(CYAN)=== SandboxTemplates ===$(NC)"
	@kubectl get sandboxtemplates -A 2>/dev/null || echo "  (none)"

sandbox-demo-run:
	@echo "Applying Lab 5 sandbox demo resources..."
	@kubectl apply -k releases/lab5/
	@echo ""
	@echo "$(CYAN)SandboxTemplate:$(NC)"
	@kubectl get sandboxtemplate -n sandboxes 2>/dev/null || true
	@echo "$(CYAN)SandboxClaim:$(NC)"
	@kubectl get sandboxclaim -n sandboxes 2>/dev/null || true

sandbox-demo-clean:
	@echo "Deleting Lab 5 sandbox demo resources..."
	@kubectl delete -k releases/lab5/ --ignore-not-found=true
	@kubectl delete namespace sandboxes --ignore-not-found=true

phoenix-ui:
	@echo "Port-forwarding Arize Phoenix UI to http://localhost:6006 — press Ctrl+C to stop"
	@kubectl port-forward svc/phoenix-svc 6006:6006 -n phoenix

phoenix-otel-demo:
	@echo "$(CYAN)Triggering OTEL sandbox demo Job (traces → Phoenix)...$(NC)"
	@kubectl delete job sandbox-otel-demo -n sandboxes --ignore-not-found=true >/dev/null 2>&1
	@kubectl apply -f releases/lab5/sandbox-otel-demo.yaml
	@echo ""
	@echo "$(CYAN)Waiting for Job to complete (up to 3 min)...$(NC)"
	@kubectl wait job/sandbox-otel-demo -n sandboxes --for=condition=complete --timeout=180s \
	  && printf '$(GREEN)[PASS]$(NC) Demo Job completed — check Phoenix UI: make phoenix-ui\n' \
	  || printf '$(RED)[FAIL]$(NC) Job did not complete in time. Check logs:\n  kubectl logs -n sandboxes -l job-name=sandbox-otel-demo\n'

# =============================================================================
# Additional Tasks — Agentgateway API Key Auth & Guardrails
# =============================================================================

# Shared port-forward helper (background, auto-killed via trap)
_AGW_URL := http://localhost:8080/v1beta/openai/openai/chat/completions
_AGW_APIKEY := abox-demo-api-key-2024

apikey-test-unauth:
	@echo "$(CYAN)Testing API key auth — no key (expect 401)...$(NC)"
	@set -e; \
	kubectl port-forward deployment/agentgateway-external -n agentgateway-system 8080:80 >/dev/null 2>&1 & \
	PF_PID=$$!; \
	trap 'kill $$PF_PID >/dev/null 2>&1 || true' EXIT; \
	sleep 2; \
	RESP=$$(curl -sS $(_AGW_URL) \
	  -H 'Content-Type: application/json' \
	  -d '{"model":"gpt-5.4-mini","messages":[{"role":"user","content":"hello"}]}' \
	  -w '\nHTTP_STATUS:%{http_code}'); \
	STATUS=$$(printf '%s\n' "$$RESP" | sed -n 's/^HTTP_STATUS://p' | tail -n1); \
	if [ "$$STATUS" -eq 401 ]; then \
	  printf '$(GREEN)[PASS]$(NC) Got 401 Unauthorized — API key auth is enforced\n'; \
	else \
	  printf '$(RED)[FAIL]$(NC) Expected 401, got HTTP %s\n' "$$STATUS"; \
	fi

apikey-test-auth:
	@echo "$(CYAN)Testing API key auth — valid key (expect 200)...$(NC)"
	@set -e; \
	kubectl port-forward deployment/agentgateway-external -n agentgateway-system 8080:80 >/dev/null 2>&1 & \
	PF_PID=$$!; \
	trap 'kill $$PF_PID >/dev/null 2>&1 || true' EXIT; \
	sleep 2; \
	RESP=$$(curl -sS $(_AGW_URL) \
	  -H 'Content-Type: application/json' \
	  -H 'Authorization: Bearer $(_AGW_APIKEY)' \
	  -d '{"model":"gpt-5.4-mini","messages":[{"role":"user","content":"Say hello"}]}' \
	  -w '\nHTTP_STATUS:%{http_code}'); \
	STATUS=$$(printf '%s\n' "$$RESP" | sed -n 's/^HTTP_STATUS://p' | tail -n1); \
	BODY=$$(printf '%s\n' "$$RESP" | sed '$$d'); \
	if [ "$$STATUS" -ge 200 ] && [ "$$STATUS" -lt 300 ]; then \
	  printf '$(GREEN)[PASS]$(NC) Got HTTP %s — request accepted with valid API key\n' "$$STATUS"; \
	else \
	  printf '$(RED)[FAIL]$(NC) Expected 2xx, got HTTP %s\n' "$$STATUS"; \
	fi; \
	printf '$(CYAN)Response:$(NC) %s\n' "$$BODY"

guardrails-test-block:
	@echo "$(CYAN)Testing guardrails — 'block' keyword in prompt (expect 403)...$(NC)"
	@set -e; \
	kubectl port-forward deployment/agentgateway-external -n agentgateway-system 8080:80 >/dev/null 2>&1 & \
	PF_PID=$$!; \
	trap 'kill $$PF_PID >/dev/null 2>&1 || true' EXIT; \
	sleep 2; \
	RESP=$$(curl -sS $(_AGW_URL) \
	  -H 'Content-Type: application/json' \
	  -H 'Authorization: Bearer $(_AGW_APIKEY)' \
	  -d '{"model":"gpt-5.4-mini","messages":[{"role":"user","content":"Please block this request"}]}' \
	  -w '\nHTTP_STATUS:%{http_code}'); \
	STATUS=$$(printf '%s\n' "$$RESP" | sed -n 's/^HTTP_STATUS://p' | tail -n1); \
	BODY=$$(printf '%s\n' "$$RESP" | sed '$$d'); \
	if [ "$$STATUS" -eq 403 ]; then \
	  printf '$(GREEN)[PASS]$(NC) Got 403 — guardrail blocked the request\n'; \
	else \
	  printf '$(RED)[FAIL]$(NC) Expected 403 from guardrail, got HTTP %s\n' "$$STATUS"; \
	fi; \
	printf '$(CYAN)Body:$(NC) %s\n' "$$BODY"

guardrails-test-mask:
	@echo "$(CYAN)Testing guardrails — 'mask' keyword in prompt (expect masked content)...$(NC)"
	@set -e; \
	kubectl port-forward deployment/agentgateway-external -n agentgateway-system 8080:80 >/dev/null 2>&1 & \
	PF_PID=$$!; \
	trap 'kill $$PF_PID >/dev/null 2>&1 || true' EXIT; \
	sleep 2; \
	RESP=$$(curl -sS $(_AGW_URL) \
	  -H 'Content-Type: application/json' \
	  -H 'Authorization: Bearer $(_AGW_APIKEY)' \
	  -d '{"model":"gpt-5.4-mini","messages":[{"role":"user","content":"mask my secret token abc123"}]}' \
	  -w '\nHTTP_STATUS:%{http_code}'); \
	STATUS=$$(printf '%s\n' "$$RESP" | sed -n 's/^HTTP_STATUS://p' | tail -n1); \
	BODY=$$(printf '%s\n' "$$RESP" | sed '$$d'); \
	printf '$(CYAN)HTTP %s — check that prompt reached LLM with "mask" replaced by "****"\n$(NC)' "$$STATUS"; \
	printf '$(CYAN)Response:$(NC) %s\n' "$$BODY"

guardrails-test-pass:
	@echo "$(CYAN)Testing guardrails — normal prompt (expect LLM response, no blocking)...$(NC)"
	@set -e; \
	kubectl port-forward deployment/agentgateway-external -n agentgateway-system 8080:80 >/dev/null 2>&1 & \
	PF_PID=$$!; \
	trap 'kill $$PF_PID >/dev/null 2>&1 || true' EXIT; \
	sleep 2; \
	RESP=$$(curl -sS $(_AGW_URL) \
	  -H 'Content-Type: application/json' \
	  -H 'Authorization: Bearer $(_AGW_APIKEY)' \
	  -d '{"model":"gpt-5.4-mini","messages":[{"role":"user","content":"What is 2+2?"}]}' \
	  -w '\nHTTP_STATUS:%{http_code}'); \
	STATUS=$$(printf '%s\n' "$$RESP" | sed -n 's/^HTTP_STATUS://p' | tail -n1); \
	BODY=$$(printf '%s\n' "$$RESP" | sed '$$d'); \
	if [ "$$STATUS" -ge 200 ] && [ "$$STATUS" -lt 300 ]; then \
	  printf '$(GREEN)[PASS]$(NC) HTTP %s — guardrail passed the request through\n' "$$STATUS"; \
	else \
	  printf '$(RED)[FAIL]$(NC) Unexpected HTTP %s\n' "$$STATUS"; \
	fi; \
	printf '$(CYAN)Response:$(NC) %s\n' "$$BODY"

# ── Network-policy demo (KRO + AgenticSandbox) ───────────────────────────────

nw-policy-demo-apply:
	@echo "$(CYAN)Step 1/3 — Applying Namespace + ResourceGraphDefinition...$(NC)"
	@kubectl apply -f releases/lab5/network-policies.yaml 2>&1 | grep -v "no matches for kind" || true
	@echo ""
	@echo "$(CYAN)Step 2/3 — Waiting for KRO to register AgenticSandbox CRD (up to 60s)...$(NC)"
	@deadline=$$((SECONDS + 60)); \
	until kubectl get crd agenticsandboxes.custom.agents.x-k8s.io >/dev/null 2>&1; do \
	  if [ $$SECONDS -ge $$deadline ]; then \
	    printf '\n$(RED)Timeout: AgenticSandbox CRD not registered after 60s$(NC)\n'; exit 1; \
	  fi; \
	  printf '.'; sleep 3; \
	done; \
	echo " Ready."
	@echo ""
	@echo "$(CYAN)Step 3/3 — Applying AgenticSandbox demo instance...$(NC)"
	kubectl apply -f releases/lab5/network-policies.yaml
	@echo ""
	@echo "$(CYAN)KRO will reconcile AgenticSandbox 'demo' into Sandbox + Service + NetworkPolicy.$(NC)"
	@echo "Run 'make nw-policy-demo-status' to watch progress."

nw-policy-demo-status:
	@echo "$(CYAN)=== KRO ResourceGraphDefinition ===$(NC)"
	kubectl get resourcegraphdefinition agentic-sandbox -n sandboxes-nw 2>/dev/null || echo "  (not found — KRO may still be installing)"
	@echo ""
	@echo "$(CYAN)=== AgenticSandbox instances ===$(NC)"
	kubectl get agenticsandboxes -n sandboxes-nw 2>/dev/null || echo "  (CRD not yet registered by KRO)"
	@echo ""
	@echo "$(CYAN)=== Sandbox pods ===$(NC)"
	kubectl get sandboxes -n sandboxes-nw 2>/dev/null || echo "  (none)"
	kubectl get pods -n sandboxes-nw -l sandbox=demo 2>/dev/null || true
	@echo ""
	@echo "$(CYAN)=== Service ===$(NC)"
	kubectl get svc -n sandboxes-nw 2>/dev/null || true
	@echo ""
	@echo "$(CYAN)=== NetworkPolicy ===$(NC)"
	kubectl get networkpolicy -n sandboxes-nw 2>/dev/null || echo "  (none — networkPolicy.enabled may be false)"
	kubectl describe networkpolicy allow-frontend-to-backend -n sandboxes-nw 2>/dev/null || true

nw-policy-demo-clean:
	@echo "$(CYAN)Deleting AgenticSandbox demo resources...$(NC)"
	kubectl delete agenticsandbox demo -n sandboxes-nw 2>/dev/null || true
	kubectl delete resourcegraphdefinition agentic-sandbox -n sandboxes-nw 2>/dev/null || true
	kubectl delete namespace sandboxes-nw 2>/dev/null || true
	@echo "$(GREEN)Done.$(NC)"
