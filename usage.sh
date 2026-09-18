#!/usr/bin/env bash

HERDR="${HERDR_BIN_PATH:-herdr}"
if ! command -v jq >/dev/null; then exit 1; fi

CYAN='\033[1;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
MAGENTA='\033[1;35m'
WHITE='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

MARGIN="    "
SUBMARGIN="      "
SUBSUBMARGIN="        "

format_bars() {
    awk '{
      if ($0 !~ /█/) {
        match($0, /[0-9]+%/)
        if (RSTART > 0) {
          pct_str = substr($0, RSTART, RLENGTH)
          pct = pct_str + 0
          width = 20
          filled = int((pct * width) / 100)
          empty = width - filled
          
          c_bar = "\033[1;32m["
          for(i=0; i<filled; i++) c_bar = c_bar "█"
          c_bar = c_bar "\033[2m"
          for(i=0; i<empty; i++) c_bar = c_bar "░"
          c_bar = c_bar "\033[1;32m]\033[0m"
          
          replacement = c_bar " \033[1;36m" pct_str "\033[0m"
          sub(/[0-9]+%/, replacement, $0)
        }
      }
      print $0
    }'
}

JSON_DATA=$("$HERDR" agent list 2>/dev/null)
if [ -z "$JSON_DATA" ] || ! echo "$JSON_DATA" | jq -e '.result.agents' >/dev/null 2>&1; then
    echo -e "${YELLOW}Error: Unable to fetch valid agent data from Herdr.${RESET}"
    exit 1
fi

clear
echo ""
echo -e "${MARGIN}${CYAN}╭─────────────────────────────────────────────────────────────────────────────╮${RESET}"
echo -e "${MARGIN}${CYAN}│                       ${BOLD}Herdr Agent Usage Dashboard${RESET}${CYAN}                           │${RESET}"
echo -e "${MARGIN}${CYAN}╰─────────────────────────────────────────────────────────────────────────────╯${RESET}\n"

TOTAL_AGENTS=$(echo "$JSON_DATA" | jq '(.result.agents // []) | length')
WORKING_AGENTS=$(echo "$JSON_DATA" | jq '[(.result.agents // [])[] | select(.agent_status == "working")] | length')
IDLE_AGENTS=$(echo "$JSON_DATA" | jq '[(.result.agents // [])[] | select(.agent_status == "idle")] | length')

echo -e "${MARGIN}${MAGENTA}■ SUMMARY ${RESET}"
echo -e "${SUBMARGIN}Total Agents:  ${WHITE}$TOTAL_AGENTS${RESET}"
echo -e "${SUBMARGIN}Working:       ${GREEN}$WORKING_AGENTS${RESET}"
echo -e "${SUBMARGIN}Idle:          ${YELLOW}$IDLE_AGENTS${RESET}\n"

echo -e "${MARGIN}${BLUE}■ AGENT CONTEXT BREAKDOWN ${RESET}"
printf "${DIM}${SUBMARGIN}%-12s | %-9s | %-32s | %s${RESET}\n" "AGENT" "STATUS" "TASK" "CONTEXT & TOKENS"
echo -e "${DIM}${SUBMARGIN}────────────────────────────────────────────────────────────────────────────${RESET}"

echo "$JSON_DATA" | jq -r '(.result.agents // [])[] | [.agent, .agent_status, (.tokens.context // "-"), (.terminal_title_stripped // "Unknown Task")] | @tsv' | while IFS=$'\t' read -r agent status context title; do
    status_c=$([ "$status" = "working" ] && echo "$GREEN" || echo "$YELLOW")
    [ ${#title} -gt 31 ] && title="${title:0:28}..."
    context_c=$([ "$context" != "-" ] && echo "$CYAN" || echo "$DIM")
    printf "${SUBMARGIN}${BOLD}${WHITE}%-12s${RESET} | ${status_c}%-9s${RESET} | ${WHITE}%-32s${RESET} | ${context_c}%s${RESET}\n" "$agent" "$status" "$title" "$context" | format_bars
done

echo -e "\n${MARGIN}${YELLOW}■ SUBSCRIPTION LIMITS ${RESET}"

CACHE_AGE_LIMIT=300
CURRENT_TIME=$(date +%s)

update_cache_if_stale() {
    local cmd=$1
    local cache_file=$2

    if [ ! -f "$cache_file" ]; then
        if command -v "$cmd" >/dev/null 2>&1; then
            echo -e "${DIM}${SUBMARGIN}Initializing $cmd quota cache...${RESET}"
            "$cmd" -p "/usage" > "${cache_file}.tmp" 2>/dev/null && mv "${cache_file}.tmp" "$cache_file"
            echo -e "\033[1A\033[2K\r\c"
        fi
    else
        local last_mod=$(stat -c "%Y" "$cache_file" 2>/dev/null || stat -f "%m" "$cache_file" 2>/dev/null)
        if [ $((CURRENT_TIME - last_mod)) -ge $CACHE_AGE_LIMIT ]; then
            (
                if command -v "$cmd" >/dev/null 2>&1; then
                    "$cmd" -p "/usage" > "${cache_file}.tmp" 2>/dev/null && mv "${cache_file}.tmp" "$cache_file"
                fi
            ) & disown
        fi
    fi
}

update_cache_if_stale "agy" "/tmp/agy_quota.txt"
update_cache_if_stale "claude" "/tmp/claude_quota.txt"

if [ -f /tmp/agy_quota.txt ]; then
    echo -e "${SUBMARGIN}${CYAN}[Antigravity Quota]${RESET}"
    grep -v "Quota:" /tmp/agy_quota.txt | awk -F'\t' '{ printf "%-22s | %-25s | %-5s | %s\n", $1, $2, $3, $4 }' | sed "s/^/$SUBSUBMARGIN/" | format_bars
    echo ""
fi

if [ -f /tmp/claude_quota.txt ]; then
    echo -e "${SUBMARGIN}${CYAN}[Claude Subscription]${RESET}"
    grep -E "used" /tmp/claude_quota.txt | sed "s/^/$SUBSUBMARGIN/" | format_bars
    echo ""
fi

echo -e "${SUBMARGIN}${CYAN}[Other Agents (Installed & Active)]${RESET}"
printf "${DIM}${SUBSUBMARGIN}%-10s | %-16s | %s${RESET}\n" "AGENT" "PROVIDER" "LIMIT / CAPACITY"
echo -e "${DIM}${SUBSUBMARGIN}──────────────────────────────────────────────────────────────────────${RESET}"

# Parse active limits natively reported by Herdr
declare -A HERDR_LIMITS
declare -A HERDR_PROVIDERS
while IFS=$'\t' read -r agent provider limit; do
    HERDR_LIMITS["$agent"]="$limit"
    HERDR_PROVIDERS["$agent"]="$provider"
done < <(echo "$JSON_DATA" | jq -r '(.result.agents // []) | map(select(.tokens != null and .tokens.limit != null)) | unique_by(.agent) | .[] | [ .agent, (.tokens.provider // "-"), .tokens.limit ] | @tsv')

# Standard integration install directories
declare -A KNOWN_AGENTS=(
    ["codex"]="$HOME/.codex"
    ["opencode"]="$HOME/.config/opencode"
    ["grok"]="$HOME/.grok"
    ["claude"]="$HOME/.claude"
    ["agy"]="$HOME/.gemini/config"
    ["cursor"]="$HOME/.cursor"
    ["devin"]="$HOME/.config/devin"
    ["kimi"]="$HOME/.kimi-code"
)

# Merge HERDR_LIMITS keys and KNOWN_AGENTS keys safely (bash)
ALL_AGENTS=($(echo "${!HERDR_LIMITS[@]}" "${!KNOWN_AGENTS[@]}" | tr ' ' '\n' | sort -u))

for agent in "${ALL_AGENTS[@]}"; do
    # Skip agy and claude as they have dedicated top-level quota sections
    if [ "$agent" = "agy" ] || [ "$agent" = "claude" ]; then
        continue
    fi
    
    is_installed=0
    if [ -n "${KNOWN_AGENTS[$agent]:-}" ] && [ -d "${KNOWN_AGENTS[$agent]}" ]; then
        is_installed=1
    fi
    
    has_limit=0
    if [ -n "${HERDR_LIMITS[$agent]:-}" ]; then
        has_limit=1
    fi
    
    if [ "$has_limit" -eq 0 ] && [ "$is_installed" -eq 0 ]; then
        continue
    fi
    
    provider="${HERDR_PROVIDERS[$agent]:-(Installed)}"
    limit="${HERDR_LIMITS[$agent]:-Idle / Offline}"
    
    # If it's just 'Installed', use DIM coloring for the provider/limit so it doesn't clutter active limits
    if [ "$has_limit" -eq 0 ]; then
        printf "${SUBSUBMARGIN}${BOLD}${WHITE}%-10s${RESET} | ${DIM}%-16s${RESET} | ${DIM}%s${RESET}\n" "$agent" "$provider" "$limit" | format_bars
    else
        printf "${SUBSUBMARGIN}${BOLD}${WHITE}%-10s${RESET} | ${CYAN}%-16s${RESET} | ${GREEN}%s${RESET}\n" "$agent" "$provider" "$limit" | format_bars
    fi
done

echo -e "\n${MARGIN}${DIM}Press any key to exit...${RESET}"
read -n 1 -s
