#!/usr/bin/env bash
# tests/test-table.sh — grid geometry, bar severity, account labels
set -u
export LC_ALL=en_US.UTF-8
cd "$(dirname "$0")/.."

PASS=0 FAIL=0
ok() { # ok <name> <expected> <actual>
    if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else
        FAIL=$((FAIL+1)); echo "FAIL: $1"
        echo "  expected: [$2]"; echo "  actual:   [$3]"
        diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | sed 's/^/  /'
    fi
}

strip() { printf '%s' "$1" | LC_ALL=C sed $'s/\x1b\\[[0-9;]*m//g'; }
has_code() { # <text> <fixed ansi> → 1 if that SGR code is on any line
    printf '%s' "$1" | grep -F -c "$2" || true
}
same_width() { # text → shared line width, or "mixed"
    local line w="" cur
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        cur=${#line}
        if [ -z "$w" ]; then w=$cur
        elif [ "$cur" != "$w" ]; then printf 'mixed\n'; return
        fi
    done <<< "$1"
    printf '%s\n' "$w"
}

source lib/table.sh

# ── bars: 10 blocks, severity color, stable visible width ──────────────
vis=$(strip "$(bar_pct 0)")
ok "bar 0 visible" "░░░░░░░░░░   0%" "$vis"
ok "bar 0 green" "1" "$(has_code "$(bar_pct 0)" $'\033[1;32m')"
ok "bar 0 not red" "0" "$(has_code "$(bar_pct 0)" $'\033[1;31m')"

vis=$(strip "$(bar_pct 36)")
ok "bar 36 visible" "███░░░░░░░  36%" "$vis"
ok "bar 36 green" "1" "$(has_code "$(bar_pct 36)" $'\033[1;32m')"

vis=$(strip "$(bar_pct 69)")
ok "bar 69 still green" "1" "$(has_code "$(bar_pct 69)" $'\033[1;32m')"
ok "bar 69 not yellow" "0" "$(has_code "$(bar_pct 69)" $'\033[1;33m')"

vis=$(strip "$(bar_pct 70)")
ok "bar 70 visible" "███████░░░  70%" "$vis"
ok "bar 70 yellow" "1" "$(has_code "$(bar_pct 70)" $'\033[1;33m')"
ok "bar 70 not green" "0" "$(has_code "$(bar_pct 70)" $'\033[1;32m')"

vis=$(strip "$(bar_pct 89)")
ok "bar 89 yellow" "1" "$(has_code "$(bar_pct 89)" $'\033[1;33m')"
vis=$(strip "$(bar_pct 90)")
ok "bar 90 visible" "█████████░  90%" "$vis"
ok "bar 90 red" "1" "$(has_code "$(bar_pct 90)" $'\033[1;31m')"
vis=$(strip "$(bar_pct 96)")
ok "bar 96 visible" "█████████░  96%" "$vis"
vis=$(strip "$(bar_pct 100)")
ok "bar 100 visible" "██████████ 100%" "$vis"
ok "bar 100 red" "1" "$(has_code "$(bar_pct 100)" $'\033[1;31m')"
vis=$(strip "$(bar_pct 0)")
ok "bar widths match" "15" "${#vis}"
vis=$(strip "$(bar_pct 100)")
ok "bar 100 width" "15" "${#vis}"

# ── account label: email from the registry, default prefix only when shared
ok "account default multi" "default · alevsk.8772@gmail.com" \
    "$(account_display default alevsk.8772@gmail.com 1)"
ok "account default single" "alevsk.8772@gmail.com" \
    "$(account_display default alevsk.8772@gmail.com 0)"
ok "account label is local-part" "lenin@alevsk.com" \
    "$(account_display lenin lenin@alevsk.com 1)"
ok "account label plus other email" "work · alevsk@websec.mx" \
    "$(account_display work alevsk@websec.mx 1)"
ok "account label only" "zai-coding-plan" \
    "$(account_display zai-coding-plan - 0)"
ok "account empty" "—" "$(account_display default - 0)"
ok "plan dash" "—" "$(plan_name -)"
ok "plan strip suffix" "max" "$(plan_name max_20x)"

# ── context cell: tokens, bar, or em dash. No cylinder glyph. ───────────
ok "context empty" "—" "$(strip "$(context_cell -)")"
ok "context tokens" "489k" "$(strip "$(context_cell '⛁ 489k')")"
ok "context percent" "███░░░░░░░  36%  92k" "$(strip "$(context_cell '⛁ 36% (92k)')")"
ok "context percent red at 96" "1" "$(has_code "$(context_cell '96% (12k)')" $'\033[1;31m')"

# ── grid: equal line widths, group rules, flex grow and shrink ──────────
sample=$(printf '%s\n' \
    $'AGENT\tSTATUS\tTASK\tCONTEXT' \
    $'claude\tidle\thi\t489k' \
    '__RULE__' \
    $'grok\tidle\tlonger task name\t—')
grown=$(table_render 60 2 1 <<< "$sample")
ok "grown one width" "60" "$(same_width "$(strip "$grown")")"
ok "grown starts with corner" "1" "$(strip "$grown" | head -n 1 | grep -c '^╭')"
rules=$(strip "$grown" | grep -c '^├')
ok "grown header rule plus group rule" "2" "$rules"
ok "grown keeps short task" "1" "$(strip "$grown" | grep -c 'hi')"
ok "grown keeps second account" "1" "$(strip "$grown" | grep -c 'longer task name')"

long=$(printf '%s\n' \
    $'AGENT\tSTATUS\tTASK\tCONTEXT' \
    $'claude\tidle\tBacklog closeout FX29-FX30 cards and the rest of the title\t489k')
shrunk=$(table_render 40 2 1 <<< "$long")
ok "shrunk one width" "40" "$(same_width "$(strip "$shrunk")")"
ok "shrunk uses ellipsis" "1" "$(strip "$shrunk" | grep -c '…')"

natural=$(printf '%s\n' $'ACCOUNT\tPLAN' $'lenin@alevsk.com\tmax' | table_render 80 0 0)
nwidth=$(same_width "$(strip "$natural")")
ok "no-grow one width" "1" "$( [ "$nwidth" != mixed ] && echo 1 || echo 0)"
ok "no-grow narrower than max" "1" "$( [ "$nwidth" -gt 10 ] && [ "$nwidth" -lt 80 ] && echo 1 || echo 0)"

# continuation rows leave the account cell blank; the rule is the separator
blocks=$(printf '%s\n' \
    $'AGENT\tACCOUNT\tPLAN\tLIMIT\tUSAGE\tRESETS' \
    $'claude\tdefault · alevsk.8772@gmail.com\tmax\tweek\t██████████ 100%\tNov 8 11pm' \
    $'\t\t\tfable\t░░░░░░░░░░   0%\t—' \
    '__RULE__' \
    $'agy\talevsk.8772@gmail.com\t—\tGemini Models · week\t██████████ 100%\tNov 13 9:32pm')
grid=$(table_render 120 1 0 <<< "$blocks")
ok "limits header" "1" "$(strip "$grid" | grep -c 'AGENT')"
ok "agy account is not the model" "1" "$(strip "$grid" | grep -c '│ agy *│ alevsk.8772@gmail.com')"
ok "model stays in the limit cell" "1" "$(strip "$grid" | grep -c 'Gemini Models · week')"
blank=$(strip "$grid" | grep 'fable')
ok "fable row keeps the limit" "1" "$(printf '%s' "$blank" | grep -c 'fable' || true)"
ok "fable row does not repeat the email" "0" "$(printf '%s' "$blank" | grep -c 'gmail.com' || true)"

tight=$(printf '%s\n' \
    $'AGENT\tACCOUNT\tPLAN\tLIMIT\tUSAGE\tRESETS' \
    $'claude\tdefault · alevsk.8772@gmail.com\tmax\tClaude and GPT models · week\t██████████ 100%\tNov 8 11pm' \
    | table_render 94 3 0 1)
ok "tight width" "94" "$(same_width "$(strip "$tight")")"
ok "tight keeps the email" "1" "$(strip "$tight" | grep -c 'alevsk.8772' || true)"
ok "tight keeps the bar" "1" "$(strip "$tight" | grep -c '100%' || true)"

banner=$(box_banner 60 "Herdr Agent Usage Dashboard")
ok "banner width" "60" "$(same_width "$(strip "$banner")")"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
