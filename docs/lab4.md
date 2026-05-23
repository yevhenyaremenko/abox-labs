# Lab 4: Agent with Agent Card and Well-Known URI (A2A Protocol)

## Goal

Implement an agent with an Agent Card and expose it via the Well-Known URI as defined by the [A2A (Agent-to-Agent) protocol](https://a2a-protocol.org/latest/specification/).

## Background

The A2A protocol is an open standard for agent interoperability. Its discovery mechanism requires every A2A-compliant agent to publish a JSON metadata document — the **Agent Card** — at a standardized well-known URI, following [RFC 8615](https://www.rfc-editor.org/rfc/rfc8615).

The Agent Card describes:

- Agent identity (`name`, `description`, `version`, `url`)
- Supported input/output modes
- Capabilities (`streaming`, `pushNotifications`)
- **Skills** — discrete named capabilities the agent can perform, each with an `id`, `description`, `tags`, and `examples`
- Authentication schemes

## Implementation

### Approach: kagent (Kubernetes-native A2A)

kagent natively supports the A2A protocol. Any `kagent.dev/v1alpha2 Agent` resource with an `a2aConfig` block automatically gets its Agent Card built and served by the `kagent-controller` on port `8083`, under:

```
/api/a2a/{namespace}/{agent-name}/.well-known/agent.json
```

The existing `aire-agent` already declares three skills in its `a2aConfig`:

| Skill ID | Name | Description |
|---|---|---|
| `cluster-diagnostics` | Cluster Diagnostics | Analyze and diagnose Kubernetes cluster issues |
| `resource-management` | Resource Management | Manage and optimize Kubernetes resources |
| `security-audit` | Security Audit | Audit and enhance Kubernetes security |

No additional code or deployment was needed — kagent generates the Agent Card from the declarative YAML spec.

### Relevant file

`releases/aire-agent.yaml` — the `spec.declarative.a2aConfig` block defines the skills that make up the Agent Card:

```yaml
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata:
  name: aire-agent
  namespace: kagent
spec:
  declarative:
    a2aConfig:
      skills:
      - id: cluster-diagnostics
        name: Cluster Diagnostics
        description: The ability to analyze and diagnose Kubernetes Cluster issues.
        tags: [cluster, diagnostics]
        examples:
        - What is the status of my cluster?
        - How can I troubleshoot a failing pod?
      - id: resource-management
        name: Resource Management
        description: The ability to manage and optimize Kubernetes resources.
        tags: [resource, management]
      - id: security-audit
        name: Security Audit
        description: The ability to audit and enhance Kubernetes security.
        tags: [security, audit]
```

## Fetching the Agent Card

A `make` target was added to automate port-forwarding and retrieval:

```bash
make a2a-agent-card
```

This target:
1. Port-forwards `svc/kagent-controller` (namespace `kagent`) to local port `8083`
2. Sends a `GET` request to the Well-Known URI
3. Prints `[PASS]`/`[FAIL]` and the full Agent Card JSON

Equivalent manual commands:

```bash
kubectl port-forward svc/kagent-controller 8083:8083 -n kagent

curl -s http://localhost:8083/api/a2a/kagent/aire-agent/.well-known/agent.json | jq .
```

### Example response

```json
{
  "name": "aire-agent",
  "description": "An GitOps and ArgoCD based Kubernetes Expert AI Agent ...",
  "version": "1.0.0",
  "url": "http://kagent-controller.kagent.svc:8083/api/a2a/kagent/aire-agent",
  "capabilities": {
    "streaming": true
  },
  "skills": [
    {
      "id": "cluster-diagnostics",
      "name": "Cluster Diagnostics",
      "description": "The ability to analyze and diagnose Kubernetes Cluster issues.",
      "tags": ["cluster", "diagnostics"],
      "examples": ["What is the status of my cluster?", "How can I troubleshoot a failing pod?"]
    },
    {
      "id": "resource-management",
      "name": "Resource Management",
      "description": "The ability to manage and optimize Kubernetes resources.",
      "tags": ["resource", "management"]
    },
    {
      "id": "security-audit",
      "name": "Security Audit",
      "description": "The ability to audit and enhance Kubernetes security.",
      "tags": ["security", "audit"]
    }
  ]
}
```

## Summary

| Item | Value |
|---|---|
| Framework | kagent (`kagent.dev/v1alpha2`) |
| Agent | `aire-agent` (namespace `kagent`) |
| Well-Known URI | `/api/a2a/kagent/aire-agent/.well-known/agent.json` |
| Port | `8083` (kagent-controller service) |
| Skills | 3 (cluster-diagnostics, resource-management, security-audit) |
| New files | none — agent card is derived from existing `aire-agent.yaml` |
| New make target | `a2a-agent-card` |
