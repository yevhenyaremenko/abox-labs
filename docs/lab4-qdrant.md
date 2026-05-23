# Lab 4 / Infrastructure Task 5: Deploying Qdrant Vector Database

## What is Qdrant

[Qdrant](https://qdrant.tech) is an open-source vector database and similarity search engine. It stores high-dimensional vectors (embeddings) alongside their payloads and answers nearest-neighbor queries in milliseconds.

## Use cases in AI infrastructure

| Use case | How Qdrant helps |
|---|---|
| **RAG (Retrieval-Augmented Generation)** | Store embeddings of documents/logs/runbooks; at query time retrieve the most relevant chunks and pass them to the LLM as context — so the agent answers with up-to-date, cluster-specific knowledge |
| **Agent long-term memory** | Persist facts an agent has learned across sessions; recall similar past observations to avoid re-discovering the same issue |
| **Semantic search over K8s events** | Embed cluster events and alerts; find incidents similar to the current one to suggest past remediation steps |
| **MCP / skill deduplication** | Embed skill descriptions to detect near-duplicate tools across MCP servers before registering them in the inventory |
| **Anomaly detection** | Store embeddings of "normal" metric snapshots; flag new snapshots that fall far from the known-good cluster |

In the context of this lab, Qdrant is the storage layer that would back a RAG pipeline for `aire-agent` or any other kagent agent — enabling knowledge retrieval beyond what fits in the LLM context window.

## Deployment

Deployed via Flux `HelmRelease` from the official Qdrant Helm repository.

**`releases/qdrant.yaml`**:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: qdrant
  namespace: flux-system
spec:
  url: https://qdrant.github.io/qdrant-helm
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: qdrant
  namespace: qdrant
spec:
  chart:
    spec:
      chart: qdrant
      version: "1.18.0"
      sourceRef:
        kind: HelmRepository
        name: qdrant
        namespace: flux-system
  values:
    replicaCount: 1
    persistence:
      size: 2Gi        # reduced from default 10Gi for the lab
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        cpu: 500m
        memory: 512Mi
```

Single-node, no auth, no TLS — appropriate for a local lab cluster. Persistent storage is provided by the `local-path` provisioner already present in abox.

## Ports

| Port | Protocol | Purpose |
|---|---|---|
| `6333` | HTTP/REST | Main API — collections, search, CRUD |
| `6334` | gRPC | High-throughput client access |
| `6335` | TCP | Internal P2P (cluster mode) |

## Querying

```bash
# Cluster info and version
make qdrant-info

# List collections (empty on fresh install)
make qdrant-collections

# Manual equivalent
kubectl port-forward svc/qdrant 6333:6333 -n qdrant
curl http://localhost:6333 | jq .
curl http://localhost:6333/collections | jq .
```

## Files changed

| File | Change |
|---|---|
| `releases/qdrant.yaml` | New — Namespace, HelmRepository, HelmRelease |
| `releases/kustomization.yaml` | Added `qdrant.yaml` |
| `Makefile` | Added `qdrant-info`, `qdrant-collections` |
