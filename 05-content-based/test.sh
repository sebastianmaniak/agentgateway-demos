#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# test.sh — Interactive test suite for AgentGateway Content-Based Routing
#
# Split-screen layout: REQUEST on the left, RESPONSE on the right.
# Each test: show request → ENTER → send & show response → ENTER
#
# Validates:
#   1. GPT model routes to OpenAI backend (200)
#   2. Claude model routes to Anthropic backend (200)
#
# Requires: port-forward running on localhost:8080
#   kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:80
##############################################################################

GATEWAY_URL="${GATEWAY_URL:-localhost:8080}"
CLUSTER_NAME="agw-series"
CLUSTER_CONTEXT="kind-${CLUSTER_NAME}"
NAMESPACE="agentgateway-system"

# ---------------------------------------------------------------------------
# Colors & Symbols
# ---------------------------------------------------------------------------
BOLD=$'\033[1m'
DIM=$'\033[2m'
ITALIC=$'\033[3m'
RESET=$'\033[0m'

PURPLE=$'\033[38;2;100;30;160m'
CYAN=$'\033[38;2;0;120;180m'
GREEN=$'\033[38;2;0;130;80m'
ORANGE=$'\033[38;2;180;90;20m'
RED=$'\033[38;2;190;40;40m'
YELLOW=$'\033[38;2;140;110;0m'
BLUE=$'\033[38;2;40;80;180m'
WHITE=$'\033[38;2;30;30;40m'
GRAY=$'\033[38;2;120;120;135m'

CHECK="${GREEN}✓${RESET}"
CROSS="${RED}✗${RESET}"
ARROW="${CYAN}→${RESET}"
BULLET="${PURPLE}●${RESET}"
DIAMOND="${ORANGE}◆${RESET}"
ROCKET="${PURPLE}▸${RESET}"

# ---------------------------------------------------------------------------
# Layout helpers
# ---------------------------------------------------------------------------

put() {
  tput cup "$1" "$2"
  printf '%b' "$3"
}

gateway_is_reachable() {
  local http_code=""

  http_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 "http://${GATEWAY_URL}/" 2>/dev/null || true)
  [[ -n "${http_code}" && "${http_code}" != "000" ]]
}

can_start_default_port_forward() {
  [[ "${GATEWAY_URL}" == "localhost:8080" || "${GATEWAY_URL}" == "127.0.0.1:8080" ]]
}

wait_for_gateway_reachable() {
  local attempts="${1:-10}"

  for _ in $(seq 1 "${attempts}"); do
    if gateway_is_reachable; then
      return 0
    fi
    sleep 1
  done

  return 1
}

json_field_or_empty() {
  local body="$1"
  local filter="$2"

  jq -er "${filter} // empty" <<<"${body}" 2>/dev/null || true
}

model_matches() {
  local model="$1"
  local pattern="$2"

  [[ -n "${model}" && "${model}" =~ ${pattern} ]]
}

response_error_message() {
  local body="$1"

  jq -er '.error.message // empty' <<<"${body}" 2>/dev/null || true
}

# Counters
PASS=0
FAIL=0
TOTAL_TESTS=2

# Store results for final dashboard
declare -a TEST_LABELS=()
declare -a TEST_STATUSES=()
declare -a TEST_RESULTS=()

# ---------------------------------------------------------------------------
# draw_test: renders one test in split-screen
#   $1 = test index (0-1)
#   $2 = phase: "req" (show request, wait) or "resp" (show response, wait)
# ---------------------------------------------------------------------------
# Test metadata arrays
TEST_HEADERS=("TEST 1 of 2" "TEST 2 of 2")
TEST_TITLES=(
  "GPT Model → OpenAI"
  "Claude Model → Anthropic"
)
TEST_USERS=("GPT-5.4-mini request" "Claude Sonnet request")
TEST_KEYS=("model: gpt-5.4-mini" "model: claude-sonnet-4-5-20250929")
TEST_EXPECT=("200 OK (OpenAI)" "200 OK (Anthropic)")
TEST_EXPECT_COLOR=("$GREEN" "$GREEN")
TEST_HEADER_COLOR=("$GREEN" "$CYAN")

# Request details (set before draw_test)
REQ_METHOD=""
REQ_URL=""
REQ_HEADERS=()
REQ_BODY=""

# Response details (set before draw_test in "resp" phase)
RESP_STATUS=""
RESP_BODY=""
RESP_MODEL=""
RESP_CONTENT=""
RESP_TOKENS=""
RESP_RESULT=""
RESP_MESSAGE=""

draw_test() {
  local idx=$1
  local phase=$2

  clear

  local cols rows mid left_w right_col right_w
  cols=$(tput cols)
  rows=$(tput lines)
  mid=$((cols / 2))
  left_w=$((mid - 4))
  right_col=$((mid + 2))
  right_w=$((cols - right_col - 3))

  # Vertical separator
  for ((r=0; r<rows; r++)); do
    put $r $mid "${DIM}│${RESET}"
  done

  # === LEFT PANEL — REQUEST ===
  local row=1

  # Test header
  put $row 3 "${TEST_HEADER_COLOR[$idx]}${BOLD}${TEST_HEADERS[$idx]}${RESET}"
  ((row++))
  put $row 3 "${WHITE}${BOLD}${TEST_TITLES[$idx]}${RESET}"
  ((row += 2))

  # Progress bar
  local prog=$idx
  [[ "$phase" == "resp" ]] && prog=$((idx + 1))
  local filled=$(( prog * 30 / TOTAL_TESTS ))
  local empty=$((30 - filled))
  local pct=$(( prog * 100 / TOTAL_TESTS ))
  local bar="${PURPLE}"
  [[ $filled -gt 0 ]] && bar+=$(printf '█%.0s' $(seq 1 $filled))
  bar+="${GRAY}"
  [[ $empty -gt 0 ]] && bar+=$(printf '░%.0s' $(seq 1 $empty))
  bar+=" ${WHITE}${BOLD}${pct}%${RESET}"
  put $row 3 "$bar"
  ((row += 2))

  # Test info
  put $row 3 "${BULLET} ${WHITE}Request:${RESET} ${TEST_USERS[$idx]}"
  ((row++))
  put $row 3 "${BULLET} ${WHITE}Model:${RESET}   ${DIM}${TEST_KEYS[$idx]}${RESET}"
  ((row++))
  put $row 3 "${BULLET} ${WHITE}Expect:${RESET}  ${TEST_EXPECT_COLOR[$idx]}${TEST_EXPECT[$idx]}${RESET}"
  ((row += 2))

  # Separator
  put $row 3 "${DIM}$(printf '─%.0s' $(seq 1 $left_w))${RESET}"
  ((row += 2))

  # REQUEST box
  put $row 3 "${PURPLE}${BOLD}REQUEST${RESET}"
  ((row++))
  local box_w=$((left_w))
  put $row 3 "${DIM}┌$(printf '─%.0s' $(seq 1 $((box_w - 2))))┐${RESET}"
  ((row++))

  # Method + URL
  put $row 3 "${DIM}│${RESET}  ${CYAN}${BOLD}${REQ_METHOD}${RESET} ${WHITE}${REQ_URL}${RESET}"
  put $row $((3 + box_w - 1)) "${DIM}│${RESET}"
  ((row++))

  # Headers
  for h in "${REQ_HEADERS[@]}"; do
    put $row 3 "${DIM}│${RESET}  ${GRAY}${h}${RESET}"
    put $row $((3 + box_w - 1)) "${DIM}│${RESET}"
    ((row++))
  done

  # Body
  if [[ -n "$REQ_BODY" ]]; then
    put $row 3 "${DIM}│${RESET}"
    put $row $((3 + box_w - 1)) "${DIM}│${RESET}"
    ((row++))
    put $row 3 "${DIM}│${RESET}  ${ORANGE}Body:${RESET}"
    put $row $((3 + box_w - 1)) "${DIM}│${RESET}"
    ((row++))
    while IFS= read -r jline; do
      local trimmed="${jline:0:$((box_w - 6))}"
      put $row 3 "${DIM}│${RESET}    ${trimmed}"
      put $row $((3 + box_w - 1)) "${DIM}│${RESET}"
      ((row++))
    done <<< "$(echo "$REQ_BODY" | jq '.' 2>/dev/null || echo "$REQ_BODY")"
  fi

  put $row 3 "${DIM}└$(printf '─%.0s' $(seq 1 $((box_w - 2))))┘${RESET}"
  ((row += 2))

  # Checklist of completed tests
  if [[ $idx -gt 0 || "$phase" == "resp" ]]; then
    put $row 3 "${DIM}Results so far:${RESET}"
    ((row++))
    local show_up_to=$idx
    [[ "$phase" == "resp" ]] && show_up_to=$((idx + 1))
    for ((t=0; t<show_up_to && t<${#TEST_RESULTS[@]}; t++)); do
      local res_icon="${CHECK}"
      local res_label="${GREEN}PASS${RESET}"
      if [[ "${TEST_RESULTS[$t]}" == "blocked" ]]; then
        res_icon="${DIAMOND}"
        res_label="${ORANGE}BLOCKED${RESET}"
      elif [[ "${TEST_RESULTS[$t]}" == "false" ]]; then
        res_icon="${CROSS}"
        res_label="${RED}FAIL${RESET}"
      fi
      put $row 3 "  ${res_icon} ${res_label}  ${DIM}${TEST_LABELS[$t]}${RESET}"
      ((row++))
    done
  fi

  # === RIGHT PANEL — RESPONSE ===
  local rrow=1

  if [[ "$phase" == "req" ]]; then
    # Response not yet received
    put $rrow $right_col "${DIM}${BOLD}RESPONSE${RESET}"
    ((rrow += 2))
    put $rrow $right_col "${DIM}┌$(printf '─%.0s' $(seq 1 $((right_w - 2))))┐${RESET}"
    ((rrow++))

    # Centered "waiting" message
    local wait_msg="Waiting for request..."
    local pad=$(( (right_w - 2 - ${#wait_msg}) / 2 ))
    (( pad < 0 )) && pad=0
    put $rrow $right_col "${DIM}│${RESET}"
    put $rrow $((right_col + right_w - 1)) "${DIM}│${RESET}"
    ((rrow++))
    put $rrow $right_col "${DIM}│${RESET}$(printf ' %.0s' $(seq 1 $pad))${GRAY}${ITALIC}${wait_msg}${RESET}"
    put $rrow $((right_col + right_w - 1)) "${DIM}│${RESET}"
    ((rrow++))
    put $rrow $right_col "${DIM}│${RESET}"
    put $rrow $((right_col + right_w - 1)) "${DIM}│${RESET}"
    ((rrow++))

    put $rrow $right_col "${DIM}└$(printf '─%.0s' $(seq 1 $((right_w - 2))))┘${RESET}"
    ((rrow += 3))

    put $rrow $right_col "${DIM}${ITALIC}Press ENTER to send request...${RESET}"
  else
    # Show response
    local status_color="$GREEN"
    [[ "$RESP_STATUS" -ge 400 ]] 2>/dev/null && status_color="$RED"

    put $rrow $right_col "${GREEN}${BOLD}RESPONSE${RESET}"
    ((rrow += 2))
    put $rrow $right_col "${DIM}┌$(printf '─%.0s' $(seq 1 $((right_w - 2))))┐${RESET}"
    ((rrow++))

    # Status line
    put $rrow $right_col "${DIM}│${RESET}  ${WHITE}Status:${RESET} ${status_color}${BOLD}HTTP ${RESP_STATUS}${RESET}"
    put $rrow $((right_col + right_w - 1)) "${DIM}│${RESET}"
    ((rrow++))

    put $rrow $right_col "${DIM}│${RESET}"
    put $rrow $((right_col + right_w - 1)) "${DIM}│${RESET}"
    ((rrow++))

    if [[ -n "$RESP_MODEL" ]]; then
      put $rrow $right_col "${DIM}│${RESET}  ${WHITE}Model:${RESET} ${CYAN}${RESP_MODEL}${RESET}"
      put $rrow $((right_col + right_w - 1)) "${DIM}│${RESET}"
      ((rrow++))
    fi

    if [[ -n "$RESP_TOKENS" ]]; then
      put $rrow $right_col "${DIM}│${RESET}  ${WHITE}Tokens:${RESET} ${ORANGE}${RESP_TOKENS}${RESET}"
      put $rrow $((right_col + right_w - 1)) "${DIM}│${RESET}"
      ((rrow++))
    fi

    if [[ -n "$RESP_CONTENT" ]]; then
      put $rrow $right_col "${DIM}│${RESET}"
      put $rrow $((right_col + right_w - 1)) "${DIM}│${RESET}"
      ((rrow++))
      put $rrow $right_col "${DIM}│${RESET}  ${WHITE}Content:${RESET}"
      put $rrow $((right_col + right_w - 1)) "${DIM}│${RESET}"
      ((rrow++))

      # Word-wrap the content to fit right panel
      local content_w=$((right_w - 8))
      local remaining="$RESP_CONTENT"
      while [[ ${#remaining} -gt 0 ]]; do
        local chunk="${remaining:0:$content_w}"
        remaining="${remaining:$content_w}"
        put $rrow $right_col "${DIM}│${RESET}    ${ITALIC}${chunk}${RESET}"
        put $rrow $((right_col + right_w - 1)) "${DIM}│${RESET}"
        ((rrow++))
        if (( rrow > rows - 10 )); then
          put $rrow $right_col "${DIM}│${RESET}    ${DIM}...${RESET}"
          put $rrow $((right_col + right_w - 1)) "${DIM}│${RESET}"
          ((rrow++))
          break
        fi
      done
    fi

    # Body (for error responses with no parsed content)
    if [[ -z "$RESP_CONTENT" && -n "$RESP_BODY" ]]; then
      put $rrow $right_col "${DIM}│${RESET}  ${WHITE}Body:${RESET}"
      put $rrow $((right_col + right_w - 1)) "${DIM}│${RESET}"
      ((rrow++))
      local bline_num=0
      while IFS= read -r bline; do
        local btrimmed="${bline:0:$((right_w - 6))}"
        put $rrow $right_col "${DIM}│${RESET}    ${btrimmed}"
        put $rrow $((right_col + right_w - 1)) "${DIM}│${RESET}"
        ((rrow++))
        ((bline_num += 1))
        (( bline_num >= 8 )) && break
      done <<< "$(echo "$RESP_BODY" | jq '.' 2>/dev/null || echo "$RESP_BODY")"
    fi

    put $rrow $right_col "${DIM}│${RESET}"
    put $rrow $((right_col + right_w - 1)) "${DIM}│${RESET}"
    ((rrow++))

    put $rrow $right_col "${DIM}└$(printf '─%.0s' $(seq 1 $((right_w - 2))))┘${RESET}"
    ((rrow += 2))

    # Result verdict
    if [[ "$RESP_RESULT" == "true" ]]; then
      put $rrow $right_col "${CHECK} ${GREEN}${BOLD}PASS${RESET}  ${WHITE}${RESP_MESSAGE}${RESET}"
    elif [[ "$RESP_RESULT" == "blocked" ]]; then
      put $rrow $right_col "${DIAMOND} ${ORANGE}${BOLD}BLOCKED${RESET}  ${WHITE}${RESP_MESSAGE}${RESET}"
    else
      put $rrow $right_col "${CROSS} ${RED}${BOLD}FAIL${RESET}  ${WHITE}${RESP_MESSAGE}${RESET}"
    fi
    ((rrow += 2))

    put $rrow $right_col "${DIM}${ITALIC}Press ENTER to continue...${RESET}"
  fi

  # Prompt at bottom
  put $((rows - 1)) 3 "${GRAY}Press ${WHITE}${BOLD}ENTER${RESET}${GRAY} to continue...${RESET}"

  read -r _
}

# ---------------------------------------------------------------------------
# Final results dashboard (split-screen)
# ---------------------------------------------------------------------------
draw_results() {
  clear

  local cols rows mid left_w right_col right_w
  cols=$(tput cols)
  rows=$(tput lines)
  mid=$((cols / 2))
  left_w=$((mid - 4))
  right_col=$((mid + 2))
  right_w=$((cols - right_col - 3))

  # Vertical separator
  for ((r=0; r<rows; r++)); do
    put $r $mid "${DIM}│${RESET}"
  done

  # === LEFT: Test results table ===
  local row=1

  put $row 3 "${PURPLE}${BOLD}TEST RESULTS${RESET}"
  ((row += 2))

  # Progress bar (full)
  local bar="${PURPLE}$(printf '█%.0s' $(seq 1 30)) ${WHITE}${BOLD}100%${RESET}"
  put $row 3 "$bar"
  ((row += 2))

  # Results table
  put $row 3 "${DIM}┌$(printf '─%.0s' $(seq 1 $((left_w - 2))))┐${RESET}"
  ((row++))

  for ((t=0; t<${#TEST_LABELS[@]}; t++)); do
    local icon label color
    if [[ "${TEST_RESULTS[$t]}" == "true" ]]; then
      icon="${CHECK}"
      label="PASS"
      color="${GREEN}"
    elif [[ "${TEST_RESULTS[$t]}" == "blocked" ]]; then
      icon="${DIAMOND}"
      label="BLOCKED"
      color="${ORANGE}"
    else
      icon="${CROSS}"
      label="FAIL"
      color="${RED}"
    fi

    put $row 3 "${DIM}│${RESET}  ${icon} ${color}${BOLD}${label}${RESET}  ${WHITE}${TEST_LABELS[$t]}${RESET}"
    put $row $((3 + left_w - 1)) "${DIM}│${RESET}"
    ((row++))

    # Separator between rows (except last)
    if (( t < ${#TEST_LABELS[@]} - 1 )); then
      put $row 3 "${DIM}├$(printf '─%.0s' $(seq 1 $((left_w - 2))))┤${RESET}"
      ((row++))
    fi
  done

  put $row 3 "${DIM}└$(printf '─%.0s' $(seq 1 $((left_w - 2))))┘${RESET}"
  ((row += 2))

  # Summary line
  put $row 3 "${CHECK} ${GREEN}${BOLD}${PASS} passed${RESET}  ${DIM}${FAIL} failed${RESET}"
  ((row += 2))

  if [[ $FAIL -eq 0 ]]; then
    put $row 3 "${GREEN}${BOLD}Content-based routing working as expected.${RESET}"
  else
    put $row 3 "${RED}${BOLD}Some tests failed — check configuration.${RESET}"
  fi

  # === RIGHT: Conclusion ===
  local rrow=1

  put $rrow $right_col "${PURPLE}${BOLD}CONCLUSION${RESET}"
  ((rrow += 2))

  # What we set up
  put $rrow $right_col "${WHITE}${BOLD}What We Set Up:${RESET}"
  ((rrow += 2))
  put $rrow $right_col "  ${GREEN}●${RESET} ${WHITE}AgentGateway${RESET} ${GRAY}on a local Kind cluster${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${GREEN}●${RESET} ${WHITE}Gateway listener${RESET} ${GRAY}on port 80 (HTTP)${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${GREEN}●${RESET} ${WHITE}OpenAI backend${RESET} ${GRAY}(gpt-5.4-mini)${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${GREEN}●${RESET} ${WHITE}Anthropic backend${RESET} ${GRAY}(claude-sonnet-4-5)${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${GREEN}●${RESET} ${WHITE}Transformation policy${RESET} ${GRAY}(body → header)${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${GREEN}●${RESET} ${WHITE}Content-based HTTPRoute${RESET} ${GRAY}(regex matching)${RESET}"
  ((rrow += 2))

  # What we tested
  put $rrow $right_col "${WHITE}${BOLD}What We Tested:${RESET}"
  ((rrow += 2))
  put $rrow $right_col "  ${CHECK} ${WHITE}GPT models route to OpenAI backend${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${CHECK} ${WHITE}Claude models route to Anthropic backend${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${CHECK} ${WHITE}One endpoint, multiple providers${RESET}"
  ((rrow += 2))

  # Key takeaway
  put $rrow $right_col "${CYAN}${BOLD}Key Takeaway:${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${GRAY}Content-based routing lets you expose a${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${GRAY}single unified endpoint while intelligently${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${GRAY}routing to different LLM providers based on${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${GRAY}the model field in the request body.${RESET}"
  ((rrow += 2))

  put $rrow $right_col "${WHITE}${BOLD}Next:${RESET}  ${CYAN}./cleanup.sh${RESET} ${GRAY}to tear down${RESET}"

  # Bottom prompt
  put $((rows - 1)) 3 "${GRAY}Press ${WHITE}${BOLD}ENTER${RESET}${GRAY} to continue...${RESET}"

  read -r _
}

# ---------------------------------------------------------------------------
# Outro — teleprompter script for video
# ---------------------------------------------------------------------------
draw_outro() {
  clear

  local cols rows
  cols=$(tput cols)
  rows=$(tput lines)

  # Center content horizontally
  local cw=60
  local lc=$(( (cols - cw) / 2 ))
  (( lc < 3 )) && lc=3

  local row=2

  # Title
  put $row $lc "${PURPLE}${BOLD}╔$(printf '═%.0s' $(seq 1 $((cw - 2))))╗${RESET}"
  ((row++))
  local title="   Thanks for Watching!"
  printf -v padded "%-$((cw - 2))s" "$title"
  put $row $lc "${PURPLE}${BOLD}║${RESET}${WHITE}${BOLD}${padded}${RESET}${PURPLE}${BOLD}║${RESET}"
  ((row++))
  put $row $lc "${PURPLE}${BOLD}╚$(printf '═%.0s' $(seq 1 $((cw - 2))))╝${RESET}"
  ((row += 2))

  # Recap
  put $row $lc "${WHITE}${BOLD}What we covered today:${RESET}"
  ((row += 2))
  put $row $lc "  ${GREEN}●${RESET} ${WHITE}Extracted model from request body${RESET} ${GRAY}via CEL${RESET}"
  ((row++))
  put $row $lc "  ${GREEN}●${RESET} ${WHITE}Routed GPT requests to OpenAI${RESET} ${GRAY}(regex: ^gpt-.*)${RESET}"
  ((row++))
  put $row $lc "  ${GREEN}●${RESET} ${WHITE}Routed Claude requests to Anthropic${RESET} ${GRAY}(regex: ^claude-.*)${RESET}"
  ((row++))
  put $row $lc "  ${GREEN}●${RESET} ${WHITE}One endpoint, multiple providers${RESET} ${GRAY}zero client changes${RESET}"
  ((row += 2))

  put $row $lc "${DIM}$(printf '─%.0s' $(seq 1 $cw))${RESET}"
  ((row += 2))

  # CTA
  put $row $lc "${WHITE}I hope you enjoyed this video!${RESET}"
  ((row += 2))
  put $row $lc "${WHITE}If you have any questions, ${BOLD}drop a comment${RESET}${WHITE} below.${RESET}"
  ((row++))
  put $row $lc "${WHITE}If there's something you'd like to see next,${RESET}"
  ((row++))
  put $row $lc "${WHITE}${BOLD}let me know${RESET}${WHITE} — I'm always open to ideas.${RESET}"
  ((row += 2))

  put $row $lc "${DIM}$(printf '─%.0s' $(seq 1 $cw))${RESET}"
  ((row += 2))

  put $row $lc "${ORANGE}${BOLD}Smash${RESET}${WHITE} that ${ORANGE}${BOLD}Like${RESET}${WHITE} button${RESET}"
  ((row++))
  put $row $lc "${RED}${BOLD}Hit${RESET}${WHITE} that ${RED}${BOLD}Subscribe${RESET}${WHITE} button${RESET}"
  ((row++))
  put $row $lc "${PURPLE}${BOLD}Star${RESET}${WHITE} the project on ${PURPLE}${BOLD}GitHub${RESET}"
  ((row += 2))

  put $row $lc "${DIM}$(printf '─%.0s' $(seq 1 $cw))${RESET}"
  ((row += 2))

  put $row $lc "${CYAN}${BOLD}github.com/agentgateway${RESET}"
  ((row++))
  put $row $lc "${GRAY}Give it a ★ — it really helps!${RESET}"
  ((row += 2))

  put $row $lc "${WHITE}See you in the next one. ${PURPLE}${BOLD}Peace!${RESET}"

  # Bottom prompt
  put $((rows - 1)) $lc "${GRAY}Press ${WHITE}${BOLD}ENTER${RESET}${GRAY} to exit.${RESET}"

  read -r _
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
       ║       Content-Based Routing — Test Suite              ║
       ║       agentgateway                                    ║
       ║                                                       ║
       ╚═══════════════════════════════════════════════════════╝
BANNER
echo -e "${RESET}"
echo -e "  ${GRAY}Interactive test suite for content-based routing${RESET}"
echo -e "  ${GRAY}Split-screen: REQUEST on the left, RESPONSE on the right${RESET}"
echo ""
echo -e "  ${GREEN}●${RESET} GPT → OpenAI backend            ${CYAN}●${RESET} Claude → Anthropic backend"
echo ""

echo ""
echo -e "  ${DIM}────────────────────────────────────────────────────────────────${RESET}"
echo -e -n "  ${GRAY}Press ${WHITE}${BOLD}ENTER${RESET}${GRAY} to begin...${RESET}"
read -r _
echo ""

# ---------------------------------------------------------------------------
# Preflight: check port-forward
# ---------------------------------------------------------------------------
echo ""
echo -e "  ${WHITE}${BOLD}Checking gateway...${RESET}"

PF_STARTED=false
if ! gateway_is_reachable; then
  if can_start_default_port_forward; then
    echo -e "  ${DIAMOND} ${ORANGE}Gateway not reachable — starting port-forward...${RESET}"
    echo ""
    echo -e "  ${YELLOW}\$ ${WHITE}kubectl --context ${CLUSTER_CONTEXT} port-forward -n ${NAMESPACE} svc/agentgateway-proxy 8080:80 &${RESET}"
    echo ""
    kubectl --context "${CLUSTER_CONTEXT}" port-forward -n "${NAMESPACE}" svc/agentgateway-proxy 8080:80 &
    PF_PID=$!
    PF_STARTED=true
    if ! wait_for_gateway_reachable 10; then
      echo -e "  ${CROSS} ${RED}Failed to reach the gateway after starting port-forward.${RESET}"
      kill $PF_PID 2>/dev/null || true
      wait $PF_PID 2>/dev/null || true
      exit 1
    fi
    echo -e "  ${CHECK} ${WHITE}Gateway reachable at ${GATEWAY_URL}${RESET}"
  else
    echo -e "  ${CROSS} ${RED}Gateway not reachable at ${GATEWAY_URL}.${RESET}"
    echo -e "  ${GRAY}Start your own port-forward with kubectl --context ${CLUSTER_CONTEXT} or set GATEWAY_URL.${RESET}"
    exit 1
  fi
else
  echo -e "  ${CHECK} ${WHITE}Gateway reachable at ${GATEWAY_URL}${RESET}"
fi

echo ""
echo -e "  ${DIM}────────────────────────────────────────────────────────────────${RESET}"
echo -e -n "  ${GRAY}Press ${WHITE}${BOLD}ENTER${RESET}${GRAY} to start tests...${RESET}"
read -r _

# ═══════════════════════════════════════════════════════════════════════════
#  TEST 1 — GPT Model → OpenAI Backend
# ═══════════════════════════════════════════════════════════════════════════
REQ_METHOD="POST"
REQ_URL="http://${GATEWAY_URL}/v1/chat/completions"
REQ_HEADERS=(
  "Content-Type: application/json"
)
REQ_BODY='{"model": "gpt-5.4-mini", "messages": [{"role": "user", "content": "Say hello in one sentence."}]}'

draw_test 0 "req"

GPT_RESPONSE=$(curl -s -w "\n%{http_code}" "http://${GATEWAY_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model": "gpt-5.4-mini", "messages": [{"role": "user", "content": "Say hello in one sentence."}]}')

GPT_STATUS=$(echo "$GPT_RESPONSE" | tail -1)
GPT_BODY=$(echo "$GPT_RESPONSE" | sed '$d')

RESP_STATUS="$GPT_STATUS"
RESP_BODY="$GPT_BODY"
RESP_MODEL=""
RESP_CONTENT=""
RESP_TOKENS=""

if [[ "$GPT_STATUS" == "200" ]]; then
  RESP_MODEL=$(json_field_or_empty "$GPT_BODY" '.model')
  RESP_CONTENT=$(json_field_or_empty "$GPT_BODY" '.choices[0].message.content')
  RESP_TOKENS=$(json_field_or_empty "$GPT_BODY" '.usage.total_tokens')

  if model_matches "$RESP_MODEL" '^gpt-'; then
    RESP_RESULT="true"
    RESP_MESSAGE="Routed to OpenAI — model: ${RESP_MODEL}"
    ((PASS += 1))
  else
    RESP_RESULT="false"
    RESP_MESSAGE="Expected gpt-* model, got ${RESP_MODEL:-missing model}"
    ((FAIL += 1))
  fi
else
  RESP_RESULT="false"
  RESP_MESSAGE="Expected 200, got ${GPT_STATUS}"
  ((FAIL += 1))
fi

TEST_LABELS+=("Test 1 — GPT-5.4-mini → OpenAI → HTTP ${GPT_STATUS}")
TEST_STATUSES+=("$GPT_STATUS")
TEST_RESULTS+=("$RESP_RESULT")

draw_test 0 "resp"

# ═══════════════════════════════════════════════════════════════════════════
#  TEST 2 — Claude Model → Anthropic Backend
# ═══════════════════════════════════════════════════════════════════════════
REQ_METHOD="POST"
REQ_URL="http://${GATEWAY_URL}/v1/chat/completions"
REQ_HEADERS=(
  "Content-Type: application/json"
)
REQ_BODY='{"model": "claude-sonnet-4-5-20250929", "messages": [{"role": "user", "content": "Say hello in one sentence."}]}'

draw_test 1 "req"

CLAUDE_RESPONSE=$(curl -s -w "\n%{http_code}" "http://${GATEWAY_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model": "claude-sonnet-4-5-20250929", "messages": [{"role": "user", "content": "Say hello in one sentence."}]}')

CLAUDE_STATUS=$(echo "$CLAUDE_RESPONSE" | tail -1)
CLAUDE_BODY=$(echo "$CLAUDE_RESPONSE" | sed '$d')

RESP_STATUS="$CLAUDE_STATUS"
RESP_BODY="$CLAUDE_BODY"
RESP_MODEL=""
RESP_CONTENT=""
RESP_TOKENS=""

if [[ "$CLAUDE_STATUS" == "200" ]]; then
  RESP_MODEL=$(json_field_or_empty "$CLAUDE_BODY" '.model')
  RESP_CONTENT=$(json_field_or_empty "$CLAUDE_BODY" '.choices[0].message.content')
  RESP_TOKENS=$(json_field_or_empty "$CLAUDE_BODY" '.usage.total_tokens')

  if model_matches "$RESP_MODEL" '^claude-'; then
    RESP_RESULT="true"
    RESP_MESSAGE="Routed to Anthropic — model: ${RESP_MODEL}"
    ((PASS += 1))
  else
    RESP_RESULT="false"
    RESP_MESSAGE="Expected claude-* model, got ${RESP_MODEL:-missing model}"
    ((FAIL += 1))
  fi
else
  RESP_RESULT="false"
  claude_error=""
  claude_error=$(response_error_message "$CLAUDE_BODY")
  if [[ "${CLAUDE_STATUS}" == "401" && "${claude_error}" == "invalid x-api-key" ]]; then
    RESP_MESSAGE="Anthropic rejected the configured API key (invalid x-api-key)"
  elif [[ -n "${claude_error}" ]]; then
    RESP_MESSAGE="Expected 200, got ${CLAUDE_STATUS} (${claude_error})"
  else
    RESP_MESSAGE="Expected 200, got ${CLAUDE_STATUS}"
  fi
  ((FAIL += 1))
fi

TEST_LABELS+=("Test 2 — Claude Sonnet → Anthropic → HTTP ${CLAUDE_STATUS}")
TEST_STATUSES+=("$CLAUDE_STATUS")
TEST_RESULTS+=("$RESP_RESULT")

draw_test 1 "resp"

# ═══════════════════════════════════════════════════════════════════════════
#  Final Results Dashboard
# ═══════════════════════════════════════════════════════════════════════════
draw_results

# ═══════════════════════════════════════════════════════════════════════════
#  Outro
# ═══════════════════════════════════════════════════════════════════════════
draw_outro

# Cleanup port-forward if we started it
if [[ "$PF_STARTED" == "true" ]]; then
  kill $PF_PID 2>/dev/null || true
  wait $PF_PID 2>/dev/null || true
fi

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
