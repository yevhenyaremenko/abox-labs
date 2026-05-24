# Lab 4 / Development Tasks 2 & 3: A2A Task Communication and Multi-Agent Team

## Goal

1. Implement A2A task communication between two agents.
2. Implement an A2A team combining a custom agent with existing kagent agents.

## Agent team

```
User
  │
  ▼
conductor-agent          ← orchestrator; receives all user requests
  ├── k8s-agent    (A2A) ← already installed; cluster inspection & analysis
  └── github-agent (A2A) ← new; GitHub read/write via agw-mcp-servers
```

### Agent roles

| Agent | Role | Tools |
|---|---|---|
| **conductor-agent** | Orchestrator — decomposes requests, routes to sub-agents, synthesises results | `type: Agent → k8s-agent`, `type: Agent → github-agent` |
| **k8s-agent** | Cluster analysis — pods, events, logs, resource descriptions | `kagent-tool-server` (kagent built-in) |
| **github-agent** | GitHub operations — branch, commit, PR, file read, code search | `agw-mcp-servers` → agentgateway → GitHub MCP |

### Name rationale — `conductor-agent`

A conductor directs an orchestra without playing an instrument themselves: they set the tempo, cue each section, and unify the result. This agent does exactly the same — it never touches the cluster or GitHub directly, but orchestrates the two specialist agents and synthesises their outputs into a coherent answer.

## A2A inter-agent communication

kagent exposes two tool types in `spec.declarative.tools[].type`:

| Type | Usage |
|---|---|
| `McpServer` | Call tools on an MCP server (existing mechanism) |
| `Agent` | Call another kagent `Agent` via A2A protocol |

The `type: Agent` tool wires one agent as a sub-agent of another. The orchestrator sends an A2A task to the sub-agent's endpoint and awaits its result — full streaming, HITL propagation, and live activity viewing are supported.

**Syntax:**

```yaml
tools:
- type: Agent
  agent:
    name: k8s-agent      # target Agent resource name
    kind: Agent
    apiGroup: kagent.dev
- type: Agent
  agent:
    name: github-agent
    kind: Agent
    apiGroup: kagent.dev
```

Both sub-agents also expose their own A2A endpoints (via `a2aConfig`) so they can be called independently or by other orchestrators.

## A2A endpoints

All three agents are reachable via the kagent-controller A2A API:

```
/api/a2a/kagent/conductor-agent/.well-known/agent.json
/api/a2a/kagent/github-agent/.well-known/agent.json
/api/a2a/kagent/k8s-agent/.well-known/agent.json
```

```bash
kubectl port-forward svc/kagent-controller 8083:8083 -n kagent

curl http://localhost:8083/api/a2a/kagent/conductor-agent/.well-known/agent.json | jq .
curl http://localhost:8083/api/a2a/kagent/github-agent/.well-known/agent.json | jq .
```

## GitHub permissions

`github-agent` uses the `agw-mcp-servers` RemoteMCPServer, which routes through agentgateway to the GitHub MCP server. The GitHub Personal Access Token is already mounted as `github-mcp-secret` in the `mcp` namespace and injected by agentgateway — no additional secret is needed for the new agent.

## Orchestration flow — example: "fix a broken deployment"

```
User → conductor-agent: "The payments service is CrashLoopBackOff — open a fix PR"
  │
  ├─ 1. → k8s-agent: "Describe pod payments-xxx and show recent events"
  │        ← findings: wrong image tag v2.2.0, image pull error
  │
  ├─ 2. → k8s-agent: "Get YAML of Deployment payments"
  │        ← current spec: image: payments:v2.2.0
  │
  ├─ 3. → github-agent: "Search repo for payments deployment manifest"
  │        ← found: deploy/payments/deployment.yaml
  │
  ├─ 4. → github-agent: "Create branch fix/payments-image, update image to v2.1.0, open PR"
  │        ← PR #42 opened: https://github.com/org/repo/pull/42
  │
  └─ conductor-agent → User: "Root cause: bad image tag v2.2.0.
                               PR #42 reverts it to v2.1.0: <url>"
```

## Files changed

| File | Change |
|---|---|
| `releases/github-agent.yaml` | New — GitHub operations agent with `agw-mcp-servers` tools and A2A skills |
| `releases/conductor-agent.yaml` | New — orchestrator with `type: Agent` tools for k8s-agent and github-agent |
| `releases/kustomization.yaml` | Added both new agents |
