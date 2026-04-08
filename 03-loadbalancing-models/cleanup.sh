#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# cleanup.sh — Remove all resources from the Load Balancing Demo
#
# Deletes AgentGateway resources, secrets, and the kind cluster.
##############################################################################

CLUSTER_NAME="agw-series"
NAMESPACE="agentgateway-system"

echo "==> Cleaning up AgentGateway load balancing demo..."

# ---------------------------------------------------------------------------
# Remove AgentGateway resources
# ---------------------------------------------------------------------------
echo ""
echo "==> Deleting AgentgatewayBackends..."
kubectl delete AgentgatewayBackend loadbalanced-backend stable-backend canary-backend \
  -n "${NAMESPACE}" --ignore-not-found

echo ""
echo "==> Deleting HTTPRoutes..."
kubectl delete httproute loadbalanced-route ab-test-route \
  -n "${NAMESPACE}" --ignore-not-found

echo ""
echo "==> Deleting Gateway..."
kubectl delete gateway agentgateway-proxy \
  -n "${NAMESPACE}" --ignore-not-found

echo ""
echo "==> Deleting Secrets..."
kubectl delete secret openai-secret anthropic-secret \
  -n "${NAMESPACE}" --ignore-not-found

# ---------------------------------------------------------------------------
# Delete the kind cluster
# ---------------------------------------------------------------------------
echo ""
echo "==> Deleting kind cluster '${CLUSTER_NAME}'..."
kind delete cluster --name "${CLUSTER_NAME}"

echo ""
echo "==> Cleanup complete."
