#!/usr/bin/env bash
# lib/providers/opencode.sh — OpenCode adapter.
#
# Context comes from the local sqlite database (session_v2 + the latest
# assistant row in session_message), not from session-total columns and not
# from `opencode stats`. The window is models.json for that session's model.
#
# Plan quota is the Z.ai / Zhipu monitor endpoint. `percentage` is already
# usage, so it is not inverted. Only the 5h and weekly token windows are rows.
# The key is sent as `Authorization: <raw key>` (not Bearer) on curl's stdin.

provider_opencode_db() {
    if [ -n "${OPENCODE_DB:-}" ]; then printf '%s' "$OPENCODE_DB"
    else printf '%s' "$HOME/.local/share/opencode/opencode.db"; fi
}

provider_opencode_models() {
    if [ -n "${OPENCODE_MODELS:-}" ]; then printf '%s' "$OPENCODE_MODELS"
    else printf '%s' "${XDG_CACHE_HOME:-$HOME/.cache}/opencode/models.json"; fi
}

provider_opencode_auth_file() {
    if [ -n "${OPENCODE_AUTH:-}" ]; then printf '%s' "$OPENCODE_AUTH"
    else printf '%s' "$HOME/.local/share/opencode/auth.json"; fi
}

# Single-quoted SQL literal. Session ids and working directories are not trusted.
provider_opencode_sql_quote() {
    local s=$1
    s=${s//\'/\'\'}
    printf "'%s'" "$s"
}

provider_opencode_quota_ext() { printf 'json\n'; }

# Global coding-plan hosts vs the CN host. Anything else has no quota endpoint.
provider_opencode_quota_url() { # <provider-id>
    case "$1" in
        zai-coding-plan|zai|z-ai|z.ai)
            printf '%s\n' "https://api.z.ai/api/monitor/usage/quota/limit" ;;
        zhipu|zhipuai)
            printf '%s\n' "https://open.bigmodel.cn/api/monitor/usage/quota/limit" ;;
        *) return 1 ;;
    esac
}

provider_opencode_api_key() { # <auth.json> <provider-id>
    jq -er --arg id "$2" '
        (.[$id] // {}) | .apiKey // .api_key // .token // .key // .accessToken // .auth_token // empty
    ' "$1"
}

# models.json is the full provider catalog (megabytes). Keep the one integer
# this pane needs, keyed by the catalog's mtime and size, so the next open
# does not parse the file again. A replaced catalog misses the cache.
provider_opencode_window() { # <provider> <model>
    local provider=$1 model=$2 models stamp size cache window tmp
    [ -n "$provider" ] && [ -n "$model" ] || return 0
    models=$(provider_opencode_models)
    [ -f "$models" ] || return 0
    stamp=$(stat -c %Y "$models" 2>/dev/null || stat -f %m "$models" 2>/dev/null) || return 0
    size=$(stat -c %s "$models" 2>/dev/null || stat -f %z "$models" 2>/dev/null) || return 0
    if [[ $provider =~ ^[A-Za-z0-9._+-]+$ && $model =~ ^[A-Za-z0-9._+-]+$ ]]; then
        cache="${TMPDIR:-/tmp}/herdr-agent-usage/opencode-window/${stamp}-${size}/${provider}/${model}"
        if [ -f "$cache" ]; then cat "$cache"; return 0; fi
    fi
    window=$(jq -r --arg p "$provider" --arg m "$model" '.[$p].models[$m].limit.context // empty' "$models" 2>/dev/null) || window=""
    if [ -n "${cache:-}" ] && mkdir -p "$(dirname "$cache")" 2>/dev/null; then
        # Write aside then rename so a second dashboard open never reads a partial integer.
        tmp=$(mktemp "${cache}.XXXXXX") && printf '%s' "$window" > "$tmp" && mv -f "$tmp" "$cache" || rm -f "$tmp"
    fi
    printf '%s' "$window"
}

provider_opencode_live_context() { # <session> <cwd>
    local session=$1 cwd=$2 db idexpr used provider model window=""
    command -v sqlite3 >/dev/null 2>&1 || return 1
    db=$(provider_opencode_db)
    [ -f "$db" ] || return 1

    # Herdr's session id wins when it is an OpenCode id. Otherwise the newest
    # root session (no parent) whose directory is the pane cwd. One read-only
    # query: the latest assistant turn only, not the session-total columns and
    # not the rest of the message body.
    if [[ $session == ses_* ]]; then
        idexpr=$(provider_opencode_sql_quote "$session")
    elif [ -n "$cwd" ] && [ "$cwd" != "-" ]; then
        idexpr="SELECT id FROM session_v2 WHERE directory = $(provider_opencode_sql_quote "$cwd") AND (parent_id IS NULL OR parent_id = '') ORDER BY time_updated DESC LIMIT 1"
    else
        return 1
    fi
    IFS=$'\t' read -r used provider model < <(sqlite3 -readonly -separator $'\t' "$db" \
        "SELECT ifnull(json_extract(m.data,'$.tokens.input'),0) + ifnull(json_extract(m.data,'$.tokens.cache.read'),0) + ifnull(json_extract(m.data,'$.tokens.cache.write'),0), ifnull(json_extract(s.model,'$.providerID'),''), ifnull(json_extract(s.model,'$.id'),'') FROM session_v2 s JOIN session_message m ON m.session_id = s.id AND m.type = 'assistant' WHERE s.id = ($idexpr) ORDER BY m.seq DESC LIMIT 1" 2>/dev/null) || return 1
    [[ $used =~ ^[0-9]+$ ]] || return 1
    window=$(provider_opencode_window "$provider" "$model")
    provider_format_context "$used" "$window"
}

# <home> is the account config dir from the registry. The key is not stored there.
provider_opencode_quota_fetch() { # <account_id> <home>
    local id=$1 home=$2 url key authf body
    : "$home"
    url=$(provider_opencode_quota_url "$id") || return 1
    authf=$(provider_opencode_auth_file)
    [ -f "$authf" ] || return 1
    key=$(provider_opencode_api_key "$authf" "$id" 2>/dev/null) || return 1
    [ -n "$key" ] || return 1
    # -H @- reads the header lines from stdin, so the key never lands in argv.
    body=$(printf 'Authorization: %s\nAccept-Language: en-US,en\n' "$key" |
        curl -sf -m 10 -H @- "$url") || return 1
    jq -e '.data.limits | type == "array"' <<<"$body" >/dev/null || return 1
    printf '%s\n' "$body"
}

# percentage is used, already. 5h is unit 3 / number 5; week is unit 6 / number 1.
# CREDIT_LIMIT replaced TOKENS_LIMIT on the same windows; other types are not plan rows.
provider_opencode_quota_rows() { # <cache-file>
    [ -f "$1" ] || return 1
    jq -er '
        [ .data.limits[]?
          | select(.type == "TOKENS_LIMIT" or .type == "CREDIT_LIMIT")
          | select((.unit == 3 and .number == 5) or (.unit == 6 and .number == 1))
          | {
              label: (if .unit == 3 then "5h" else "week" end),
              pct: (
                ((.percentage // 0) | tonumber) as $n
                | ((if $n < 0 then 0 elif $n > 100 then 100 else $n end) + 0.5 | floor)
              ),
              reset: (if .nextResetTime == null then "" else (.nextResetTime / 1000 | floor | tostring) end)
            }
        ]
        | sort_by(if .label == "5h" then 0 else 1 end)
        | .[]
        | [.label, (.pct | tostring), .reset]
        | @tsv
    ' "$1"
}
