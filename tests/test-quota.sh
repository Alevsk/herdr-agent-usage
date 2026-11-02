#!/usr/bin/env bash
# tests/test-quota.sh — cache/TTL/store tests for lib/quota.sh using fake fetchers
set -u
cd "$(dirname "$0")/.."

PASS=0 FAIL=0
ok() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $1"; echo "  expected: [$2]"; echo "  actual:   [$3]"
    diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | sed 's/^/  /'
    fi; }

FIX=$(mktemp -d); trap 'rm -rf "$FIX"' EXIT INT TERM
export TMPDIR="$FIX/tmp"; mkdir -p "$TMPDIR"
unset CLAUDE_CONFIG_DIR CODEX_HOME || true

source lib/quota.sh

# cache path is namespaced per agent/id and slash-safe
ok "cache path" "$TMPDIR/herdr-agent-usage/quota/grok/a::b.txt" \
    "$(quota_cache_path grok 'a::b')"

# store succeeds and writes non-empty output atomically
quota_store agy default txt bash -c 'echo ok-data'
ok "store writes" "ok-data" "$(cat "$(quota_cache_path agy default txt)")"

# store rejects empty output and keeps the previous cache
touch -t 202001010000 "$(quota_cache_path agy default txt)"
quota_store agy default txt true
ok "store keeps old on empty" "ok-data" "$(cat "$(quota_cache_path agy default txt)")"

# freshness honors TTL
ok "stale after touch" "0" "$(quota_is_fresh "$(quota_cache_path agy default txt)" && echo 1 || echo 0)"
quota_store agy default txt bash -c 'echo ok-data'
ok "fresh after write" "1" "$(quota_is_fresh "$(quota_cache_path agy default txt)" && echo 1 || echo 0)"

# local claude 7d summary from stats-cache.json
mkdir -p "$FIX/home"
export HOME="$FIX/home"
today=$(date +%Y-%m-%d); old=$(date -v-8d +%Y-%m-%d 2>/dev/null || date -d '8 days ago' +%Y-%m-%d)
jq -n --arg t "$today" --arg o "$old" '{dailyActivity:[
    {date:$t, messageCount:100, sessionCount:5},
    {date:$o, messageCount:999, sessionCount:9}]}' > "$HOME/stats-cache.json"
ok "local 7d summary" "7d · 100 req · 5 sessions" "$(quota_claude_local_usage "$HOME")"

# cached /usage text extraction
printf 'header\nLast 7d · 32334 requests · 20 sessions\ntrailer\n' > "$FIX/q.txt"
ok "cached usage line" "7d · 32334 requests · 20 sessions" "$(quota_claude_cached_usage "$FIX/q.txt")"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
