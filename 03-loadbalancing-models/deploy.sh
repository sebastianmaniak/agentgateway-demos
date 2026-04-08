#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# deploy.sh — Deploy AgentGateway LLM Load Balancing Demo
#
# Deploys a kind cluster with AgentGateway configured for:
#   1. Multi-provider load balancing (OpenAI + Anthropic) on /chat
#   2. A/B traffic splitting (gpt-4o 80% / gpt-4o-mini 20%) on /test
#
# Prerequisites:
#   - kind, kubectl, helm, jq installed
#   - OPENAI_API_KEY and ANTHROPIC_API_KEY environment variables set
##############################################################################

CLUSTER_NAME="agw-series"
NAMESPACE="agentgateway-system"
AGW_VERSION="v1.0.1"
GATEWAY_API_VERSION="v1.5.0"

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
echo "==> Checking prerequisites..."

for cmd in kind kubectl helm jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is required but not installed." >&2
    exit 1
  fi
done

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  echo "ERROR: OPENAI_API_KEY environment variable is not set." >&2
  exit 1
fi

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "ERROR: ANTHROPIC_API_KEY environment variable is not set." >&2
  exit 1
fi

echo "    All prerequisites met."

# ---------------------------------------------------------------------------
# Step 1: Create kind cluster
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 1: Creating kind cluster '${CLUSTER_NAME}'..."

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "    Cluster '${CLUSTER_NAME}' already exists, skipping creation."
else
  kind create cluster --name "${CLUSTER_NAME}"
fi

# ---------------------------------------------------------------------------
# Step 2: Install Gateway API CRDs
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 2: Installing Gateway API CRDs (${GATEWAY_API_VERSION})..."

kubectl apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

# ---------------------------------------------------------------------------
# Step 3: Install AgentGateway via Helm
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 3: Installing AgentGateway CRDs and control plane (${AGW_VERSION})..."

helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --create-namespace --namespace "${NAMESPACE}" \
  --version "${AGW_VERSION}" \
  --set controller.image.pullPolicy=Always

helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace "${NAMESPACE}" \
  --version "${AGW_VERSION}" \
  --set controller.image.pullPolicy=Always \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true \
  --wait

# ---------------------------------------------------------------------------
# Step 4: Wait for pods to be ready
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 4: Waiting for AgentGateway pods to be ready..."

kubectl wait --for=condition=Ready pods --all -n "${NAMESPACE}" --timeout=120s
kubectl get pods -n "${NAMESPACE}"

# ---------------------------------------------------------------------------
# Step 5: Create the Gateway listener
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 5: Creating Gateway listener on port 80..."

kubectl apply -f- <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agentgateway-proxy
  namespace: ${NAMESPACE}
spec:
  gatewayClassName: agentgateway
  listeners:
  - protocol: HTTP
    port: 80
    name: http
    allowedRoutes:
      namespaces:
        from: All
EOF

# ---------------------------------------------------------------------------
# Step 6: Create API key secrets
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 6: Creating API key secrets..."

kubectl apply -f- <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: openai-secret
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  Authorization: "${OPENAI_API_KEY}"
---
apiVersion: v1
kind: Secret
metadata:
  name: anthropic-secret
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  Authorization: "${ANTHROPIC_API_KEY}"
EOF

# ---------------------------------------------------------------------------
# Step 7: Create multi-provider load balanced backend (/chat)
#
# Both providers are in the same priority group, so AgentGateway uses
# Power of Two Choices (P2C) to balance requests across them based on
# health, latency, and pending request count.
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 7: Creating load balanced backend (OpenAI + Anthropic)..."

kubectl apply -f- <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: loadbalanced-backend
  namespace: ${NAMESPACE}
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
EOF

# ---------------------------------------------------------------------------
# Step 8: Create HTTPRoute for /chat -> load balanced backend
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 8: Creating HTTPRoute for /chat (load balanced)..."

kubectl apply -f- <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: loadbalanced-route
  namespace: ${NAMESPACE}
spec:
  parentRefs:
    - name: agentgateway-proxy
      namespace: ${NAMESPACE}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /chat
      backendRefs:
        - name: loadbalanced-backend
          namespace: ${NAMESPACE}
          group: agentgateway.dev
          kind: AgentgatewayBackend
EOF

# ---------------------------------------------------------------------------
# Step 9: Create A/B testing backends
#
# Two separate backends with different models:
#   - stable-backend: gpt-4o (production)
#   - canary-backend: gpt-4o-mini (candidate for evaluation)
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 9: Creating A/B testing backends (stable + canary)..."

kubectl apply -f- <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: stable-backend
  namespace: ${NAMESPACE}
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
  namespace: ${NAMESPACE}
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
EOF

# ---------------------------------------------------------------------------
# Step 10: Create HTTPRoute for /test -> A/B split (80/20)
#
# Uses Gateway API weighted backendRefs to split traffic:
#   80% -> stable-backend (gpt-4o)
#   20% -> canary-backend (gpt-4o-mini)
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 10: Creating HTTPRoute for /test (80/20 A/B split)..."

kubectl apply -f- <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ab-test-route
  namespace: ${NAMESPACE}
spec:
  parentRefs:
    - name: agentgateway-proxy
      namespace: ${NAMESPACE}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /test
      backendRefs:
        - name: stable-backend
          namespace: ${NAMESPACE}
          group: agentgateway.dev
          kind: AgentgatewayBackend
          weight: 80
        - name: canary-backend
          namespace: ${NAMESPACE}
          group: agentgateway.dev
          kind: AgentgatewayBackend
          weight: 20
EOF

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Deployment complete!"
echo "============================================================"
echo ""
echo " Endpoints:"
echo "   /chat  — Load balanced across OpenAI gpt-4o + Anthropic claude-sonnet-4-6"
echo "   /test  — A/B split: 80% gpt-4o / 20% gpt-4o-mini"
echo ""
echo " To port-forward the gateway:"
echo "   kubectl port-forward -n ${NAMESPACE} svc/agentgateway-proxy 8080:80"
echo ""
echo " Then test with:"
echo "   ./test.sh"
echo ""
