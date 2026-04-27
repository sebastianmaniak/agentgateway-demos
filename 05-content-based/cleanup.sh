#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# cleanup.sh — Remove all resources from the Content-Based Routing Demo
#
# Deletes AgentGateway resources, secrets, and the kind cluster.
##############################################################################

CLUSTER_NAME="agw-series"
CLUSTER_CONTEXT="kind-${CLUSTER_NAME}"
NAMESPACE="agentgateway-system"

cluster_exists() {
  kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"
}

k() {
  kubectl --context "${CLUSTER_CONTEXT}" "$@"
}

echo "==> Cleaning up AgentGateway content-based routing demo..."

if ! cluster_exists; then
  echo "==> Cluster '${CLUSTER_NAME}' does not exist, skipping Kubernetes resource deletion."
  echo ""
  echo "==> Cleanup complete."
  exit 0
fi

# ---------------------------------------------------------------------------
# Remove AgentGateway policies
# ---------------------------------------------------------------------------
echo ""
echo "==> Deleting AgentgatewayPolicies..."
k delete AgentgatewayPolicy extract-model \
  -n "${NAMESPACE}" --ignore-not-found

# ---------------------------------------------------------------------------
# Remove AgentGateway backends
# ---------------------------------------------------------------------------
echo ""
echo "==> Deleting AgentgatewayBackends..."
k delete AgentgatewayBackend openai-backend anthropic-backend \
  -n "${NAMESPACE}" --ignore-not-found

# ---------------------------------------------------------------------------
# Remove HTTPRoutes
# ---------------------------------------------------------------------------
echo ""
echo "==> Deleting HTTPRoutes..."
k delete httproute content-routing \
  -n "${NAMESPACE}" --ignore-not-found

# ---------------------------------------------------------------------------
# Remove Gateway
# ---------------------------------------------------------------------------
echo ""
echo "==> Deleting Gateway..."
k delete gateway agentgateway-proxy \
  -n "${NAMESPACE}" --ignore-not-found

# ---------------------------------------------------------------------------
# Remove Secrets
# ---------------------------------------------------------------------------
echo ""
echo "==> Deleting Secrets..."
k delete secret openai-secret anthropic-secret \
  -n "${NAMESPACE}" --ignore-not-found

# ---------------------------------------------------------------------------
# Delete the kind cluster
# ---------------------------------------------------------------------------
echo ""
echo "==> Deleting kind cluster '${CLUSTER_NAME}'..."
kind delete cluster --name "${CLUSTER_NAME}"

echo ""
echo "==> Cleanup complete."
