GREEN := \033[0;32m
RED   := \033[0;31m
CYAN  := \033[0;36m
NC    := \033[0m

.PHONY: help run tools tofu apply secrets check-env down push test-api test-agentgateway-endpoint test-openai test-openai-direct test-openai-via-agentgateway

help:
	@echo "Available targets:"
	@echo "  run     - Bootstrap the full environment (install tools, provision cluster)"
	@echo "  down    - Destroy the cluster and all resources"
	@echo "  push    - Bump patch version, tag, and push to trigger CI"
	@echo "  tools   - Install necessary tools only"
	@echo "  tofu    - Initialize OpenTofu"
	@echo "  apply   - Apply OpenTofu configuration and create secrets"
	@echo "  secrets                      - Create openai-secret secret from OPENAI_API_KEY"
	@echo "  test-api                     - Run all API checks (agentgateway endpoint + OpenAI direct + via agentgateway)"
	@echo "  test-agentgateway-endpoint   - Curl agentgateway OpenAI-compatible endpoint"
	@echo "  test-openai                  - Run all OpenAI checks (direct + via agentgateway)"
	@echo "  test-openai-direct           - Curl OpenAI API directly (requires OPENAI_API_KEY)"
	@echo "  test-openai-via-agentgateway - Curl OpenAI via agentgateway (port-forward auto)"

run:
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
	fi

check-env:
	@if [ -z "$$OPENAI_API_KEY" ]; then \
		echo "Error: OPENAI_API_KEY is not set"; \
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

test-api: test-agentgateway-endpoint test-openai

test-agentgateway-endpoint:
	@set -e; \
	kubectl port-forward deployment/agentgateway-external -n agentgateway-system 8080:80 >/dev/null 2>&1 & \
	PF_PID=$$!; \
	trap 'kill $$PF_PID >/dev/null 2>&1 || true' EXIT; \
	sleep 2; \
	RESP=$$(curl -sS http://localhost:8080/v1beta/openai/chat/completions \
	  -H 'Content-Type: application/json' \
	  -d '{"model":"","messages":[{"role":"user","content":"Say hello from OpenAI-compatible agentgateway endpoint"}]}' \
	  -w '\nHTTP_STATUS:%{http_code}'); \
	STATUS=$$(printf '%s\n' "$$RESP" | sed -n 's/^HTTP_STATUS://p' | tail -n1); \
	BODY=$$(printf '%s\n' "$$RESP" | sed '$$d'); \
	if [ "$$STATUS" -ge 200 ] && [ "$$STATUS" -lt 300 ]; then \
	  printf '$(GREEN)[PASS]$(NC) agentgateway-endpoint (HTTP %s)\n' "$$STATUS"; \
	else \
	  printf '$(RED)[FAIL]$(NC) agentgateway-endpoint (HTTP %s)\n' "$$STATUS"; \
	fi; \
	printf '$(CYAN)Response:$(NC) %s\n' "$$BODY"; \
	[ "$$STATUS" -ge 200 ] && [ "$$STATUS" -lt 300 ]

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
