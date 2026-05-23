# Lab 4 / Infrastructure Task 3: Deploying agentregistry-inventory on abox

## Goal

Deploy [agentregistry-inventory](https://github.com/den-vasyliev/agentregistry-inventory) on the abox kind cluster and retrieve the list of AI resources (agents, MCP servers) discovered in the cluster.

## What is agentregistry-inventory

A Kubernetes-native control plane for AI infrastructure. It automatically discovers and catalogs:

- **Agents** — `kagent.dev/v1alpha2 Agent` resources
- **MCP Servers** — `kagent.dev` `MCPServer` and `RemoteMCPServer` resources
- **Skills** — agent skill definitions
- **Models** — `ModelConfig` resources

Discovery is driven by a `DiscoveryConfig` CRD that declares which namespaces to scan. The controller exposes a read-only REST API and an embedded web UI.

## Architecture

```
Flux GitRepository ──► HelmRelease (agentregistry)
                              │
                              ▼
                   agentregistry-api  :8080 (REST API + UI)
                   agentregistry-api  :8083 (MCP server)
                              │
                   DiscoveryConfig (abox)
                     namespaces: [kagent, mcp]
                              │
                    watches kagent.dev resources
                    ┌─────────────────────────┐
                    │ aire-agent              │  ← Agent
                    │ lab3-agent (optional)   │  ← Agent
                    │ kagent-tool-server      │  ← RemoteMCPServer
                    │ agw-mcp-servers         │  ← RemoteMCPServer
                    │ github-mcp (mcp ns)     │  ← MCPServer
                    └─────────────────────────┘
```

## Implementation

### Flux source + HelmRelease

**`releases/agentregistry.yaml`** — the full deployment:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: agentregistry
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: agentregistry-inventory
  namespace: flux-system
spec:
  interval: 1h
  url: https://github.com/den-vasyliev/agentregistry-inventory
  ref:
    branch: main
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: agentregistry
  namespace: agentregistry
spec:
  interval: 1h
  chart:
    spec:
      chart: ./charts/agentregistry
      sourceRef:
        kind: GitRepository
        name: agentregistry-inventory
        namespace: flux-system
  install:
    crds: Create
  upgrade:
    crds: CreateReplace
  values:
    disableAuth: true   # no auth for lab purposes
---
apiVersion: agentregistry.dev/v1alpha1
kind: DiscoveryConfig
metadata:
  name: abox
  namespace: agentregistry
spec:
  environments:
  - name: abox
    cluster:
      name: local
    namespaces:
    - kagent
    - mcp
    discoveryEnabled: true
```

The chart is pulled directly from the GitHub repo via a Flux `GitRepository` source. CRDs are installed by Helm on first deploy (`install.crds: Create`).

The `DiscoveryConfig` is applied in the same Kustomization. Flux retries every 30 s, so if the CRD is not yet registered when the Kustomization first reconciles, it will succeed on the next retry after the HelmRelease installs the CRD.

### Controller ClusterRole (auto-created by chart)

The chart creates a ClusterRole granting the controller read access to:

| API Group | Resources |
|---|---|
| `agentregistry.dev` | mcpservercatalogs, agentcatalogs, skillcatalogs, modelcatalogs, discoveryconfigs, … |
| `kagent.dev` | agents, remotemcpservers, mcpservers, modelconfigs |
| `""` (core) | configmaps (rw), secrets (ro), events |
| `coordination.k8s.io` | leases (for leader election) |

## Querying the inventory

Two `make` targets are provided. Both port-forward the `agentregistry-api` service to `localhost:8080`, hit the REST API, and print the result.

### List AI agents

```bash
make inventory-agents
# equivalent:
kubectl port-forward svc/agentregistry-api 8080:8080 -n agentregistry
curl http://localhost:8080/v0/agents | jq .
```

### List MCP servers

```bash
make inventory-servers
# equivalent:
kubectl port-forward svc/agentregistry-api 8080:8080 -n agentregistry
curl http://localhost:8080/v0/servers | jq .
```

### Web UI

The controller also embeds a Next.js web UI on the same port:

```bash
kubectl port-forward svc/agentregistry-api 8080:8080 -n agentregistry
open http://localhost:8080
```

## REST API reference

| Method | Path | Description |
|---|---|---|
| `GET` | `/v0/agents` | List all discovered agents |
| `GET` | `/v0/servers` | List all discovered MCP servers |
| `GET` | `/v0/skills` | List all discovered skills |
| `POST` | `/admin/v0/servers` | Create a catalog entry (auth required by default) |

## Files changed

| File | Change |
|---|---|
| `releases/agentregistry.yaml` | New — Namespace, GitRepository, HelmRelease, DiscoveryConfig |
| `releases/kustomization.yaml` | Added `agentregistry.yaml` to resources list |
| `Makefile` | Added `inventory-agents` and `inventory-servers` targets |
