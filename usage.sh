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

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/accounts.sh
source "$PLUGIN_DIR/lib/accounts.sh"
# shellcheck source=lib/quota.sh
source "$PLUGIN_DIR/lib/quota.sh"

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

# printf pads by bytes; pad display columns by characters (agent names hold ·/…)
pad_cols() { # <string> <width>
    local n=$(( $2 - ${#1} ))
    if [ "$n" -gt 0 ]; then printf '%s%*s' "$1" "$n" ''; else printf '%s' "$1"; fi
}

truncate_cell() { # <text> <width>
    [ ${#1} -gt "$2" ] && echo "${1:0:$(( $2 - 1 ))}…" || echo "$1"
}

render_account_cell() { # <label> <email> → "label · email" truncated to 28
    local cell="$1"
    [ "$2" != "-" ] && [ -n "$2" ] && cell="$1 · $2"
    truncate_cell "$cell" 28
}

render_agy_account() { # <account_id> <account_cell> — agy TSV rows, single usage column
    local cache; cache=$(quota_cache_path agy "$1")
    [ -f "$cache" ] || { printf "${SUBSUBMARGIN}%s | %s | %s\n" "$(pad_cols "$2" 28)" "$(pad_cols "-" 13)" "-"; return; }
    local first=1 model limit pct reset reset_seg
    grep -v "Quota:" "$cache" | while IFS=$'\t' read -r model limit pct reset; do
        reset_seg=""
        if [ -n "$reset" ] && [ "$pct" != "disabled" ]; then
            if [ "$IS_GNU_DATE" = 1 ]; then
                reset_seg=$(date -d "$reset" "+%b %d at %-I:%M%p (%Z)" 2>/dev/null)
            else
                reset_seg=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$reset" "+%b %d at %-I:%M%p (%Z)" 2>/dev/null)
            fi
            reset_seg=" · ${reset_seg:-$reset}"
        fi
        if [ "$first" -eq 1 ]; then
            printf "${SUBSUBMARGIN}%s | %s | %s\n" "$(pad_cols "$2" 28)" "$(pad_cols "-" 13)" "$model · $limit · $pct$reset_seg"
            first=0
        else
            printf "${SUBSUBMARGIN}%s | %s | %s\n" "$(pad_cols "" 28)" "$(pad_cols "" 13)" "$model · $limit · $pct$reset_seg"
        fi
    done
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
    local session=$1 tokens window=""
    [ "$session" != "-" ] || return 1
    local transcript
    transcript=$(accounts_claude_transcript "$session")
    [ -n "$transcript" ] || return 1
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
    local cwd=$1 rollout used window
    rollout=$(accounts_codex_rollout "$cwd")
    [ -n "$rollout" ] || return 1
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

# Account registry (single discovery pass; rows consult ACC_LABEL below, and
# the ACC_* arrays also feed the SUBSCRIPTION LIMITS section in a later task).
ACC_TSV=$(accounts_list)
declare -A ACC_LABEL=() ACC_EMAIL=() ACC_PLAN=() ACC_HOME=() AGENT_HAS=()
while IFS=$'\t' read -r a id label email plan home; do
    [ -n "$a" ] || continue
    ACC_LABEL["$a/$id"]=$label; ACC_EMAIL["$a/$id"]=$email
    ACC_PLAN["$a/$id"]=$plan;   ACC_HOME["$a/$id"]=$home; AGENT_HAS["$a"]=1
done <<< "$ACC_TSV"

# Empty fields become "-": read collapses consecutive tabs.
jq -r '(.result.agents // [])[] | [.agent, .agent_status, (.tokens.context // "-"), (.terminal_title_stripped // "Unknown Task"),
    (.agent_session.value // "-"), (.foreground_cwd // .cwd // "-")] | map(if . == null or . == "" then "-" else . end) | @tsv' <<< "$JSON_DATA" |
while IFS=$'\t' read -r agent status context title session cwd; do
    # Prefer the live value; what Herdr holds is only as fresh as the last report.
    # The braces in "${agent}·…" are load-bearing: bash 3.2–5.3 in a UTF-8
    # locale otherwise scans $agent· as one (empty) variable name and drops the prefix.
    live=""
    case "$agent" in
        claude)
            live=$(claude_live_context "$session")
            id=$(accounts_resolve claude "$session")
            [ -n "$id" ] && [ "${ACC_LABEL[claude/$id]:-}" != default ] && [ -n "${ACC_LABEL[claude/$id]:-}" ] &&
                agent="${agent}·${ACC_LABEL[claude/$id]}"
            ;;
        codex)
            live=$(codex_live_context "$cwd")
            id=$(accounts_resolve codex "$cwd")
            [ -n "$id" ] && [ "${ACC_LABEL[codex/$id]:-}" != default ] && [ -n "${ACC_LABEL[codex/$id]:-]}" ] &&
                agent="${agent}·${ACC_LABEL[codex/$id]}"
            ;;
    esac
    [ ${#agent} -gt 12 ] && agent="${agent:0:11}…"
    [ -n "$live" ] && context=$live
    status_c=$([ "$status" = "working" ] && echo "$GREEN" || echo "$YELLOW")
    [ ${#title} -gt 31 ] && title="${title:0:28}..."
    context_c=$([ "$context" != "-" ] && echo "$CYAN" || echo "$DIM")
    agent_padded=$(pad_cols "$agent" 12)
    printf "${SUBMARGIN}${BOLD}${WHITE}%s${RESET} | ${status_c}%-9s${RESET} | ${WHITE}%-32s${RESET} | ${context_c}%s${RESET}\n" "$agent_padded" "$status" "$title" "$context" | format_bars
done
echo -e "${DIM}${SUBMARGIN}* Claude and Codex context is read live from their session files; Claude shows a percentage once hooks/claude-statusline.sh has run. \"-\" means no data yet. A bare claude/codex row is the default account (or not yet attributable); a ·label suffix names the account in use.${RESET}"
echo ""

echo -e "\n${MARGIN}${YELLOW}■ SUBSCRIPTION LIMITS ${RESET}"

CURRENT_TIME=$(date +%s)
IS_GNU_DATE=$(date --version >/dev/null 2>&1 && echo 1 || echo 0)

format_epoch() {
    if [ "$IS_GNU_DATE" = 1 ]; then
        date -d "@$1" "+%b %d at %-I:%M%p"
    else
        date -r "$1" "+%b %d at %-I:%M%p"
    fi
}

# Converts an ISO-8601 UTC timestamp (fractional seconds allowed) to epoch
# seconds. BSD date -j -f parses in local time, so it runs under TZ=UTC.
iso_to_epoch() {
    if [ "$IS_GNU_DATE" = 1 ]; then
        date -d "$1" +%s 2>/dev/null
    else
        local clean=${1%Z}
        TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "${clean%%.*}" +%s 2>/dev/null
    fi
}

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
codex_local_limit() { # <home>
    local sessions="$1/sessions" rate_limits
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
    [ -z "${AGENT_HAS[$agent]:-}" ] || continue
    [ -n "${HERDR_LIMITS[$agent]:-}" ] && continue
    case "$agent" in
        codex) IFS=$'\t' read -r provider limit < <(codex_local_limit "$HOME/.codex") || continue ;;
        kimi)  IFS=$'\t' read -r provider limit < <(kimi_local_limit) || continue ;;
    esac
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

# ── quota caches: first open initializes in parallel, then async refresh ────
declare -a QUOTA_INIT=()
while IFS=$'\t' read -r a id label email plan home; do
    case "$a" in
        claude)
            quota_refresh_async_identity "$id" "$home"   # self-checks 1h TTL
            [ -f "$(quota_cache_path claude "$id")" ] || QUOTA_INIT+=("claude|$id|txt|$home")
            ;;
        agy)  [ -f "$(quota_cache_path agy "$id")" ] || QUOTA_INIT+=("agy|$id|txt|$home") ;;
        kimi) [ -f "$(quota_cache_path kimi "$id" json)" ] || QUOTA_INIT+=("kimi|$id|json|$home") ;;
    esac
done <<< "$ACC_TSV"

if [ ${#QUOTA_INIT[@]} -gt 0 ]; then
    echo -e "${DIM}${SUBMARGIN}Initializing quota caches...${RESET}"
    for job in "${QUOTA_INIT[@]}"; do
        IFS='|' read -r a id ext home <<< "$job"
        quota_dispatch "$a" "$id" "$ext" "$home" &
    done
    wait
    echo -e "\033[1A\033[2K\r\c"
fi

# stale refreshes happen in the background, never blocking the popup
while IFS=$'\t' read -r a id label email plan home; do
    case "$a" in
        claude) quota_is_fresh "$(quota_cache_path claude "$id")" || quota_refresh_async claude "$id" txt "$home" ;;
        agy)    quota_is_fresh "$(quota_cache_path agy "$id")"    || quota_refresh_async agy    "$id" txt "$home" ;;
        kimi)   quota_is_fresh "$(quota_cache_path kimi "$id" json)" || quota_refresh_async kimi "$id" json "$home" ;;
    esac
done <<< "$ACC_TSV"

# ── unified per-agent groups ────────────────────────────────────────────────
GROUP_ORDER=(claude agy codex grok opencode kimi)
for agent in "${GROUP_ORDER[@]}"; do
    ids=$(awk -F'\t' -v a="$agent" '$1 == a { print $2 }' <<< "$ACC_TSV")
    [ -n "$ids" ] || continue
    echo -e "${SUBMARGIN}${CYAN}[$agent]${RESET}"
    printf "${DIM}${SUBSUBMARGIN}%-28s | %-13s | %s${RESET}\n" "ACCOUNT" "PLAN" "USAGE & LIMITS"
    grok_first_id=$(awk -F'\t' -v a=grok '$1==a{print $2; exit}' <<< "$ACC_TSV")
    while IFS= read -r id; do
        local_key="$agent/$id"
        cell=$(render_account_cell "${ACC_LABEL[$local_key]}" "${ACC_EMAIL[$local_key]}")
        plan=$(truncate_cell "${ACC_PLAN[$local_key]:--}" 13)
        usage=""
        case "$agent" in
            claude)
                usage=$(quota_claude_cached_usage "$(quota_cache_path claude "$id")")
                [ -n "$usage" ] || usage=$(quota_claude_local_usage "${ACC_HOME[$local_key]}")
                usage=${usage:--}
                printf "${SUBSUBMARGIN}%s | %s | %s\n" "$(pad_cols "$cell" 28)" "$(pad_cols "$plan" 13)" "$usage"
                ;;
            agy)
                render_agy_account "$id" "$cell"
                ;;
            codex)
                # Herdr's per-pane limit is account-blind, so it attaches only to
                # the default home; custom homes read their own rollouts.
                if [ -n "${HERDR_LIMITS[codex]:-}" ] && [ "$id" = ".codex" ]; then
                    usage="${HERDR_LIMITS[codex]}"
                else
                    IFS=$'\t' read -r _ usage < <(codex_local_limit "${ACC_HOME[$local_key]}")
                fi
                printf "${SUBSUBMARGIN}%s | %s | %s\n" "$(pad_cols "$cell" 28)" "$(pad_cols "$plan" 13)" "${usage:--}"
                ;;
            grok)
                if [ -n "${HERDR_LIMITS[grok]:-}" ] && [ "$id" = "$grok_first_id" ]; then
                    usage="${HERDR_LIMITS[grok]}"
                else
                    usage="-"
                fi
                printf "${SUBSUBMARGIN}%s | %s | %s\n" "$(pad_cols "$cell" 28)" "$(pad_cols "$plan" 13)" "$usage"
                ;;
            kimi)
                cache=$(quota_cache_path kimi "$id" json)
                [ -f "$cache" ] || { printf "${SUBSUBMARGIN}%s | %s | %s\n" "$(pad_cols "$cell" 28)" "$(pad_cols "$plan" 13)" "-"; continue; }
                jq -r '
                  [["limit_5h", "5h limit"], ["limit_7d", "Weekly limit"],
                   ["limit_month_total", "Monthly limit"], ["limit_month_code", "Monthly code limit"]][] as [$key, $label] |
                  .usages[$key] | select(. != null) |
                  ((.used_ratio // null) | tonumber? // null) as $ratio | select($ratio != null) |
                  [$label, "\($ratio * 100 | round)%", (.reset_time // "")] | @tsv
                ' "$cache" 2>/dev/null | {
                    first=1
                    while IFS=$'\t' read -r label pct reset; do
                        epoch=$([ -n "$reset" ] && iso_to_epoch "$reset")
                        # The cache outlives an expired token; a window that already reset is back to 0%.
                        [ -n "$epoch" ] && [ "$epoch" -lt "$CURRENT_TIME" ] && pct="0%" && epoch=""
                        line="$label $pct${epoch:+ · resets $(format_epoch "$epoch")}"
                        if [ "$first" -eq 1 ]; then
                            printf "${SUBSUBMARGIN}%s | %s | %s\n" "$(pad_cols "$cell" 28)" "$(pad_cols "$plan" 13)" "$line"; first=0
                        else
                            printf "${SUBSUBMARGIN}%s | %s | %s\n" "$(pad_cols "" 28)" "$(pad_cols "" 13)" "$line"
                        fi
                    done
                }
                ;;
            *)
                printf "${SUBSUBMARGIN}%s | %s | %s\n" "$(pad_cols "$cell" 28)" "$(pad_cols "$plan" 13)" "-"
                ;;
        esac
    done <<< "$ids" | format_bars
    echo ""
done

echo -e "${SUBMARGIN}${CYAN}[Other Agents (Installed & Active)]${RESET}"
printf "${DIM}${SUBSUBMARGIN}%-10s | %-16s | %s${RESET}\n" "AGENT" "PROVIDER" "LIMIT / CAPACITY"
echo -e "${DIM}${SUBSUBMARGIN}──────────────────────────────────────────────────────────────────────${RESET}"

for agent in "${ALL_AGENTS[@]}"; do
    # Agents with registry accounts render as groups above
    [ -n "${AGENT_HAS[$agent]:-}" ] && continue
    
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
