#!/usr/bin/env bash
##############################################################################
# step-by-step.sh — Interactive walk-through of the agentgateway
#                    Content-Based Routing demo
#
# Pauses after each step so you can inspect state, explain to an audience,
# or troubleshoot before moving on. Press ENTER to continue to the next step.
# Every command is displayed before it runs so the audience can follow along.
#
# Prerequisites:
#   - kind, kubectl, helm, jq, curl installed
#   - OPENAI_API_KEY environment variable set
#   - ANTHROPIC_API_KEY environment variable set
##############################################################################
set -euo pipefail

CLUSTER_NAME="agw-series"
CLUSTER_CONTEXT="kind-${CLUSTER_NAME}"
NAMESPACE="agentgateway-system"
AGW_VERSION="v1.1.0"
GATEWAY_API_VERSION="v1.5.0"

# ---------------------------------------------------------------------------
# Colors & Symbols
# ---------------------------------------------------------------------------
BOLD=$'\033[1m'
DIM=$'\033[2m'
ITALIC=$'\033[3m'
RESET=$'\033[0m'

# Brand colors — tuned for light terminals
PURPLE=$'\033[38;2;100;30;160m'
CYAN=$'\033[38;2;0;120;180m'
GREEN=$'\033[38;2;0;130;80m'
ORANGE=$'\033[38;2;180;90;20m'
RED=$'\033[38;2;190;40;40m'
YELLOW=$'\033[38;2;140;110;0m'
BLUE=$'\033[38;2;40;80;180m'
WHITE=$'\033[38;2;30;30;40m'
GRAY=$'\033[38;2;120;120;135m'

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

# Print YAML with syntax highlighting
show_yaml() {
  local yaml="$1"
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
      -e "s/providers:/${C_GREEN}providers:${C_RESET}/g" \
      -e "s/groups:/${C_GREEN}groups:${C_RESET}/g" \
      -e "s/rules:/${C_GREEN}rules:${C_RESET}/g" \
      -e "s/listeners:/${C_GREEN}listeners:${C_RESET}/g" \
      -e "s/backendRefs:/${C_GREEN}backendRefs:${C_RESET}/g" \
      -e "s/parentRefs:/${C_GREEN}parentRefs:${C_RESET}/g" \
      -e "s/matches:/${C_GREEN}matches:${C_RESET}/g" \
      -e "s/targetRefs:/${C_GREEN}targetRefs:${C_RESET}/g" \
      -e "s/headers:/${C_GREEN}headers:${C_RESET}/g" \
      -e "s/policies:/${C_PURPLE}policies:${C_RESET}/g" \
      -e "s/secretRef:/${C_PURPLE}secretRef:${C_RESET}/g" \
      -e "s/stringData:/${C_PURPLE}stringData:${C_RESET}/g" \
      -e "s/traffic:/${C_PURPLE}traffic:${C_RESET}/g" \
      -e "s/transformation:/${C_ORANGE}transformation:${C_RESET}/g" \
      -e "s/phase:/${C_RED}phase:${C_RESET}/g" \
      -e "s/PreRouting/${C_RED}PreRouting${C_RESET}/g" \
      -e "s/RegularExpression/${C_ORANGE}RegularExpression${C_RESET}/g" \
      -e "s/value:/${C_ORANGE}value:${C_RESET}/g" \
      -e "s/type:/${C_CYAN}type:${C_RESET}/g" \
      -e "s/labels:/${C_PURPLE}labels:${C_RESET}/g" \
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
  local timeout="${3:-30s}"

  if ! k wait --for="condition=${condition}" "${resource}" -n "${NAMESPACE}" --timeout="${timeout}" 2>/dev/null; then
    echo ""
    warn "kubectl wait timed out — checking status directly..."
    local status
    status=$(k get "${resource}" -n "${NAMESPACE}" -o jsonpath="{.status}" 2>/dev/null || true)
    if echo "$status" | grep -q "\"reason\":\"Accepted\""; then
      success "${resource} is Accepted (confirmed via status check)."
      return 0
    fi
    # For HTTPRoute, conditions are nested under .status.parents[].conditions[]
    local parent_status
    parent_status=$(k get "${resource}" -n "${NAMESPACE}" \
      -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
    if [[ "$parent_status" == "True" ]]; then
      success "${resource} is Accepted (confirmed via parent status)."
      return 0
    fi
    warn "${resource} did not reach condition ${condition}."
    k describe "${resource}" -n "${NAMESPACE}" || true
    exit 1
  fi
}

# Progress bar for visual step tracking
TOTAL_STEPS=10
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
       ║       Content-Based Routing for LLMs                  ║
       ║       with agentgateway                               ║
       ║                                                       ║
       ╚═══════════════════════════════════════════════════════╝
BANNER
echo -e "${RESET}"
echo -e "  ${GRAY}Interactive step-by-step demo${RESET}"
echo -e "  ${GRAY}One endpoint, multiple LLM providers, routed by model field${RESET}"
echo ""
echo -e "  ${PURPLE}●${RESET} Body-field extraction (CEL)     ${CYAN}●${RESET} Gateway API native"
echo -e "  ${GREEN}●${RESET} Regex header matching            ${ORANGE}●${RESET} Multi-provider routing"
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
header "STEP 1 of 10" "Create the Kind Cluster" "$PURPLE"
show_progress 1

desc "Creates a local Kubernetes cluster for the demo."
echo ""

show_cmd "kind create cluster --name ${CLUSTER_NAME}"
echo ""

if cluster_exists; then
  warn "Cluster '${CLUSTER_NAME}' already exists — skipping creation."
else
  kind create cluster --name "${CLUSTER_NAME}"
fi

echo ""
info "All kubectl and helm commands in this demo target ${BOLD}${CLUSTER_CONTEXT}${RESET}."
success "Cluster '${CLUSTER_NAME}' is ready."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 2 — Install Gateway API CRDs
# ═══════════════════════════════════════════════════════════════════════════
header "STEP 2 of 10" "Install Gateway API CRDs" "$CYAN"
show_progress 2

desc "The Gateway API CRDs define resources like Gateway and HTTPRoute."
desc "agentgateway implements the Gateway API spec."
echo ""

show_cmd "kubectl apply --server-side --force-conflicts \\"
echo -e "    ${WHITE}-f https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml${RESET}"
echo ""

k apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

echo ""
success "Gateway API CRDs (${GATEWAY_API_VERSION}) installed."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 3a — Install agentgateway CRDs
# ═══════════════════════════════════════════════════════════════════════════
header "STEP 3a of 10" "Install agentgateway CRDs" "$GREEN"
show_progress 3

desc "Custom Resource Definitions for AgentgatewayBackend, AgentgatewayPolicy, etc."
echo ""

show_cmd "helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \\"
echo -e "    ${WHITE}--create-namespace --namespace ${NAMESPACE} \\${RESET}"
echo -e "    ${WHITE}--version ${AGW_VERSION} \\${RESET}"
echo -e "    ${WHITE}--set controller.image.pullPolicy=Always${RESET}"
echo ""

h upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --create-namespace --namespace "${NAMESPACE}" \
  --version "${AGW_VERSION}" \
  --set controller.image.pullPolicy=Always

echo ""
success "agentgateway CRDs (${AGW_VERSION}) installed."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 3b — Install agentgateway control plane
# ═══════════════════════════════════════════════════════════════════════════
header "STEP 3b of 10" "Install agentgateway Control Plane" "$GREEN"

desc "Deploys the controller and data plane proxy."
desc "Experimental features enabled for body-level transformations."
echo ""

show_cmd "helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \\"
echo -e "    ${WHITE}--namespace ${NAMESPACE} \\${RESET}"
echo -e "    ${WHITE}--version ${AGW_VERSION} \\${RESET}"
echo -e "    ${WHITE}--set controller.image.pullPolicy=Always \\${RESET}"
echo -e "    ${WHITE}--set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true${RESET}"
echo ""

h upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace "${NAMESPACE}" \
  --version "${AGW_VERSION}" \
  --set controller.image.pullPolicy=Always \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true \
  --wait

echo ""
success "agentgateway control plane deployed."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 4 — Wait for pods
# ═══════════════════════════════════════════════════════════════════════════
header "STEP 4 of 10" "Wait for Pods to be Ready" "$ORANGE"
show_progress 4

desc "Ensure all AgentGateway pods are running before we configure them."
echo ""

show_cmd "kubectl wait --for=condition=Ready pods --all -n ${NAMESPACE} --timeout=120s"
echo ""

k wait --for=condition=Ready pods --all -n "${NAMESPACE}" --timeout=120s

echo ""
show_cmd "kubectl get pods -n ${NAMESPACE}"
echo ""
k get pods -n "${NAMESPACE}"

echo ""
success "All pods ready."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 5 — Create Gateway listener
# ═══════════════════════════════════════════════════════════════════════════
header "STEP 5 of 10" "Create the Gateway Listener" "$PURPLE"
show_progress 5

desc "An HTTP listener on port 80 that accepts routes from all namespaces."
echo ""

GATEWAY_YAML='apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agentgateway-proxy
  namespace: '"${NAMESPACE}"'
spec:
  gatewayClassName: agentgateway
  listeners:
  - protocol: HTTP
    port: 80
    name: http
    allowedRoutes:
      namespaces:
        from: All'

show_yaml "$GATEWAY_YAML"
echo ""

k apply -f- <<EOF
${GATEWAY_YAML}
EOF

echo ""
show_cmd "kubectl wait --for=condition=Accepted gateway/agentgateway-proxy -n ${NAMESPACE} --timeout=120s"
echo ""
wait_for_condition "gateway/agentgateway-proxy" "Accepted"

echo ""
success "Gateway listener created on port 80."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 6 — Create provider secrets
# ═══════════════════════════════════════════════════════════════════════════
header "STEP 6 of 10" "Create Provider API Key Secrets" "$CYAN"
show_progress 6

desc "Each LLM provider needs its own API key stored as a Kubernetes secret."
desc "Both provider API keys are stored under the Authorization field."
echo ""

info "Creating ${BOLD}openai-secret${RESET} (Opaque — provider credential)"
info "Creating ${BOLD}anthropic-secret${RESET} (Opaque — provider credential)"
echo ""

SECRET_YAML_DISPLAY='apiVersion: v1
kind: Secret
metadata:
  name: openai-secret
  namespace: '"${NAMESPACE}"'
type: Opaque
stringData:
  Authorization: "${OPENAI_API_KEY}"
---
apiVersion: v1
kind: Secret
metadata:
  name: anthropic-secret
  namespace: '"${NAMESPACE}"'
type: Opaque
stringData:
  Authorization: "${ANTHROPIC_API_KEY}"'

show_yaml "$SECRET_YAML_DISPLAY"
echo ""

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

echo ""
show_cmd "kubectl get secrets -n ${NAMESPACE}"
echo ""
k get secrets -n "${NAMESPACE}"

echo ""
success "Provider secrets created."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 7 — Create OpenAI backend
# ═══════════════════════════════════════════════════════════════════════════
header "STEP 7 of 10" "Create OpenAI Backend (gpt-5.4-mini)" "$GREEN"
show_progress 7

desc "An AgentgatewayBackend that points to OpenAI's gpt-5.4-mini model."
desc "Authenticates outbound requests using the openai-secret."
echo ""

OPENAI_BACKEND_YAML='apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: openai-backend
  namespace: '"${NAMESPACE}"'
spec:
  ai:
    provider:
      openai:
        model: gpt-5.4-mini
  policies:
    auth:
      secretRef:
        name: openai-secret'

show_yaml "$OPENAI_BACKEND_YAML"
echo ""

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

echo ""
show_cmd "kubectl wait --for=condition=Accepted agentgatewaybackend/openai-backend -n ${NAMESPACE} --timeout=120s"
echo ""
wait_for_condition "agentgatewaybackend/openai-backend" "Accepted"

echo ""
success "OpenAI backend created (gpt-5.4-mini)."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 8 — Create Anthropic backend
# ═══════════════════════════════════════════════════════════════════════════
header "STEP 8 of 10" "Create Anthropic Backend (claude-sonnet-4-5)" "$BLUE"
show_progress 8

desc "An AgentgatewayBackend that points to Anthropic's Claude model."
desc "Authenticates outbound requests using the anthropic-secret."
echo ""

ANTHROPIC_BACKEND_YAML='apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: anthropic-backend
  namespace: '"${NAMESPACE}"'
spec:
  ai:
    provider:
      anthropic:
        model: claude-sonnet-4-5-20250929
  policies:
    auth:
      secretRef:
        name: anthropic-secret'

show_yaml "$ANTHROPIC_BACKEND_YAML"
echo ""

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

echo ""
show_cmd "kubectl wait --for=condition=Accepted agentgatewaybackend/anthropic-backend -n ${NAMESPACE} --timeout=120s"
echo ""
wait_for_condition "agentgatewaybackend/anthropic-backend" "Accepted"

echo ""
show_cmd "kubectl get agentgatewaybackends -n ${NAMESPACE}"
echo ""
k get agentgatewaybackends -n "${NAMESPACE}"

echo ""
success "Anthropic backend created (claude-sonnet-4-5-20250929)."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 9 — Create transformation policy (the magic)
# ═══════════════════════════════════════════════════════════════════════════
header "STEP 9 of 10" "Create Model Extraction Policy" "$RED"
show_progress 9

desc "This is the key to content-based routing!"
desc "A CEL expression extracts the 'model' field from the JSON body"
desc "and sets it as the 'x-model' header — before route matching."
echo ""

info "${BOLD}Phase: PreRouting${RESET} — runs before HTTPRoute matching"
info "${BOLD}CEL:${RESET} json(request.body).model → x-model header"
echo ""

TRANSFORM_YAML='apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: extract-model
  namespace: '"${NAMESPACE}"'
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
          value: '"'"'json(request.body).model'"'"

show_yaml "$TRANSFORM_YAML"
echo ""

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

echo ""
show_cmd "kubectl get agentgatewaypolicies -n ${NAMESPACE}"
echo ""
k get agentgatewaypolicies -n "${NAMESPACE}"

echo ""
success "Model extraction policy created."
echo ""
info "Request flow: Body → CEL extracts model → x-model header → route match"

pause

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 10 — Create content-based HTTPRoute
# ═══════════════════════════════════════════════════════════════════════════
header "STEP 10 of 10" "Create Content-Based HTTPRoute" "$PURPLE"
show_progress 10

desc "A single path (/v1/chat/completions) with two rules:"
desc "  Rule 1: x-model header matches ^gpt-.* → OpenAI backend"
desc "  Rule 2: x-model header matches ^claude-.* → Anthropic backend"
echo ""

ROUTE_YAML='apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: content-routing
  namespace: '"${NAMESPACE}"'
spec:
  parentRefs:
    - name: agentgateway-proxy
      namespace: '"${NAMESPACE}"'
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
          namespace: '"${NAMESPACE}"'
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
          namespace: '"${NAMESPACE}"'
          group: agentgateway.dev
          kind: AgentgatewayBackend'

show_yaml "$ROUTE_YAML"
echo ""

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

echo ""
show_cmd "kubectl get httproutes -n ${NAMESPACE}"
echo ""
k get httproutes -n "${NAMESPACE}"

echo ""
success "Content-based HTTPRoute created."

pause

# ═══════════════════════════════════════════════════════════════════════════
#  DEPLOYMENT COMPLETE — Summary
# ═══════════════════════════════════════════════════════════════════════════
header "COMPLETE" "Deployment Summary" "$GREEN"
show_progress 10

echo -e "  ${WHITE}${BOLD}Resources created:${RESET}"
echo ""
echo -e "  ${CHECK} Kind cluster ${DIM}(${CLUSTER_NAME})${RESET}"
echo -e "  ${CHECK} Gateway API CRDs ${DIM}(${GATEWAY_API_VERSION})${RESET}"
echo -e "  ${CHECK} AgentGateway ${DIM}(${AGW_VERSION})${RESET}"
echo -e "  ${CHECK} Gateway listener ${DIM}(port 80)${RESET}"
echo -e "  ${CHECK} Provider secrets ${DIM}(openai-secret, anthropic-secret)${RESET}"
echo -e "  ${CHECK} OpenAI backend ${DIM}(gpt-5.4-mini)${RESET}"
echo -e "  ${CHECK} Anthropic backend ${DIM}(claude-sonnet-4-5-20250929)${RESET}"
echo -e "  ${CHECK} Transformation policy ${DIM}(extract-model → x-model header)${RESET}"
echo -e "  ${CHECK} Content-based route ${DIM}(^gpt-.* → OpenAI, ^claude-.* → Anthropic)${RESET}"
echo ""

echo -e "  ${WHITE}${BOLD}How content-based routing works:${RESET}"
echo ""
echo -e "  ${BULLET} Client sends POST /v1/chat/completions with ${ORANGE}\"model\": \"gpt-5.4-mini\"${RESET}"
echo -e "  ${ARROW} AgentgatewayPolicy extracts model → ${CYAN}x-model: gpt-5.4-mini${RESET}"
echo -e "  ${ARROW} HTTPRoute matches ${ORANGE}^gpt-.*${RESET} → routes to ${GREEN}openai-backend${RESET}"
echo -e "  ${ARROW} Backend authenticates with OpenAI and returns response"
echo ""
echo -e "  ${BULLET} Client sends POST /v1/chat/completions with ${ORANGE}\"model\": \"claude-sonnet-4-5-20250929\"${RESET}"
echo -e "  ${ARROW} AgentgatewayPolicy extracts model → ${CYAN}x-model: claude-sonnet-4-5-20250929${RESET}"
echo -e "  ${ARROW} HTTPRoute matches ${ORANGE}^claude-.*${RESET} → routes to ${BLUE}anthropic-backend${RESET}"
echo -e "  ${ARROW} Backend authenticates with Anthropic and returns response"
echo ""

echo -e "  ${WHITE}${BOLD}Next steps:${RESET}"
echo ""
echo -e "  ${ROCKET} Port-forward:  ${YELLOW}kubectl --context ${CLUSTER_CONTEXT} port-forward -n ${NAMESPACE} svc/agentgateway-proxy 8080:80${RESET}"
echo -e "  ${ROCKET} Run tests:     ${YELLOW}./test.sh${RESET}"
echo -e "  ${ROCKET} Clean up:      ${YELLOW}./cleanup.sh${RESET}"

pause

echo ""
echo -e "${GREEN}${BOLD}Done!${RESET} The gateway is ready for content-based routing."
echo ""
