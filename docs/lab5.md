# Lab 5 — Agent Sandbox & Observability with Arize Phoenix

## Overview

| Task | Component | Status |
|------|-----------|--------|
| Install Agent Sandbox controller | `releases/agent-sandbox.yaml` + `releases/crds/agent-sandbox-crds.yaml` | 🟢 Automated via Flux |
| Expose controller metrics | Prometheus annotations on Deployment, Service on :8080 | 🟢 Included |
| Deploy Arize Phoenix | `releases/phoenix.yaml` (Helm, OCI) | 🟢 Automated via Flux |
| Agent Sandbox OTEL → Phoenix | `releases/lab5/sandbox-otel-demo.yaml` (Job) | 🟢 `make phoenix-otel-demo` |
| MCP server tracing → Phoenix | `releases/lab5/mcp-tracing-patch.yaml` + code changes | ⚠️ Needs image rebuild |

---

## Part 1 — Agent Sandbox Controller

### What is Agent Sandbox?

[Agent Sandbox](https://agent-sandbox.sigs.k8s.io) (kubernetes-sigs) is a Kubernetes controller that
provides isolated, stateful, singleton workloads — ideal for AI agent runtimes.

**CRDs installed (v0.4.6):**

| CRD | Group | Purpose |
|-----|-------|---------|
| `Sandbox` | `agents.x-k8s.io` | Core: stateful singleton pod with stable identity & PVC |
| `SandboxTemplate` | `extensions.agents.x-k8s.io` | Reusable pod templates |
| `SandboxClaim` | `extensions.agents.x-k8s.io` | User-friendly claim → provisions a Sandbox |
| `SandboxWarmPool` | `extensions.agents.x-k8s.io` | Pre-warmed sandbox pool for fast starts |

### Installation

CRDs are applied first via the `releases-crds` Flux Kustomization:
```
releases/crds/agent-sandbox-crds.yaml   ← 4 CRDs from v0.4.6
releases/crds/kustomization.yaml        ← includes agent-sandbox-crds.yaml
```

Controller (non-CRD resources) is applied via the main `releases` Kustomization:
```
releases/agent-sandbox.yaml             ← Namespace, RBAC, Service, Deployment
releases/kustomization.yaml             ← includes agent-sandbox.yaml
```

### Controller Metrics

The controller exposes standard [controller-runtime](https://book.kubebuilder.io/reference/metrics.html) Prometheus metrics on port **8080** at `/metrics`.

The Deployment has `prometheus.io/scrape: "true"` annotations for auto-discovery.

```bash
# Inspect metrics (manual port-forward)
kubectl port-forward svc/agent-sandbox-controller 8080:8080 -n agent-sandbox-system
curl -s http://localhost:8080/metrics | grep sandbox
```

Example metrics:
- `controller_runtime_reconcile_total` — reconciliation counts (by controller, result)
- `controller_runtime_reconcile_errors_total` — reconciliation errors
- `workqueue_depth` — queue depth per controller
- `workqueue_work_duration_seconds` — processing latency

### Verify Installation

```bash
make sandbox-status     # controller health + CRD list
make sandbox-list       # list all Sandbox/Claim/Template resources
```

---

## Part 2 — Agent Sandbox OTEL Telemetry Collection

### Architecture

```
Python Job (sandbox-otel-demo)
  ↓  opentelemetry-instrument wrapper
  ↓  OTLP HTTP (port 6006)
Arize Phoenix
  ↓  UI at http://localhost:6006
```

### How It Works

`releases/lab5/sandbox-otel-demo.yaml` deploys a Kubernetes **Job** that:

1. **init-container** installs Python SDK + OTel packages into an `emptyDir` volume
2. **main container** runs `opentelemetry-instrument` CLI wrapper around `demo.py`
   - Instruments all outbound HTTP requests (to Kubernetes API) automatically
   - Exports traces + metrics to Phoenix via OTLP HTTP
3. **demo.py** script:
   - Creates a `Sandbox` via the Kubernetes `agents.x-k8s.io/v1alpha1` API
   - Waits for the Sandbox to reach `Ready` condition
   - Lists all sandboxes
   - Deletes the sandbox

### Run the Demo

```bash
# Make sure Phoenix is up first
make phoenix-ui &   # opens http://localhost:6006

# Trigger the demo job
make phoenix-otel-demo

# View traces in Phoenix at http://localhost:6006
# Project: "agent-sandbox-demo"
```

### Key OTEL Environment Variables

| Variable | Value | Purpose |
|----------|-------|---------|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://phoenix.phoenix.svc.cluster.local:6006` | Phoenix OTLP HTTP endpoint |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/protobuf` | Wire format |
| `OTEL_SERVICE_NAME` | `agent-sandbox-demo` | Shown in Phoenix traces |
| `OTEL_RESOURCE_ATTRIBUTES` | `deployment.environment=lab5,...` | Extra span attributes |

---

## Part 3 — Arize Phoenix Deployment

**Chart:** `oci://registry-1.docker.io/arizephoenix/phoenix-helm` **v8.0.0**  
**Namespace:** `phoenix`  
**UI port:** 6006 (HTTP + OTLP receiver)  

```bash
make phoenix-ui          # port-forward → http://localhost:6006
```

**In-cluster OTLP endpoints:**
- HTTP: `http://phoenix.phoenix.svc.cluster.local:6006/v1/traces`
- gRPC: `http://phoenix.phoenix.svc.cluster.local:4317`

Managed by `releases/phoenix.yaml` (Flux HelmRelease, `OCIRepository` source).

---

## Part 4 — MCP Server Phoenix Tracing

### Architecture

```
kagent → elicitation-mcp-server
              ↓ OTLP (openinference-instrumentation-mcp)
         Arize Phoenix
```

### Code Changes Required (abox-labs-mcp-server repo)

The MCP server needs two changes before the `mcp-tracing-patch.yaml` env vars take effect:

#### 1. `pyproject.toml` — add dependencies

```toml
dependencies = [
    # ... existing deps ...
    "arize-phoenix-otel>=0.6.0",
    "openinference-instrumentation-mcp>=0.1.0",
]
```

#### 2. `src/abox_labs_mcp_server/main.py` — register Phoenix tracer

Add at the **top of the file** (before FastMCP initialisation):

```python
import os
from phoenix.otel import register as _phoenix_register

# Instrument MCP server — context propagation between MCP client and server.
# OTEL env vars (OTEL_EXPORTER_OTLP_ENDPOINT, OTEL_SERVICE_NAME, etc.)
# are read from the environment; see releases/lab5/mcp-tracing-patch.yaml.
if os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT"):
    _phoenix_tracer_provider = _phoenix_register(auto_instrument=True)
```

> **Note:** `openinference-instrumentation-mcp` does **not** generate its own telemetry.
> It enables context propagation between MCP clients and servers, unifying their traces
> into a single distributed trace visible in Phoenix.

#### 3. Build and push a new image

```bash
# In abox-labs-mcp-server repo
uv add arize-phoenix-otel openinference-instrumentation-mcp
docker build -t ghcr.io/yevhenyaremenko/abox-labs-mcp-server:0.2.0 .
docker push ghcr.io/yevhenyaremenko/abox-labs-mcp-server:0.2.0
```

#### 4. Update the image tag

In `releases/elicitation-mcp.yaml`, update:
```yaml
image: ghcr.io/yevhenyaremenko/abox-labs-mcp-server:0.2.0
```

### OTEL Environment Patch

`releases/lab5/mcp-tracing-patch.yaml` is a strategic-merge patch that adds OTEL
environment variables to the `elicitation-mcp-server` Deployment:

| Variable | Value |
|----------|-------|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://phoenix.phoenix.svc.cluster.local:6006` |
| `OTEL_SERVICE_NAME` | `elicitation-mcp-server` |
| `PHOENIX_PROJECT_NAME` | `elicitation-mcp` |
| `PHOENIX_COLLECTOR_ENDPOINT` | `http://phoenix.phoenix.svc.cluster.local:6006` |

The patch is applied by the lab5 Kustomization (only when `enable_lab5_resources=true`).

### Enable Lab 5

```bash
cd bootstrap
tofu apply -var="enable_lab5_resources=true"
```

Or directly:
```bash
kubectl apply -k releases/lab5/
```

---

## Quick Reference

```bash
# Agent Sandbox
make sandbox-status          # controller health + installed CRDs
make sandbox-list            # all Sandbox/Claim/Template resources
make sandbox-demo-run        # apply lab5 SandboxTemplate + SandboxClaim
make sandbox-demo-clean      # remove demo resources

# Phoenix
make phoenix-ui              # open Phoenix UI at http://localhost:6006
make phoenix-otel-demo       # run OTEL demo job → traces in Phoenix
```
