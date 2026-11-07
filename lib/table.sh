#!/usr/bin/env bash
# lib/table.sh — width-aware bars and box tables for the usage dashboard.
# Sourced by usage.sh. Cells may contain SGR color; padding uses visible width.

# Real ESC bytes. usage.sh's '\033…' literals are for echo -e; printf %s does not
# interpret them, and a UTF-8 sed refuses a string that still contains ESC.
: "${CYAN:=$'\033[1;36m'}"
: "${GREEN:=$'\033[1;32m'}"
: "${YELLOW:=$'\033[1;33m'}"
: "${RED:=$'\033[1;31m'}"
: "${WHITE:=$'\033[1;37m'}"
: "${DIM:=$'\033[2m'}"
: "${BOLD:=$'\033[1m'}"
: "${RESET:=$'\033[0m'}"

# tr is byte-oriented and splits a multibyte box character into garbage.
repeat_char() { # <char> <count>
    local char=$1 n=$2 i out=""
    for (( i = 0; i < n; i++ )); do out+=$char; done
    printf '%s' "$out"
}

visible_len() { # <string> — characters, after stripping SGR
    local s=$1
    [[ $s == *$'\033'* ]] && s=$(printf '%s' "$s" | LC_ALL=C sed $'s/\x1b\\[[0-9;]*m//g')
    printf '%s' "${#s}"
}

pad_cols() { # <string> <width>
    local n=$(( $2 - $(visible_len "$1") ))
    if [ "$n" -gt 0 ]; then printf '%s%*s' "$1" "$n" ''; else printf '%s' "$1"; fi
}

truncate_cell() { # <plain text> <width> — single ellipsis, display width
    local s=$1 w=$2
    [ "$(visible_len "$s")" -le "$w" ] && { printf '%s' "$s"; return; }
    [ "$w" -le 1 ] && { printf '…'; return; }
    printf '%s…' "${s:0:$(( w - 1 ))}"
}

fit_pad() { # <string> <width> — truncate (dropping color if needed), then pad
    local s=$1 w=$2
    if [ "$(visible_len "$s")" -gt "$w" ]; then
        [[ $s == *$'\033'* ]] && s=$(printf '%s' "$s" | LC_ALL=C sed $'s/\x1b\\[[0-9;]*m//g')
        s=$(truncate_cell "$s" "$w")
    fi
    pad_cols "$s" "$w"
}

# 10-block bar. Green under 70, yellow from 70 to 89, red at 90 and above.
bar_pct() { # <pct 0-100>
    local pct=${1%\%} w=10 color filled_bar="" empty_bar="" i
    [[ $pct =~ ^[0-9]+$ ]] || pct=0
    [ "$pct" -gt 100 ] && pct=100
    local filled=$(( pct * w / 100 ))
    if [ "$pct" -ge 90 ]; then color=$RED
    elif [ "$pct" -ge 70 ]; then color=$YELLOW
    else color=$GREEN
    fi
    for (( i = 0; i < filled; i++ )); do filled_bar+="█"; done
    for (( i = filled; i < w; i++ )); do empty_bar+="░"; done
    local out=""
    [ -n "$filled_bar" ] && out+="${color}${filled_bar}"
    [ -n "$empty_bar" ] && out+="${DIM}${empty_bar}"
    printf '%s%s %3d%%%s' "$out" "$color" "$pct" "$RESET"
}

plan_name() { # <plan> — strip at the first underscore; empty and "-" become —
    local p=${1%%_*}
    if [ -z "$p" ] || [ "$p" = "-" ]; then printf '—'
    else printf '%s' "$p"
    fi
}

# Email wins. A label that is not already the address's local-part is prefixed
# ("work · alevsk@websec.mx"). "default" is prefixed only when the agent has
# more than one account, so a single agy/codex/grok account shows the bare email.
account_display() { # <label> <email> <multi 0|1>
    local label=$1 email=$2 multi=${3:-0} localpart
    if [ -n "$email" ] && [ "$email" != "-" ]; then
        localpart=${email%%@*}
        if [ -n "$label" ] && [ "$label" != "-" ] && [ "$label" != "default" ] && [[ $localpart != "$label"* ]]; then
            printf '%s · %s' "$label" "$email"
        elif [ "$label" = "default" ] && [ "$multi" = 1 ]; then
            printf 'default · %s' "$email"
        else
            printf '%s' "$email"
        fi
    elif [ -n "$label" ] && [ "$label" != "-" ] && [ "$label" != "default" ]; then
        printf '%s' "$label"
    else
        printf '—'
    fi
}

context_cell() { # <raw herdr/live context> — tokens, a bar, or an em dash
    local s=$1 pct tokens
    if [ -z "$s" ] || [ "$s" = "-" ]; then
        printf '%s—%s' "$DIM" "$RESET"
        return
    fi
    s=${s#⛁ }
    s=${s# }
    if [[ $s =~ ([0-9]+)% ]]; then
        pct=${BASH_REMATCH[1]}
        tokens=""
        [[ $s =~ ([0-9]+[kK]) ]] && tokens=${BASH_REMATCH[1]}
        if [ -n "$tokens" ]; then printf '%s  %s' "$(bar_pct "$pct")" "$tokens"
        else bar_pct "$pct"
        fi
    else
        printf '%s%s%s' "$CYAN" "$s" "$RESET"
    fi
}

box_banner() { # <width> <title>
    local w=$1 title=$2 inner pad rest rule
    inner=$(( w - 2 ))
    if [ "$inner" -lt ${#title} ]; then inner=${#title}; w=$(( inner + 2 )); fi
    pad=$(( (inner - ${#title}) / 2 ))
    rest=$(( inner - pad - ${#title} ))
    rule=$(repeat_char "─" "$inner")
    printf '%s╭%s╮%s\n' "$CYAN" "$rule" "$RESET"
    printf '%s│%*s%s%s%s%*s│%s\n' "$CYAN" "$pad" '' "$BOLD$WHITE" "$title" "$RESET$CYAN" "$rest" '' "$RESET"
    printf '%s╰%s╯%s\n' "$CYAN" "$rule" "$RESET"
}

# Split a TSV line into FIELDS, keeping empty columns.
_table_split() {
    local rest=$1 field
    FIELDS=()
    while [[ $rest == *$'\t'* ]]; do
        field=${rest%%$'\t'*}
        rest=${rest#*$'\t'}
        FIELDS+=("$field")
    done
    FIELDS+=("$rest")
}

_table_rule() { # <left> <mid> <right>  uses widths[] and ncols
    local left=$1 mid=$2 right=$3 i out=$1
    for (( i = 0; i < ncols; i++ )); do
        [ "$i" -gt 0 ] && out+=$mid
        out+=$(repeat_char "─" "$(( widths[i] + 2 ))")
    done
    printf '%s%s%s%s\n' "$DIM" "$out" "$right" "$RESET"
}

_table_outer_width() {
    local i sum=0
    for (( i = 0; i < ncols; i++ )); do sum=$(( sum + widths[i] )); done
    printf '%s' "$(( sum + 3 * ncols + 1 ))"
}

# stdin: TSV. First row is the header. A line equal to __RULE__ separates groups.
# <max_width> outer width. <flex_col> 0-based column stretched when grow=1.
# <grow 0|1>. <protect> optional column shrunk only after the others (account).
table_render() {
    local maxw=$1 flex=$2 grow=$3 protect=${4:--1}
    local -a kind=() raw=() widths=() headers=()
    local line i j
    while IFS= read -r line || [ -n "${line:-}" ]; do
        [ -z "$line" ] && continue
        if [ "$line" = "__RULE__" ]; then
            local n=${#kind[@]}
            [ "$n" -eq 0 ] && continue
            [ "${kind[$(( n - 1 ))]}" = "rule" ] && continue
            kind+=("rule"); raw+=("")
        else
            kind+=("row"); raw+=("$line")
        fi
    done
    local last=$(( ${#kind[@]} - 1 ))
    while [ "$last" -ge 0 ] && [ "${kind[last]}" = "rule" ]; do
        last=$(( last - 1 ))
    done
    [ "$last" -ge 0 ] && [ "${kind[0]}" = "row" ] || return 0

    _table_split "${raw[0]}"
    headers=("${FIELDS[@]}")
    local ncols=${#headers[@]}
    for (( i = 0; i < ncols; i++ )); do widths[i]=$(visible_len "${headers[i]}"); done
    for (( j = 1; j <= last; j++ )); do
        [ "${kind[j]}" = "row" ] || continue
        _table_split "${raw[j]}"
        for (( i = 0; i < ncols; i++ )); do
            local cell="${FIELDS[i]:-}" len
            len=$(visible_len "$cell")
            [ "$len" -gt "${widths[i]}" ] && widths[i]=$len
        done
    done

    # Shrink the longest column. A protected column (the account) stays intact
    # until every other column is down to 16, so emails survive a narrow pane
    # and a fixed 15-wide bar is not the first thing cut.
    _table_pick() { # <floor> <skip_protect 0|1>
        local floor=$1 skip=$2 i best=-1 bestw=-1
        for (( i = 0; i < ncols; i++ )); do
            [ "$skip" = 1 ] && [ "$i" -eq "$protect" ] && continue
            if [ "${widths[i]}" -gt "$floor" ] && [ "${widths[i]}" -gt "$bestw" ]; then
                best=$i; bestw=${widths[i]}
            fi
        done
        printf '%s' "$best"
    }
    local width guard=0 pick
    width=$(_table_outer_width)
    while [ "$width" -gt "$maxw" ] && [ "$guard" -lt 4000 ]; do
        guard=$(( guard + 1 ))
        pick=$(_table_pick 16 1)
        [ "$pick" -lt 0 ] && pick=$(_table_pick 16 0)
        [ "$pick" -lt 0 ] && pick=$(_table_pick 4 1)
        [ "$pick" -lt 0 ] && pick=$(_table_pick 4 0)
        [ "$pick" -lt 0 ] && break
        widths[pick]=$(( widths[pick] - 1 ))
        width=$(_table_outer_width)
    done
    if [ "$grow" = 1 ] && [ "$flex" -ge 0 ] && [ "$flex" -lt "$ncols" ] && [ "$width" -lt "$maxw" ]; then
        widths[flex]=$(( widths[flex] + maxw - width ))
    fi

    _table_rule "╭" "┬" "╮"
    local -a cells=()
    for (( j = 0; j <= last; j++ )); do
        if [ "${kind[j]}" = "rule" ]; then
            _table_rule "├" "┼" "┤"
            continue
        fi
        _table_split "${raw[j]}"
        local out="${DIM}│${RESET}"
        for (( i = 0; i < ncols; i++ )); do
            local fitted
            fitted=$(fit_pad "${FIELDS[i]:-}" "${widths[i]}")
            if [ "$j" -eq 0 ]; then fitted="${DIM}${fitted}${RESET}"; fi
            out+=" ${fitted} ${DIM}│${RESET}"
        done
        printf '%s\n' "$out"
        if [ "$j" -eq 0 ]; then _table_rule "├" "┼" "┤"; fi
    done
    _table_rule "╰" "┴" "╯"
}
