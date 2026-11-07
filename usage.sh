#!/usr/bin/env bash

HERDR="${HERDR_BIN_PATH:-herdr}"
if ! command -v jq >/dev/null; then exit 1; fi

BLUE=$'\033[1;34m'
MAGENTA=$'\033[1;35m'

MARGIN="    "
SUBMARGIN="      "

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/table.sh
source "$PLUGIN_DIR/lib/table.sh"
# shellcheck source=lib/accounts.sh
source "$PLUGIN_DIR/lib/accounts.sh"
# shellcheck source=lib/quota.sh
source "$PLUGIN_DIR/lib/quota.sh"

# Outer width of the grids: the pane, minus the indent, capped so a wide
# terminal does not stretch every column.
term_budget() {
    local cols=${COLUMNS:-}
    if [ -z "$cols" ]; then
        cols=$(stty size 2>/dev/null | awk '{print $2}')
    fi
    [[ $cols =~ ^[0-9]+$ ]] && [ "$cols" -gt 0 ] || cols=100
    local budget=$(( cols - ${#SUBMARGIN} ))
    [ "$budget" -gt 140 ] && budget=140
    [ "$budget" -lt 48 ] && budget=48
    printf '%s' "$budget"
}

print_indented() { # <indent> — prefix each stdin line
    local indent=$1 line
    while IFS= read -r line || [ -n "$line" ]; do
        printf '%s%s\n' "$indent" "$line"
    done
}

# Herdr reports limits as "7d 18%"; rows want "18% 7d". Empty when the value
# does not match that shape (e.g. codex_local_limit's chained summary).
herdr_limit_usage() { # <limit>
    local window pct
    read -r window pct <<< "$1"
    [[ "$window" =~ ^[0-9]+[smhd]$ && "$pct" =~ ^[0-9]+%$ ]] && echo "$pct $window"
}

JSON_DATA=$("$HERDR" agent list 2>/dev/null)
if [ -z "$JSON_DATA" ] || ! jq -e '.result.agents' <<< "$JSON_DATA" >/dev/null 2>&1; then
    echo -e "${YELLOW}Error: Unable to fetch valid agent data from Herdr.${RESET}"
    exit 1
fi

clear
BUDGET=$(term_budget)
echo ""
print_indented "$SUBMARGIN" <<< "$(box_banner "$BUDGET" "Herdr Agent Usage Dashboard")"
echo ""

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
context_tsv=$'AGENT\tSTATUS\tTASK\tCONTEXT\n'
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
            [ -n "$id" ] && [ "${ACC_LABEL[codex/$id]:-}" != default ] && [ -n "${ACC_LABEL[codex/$id]:-}" ] &&
                agent="${agent}·${ACC_LABEL[codex/$id]}"
            ;;
    esac
    [ "$(visible_len "$agent")" -gt 22 ] && agent=$(truncate_cell "$agent" 22)
    [ -n "$live" ] && context=$live
    title=${title//$'\t'/ }
    if [ "$status" = "working" ]; then status_cell="${GREEN}${status}${RESET}"
    else status_cell="${YELLOW}${status}${RESET}"; fi
    context_tsv+="${BOLD}${WHITE}${agent}${RESET}"$'\t'"${status_cell}"$'\t'"${title}"$'\t'"$(context_cell "$context")"$'\n'
done < <(jq -r '(.result.agents // [])[] | [.agent, .agent_status, (.tokens.context // "-"), (.terminal_title_stripped // "Unknown Task"),
    (.agent_session.value // "-"), (.foreground_cwd // .cwd // "-")] | map(if . == null or . == "" then "-" else . end) | @tsv' <<< "$JSON_DATA")

context_table=$(table_render "$BUDGET" 2 1 <<< "$context_tsv")
print_indented "$SUBMARGIN" <<< "$context_table"
note='Live for Claude and Codex. A percentage appears once hooks/claude-statusline.sh has run.
"—" means no data. A bare claude/codex row is the default account; a ·label suffix names the account.'
echo ""
while IFS= read -r line; do
    printf '%s%s%s%s\n' "$SUBMARGIN" "$DIM" "$line" "$RESET"
done < <(printf '%s\n' "$note" | fold -s -w "$BUDGET")
echo ""

CURRENT_TIME=$(date +%s)
IS_GNU_DATE=$(date --version >/dev/null 2>&1 && echo 1 || echo 0)

format_epoch() {
    if [ "$IS_GNU_DATE" = 1 ]; then
        date -d "@$1" "+%b %-d %-I:%M%p"
    else
        date -r "$1" "+%b %-d %-I:%M%p"
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

# ── one block per agent+account ─────────────────────────────────────────────
GROUP_ORDER=(claude agy codex grok opencode kimi)

# Compact 7d summary for a claude account: the /usage cache's "Last 7d" line
# when present, else the home's stats-cache.json via quota_claude_local_usage.
claude_local_summary() { # <cache-file> <home>
    local nreq nsess
    if [ -f "$1" ] && read -r _ _ _ nreq _ _ nsess _ < <(
            grep -oE 'Last 7d · [0-9]+ requests? · [0-9]+ sessions?' "$1" | head -n 1); then
        [ "$nreq" -ge 1000 ] 2>/dev/null && nreq="$(( (nreq + 500) / 1000 ))k"
        echo "7d $nreq req · $nsess sess"
    else
        quota_claude_local_usage "$2"
    fi
}

# One account block. The first window row carries agent, account, and plan;
# the rows under it leave those cells empty until the next __RULE__.
emit_account() { # <agent> <id> <multi 0|1> <first_id>
    local agent=$1 id=$2 multi=$3 first_id=$4
    local key="$agent/$id" shown=0 any=0
    local account plan agent_cell account_cell
    account=$(account_display "${ACC_LABEL[$key]:-}" "${ACC_EMAIL[$key]:-}" "$multi")
    plan=$(plan_name "${ACC_PLAN[$key]:-}")
    agent_cell="${BOLD}${WHITE}${agent}${RESET}"
    account_cell="${CYAN}${account}${RESET}"

    # shellcheck disable=SC2317
    emit() { # <limit> <usage> <reset>
        local reset=$3
        { [ -n "$reset" ] && [ "$reset" != "-" ]; } || reset="—"
        if [ "$shown" = 0 ]; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$agent_cell" "$account_cell" "$plan" "$1" "$2" "$reset"
            shown=1
        else
            printf '\t\t\t%s\t%s\t%s\n' "$1" "$2" "$reset"
        fi
        any=1
    }

    local cache pct="" tag=""
    case "$agent" in
        claude)
            cache=$(quota_cache_path claude "$id")
            local week_pct="" week_reset="" sess_pct="" fable_pct="" lusage=""
            if [ -f "$cache" ]; then
                while IFS=$'\t' read -r k p r; do
                    case "$k" in
                        week)  week_pct=$p; week_reset=$r ;;
                        sess)  sess_pct=$p ;;
                        fable) fable_pct=$p ;;
                    esac
                done < <(quota_claude_quota "$cache" || true)
            fi
            [ -n "$week_pct" ] && emit week "$(bar_pct "$week_pct")" "$week_reset"
            [ -n "$sess_pct" ] && emit session "$(bar_pct "$sess_pct")" ""
            [ -n "$fable_pct" ] && emit fable "$(bar_pct "$fable_pct")" ""
            lusage=$(claude_local_summary "$cache" "${ACC_HOME[$key]:-}" || true)
            [ -n "$lusage" ] && emit "7d" "${lusage#7d }" ""
            [ "$any" = 0 ] && emit "—" "—" ""
            ;;
        agy)
            cache=$(quota_cache_path agy "$id")
            if [ ! -f "$cache" ]; then emit "—" "—" ""; return; fi
            local model wpct wreset fpct epoch reset_fmt
            # one weekly row and one five-hour row per model family
            while IFS=$'\t' read -r model wpct wreset fpct; do
                [ -n "$model" ] || continue
                model=${model//$'\t'/ }
                if [ -n "$wpct" ]; then
                    if [ "$wpct" = "disabled" ]; then
                        emit "${model} · week" "${DIM}disabled${RESET}" ""
                    else
                        epoch=$(iso_to_epoch "$wreset" || true)
                        reset_fmt="—"
                        [ -n "$epoch" ] && reset_fmt=$(format_epoch "$epoch" | sed 's/AM$/am/; s/PM$/pm/')
                        emit "${model} · week" "$(bar_pct "${wpct%\%}")" "$reset_fmt"
                    fi
                fi
                if [ "$fpct" = "disabled" ]; then
                    emit "${model} · 5h" "${DIM}disabled${RESET}" ""
                elif [ -n "$fpct" ]; then
                    emit "${model} · 5h" "$(bar_pct "${fpct%\%}")" ""
                fi
            done < <(awk -F'\t' '
                $1 != "Quota:" && NF >= 3 {
                    if (!($1 in fam)) { fam[$1] = 1; order[++n] = $1 }
                    if ($2 ~ /Weekly/ && w[$1]++ == 0) { wp[$1] = $3; wr[$1] = $4 }
                    if ($2 ~ /Five Hour/ && f[$1]++ == 0) fp[$1] = $3
                }
                END { for (i = 1; i <= n; i++) printf "%s\t%s\t%s\t%s\n", order[i], wp[order[i]], wr[order[i]], fp[order[i]] }
            ' "$cache")
            [ "$any" = 0 ] && emit "—" "—" ""
            ;;
        codex)
            read -r pct tag <<< "$(herdr_limit_usage "${HERDR_LIMITS[codex]:-}")" || true
            if [ -n "$pct" ]; then emit "${tag:--}" "$(bar_pct "${pct%\%}")" ""
            else emit "—" "—" ""; fi
            ;;
        grok)
            # Herdr's limit is account-blind; attach it to the first account only.
            if [ "$id" = "$first_id" ]; then
                read -r pct tag <<< "$(herdr_limit_usage "${HERDR_LIMITS[grok]:-}")" || true
                if [ -n "$pct" ]; then emit "${tag:--}" "$(bar_pct "${pct%\%}")" ""
                else emit "—" "—" ""; fi
            else
                emit "—" "—" ""
            fi
            ;;
        opencode)
            emit "—" "—" ""
            ;;
        kimi)
            cache=$(quota_cache_path kimi "$id" json)
            local pct7="" reset7="" pct5="" pctm="" epoch7="" reset_fmt="—"
            if [ -f "$cache" ]; then
                IFS=$'\t' read -r pct7 reset7 pct5 pctm < <(jq -r '
                    def pct($k): (.usages[$k].used_ratio // null) as $r |
                        if $r == null then "" else "\(($r * 100) | round)%" end;
                    def rst($k): (.usages[$k].reset_time // "");
                    [pct("limit_7d"), rst("limit_7d"), pct("limit_5h"), pct("limit_month_total")] | @tsv
                ' "$cache" 2>/dev/null) || true
                [ -n "$reset7" ] && epoch7=$(iso_to_epoch "$reset7" || true)
                if [ -n "$pct7" ]; then
                    # the cache outlives an expired token: a window that already reset is back to 0%
                    if [ -n "$epoch7" ] && [ "$epoch7" -lt "$CURRENT_TIME" ]; then
                        pct7="0%"; epoch7=""
                    fi
                    [ -n "$epoch7" ] && reset_fmt=$(format_epoch "$epoch7" | sed 's/AM$/am/; s/PM$/pm/')
                    emit "7d" "$(bar_pct "${pct7%\%}")" "$reset_fmt"
                fi
                [ -n "$pct5" ] && emit "5h" "$(bar_pct "${pct5%\%}")" ""
                [ -n "$pctm" ] && emit "month" "$(bar_pct "${pctm%\%}")" ""
            fi
            [ "$any" = 0 ] && emit "—" "—" ""
            ;;
    esac
}

render_group() { # <agent> <ids> — TSV rows, __RULE__ between accounts
    local agent=$1 ids=$2 multi=0 count=0 first=1 id first_id
    count=$(grep -c '' <<< "$ids")
    [ "$count" -gt 1 ] && multi=1
    first_id=$(head -n 1 <<< "$ids")
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        [ "$first" = 0 ] && echo __RULE__
        first=0
        emit_account "$agent" "$id" "$multi" "$first_id"
    done <<< "$ids"
}

limit_tsv=$'AGENT\tACCOUNT\tPLAN\tLIMIT\tUSAGE\tRESETS\n'
sep=0
for agent in "${GROUP_ORDER[@]}"; do
    ids=$(awk -F'\t' -v a="$agent" '$1 == a { print $2 }' <<< "$ACC_TSV")
    [ -n "$ids" ] || continue
    block=$(render_group "$agent" "$ids")
    [ -n "$block" ] || continue
    [ "$sep" = 1 ] && limit_tsv+=$'__RULE__\n'
    limit_tsv+="$block"$'\n'
    sep=1
done

if [ "$sep" = 1 ]; then
    echo ""
    echo -e "${MARGIN}${YELLOW}■ SUBSCRIPTION LIMITS ${RESET}"
    # protect the account column (1): model names ellipsize before emails do
    print_indented "$SUBMARGIN" <<< "$(table_render "$BUDGET" 3 0 1 <<< "$limit_tsv")"
fi

other_tsv=$'AGENT\tPROVIDER\tLIMIT\n'
other_any=0
for agent in "${ALL_AGENTS[@]}"; do
    [ -n "${AGENT_HAS[$agent]:-}" ] && continue
    is_installed=0
    if [ -n "${KNOWN_AGENTS[$agent]:-}" ] && [ -d "${KNOWN_AGENTS[$agent]}" ]; then
        is_installed=1
    fi
    has_limit=0
    [ -n "${HERDR_LIMITS[$agent]:-}" ] && has_limit=1
    if [ "$has_limit" -eq 0 ] && [ "$is_installed" -eq 0 ]; then
        continue
    fi
    provider="${HERDR_PROVIDERS[$agent]:-(Installed)}"
    limit="${HERDR_LIMITS[$agent]:-Idle / Offline}"
    limit=${limit//$'\t'/ }
    if [ "$has_limit" -eq 0 ]; then
        provider="${DIM}${provider}${RESET}"
        limit="${DIM}${limit}${RESET}"
    else
        provider="${CYAN}${provider}${RESET}"
        limit="${GREEN}${limit}${RESET}"
    fi
    other_tsv+="${BOLD}${WHITE}${agent}${RESET}"$'\t'"${provider}"$'\t'"${limit}"$'\n'
    other_any=1
done

if [ "$other_any" = 1 ]; then
    echo ""
    echo -e "${MARGIN}${CYAN}■ OTHER AGENTS ${RESET}"
    print_indented "$SUBMARGIN" <<< "$(table_render "$BUDGET" 2 0 <<< "$other_tsv")"
fi

echo -e "\n${MARGIN}${DIM}Press any key to exit...${RESET}"
read -n 1 -s
