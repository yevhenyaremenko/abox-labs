# abox

> **Note:** This is a personal clone of [den-vasyliev/abox](https://github.com/den-vasyliev/abox) for learning purposes.

> One command. Full AI infrastructure.

`make run` gives you a local Kubernetes cluster with everything an AI project needs: an AI-aware API gateway, an agent runtime, observability, distributed tracing, and an eval harness — ready to use.

## What's included

| Component | Role |
|---|---|
| **agentgateway v2.2.1** | AI-aware API gateway (Gateway API–native, MCP-aware) |
| **kagent** | Kubernetes-native AI agent framework |
| **Flux CD 2.x** | GitOps/GitLessOps operator — keeps the cluster in sync with OCI artifacts |
| **KinD** | Local Kubernetes (1 control-plane + 2 workers) - can be any k8s |
| **cloud-provider-kind** | LoadBalancer support so gateway gets a real IP for local development |

## Required Environment Variables

| Variable | Description |
|---|---|
| `OPENAI_API_KEY` | OpenAI API key — injected into `openai-secret` in `agentgateway-system` |
| `GITHUB_TOKEN` | GitHub Personal Access Token — injected into `github-mcp-secret` in `mcp` |

### Creating a GitHub Personal Access Token (fine-grained, least privilege)

Create a **fine-grained** PAT scoped to only the repository the AIRE agent will manage:

1. Go to **GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token**.
2. Set **Token name** (e.g. `aire-agent-mcp`).
3. Under **Resource owner**, select the organisation or user that owns the target repository.
4. Under **Repository access**, choose **Only select repositories** and pick the single target repo.
5. Under **Repository permissions**, grant only:
   | Permission | Access |
   |---|---|
   | **Contents** | Read and write |
   | **Pull requests** | Read and write |
6. Leave all other permissions at *No access*.
7. Click **Generate token** and copy the value.

Export it before running `make`:

```bash
export GITHUB_TOKEN=<your-fine-grained-pat>
```

> **Note:** Classic PATs are not recommended. Fine-grained tokens cannot be used across organisations, so create one per target organisation/repository.



```bash
make run
```

That's it. Installs OpenTofu and k9s, provisions the cluster, bootstraps Flux, and reconciles all components. When it finishes:

```bash
kubectl get gateway,httproute -A        # gateway is up
kubectl get agents -n kagent            # agent runtime is up
kubectl get svc -n agentgateway-system  # grab the LoadBalancer IP
```

Point your AI app at the gateway IP on port 80.

## How it works

```
make run  →  scripts/setup.sh
  → tofu apply (bootstrap/)
      → KinD cluster
      → Flux Operator + FluxInstance
      → ResourceSetInputProvider   polls oci://ghcr.io/yevhenyaremenko/abox-labs/releases
      → ResourceSet                creates OCIRepository + 2 Kustomizations
          → releases/crds/    gateway-api-crds, agentgateway-crds, kagent-crds
          → releases/         agentgateway (Gateway + GatewayClass)
                              kagent (agent runtime + HTTPRoute)
```

Everything after the cluster is **gitless GitOps via OCI**: no Git polling, no deploy keys. CI publishes `releases/` as an OCI artifact on every version tag. The cluster reconciles from that artifact automatically.

## Releasing

```bash
make push   # bumps patch version, tags, pushes → CI publishes OCI artifact → cluster reconciles
```

> **Note:** RSIP tag sorting is lexicographic. If the patch version would exceed 9, bump the minor instead: `git tag vX.Y+1.0`.

## Directory layout

| Path | Purpose |
|---|---|
| `bootstrap/` | OpenTofu: KinD + Flux bootstrap (operator, instance, RSIP, ResourceSet) |
| `releases/crds/` | CRD HelmReleases: gateway-api, agentgateway, kagent |
| `releases/` | App HelmReleases + Gateway + HTTPRoutes |
| `scripts/setup.sh` | Full setup script (`make run`) |
| `.github/workflows/flux-push.yaml` | CI: publish `releases/` as OCI artifact on `v*` tags |

## Labs

### Lab 3 — MCP Elicitation and Autonomous Remediation

Lab 3 introduces two new components and a broken target for the agent to fix.

#### Components

| Resource | File | Purpose |
|---|---|---|
| `elicitation-mcp-server` (Deployment, `mcp`) | `releases/elicitation-mcp.yaml` | Custom Python MCP server (`abox-labs-mcp-server`) that exposes K8s operations — `list_pods`, `get_pod_logs`, `scale_deployment` — and uses MCP Elicitation to interactively prompt the user when a request is ambiguous (e.g. no namespace specified). |
| `elicitation-mcp-server` (RemoteMCPServer, `kagent`) | `releases/elicitation-remote-mcp.yaml` | kagent `RemoteMCPServer` that registers the elicitation server with the agent runtime over StreamableHTTP. |
| `lab3-agent` (Agent, `kagent`) | `releases/lab3-agent.yaml` | kagent `Agent` wired to the elicitation MCP server. Handles cluster queries, confirms destructive actions, and asks for clarification when the request is underspecified. |
| `sample-app` (Deployment, `sample-app`) | `releases/sample-app.yaml` | **Intentionally broken** nginx deployment whose readiness and liveness probes point to `/healthz` (nginx does not serve this path). The pod will never become Ready. This is the lab exercise target — `lab3-agent` is expected to detect the misconfigured probes and fix them. |

#### MCP server health probe

FastMCP's StreamableHTTP transport requires `Accept: application/json, text/event-stream` on the `GET /mcp` endpoint. Kubernetes kubelet probes do not send this header and receive `406 Not Acceptable`. The server exposes a dedicated `GET /health` endpoint for probes; the Deployment's `readinessProbe` uses `/health` instead of `/mcp`.

## Adding components

1. Put CRD charts in `releases/crds/` as HelmReleases.
2. Put app charts in `releases/` as HelmReleases.
3. Run `make push` — the cluster reconciles automatically.

The CRD kustomization runs first (`wait: true`), apps run after (`dependsOn: releases-crds`). This ordering is enforced by Flux and must be preserved.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md).

## License

Apache 2.0 — see [LICENSE](./LICENSE).
