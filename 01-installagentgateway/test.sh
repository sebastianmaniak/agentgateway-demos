#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# test.sh — Test AgentGateway Proxy
#
# Sends requests to the /chat endpoint and displays the response.
#
# Requires: port-forward running on localhost:8080
#   kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:80
##############################################################################

GATEWAY_URL="${GATEWAY_URL:-localhost:8080}"

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
# Test 1: Single request
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Test 1: Single Chat Request"
echo " Expects response from gpt-4o via AgentGateway"
echo "============================================================"
echo ""

echo "  Sending request to /chat..."
response=$(curl -s "http://${GATEWAY_URL}/chat" \
  -H "Content-Type: application/json" \
  -d '{"messages": [{"role": "user", "content": "Say hello in one sentence and tell me which model you are."}]}')

model=$(echo "$response" | jq -r '.model // "unknown"')
content=$(echo "$response" | jq -r '.choices[0].message.content // .content[0].text // "no content"')

echo "  Model:   $model"
echo "  Response: $content"

# ---------------------------------------------------------------------------
# Test 2: Multiple requests
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Test 2: Multiple Requests (5x)"
echo " Verifies consistent routing to gpt-4o"
echo "============================================================"
echo ""

for i in $(seq 1 5); do
  model=$(curl -s "http://${GATEWAY_URL}/chat" \
    -H "Content-Type: application/json" \
    -d '{"messages": [{"role": "user", "content": "Say hello in one sentence."}]}' \
    | jq -r '.model // "unknown"')
  printf "  Request %d: %s\n" "$i" "$model"
done

# ---------------------------------------------------------------------------
# Test 3: Full JSON response
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Test 3: Full JSON Response"
echo "============================================================"
echo ""

curl -s "http://${GATEWAY_URL}/chat" \
  -H "Content-Type: application/json" \
  -d '{"messages": [{"role": "user", "content": "What is AgentGateway? Answer in one sentence."}]}' | jq .

echo ""
echo "==> Tests complete."
