#!/usr/bin/env bash
# lib/quota.sh — per-account quota fetching and caching. Source AFTER
# lib/accounts.sh (reuses $IDENTITY_CACHE). All fetchers print to stdout;
# quota_store caches atomically (tmp + mv) and never clobbers a good cache
# with a failure. First-open initialization runs in parallel behind one wait;
# later refreshes are the existing stale-mtime background (& disown) pattern.

QUOTA_CACHE_ROOT="${TMPDIR:-/tmp}/herdr-agent-usage/quota"
QUOTA_TTL=300
IDENTITY_TTL=3600
QUOTA_NOW=$(date +%s)

quota_cache_path() { # <agent> <account_id> [ext=txt]
    local id=${2//\//_}
    echo "$QUOTA_CACHE_ROOT/$1/$id.${3:-txt}"
}

quota_is_fresh() { # <cache-file> [ttl=$QUOTA_TTL]
    local f=$1 ttl=${2:-$QUOTA_TTL} m
    [ -f "$f" ] || return 1
    m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null) || return 1
    [ $(( QUOTA_NOW - m )) -lt "$ttl" ]
}

quota_store() { # <agent> <account_id> <ext> <cmd...> — run cmd, cache stdout if non-empty
    local agent=$1 id=$2 ext=$3; shift 3
    local cache; cache=$(quota_cache_path "$agent" "$id" "$ext")
    mkdir -p "$(dirname "$cache")"
    local tmp; tmp=$(mktemp "${cache}.tmp.XXXXXX") || return 1
    if "$@" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        mv "$tmp" "$cache"
    else
        rm -f "$tmp"; return 1
    fi
}

# ── fetchers (stdout only; no credentials on command lines) ────────────────
quota_claude_usage_is_valid() { # reads stdin, passes through when valid
    local out; out=$(cat)
    if grep -qE '% used|Last 7d|subscription' <<<"$out"; then printf '%s' "$out"; else return 1; fi
}

quota_fetch_claude() { # <home>
    # Explicit CLAUDE_CONFIG_DIR on the implicit default home makes the CLI
    # print a result footer instead of the /usage report; only set it for
    # non-default homes and scrub it for the default.
    if [ "$1" = "$HOME/.claude" ]; then
        env -u CLAUDE_CONFIG_DIR claude -p "/usage" | quota_claude_usage_is_valid
    else
        CLAUDE_CONFIG_DIR="$1" claude -p "/usage" | quota_claude_usage_is_valid
    fi
}
quota_fetch_agy()    { agy -p "/usage" | awk -F'\t' 'NF >= 3 && $1 != "Quota:"'; }
quota_fetch_kimi() {
    local token
    token=$(jq -rs 'map(select((.expires_at // 0) > now)) | max_by(.expires_at) | .access_token // empty' \
        "$HOME/.kimi-code"/credentials/*.json 2>/dev/null)
    [ -n "$token" ] || return 1
    printf 'Authorization: Bearer %s' "$token" |
        curl -sf -m 10 -H @- "${KIMI_CODE_BASE_URL:-https://api.kimi.com/coding/v1}/usages" |
        jq -e '.usages'
}

quota_identity_cache_path() { echo "${IDENTITY_CACHE:-${TMPDIR:-/tmp}/herdr-agent-usage/identity}/claude/$1.json"; }

quota_store_claude_identity() { # <account_id> <home> — keychain-auth homes have no oauthAccount
    local cache; cache=$(quota_identity_cache_path "$1")
    mkdir -p "$(dirname "$cache")"
    local out
    # Same default-home quirk as quota_fetch_claude: explicit CLAUDE_CONFIG_DIR
    # hides the keychain login from `claude auth status`, so scrub it there too.
    if [ "$2" = "$HOME/.claude" ]; then
        out=$(env -u CLAUDE_CONFIG_DIR claude auth status 2>/dev/null) || return 1
    else
        out=$(CLAUDE_CONFIG_DIR="$2" claude auth status 2>/dev/null) || return 1
    fi
    jq -e '.loggedIn == true and (.email // "") != ""' <<<"$out" >/dev/null 2>&1 || return 1
    # mktemp only after validation, so no early return can leave a tmp file behind
    local tmp; tmp=$(mktemp "${cache}.tmp.XXXXXX") || return 1
    jq '{email: .email, subscriptionType: (.subscriptionType // "-")}' <<<"$out" > "$tmp" &&
        mv "$tmp" "$cache" || { rm -f "$tmp"; return 1; }
}

# ── dispatch (init = parallel + wait; refresh = background + disown) ────────
quota_dispatch() { # <agent> <account_id> <ext> <home>
    local agent=$1 id=$2 ext=$3 home=$4
    case "$agent" in
        claude) quota_store claude "$id" "$ext" quota_fetch_claude "$home" ;;
        agy)    quota_store agy    "$id" "$ext" quota_fetch_agy ;;
        kimi)   quota_store kimi   "$id" "$ext" quota_fetch_kimi ;;
        *)      return 1 ;;
    esac
}

quota_refresh_async() { ( quota_dispatch "$@" ) & disown; }

quota_refresh_async_identity() { # <account_id> <home> — background, 1h TTL
    local cache; cache=$(quota_identity_cache_path "$1")
    quota_is_fresh "$cache" "$IDENTITY_TTL" && return 0
    ( quota_store_claude_identity "$1" "$2" ) & disown
}

# ── claude usage rendering helpers ──────────────────────────────────────────
quota_claude_local_usage() { # <home> → "7d · N req · N sessions" from stats-cache.json
    local f="$1/stats-cache.json"
    [ -f "$f" ] || return 1
    local cutoff
    cutoff=$(date -v-7d +%Y-%m-%d 2>/dev/null || date -d '7 days ago' +%Y-%m-%d)
    jq -er --arg cutoff "$cutoff" '
        [(.dailyActivity // [])[] | select(.date >= $cutoff)] as $d |
        select(($d | length) > 0) |
        ($d | map(.messageCount // 0) | add // 0) as $req |
        ($d | map(.sessionCount // 0) | add // 0) as $sess |
        "7d · \($req) req · \($sess) sessions"
    ' "$f" 2>/dev/null
}

quota_claude_cached_usage() { # <cache-file> → usage lines from `claude -p /usage`
    [ -f "$1" ] || return 1
    {
        grep '% used' "$1" 2>/dev/null | head -n 4
        grep -oE 'Last 7d · [0-9]+ requests? · [0-9]+ sessions?' "$1" 2>/dev/null | head -n 1 |
            sed 's/^Last //'
    } | awk '!seen[$0]++' | head -n 5
}
