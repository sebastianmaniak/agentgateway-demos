#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# test.sh — Test AgentGateway Load Balancing Demo
#
# Sends requests to both endpoints and displays which model handled each one:
#   /chat — multi-provider load balancing (OpenAI + Anthropic)
#   /test — A/B traffic splitting (80% gpt-4o / 20% gpt-4o-mini)
#
# Requires: port-forward running on localhost:8080
#   kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:80
##############################################################################

GATEWAY_URL="${GATEWAY_URL:-localhost:8080}"
NUM_REQUESTS="${NUM_REQUESTS:-10}"

# ---------------------------------------------------------------------------
# Preflight: check that the gateway is reachable
# ---------------------------------------------------------------------------
echo "==> Checking gateway at ${GATEWAY_URL}..."

if ! curl -sf -o /dev/null --max-time 3 "http://${GATEWAY_URL}" 2>/dev/null; then
  echo ""
  echo "WARNING: Gateway not reachable at ${GATEWAY_URL}."
  echo "Start a port-forward first:"
  echo "  kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:80"
  echo ""
  read -rp "Continue anyway? [y/N] " ans
  if [[ "${ans}" != "y" && "${ans}" != "Y" ]]; then
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Test 1: Multi-provider load balancing on /chat
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Test 1: Multi-Provider Load Balancing (/chat)"
echo " Expects responses from both gpt-4o and claude-sonnet-4-6"
echo "============================================================"
echo ""

declare -A chat_models 2>/dev/null || true

for i in $(seq 1 "${NUM_REQUESTS}"); do
  model=$(curl -s "http://${GATEWAY_URL}/chat" \
    -H "Content-Type: application/json" \
    -d '{"messages": [{"role": "user", "content": "Say hello in one sentence and tell me which model you are."}]}' \
    | jq -r '.model // "unknown"')
  printf "  Request %2d: %s\n" "$i" "$model"
done

# ---------------------------------------------------------------------------
# Test 2: A/B traffic splitting on /test
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Test 2: A/B Traffic Splitting (/test)"
echo " Expects ~80% gpt-4o and ~20% gpt-4o-mini"
echo "============================================================"
echo ""

for i in $(seq 1 "${NUM_REQUESTS}"); do
  model=$(curl -s "http://${GATEWAY_URL}/test" \
    -H "Content-Type: application/json" \
    -d '{"messages": [{"role": "user", "content": "Say hello in one sentence and tell me which model you are."}]}' \
    | jq -r '.model // "unknown"')
  printf "  Request %2d: %s\n" "$i" "$model"
done

echo ""
echo "==> Tests complete."
