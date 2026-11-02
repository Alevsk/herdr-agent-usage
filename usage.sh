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
      # only table rows (" | " separators) get bars; lines that already carry a
      # composed bar_pct cell ([█… / [░…) and pipe-free detail/footnote lines
      # pass through untouched even when they carry N%
      if ($0 ~ / \| / && $0 !~ /\[[█░]/) {
        match($0, /[0-9]+%/)
        if (RSTART > 0) {
          pct_str = substr($0, RSTART, RLENGTH)
          pct = pct_str + 0
          width = 14
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

# Visible display width of a string: characters, with ANSI SGR color codes
# stripped first (bar_pct cells carry them).
visible_len() { # <string>
    local s=$1
    [[ $s == *$'\033'* ]] && s=$(printf '%s' "$s" | sed $'s/\x1b\\[[0-9;]*m//g')
    printf '%s' "${#s}"
}

# printf pads by bytes; pad display columns by characters (agent names hold ·/…)
pad_cols() { # <string> <width>
    local n=$(( $2 - $(visible_len "$1") ))
    if [ "$n" -gt 0 ]; then printf '%s%*s' "$1" "$n" ''; else printf '%s' "$1"; fi
}

# Colored bar for a known percentage — deterministic width, so cells that
# contain it can be padded correctly BEFORE printing (format_bars skips
# lines that already contain █).
bar_pct() { # <pct 0-100>
    # NB: the filled arithmetic needs its own local line — a single `local
    # pct=$1 w=14 filled=$(( pct * w / 100 ))` expands before pct/w exist.
    local pct=$1 w=14 bar="" i
    local filled=$(( pct * w / 100 ))
    for (( i = 0; i < w; i++ )); do
        if [ "$i" -lt "$filled" ]; then bar+="█"; else bar+="░"; fi
    done
    printf '\033[1;32m[%s]\033[0m \033[1;36m%d%%\033[0m' "$bar" "$pct"
}

truncate_cell() { # <text> <width>
    [ ${#1} -gt "$2" ] && echo "${1:0:$(( $2 - 1 ))}…" || echo "$1"
}

plan_cell() { # <plan> — strip at first underscore, "-" → em dash, pad 6
    local p=${1%%_*}
    { [ -z "$p" ] || [ "$p" = "-" ]; } && p="—"
    pad_cols "$p" 6
}

# group-label identity: the email, else a non-default label (opencode's
# provider key) — empty when the account has neither
agent_identity() { # <agent>/<account_id>
    local email="${ACC_EMAIL[$1]:-}" label="${ACC_LABEL[$1]:-}"
    if [ -n "$email" ] && [ "$email" != "-" ]; then echo "$email"
    elif [ -n "$label" ] && [ "$label" != "default" ]; then echo "$label"
    fi
}

account_cell() { # <label> <email> <width> — bare email when its local part starts with the label
    local cell=$1
    if [ -n "$2" ] && [ "$2" != "-" ]; then
        if [[ "${2%%@*}" == "$1"* ]]; then cell=$2; else cell="$1 · $2"; fi
    fi
    pad_cols "$(truncate_cell "$cell" "$3")" "$3"
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

# ── unified per-agent groups ────────────────────────────────────────────────
GROUP_ORDER=(claude agy codex grok opencode kimi)

printf "${DIM}${SUBMARGIN}%-28s | %-6s | %-24s | %s${RESET}\n" "ACCOUNT" "PLAN" "USAGE" "RESETS"
echo -e "${DIM}${SUBMARGIN}$(printf '%.0s─' {1..70})${RESET}"

emit_label() { echo -e "${SUBMARGIN}${CYAN}$1${RESET}"; }

emit_row() { # <padded-cell> <cellw> <plan> <usage> <resets> — width-28 rows sit at SUBMARGIN
    local indent=$SUBSUBMARGIN
    [ "$2" = 28 ] && indent=$SUBMARGIN
    printf "%s%s | %s | %s | %s\n" "$indent" "$1" "$(plan_cell "$3")" "$(pad_cols "$4" 24)" "${5:--}"
}

emit_detail() { # "item · item" — dim, no pipes, so format_bars leaves the N% bare
    [ -n "$1" ] && echo -e "${DIM}${SUBSUBMARGIN}  · $1${RESET}"
}

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

render_group() { # <agent> <ids> — label line, primary rows, detail lines
    local agent=$1 ids=$2
    local first_id; first_id=$(head -n 1 <<< "$ids")
    local id key plan cell cache usage reset epoch items lusage identity pct tag
    local week_pct week_reset sess_pct fable_pct

    case "$agent" in
        claude|grok) emit_label "$agent" ;;         # multi-account: bare name
        agy)                                           # one account, many model families
            identity=$(agent_identity "agy/$first_id")
            emit_label "agy${identity:+ · $identity}"
            ;;
        *) # single-account agents fold the label into their row; width 28 at
           # SUBMARGIN spans the same columns as width 26 at SUBSUBMARGIN
            ;;
    esac

    while IFS= read -r id; do
        key="$agent/$id"
        plan=${ACC_PLAN[$key]:-}
        usage="—" reset="—" items=""
        case "$agent" in
            claude)
                cell=$(account_cell "${ACC_LABEL[$key]}" "${ACC_EMAIL[$key]}" 26)
                cache=$(quota_cache_path claude "$id")
                week_pct="" week_reset="" sess_pct="" fable_pct=""
                while IFS=$'\t' read -r k p r; do
                    case "$k" in
                        week)  week_pct=$p;  week_reset=$r ;;
                        sess)  sess_pct=$p ;;
                        fable) fable_pct=$p ;;
                    esac
                done <<< "$(quota_claude_quota "$cache")"
                if [ -n "$week_pct" ]; then
                    usage="$(bar_pct "$week_pct") wk"
                    [ -n "$week_reset" ] && reset=$week_reset
                fi
                [ -n "$sess_pct" ] && items="sess ${sess_pct}%"
                [ -n "$fable_pct" ] && items="${items:+$items · }Fable ${fable_pct}%"
                lusage=$(claude_local_summary "$cache" "${ACC_HOME[$key]}")
                [ -n "$lusage" ] && items="${items:+$items · }$lusage"
                emit_row "$cell" 26 "$plan" "$usage" "$reset"
                emit_detail "$items"
                ;;
            agy)
                cache=$(quota_cache_path agy "$id")
                if [ ! -f "$cache" ]; then
                    emit_row "$(account_cell "${ACC_LABEL[$key]}" "${ACC_EMAIL[$key]}" 26)" 26 "$plan" "—" "—"
                    continue
                fi
                # collapse the cache to one weekly row per model family,
                # carrying its five-hour percentage alongside
                awk -F'\t' '
                    $1 != "Quota:" && NF >= 3 {
                        if (!($1 in fam)) { fam[$1] = 1; order[++n] = $1 }
                        if ($2 ~ /Weekly/ && w[$1]++ == 0) { wp[$1] = $3; wr[$1] = $4 }
                        if ($2 ~ /Five Hour/ && f[$1]++ == 0) fp[$1] = $3
                    }
                    END { for (i = 1; i <= n; i++) printf "%s\t%s\t%s\t%s\n", order[i], wp[order[i]], wr[order[i]], fp[order[i]] }
                ' "$cache" | while IFS=$'\t' read -r model wpct wreset fpct; do
                    usage="—" reset="—" items=""
                    if [ -n "$wpct" ] && [ "$wpct" != "disabled" ]; then
                        usage="$(bar_pct "${wpct%\%}") wk"
                        epoch=$(iso_to_epoch "$wreset")
                        [ -n "$epoch" ] && reset=$(format_epoch "$epoch" | sed 's/AM$/am/; s/PM$/pm/')
                    fi
                    if [ "$fpct" = "disabled" ]; then items="5h disabled"
                    elif [ -n "$fpct" ]; then items="5h $fpct"
                    fi
                    emit_row "$(pad_cols "$(truncate_cell "$model" 26)" 26)" 26 "-" "$usage" "$reset"
                    emit_detail "$items"
                done
                ;;
            codex)
                identity=$(agent_identity "$key")
                cell=$(pad_cols "$(truncate_cell "${agent}${identity:+ · $identity}" 28)" 28)
                read -r pct tag <<< "$(herdr_limit_usage "${HERDR_LIMITS[codex]:-}")"
                [ -n "$pct" ] && usage="$(bar_pct "${pct%\%}") $tag"
                emit_row "$cell" 28 "$plan" "$usage" "—"
                ;;
            grok)
                cell=$(account_cell "${ACC_LABEL[$key]}" "${ACC_EMAIL[$key]}" 26)
                # Herdr's limit is account-blind; attach it to the first account
                if [ "$id" = "$first_id" ]; then
                    read -r pct tag <<< "$(herdr_limit_usage "${HERDR_LIMITS[grok]:-}")"
                    [ -n "$pct" ] && usage="$(bar_pct "${pct%\%}") $tag"
                fi
                emit_row "$cell" 26 "$plan" "$usage" "—"
                ;;
            opencode)
                identity=$(agent_identity "$key")
                cell=$(pad_cols "$(truncate_cell "${agent}${identity:+ · $identity}" 28)" 28)
                emit_row "$cell" 28 "$plan" "—" "—"
                ;;
            kimi)
                identity=$(agent_identity "$key")
                cell=$(pad_cols "$(truncate_cell "${agent}${identity:+ · $identity}" 28)" 28)
                cache=$(quota_cache_path kimi "$id" json)
                if [ -f "$cache" ]; then
                    local pct7 reset7 pct5 pctm epoch7=""
                    IFS=$'\t' read -r pct7 reset7 pct5 pctm < <(jq -r '
                        def pct($k): (.usages[$k].used_ratio // null) as $r |
                            if $r == null then "" else "\(($r * 100) | round)%" end;
                        def rst($k): (.usages[$k].reset_time // "");
                        [pct("limit_7d"), rst("limit_7d"), pct("limit_5h"), pct("limit_month_total")] | @tsv
                    ' "$cache" 2>/dev/null)
                    [ -n "$reset7" ] && epoch7=$(iso_to_epoch "$reset7")
                    if [ -n "$pct7" ]; then
                        # the cache outlives an expired token: a window that
                        # already reset is back to 0%
                        if [ -n "$epoch7" ] && [ "$epoch7" -lt "$CURRENT_TIME" ]; then
                            pct7="0%"; epoch7=""
                        fi
                        usage="$(bar_pct "${pct7%\%}") wk"
                        [ -n "$epoch7" ] && reset=$(format_epoch "$epoch7" | sed 's/AM$/am/; s/PM$/pm/')
                    fi
                    [ -n "$pct5" ] && items="5h $pct5"
                    [ -n "$pctm" ] && items="${items:+$items · }month $pctm"
                fi
                emit_row "$cell" 28 "$plan" "$usage" "$reset"
                emit_detail "$items"
                ;;
        esac
    done <<< "$ids"
}

prev_seen=0 prev_multi=0
for agent in "${GROUP_ORDER[@]}"; do
    ids=$(awk -F'\t' -v a="$agent" '$1 == a { print $2 }' <<< "$ACC_TSV")
    [ -n "$ids" ] || continue
    out=$(render_group "$agent" "$ids")
    [ -n "$out" ] || continue
    multi=0; [ "$(grep -c '' <<< "$out")" -gt 1 ] && multi=1
    # separate blocks when either neighbor renders more than one line;
    # adjacent single-line rows (codex · …, opencode · …) stack compactly
    [ "$prev_seen" = 1 ] && { [ "$multi" = 1 ] || [ "$prev_multi" = 1 ]; } && echo ""
    printf '%s\n' "$out" | format_bars
    prev_seen=1; prev_multi=$multi
done

echo ""
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
