#!/usr/bin/env bash
# lib/provider.sh — adapter contract the dashboard calls.
#
# A provider is a set of functions. The renderer asks the dispatcher; it does
# not grow a new branch per agent. Drop in lib/providers/<id>.sh (sourced by
# usage.sh) and define whichever of these apply:
#
#   provider_<id>_live_context <session> <cwd>
#       Print "⛁ N% (Nk)" or "⛁ Nk". Return 1 when unknown.
#   provider_<id>_quota_ext
#       Cache extension. json when this is unset.
#   provider_<id>_quota_fetch <account_id> <home>
#       Print the cache body on stdout. Keep credentials off argv.
#       Return 1 on failure (nothing is cached).
#   provider_<id>_quota_rows <cache-file>
#       Print TSV rows: label, used percent (integer), reset epoch seconds.
#
# Names are resolved at call time, so provider files may be sourced after this.

provider_short_tokens() {
    if [ "$1" -ge 1000 ]; then printf '%sk' "$(( ($1 + 500) / 1000 ))"
    else printf '%s' "$1"; fi
}

# Same rounding as the Claude/Codex context cells: half up, then "58k".
provider_format_context() { # <used-tokens> <window-or-empty>
    local used=$1 window=$2
    if [[ $window =~ ^[0-9]+$ ]] && [ "$window" -gt 0 ]; then
        printf '⛁ %s%% (%s)\n' "$(( (used * 100 + window / 2) / window ))" "$(provider_short_tokens "$used")"
    else
        printf '⛁ %s\n' "$(provider_short_tokens "$used")"
    fi
}

provider_live_context() { # <agent> <session> <cwd>
    local fn="provider_${1}_live_context"
    declare -F "$fn" >/dev/null || return 1
    "$fn" "$2" "$3"
}

provider_has_quota() { # <agent> — true when both fetch and rows exist
    declare -F "provider_${1}_quota_fetch" >/dev/null &&
        declare -F "provider_${1}_quota_rows" >/dev/null
}

provider_quota_ext() { # <agent>
    local fn="provider_${1}_quota_ext"
    if declare -F "$fn" >/dev/null; then "$fn"
    else printf 'json\n'; fi
}

provider_quota_fetch() { # <agent> <account_id> <home>
    local fn="provider_${1}_quota_fetch"
    declare -F "$fn" >/dev/null || return 1
    "$fn" "$2" "$3"
}

provider_quota_rows() { # <agent> <cache-file>
    local fn="provider_${1}_quota_rows"
    declare -F "$fn" >/dev/null || return 1
    "$fn" "$2"
}
