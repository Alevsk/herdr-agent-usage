#!/usr/bin/env bash
# tests/test-accounts.sh — fixture-driven tests for lib/accounts.sh
# Run: bash tests/test-accounts.sh   (from the plugin root or anywhere)
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
H="$FIX/home";  mkdir -p "$H"
export HOME="$H"
export XDG_CONFIG_HOME="$FIX/config"
export TMPDIR="$FIX/tmp"; mkdir -p "$TMPDIR"     # isolates identity/quota cache roots
unset CLAUDE_CONFIG_DIR CODEX_HOME || true

# ── fixtures ────────────────────────────────────────────────────────────────
mkdir -p "$H/.claude/projects/p0"                      # default home, oauth identity
jq -n '{oauthAccount:{emailAddress:"alevsk.8772@gmail.com", seatTier:"max5"}}' \
    > "$H/.claude/.claude.json"

mkdir -p "$H/.claude-lenin"                            # no oauthAccount → identity cache fallback
jq -n '{firstInstall:true}' > "$H/.claude-lenin/.claude.json"
mkdir -p "${TMPDIR}/herdr-agent-usage/identity/claude"
jq -n '{email:"lenin@alevsk.com", subscriptionType:"pro"}' \
    > "${TMPDIR}/herdr-agent-usage/identity/claude/.claude-lenin.json"

mkdir -p "$H/.claude-work/projects/projA"              # oauth identity + transcript for resolve
jq -n '{oauthAccount:{emailAddress:"alevsk@websec.mx", seatTier:"team_standard"}}' \
    > "$H/.claude-work/.claude.json"
echo '{"type":"assistant"}' > "$H/.claude-work/projects/projA/sess-work.jsonl"

mkdir -p "$H/.claude-mem"                              # NOT an account (no .claude.json, no projects/)
echo '{}' > "$H/.claude-mem/settings.json"

mkdir -p "$H/custom-claude"                            # extra home via conf
jq -n '{oauthAccount:{emailAddress:"custom@x.dev", seatTier:"pro"}}' \
    > "$H/custom-claude/.claude.json"

mkdir -p "$H/.codex/sessions/2026/11/02"               # codex home with JWT identity
PAYLOAD='{"email":"a@openai.com","https://api.openai.com/auth":{"chatgpt_plan_type":"pro"}}'
B64=$(printf '%s' "$PAYLOAD" | jq -sRr @base64 | tr '/+' '_-' | tr -d '=')
jq -n --arg t "h.$B64.s" '{tokens:{id_token:$t}}' > "$H/.codex/auth.json"
printf '{"cwd":"%s","session_id":"s1"}\n' "$H/proj" > "$H/.codex/sessions/2026/11/02/rollout-1.jsonl"

mkdir -p "$H/.grok"
jq -n '{ "https://auth.x.ai::uuid-1": {email:"alevsk8772@gmail.com", tier:1},
         "https://auth.x.ai::uuid-2": {email:"other@x.ai", tier:2} }' > "$H/.grok/auth.json"

mkdir -p "$H/.gemini"
jq -n '{active:"aguy@gmail.com"}' > "$H/.gemini/google_accounts.json"
mkdir -p "$H/.local/share/opencode"
jq -n '{"zai-coding-plan":{type:"api", key:"k"}}' > "$H/.local/share/opencode/auth.json"
mkdir -p "$H/.kimi-code/credentials"

mkdir -p "$XDG_CONFIG_HOME/herdr-agent-usage"
cat > "$XDG_CONFIG_HOME/herdr-agent-usage/accounts.conf" <<EOF
[claude]
rename.work = W3B
rename..claude-lenin = Lenin
extra.custom = $H/custom-claude

[grok]
exclude = https://auth.x.ai::uuid-2
EOF

# ── tests: list ─────────────────────────────────────────────────────────────
GOT=$(bash lib/accounts.sh list)
WANT=$(printf '%s\n' \
"claude	.claude	default	alevsk.8772@gmail.com	max5	$H/.claude" \
"claude	.claude-lenin	Lenin	lenin@alevsk.com	pro	$H/.claude-lenin" \
"claude	.claude-work	W3B	alevsk@websec.mx	team_standard	$H/.claude-work" \
"claude	custom-claude	custom	custom@x.dev	pro	$H/custom-claude" \
"agy	default	default	aguy@gmail.com	-	$H/.gemini" \
"codex	.codex	default	a@openai.com	pro	$H/.codex" \
"grok	https://auth.x.ai::uuid-1	alevsk8772	alevsk8772@gmail.com	tier 1	$H/.grok" \
"opencode	zai-coding-plan	zai-coding-plan	-	-	$H/.config/opencode" \
"kimi	default	default	-	-	$H/.kimi-code")
ok "list exact TSV" "$WANT" "$GOT"

ok "claude-mem excluded" "0" "$(grep -c claude-mem <<<"$GOT" || true)"

# ── tests: resolve ──────────────────────────────────────────────────────────
ok "resolve claude session" ".claude-work" "$(bash lib/accounts.sh resolve claude sess-work)"
ok "resolve claude unknown" "" "$(bash lib/accounts.sh resolve claude nope)"
ok "resolve codex cwd" ".codex" "$(bash lib/accounts.sh resolve codex "$H/proj")"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
