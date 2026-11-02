# Multi-Account Subscription Usage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generalize the Agent Usage Dashboard from one-account-per-agent to a registry of N accounts per agent (discovery, identity, per-account quota, pane attribution), with the existing performance contract (instant popup, async fetches, mtime caches).

**Architecture:** New `lib/accounts.sh` (account registry: discovery + identity + pane attribution) and `lib/quota.sh` (per-account quota fetch/cache) sourced by `usage.sh`; `usage.sh` keeps only orchestration + rendering. Unified per-agent groups replace the ad-hoc subscription sections.

**Tech Stack:** bash, jq (≥1.6, `input_filename`), awk, BSD+GNU date/stat dual support. Tests: plain bash script, no new deps.

**Spec:** `docs/specs/2026-11-02-multi-account-usage-design.md`

**Repo:** all paths relative to `herdr-agent-usage/` (its own git repo). Commits must use `git -c commit.gpgsign=false commit …` — the user signs via 1Password which cannot prompt from non-interactive shells.

**Verified ground truth (do not re-derive):**
- Claude profiles are config dirs: `~/.claude` (default, alevsk.8772@gmail.com, keychain auth, **no `oauthAccount` in `.claude.json`**), `~/.claude-work` (alevsk@websec.mx, `oauthAccount.seatTier` = `team_standard`), `~/.claude-lenin` (lenin@alevsk.com). `~/.claude-mem` is claude-mem's database (no `.claude.json`, no `projects/`) — must be excluded.
- `claude auth status` prints JSON `{loggedIn, email, subscriptionType, …}` and works per home via `CLAUDE_CONFIG_DIR=<home>`; `.oauthAccount.emailAddress` is present only for some homes.
- Codex identity: `<home>/auth.json` → `.tokens.id_token` JWT → `.email`, `."https://api.openai.com/auth".chatgpt_plan_type`.
- Grok: `~/.grok/auth.json` is a map keyed `issuer::uuid`; values have `email`, `tier`. Quota arrives via Herdr (`tokens.limit`, e.g. `7d 18%`).
- agy: `~/.gemini/google_accounts.json` → `.active` = email; quota via `agy -p "/usage"` → TSV `model \t limit \t pct \t reset`.
- OpenCode: `~/.local/share/opencode/auth.json` keyed by provider (e.g. `zai-coding-plan`).
- Kimi: `~/.kimi-code/credentials/*.json`; quota via OAuth `/usages` (existing code).
- Claude transcripts: `<home>/projects/<proj>/<session>.jsonl`. Codex rollouts: `<home>/sessions/YYYY/MM/DD/rollout-*.jsonl`, first line contains `"cwd":"<path>"`.
- `claude -p "/usage"` output includes a `Last 7d · N requests · N sessions` line and usually no percentages.
- `<home>/stats-cache.json` has `dailyActivity[] {date, messageCount, sessionCount}` — local 7d fallback.

---

### Task 1: Test scaffold + fixtures + failing `accounts list` tests

**Files:**
- Create: `tests/test-accounts.sh`

- [ ] **Step 1: Write the test script**

```bash
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
    fi
}

FIX=$(mktemp -d); trap 'rm -rf "$FIX"' EXIT
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

jq -n '{ "https://auth.x.ai::uuid-1": {email:"alevsk8772@gmail.com", tier:1},
         "https://auth.x.ai::uuid-2": {email:"other@x.ai", tier:2} }' > "$H/.grok/auth.json"
mkdir -p "$H/.grok"

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

ok "claude-mem excluded" "" "$(grep -c claude-mem <<<"$GOT" | grep -v '^0$')"

# ── tests: resolve ──────────────────────────────────────────────────────────
ok "resolve claude session" ".claude-work" "$(bash lib/accounts.sh resolve claude sess-work)"
ok "resolve claude unknown" "" "$(bash lib/accounts.sh resolve claude nope)"
ok "resolve codex cwd" ".codex" "$(bash lib/accounts.sh resolve codex "$H/proj")"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test-accounts.sh`
Expected: FAIL — `lib/accounts.sh: No such file or directory`, final line `pass=0 fail=…`, exit non-zero.

- [ ] **Step 3: Commit**

```bash
git add tests/test-accounts.sh
git -c commit.gpgsign=false commit -m "test: account registry fixtures and expectations"
```

---

### Task 2: Implement `lib/accounts.sh` (discovery, identity, conf overrides)

**Files:**
- Create: `lib/accounts.sh`

- [ ] **Step 1: Write the library**

```bash
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

accounts_conf_label() { # <agent> <account_id> → overridden label or nothing
    accounts_conf "$1" | awk -F'\t' -v id="$2" '$1 == "rename" && $2 == id { print $3 }'
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

# ── emit ────────────────────────────────────────────────────────────────────
accounts_dir_label() { # <agent> <home-basename> → "default" or dir suffix
    if [ "$2" = ".$1" ]; then echo default; else echo "${2#.$1-}"; fi
}

accounts_email_label() { echo "${1%%@*}"; }

# emit_account <agent> <account_id> <label> <email> <plan> <home>
emit_account() {
    local agent=$1 id=$2 label=$3 over
    [ -n "$(accounts_conf_excluded "$agent" "$id")" ] && return 0
    over=$(accounts_conf_label "$agent" "$id")
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
    local dir file email plan b
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
        emit_account claude "$b" "$(accounts_dir_label claude "$b")" "$email" "$plan" "$dir"
    done
}

accounts_list_codex() {
    local file token payload email plan dir b
    while IFS=$'\t' read -r file token; do
        [ -n "$token" ] || continue
        payload=$(accounts_jwt_payload "$token")
        [ -n "$payload" ] || continue
        IFS=$'\t' read -r email plan < <(jq -r '
            [.email // "-", (."https://api.openai.com/auth".chatgpt_plan_type // "-")] | @tsv
        ' <<<"$payload" 2>/dev/null)
        dir=$(dirname "$file"); b=$(basename "$dir")
        emit_account codex "$b" "$(accounts_dir_label codex "$b")" "$email" "$plan" "$dir"
    done < <(accounts_candidate_homes codex CODEX_HOME |
        while IFS= read -r d; do [ -f "$d/auth.json" ] && echo "$d/auth.json"; done |
        xargs jq -r '[input_filename, (.tokens.id_token // "")] | @tsv' 2>/dev/null)
}

accounts_list_grok() {
    local f="$HOME/.grok/auth.json" key email tier
    [ -f "$f" ] || return 0
    while IFS=$'\t' read -r key email tier; do
        [ -n "$email" ] || continue
        emit_account grok "$key" "$(accounts_email_label "$email")" "$email" \
            "${tier:+tier $tier}${tier:--}" "$HOME/.grok"
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
    while IFS=$'\t' read -r key; do
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
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `bash tests/test-accounts.sh`
Expected: `pass=5 fail=0`, exit 0. If `list exact TSV` fails, diff field-by-field before touching code — the expected block encodes discovery order (default → glob-sorted siblings → extras), labels, and conf overrides.

- [ ] **Step 3: Commit**

```bash
git add lib/accounts.sh
git -c commit.gpgsign=false commit -m "feat: account registry with identity-based discovery and overrides"
```

---

### Task 3: `lib/quota.sh` — per-account fetch/cache engine

**Files:**
- Create: `lib/quota.sh`
- Create: `tests/test-quota.sh`

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# tests/test-quota.sh — cache/TTL/store tests for lib/quota.sh using fake fetchers
set -u
cd "$(dirname "$0")/.."

PASS=0 FAIL=0
ok() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $1"; echo "  expected: [$2]"; echo "  actual:   [$3]"; fi; }

FIX=$(mktemp -d); trap 'rm -rf "$FIX"' EXIT
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
```

Run: `bash tests/test-quota.sh` — Expected: FAIL (`lib/quota.sh: No such file or directory`).

- [ ] **Step 2: Write the library**

```bash
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
    local tmp="${cache}.tmp.$$"
    if "$@" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        mv "$tmp" "$cache"
    else
        rm -f "$tmp"; return 1
    fi
}

# ── fetchers (stdout only; no credentials on command lines) ────────────────
quota_fetch_claude() { CLAUDE_CONFIG_DIR="$1" claude -p "/usage"; }
quota_fetch_agy()    { agy -p "/usage"; }
quota_fetch_kimi() {
    local token
    token=$(jq -rs 'map(select((.expires_at // 0) > now)) | max_by(.expires_at) | .access_token // empty' \
        "$HOME/.kimi-code"/credentials/*.json 2>/dev/null)
    [ -n "$token" ] || return 1
    printf 'Authorization: Bearer %s' "$token" |
        curl -sf -m 10 -H @- "${KIMI_CODE_BASE_URL:-https://api.kimi.com/coding/v1}/usages" |
        jq -e '.usages'
}

quota_store_claude_identity() { # <account_id> <home> — keychain-auth homes have no oauthAccount
    local cache="${IDENTITY_CACHE:-${TMPDIR:-/tmp}/herdr-agent-usage/identity}/claude/$1.json"
    mkdir -p "$(dirname "$cache")"
    local tmp="${cache}.tmp.$$" out
    out=$(CLAUDE_CONFIG_DIR="$2" claude auth status 2>/dev/null) || return 1
    jq -e '.loggedIn == true and (.email // "") != ""' <<<"$out" >/dev/null 2>&1 || return 1
    jq '{email: .email, subscriptionType: (.subscriptionType // "-")}' <<<"$out" > "$tmp" &&
        mv "$tmp" "$cache"
}

# ── dispatch (init = parallel + wait; refresh = background + disown) ────────
quota_dispatch() { # <agent> <account_id> <ext> <home>
    local agent=$1 id=$2 ext=$3 home=$4
    case "$agent" in
        claude) quota_store claude "$id" "$ext" quota_fetch_claude "$home" ;;
        agy)    quota_store agy    "$id" "$ext" quota_fetch_agy ;;
        kimi)   quota_store kimi   "$id" "$ext" quota_fetch_kimi ;;
    esac
}

quota_refresh_async() { ( quota_dispatch "$@" ) & disown; }

quota_refresh_async_identity() { # <account_id> <home> — background, 1h TTL
    local cache="${IDENTITY_CACHE:-${TMPDIR:-/tmp}/herdr-agent-usage/identity}/claude/$1.json"
    quota_is_fresh "$cache" "$IDENTITY_TTL" && return 0
    ( quota_store_claude_identity "$1" "$2" ) & disown
}

# ── claude usage rendering helpers ──────────────────────────────────────────
quota_claude_local_usage() { # <home> → "7d · N req · N sessions" from stats-cache.json
    local f="$1/stats-cache.json"
    [ -f "$f" ] || return 1
    local cutoff
    cutoff=$(date -v-7d +%Y-%m-%d 2>/dev/null || date -d '7 days ago' +%Y-%m-%d)
    jq -r --arg cutoff "$cutoff" '
        [(.dailyActivity // [])[] | select(.date >= $cutoff)] as $d |
        ($d | map(.messageCount // 0) | add // 0) as $req |
        ($d | map(.sessionCount // 0) | add // 0) as $sess |
        "7d · \($req) req · \($sess) sessions"
    ' "$f" 2>/dev/null
}

quota_claude_cached_usage() { # <cache-file> → summary line from `claude -p /usage`
    [ -f "$1" ] || return 1
    grep -oE 'Last 7d · [0-9]+ requests? · [0-9]+ sessions?' "$1" 2>/dev/null | head -n 1 |
        sed 's/^Last //'
}
```

- [ ] **Step 3: Run both test scripts**

Run: `bash tests/test-quota.sh && bash tests/test-accounts.sh`
Expected: `pass=9 fail=0` and `pass=7 fail=0`, exit 0.

- [ ] **Step 4: Commit**

```bash
git add lib/quota.sh tests/test-quota.sh
git -c commit.gpgsign=false commit -m "feat: per-account quota cache engine with parallel init"
```

---

### Task 4: `usage.sh` — source libs, pane attribution, multi-home live context

**Files:**
- Modify: `usage.sh`

- [ ] **Step 1: Source the libraries (after the HERDR/jq setup, before first use)**

Insert after the `MARGIN`/`SUBMARGIN` definitions:

```bash
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/accounts.sh
source "$PLUGIN_DIR/lib/accounts.sh"
# shellcheck source=lib/quota.sh
source "$PLUGIN_DIR/lib/quota.sh"
```

- [ ] **Step 2: Replace `claude_live_context` transcript lookup (multi-home)**

Replace the body from `for transcript in …` through `[ -f "$transcript" ] || return 1` with:

```bash
    local transcript
    transcript=$(accounts_claude_transcript "$session")
    [ -n "$transcript" ] || return 1
```

(Delete the old `CLAUDE_CONFIG_DIR` single-home glob; the status-cache read below it is unchanged.)

- [ ] **Step 3: Replace `codex_live_context` rollout lookup (multi-home)**

Replace the `sessions=` assignment, the `-d` guard, and the `rollout=$(find …)` pipeline with:

```bash
    local cwd=$1 rollout used window
    rollout=$(accounts_codex_rollout "$cwd")
    [ -n "$rollout" ] || return 1
```

(The token_count parsing below it is unchanged. The old `newest_file` helper stays — `kimi_local_limit` uses it.)

- [ ] **Step 4: Attribute rows to accounts in the context loop**

Inside the `while IFS=$'\t' read -r agent status context title session cwd; do` loop, replace the `case "$agent" in … esac` block with:

```bash
    live=""
    case "$agent" in
        claude)
            live=$(claude_live_context "$session")
            id=$(accounts_resolve claude "$session")
            [ -n "$id" ] && [ -n "${ACC_LABEL[claude/$id]:-}" ] &&
                agent="$agent·${ACC_LABEL[claude/$id]}"
            ;;
        codex)
            live=$(codex_live_context "$cwd")
            id=$(accounts_resolve codex "$cwd")
            [ -n "$id" ] && [ -n "${ACC_LABEL[codex/$id]:-}" ] &&
                agent="$agent·${ACC_LABEL[codex/$id]}"
            ;;
    esac
    [ ${#agent} -gt 12 ] && agent="${agent:0:11}…"
```

- [ ] **Step 5: Load the registry before the context loop**

Insert just above the `jq -r '(.result.agents // [])[] | …` pipeline that feeds the context loop:

```bash
# Account registry (single discovery pass; arrays consulted per row later).
ACC_TSV=$(accounts_list)
declare -A ACC_LABEL=() ACC_EMAIL=() ACC_PLAN=() ACC_HOME=() AGENT_HAS=()
while IFS=$'\t' read -r a id label email plan home; do
    [ -n "$a" ] || continue
    ACC_LABEL["$a/$id"]=$label; ACC_EMAIL["$a/$id"]=$email
    ACC_PLAN["$a/$id"]=$plan;   ACC_HOME["$a/$id"]=$home; AGENT_HAS["$a"]=1
done <<< "$ACC_TSV"
```

- [ ] **Step 6: Smoke test**

Run: `printf 'q' | bash usage.sh | head -40`
Expected: renders without errors; claude rows that belong to `~/.claude-work` show `claude·work` and live context `⛁ …` where transcripts exist; other rows unchanged.

- [ ] **Step 7: Commit**

```bash
git add usage.sh
git -c commit.gpgsign=false commit -m "feat: attribute panes to accounts, read context across homes"
```

---

### Task 5: `usage.sh` — unified SUBSCRIPTION LIMITS rendering

**Files:**
- Modify: `usage.sh` (the whole tail from `update_cache_if_stale()` through the `[Other Agents]` loop)

- [ ] **Step 1: Delete the old section machinery**

Remove entirely: `update_cache_if_stale()`, `fetch_kimi_quota()`, `update_kimi_cache_if_stale()`, the three `if [ -f /tmp/… ]` section blocks (agy/claude/kimi), and the `KIMI_HOME`/`KIMI_CACHE` variables. Keep `format_epoch`, `iso_to_epoch`, `format_bars`, `newest_file`, the HERDR_LIMITS/HERDR_PROVIDERS parse, `codex_local_limit`, `kimi_local_limit`, `KNOWN_AGENTS`.

- [ ] **Step 2: Parameterize `codex_local_limit` by home**

Change its first lines to accept a home argument:

```bash
codex_local_limit() { # <home>
    local sessions="$1/sessions" rate_limits
```

and replace the single remaining use of `$sessions` accordingly (the `find` already uses it). Update its caller later in this task.

- [ ] **Step 3: Write the new unified section**

Insert after the HERDR_LIMITS/HERDR_PROVIDERS parsing:

```bash
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
truncate_cell() { # <text> <width>
    [ ${#1} -gt "$2" ] && echo "${1:0:$(( $2 - 1 ))}…" || echo "$1"
}

render_account_cell() { # <label> <email> → "label · email" truncated to 28
    local cell="$1"
    [ "$2" != "-" ] && [ -n "$2" ] && cell="$1 · $2"
    truncate_cell "$cell" 28
}

render_agy_account() { # <account_id> <account_cell> — agy TSV rows, single usage column
    local cache; cache=$(quota_cache_path agy "$1")
    [ -f "$cache" ] || { printf "%-28s | %-13s | %s\n" "$2" "-" "-"; return; }
    local first=1 model limit pct reset reset_local
    grep -v "Quota:" "$cache" | while IFS=$'\t' read -r model limit pct reset; do
        if date --version >/dev/null 2>&1; then
            reset_local=$(date -d "$reset" "+%b %d at %-I:%M%p (%Z)" 2>/dev/null)
        else
            reset_local=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$reset" "+%b %d at %-I:%M%p (%Z)" 2>/dev/null)
        fi
        reset_local=${reset_local:-$reset}
        if [ "$first" -eq 1 ]; then
            printf "%-28s | %-13s | %s\n" "$2" "-" "$model · $limit · $pct · $reset_local"
            first=0
        else
            printf "%-28s | %-13s | %s\n" "" "" "$model · $limit · $pct · $reset_local"
        fi
    done
}
```

Continue with the group loop:

```bash
GROUP_ORDER=(claude agy codex grok opencode kimi)
for agent in "${GROUP_ORDER[@]}"; do
    ids=$(awk -F'\t' -v a="$agent" '$1 == a { print $2 }' <<< "$ACC_TSV")
    [ -n "$ids" ] || continue
    echo -e "${SUBMARGIN}${CYAN}[$agent]${RESET}"
    printf "${DIM}${SUBSUBMARGIN}%-28s | %-13s | %s${RESET}\n" "ACCOUNT" "PLAN" "USAGE & LIMITS"
    while IFS= read -r id; do
        local_key="$agent/$id"
        cell=$(render_account_cell "${ACC_LABEL[$local_key]}" "${ACC_EMAIL[$local_key]}")
        plan=$(truncate_cell "${ACC_PLAN[$local_key]:- -}" 13)
        case "$agent" in
            claude)
                usage=$(quota_claude_cached_usage "$(quota_cache_path claude "$id")")
                [ -n "$usage" ] || usage=$(quota_claude_local_usage "${ACC_HOME[$local_key]}")
                usage=${usage:--}
                printf "${SUBSUBMARGIN}%-28s | %-13s | %s\n" "$cell" "$plan" "$usage"
                ;;
            agy)
                render_agy_account "$id" "$cell" | sed "s/^/$SUBSUBMARGIN/"
                ;;
            codex)
                if [ -n "${HERDR_LIMITS[codex]:-}" ] && [ "$id" = ".codex" ]; then
                    usage="${HERDR_LIMITS[codex]}"
                else
                    IFS=$'\t' read -r _ usage < <(codex_local_limit "${ACC_HOME[$local_key]}")
                fi
                printf "${SUBSUBMARGIN}%-28s | %-13s | %s\n" "$cell" "$plan" "${usage:--}"
                ;;
            grok)
                if [ -n "${HERDR_LIMITS[grok]:-}" ] && [ "$id" = "$(awk -F'\t' -v a=grok '$1==a{print $2; exit}' <<< "$ACC_TSV")" ]; then
                    usage="${HERDR_LIMITS[grok]}"
                else
                    usage="-"
                fi
                printf "${SUBSUBMARGIN}%-28s | %-13s | %s\n" "$cell" "$plan" "$usage"
                ;;
            *)
                printf "${SUBSUBMARGIN}%-28s | %-13s | %s\n" "$cell" "$plan" "-"
                ;;
        esac
    done <<< "$ids" | format_bars
    echo ""
done
```

**Note on the grok branch:** the Herdr-reported limit attaches to the *first* grok account only; the inline awk selects it. kimi falls into `*` for the header but needs its own rendering — add before `*)`:

```bash
            kimi)
                cache=$(quota_cache_path kimi "$id" json)
                [ -f "$cache" ] || { printf "${SUBSUBMARGIN}%-28s | %-13s | %s\n" "$cell" "$plan" "-"; continue; }
                jq -r '
                  [["limit_5h", "5h limit"], ["limit_7d", "Weekly limit"],
                   ["limit_month_total", "Monthly limit"], ["limit_month_code", "Monthly code limit"]][] as [$key, $label] |
                  .usages[$key] | select(. != null) |
                  ((.used_ratio // null) | tonumber? // null) as $ratio | select($ratio != null) |
                  [$label, "\($ratio * 100 | round)%", (.reset_time // "")] | @tsv
                ' "$cache" 2>/dev/null | {
                    first=1
                    while IFS=$'\t' read -r label pct reset; do
                        epoch=$([ -n "$reset" ] && iso_to_epoch "$reset")
                        [ -n "$epoch" ] && [ "$epoch" -lt "$CURRENT_TIME" ] && pct="0%" && epoch=""
                        line="$label $pct${epoch:+ · resets $(format_epoch "$epoch")}"
                        if [ "$first" -eq 1 ]; then
                            printf "%-28s | %-13s | %s\n" "$cell" "$plan" "$line"; first=0
                        else
                            printf "%-28s | %-13s | %s\n" "" "" "$line"
                        fi
                    done
                }
                ;;
```

- [ ] **Step 4: Shrink the fallback table to account-less agents**

In the `for agent in "${ALL_AGENTS[@]}"` loop, the skip condition becomes:

```bash
    # Agents with registry accounts render as groups above
    [ -n "${AGENT_HAS[$agent]:-}" ] && continue
```

(replacing the old `agy`/`claude` skip). Update the codex/kimi local-limit fallback loop to only run when that agent has **no** registry accounts.

- [ ] **Step 5: Verify the fallback local-limit loop**

The old `for agent in codex kimi; do` fallback loop must only run for agents with **no** registry accounts:

```bash
for agent in codex kimi; do
    [ -z "${AGENT_HAS[$agent]:-}" ] || continue
    [ -n "${HERDR_LIMITS[$agent]:-}" ] && continue
    case "$agent" in
        codex) IFS=$'\t' read -r provider limit < <(codex_local_limit "${ACC_HOME[codex/.codex]:-$HOME/.codex}") || continue ;;
        kimi)  IFS=$'\t' read -r provider limit < <(kimi_local_limit) || continue ;;
    esac
    HERDR_LIMITS["$agent"]="$limit"
    HERDR_PROVIDERS["$agent"]="$provider"
done
```

(`codex_local_limit` takes the account home; `kimi_local_limit` takes no argument.)

- [ ] **Step 6: Smoke test twice (init path + cached path)**

Run: `printf 'q' | bash usage.sh | head -60` (twice; first shows "Initializing quota caches…", second renders groups).
Expected: `[claude]` group lists default/work/lenin rows with emails and `7d · N req · N sessions`; `[agy]` group shows the Gemini/Claude-GPT quota rows with bars; grok attaches `7d 18%`; codex row shows rollout-derived limits; devin/cursor remain in the fallback table; no `[Claude Subscription]`/`[Antigravity Quota]`/`[Kimi Code Subscription]` headers remain.

- [ ] **Step 7: Commit**

```bash
git add usage.sh lib/quota.sh
git -c commit.gpgsign=false commit -m "feat: unified per-account subscription groups"
```

---

### Task 6: Docs, version bump, full verification

**Files:**
- Modify: `herdr-plugin.toml` (version `0.2.0` → `0.3.0`)
- Modify: `README.md`
- Modify: `docs/specs/2026-11-02-multi-account-usage-design.md` (Status → Implemented)

- [ ] **Step 1: README additions** — new "Multiple accounts" section: convention discovery (`~/.claude-*`, `~/.codex-*`), identity sources table, `accounts.conf` reference (exclude/rename/extra), new cache locations (`/tmp/herdr-agent-usage/{quota,identity}`), pane attribution (`claude·work`), and the keychain-identity note (first popup after login shows `-` until the background `claude auth status` enrichment caches).

- [ ] **Step 2: Run everything**

Run: `bash tests/test-accounts.sh && bash tests/test-quota.sh && printf 'q' | bash usage.sh | head -60`
Expected: test-quota `pass=9 fail=0` and test-accounts `pass=5 fail=0`; dashboard renders groups as in Task 5.

- [ ] **Step 3: Manual visual check** — press `prefix+u` in Herdr; confirm the layout matches the smoke output and bars align.

- [ ] **Step 4: Commit**

```bash
git add herdr-plugin.toml README.md docs/specs/2026-11-02-multi-account-usage-design.md
git -c commit.gpgsign=false commit -m "docs: multi-account usage, bump 0.3.0"
```

---

## Self-review notes

- Spec coverage: discovery+identity (Tasks 1–2), conf overrides (Task 1 fixtures, Task 2 code), quota cache/init/refresh (Tasks 3, 5), keychain identity enrichment (Task 3 helper, Task 5 wiring), pane attribution + multi-home context (Task 4), unified rendering + fallback table (Task 5), docs/version (Task 6). Registry TSV cache (`registry.tsv`) deliberately **not** built — the measured spawn budget (~5 jq) meets the <100ms target; the spec lists it only as a fallback.
- Known deferred (per spec non-goals): agent-profiles plugin reuse; non-active grok quota; opencode quota.
- Bash gotchas already accounted for: pipeline `while` loops run in subshells (rendering only, no state escapes needed); `accounts_resolve_codex` needs 5 `dirname`s to reach the home basename; `quota_cache_path` sanitizes `/` in ids (grok keys).
