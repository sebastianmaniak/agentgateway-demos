#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# cleanup.sh — Remove all resources from the Install AgentGateway demo
#
# Deletes AgentGateway resources, secrets, and the kind cluster.
##############################################################################

CLUSTER_NAME="agw-install"
NAMESPACE="agentgateway-system"

echo "==> Cleaning up AgentGateway install demo..."

# ---------------------------------------------------------------------------
# Remove AgentGateway resources
# ---------------------------------------------------------------------------
echo ""
echo "==> Deleting AgentgatewayBackend..."
kubectl delete AgentgatewayBackend openai-backend \
  -n "${NAMESPACE}" --ignore-not-found

echo ""
echo "==> Deleting HTTPRoute..."
kubectl delete httproute chat-route \
  -n "${NAMESPACE}" --ignore-not-found

echo ""
echo "==> Deleting Gateway..."
kubectl delete gateway agentgateway-proxy \
  -n "${NAMESPACE}" --ignore-not-found

echo ""
echo "==> Deleting Secret..."
kubectl delete secret openai-secret \
  -n "${NAMESPACE}" --ignore-not-found

# ---------------------------------------------------------------------------
# Delete the kind cluster
# ---------------------------------------------------------------------------
echo ""
echo "==> Deleting kind cluster '${CLUSTER_NAME}'..."
kind delete cluster --name "${CLUSTER_NAME}"

echo ""
echo "==> Cleanup complete."
