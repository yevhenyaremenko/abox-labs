GREEN := \033[0;32m
RED   := \033[0;31m
CYAN  := \033[0;36m
NC    := \033[0m

.PHONY: help run tools tofu apply secrets check-env down push test-api test-openai test-openai-direct test-openai-via-agentgateway a2a-agent-card inventory-agents inventory-servers governance-score governance-servers governance-ui

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
	@echo "  a2a-agent-card               - Fetch aire-agent Agent Card via Well-Known URI (A2A, port-forward auto)"
	@echo "  inventory-agents             - List AI agents discovered by agentregistry-inventory (port-forward auto)"
	@echo "  inventory-servers            - List MCP servers discovered by agentregistry-inventory (port-forward auto)"
	@echo "  governance-score             - Fetch MCPG overall governance score (port-forward auto)"
	@echo "  governance-servers           - Fetch MCPG per-MCP-server security findings (port-forward auto)"
	@echo "  governance-ui                - Open MCPG dashboard in browser (port-forward auto)"

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
	@set -e; \
	kubectl port-forward svc/kagent-controller 8083:8083 -n kagent >/dev/null 2>&1 & \
	PF_PID=$$!; \
	trap 'kill $$PF_PID >/dev/null 2>&1 || true' EXIT; \
	sleep 2; \
	RESP=$$(curl -sS http://localhost:8083/api/a2a/kagent/aire-agent/.well-known/agent.json \
	  -w '\nHTTP_STATUS:%{http_code}'); \
	STATUS=$$(printf '%s\n' "$$RESP" | sed -n 's/^HTTP_STATUS://p' | tail -n1); \
	BODY=$$(printf '%s\n' "$$RESP" | sed '$$d'); \
	if [ "$$STATUS" -ge 200 ] && [ "$$STATUS" -lt 300 ]; then \
	  printf '$(GREEN)[PASS]$(NC) a2a-agent-card (HTTP %s)\n' "$$STATUS"; \
	else \
	  printf '$(RED)[FAIL]$(NC) a2a-agent-card (HTTP %s)\n' "$$STATUS"; \
	fi; \
	printf '$(CYAN)Agent Card:$(NC)\n%s\n' "$$BODY"; \
	[ "$$STATUS" -ge 200 ] && [ "$$STATUS" -lt 300 ]

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
	printf '$(CYAN)Agents:$(NC)\n%s\n' "$$BODY"; \
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
	printf '$(CYAN)MCP Servers:$(NC)\n%s\n' "$$BODY"; \
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
	printf '$(CYAN)Governance Score:$(NC)\n%s\n' "$$BODY"; \
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
	printf '$(CYAN)MCP Server Findings:$(NC)\n%s\n' "$$BODY"; \
	[ "$$STATUS" -ge 200 ] && [ "$$STATUS" -lt 300 ]

governance-ui:
	@echo "Port-forwarding MCPG dashboard to http://localhost:3000 — press Ctrl+C to stop"; \
	kubectl port-forward svc/mcp-governance-dashboard 3000:3000 -n mcp-governance
