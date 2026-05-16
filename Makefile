help:
	@echo "Available targets:"
	@echo "  run     - Bootstrap the full environment (install tools, provision cluster)"
	@echo "  down    - Destroy the cluster and all resources"
	@echo "  push    - Bump patch version, tag, and push to trigger CI"
	@echo "  tools   - Install necessary tools only"
	@echo "  tofu    - Initialize OpenTofu"
	@echo "  apply   - Apply OpenTofu configuration and create secrets"
	@echo "  secrets - Create agentgateway-credentials secret from OPENAI_API_KEY"

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
	if kubectl get secret agentgateway-credentials -n agentgateway-system >/dev/null 2>&1; then \
		echo "Secret agentgateway-credentials already exists, skipping"; \
	else \
		kubectl create secret generic agentgateway-credentials \
			--from-literal=openai-api-key="$$OPENAI_API_KEY" \
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
