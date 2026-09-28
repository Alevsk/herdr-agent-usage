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
if [ -z "$JSON_DATA" ] || ! jq -e '.result.agents' <<< "$JSON_DATA" >/dev/null 2>&1; then
    echo -e "${YELLOW}Error: Unable to fetch valid agent data from Herdr.${RESET}"
    exit 1
fi

clear
echo ""
echo -e "${MARGIN}${CYAN}╭─────────────────────────────────────────────────────────────────────────────╮${RESET}"
echo -e "${MARGIN}${CYAN}│                       ${BOLD}Herdr Agent Usage Dashboard${RESET}${CYAN}                           │${RESET}"
echo -e "${MARGIN}${CYAN}╰─────────────────────────────────────────────────────────────────────────────╯${RESET}\n"

read -r TOTAL_AGENTS WORKING_AGENTS IDLE_AGENTS <<< $(jq -r '
  (.result.agents // []) |
  length as $total |
  (map(select(.agent_status == "working")) | length) as $working |
  (map(select(.agent_status == "idle")) | length) as $idle |
  "\($total) \($working) \($idle)"
' <<< "$JSON_DATA")

echo -e "${MARGIN}${MAGENTA}■ SUMMARY ${RESET}"
echo -e "${SUBMARGIN}Total Agents:  ${WHITE}$TOTAL_AGENTS${RESET}"
echo -e "${SUBMARGIN}Working:       ${GREEN}$WORKING_AGENTS${RESET}"
echo -e "${SUBMARGIN}Idle:          ${YELLOW}$IDLE_AGENTS${RESET}\n"

echo -e "${MARGIN}${BLUE}■ AGENT CONTEXT BREAKDOWN ${RESET}"
printf "${DIM}${SUBMARGIN}%-12s | %-9s | %-32s | %s${RESET}\n" "AGENT" "STATUS" "TASK" "CONTEXT & TOKENS"
echo -e "${DIM}${SUBMARGIN}────────────────────────────────────────────────────────────────────────────${RESET}"

short_tokens() {
    if [ "$1" -ge 1000 ]; then echo "$(( ($1 + 500) / 1000 ))k"; else echo "$1"; fi
}

# Live context of a pane, read from the session file its agent is writing, so it
# is current even mid-turn and needs no hook. Prints nothing when unknown.
# Claude: the transcript named by the session id Herdr tracks for the pane; the
# context is every input token of the last main-thread request. The window size
# is only given to the status line, so it comes from what hooks/claude-statusline.sh
# saved for the session; without it there is no percentage.
CLAUDE_STATUS_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/herdr-agent-usage/claude"

claude_live_context() {
    local session=$1 transcript tokens window=""
    [ "$session" != "-" ] || return 1
    for transcript in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/projects/*/"$session".jsonl; do
        [ -f "$transcript" ] && break
    done
    [ -f "$transcript" ] || return 1
    tokens=$(grep -h '"type":"assistant"' "$transcript" | grep -v -e '"isSidechain":true' -e '"model":"<synthetic>"' |
        tail -n 1 | jq -r '.message.usage | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)' 2>/dev/null)
    [[ "$tokens" =~ ^[0-9]+$ ]] && [ "$tokens" -gt 0 ] || return 1
    [ -f "$CLAUDE_STATUS_CACHE/$session.json" ] &&
        window=$(jq -r '.context_window.context_window_size // empty' "$CLAUDE_STATUS_CACHE/$session.json" 2>/dev/null)
    if [[ "$window" =~ ^[0-9]+$ ]] && [ "$window" -gt 0 ]; then
        echo "⛁ $(( (tokens * 100 + window / 2) / window ))% ($(short_tokens "$tokens"))"
    else
        echo "⛁ $(short_tokens "$tokens")"
    fi
}

# Codex: Herdr has no session id for it, so use the newest rollout started in
# the pane's working directory, against the model's context window.
codex_live_context() {
    local cwd=$1 sessions="${CODEX_HOME:-$HOME/.codex}/sessions" rollout used window
    [ -d "$sessions" ] && [ "$cwd" != "-" ] || return 1
    rollout=$(find "$sessions" -type f -name 'rollout-*.jsonl' -mtime -7 -print0 2>/dev/null |
        while IFS= read -r -d '' file; do
            head -n 1 "$file" | grep -qF "\"cwd\":\"$cwd\"" && printf '%s\0' "$file"
        done | newest_file) || return 1
    read -r used window < <(grep -h '"type":"token_count"' "$rollout" | grep '"info":{' | tail -n 1 |
        jq -r '.payload.info | "\(.last_token_usage.total_tokens // "") \(.model_context_window // "")"' 2>/dev/null)
    [[ "$used" =~ ^[0-9]+$ ]] || return 1
    if [[ "$window" =~ ^[0-9]+$ ]] && [ "$window" -gt 0 ]; then
        echo "⛁ $(( (used * 100 + window / 2) / window ))% ($(short_tokens "$used"))"
    else
        echo "⛁ $(short_tokens "$used")"
    fi
}

# Prints the newest file among the NUL-separated paths read from stdin.
newest_file() {
    local newest="" file
    while IFS= read -r -d '' file; do
        [[ -z "$newest" || "$file" -nt "$newest" ]] && newest=$file
    done
    [ -n "$newest" ] && echo "$newest"
}

# Empty fields become "-": read collapses consecutive tabs.
jq -r '(.result.agents // [])[] | [.agent, .agent_status, (.tokens.context // "-"), (.terminal_title_stripped // "Unknown Task"),
    (.agent_session.value // "-"), (.foreground_cwd // .cwd // "-")] | map(if . == null or . == "" then "-" else . end) | @tsv' <<< "$JSON_DATA" |
while IFS=$'\t' read -r agent status context title session cwd; do
    # Prefer the live value; what Herdr holds is only as fresh as the last report.
    live=""
    case "$agent" in
        claude) live=$(claude_live_context "$session") ;;
        codex) live=$(codex_live_context "$cwd") ;;
    esac
    [ -n "$live" ] && context=$live
    status_c=$([ "$status" = "working" ] && echo "$GREEN" || echo "$YELLOW")
    [ ${#title} -gt 31 ] && title="${title:0:28}..."
    context_c=$([ "$context" != "-" ] && echo "$CYAN" || echo "$DIM")
    printf "${SUBMARGIN}${BOLD}${WHITE}%-12s${RESET} | ${status_c}%-9s${RESET} | ${WHITE}%-32s${RESET} | ${context_c}%s${RESET}\n" "$agent" "$status" "$title" "$context" | format_bars
done
echo -e "${DIM}${SUBMARGIN}* Claude and Codex context is read live from their session files; Claude shows a percentage once hooks/claude-statusline.sh has run. \"-\" means no data yet.${RESET}"
echo ""

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

format_epoch() {
    if date --version >/dev/null 2>&1; then
        date -d "@$1" "+%b %d at %-I:%M%p"
    else
        date -r "$1" "+%b %d at %-I:%M%p"
    fi
}

# Converts an ISO-8601 UTC timestamp (fractional seconds allowed) to epoch
# seconds. BSD date -j -f parses in local time, so it runs under TZ=UTC.
iso_to_epoch() {
    if date --version >/dev/null 2>&1; then
        date -d "$1" +%s 2>/dev/null
    else
        local clean=${1%Z}
        TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "${clean%%.*}" +%s 2>/dev/null
    fi
}

# Kimi Code has no non-interactive /usage and keeps no quota on disk, so query
# the /usages endpoint its /usage command uses, with the OAuth token kimi keeps
# in ~/.kimi-code/credentials. The token is short-lived and refreshed by a
# running kimi; when it has expired the previous cache is kept.
KIMI_HOME="$HOME/.kimi-code"
KIMI_CACHE="/tmp/kimi_quota.json"

fetch_kimi_quota() {
    local token
    token=$(jq -rs 'map(select((.expires_at // 0) > now)) | max_by(.expires_at) | .access_token // empty' \
        "$KIMI_HOME"/credentials/*.json 2>/dev/null)
    [ -n "$token" ] || return 1
    # The header goes through stdin so the token never shows in the process list.
    printf 'Authorization: Bearer %s' "$token" |
        curl -sf -m 10 -H @- "${KIMI_CODE_BASE_URL:-https://api.kimi.com/coding/v1}/usages" > "${KIMI_CACHE}.tmp" 2>/dev/null &&
        jq -e '.usages' "${KIMI_CACHE}.tmp" >/dev/null 2>&1 &&
        mv "${KIMI_CACHE}.tmp" "$KIMI_CACHE"
}

update_kimi_cache_if_stale() {
    [ -d "$KIMI_HOME/credentials" ] && command -v curl >/dev/null 2>&1 || return 0
    if [ ! -f "$KIMI_CACHE" ]; then
        echo -e "${DIM}${SUBMARGIN}Initializing kimi quota cache...${RESET}"
        fetch_kimi_quota
        echo -e "\033[1A\033[2K\r\c"
    else
        local last_mod=$(stat -c "%Y" "$KIMI_CACHE" 2>/dev/null || stat -f "%m" "$KIMI_CACHE" 2>/dev/null)
        if [ $((CURRENT_TIME - last_mod)) -ge $CACHE_AGE_LIMIT ]; then
            ( fetch_kimi_quota ) & disown
        fi
    fi
}

update_cache_if_stale "agy" "/tmp/agy_quota.txt"
update_cache_if_stale "claude" "/tmp/claude_quota.txt"
update_kimi_cache_if_stale

if [ -f /tmp/agy_quota.txt ]; then
    echo -e "${SUBMARGIN}${CYAN}[Antigravity Quota]${RESET}"
    grep -v "Quota:" /tmp/agy_quota.txt | while IFS=$'	' read -r model limit pct reset; do
        if date --version >/dev/null 2>&1; then
            reset_local=$(date -d "$reset" "+%b %d at %-I:%M%p (%Z)" 2>/dev/null)
        else
            reset_local=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$reset" "+%b %d at %-I:%M%p (%Z)" 2>/dev/null)
        fi
        reset_local=${reset_local:-$reset}
        printf "%-22s | %-25s | %-5s | %s\n" "$model" "$limit" "$pct" "$reset_local"
    done | sed "s/^/$SUBSUBMARGIN/" | format_bars
    echo ""
fi

if [ -f /tmp/claude_quota.txt ]; then
    echo -e "${SUBMARGIN}${CYAN}[Claude Subscription]${RESET}"
    awk -v prefix="$SUBSUBMARGIN" '/used/{print prefix $0}' /tmp/claude_quota.txt | format_bars
    echo ""
fi

if [ -f "$KIMI_CACHE" ]; then
    echo -e "${SUBMARGIN}${CYAN}[Kimi Code Subscription]${RESET}"
    jq -r '
      [["limit_5h", "5h limit"], ["limit_7d", "Weekly limit"],
       ["limit_month_total", "Monthly limit"], ["limit_month_code", "Monthly code limit"]][] as [$key, $label] |
      .usages[$key] | select(. != null) |
      ((.used_ratio // null) | tonumber? // null) as $ratio | select($ratio != null) |
      [$label, "\($ratio * 100 | round)%", (.reset_time // "")] | @tsv
    ' "$KIMI_CACHE" 2>/dev/null | while IFS=$'\t' read -r label pct reset; do
        epoch=$([ -n "$reset" ] && iso_to_epoch "$reset")
        # The cache outlives an expired token; a window that already reset is back to 0%.
        [ -n "$epoch" ] && [ "$epoch" -lt "$CURRENT_TIME" ] && pct="0%" && epoch=""
        printf "%-22s | %-5s | %s\n" "$label" "$pct" "${epoch:+resets $(format_epoch "$epoch")}"
    done | sed "s/^/$SUBSUBMARGIN/" | format_bars
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
done < <(jq -r '(.result.agents // []) | map(select(.tokens != null and .tokens.limit != null)) | unique_by(.agent) | .[] | [ .agent, (.tokens.provider // "-"), .tokens.limit ] | @tsv' <<< "$JSON_DATA")

# Fallback for agents Herdr has no limit for: read what the agent CLI already
# writes to its local session files. No network calls, no credentials.

# Codex records its subscription limits in every token_count event of the
# session rollouts (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl). Use the latest
# snapshot from the last 7 days; it reflects the last Codex turn.
codex_local_limit() {
    local sessions="${CODEX_HOME:-$HOME/.codex}/sessions" rate_limits
    [ -d "$sessions" ] || return 1
    rate_limits=$(
        find "$sessions" -type f -name 'rollout-*.jsonl' -mtime -7 -print0 2>/dev/null |
            xargs -0 grep -h '"rate_limits":{' 2>/dev/null |

            jq -sc 'map(select(.payload.rate_limits != null)) | max_by(.timestamp) // empty | .payload.rate_limits' 2>/dev/null
    )
    [ -n "$rate_limits" ] || return 1

    local plan limit="" window pct reset
    plan=$(jq -r '.plan_type // empty' <<< "$rate_limits")
    while IFS=$'\t' read -r window pct reset; do
        [ -n "$limit" ] && limit+=" · "
        limit+="$pct $window"
        [ -n "$reset" ] && limit+=" (resets $(format_epoch "$reset"))"
    done < <(jq -r '
      def window: if . == null then "window"
        elif . % 1440 == 0 then "\(. / 1440)d"
        elif . % 60 == 0 then "\(. / 60)h"
        else "\(.)m" end;
      [.primary, .secondary][] | select(. != null and .used_percent != null) |
      ((.resets_at // null) | if . == null then null else floor end) as $reset |
      # A window that reset after the last Codex turn is back to 0%.
      (if $reset != null and $reset < now then 0 else .used_percent end) as $used |
      [(.window_minutes | window), "\($used | round)%", ($reset // "" | tostring)] | @tsv
    ' <<< "$rate_limits")
    [ -n "$limit" ] || return 1
    printf '%s\t%s\n' "openai${plan:+ ($plan)}" "$limit"
}

# Kimi Code keeps no quota on disk, only per-session context usage: the last
# token_counting event of the newest main-agent wire log, measured against the
# model's max_context_size from ~/.kimi-code/config.toml.
kimi_local_limit() {
    local home="$HOME/.kimi-code" wire model tokens max
    [ -d "$home/sessions" ] || return 1
    wire=$(find "$home/sessions" -type f -path '*/agents/main/wire.jsonl' -mtime -7 -print0 2>/dev/null | newest_file) || return 1

    tokens=$(grep -h '"type":"token_counting\.' "$wire" | tail -n 1 | jq -r '.tokens // empty' 2>/dev/null)
    model=$(grep -h '"type":"usage.record"' "$wire" | tail -n 1 | jq -r '.model // empty' 2>/dev/null)
    [ -n "$tokens" ] || return 1
    max=$(awk -v section="[models.\"$model\"]" '
        $0 == section { in_section = 1; next }
        /^\[/ { in_section = 0 }
        in_section && $1 == "max_context_size" { print $3; exit }
    ' "$home/config.toml" 2>/dev/null)

    local limit
    if [[ "$max" =~ ^[0-9]+$ ]] && [ "$max" -gt 0 ]; then
        limit="⛁ $((tokens * 100 / max))% context ($((tokens / 1000))k / $((max / 1000))k)"
    else
        limit="⛁ $((tokens / 1000))k context"
    fi
    printf '%s\t%s\n' "kimi-code" "$limit${model:+ · ${model#kimi-code/}}"
}

for agent in codex kimi; do
    [ -n "${HERDR_LIMITS[$agent]:-}" ] && continue
    IFS=$'\t' read -r provider limit < <("${agent}_local_limit") || continue
    HERDR_LIMITS["$agent"]="$limit"
    HERDR_PROVIDERS["$agent"]="$provider"
done

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
