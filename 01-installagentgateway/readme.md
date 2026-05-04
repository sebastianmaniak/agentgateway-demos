# 01 - Install AgentGateway and Set Up a Proxy

This demo walks through installing **AgentGateway** on a local Kubernetes cluster and configuring it as a proxy to an LLM provider. By the end, you'll have a running gateway that accepts OpenAI-compatible requests on `/chat` and forwards them to OpenAI's `gpt-4o`.

## Architecture

```
┌──────────┐     HTTP      ┌──────────────────┐     HTTPS     ┌──────────┐
│  Client   │────/chat────▶│  AgentGateway    │─────────────▶│  OpenAI  │
│  (curl)   │              │  (Gateway Proxy)  │              │  gpt-4o  │
└──────────┘               └──────────────────┘               └──────────┘
```

AgentGateway sits between your application and the LLM provider. It uses the Kubernetes **Gateway API** to define listeners and routes, and custom **AgentgatewayBackend** resources to define LLM providers.

## Key Concepts

- **Gateway** — A Kubernetes Gateway API resource that creates an HTTP listener on port 80
- **AgentgatewayBackend** — A custom resource that defines an LLM provider (model, auth credentials)
- **HTTPRoute** — A Gateway API resource that routes requests from a path (e.g., `/chat`) to a backend
- **Secret** — Stores the API key used to authenticate with the LLM provider

## Prerequisites

- [kind](https://kind.sigs.k8s.io/) installed
- [kubectl](https://kubernetes.io/docs/tasks/tools/) installed
- [Helm](https://helm.sh/docs/intro/install/) installed
- [jq](https://jqlang.github.io/jq/download/) installed
- OpenAI API key (`OPENAI_API_KEY` env var)

## Quick Start

```bash
# Set your API key
export OPENAI_API_KEY="your-openai-key"

# Deploy everything
./deploy.sh

# Port-forward the gateway
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:80 &

# Run tests
./test.sh

# Cleanup
./cleanup.sh
```

## What Gets Deployed

### 1. Kind Cluster

A local Kubernetes cluster named `agw-install`.

### 2. Gateway API CRDs

The standard Gateway API CRDs (v1.5.0) that AgentGateway builds on.

### 3. AgentGateway Control Plane

Installed via Helm — includes the AgentGateway CRDs and the controller that watches for Gateway, HTTPRoute, and AgentgatewayBackend resources.

### 4. Gateway Listener

A Gateway resource listening on port 80 for HTTP traffic.

### 5. OpenAI Backend

An `AgentgatewayBackend` resource pointing to OpenAI's `gpt-4o` model, with authentication via a Kubernetes Secret.

### 6. HTTP Route

An HTTPRoute that sends all `/chat` requests to the OpenAI backend.

## Manual Step-by-Step

### Step 1: Create the Kind cluster

```bash
kind create cluster --name agw-install
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
  --version v1.1.0 \
  --set controller.image.pullPolicy=Always

# Control plane + data plane
helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace agentgateway-system \
  --version v1.1.0 \
  --set controller.image.pullPolicy=Always \
  --wait
```

### Step 4: Verify pods are running

```bash
kubectl get pods -n agentgateway-system
```

Expected output:

```
NAME                                      READY   STATUS    RESTARTS   AGE
agentgateway-controller-xxxxxxxxxx-xxxxx  1/1     Running   0          30s
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

### Step 6: Create the API key secret

```bash
kubectl create secret generic openai-secret \
  -n agentgateway-system \
  --from-literal=Authorization="$OPENAI_API_KEY"
```

### Step 7: Create the LLM backend

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: openai-backend
  namespace: agentgateway-system
spec:
  ai:
    groups:
      - providers:
          - name: openai-gpt4o
            openai:
              model: gpt-4o
            policies:
              auth:
                secretRef:
                  name: openai-secret
```

### Step 8: Create the HTTPRoute

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: chat-route
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
        - name: openai-backend
          namespace: agentgateway-system
          group: agentgateway.dev
          kind: AgentgatewayBackend
```

### Step 9: Port-forward and test

```bash
# Start port-forward (run in background)
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:80 &
```

Wait a few seconds for the port-forward to establish, then send a request:

```bash
curl -s "http://localhost:8080/chat" \
  -H "Content-Type: application/json" \
  -d '{"messages": [{"role": "user", "content": "Say hello and tell me which model you are"}]}' | jq .
```

You should see a response from `gpt-4o` with the model field set in the JSON response.

```bash
# Stop the port-forward when done
kill %1
```

## Cleanup

```bash
# Remove all resources
kubectl delete AgentgatewayBackend openai-backend -n agentgateway-system
kubectl delete httproute chat-route -n agentgateway-system
kubectl delete gateway agentgateway-proxy -n agentgateway-system
kubectl delete secret openai-secret -n agentgateway-system

# Delete the cluster
kind delete cluster --name agw-install
```

Or simply run:

```bash
./cleanup.sh
```

## What's Next

Once you have AgentGateway running as a basic proxy, explore these demos:

- **03 - Load Balancing Models** — Balance traffic across multiple LLM providers
- **04 - Virtual Keys** — Manage API keys with rate limiting and access control
- **05 - Content-Based Routing** — Route requests based on message content

## References

- [AgentGateway Docs](https://agentgateway.dev/docs/)
- [Gateway API Spec](https://gateway-api.sigs.k8s.io/)
- [Kind Quick Start](https://kind.sigs.k8s.io/docs/user/quick-start/)
