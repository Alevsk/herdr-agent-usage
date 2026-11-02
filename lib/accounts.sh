#!/usr/bin/env bash
# lib/accounts.sh — account registry: discovery, identity resolution, pane
# attribution. Sourced by usage.sh (after which the CLI guard is inert); also
# directly runnable:
#   lib/accounts.sh list
#   lib/accounts.sh resolve <agent> <session-id | cwd>
#
# `list` prints one TSV line per account:
#   agent, account_id, label, email, plan, home
#
# An account exists iff a candidate directory holds agent state (.claude.json
# or projects/ for claude, auth.json for codex) — ~/.claude-mem style dirs are
# excluded structurally. Identity (email/plan) is read from local files only;
# for claude homes whose credentials live in the macOS keychain (no
# oauthAccount on disk) it falls back to the identity cache written by
# lib/quota.sh from `claude auth status`.

ACCOUNTS_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/herdr-agent-usage/accounts.conf"
IDENTITY_CACHE="${TMPDIR:-/tmp}/herdr-agent-usage/identity"

# ── optional overrides (INI-style, awk-parsed) ──────────────────────────────
# accounts_conf <agent> prints "action<TAB>key<TAB>value" lines (key empty for
# exclude). Absent file → no output, no subprocesses.
accounts_conf() {
    local agent=$1
    [ -f "$ACCOUNTS_CONF" ] || return 0
    awk -v agent="$agent" '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        /^[ \t]*[#;]/ { next }
        /^[ \t]*\[/ { sec = $0; gsub(/[][ \t]/, "", sec); insec = (tolower(sec) == tolower(agent)); next }
        insec && "=" {
            k = trim(substr($0, 1, index($0, "=") - 1))
            v = trim(substr($0, index($0, "=") + 1))
            split(k, ka, ".")
            if (ka[1] == "exclude") print "exclude\t\t" v
            else if (ka[1] == "rename") print "rename\t" ka[2] "\t" v
            else if (ka[1] == "extra") print "extra\t" ka[2] "\t" v
        }
    ' "$ACCOUNTS_CONF"
}

accounts_conf_label() { # <agent> <account_id> <label> → overridden label or nothing
    accounts_conf "$1" | awk -F'\t' -v id="$2" -v label="$3" '
        $1 == "rename" && ($2 == id || $2 == label) { print $3 }'
}

accounts_conf_excluded() { # <agent> <account_id> → "1" if excluded
    accounts_conf "$1" | awk -F'\t' -v id="$2" '$1 == "exclude" {
        n = split($3, ids, /[ \t]*,[ \t]*/)
        for (i = 1; i <= n; i++) if (ids[i] == id) { print "1"; exit }
    }'
}

accounts_conf_extras() { # <agent> → extra home paths, one per line (~ expanded)
    accounts_conf "$1" | awk -F'\t' '$1 == "extra" { print $3 }' |
        while IFS= read -r p; do echo "${p/#\~/$HOME}"; done
}

accounts_extra_label() { # <agent> <home> → conf key naming this extra home, or nothing
    accounts_conf "$1" | awk -F'\t' -v home="$2" -v h="$HOME" '
        $1 == "extra" {
            p = $3; sub(/^~/, h, p); sub(/\/+$/, "", p)
            if (p == home) { print $2; exit }
        }'
}

# ── emit ────────────────────────────────────────────────────────────────────
accounts_dir_label() { # <agent> <home-basename> → "default" or dir suffix
    if [ "$2" = ".$1" ]; then echo default; else echo "${2#.$1-}"; fi
}

accounts_email_label() { echo "${1%%@*}"; }

# emit_account <agent> <account_id> <label> <email> <plan> <home>
emit_account() {
    local agent=$1 id=$2 label=$3 over
    [ -n "$(accounts_conf_excluded "$agent" "$id")" ] && return 0
    over=$(accounts_conf_label "$agent" "$id" "$label")
    [ -n "$over" ] && label=$over
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$agent" "$id" "$label" "$4" "$5" "$6"
}

# ── JWT (codex) ─────────────────────────────────────────────────────────────
accounts_jwt_payload() { # <jwt> → decoded payload JSON
    local payload=${1#*.}; payload=${payload%%.*}
    local pad=$(( ${#payload} % 4 ))
    [ "$pad" -eq 2 ] && payload+="=="
    [ "$pad" -eq 3 ] && payload+="="
    printf '%s' "$payload" | tr '_-' '/+' |
        { base64 -d 2>/dev/null || base64 -D 2>/dev/null; }
}

# ── candidate homes (env override, default base, sibling glob, conf extras) ─
accounts_candidate_homes() { # <agent> <env_var> → one home path per line, deduped
    local agent=$1 env_var=$2 dir
    local -a seen=()
    for dir in "${!env_var}" "$HOME/.$agent" "$HOME/.$agent"-*; do
        [ -n "${dir:-}" ] && [ -d "$dir" ] || continue
        local dup=0 s
        for s in "${seen[@]:-}"; do [ "$s" = "$dir" ] && dup=1 && break; done
        [ "$dup" -eq 0 ] && seen+=("$dir")
    done
    while IFS= read -r dir; do
        [ -n "$dir" ] && [ -d "$dir" ] || continue
        local dup=0 s
        for s in "${seen[@]:-}"; do [ "$s" = "$dir" ] && dup=1 && break; done
        [ "$dup" -eq 0 ] && seen+=("$dir")
    done < <(accounts_conf_extras "$agent")
    printf '%s\n' "${seen[@]:-}"
}

# ── per-agent listers ───────────────────────────────────────────────────────
accounts_list_claude() {
    local -a dirs=() jfiles=()
    local dir file email plan b label
    while IFS= read -r dir; do
        [ -f "$dir/.claude.json" ] || [ -d "$dir/projects" ] || continue
        dirs+=("$dir")
        [ -f "$dir/.claude.json" ] && jfiles+=("$dir/.claude.json")
    done < <(accounts_candidate_homes claude CLAUDE_CONFIG_DIR)
    [ ${#dirs[@]} -gt 0 ] || return 0
    local -A email_of=() plan_of=()
    if [ ${#jfiles[@]} -gt 0 ]; then
        while IFS=$'\t' read -r file email plan; do
            email_of["$file"]=$email; plan_of["$file"]=$plan
        done < <(jq -r '
            (.oauthAccount // {}) as $oa |
            select(($oa.emailAddress // "") != "") |
            [input_filename, $oa.emailAddress, ($oa.seatTier // $oa.organizationName // "-")] | @tsv
        ' "${jfiles[@]}" 2>/dev/null)
    fi
    for dir in "${dirs[@]}"; do
        b=$(basename "$dir"); email="-"; plan="-"
        file="$dir/.claude.json"
        if [ -n "${email_of[$file]:-}" ]; then
            email=${email_of[$file]}; plan=${plan_of[$file]}
        elif [ -f "$IDENTITY_CACHE/claude/$b.json" ]; then
            email=$(jq -r '.email // "-"' "$IDENTITY_CACHE/claude/$b.json" 2>/dev/null)
            plan=$(jq -r '.subscriptionType // "-"' "$IDENTITY_CACHE/claude/$b.json" 2>/dev/null)
        fi
        label=$(accounts_extra_label claude "$dir"); [ -n "$label" ] || label=$(accounts_dir_label claude "$b")
        emit_account claude "$b" "$label" "$email" "$plan" "$dir"
    done
}

accounts_list_codex() {
    local file token payload email plan dir b label
    while IFS=$'\t' read -r file token; do
        [ -n "$token" ] || continue
        payload=$(accounts_jwt_payload "$token")
        [ -n "$payload" ] || continue
        IFS=$'\t' read -r email plan < <(jq -r '
            [.email // "-", (."https://api.openai.com/auth".chatgpt_plan_type // "-")] | @tsv
        ' <<<"$payload" 2>/dev/null)
        dir=$(dirname "$file"); b=$(basename "$dir")
        label=$(accounts_extra_label codex "$dir"); [ -n "$label" ] || label=$(accounts_dir_label codex "$b")
        emit_account codex "$b" "$label" "$email" "$plan" "$dir"
    done < <(accounts_candidate_homes codex CODEX_HOME |
        while IFS= read -r d; do
            [ -f "$d/auth.json" ] || continue
            jq -r '[input_filename, (.tokens.id_token // "")] | @tsv' "$d/auth.json" 2>/dev/null
        done)
}

accounts_list_grok() {
    local f="$HOME/.grok/auth.json" key email tier
    [ -f "$f" ] || return 0
    while IFS=$'\t' read -r key email tier; do
        [ -n "$email" ] || continue
        emit_account grok "$key" "$(accounts_email_label "$email")" "$email" \
            "$([ -n "$tier" ] && echo "tier $tier" || echo "-")" "$HOME/.grok"
    done < <(jq -r 'to_entries[] |
        [.key, (.value.email // ""), ((.value.tier // "") | tostring)] | @tsv' "$f" 2>/dev/null)
}

accounts_list_agy() {
    local f="$HOME/.gemini/google_accounts.json" email
    [ -f "$f" ] || return 0
    email=$(jq -r '.active // empty' "$f" 2>/dev/null)
    [ -n "$email" ] || return 0
    emit_account agy default default "$email" "-" "$HOME/.gemini"
}

accounts_list_opencode() {
    local f="$HOME/.local/share/opencode/auth.json" key
    [ -f "$f" ] || return 0
    while IFS= read -r key; do
        emit_account opencode "$key" "$key" "-" "-" "$HOME/.config/opencode"
    done < <(jq -r 'to_entries[] | select(.key != null) | .key' "$f" 2>/dev/null)
}

accounts_list_kimi() {
    [ -d "$HOME/.kimi-code/credentials" ] || return 0
    emit_account kimi default default "-" "-" "$HOME/.kimi-code"
}

accounts_list() {
    local agent
    for agent in claude agy codex grok opencode kimi; do
        "accounts_list_$agent"
    done
}

# ── pane attribution ────────────────────────────────────────────────────────
accounts_claude_transcript() { # <session-id> → transcript path across homes
    local session=$1 dir f
    [ -n "$session" ] && [ "$session" != "-" ] || return 0
    while IFS= read -r dir; do
        for f in "$dir/projects/"*/"$session.jsonl"; do
            [ -f "$f" ] && { echo "$f"; return 0; }
        done
    done < <(accounts_candidate_homes claude CLAUDE_CONFIG_DIR)
    return 0
}

accounts_resolve_claude() { # <session-id> → owning account_id
    local t; t=$(accounts_claude_transcript "$1")
    [ -n "$t" ] || return 0
    basename "$(dirname "$(dirname "$(dirname "$t")")")"   # projects/<proj>/<sess>.jsonl
}

accounts_codex_rollout() { # <cwd> → newest matching rollout across homes
    local cwd=$1 dir file nf=""
    [ -n "$cwd" ] && [ "$cwd" != "-" ] || return 0
    while IFS= read -r dir; do
        [ -d "$dir/sessions" ] || continue
        while IFS= read -r -d '' file; do
            head -n 1 "$file" | grep -qF "\"cwd\":\"$cwd\"" || continue
            [ -z "$nf" ] || [ "$file" -nt "$nf" ] || continue
            nf=$file
        done < <(find "$dir/sessions" -type f -name 'rollout-*.jsonl' -mtime -7 -print0 2>/dev/null)
    done < <(accounts_candidate_homes codex CODEX_HOME)
    [ -n "$nf" ] && echo "$nf"
    return 0
}

accounts_resolve_codex() { # <cwd> → owning account_id
    local r; r=$(accounts_codex_rollout "$1")
    [ -n "$r" ] || return 0
    basename "$(dirname "$(dirname "$(dirname "$(dirname "$(dirname "$r")")")")")"  # sessions/Y/M/D/rollout → home needs 5 dirnames
}

accounts_resolve() { # <agent> <session-id | cwd> → account_id (empty if unknown)
    case "$1" in
        claude) accounts_resolve_claude "$2" ;;
        codex)  accounts_resolve_codex "$2" ;;
        *)      return 0 ;;
    esac
}

# ── CLI guard (inert when sourced) ──────────────────────────────────────────
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        list)    accounts_list ;;
        resolve) accounts_resolve "${2:-}" "${3:-}" ;;
        *) echo "usage: lib/accounts.sh {list | resolve <agent> <session-id|cwd>}" >&2; exit 2 ;;
    esac
fi
