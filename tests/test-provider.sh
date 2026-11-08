#!/usr/bin/env bash
# tests/test-provider.sh — provider adapter contract and the OpenCode adapter.
# No network: quota fetch is a fake curl, context is a temp sqlite database.
set -u
cd "$(dirname "$0")/.."

PASS=0 FAIL=0
ok() { # ok <name> <expected> <actual>
    if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else
        FAIL=$((FAIL+1)); echo "FAIL: $1"
        echo "  expected: [$2]"; echo "  actual:   [$3]"
        diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | sed 's/^/  /'
    fi
}

FIX=$(mktemp -d); trap 'rm -rf "$FIX"' EXIT INT TERM
export HOME="$FIX/home"
export TMPDIR="$FIX/tmp"
mkdir -p "$HOME" "$TMPDIR" "$FIX/bin"
unset OPENCODE_DB OPENCODE_MODELS OPENCODE_AUTH || true

source lib/quota.sh
source lib/provider.sh
source lib/providers/opencode.sh

# ── dispatcher finds hooks by name, and ignores agents that have none ───────
provider_kimi_live_context() { printf 'kimi:%s:%s\n' "$1" "$2"; }
provider_kimi_quota_fetch() { printf '%s' '{"ok":true}'; }
provider_kimi_quota_rows() { printf 'week\t10\t\n'; }

ok "dispatch live context" "kimi:ses:/tmp/proj" \
    "$(provider_live_context kimi ses /tmp/proj)"
ok "unknown live context" "1" \
    "$(provider_live_context nope ses /tmp/proj >/dev/null 2>&1; echo $?)"
ok "adapter has quota" "1" "$(provider_has_quota kimi && echo 1 || echo 0)"
ok "bare agent has no quota" "0" "$(provider_has_quota claude && echo 1 || echo 0)"
ok "default quota ext" "json" "$(provider_quota_ext kimi)"
ok "opencode quota ext" "json" "$(provider_quota_ext opencode)"

# ── OpenCode session context (latest assistant turn, not session totals) ────
DB="$FIX/opencode.db"
MODELS="$FIX/models.json"
export OPENCODE_DB="$DB" OPENCODE_MODELS="$MODELS"
sqlite3 "$DB" <<'SQL'
CREATE TABLE session_v2 (
  id text PRIMARY KEY,
  directory text NOT NULL,
  parent_id text,
  model text,
  time_updated integer NOT NULL,
  tokens_input integer DEFAULT 0,
  tokens_cache_read integer DEFAULT 0
);
CREATE TABLE session_message (
  id text PRIMARY KEY,
  session_id text NOT NULL,
  type text NOT NULL,
  seq integer NOT NULL,
  data text NOT NULL
);
INSERT INTO session_v2 VALUES
  ('ses_old', '/work/app', NULL, '{"id":"glm-5.3","providerID":"zai-coding-plan"}', 1, 0, 0),
  ('ses_live', '/work/app', NULL, '{"id":"glm-5.3","providerID":"zai-coding-plan"}', 10, 54619, 288000),
  ('ses_child', '/work/app', 'ses_live', '{"id":"glm-5.3","providerID":"zai-coding-plan"}', 99, 0, 0),
  ('ses_other', '/work/other', '', '{"id":"small","providerID":"zai"}', 5, 99999, 0),
  ('ses_quote', '/work/it''s', NULL, '{"id":"quote-model","providerID":"zai-coding-plan"}', 3, 0, 0);
INSERT INTO session_message VALUES
  ('m1', 'ses_old', 'assistant', 1, '{"tokens":{"input":100,"cache":{"read":0,"write":0}}}'),
  ('m2', 'ses_live', 'assistant', 1, '{"tokens":{"input":1,"cache":{"read":0,"write":0}}}'),
  ('m3', 'ses_live', 'assistant', 2, '{"tokens":{"input":920,"output":971,"reasoning":19,"cache":{"read":57024,"write":0}}}'),
  ('m4', 'ses_live', 'user', 3, '{"tokens":{"input":999999,"cache":{"read":0,"write":0}}}'),
  ('m5', 'ses_child', 'assistant', 1, '{"tokens":{"input":500000,"cache":{"read":0,"write":0}}}'),
  ('m6', 'ses_other', 'assistant', 1, '{"tokens":{"input":50000,"cache":{"read":0,"write":0}}}'),
  ('m7', 'ses_quote', 'assistant', 1, '{"tokens":{"input":1000,"cache":{"read":0,"write":0}}}');
SQL
jq -n '{
  "zai-coding-plan": {"models": {
    "glm-5.3": {"limit": {"context": 1000000}},
    "quote-model": {"limit": {"context": 10000}}
  }},
  "zai": {"models": {"small": {"limit": {"context": 100000}}}}
}' > "$MODELS"

ok "context from newest root session" "⛁ 6% (58k)" \
    "$(provider_opencode_live_context - /work/app)"
ok "session id wins over directory" "⛁ 50% (50k)" \
    "$(provider_opencode_live_context ses_other /work/app)"
ok "directory quote is escaped" "⛁ 10% (1k)" \
    "$(provider_opencode_live_context - "/work/it's")"
# The catalog is megabytes. Once a window is cached, a later open must not
# need to read it again. Changing the file (below) still drops the cache.
chmod 000 "$MODELS"
ok "context reuses cached window" "⛁ 6% (58k)" \
    "$(provider_opencode_live_context - /work/app)"
chmod 644 "$MODELS"
ok "missing session id does not fall back" "1" \
    "$(provider_opencode_live_context ses_missing /work/app >/dev/null; echo $?)"
ok "no assistant message" "1" \
    "$(sqlite3 "$DB" "DELETE FROM session_message WHERE session_id='ses_other'";
       provider_opencode_live_context ses_other /work/other >/dev/null; echo $?)"

# window unknown → tokens only, still not the session-total column
jq -n '{}' > "$MODELS"
ok "context without window" "⛁ 58k" \
    "$(provider_opencode_live_context - /work/app)"
jq -n '{
  "zai-coding-plan": {"models": {
    "glm-5.3": {"limit": {"context": 1000000}},
    "quote-model": {"limit": {"context": 10000}}
  }},
  "zai": {"models": {"small": {"limit": {"context": 100000}}}}
}' > "$MODELS"

ok "missing database" "1" \
    "$(OPENCODE_DB=$FIX/nope.db provider_opencode_live_context - /work/app >/dev/null; echo $?)"

# dispatcher reaches the OpenCode hook
ok "dispatch opencode context" "⛁ 6% (58k)" \
    "$(provider_live_context opencode - /work/app)"

# ── quota rows: used percent, 5h then week, ms reset, skip other windows ───
# Week is listed first on purpose. CREDIT_LIMIT is the current z.ai type;
# TOKENS_LIMIT is the older one. Both count. TIME_LIMIT and unknown windows do not.
cat > "$FIX/quota.json" <<'JSON'
{"code":200,"data":{"level":"pro","limits":[
  {"type":"TIME_LIMIT","percentage":99,"unit":1,"number":1,"nextResetTime":1700000000000},
  {"type":"CREDIT_LIMIT","percentage":12.2,"unit":6,"number":1,"nextResetTime":1700003600000},
  {"type":"TOKENS_LIMIT","percentage":40.5,"unit":3,"number":5,"nextResetTime":1700000000000},
  {"type":"CREDIT_LIMIT","percentage":80,"unit":3,"number":1,"nextResetTime":1}
]}}
JSON
ok "quota rows 5h then week" "5h	41	1700000000
week	12	1700003600" "$(provider_opencode_quota_rows "$FIX/quota.json")"
ok "quota rows via dispatch" "5h	41	1700000000
week	12	1700003600" "$(provider_quota_rows opencode "$FIX/quota.json")"
ok "quota rows missing file" "1" \
    "$(provider_opencode_quota_rows "$FIX/nope.json" >/dev/null 2>&1; echo $?)"

ok "zai quota url" "https://api.z.ai/api/monitor/usage/quota/limit" \
    "$(provider_opencode_quota_url zai-coding-plan)"
ok "zai alias url" "https://api.z.ai/api/monitor/usage/quota/limit" \
    "$(provider_opencode_quota_url z.ai)"
ok "zhipu quota url" "https://open.bigmodel.cn/api/monitor/usage/quota/limit" \
    "$(provider_opencode_quota_url zhipuai)"
ok "unknown quota url" "1" \
    "$(provider_opencode_quota_url openai >/dev/null 2>&1; echo $?)"

# ── fetch: raw Authorization header, fake curl, no cache on a bad body ─────
export CURL_LOG="$FIX/curl-headers" CURL_URL="$FIX/curl-url" CURL_BODY="$FIX/curl-body"
cat > "$FIX/bin/curl" <<'EOF'
#!/usr/bin/env bash
url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -sf) shift ;;
        -m) shift 2 ;;
        -H)
            shift
            if [ "$1" = "@-" ]; then cat > "$CURL_LOG"; fi
            shift
            ;;
        *) url=$1; shift ;;
    esac
done
printf '%s' "$url" > "$CURL_URL"
cat "$CURL_BODY"
EOF
chmod +x "$FIX/bin/curl"
export PATH="$FIX/bin:$PATH"

AUTH="$FIX/auth.json"
export OPENCODE_AUTH="$AUTH"
jq -n '{"zai-coding-plan":{"type":"api","key":"test-key"},"zhipuai":{"apiKey":"cn-key"}}' > "$AUTH"
cp "$FIX/quota.json" "$CURL_BODY"

got=$(provider_opencode_quota_fetch zai-coding-plan "$HOME/.config/opencode")
ok "fetch returns body" "$(cat "$FIX/quota.json")" "$got"
ok "fetch url" "https://api.z.ai/api/monitor/usage/quota/limit" "$(cat "$CURL_URL")"
ok "fetch auth header" "Authorization: test-key
Accept-Language: en-US,en" "$(cat "$CURL_LOG")"
ok "fetch is not bearer" "0" "$(grep -c 'Bearer' "$CURL_LOG")"

printf '%s' '{"error":"nope"}' > "$CURL_BODY"
ok "fetch rejects bad body" "1" \
    "$(provider_opencode_quota_fetch zai-coding-plan "$HOME" >/dev/null; echo $?)"
ok "unknown provider does not curl" "1" \
    "$(rm -f "$CURL_URL"; provider_opencode_quota_fetch openai "$HOME" >/dev/null; echo $?)"
ok "unknown provider left no url" "" "$(cat "$CURL_URL" 2>/dev/null)"

# quota_dispatch caches a good body and keeps it when the next fetch fails
cp "$FIX/quota.json" "$CURL_BODY"
quota_dispatch opencode zai-coding-plan json "$HOME/.config/opencode"
cache=$(quota_cache_path opencode zai-coding-plan json)
ok "dispatch caches quota" "$(cat "$FIX/quota.json")" "$(cat "$cache")"
printf '%s' '{"error":"nope"}' > "$CURL_BODY"
quota_dispatch opencode zai-coding-plan json "$HOME/.config/opencode" || true
ok "dispatch keeps cache on failure" "$(cat "$FIX/quota.json")" "$(cat "$cache")"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
