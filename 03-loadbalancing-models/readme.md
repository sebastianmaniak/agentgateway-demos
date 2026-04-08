# 03 - Load Balancing Across LLM Models

This demo shows how to use **AgentGateway** to load balance traffic across multiple LLM providers (OpenAI and Anthropic) using a single unified endpoint. It also demonstrates **traffic splitting** for A/B testing between model versions.

## How It Works

AgentGateway uses the **Power of Two Choices (P2C)** load balancing algorithm:
- Selects two random providers from the available pool
- Routes to the provider with the better score based on health, latency, and pending requests
- Scoring: `score = health / (1 + latency_penalty)` where `latency_penalty = request_latency * (1 + pending_requests * 0.1)`

Key behaviors:
- **Health tracking** — EWMA (α=0.3) tracks success rate per provider
- **Latency tracking** — EWMA of response time (only successful requests)
- **Pending request penalty** — each active request adds 10% latency penalty
- **Eviction** — providers returning 429 (rate limit) are temporarily removed from the pool

> **Note:** Eviction currently only triggers on 429 responses with proper rate-limit headers. Other errors (503, DNS failures, connection errors) degrade the health score but do not evict the provider.

## Prerequisites

- [kind](https://kind.sigs.k8s.io/) installed
- [kubectl](https://kubernetes.io/docs/tasks/tools/) installed
- [Helm](https://helm.sh/docs/intro/install/) installed
- OpenAI API key (`OPENAI_API_KEY` env var)
- Anthropic API key (`ANTHROPIC_API_KEY` env var)

## Quick Start

```bash
# Set your API keys
export OPENAI_API_KEY="your-openai-key"
export ANTHROPIC_API_KEY="your-anthropic-key"

# Deploy everything
./deploy.sh

# Run tests
./test.sh

# Cleanup
./cleanup.sh
```

## What Gets Deployed

### 1. Kind Cluster & AgentGateway

Creates a local Kubernetes cluster and installs AgentGateway with Gateway API support.

### 2. Gateway Listener

A Gateway resource listening on port 80 for HTTP traffic, accepting routes from all namespaces.

### 3. Multi-Provider Load Balanced Backend

An `AgentgatewayBackend` with two providers in the same priority group:
- **openai-gpt4** — OpenAI `gpt-4o`
- **anthropic-claude** — Anthropic `claude-sonnet-4-6`

Requests to `/chat` are load balanced across both providers using P2C.

### 4. Traffic Splitting for A/B Testing

Two separate backends with weighted routing:
- **stable-backend** (80%) — OpenAI `gpt-4o` (production model)
- **canary-backend** (20%) — OpenAI `gpt-4o-mini` (candidate model)

Requests to `/test` split traffic 80/20 between stable and canary.

## Manual Step-by-Step

### Step 1: Create the Kind cluster

```bash
kind create cluster --name agw-series
```

### Step 2: Install Gateway API CRDs

```bash
kubectl apply --server-side --force-conflicts \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.0/standard-install.yaml
```

### Step 3: Install AgentGateway

```bash
# CRDs
helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --create-namespace --namespace agentgateway-system \
  --version v1.0.1 \
  --set controller.image.pullPolicy=Always

# Control plane + data plane
helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace agentgateway-system \
  --version v1.0.1 \
  --set controller.image.pullPolicy=Always \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true \
  --wait
```

### Step 4: Verify pods are running

```bash
kubectl get pods -n agentgateway-system
```

### Step 5: Create the Gateway

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agentgateway-proxy
  namespace: agentgateway-system
spec:
  gatewayClassName: agentgateway
  listeners:
  - protocol: HTTP
    port: 80
    name: http
    allowedRoutes:
      namespaces:
        from: All
```

### Step 6: Create API key secrets

```bash
# OpenAI
kubectl create secret generic openai-secret \
  -n agentgateway-system \
  --from-literal=Authorization="$OPENAI_API_KEY"

# Anthropic
kubectl create secret generic anthropic-secret \
  -n agentgateway-system \
  --from-literal=Authorization="$ANTHROPIC_API_KEY"
```

### Step 7: Create the load balanced backend

This backend puts both providers in the same priority group so P2C balances across them.

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: loadbalanced-backend
  namespace: agentgateway-system
spec:
  ai:
    groups:
      - providers:
          - name: openai-gpt4
            openai:
              model: gpt-4o
            policies:
              auth:
                secretRef:
                  name: openai-secret
          - name: anthropic-claude
            anthropic:
              model: claude-sonnet-4-6
            policies:
              auth:
                secretRef:
                  name: anthropic-secret
```

### Step 8: Create the HTTPRoute for load balancing

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: loadbalanced-route
  namespace: agentgateway-system
spec:
  parentRefs:
    - name: agentgateway-proxy
      namespace: agentgateway-system
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /chat
      backendRefs:
        - name: loadbalanced-backend
          namespace: agentgateway-system
          group: agentgateway.dev
          kind: AgentgatewayBackend
```

### Step 9: Create A/B testing backends with traffic splitting

Two separate backends — one stable, one canary — with weighted routing (80/20).

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: stable-backend
  namespace: agentgateway-system
spec:
  ai:
    groups:
      - providers:
          - name: stable-model
            openai:
              model: gpt-4o
            policies:
              auth:
                secretRef:
                  name: openai-secret
---
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: canary-backend
  namespace: agentgateway-system
spec:
  ai:
    groups:
      - providers:
          - name: canary-model
            openai:
              model: gpt-4o-mini
            policies:
              auth:
                secretRef:
                  name: openai-secret
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ab-test-route
  namespace: agentgateway-system
spec:
  parentRefs:
    - name: agentgateway-proxy
      namespace: agentgateway-system
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /test
      backendRefs:
        - name: stable-backend
          namespace: agentgateway-system
          group: agentgateway.dev
          kind: AgentgatewayBackend
          weight: 80
        - name: canary-backend
          namespace: agentgateway-system
          group: agentgateway.dev
          kind: AgentgatewayBackend
          weight: 20
```

### Step 10: Test

```bash
# Test load balancing across providers (hit /chat multiple times)
for i in {1..10}; do
  echo "--- Request $i ---"
  curl -s "localhost:8080/chat" \
    -H "Content-Type: application/json" \
    -d '{"messages": [{"role": "user", "content": "Say hello and tell me which model you are"}]}' | jq -r '.model'
done

# Test A/B traffic splitting (hit /test multiple times)
for i in {1..10}; do
  echo "--- Request $i ---"
  curl -s "localhost:8080/test" \
    -H "Content-Type: application/json" \
    -d '{"messages": [{"role": "user", "content": "Say hello and tell me which model you are"}]}' | jq -r '.model'
done
```

## Cleanup

```bash
# Remove all resources
kubectl delete AgentgatewayBackend loadbalanced-backend stable-backend canary-backend -n agentgateway-system
kubectl delete httproute loadbalanced-route ab-test-route -n agentgateway-system
kubectl delete secret openai-secret anthropic-secret -n agentgateway-system

# Delete the cluster
kind delete cluster --name agw-series
```

## References

- [AgentGateway Load Balancing Docs](https://agentgateway.dev/docs/kubernetes/main/llm/load-balancing/)
- [Gateway API HTTPRoute Spec](https://gateway-api.sigs.k8s.io/reference/spec/#gateway.networking.k8s.io/v1.HTTPRoute)
