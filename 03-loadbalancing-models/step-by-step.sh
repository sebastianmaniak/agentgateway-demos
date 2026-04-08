#!/usr/bin/env bash
##############################################################################
# step-by-step.sh — Interactive walk-through of the agentgateway LLM
#                    Load Balancing demo
#
# Pauses after each step so you can inspect state, explain to an audience,
# or troubleshoot before moving on. Press ENTER to continue to the next step.
# Every command is displayed before it runs so the audience can follow along.
#
# Prerequisites:
#   - kind, kubectl, helm, jq installed
#   - OPENAI_API_KEY and ANTHROPIC_API_KEY environment variables set
##############################################################################
set -euo pipefail

CLUSTER_NAME="agw-series"
NAMESPACE="agentgateway-system"
AGW_VERSION="v1.0.1"
GATEWAY_API_VERSION="v1.5.0"

# ---------------------------------------------------------------------------
# Colors & Symbols
# ---------------------------------------------------------------------------
BOLD='\033[1m'
DIM='\033[2m'
ITALIC='\033[3m'
RESET='\033[0m'

# Brand colors — tuned for light terminals
PURPLE='\033[38;2;100;30;160m'
CYAN='\033[38;2;0;120;180m'
GREEN='\033[38;2;0;130;80m'
ORANGE='\033[38;2;180;90;20m'
RED='\033[38;2;190;40;40m'
YELLOW='\033[38;2;140;110;0m'
BLUE='\033[38;2;40;80;180m'
WHITE='\033[38;2;30;30;40m'
GRAY='\033[38;2;120;120;135m'

# Backgrounds — subtle tints on light terminals
BG_PURPLE='\033[48;2;235;225;245m'
BG_CYAN='\033[48;2;220;240;250m'
BG_GREEN='\033[48;2;220;245;230m'
BG_ORANGE='\033[48;2;250;235;220m'

# Symbols
CHECK="${GREEN}✓${RESET}"
CROSS="${RED}✗${RESET}"
ARROW="${CYAN}→${RESET}"
BULLET="${PURPLE}●${RESET}"
DIAMOND="${ORANGE}◆${RESET}"
ROCKET="${PURPLE}▸${RESET}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

pause() {
  echo ""
  echo -e "${DIM}────────────────────────────────────────────────────────────────${RESET}"
  echo -e -n "  ${GRAY}Press ${WHITE}${BOLD}ENTER${RESET}${GRAY} to continue to the next step...${RESET}"
  read -r _
  echo ""
}

header() {
  local step="$1"
  local title="$2"
  local color="${3:-$PURPLE}"
  local width=64
  echo ""
  echo -e "${color}${BOLD}╔$(printf '═%.0s' $(seq 1 $width))╗${RESET}"
  printf -v padded_step "%-$(($width - 2))s" "$step"
  echo -e "${color}${BOLD}║${RESET}  ${DIM}${padded_step}${RESET}${color}${BOLD}║${RESET}"
  printf -v padded_title "%-$(($width - 2))s" "$title"
  echo -e "${color}${BOLD}║${RESET}  ${WHITE}${BOLD}${padded_title}${RESET}${color}${BOLD}║${RESET}"
  echo -e "${color}${BOLD}╚$(printf '═%.0s' $(seq 1 $width))╝${RESET}"
  echo ""
}

# Print a command
show_cmd() {
  echo -e "  ${YELLOW}\$ ${WHITE}$*${RESET}"
}

# Print YAML with syntax highlighting (no backgrounds)
show_yaml() {
  local yaml="$1"
  # RGB color codes for sed — matching the palette
  local C_PURPLE; C_PURPLE=$(printf '\033[38;2;100;30;160m')
  local C_CYAN;   C_CYAN=$(printf '\033[38;2;0;120;180m')
  local C_GREEN;  C_GREEN=$(printf '\033[38;2;0;130;80m')
  local C_ORANGE; C_ORANGE=$(printf '\033[38;2;180;90;20m')
  local C_RED;    C_RED=$(printf '\033[38;2;190;40;40m')
  local C_BLUE;   C_BLUE=$(printf '\033[38;2;40;80;180m')
  local C_GRAY;   C_GRAY=$(printf '\033[38;2;120;120;135m')
  local C_RESET;  C_RESET=$(printf '\033[0m')

  echo -e "  ${YELLOW}\$ ${WHITE}kubectl apply -f- <<EOF${RESET}"
  echo "$yaml" | while IFS= read -r line; do
    colored=$(echo "$line" | sed \
      -e "s/apiVersion:/${C_PURPLE}apiVersion:${C_RESET}/g" \
      -e "s/kind:/${C_CYAN}kind:${C_RESET}/g" \
      -e "s/metadata:/${C_PURPLE}metadata:${C_RESET}/g" \
      -e "s/spec:/${C_PURPLE}spec:${C_RESET}/g" \
      -e "s/name:/${C_BLUE}name:${C_RESET}/g" \
      -e "s/namespace:/${C_BLUE}namespace:${C_RESET}/g" \
      -e "s/model:/${C_ORANGE}model:${C_RESET}/g" \
      -e "s/weight:/${C_RED}weight:${C_RESET}/g" \
      -e "s/providers:/${C_GREEN}providers:${C_RESET}/g" \
      -e "s/groups:/${C_GREEN}groups:${C_RESET}/g" \
      -e "s/rules:/${C_GREEN}rules:${C_RESET}/g" \
      -e "s/listeners:/${C_GREEN}listeners:${C_RESET}/g" \
      -e "s/backendRefs:/${C_GREEN}backendRefs:${C_RESET}/g" \
      -e "s/parentRefs:/${C_GREEN}parentRefs:${C_RESET}/g" \
      -e "s/matches:/${C_GREEN}matches:${C_RESET}/g" \
      -e "s/policies:/${C_PURPLE}policies:${C_RESET}/g" \
      -e "s/secretRef:/${C_PURPLE}secretRef:${C_RESET}/g" \
      -e "s/stringData:/${C_PURPLE}stringData:${C_RESET}/g" \
      -e "s/#.*$/${C_GRAY}&${C_RESET}/g" \
    )
    echo -e "  ${colored}${RESET}"
  done
  echo -e "  ${WHITE}EOF${RESET}"
}

# Print an info line
info() {
  echo -e "  ${BULLET} $*"
}

# Print a success line
success() {
  echo -e "  ${CHECK} ${GREEN}$*${RESET}"
}

# Print a warning line
warn() {
  echo -e "  ${DIAMOND} ${ORANGE}$*${RESET}"
}

# Print a description
desc() {
  echo -e "  ${GRAY}${ITALIC}$*${RESET}"
}

# Progress bar for visual step tracking
TOTAL_STEPS=12
show_progress() {
  local current=$1
  local filled=$((current * 40 / TOTAL_STEPS))
  local empty=$((40 - filled))
  local pct=$((current * 100 / TOTAL_STEPS))
  echo -n -e "  ${PURPLE}"
  [[ $filled -gt 0 ]] && printf '█%.0s' $(seq 1 $filled)
  echo -n -e "${GRAY}"
  [[ $empty -gt 0 ]] && printf '░%.0s' $(seq 1 $empty)
  echo -e " ${WHITE}${BOLD}${pct}%${RESET}  ${DIM}(${current}/${TOTAL_STEPS})${RESET}"
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
clear 2>/dev/null || true
echo ""
echo -e "${PURPLE}${BOLD}"
cat << 'BANNER'
       ╔═══════════════════════════════════════════════════════╗
       ║                                                       ║
       ║       Load Balancing LLM Models                       ║
       ║       with agentgateway                               ║
       ║                                                       ║
       ╚═══════════════════════════════════════════════════════╝
BANNER
echo -e "${RESET}"
echo -e "  ${GRAY}Interactive step-by-step demo${RESET}"
echo -e "  ${GRAY}Power of Two Choices (P2C) + A/B Traffic Splitting${RESET}"
echo ""
echo -e "  ${PURPLE}●${RESET} Multi-provider load balancing  ${CYAN}●${RESET} Gateway API native"
echo -e "  ${GREEN}●${RESET} A/B testing with weights       ${ORANGE}●${RESET} Automatic health tracking"
echo ""
show_progress 0

pause

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
header "PREFLIGHT" "Checking Prerequisites" "$CYAN"

echo -e "  ${WHITE}${BOLD}Tools:${RESET}"
MISSING=""
for cmd in kind kubectl helm jq curl; do
  if command -v "$cmd" &>/dev/null; then
    echo -e "  ${CHECK} ${WHITE}${cmd}${RESET}  ${DIM}$(command -v "$cmd")${RESET}"
  else
    echo -e "  ${CROSS} ${RED}${cmd}${RESET}  ${DIM}(not found)${RESET}"
    MISSING="$MISSING $cmd"
  fi
done

if [[ -n "$MISSING" ]]; then
  echo ""
  echo -e "  ${CROSS} ${RED}${BOLD}Missing required tools:${MISSING}${RESET}"
  exit 1
fi

echo ""
echo -e "  ${WHITE}${BOLD}API Keys:${RESET}"

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  echo -e "  ${CROSS} ${RED}OPENAI_API_KEY is not set${RESET}"
  echo -e "  ${DIM}  export OPENAI_API_KEY=\"your-key\"${RESET}"
  exit 1
else
  echo -e "  ${CHECK} ${WHITE}OPENAI_API_KEY${RESET}  ${DIM}(${#OPENAI_API_KEY} chars)${RESET}"
fi

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  echo -e "  ${CROSS} ${RED}ANTHROPIC_API_KEY is not set${RESET}"
  echo -e "  ${DIM}  export ANTHROPIC_API_KEY=\"your-key\"${RESET}"
  exit 1
else
  echo -e "  ${CHECK} ${WHITE}ANTHROPIC_API_KEY${RESET}  ${DIM}(${#ANTHROPIC_API_KEY} chars)${RESET}"
fi

echo ""
success "All prerequisites met."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 1 — Create the Kind cluster
# ═══════════════════════════════════════════════════════════════════════════
header "STEP 1 of 12" "Create the Kind Cluster" "$PURPLE"
show_progress 1

desc "Creates a local Kubernetes cluster for the demo."
echo ""

show_cmd "kind create cluster --name ${CLUSTER_NAME}"
echo ""

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  warn "Cluster '${CLUSTER_NAME}' already exists — skipping creation."
else
  kind create cluster --name "${CLUSTER_NAME}"
fi

echo ""
success "Cluster '${CLUSTER_NAME}' is ready."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 2 — Install Gateway API CRDs
# ═══════════════════════════════════════════════════════════════════════════
header "STEP 2 of 12" "Install Gateway API CRDs" "$CYAN"
show_progress 2

desc "The Gateway API CRDs define resources like Gateway and HTTPRoute."
desc "agentgateway implements the Gateway API spec."
echo ""

show_cmd "kubectl apply --server-side --force-conflicts \\"
echo -e "    ${WHITE}-f https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml${RESET}"
echo ""

kubectl apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

echo ""
success "Gateway API CRDs (${GATEWAY_API_VERSION}) installed."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 3a — Install agentgateway CRDs
# ═══════════════════════════════════════════════════════════════════════════
header "STEP 3a of 12" "Install agentgateway CRDs" "$GREEN"
show_progress 3

desc "Custom Resource Definitions for AgentgatewayBackend and other resources."
echo ""

show_cmd "helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \\"
echo -e "    ${WHITE}--create-namespace --namespace ${NAMESPACE} \\${RESET}"
echo -e "    ${WHITE}--version ${AGW_VERSION} \\${RESET}"
echo -e "    ${WHITE}--set controller.image.pullPolicy=Always${RESET}"
echo ""

helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --create-namespace --namespace "${NAMESPACE}" \
  --version "${AGW_VERSION}" \
  --set controller.image.pullPolicy=Always

echo ""
success "agentgateway CRDs installed."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 3b — Install agentgateway control plane + proxy
# ═══════════════════════════════════════════════════════════════════════════
header "STEP 3b of 12" "Install agentgateway Control Plane + Proxy" "$GREEN"
show_progress 3

desc "The controller and data plane proxy that handles LLM routing."
echo ""

show_cmd "helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \\"
echo -e "    ${WHITE}--namespace ${NAMESPACE} \\${RESET}"
echo -e "    ${WHITE}--version ${AGW_VERSION} \\${RESET}"
echo -e "    ${WHITE}--set controller.image.pullPolicy=Always \\${RESET}"
echo -e "    ${WHITE}--set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true \\${RESET}"
echo -e "    ${WHITE}--wait${RESET}"
echo ""

helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace "${NAMESPACE}" \
  --version "${AGW_VERSION}" \
  --set controller.image.pullPolicy=Always \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true \
  --wait

echo ""
success "agentgateway ${AGW_VERSION} control plane installed."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 4 — Verify pods are running
# ═══════════════════════════════════════════════════════════════════════════
header "STEP 4 of 12" "Verify Pods Are Running" "$ORANGE"
show_progress 4

desc "Waiting for all pods to be Ready..."
echo ""

show_cmd "kubectl wait --for=condition=Ready pods --all -n ${NAMESPACE} --timeout=120s"
echo ""
kubectl wait --for=condition=Ready pods --all -n "${NAMESPACE}" --timeout=120s

echo ""
show_cmd "kubectl get pods -n ${NAMESPACE}"
echo ""
kubectl get pods -n "${NAMESPACE}"

echo ""
success "All pods are running."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 5 — Create the Gateway listener
header "STEP 5 of 12" "Create the Gateway Listener" "$PURPLE"
show_progress 5

desc "Creates a listener on port 80, accepting routes from all namespaces."
echo ""

GATEWAY_YAML="apiVersion: gateway.networking.k8s.io/v1
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
        from: All"

show_yaml "$GATEWAY_YAML"
echo ""
echo "$GATEWAY_YAML" | kubectl apply -f-

echo ""
success "Gateway created on port 80."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 6 — Create API key secrets
# ═══════════════════════════════════════════════════════════════════════════
header "STEP 6 of 12" "Create API Key Secrets" "$CYAN"
show_progress 6

desc "Storing provider API keys as Kubernetes Secrets."
desc "agentgateway injects these into outbound requests automatically."
echo ""

info "${WHITE}openai-secret${RESET}     ${ARROW} OPENAI_API_KEY"
info "${WHITE}anthropic-secret${RESET}  ${ARROW} ANTHROPIC_API_KEY"
echo ""

SECRETS_DISPLAY="apiVersion: v1
kind: Secret
metadata:
  name: openai-secret
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  Authorization: \"\${OPENAI_API_KEY}\"
---
apiVersion: v1
kind: Secret
metadata:
  name: anthropic-secret
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  Authorization: \"\${ANTHROPIC_API_KEY}\""

show_yaml "$SECRETS_DISPLAY"
echo ""

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

echo ""
success "Secrets created."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 7 — Create the load balanced backend
# ═══════════════════════════════════════════════════════════════════════════
header "STEP 7 of 12" "Create the Load Balanced Backend" "$GREEN"
show_progress 7

desc "Two providers in the SAME priority group = P2C load balanced."
echo ""

echo -e "  ${BG_GREEN}${WHITE}${BOLD} Provider 1 ${RESET}  ${WHITE}openai-gpt4${RESET}       ${ARROW} OpenAI ${ORANGE}gpt-4o${RESET}"
echo -e "  ${BG_ORANGE}${WHITE}${BOLD} Provider 2 ${RESET}  ${WHITE}anthropic-claude${RESET}  ${ARROW} Anthropic ${ORANGE}claude-sonnet-4-6${RESET}"
echo ""

LB_BACKEND_YAML="apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: loadbalanced-backend
  namespace: ${NAMESPACE}
spec:
  ai:
    groups:
      - providers:          # same group = P2C load balanced
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
                  name: anthropic-secret"

show_yaml "$LB_BACKEND_YAML"
echo ""
echo "$LB_BACKEND_YAML" | kubectl apply -f-

echo ""
success "Load balanced backend created."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 8 — Create HTTPRoute for /chat
# ═══════════════════════════════════════════════════════════════════════════
header "STEP 8 of 12" "Create HTTPRoute for /chat" "$PURPLE"
show_progress 8

desc "Standard Gateway API HTTPRoute — no proprietary annotations."
echo ""

echo -e "  ${BG_PURPLE}${WHITE}${BOLD} /chat ${RESET}  ${ARROW}  ${WHITE}loadbalanced-backend${RESET}  ${ARROW}  ${GREEN}P2C across OpenAI + Anthropic${RESET}"
echo ""

LB_ROUTE_YAML="apiVersion: gateway.networking.k8s.io/v1
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
          kind: AgentgatewayBackend"

show_yaml "$LB_ROUTE_YAML"
echo ""
echo "$LB_ROUTE_YAML" | kubectl apply -f-

echo ""
success "HTTPRoute for /chat created."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 9 — Create A/B testing backends
# ═══════════════════════════════════════════════════════════════════════════
header "STEP 9 of 12" "Create A/B Testing Backends" "$ORANGE"
show_progress 9

desc "Two separate backends for traffic splitting."
echo ""

echo -e "  ${BG_GREEN}${WHITE}${BOLD} STABLE  ${RESET}  ${WHITE}gpt-4o${RESET}       ${DIM}(production model)${RESET}"
echo -e "  ${BG_ORANGE}${WHITE}${BOLD} CANARY  ${RESET}  ${WHITE}gpt-4o-mini${RESET}  ${DIM}(candidate for evaluation)${RESET}"
echo ""

AB_BACKENDS_YAML="apiVersion: agentgateway.dev/v1alpha1
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
                  name: openai-secret"

show_yaml "$AB_BACKENDS_YAML"
echo ""
echo "$AB_BACKENDS_YAML" | kubectl apply -f-

echo ""
success "Stable and canary backends created."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 10 — Create HTTPRoute for /test with weighted traffic splitting
# ═══════════════════════════════════════════════════════════════════════════
header "STEP 10 of 12" "Create HTTPRoute for /test (80/20 Split)" "$CYAN"
show_progress 10

desc "Uses Gateway API weighted backendRefs to split traffic."
echo ""

echo -e "                                                      ${RESET}"
echo -e "    ${WHITE}/test${RESET}  ${ARROW}  ${GREEN}████████████████████████████████${RESET}  ${WHITE}80%%${RESET}  ${DIM}stable (gpt-4o)${RESET}      ${RESET}"
echo -e "           ${ARROW}  ${ORANGE}████████${RESET}                          ${WHITE}20%%${RESET}  ${DIM}canary (gpt-4o-mini)${RESET} ${RESET}"
echo -e "                                                      ${RESET}"
echo ""

AB_ROUTE_YAML="apiVersion: gateway.networking.k8s.io/v1
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
          weight: 20"

show_yaml "$AB_ROUTE_YAML"
echo ""
echo "$AB_ROUTE_YAML" | kubectl apply -f-

echo ""
success "A/B test route created (80/20 split)."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 11 — Verify all resources
# ═══════════════════════════════════════════════════════════════════════════
header "STEP 11 of 12" "Verify All Resources" "$GREEN"
show_progress 11

desc "Checking that everything was created correctly..."
echo ""

echo -e "  ${BG_PURPLE}${WHITE}${BOLD} Gateways ${RESET}"
show_cmd "kubectl get gateway -n ${NAMESPACE}"
echo ""
kubectl get gateway -n "${NAMESPACE}"
echo ""

echo -e "  ${BG_CYAN}${WHITE}${BOLD} HTTPRoutes ${RESET}"
show_cmd "kubectl get httproute -n ${NAMESPACE}"
echo ""
kubectl get httproute -n "${NAMESPACE}"
echo ""

echo -e "  ${BG_GREEN}${WHITE}${BOLD} AgentgatewayBackends ${RESET}"
show_cmd "kubectl get agentgatewaybackend -n ${NAMESPACE}"
echo ""
kubectl get agentgatewaybackend -n "${NAMESPACE}"
echo ""

echo -e "  ${BG_ORANGE}${WHITE}${BOLD} Secrets ${RESET}"
show_cmd "kubectl get secret openai-secret anthropic-secret -n ${NAMESPACE}"
echo ""
kubectl get secret openai-secret anthropic-secret -n "${NAMESPACE}"

echo ""
success "All resources verified."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 12 — Port-forward and test
# ═══════════════════════════════════════════════════════════════════════════
header "STEP 12 of 12" "Test the Endpoints" "$ORANGE"
show_progress 12

echo -e "  ${WHITE}${BOLD}Starting port-forward...${RESET}"
echo ""
show_cmd "kubectl port-forward -n ${NAMESPACE} svc/agentgateway-proxy 8080:80 &"
echo ""

kubectl port-forward -n "${NAMESPACE}" svc/agentgateway-proxy 8080:80 &
PF_PID=$!
sleep 3

# ── Test 1 ──
echo ""
echo -e "  ${BG_PURPLE}${WHITE}${BOLD} TEST 1: Multi-Provider Load Balancing (/chat) ${RESET}"
echo ""
show_cmd "curl -s \"http://localhost:8080/chat\" \\"
echo -e "    ${WHITE}-H \"Content-Type: application/json\" \\${RESET}"
echo -e "    ${WHITE}-d '{\"messages\": [{\"role\": \"user\", \"content\": \"Say hello\"}]}' | jq -r '.model'${RESET}"
echo ""
echo -e "  ${DIM}Sending 5 requests — expect responses from both providers...${RESET}"
echo ""

for i in 1 2 3 4 5; do
  MODEL=$(curl -s "http://localhost:8080/chat" \
    -H "Content-Type: application/json" \
    -d '{"messages": [{"role": "user", "content": "Say hello in one sentence."}]}' \
    | jq -r '.model // "unknown"')
  if [[ "$MODEL" == *"claude"* ]]; then
    COLOR="$ORANGE"
    LABEL="Anthropic"
  else
    COLOR="$GREEN"
    LABEL="OpenAI   "
  fi
  echo -e "  ${ROCKET} Request ${WHITE}${BOLD}${i}${RESET}  ${ARROW}  ${COLOR}${BOLD}${MODEL}${RESET}  ${DIM}(${LABEL})${RESET}"
done

echo ""
pause

# ── Test 2 ──
echo -e "  ${BG_CYAN}${WHITE}${BOLD} TEST 2: A/B Traffic Splitting (/test) ${RESET}"
echo ""
show_cmd "curl -s \"http://localhost:8080/test\" \\"
echo -e "    ${WHITE}-H \"Content-Type: application/json\" \\${RESET}"
echo -e "    ${WHITE}-d '{\"messages\": [{\"role\": \"user\", \"content\": \"Say hello\"}]}' | jq -r '.model'${RESET}"
echo ""
echo -e "  ${DIM}Sending 10 requests — expect ~80%% gpt-4o / ~20%% gpt-4o-mini...${RESET}"
echo ""

STABLE_COUNT=0
CANARY_COUNT=0
for i in 1 2 3 4 5 6 7 8 9 10; do
  MODEL=$(curl -s "http://localhost:8080/test" \
    -H "Content-Type: application/json" \
    -d '{"messages": [{"role": "user", "content": "Say hello in one sentence."}]}' \
    | jq -r '.model // "unknown"')
  if [[ "$MODEL" == *"gpt-4o-mini"* ]]; then
    COLOR="$ORANGE"
    LABEL="CANARY"
    ((CANARY_COUNT++)) || true
  else
    COLOR="$GREEN"
    LABEL="STABLE"
    ((STABLE_COUNT++)) || true
  fi
  printf -v NUM "%2d" "$i"
  echo -e "  ${ROCKET} Request ${WHITE}${BOLD}${NUM}${RESET}  ${ARROW}  ${COLOR}${BOLD}${MODEL}${RESET}  ${DIM}(${LABEL})${RESET}"
done

# Results bar chart
echo ""
echo -e "  ${WHITE}${BOLD}── Results ──${RESET}"
echo ""

STABLE_BAR=""
for ((j=0; j<STABLE_COUNT; j++)); do STABLE_BAR+="█"; done
CANARY_BAR=""
for ((j=0; j<CANARY_COUNT; j++)); do CANARY_BAR+="█"; done

printf "  ${GREEN}${BOLD}  Stable  ${RESET} ${GREEN}%-10s${RESET}  ${WHITE}${BOLD}%d/10${RESET}  ${DIM}(expected ~8)${RESET}\n" "$STABLE_BAR" "$STABLE_COUNT"
printf "  ${ORANGE}${BOLD}  Canary  ${RESET} ${ORANGE}%-10s${RESET}  ${WHITE}${BOLD}%d/10${RESET}  ${DIM}(expected ~2)${RESET}\n" "$CANARY_BAR" "$CANARY_COUNT"

echo ""

# Stop port-forward
kill $PF_PID 2>/dev/null || true
wait $PF_PID 2>/dev/null || true
success "Port-forward stopped."

# ═══════════════════════════════════════════════════════════════════════════
#  SUMMARY — Show all commands executed
# ═══════════════════════════════════════════════════════════════════════════

pause

header "SUMMARY" "All Commands Executed" "$PURPLE"

echo -e "  ${PURPLE}${BOLD}# Step 1: Create kind cluster${RESET}"
echo -e "  ${YELLOW}\$ ${WHITE}kind create cluster --name agw-series${RESET}"
echo ""
echo -e "  ${CYAN}${BOLD}# Step 2: Install Gateway API CRDs${RESET}"
echo -e "  ${YELLOW}\$ ${WHITE}kubectl apply --server-side --force-conflicts \\${RESET}"
echo -e "    ${WHITE}-f https://...gateway-api/.../v1.5.0/standard-install.yaml${RESET}"
echo ""
echo -e "  ${GREEN}${BOLD}# Step 3a: Install agentgateway CRDs${RESET}"
echo -e "  ${YELLOW}\$ ${WHITE}helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \\${RESET}"
echo -e "    ${WHITE}--create-namespace --namespace agentgateway-system --version v1.0.1${RESET}"
echo ""
echo -e "  ${GREEN}${BOLD}# Step 3b: Install agentgateway control plane${RESET}"
echo -e "  ${YELLOW}\$ ${WHITE}helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \\${RESET}"
echo -e "    ${WHITE}--namespace agentgateway-system --version v1.0.1 --wait${RESET}"
echo ""
echo -e "  ${ORANGE}${BOLD}# Step 4: Verify pods${RESET}"
echo -e "  ${YELLOW}\$ ${WHITE}kubectl get pods -n agentgateway-system${RESET}"
echo ""
echo -e "  ${PURPLE}${BOLD}# Step 5: Create Gateway${RESET}"
echo -e "  ${YELLOW}\$ ${WHITE}kubectl apply -f gateway.yaml${RESET}"
echo ""
echo -e "  ${CYAN}${BOLD}# Step 6: Create secrets${RESET}"
echo -e "  ${YELLOW}\$ ${WHITE}kubectl apply -f secrets.yaml${RESET}"
echo ""
echo -e "  ${GREEN}${BOLD}# Step 7: Create load balanced backend${RESET}"
echo -e "  ${YELLOW}\$ ${WHITE}kubectl apply -f loadbalanced-backend.yaml${RESET}"
echo ""
echo -e "  ${PURPLE}${BOLD}# Step 8: Create HTTPRoute /chat${RESET}"
echo -e "  ${YELLOW}\$ ${WHITE}kubectl apply -f loadbalanced-route.yaml${RESET}"
echo ""
echo -e "  ${ORANGE}${BOLD}# Step 9: Create A/B backends${RESET}"
echo -e "  ${YELLOW}\$ ${WHITE}kubectl apply -f ab-backends.yaml${RESET}"
echo ""
echo -e "  ${CYAN}${BOLD}# Step 10: Create weighted HTTPRoute /test${RESET}"
echo -e "  ${YELLOW}\$ ${WHITE}kubectl apply -f ab-test-route.yaml${RESET}"
echo ""
echo -e "  ${GREEN}${BOLD}# Step 11: Verify resources${RESET}"
echo -e "  ${YELLOW}\$ ${WHITE}kubectl get gateway,httproute,agentgatewaybackend -n agentgateway-system${RESET}"
echo ""
echo -e "  ${ORANGE}${BOLD}# Step 12: Test${RESET}"
echo -e "  ${YELLOW}\$ ${WHITE}kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:80 &${RESET}"
echo -e "  ${YELLOW}\$ ${WHITE}curl -s http://localhost:8080/chat -H 'Content-Type: application/json' \\${RESET}"
echo -e "    ${WHITE}-d '{\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}' | jq -r '.model'${RESET}"
echo -e "  ${YELLOW}\$ ${WHITE}curl -s http://localhost:8080/test ... | jq -r '.model'${RESET}"
echo ""
echo -e "  ${RED}${BOLD}# Cleanup${RESET}"
echo -e "  ${YELLOW}\$ ${WHITE}./cleanup.sh${RESET}"

echo ""
show_progress 12
echo ""

header "DONE" "Demo complete!" "$PURPLE"

echo -e "  ${GREEN}●${RESET} ${WHITE}/chat${RESET}  ${GRAY}P2C load balanced (OpenAI + Anthropic)${RESET}"
echo -e "  ${ORANGE}●${RESET} ${WHITE}/test${RESET}  ${GRAY}A/B split (80% gpt-4o / 20% gpt-4o-mini)${RESET}"
echo ""
echo -e "  ${GRAY}To clean up:${RESET}  ${CYAN}./cleanup.sh${RESET}"
echo ""
