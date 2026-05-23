# Lab 4 / Infrastructure Task 4: Deploying MCPG in the AI Infrastructure

## Goal

Deploy [MCP Security Governance (MCPG)](https://github.com/techwithhuz/mcp-security-governance) into the abox cluster and evaluate the security posture of the existing MCP infrastructure.

## What is MCPG

A Kubernetes-native governance system for MCP (Model Context Protocol) infrastructure. It:

- **Discovers** MCP servers, agents, and gateways across namespaces via the Kubernetes API
- **Evaluates** each MCP server across 9 security categories using a configurable scoring engine
- **Surfaces findings** through a REST API and a real-time Next.js dashboard
- **Integrates** natively with AgentGateway, kagent, and agentregistry CRDs

The scoring model is **MCP-server-centric**: each server receives an individual score rather than a single cluster-wide score.

## Security Categories Evaluated

| Category | Default Weight | What It Checks |
|---|---|---|
| Agent Gateway Integration | 25% | All MCP traffic routed via AgentGateway proxy |
| Authentication | 20% | JWT auth configured on the server |
| Authorization | 15% | RBAC / CEL-based policies in place |
| CORS Policy | 10% | Cross-origin restrictions configured |
| TLS Encryption | 10% | TLS termination enforced |
| Tool Scope | 10% | Number of exposed tools vs. warning/critical thresholds |
| Prompt Guard | 5% | Prompt injection protection present |
| Rate Limiting | 5% | Rate limit policies configured |

## Architecture

```
Flux OCIRepository (ghcr.io/techwithhuz/charts/mcp-governance:0.22.2)
        │
        ▼
HelmRelease → mcp-governance namespace
    ├── mcp-governance-controller  :8090  (REST API, scoring engine, discovery)
    └── mcp-governance-dashboard   :3000  (Next.js UI)

MCPGovernancePolicy (enterprise-mcp-policy)
    └── evaluationScope: cluster
        └── targetNamespaces: [] (all non-excluded)
            excludes: kube-system, flux-system, agentregistry, mcp-governance, ...

Discovery reads:
  kagent.dev → agents, mcpservers, remotemcpservers
  agentgateway.dev → backends, policies
  gateway.networking.k8s.io → gateways, httproutes
  agentregistry.dev → mcpservercatalogs, skillcatalogs
```

## What gets scanned in abox

| Resource | Namespace | Type |
|---|---|---|
| `github-mcp` | `mcp` | MCPServer (stdio) |
| `elicitation-mcp-server` | `mcp` | Deployment + RemoteMCPServer (optional, Lab 3) |
| `agw-mcp-servers` | `kagent` | RemoteMCPServer → agentgateway |
| `kagent-tool-server` | `kagent` | RemoteMCPServer |
| `agentgateway-external` | `agentgateway-system` | Gateway |

## Implementation

### Flux deployment (`releases/mcp-governance.yaml`)

The chart is published to OCI at `ghcr.io/techwithhuz/charts/mcp-governance`. Flux pulls it via `OCIRepository` and deploys with `HelmRelease`:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: mcp-governance
  namespace: flux-system
spec:
  url: oci://ghcr.io/techwithhuz/charts/mcp-governance
  ref:
    tag: "0.22.2"
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: mcp-governance
  namespace: mcp-governance
spec:
  chartRef:
    kind: OCIRepository
    name: mcp-governance
    namespace: flux-system
  install:
    crds: Create
  values:
    controller:
      image:
        repository: ghcr.io/techwithhuz/mcp-governance-controller
        tag: "0.22.2"
        pullPolicy: IfNotPresent
    dashboard:
      image:
        repository: ghcr.io/techwithhuz/mcp-governance-dashboard
        tag: "0.22.2"
        pullPolicy: IfNotPresent
      service:
        type: ClusterIP   # use port-forward, consistent with rest of infra
    samples:
      install: true       # creates MCPGovernancePolicy + GovernanceEvaluation
    governancePolicy:
      spec:
        aiAgent:
          enabled: false  # no Gemini key configured
        targetNamespaces: []  # scan all non-excluded namespaces
        excludeNamespaces:
          - kube-system
          - kube-public
          - kube-node-lease
          - local-path-storage
          - flux-system
          - agentregistry
          - mcp-governance
```

CRDs installed by Helm:
- `governance.mcp.io/v1alpha1 MCPGovernancePolicy`
- `governance.mcp.io/v1alpha1 GovernanceEvaluation`

### Controller RBAC (auto-created by chart)

The ClusterRole grants the controller read access to:

| API Group | Resources |
|---|---|
| `kagent.dev` | agents, mcpservers, remotemcpservers |
| `agentgateway.dev` | backends, parameters, policies |
| `gateway.networking.k8s.io` | gateways, httproutes, gatewayclasses |
| `agentregistry.dev` | mcpservercatalogs, skillcatalogs, agentcatalogs, modelcatalogs |
| `governance.mcp.io` | policies, evaluations (rw) |
| `""` (core) | services, namespaces, pods (ro) |
| `apps` | deployments, statefulsets (ro) |
| `networking.k8s.io` | networkpolicies (ro) |

## Querying the governance results

### Overall score

```bash
make governance-score
# equivalent:
kubectl port-forward svc/mcp-governance-controller 8090:8090 -n mcp-governance
curl http://localhost:8090/api/governance/score | jq .
```

### Per-server findings

```bash
make governance-servers
# equivalent:
curl http://localhost:8090/api/governance/mcp-servers | jq .
```

### Web dashboard

```bash
make governance-ui
# then open http://localhost:3000
```

The dashboard has four tabs: Overview, MCP Servers, Resource Inventory, Findings.

## REST API reference

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/health` | Health check |
| `GET` | `/api/governance/score` | Overall + per-category scores |
| `GET` | `/api/governance/mcp-servers` | Per-server scores and findings |
| `GET` | `/api/governance/findings` | All findings aggregated |
| `GET` | `/api/governance/ai-score` | AI analysis (requires `aiAgent.enabled: true`) |
| `POST` | `/api/governance/ai-score/refresh` | Trigger immediate AI re-evaluation |

## Files changed

| File | Change |
|---|---|
| `releases/mcp-governance.yaml` | New — Namespace, OCIRepository, HelmRelease |
| `releases/kustomization.yaml` | Added `mcp-governance.yaml` |
| `Makefile` | Added `governance-score`, `governance-servers`, `governance-ui` |
