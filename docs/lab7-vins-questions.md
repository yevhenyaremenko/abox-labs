# Lab 7 — Vin's Questions: AI Infrastructure Deep-Dive

> **Context:** Final certification task. Research and self-assessment of the abox AI infrastructure.  
> Stack: **KinD + Flux GitOps (OCI) · agentgateway v2.2.1 · kagent 0.7.23 · FastMCP (StreamableHTTP) · OpenAI backend**

---

## Q1 — How could we handle "agent got stuck" scenarios?

**The problem:** An agent enters an infinite tool-call loop, waits forever on a slow LLM response, or keeps retrying a failing sub-agent.

### What exists today in the stack

| Layer | Mechanism | How it helps |
|---|---|---|
| **agentgateway** | Request-level timeout on the `AgentgatewayBackend` | Cuts the HTTP connection to the LLM if no response arrives within the configured window |
| **kagent** | `Agent` CRD has no built-in max-steps field in v0.7.23, but the underlying AutoGen/OpenAI agent loop respects LLM call timeouts | A single hung LLM call unblocks when agentgateway times out |
| **Kubernetes** | Pod restart policy + liveness probe | If the agent process deadlocks completely, the probe fails and kubelet restarts the pod |

### Patterns to implement now

```
1. Conversation-level deadline
   ┌─────────────────────────────────────────────────────┐
   │  Client sets X-Request-Deadline header on the       │
   │  initial request to agentgateway.  agentgateway      │
   │  propagates the remaining budget to every upstream   │
   │  call (LLM + MCP tools).  When budget hits zero,     │
   │  agentgateway returns 504 to the client.             │
   └─────────────────────────────────────────────────────┘

2. Max-steps guard (system-prompt level)
   Add to the agent's systemMessage:
     "If you have made more than N tool calls without
      a final answer, stop and report what you found."

3. MCP server heartbeat
   The elicitation-mcp-server (/health endpoint) is already
   present. Extend it to expose a /metrics endpoint counting
   active requests.  A Prometheus alert fires if a single
   request holds an open SSE stream for > T seconds.

4. Dead-letter session pattern (future)
   Store the session ID in Redis.  A sidecar process scans
   for sessions older than TTL and sends a synthetic STOP
   message via kagent's A2A cancel endpoint.
```

### Recommended immediate action

Add `timeout` to the agentgateway HelmRelease values and set a `maxTokens` cap in the ModelConfig to bound worst-case duration:

```yaml
# releases/kagent.yaml — ModelConfig
spec:
  openAI:
    baseUrl: ...
  # Bound token usage per call to prevent infinite chain
  maxTokens: 4096
```

---

## Q2 — Automatic timeout / circuit-breaker patterns from this framework

### Timeout layers already present

```
Client → agentgateway (HTTP timeout, configurable per-backend)
       → LLM provider (OpenAI API timeout)
       → kagent agent loop (per-LLM-call timeout inherited from agentgateway)
       → MCP tool call (FastMCP server, OS-level socket timeout)
```

agentgateway is built on Envoy-lineage semantics. Each `AgentgatewayBackend` supports:

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
spec:
  ai:
    provider:
      openai:
        model: gpt-5.4-mini
  timeout: 30s          # ← per-request deadline to the LLM
  retries:
    attempts: 3
    perTryTimeout: 10s
    retryOn: "5xx,reset,connect-failure"
```

### Circuit-breaker pattern

agentgateway does **not** ship an explicit circuit-breaker CRD in v2.2.1, but the retry + outlier detection approach can be layered:

| Approach | How |
|---|---|
| **Passive circuit breaker** | Configure `retries.retryOn: "5xx,reset"` + low `attempts: 1`. After one failure the gateway returns 503 immediately instead of queuing more calls |
| **Active health checking** | Add an `activeHealthCheck` block on the Backend; unhealthy backends are ejected from the pool for a configurable interval |
| **Rate-limit as a fuse** | MCP-governance (`requireRateLimit: true` already configured) enforces token-per-minute caps. When the LLM is overloaded and latency spikes, rate-limiting acts as a soft circuit breaker |

---

## Q3 — How does kgateway handle model failover?

> **Naming note:** The Helm chart is published as `agentgateway` under `kgateway-dev` org; "kgateway" and "agentgateway" refer to the same product.

### Current setup — single backend

```yaml
# releases/agentgateway.yaml
config:
  llm:
    models:
    - name: gpt-5.4-mini
      provider: openai
      params:
        model: gpt-5.4-mini
```

Only one model/backend is registered. There is no automatic failover configured today.

### How failover works in agentgateway

agentgateway supports **model pools** (sometimes called `LLMRoute` or `AIRoute` depending on the version). The pattern:

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: LLMPolicy           # hypothetical - API evolving in v2.x
spec:
  backends:
  - name: openai-primary
    weight: 100
    failover:
      to: claude-fallback
      on: "5xx,timeout"
  - name: claude-fallback
    weight: 0             # standby — only activated on failover
```

In v2.2.1 (current), failover is approximated by:

1. **Multiple `AgentgatewayBackend` resources** — one per provider.
2. **HTTPRoute weighted routing** — split traffic or cascade via `backendRefs` with priority weights.
3. **Retry with different backend** — not natively supported; requires an external load balancer or Envoy filter.

The recommended production pattern while the API matures is to run an **Envoy proxy** in front of agentgateway and define weighted clusters at that layer.

---

## Q4 — Can we automatically switch from OpenAI → Claude → local model?

### Current state

The stack has one `ModelConfig` pointing through agentgateway to OpenAI. Switching providers requires changing the `baseUrl` + `apiKeySecret` in `ModelConfig`.

### Target architecture — provider waterfall

```
kagent agent
    │
    ▼
ModelConfig (single endpoint) ──► agentgateway
                                       │
                           ┌───────────┼───────────────┐
                           ▼           ▼               ▼
                     OpenAI        Anthropic        vLLM (local)
                   (primary)      (fallback 1)    (fallback 2)
```

### Implementation path

**Step 1 — Add Anthropic and local backends**

```yaml
# releases/agentgateway.yaml
config:
  llm:
    models:
    - name: gpt-5.4-mini
      provider: openai
      params:
        model: gpt-5.4-mini
        apiKeyRef: { secretName: openai-secret, key: Authorization }
    - name: claude-sonnet
      provider: anthropic
      params:
        model: claude-sonnet-4-6
        apiKeyRef: { secretName: anthropic-secret, key: Authorization }
    - name: llama-local
      provider: openai          # vLLM speaks OpenAI-compatible API
      params:
        model: llama-3.1-8b
        baseUrl: http://vllm-service.vllm.svc:8000/v1
```

**Step 2 — Routing policy**

```yaml
# HTTPRoute with priority-ordered backendRefs
rules:
- backendRefs:
  - name: openai
    weight: 100
  - name: claude-sonnet
    weight: 0        # activated by failover policy
  - name: llama-local
    weight: 0
```

**Step 3 — Seamless fallback via kagent ModelConfig**

Each kagent `ModelConfig` points at a single agentgateway endpoint. The failover is transparent — the agent never knows which provider responded.

---

## Q5 — Can we seamlessly handle response formats from different providers?

### The challenge

| Provider | Response differences |
|---|---|
| OpenAI | `choices[0].message.content`, `tool_calls` array |
| Anthropic | `content[].text`, `content[].tool_use` (different key names) |
| vLLM / local | OpenAI-compatible but may omit fields like `usage`, `logprobs` |

### How agentgateway solves this

agentgateway **normalizes** responses to the OpenAI wire format before returning to the caller. This is the core value proposition of an AI-aware gateway: every backend speaks its native protocol upstream; every client sees a uniform API downstream.

```
Anthropic native response          agentgateway               kagent
{ "content": [{ "type": "text",     ────────────►   { "choices": [{ "message":
  "text": "Hello" }] }                                "content": "Hello" }] }
```

### What still leaks through

1. **Tool/function call schemas** — Anthropic uses slightly different tool-call JSON keys. agentgateway translates, but complex nested tool results can expose edge cases.
2. **Streaming deltas** — SSE event shapes differ. agentgateway normalises `content_block_delta` (Anthropic) to `delta.content` (OpenAI).
3. **Model-specific features** — Reasoning tokens (`thinking` blocks), citation objects, logprobs — these are provider-specific and are either dropped or passed through verbatim.

**Practical rule for abox:** Keep all agent system prompts provider-agnostic (no model-specific token budgets, no model-name references). This ensures clean failover without prompt changes.

---

## Q6 — Can we version the agents built from kagent?

### Short answer: yes — through GitOps versioning

kagent `Agent` resources are Kubernetes manifests. The entire versioning story comes from Flux + OCI:

```
git tag v0.3.5    →    CI pushes OCI artifact    →    RSIP detects tag
                                                        │
                                               Flux reconciles
                                               Agent CRD updated
                                               in-place
```

Every agent version is a tagged OCI artifact. Rolling back is `git revert` + `make push`.

### Agent-level versioning patterns

| Pattern | Implementation |
|---|---|
| **Semantic version in metadata label** | `labels: agent.kagent.dev/version: "1.2.0"` |
| **Separate namespace per version** | `namespace: kagent-v1`, `namespace: kagent-v2` — full isolation |
| **A2A `version` field** | kagent auto-populates `version` in the Agent Card from the resource spec |
| **ModelConfig versioning** | Point different agent versions at different ModelConfigs (different model or endpoint) |

### A2A version field

```json
{
  "name": "aire-agent",
  "version": "1.0.0",    ← comes from spec, surfaced in well-known agent card
  ...
}
```

Bumping `version` in `aire-agent.yaml` automatically propagates to the Agent Card at `/.well-known/agent.json`.

---

## Q7 — Blue/Green or Canary deployment patterns for agents

### Blue/Green

```
Namespace: kagent-blue   ← stable, receives 100% traffic
Namespace: kagent-green  ← new version, receives 0%

HTTPRoute in agentgateway:
  rules:
  - backendRefs:
    - name: kagent-controller.kagent-blue   weight: 100
    - name: kagent-controller.kagent-green  weight: 0
```

Flip traffic by patching weights. Rollback = flip back.

### Canary

```yaml
# HTTPRoute — canary split
rules:
- backendRefs:
  - name: kagent-controller
    namespace: kagent        # stable
    weight: 90
  - name: kagent-controller
    namespace: kagent-canary  # canary
    weight: 10
```

### In abox today

abox uses Flux `Kustomization` with `wait: true`. A structured canary approach requires:

1. A second `releases-canary/` path.
2. A second `Kustomization` targeting that path.
3. Weighted `HTTPRoute` rules managed by a `Kustomize` patch per environment.

Flux itself doesn't orchestrate traffic shifting — that lives in the Gateway config. The combination is: **Flux manages the agent versions; agentgateway manages the traffic split**.

### Flagger integration (advanced)

[Flagger](https://flagger.app) automates progressive delivery by watching Prometheus metrics and patching `HTTPRoute` weights automatically. It supports kagent's workloads as standard Kubernetes `Deployments`.

---

## Q8 — What is the FastMCP Python framework?

### What it is

[FastMCP](https://github.com/jlowin/fastmcp) is a Python library that makes building **Model Context Protocol (MCP) servers** as easy as writing a FastAPI app. It provides:

- `@mcp.tool()` decorator — expose any Python function as an MCP tool
- `@mcp.resource()` — expose data as MCP resources
- `@mcp.prompt()` — define reusable prompt templates
- Transport adapters: **stdio** (for local CLI use), **StreamableHTTP** (for server deployment), and **SSE**
- Built-in **Elicitation** support — prompt the user for missing parameters mid-tool-call

### In abox

The `elicitation-mcp-server` (`ghcr.io/yevhenyaremenko/abox-labs-mcp-server:0.1.6`) is built with FastMCP. Key design decisions from the implementation:

```python
from fastmcp import FastMCP

mcp = FastMCP("abox-labs-mcp-server")

@mcp.tool()
async def list_pods(namespace: str | None = None) -> list[dict]:
    """List pods. Uses Elicitation if namespace is not provided."""
    if namespace is None:
        namespace = await mcp.elicit("Which namespace?", type=str)
    # ... kubernetes client call ...
```

The server runs in HTTP mode (`MCP_TRANSPORT_MODE=http`) and listens on port 3000. The `GET /mcp` endpoint requires `Accept: application/json, text/event-stream` — this is why the readiness probe uses `/health` instead of `/mcp`.

### Transport modes

| Mode | When to use |
|---|---|
| `stdio` | Local development, Claude Desktop integration |
| `streamable-http` | Server deployment, Kubernetes (abox uses this) |
| `sse` | Legacy SSE-only clients |

---

## Q9 — Is FastMCP the easiest path to MCP?

### Comparison of MCP server approaches

| Approach | Ease | Deployment | Features |
|---|---|---|---|
| **FastMCP (Python)** | ⭐⭐⭐⭐⭐ | Any container | Elicitation, all transports, typed tools |
| **MCP SDK (TypeScript)** | ⭐⭐⭐⭐ | Any container | Official SDK, more verbose |
| **MCP SDK (Python)** | ⭐⭐⭐ | Any container | Official, lower-level than FastMCP |
| **kagent built-in tools** | ⭐⭐⭐⭐ | In-cluster only | No custom code needed for K8s ops |
| **agentgateway MCP proxy** | ⭐⭐⭐ | Requires gateway | No new service, but limited tool shapes |

### Verdict for abox

For **custom business logic** (Kubernetes operations with Elicitation, custom APIs): **FastMCP is the fastest path**. The `@mcp.tool()` decorator plus automatic JSON schema generation means you go from Python function to kagent-registered tool in minutes.

For **standard K8s operations**: kagent's built-in `kagent-tool-server` (already registered as `RemoteMCPServer`) is even easier — zero new code.

For **connecting to external SaaS tools** (GitHub, Slack, Jira): use existing MCP community servers and register them via `RemoteMCPServer` pointing at the remote URL.

---

## Q10 — FinOps: how much control do I have?

### Cost surfaces in the stack

```
Token cost   = (input tokens + output tokens) × model price
               ↑ controlled by: ModelConfig.maxTokens,
                                 system prompt verbosity,
                                 number of tool call round-trips

Infrastructure cost = KinD cluster on-prem (free)
                      OR cloud nodes × node hours
                      ↑ controlled by: node count, node type,
                                        autoscaler min/max
```

### Current controls available

| Control | Where | Status in abox |
|---|---|---|
| **Model selection** | `ModelConfig.model` | `gpt-5.4-mini` (cost-optimised model) |
| **Max tokens per call** | `ModelConfig.maxTokens` | Not set — should be added |
| **Rate limiting** | mcp-governance `requireRateLimit: true` | ✅ Enabled |
| **Per-backend timeout** | `AgentgatewayBackend.timeout` | Not configured — should be added |
| **Model routing by cost** | HTTPRoute weight split to cheap vs expensive model | Not configured |

---

## Q11 — Token-level / per-agent cost control

### Token-level

```yaml
# ModelConfig — per-agent token cap
apiVersion: kagent.dev/v1alpha2
kind: ModelConfig
metadata:
  name: budget-model-config
  namespace: kagent
spec:
  model: gpt-5.4-mini
  maxTokens: 2048        # hard cap on output tokens per call
  # Note: input token truncation requires system prompt engineering
  #       or agentgateway request transformation
```

### Per-agent

Each kagent `Agent` references a `modelConfig` by name. Give budget-conscious agents a `ModelConfig` that points at a cheaper model or has tighter `maxTokens`:

```yaml
# Expensive agent — detailed analysis
spec:
  declarative:
    modelConfig: premium-model-config   # gpt-5.4-mini, maxTokens: 8192

# Cheap agent — simple Q&A
spec:
  declarative:
    modelConfig: budget-model-config    # gpt-5.4-mini, maxTokens: 512
```

### Observability for cost

agentgateway can emit **token-usage metrics** per backend. Wire these to Prometheus + Grafana (already planned in the stack via `grafana-mcp: enabled: false` in kagent values — enable this for cost dashboards).

---

## Q12 — Can I implement custom cost controls?

### Yes — multiple layers

**Layer 1: agentgateway RateLimitPolicy**

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: RateLimitPolicy
spec:
  tokenLimit:
    requestsPerMinute: 1000   # TPM cap across all agents sharing this backend
  costLimit:
    dailyBudgetUSD: 10.00     # agentgateway tracks usage × model price
```

**Layer 2: Custom MCP tool budget guard**

In the FastMCP server, add a cost-tracking tool wrapper:

```python
from fastmcp import FastMCP
import httpx

mcp = FastMCP("abox-labs-mcp-server")
DAILY_BUDGET = float(os.getenv("DAILY_BUDGET_USD", "5.0"))
_spend_today = 0.0

@mcp.tool()
async def budget_status() -> dict:
    """Return remaining daily budget."""
    return {"remaining": DAILY_BUDGET - _spend_today, "limit": DAILY_BUDGET}
```

**Layer 3: Admission webhook**

A validating webhook rejects new `Agent` resources that don't declare a `modelConfig` with a `maxTokens` field — enforcing a "no unbounded agents" policy.

**Layer 4: Chargeback labels**

```yaml
metadata:
  labels:
    cost-center: "platform-team"
    project: "abox-labs"
```

agentgateway (and Prometheus) can group token metrics by label to produce per-team cost reports.

---

## Q13 — Per-agent budgets or depth of token limits

### Token depth = number of tool-call round-trips × tokens per call

For an agent doing 15 tool calls (see Q15), total token spend is roughly:

```
total_tokens ≈ system_prompt_tokens
              + Σ (tool_call_request_tokens + tool_result_tokens) × 15
              + final_answer_tokens

Example:
  system_prompt:       1000 tokens
  per-round-trip:       500 tokens (request + result) × 15 = 7500
  final answer:         200 tokens
  ─────────────────────────────────────────────────────────────────
  Total:               ~8700 tokens per multi-step session
```

### Controls

| Limit type | Config location | Granularity |
|---|---|---|
| Max output tokens / call | `ModelConfig.maxTokens` | Per ModelConfig → per agent |
| Max context window | Implicit in model choice | Per model |
| Max tool calls / session | System prompt instruction | Per agent (soft) |
| Daily token budget | agentgateway RateLimitPolicy | Per backend or per route |
| Per-request token log | agentgateway access logs | Observable, not enforced |

### Recommended abox setup

```yaml
# Three tiers of ModelConfig
budget-config:   maxTokens: 1024   # triage agents, quick answers
standard-config: maxTokens: 4096   # most agents (aire-agent, lab3-agent)
premium-config:  maxTokens: 16384  # conductor-agent doing full incident remediation
```

---

## Q14 — Is vLLM suitable for agents with many back-and-forth tool calls, or better for single-shot inference?

### vLLM's architecture

vLLM is optimised for **throughput** (many concurrent users × tokens/sec). Its key techniques:

- **PagedAttention** — efficient KV-cache management for long contexts
- **Continuous batching** — dynamic request batching to maximise GPU utilisation
- **Speculative decoding** — small draft model pre-fills tokens for large model

### Comparison by workload

| Workload | vLLM suitability | Why |
|---|---|---|
| **Single-shot inference** (translate, summarise) | ⭐⭐⭐⭐⭐ | High throughput, easy batching |
| **Chat (multi-turn, few turns)** | ⭐⭐⭐⭐ | KV cache reuse across turns |
| **Agents (15 tool-call round-trips)** | ⭐⭐⭐ | Works, but each tool-call is a new request → KV-cache reuse depends on prefix caching |

### Why agents stress vLLM differently

```
Turn 1: [system_prompt + user_message]                → LLM call 1
Turn 2: [system_prompt + turn1 + tool_result_1]       → LLM call 2 (grows)
Turn 3: [system_prompt + turn1-2 + tool_result_2]     → LLM call 3 (grows)
...
Turn 15: context window may be 10k-50k tokens         → LLM call 15
```

Each call has a **growing prefix** that overlaps with previous calls. vLLM's **prefix caching** (`--enable-prefix-caching`) reuses KV states for the shared prefix, making agent workloads much more efficient.

### Recommendation

**vLLM IS suitable for agents** — enable these flags:

```bash
vllm serve llama-3.1-8b \
  --enable-prefix-caching \    # reuse KV cache for growing context
  --max-model-len 32768 \      # enough for 15-turn agent sessions
  --gpu-memory-utilization 0.9
```

Without prefix caching, every round-trip re-computes the full context — wasteful and slow.

---

## Q15 — llm-d's scheduler: does it help when an agent makes 15 LLM calls?

### What llm-d is

[llm-d](https://github.com/llm-d/llm-d) (LLM Distributed) is a **Kubernetes-native inference scheduler** that extends the standard Kubernetes scheduler to make KV-cache–aware routing decisions. It routes LLM requests to the inference replica that already holds the relevant KV-cache prefix in GPU memory.

### The core insight

```
Without llm-d:
  Request arrives → any vLLM pod → full KV recompute if cache cold

With llm-d:
  Request arrives → llm-d scheduler reads prefix hash
                  → routes to the pod that has the prefix cached
                  → cache hit → 5–20× faster TTFT (time-to-first-token)
```

### For a 15-call agent session

```
Call 1:  [system_prompt]                    → any pod (cache cold)
Call 2:  [system_prompt + turn1]            → llm-d → SAME pod (prefix hit!)
Call 3:  [system_prompt + turn1 + turn2]    → llm-d → SAME pod (prefix hit!)
...
Call 15: [system_prompt + turns 1-14]       → llm-d → SAME pod (long prefix hit)
```

**With llm-d: calls 2–15 skip recomputing the growing shared prefix** → latency drops dramatically for long agent sessions.

### Does abox use llm-d?

Not yet. abox uses the OpenAI API (remote, managed) so KV-cache routing is handled by OpenAI's infrastructure, not by us. llm-d becomes relevant when running **self-hosted vLLM** at scale.

### When to add llm-d

| Condition | llm-d impact |
|---|---|
| Single vLLM pod | None (no routing decision) |
| 2–4 vLLM pods, low agent concurrency | Moderate — reduces cold starts |
| 4+ vLLM pods, high agent concurrency (many simultaneous 15-call sessions) | **High** — 3–10× throughput improvement for agentic workloads |

### Integration with abox

```yaml
# Future release: releases/vllm.yaml
# Add llm-d as a scheduler plugin alongside vLLM deployment
# llm-d exposes an OpenAI-compatible endpoint that agentgateway
# routes to instead of direct vLLM pods:

AgentgatewayBackend:
  name: vllm-local
  ai:
    provider:
      openai:
        baseUrl: http://llm-d-gateway.vllm.svc:8000/v1
        model: llama-3.1-8b
```

---

## Summary Table

| # | Question | Status in abox | Effort to add |
|---|---|---|---|
| 1 | Agent stuck handling | Partial (K8s liveness probe) | Medium — add per-call timeout to AgentgatewayBackend |
| 2 | Timeout / circuit breaker | Partial (retry config available) | Low — add `timeout` + `retries` to backends |
| 3 | Model failover | Not configured | Medium — add multiple AgentgatewayBackend + routing policy |
| 4 | Auto switch OpenAI→Claude→local | Not configured | Medium — multi-backend config + HTTPRoute weights |
| 5 | Response format normalization | Built into agentgateway | **Done** — transparent to agents |
| 6 | Agent versioning | Done via GitOps + OCI tags | **Done** — `make push` version-pins agents |
| 7 | Blue/Green / Canary | Architecture supports it | Medium — add namespace-per-version + weighted HTTPRoute |
| 8 | FastMCP framework | Used in abox (elicitation-mcp-server) | **Done** |
| 9 | Easiest MCP path | FastMCP for custom; kagent built-ins for K8s | **Done** |
| 10 | FinOps control | mcp-governance rate-limit enabled; detailed controls absent | Low-Medium — add maxTokens, timeout, cost labels |
| 11 | Token / per-agent control | ModelConfig per-agent — no maxTokens set | Low — add maxTokens to each ModelConfig |
| 12 | Custom cost controls | Possible at gateway + MCP + webhook layers | Medium |
| 13 | Per-agent budgets | Supported via ModelConfig tiers | Low |
| 14 | vLLM for agents | Suitable with `--enable-prefix-caching` | N/A (using managed OpenAI today) |
| 15 | llm-d scheduler | Not in abox; relevant for self-hosted vLLM | High — requires vLLM fleet deployment first |

---

*Generated: 2026-05-24 · Lab 7 — Certification deep-dive*
