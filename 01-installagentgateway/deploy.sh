#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# deploy.sh — Install AgentGateway and Set Up a Simple LLM Proxy
#
# Deploys a kind cluster with AgentGateway configured as a proxy to OpenAI.
# After deployment, all requests to /chat are forwarded to OpenAI's gpt-4o.
#
# Prerequisites:
#   - kind, kubectl, helm, jq installed
#   - OPENAI_API_KEY environment variable set
##############################################################################

CLUSTER_NAME="agw-install"
NAMESPACE="agentgateway-system"
AGW_VERSION="v1.1.0"
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
# Step 6: Create API key secret
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 6: Creating OpenAI API key secret..."

kubectl apply -f- <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: openai-secret
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  Authorization: "${OPENAI_API_KEY}"
EOF

# ---------------------------------------------------------------------------
# Step 7: Create the LLM backend
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 7: Creating OpenAI backend (gpt-4o)..."

kubectl apply -f- <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: openai-backend
  namespace: ${NAMESPACE}
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
EOF

# ---------------------------------------------------------------------------
# Step 8: Create the HTTPRoute
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 8: Creating HTTPRoute for /chat -> OpenAI backend..."

kubectl apply -f- <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: chat-route
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
        - name: openai-backend
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
echo " Endpoint:"
echo "   /chat  — Proxied to OpenAI gpt-4o"
echo ""
echo " To port-forward the gateway:"
echo "   kubectl port-forward -n ${NAMESPACE} svc/agentgateway-proxy 8080:80"
echo ""
echo " Then test with:"
echo "   ./test.sh"
echo ""
