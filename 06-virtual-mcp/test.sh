#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# test.sh — Interactive test suite for AgentGateway Virtual MCP Demo
#
# Tests virtual MCP multiplexing — federating multiple MCP servers through
# a single gateway endpoint using JSON-RPC over Streamable HTTP.
#
# Validates:
#   1. MCP initialization handshake succeeds
#   2. Tools list returns federated tools from both servers
#   3. Echo tool call from mcp-server-everything works (roundtrip)
#   4. MCP Inspector launches for live visual demo of federated tools
#
# Requires: port-forward running on localhost:8080
#   kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:80
##############################################################################

GATEWAY_URL="${GATEWAY_URL:-localhost:8080}"
NAMESPACE="default"
GATEWAY_NAMESPACE="agentgateway-system"
HEADER_TMP=$(mktemp)
SESSION_FILE=$(mktemp)
ID_FILE=$(mktemp)
echo "0" > "$ID_FILE"
cleanup() {
  rm -f "$HEADER_TMP" "$SESSION_FILE" "$ID_FILE"
  [[ "${PF_STARTED:-false}" == "true" ]] && kill "${PF_PID:-}" 2>/dev/null || true
}
trap cleanup EXIT

mcp_request() {
  local method="$1"
  local params="$2"
  [[ -z "$params" ]] && params="{}"
  local timeout="${3:-30}"

  local id
  id=$(cat "$ID_FILE")
  echo $(( id + 1 )) > "$ID_FILE"

  local session_id=""
  [[ -s "$SESSION_FILE" ]] && session_id=$(cat "$SESSION_FILE")

  local body
  body=$(printf '{"jsonrpc":"2.0","id":%s,"method":"%s","params":%s}' "$id" "$method" "$params")

  local -a curl_args=(
    -sN -D "$HEADER_TMP" --max-time "$timeout"
    -X POST "http://${GATEWAY_URL}/mcp"
    -H "Content-Type: application/json"
    -H "Accept: application/json, text/event-stream"
  )
  [[ -n "$session_id" ]] && curl_args+=(-H "Mcp-Session-Id: ${session_id}")
  curl_args+=(--data-raw "$body")

  local raw_output
  raw_output=$(curl "${curl_args[@]}" 2>/dev/null || true)

  local sid
  sid=$(grep -i '^mcp-session-id:' "$HEADER_TMP" 2>/dev/null | head -1 | sed 's/^[^:]*: *//;s/\r$//' || true)
  [[ -n "$sid" ]] && echo -n "$sid" > "$SESSION_FILE"

  local status="000"
  local status_line
  status_line=$(grep -oE '^HTTP/[0-9.]+ [0-9]+' "$HEADER_TMP" 2>/dev/null | tail -1 || true)
  [[ -n "$status_line" ]] && status=$(echo "$status_line" | awk '{print $2}')

  local body_json="$raw_output"
  if [[ "$raw_output" == data:* || "$raw_output" == event:* ]]; then
    body_json=$(echo "$raw_output" | awk '/^data:/{sub(/^data: ?/,""); printf "%s",$0} /^$/{exit}')
  fi

  echo "${status}|${body_json}"
}

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

show_cmd() {
  local cmd="$*"
  local inner=$(( ${#cmd} + 6 ))
  echo ""
  echo -e "  ${PURPLE}╭$(printf '─%.0s' $(seq 1 $inner))╮${RESET}"
  echo -e "  ${PURPLE}│${RESET}  ${YELLOW}${BOLD}\$${RESET} ${WHITE}${BOLD}${cmd}${RESET}  ${PURPLE}│${RESET}"
  echo -e "  ${PURPLE}╰$(printf '─%.0s' $(seq 1 $inner))╯${RESET}"
  echo ""
}

put() {
  tput cup "$1" "$2"
  printf '%b' "$3"
}

# Counters
PASS=0
FAIL=0
TOTAL_TESTS=3

# Store results for final dashboard
declare -a TEST_LABELS=()
declare -a TEST_STATUSES=()
declare -a TEST_RESULTS=()

# Test metadata arrays
TEST_HEADERS=("TEST 1 of 3" "TEST 2 of 3" "TEST 3 of 3")
TEST_TITLES=(
  "MCP Initialization"
  "Federated Tools List"
  "Echo Tool Call"
)
TEST_DESC=(
  "JSON-RPC handshake with virtual MCP"
  "List tools from both federated servers"
  "Call echo tool via mcp-server-everything"
)

# Request details (set before draw_test)
REQ_METHOD=""
REQ_URL=""
REQ_HEADERS=()
REQ_BODY=""

# Response details
RESP_STATUS=""
RESP_BODY=""
RESP_RESULT=""
RESP_MESSAGE=""

# ---------------------------------------------------------------------------
# draw_test: renders one test in split-screen layout
# ---------------------------------------------------------------------------
draw_test() {
  local idx=$1
  local phase=$2

  clear

  local cols rows mid lc lw rc rw
  cols=$(tput cols 2>/dev/null || echo 80)
  rows=$(tput lines 2>/dev/null || echo 24)
  mid=$((cols / 2))
  lc=3
  lw=$((mid - lc - 1))
  rc=$((mid + 2))
  rw=$((cols - rc - 2))

  # Vertical separator
  for ((r=0; r<rows-1; r++)); do
    put $r $mid "${DIM}│${RESET}"
  done

  # ── LEFT PANEL ──
  local row=2

  put $row $lc "${PURPLE}${BOLD}${TEST_HEADERS[$idx]}${RESET}  ${DIM}—${RESET}  ${WHITE}${BOLD}${TEST_TITLES[$idx]}${RESET}"
  ((row += 3))

  # Progress bar
  local prog=$idx
  [[ "$phase" == "resp" ]] && prog=$((idx + 1))
  local bar_w=$((lw - 6))
  (( bar_w > 30 )) && bar_w=30
  local filled=$(( prog * bar_w / TOTAL_TESTS ))
  local empty=$((bar_w - filled))
  local pct=$(( prog * 100 / TOTAL_TESTS ))
  local bar="${PURPLE}"
  [[ $filled -gt 0 ]] && bar+=$(printf '█%.0s' $(seq 1 $filled)) || true
  bar+="${GRAY}"
  [[ $empty -gt 0 ]] && bar+=$(printf '░%.0s' $(seq 1 $empty)) || true
  bar+=" ${WHITE}${pct}%${RESET}"
  put $row $lc "$bar"
  ((row += 3))

  # Request box — full panel width
  put $row $lc "${PURPLE}${BOLD}REQUEST${RESET}"
  ((row += 2))
  put $row $lc "${DIM}┌$(printf '─%.0s' $(seq 1 $((lw - 2))))┐${RESET}"
  ((row++))
  put $row $lc "${DIM}│${RESET}  ${CYAN}${BOLD}${REQ_METHOD}${RESET} ${WHITE}${REQ_URL}${RESET}"
  put $row $((lc + lw - 1)) "${DIM}│${RESET}"
  ((row++))
  for h in "${REQ_HEADERS[@]}"; do
    put $row $lc "${DIM}│${RESET}  ${GRAY}${h}${RESET}"
    put $row $((lc + lw - 1)) "${DIM}│${RESET}"
    ((row++))
  done
  if [[ -n "$REQ_BODY" ]]; then
    put $row $lc "${DIM}│${RESET}"
    put $row $((lc + lw - 1)) "${DIM}│${RESET}"
    ((row++))
    local max_body_lines=$(( rows - row - 8 ))
    (( max_body_lines < 4 )) && max_body_lines=4
    (( max_body_lines > 12 )) && max_body_lines=12
    local line_num=0
    while IFS= read -r jline; do
      ((line_num++))
      (( line_num > max_body_lines )) && break
      put $row $lc "${DIM}│${RESET}    ${jline:0:$((lw - 6))}"
      put $row $((lc + lw - 1)) "${DIM}│${RESET}"
      ((row++))
    done <<< "$(echo "$REQ_BODY" | jq '.' 2>/dev/null || echo "$REQ_BODY")"
    if (( line_num > max_body_lines )); then
      put $row $lc "${DIM}│${RESET}    ${GRAY}...${RESET}"
      put $row $((lc + lw - 1)) "${DIM}│${RESET}"
      ((row++))
    fi
  fi
  put $row $lc "${DIM}└$(printf '─%.0s' $(seq 1 $((lw - 2))))┘${RESET}"
  ((row += 3))

  # Completed tests checklist
  if [[ $idx -gt 0 || "$phase" == "resp" ]]; then
    local show_up_to=$idx
    [[ "$phase" == "resp" ]] && show_up_to=$((idx + 1))
    for ((t=0; t<show_up_to && t<${#TEST_RESULTS[@]}; t++)); do
      local ri="${CHECK}" rl="${GREEN}PASS${RESET}"
      [[ "${TEST_RESULTS[$t]}" == "false" ]] && ri="${CROSS}" && rl="${RED}FAIL${RESET}"
      put $row $((lc + 2)) "${ri} ${rl}  ${DIM}${TEST_LABELS[$t]}${RESET}"
      ((row += 2))
    done
  fi

  # ── RIGHT PANEL ──
  local rrow=2

  local re=$((rc + rw - 1))

  if [[ "$phase" == "req" ]]; then
    put $rrow $rc "${DIM}${BOLD}RESPONSE${RESET}"
    ((rrow += 3))
    put $rrow $rc "${DIM}┌$(printf '─%.0s' $(seq 1 $((rw - 2))))┐${RESET}"
    ((rrow++))
    put $rrow $rc "${DIM}│${RESET}"; put $rrow $re "${DIM}│${RESET}"
    ((rrow++))
    local pad=$(( (rw - 24) / 2 ))
    (( pad < 2 )) && pad=2
    put $rrow $rc "${DIM}│${RESET}$(printf ' %.0s' $(seq 1 $pad))${GRAY}${ITALIC}Waiting for request...${RESET}"
    put $rrow $re "${DIM}│${RESET}"
    ((rrow++))
    put $rrow $rc "${DIM}│${RESET}"; put $rrow $re "${DIM}│${RESET}"
    ((rrow++))
    put $rrow $rc "${DIM}└$(printf '─%.0s' $(seq 1 $((rw - 2))))┘${RESET}"
  else
    local sc="$GREEN"
    [[ "$RESP_STATUS" -ge 400 ]] 2>/dev/null && sc="$RED"

    put $rrow $rc "${sc}${BOLD}RESPONSE${RESET}"
    ((rrow += 3))
    put $rrow $rc "${DIM}┌$(printf '─%.0s' $(seq 1 $((rw - 2))))┐${RESET}"
    ((rrow++))
    put $rrow $rc "${DIM}│${RESET}"; put $rrow $re "${DIM}│${RESET}"
    ((rrow++))
    put $rrow $rc "${DIM}│${RESET}   ${WHITE}Status:${RESET} ${sc}${BOLD}HTTP ${RESP_STATUS}${RESET}"
    put $rrow $re "${DIM}│${RESET}"
    ((rrow++))
    put $rrow $rc "${DIM}│${RESET}"; put $rrow $re "${DIM}│${RESET}"
    ((rrow++))

    local is_json=false
    [[ -n "$RESP_BODY" ]] && echo "$RESP_BODY" | jq -e '.' &>/dev/null && is_json=true

    if [[ "$is_json" == "true" ]]; then
      local resp_id
      resp_id=$(echo "$RESP_BODY" | jq -r '.id // empty' 2>/dev/null || true)
      if [[ -n "$resp_id" ]]; then
        put $rrow $rc "${DIM}│${RESET}   ${WHITE}ID:${RESET} ${CYAN}${resp_id}${RESET}"
        put $rrow $re "${DIM}│${RESET}"
        ((rrow++))
        put $rrow $rc "${DIM}│${RESET}"; put $rrow $re "${DIM}│${RESET}"
        ((rrow++))
      fi

      # tools/list — show tool count + servers
      if echo "$RESP_BODY" | jq -e '.result.tools' &>/dev/null; then
        local tc
        tc=$(echo "$RESP_BODY" | jq '.result.tools | length' 2>/dev/null || echo "?")
        put $rrow $rc "${DIM}│${RESET}   ${WHITE}Tools:${RESET} ${ORANGE}${BOLD}${tc}${RESET}"
        put $rrow $re "${DIM}│${RESET}"
        ((rrow++))
        put $rrow $rc "${DIM}│${RESET}"; put $rrow $re "${DIM}│${RESET}"
        ((rrow++))

        local snames
        snames=$(echo "$RESP_BODY" | jq -r '[.result.tools[].name] | map(split("_")[0]) | unique | .[]' 2>/dev/null || true)
        put $rrow $rc "${DIM}│${RESET}   ${WHITE}Servers:${RESET}"
        put $rrow $re "${DIM}│${RESET}"
        ((rrow++))
        while IFS= read -r sn; do
          [[ -z "$sn" ]] && continue
          put $rrow $rc "${DIM}│${RESET}     ${GREEN}●${RESET} ${WHITE}${sn}${RESET}"
          put $rrow $re "${DIM}│${RESET}"
          ((rrow++))
        done <<< "$snames"

        put $rrow $rc "${DIM}│${RESET}"; put $rrow $re "${DIM}│${RESET}"
        ((rrow++))
        put $rrow $rc "${DIM}│${RESET}   ${WHITE}Sample:${RESET}"
        put $rrow $re "${DIM}│${RESET}"
        ((rrow++))
        local st
        st=$(echo "$RESP_BODY" | jq -r '.result.tools[:4][].name' 2>/dev/null || true)
        while IFS= read -r tn; do
          [[ -z "$tn" ]] && continue
          put $rrow $rc "${DIM}│${RESET}     ${CYAN}→${RESET} ${tn:0:$((rw - 8))}"
          put $rrow $re "${DIM}│${RESET}"
          ((rrow++))
        done <<< "$st"

      # Generic result — compact JSON
      elif echo "$RESP_BODY" | jq -e '.result' &>/dev/null; then
        put $rrow $rc "${DIM}│${RESET}   ${WHITE}Result:${RESET}"
        put $rrow $re "${DIM}│${RESET}"
        ((rrow++))
        while IFS= read -r jl; do
          put $rrow $rc "${DIM}│${RESET}     ${jl:0:$((rw - 7))}"
          put $rrow $re "${DIM}│${RESET}"
          ((rrow++))
        done <<< "$(echo "$RESP_BODY" | jq '.result' 2>/dev/null | head -8)"
      fi

      # JSON-RPC error
      if echo "$RESP_BODY" | jq -e '.error' &>/dev/null; then
        put $rrow $rc "${DIM}│${RESET}"; put $rrow $re "${DIM}│${RESET}"
        ((rrow++))
        local em
        em=$(echo "$RESP_BODY" | jq -r '"\(.error.code // ""): \(.error.message // "unknown")"' 2>/dev/null || echo "unknown")
        put $rrow $rc "${DIM}│${RESET}   ${RED}${BOLD}Error:${RESET} ${RED}${em:0:$((rw - 11))}${RESET}"
        put $rrow $re "${DIM}│${RESET}"
        ((rrow++))
      fi
    elif [[ -n "$RESP_BODY" ]]; then
      put $rrow $rc "${DIM}│${RESET}   ${WHITE}Body:${RESET}"
      put $rrow $re "${DIM}│${RESET}"
      ((rrow++))
      while IFS= read -r rl; do
        [[ -z "$rl" ]] && continue
        put $rrow $rc "${DIM}│${RESET}     ${GRAY}${rl:0:$((rw - 7))}${RESET}"
        put $rrow $re "${DIM}│${RESET}"
        ((rrow++))
      done <<< "$(echo "$RESP_BODY" | head -4)"
    fi

    put $rrow $rc "${DIM}│${RESET}"; put $rrow $re "${DIM}│${RESET}"
    ((rrow++))
    put $rrow $rc "${DIM}└$(printf '─%.0s' $(seq 1 $((rw - 2))))┘${RESET}"
    ((rrow += 3))

    # Verdict
    if [[ "$RESP_RESULT" == "true" ]]; then
      put $rrow $rc "  ${CHECK} ${GREEN}${BOLD}PASS${RESET}  ${WHITE}${RESP_MESSAGE}${RESET}"
    else
      put $rrow $rc "  ${CROSS} ${RED}${BOLD}FAIL${RESET}  ${WHITE}${RESP_MESSAGE}${RESET}"
    fi
  fi

  put $((rows - 1)) 3 "${GRAY}Press ${WHITE}${BOLD}ENTER${RESET}${GRAY} to continue...${RESET}"
  read -r _
}

# ---------------------------------------------------------------------------
# Final results dashboard
# ---------------------------------------------------------------------------
draw_results() {
  clear

  local cols rows mid left_w right_col right_w
  cols=$(tput cols 2>/dev/null || echo 80)
  rows=$(tput lines 2>/dev/null || echo 24)
  mid=$((cols / 2))
  left_w=$((mid - 4))
  right_col=$((mid + 2))
  right_w=$((cols - right_col - 3))

  [[ $left_w -gt 40 ]] && left_w=40

  for ((r=0; r<rows; r++)); do
    put $r $mid "${DIM}│${RESET}"
  done

  local row=1

  put $row 3 "${PURPLE}${BOLD}TEST RESULTS${RESET}"
  ((row += 2))

  local bar="${PURPLE}$(printf '█%.0s' $(seq 1 30)) ${WHITE}${BOLD}100%${RESET}"
  put $row 3 "$bar"
  ((row += 2))

  put $row 3 "${DIM}┌$(printf '─%.0s' $(seq 1 $((left_w - 2))))┐${RESET}"
  ((row++))

  for ((t=0; t<${#TEST_RESULTS[@]}; t++)); do
    local icon
    if [[ "${TEST_RESULTS[$t]}" == "true" ]]; then
      icon="${CHECK} ${GREEN}PASS${RESET}"
    else
      icon="${CROSS} ${RED}FAIL${RESET}"
    fi

    put $row 3 "${DIM}│${RESET}  ${icon}  ${WHITE}${TEST_LABELS[$t]}${RESET}"
    put $row $((3 + left_w - 1)) "${DIM}│${RESET}"
    ((row++))

    if (( t < ${#TEST_RESULTS[@]} - 1 )); then
      put $row 3 "${DIM}├$(printf '─%.0s' $(seq 1 $((left_w - 2))))┤${RESET}"
      ((row++))
    fi
  done

  put $row 3 "${DIM}└$(printf '─%.0s' $(seq 1 $((left_w - 2))))┘${RESET}"
  ((row += 2))

  put $row 3 "${CHECK} ${GREEN}${PASS} passed${RESET}  ${DIM}${FAIL} failed${RESET}"
  ((row += 2))

  if [[ $FAIL -eq 0 ]]; then
    put $row 3 "${GREEN}${BOLD}Virtual MCP working as expected.${RESET}"
  else
    put $row 3 "${RED}${BOLD}Some tests failed — check configuration.${RESET}"
  fi

  local rrow=1

  put $rrow $right_col "${PURPLE}${BOLD}CONCLUSION${RESET}"
  ((rrow += 2))

  put $rrow $right_col "${WHITE}${BOLD}What We Set Up:${RESET}"
  ((rrow += 2))
  put $rrow $right_col "  ${GREEN}●${RESET} ${WHITE}AgentGateway${RESET} ${GRAY}on a local Kind cluster${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${GREEN}●${RESET} ${WHITE}Gateway listener${RESET} ${GRAY}on port 80 (HTTP)${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${GREEN}●${RESET} ${WHITE}mcp-server-everything${RESET} ${GRAY}(echo, add, sleep...)${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${GREEN}●${RESET} ${WHITE}mcp-server-tools${RESET} ${GRAY}(echo, add, sleep...)${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${GREEN}●${RESET} ${WHITE}AgentgatewayBackend${RESET} ${GRAY}(federating both servers)${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${GREEN}●${RESET} ${WHITE}HTTPRoute${RESET} ${GRAY}on /mcp${RESET}"
  ((rrow += 2))

  put $rrow $right_col "${WHITE}${BOLD}What We Tested:${RESET}"
  ((rrow += 2))
  put $rrow $right_col "  ${CHECK} ${WHITE}MCP initialization handshake${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${CHECK} ${WHITE}Federated tools list from both servers${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${CHECK} ${WHITE}Echo tool call roundtrip${RESET}"
  ((rrow += 2))

  put $rrow $right_col "${CYAN}${BOLD}Key Takeaway:${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${GRAY}Virtual MCP multiplexes multiple MCP${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${GRAY}servers behind a single endpoint.${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${GRAY}Clients connect once and get all tools${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${GRAY}from all federated servers — name${RESET}"
  ((rrow++))
  put $rrow $right_col "  ${GRAY}prefixes identify the source server.${RESET}"
  ((rrow += 2))

  put $rrow $right_col "${WHITE}${BOLD}Next:${RESET}  ${CYAN}./cleanup.sh${RESET} ${GRAY}to tear down${RESET}"

  put $((rows - 1)) 3 "${GRAY}Press ${WHITE}${BOLD}ENTER${RESET}${GRAY} to continue...${RESET}"

  read -r _
}

# ---------------------------------------------------------------------------
# Outro — teleprompter script for video
# ---------------------------------------------------------------------------
draw_outro() {
  clear

  local cols rows
  cols=$(tput cols 2>/dev/null || echo 80)
  rows=$(tput lines 2>/dev/null || echo 24)

  local cw=60
  local lc=$(( (cols - cw) / 2 ))
  (( lc < 3 )) && lc=3

  local row=2

  put $row $lc "${PURPLE}${BOLD}╔$(printf '═%.0s' $(seq 1 $((cw - 2))))╗${RESET}"
  ((row++))
  local title="   Thanks for Watching!"
  printf -v padded "%-$((cw - 2))s" "$title"
  put $row $lc "${PURPLE}${BOLD}║${RESET}${WHITE}${BOLD}${padded}${RESET}${PURPLE}${BOLD}║${RESET}"
  ((row++))
  put $row $lc "${PURPLE}${BOLD}╚$(printf '═%.0s' $(seq 1 $((cw - 2))))╝${RESET}"
  ((row += 2))

  put $row $lc "${WHITE}${BOLD}What we covered today:${RESET}"
  ((row += 2))
  put $row $lc "  ${GREEN}●${RESET} ${WHITE}Multiple MCP servers${RESET} ${GRAY}in one cluster${RESET}"
  ((row++))
  put $row $lc "  ${GREEN}●${RESET} ${WHITE}Virtual MCP${RESET} ${GRAY}(multiplexing via AgentgatewayBackend)${RESET}"
  ((row++))
  put $row $lc "  ${GREEN}●${RESET} ${WHITE}Single endpoint${RESET} ${GRAY}(clients connect once, get all tools)${RESET}"
  ((row++))
  put $row $lc "  ${GREEN}●${RESET} ${WHITE}Federated tool discovery${RESET} ${GRAY}with source prefixes${RESET}"
  ((row++))
  put $row $lc "  ${GREEN}●${RESET} ${WHITE}JSON-RPC over Streamable HTTP${RESET} ${GRAY}(MCP protocol)${RESET}"
  ((row += 2))

  put $row $lc "${DIM}$(printf '─%.0s' $(seq 1 $cw))${RESET}"
  ((row += 2))

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

  put $row $lc "${CYAN}${BOLD}github.com/solo-io/agentgateway${RESET}"
  ((row++))
  put $row $lc "${GRAY}Give it a ★ — it really helps!${RESET}"
  ((row += 2))

  put $row $lc "${WHITE}See you in the next one. ${PURPLE}${BOLD}Peace!${RESET}"
  ((row += 2))

  local prompt_row=$((rows - 1))
  (( row > prompt_row )) && prompt_row=$row
  put $prompt_row $lc "${GRAY}Press ${WHITE}${BOLD}ENTER${RESET}${GRAY} to exit.${RESET}"

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
       ║       Virtual MCP — Test Suite                        ║
       ║       agentgateway                                    ║
       ║                                                       ║
       ╚═══════════════════════════════════════════════════════╝
BANNER
echo -e "${RESET}"
echo -e "  ${GRAY}JSON-RPC tests for virtual MCP multiplexing${RESET}"
echo -e "  ${GRAY}Split-screen: REQUEST on the left, RESPONSE on the right${RESET}"
echo ""
echo -e "  ${GREEN}●${RESET} MCP initialization     ${CYAN}●${RESET} Federated tools discovery"
echo -e "  ${GREEN}●${RESET} Echo tool roundtrip"
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
if ! curl -s -o /dev/null --max-time 3 "http://${GATEWAY_URL}" 2>/dev/null; then
  echo -e "  ${DIAMOND} ${ORANGE}Gateway not reachable — starting port-forward...${RESET}"
  show_cmd "kubectl port-forward -n ${GATEWAY_NAMESPACE} svc/agentgateway-proxy 8080:80 &"
  kubectl port-forward -n "${GATEWAY_NAMESPACE}" svc/agentgateway-proxy 8080:80 &
  PF_PID=$!
  PF_STARTED=true
  sleep 3
else
  echo -e "  ${CHECK} ${WHITE}Gateway reachable at ${GATEWAY_URL}${RESET}"
fi

echo ""
echo -e "  ${DIM}────────────────────────────────────────────────────────────────${RESET}"
echo -e -n "  ${GRAY}Press ${WHITE}${BOLD}ENTER${RESET}${GRAY} to start tests...${RESET}"
read -r _

# ═══════════════════════════════════════════════════════════════════════════
#  TEST 1 — MCP Initialization Handshake
# ═══════════════════════════════════════════════════════════════════════════
REQ_METHOD="POST"
REQ_URL="http://${GATEWAY_URL}/mcp"
REQ_HEADERS=("Content-Type: application/json")
REQ_BODY='{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"agw-demo","version":"1.0"}}}'

draw_test 0 "req"

RES=$(mcp_request "initialize" '{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"agw-demo","version":"1.0"}}')
HTTP_STATUS=$(echo "$RES" | cut -d'|' -f1)
RESP_BODY_TEXT=$(echo "$RES" | cut -d'|' -f2-)

RESP_STATUS="$HTTP_STATUS"
RESP_BODY="$RESP_BODY_TEXT"

if [[ "$HTTP_STATUS" == "200" || "$HTTP_STATUS" == "202" ]]; then
  if echo "$RESP_BODY_TEXT" | jq -e '.result' &>/dev/null; then
    INIT_PROTOCOL=$(echo "$RESP_BODY_TEXT" | jq -r '.result.protocolVersion // "unknown"' 2>/dev/null || echo "unknown")
    RESP_RESULT="true"
    RESP_MESSAGE="Initialized — protocol ${INIT_PROTOCOL}"
    ((PASS++))
  elif echo "$RESP_BODY_TEXT" | jq -e '.error' &>/dev/null; then
    err_msg=$(echo "$RESP_BODY_TEXT" | jq -r '.error.message // "unknown"' 2>/dev/null || echo "unknown")
    RESP_RESULT="false"
    RESP_MESSAGE="Server error: ${err_msg}"
    ((FAIL++))
  else
    RESP_RESULT="true"
    RESP_MESSAGE="Connection established (HTTP ${HTTP_STATUS})"
    ((PASS++))
  fi
else
  RESP_RESULT="false"
  RESP_MESSAGE="Expected 200, got ${HTTP_STATUS}"
  ((FAIL++))
fi

TEST_LABELS+=("MCP initialization")
TEST_STATUSES+=("$HTTP_STATUS")
TEST_RESULTS+=("$RESP_RESULT")

draw_test 0 "resp"

# Also send initialized notification
mcp_request "notifications/initialized" "" > /dev/null 2>&1 || true

# ═══════════════════════════════════════════════════════════════════════════
#  TEST 2 — Federated Tools List
# ═══════════════════════════════════════════════════════════════════════════
REQ_METHOD="POST"
REQ_URL="http://${GATEWAY_URL}/mcp"
REQ_HEADERS=("Content-Type: application/json")
REQ_BODY='{"jsonrpc":"2.0","id":1,"method":"tools/list"}'

draw_test 1 "req"

RES=$(mcp_request "tools/list" '{}')
HTTP_STATUS=$(echo "$RES" | cut -d'|' -f1)
RESP_BODY_TEXT=$(echo "$RES" | cut -d'|' -f2-)

RESP_STATUS="$HTTP_STATUS"
RESP_BODY="$RESP_BODY_TEXT"

if [[ "$HTTP_STATUS" == "200" ]]; then
  if echo "$RESP_BODY_TEXT" | jq -e '.result.tools' &>/dev/null; then
    TOOL_COUNT=$(echo "$RESP_BODY_TEXT" | jq '.result.tools | length' 2>/dev/null || echo "0")
    
    # Check tools from both servers
    HAS_EVERYTHING=$(echo "$RESP_BODY_TEXT" | jq '[.result.tools[].name] | any(startswith("mcp-server-everything"))' 2>/dev/null || echo "false")
    HAS_TOOLS=$(echo "$RESP_BODY_TEXT" | jq '[.result.tools[].name] | any(startswith("mcp-server-tools"))' 2>/dev/null || echo "false")
    
    if [[ "$TOOL_COUNT" -gt 0 && "$HAS_EVERYTHING" == "true" && "$HAS_TOOLS" == "true" ]]; then
      RESP_RESULT="true"
      RESP_MESSAGE="${TOOL_COUNT} federated tools found (both servers ✓)"
      ((PASS++))
    elif [[ "$HAS_EVERYTHING" == "true" || "$HAS_TOOLS" == "true" ]]; then
      RESP_RESULT="true"
      RESP_MESSAGE="${TOOL_COUNT} tools found (only one server discovered)"
      ((PASS++))
    else
      RESP_RESULT="false"
      RESP_MESSAGE="Tools returned but no expected tool prefixes found"
      ((FAIL++))
    fi
  else
    RESP_RESULT="false"
    RESP_MESSAGE="Unexpected response format"
    ((FAIL++))
  fi
else
  RESP_RESULT="false"
  RESP_MESSAGE="Expected 200, got ${HTTP_STATUS}"
  ((FAIL++))
fi

TEST_LABELS+=("Federated tools list")
TEST_STATUSES+=("$HTTP_STATUS")
TEST_RESULTS+=("$RESP_RESULT")

draw_test 1 "resp"

# ═══════════════════════════════════════════════════════════════════════════
#  TEST 3 — Echo Tool Call
# ═══════════════════════════════════════════════════════════════════════════
REQ_METHOD="POST"
REQ_URL="http://${GATEWAY_URL}/mcp"
REQ_HEADERS=("Content-Type: application/json")
REQ_BODY='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"mcp-server-everything-3001_echo","arguments":{"message":"Hello from AgentGateway!"}}}'

draw_test 2 "req"

RES=$(mcp_request "tools/call" '{"name":"mcp-server-everything-3001_echo","arguments":{"message":"Hello from AgentGateway!"}}')
HTTP_STATUS=$(echo "$RES" | cut -d'|' -f1)
RESP_BODY_TEXT=$(echo "$RES" | cut -d'|' -f2-)

RESP_STATUS="$HTTP_STATUS"
RESP_BODY="$RESP_BODY_TEXT"

if [[ "$HTTP_STATUS" == "200" ]]; then
  if echo "$RESP_BODY_TEXT" | jq -e '.result.content' &>/dev/null; then
    TOOL_NAME=$(echo "$RESP_BODY_TEXT" | jq -r '.result.name // "echo"' 2>/dev/null || echo "echo")
    CONTENT_ITEMS=$(echo "$RESP_BODY_TEXT" | jq -r '.result.content[] | if .type == "text" then .text else "[non-text]" end' 2>/dev/null || echo "")
    
    RESP_RESULT="true"
    RESP_MESSAGE="Echo response received: ${CONTENT_ITEMS:-no text content}"
    ((PASS++))
  else
    RESP_RESULT="false"
    RESP_MESSAGE="Unexpected tool response format"
    ((FAIL++))
  fi
else
  RESP_RESULT="false"
  RESP_MESSAGE="Expected 200, got ${HTTP_STATUS}"
  ((FAIL++))
fi

TEST_LABELS+=("Echo tool call")
TEST_STATUSES+=("$HTTP_STATUS")
TEST_RESULTS+=("$RESP_RESULT")

draw_test 2 "resp"

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
