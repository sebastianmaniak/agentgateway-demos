#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# deploy.sh — Deploy AgentGateway Content-Based Routing Demo
#
# Deploys a kind cluster with AgentGateway configured for:
#   1. Model-field extraction from request body (CEL transformation)
#   2. Regex header matching to route gpt-* → OpenAI, claude-* → Anthropic
#   3. Single /v1/chat/completions endpoint, multiple backends
#
# Prerequisites:
#   - kind, kubectl, helm, jq installed
#   - OPENAI_API_KEY environment variable set
#   - ANTHROPIC_API_KEY environment variable set
##############################################################################

CLUSTER_NAME="agw-series"
CLUSTER_CONTEXT="kind-${CLUSTER_NAME}"
NAMESPACE="agentgateway-system"
AGW_VERSION="v1.1.0"
GATEWAY_API_VERSION="v1.5.0"

cluster_exists() {
  kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"
}

k() {
  kubectl --context "${CLUSTER_CONTEXT}" "$@"
}

h() {
  helm --kube-context "${CLUSTER_CONTEXT}" "$@"
}

wait_for_condition() {
  local resource="$1"
  local condition="$2"
  local timeout="${3:-120s}"

  if ! k wait --for="condition=${condition}" "${resource}" -n "${NAMESPACE}" --timeout="${timeout}"; then
    echo "ERROR: ${resource} did not reach condition ${condition}." >&2
    k describe "${resource}" -n "${NAMESPACE}" || true
    exit 1
  fi
}

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

if cluster_exists; then
  echo "    Cluster '${CLUSTER_NAME}' already exists, skipping creation."
else
  kind create cluster --name "${CLUSTER_NAME}"
fi

echo "    Using cluster context '${CLUSTER_CONTEXT}'."
k cluster-info >/dev/null

# ---------------------------------------------------------------------------
# Step 2: Install Gateway API CRDs
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 2: Installing Gateway API CRDs (${GATEWAY_API_VERSION})..."

k apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

# ---------------------------------------------------------------------------
# Step 3: Install AgentGateway via Helm
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 3: Installing AgentGateway CRDs and control plane (${AGW_VERSION})..."

h upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --create-namespace --namespace "${NAMESPACE}" \
  --version "${AGW_VERSION}" \
  --set controller.image.pullPolicy=Always

h upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
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

k wait --for=condition=Ready pods --all -n "${NAMESPACE}" --timeout=120s
k get pods -n "${NAMESPACE}"

# ---------------------------------------------------------------------------
# Step 5: Create the Gateway listener
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 5: Creating Gateway listener on port 80..."

k apply -f- <<EOF
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

wait_for_condition "gateway/agentgateway-proxy" "Accepted"

# ---------------------------------------------------------------------------
# Step 6: Create provider secrets
#
# Two secrets:
#   - openai-secret: API key for OpenAI
#   - anthropic-secret: API key for Anthropic
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 6: Creating provider API key secrets..."

k apply -f- <<EOF
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
# Step 7: Create OpenAI backend
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 7: Creating OpenAI backend (gpt-5.4-mini)..."

k apply -f- <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: openai-backend
  namespace: ${NAMESPACE}
spec:
  ai:
    provider:
      openai:
        model: gpt-5.4-mini
  policies:
    auth:
      secretRef:
        name: openai-secret
EOF

wait_for_condition "agentgatewaybackend/openai-backend" "Accepted"

# ---------------------------------------------------------------------------
# Step 8: Create Anthropic backend
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 8: Creating Anthropic backend (claude-sonnet-4-5-20250929)..."

k apply -f- <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: anthropic-backend
  namespace: ${NAMESPACE}
spec:
  ai:
    provider:
      anthropic:
        model: claude-sonnet-4-5-20250929
  policies:
    auth:
      secretRef:
        name: anthropic-secret
EOF

wait_for_condition "agentgatewaybackend/anthropic-backend" "Accepted"

# ---------------------------------------------------------------------------
# Step 9: Create transformation policy
#
# Extracts the "model" field from the JSON request body and sets it as
# the x-model header. This runs in the PreRouting phase so the header
# is available for HTTPRoute matching.
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 9: Creating model extraction transformation policy..."

k apply -f- <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: extract-model
  namespace: ${NAMESPACE}
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: agentgateway-proxy
  traffic:
    phase: PreRouting
    transformation:
      request:
        set:
        - name: "x-model"
          value: 'json(request.body).model'
EOF

# ---------------------------------------------------------------------------
# Step 10: Create HTTPRoute with content-based matching
#
# Two rules on the same path (/v1/chat/completions):
#   - x-model: ^gpt-.* → openai-backend
#   - x-model: ^claude-.* → anthropic-backend
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 10: Creating content-based HTTPRoute..."

k apply -f- <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: content-routing
  namespace: ${NAMESPACE}
spec:
  parentRefs:
    - name: agentgateway-proxy
      namespace: ${NAMESPACE}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /v1/chat/completions
          headers:
            - type: RegularExpression
              name: x-model
              value: "^gpt-.*"
      backendRefs:
        - name: openai-backend
          namespace: ${NAMESPACE}
          group: agentgateway.dev
          kind: AgentgatewayBackend
    - matches:
        - path:
            type: PathPrefix
            value: /v1/chat/completions
          headers:
            - type: RegularExpression
              name: x-model
              value: "^claude-.*"
      backendRefs:
        - name: anthropic-backend
          namespace: ${NAMESPACE}
          group: agentgateway.dev
          kind: AgentgatewayBackend
EOF

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Deployment complete!"
echo "============================================================"
echo ""
echo " Backends:"
echo "   OpenAI    — gpt-5.4-mini            (model: ^gpt-.*)"
echo "   Anthropic — claude-sonnet-4-5  (model: ^claude-.*)"
echo ""
echo " Endpoint:"
echo "   POST /v1/chat/completions  — routed by model field in body"
echo ""
echo " How it works:"
echo "   1. AgentgatewayPolicy extracts \"model\" from JSON body → x-model header"
echo "   2. HTTPRoute matches x-model regex → correct backend"
echo "   3. Backend authenticates with provider and returns response"
echo ""
echo " To port-forward the gateway:"
echo "   kubectl --context ${CLUSTER_CONTEXT} port-forward -n ${NAMESPACE} svc/agentgateway-proxy 8080:80"
echo ""
echo " Then test with:"
echo "   ./test.sh"
echo ""
