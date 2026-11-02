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
ok "cache path slash-safe" "$TMPDIR/herdr-agent-usage/quota/grok/https:__auth.x.ai_uuid-1.txt" \
    "$(quota_cache_path grok 'https://auth.x.ai/uuid-1')"

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
ok "local 7d summary" "7d 100 req · 5 sess" "$(quota_claude_local_usage "$HOME")"

# requests round to k ((n+500)/1000) once they pass 1000; sessions stay exact
h3="$FIX/home3"; mkdir -p "$h3"
jq -n --arg t "$today" '{dailyActivity:[{date:$t, messageCount:42444, sessionCount:17}]}' > "$h3/stats-cache.json"
ok "local 7d k rounding" "7d 42k req · 17 sess" "$(quota_claude_local_usage "$h3")"

# only stale entries → no output, nonzero exit (no-data, not "0 req")
h2="$FIX/home2"; mkdir -p "$h2"
jq -n --arg o "$old" '{dailyActivity:[{date:$o, messageCount:999, sessionCount:9}]}' > "$h2/stats-cache.json"
ok "local 7d no data" "0" "$(quota_claude_local_usage "$h2" >/dev/null && echo 1 || echo 0)"

# claude /usage cache → TSV kind/pct/reset, kinds in week/sess/fable priority;
# behavior lines ("of your usage", "Top subagents") and the 7d summary excluded
printf 'header\nCurrent session: 3%% used · resets Nov 2 at 4:20pm\nCurrent week (all models): 49%% used · resets Nov 8 at 7am\nLast 24h · 15697 requests · 6 sessions\n  98%% of your usage came from sessions active for 8+ hours\n  Top subagents: workflow-subagent 86%%\nLast 7d · 32334 requests · 20 sessions\ntrailer\n' > "$FIX/q.txt"
ok "claude quota week+sess" "week	49	Nov 8 7am
sess	3	Nov 2 4:20pm" "$(quota_claude_quota "$FIX/q.txt")"

# parenthesized timezone stripped, "at" dropped, session without reset → empty
printf 'Current session: 0%% used\nCurrent week (all models): 100%% used · resets Nov 3 at 10pm (America/Los_Angeles)\nCurrent week (Fable): 0%% used · resets Nov 3 at 10pm (America/Los_Angeles)\n' > "$FIX/q3.txt"
ok "claude quota fable/parens/no-reset" "week	100	Nov 3 10pm
sess	0	
fable	0	Nov 3 10pm" "$(quota_claude_quota "$FIX/q3.txt")"

# missing cache file → nonzero exit, no output
ok "claude quota missing cache" "0" "$(quota_claude_quota "$FIX/nope.txt" >/dev/null 2>&1 && echo 1 || echo 0)"

# agy fetch filters malformed rows (shape check before caching)
mkdir -p "$FIX/bin"
printf '#!/usr/bin/env bash\necho -e "Quota:\\theader\\nGemini Models\\tWeekly\\t100%%\\t2026-11-09T17:22:24Z\\ntruncated-row\\t%%"\n' > "$FIX/bin/agy"
chmod +x "$FIX/bin/agy"
export PATH="$FIX/bin:$PATH"
ok "agy fetch filters malformed rows" "Gemini Models	Weekly	100%	2026-11-09T17:22:24Z" "$(quota_fetch_agy)"

# all-malformed output yields nothing → no cache file is written
printf '#!/usr/bin/env bash\necho "Quota:\\tonly"\n' > "$FIX/bin/agy"
quota_store agy shape txt quota_fetch_agy 2>/dev/null
ok "agy malformed not cached" "" "$(cat "$(quota_cache_path agy shape txt)" 2>/dev/null)"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
