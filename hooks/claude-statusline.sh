#!/bin/sh
# Claude Code status line for herdr-agent-usage.
# Claude Code only gives the context window size to the status line, so this
# saves it per session for the dashboard, reports the context to herdr as the
# pane metadata token "context", and prints a one-line status.
# Optional; register it as the statusLine command (see README). Requires jq.

command -v jq >/dev/null 2>&1 || exit 0
payload=$(cat)
[ -n "$payload" ] || exit 0

# Tab-separated so an empty field cannot shift the others.
fields=$(printf '%s' "$payload" | jq -r '
  [(.session_id // ""), (.model.display_name // ""),
   (.context_window.context_window_size // "" | tostring),
   (.context_window.current_usage // null |
     if . == null then "" else (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0) | tostring end)
  ] | @tsv' 2>/dev/null) || exit 0
tab=$(printf '\t')
IFS=$tab read -r session model window used <<EOF
$fields
EOF

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/herdr-agent-usage/claude"
case "$session" in
  ''|*/*|.*) ;;
  *)
    if mkdir -p "$cache_dir" 2>/dev/null; then
      printf '%s' "$payload" | jq -c '{context_window, model: .model.id}' >"$cache_dir/$session.json.tmp" 2>/dev/null &&
        mv "$cache_dir/$session.json.tmp" "$cache_dir/$session.json"
    fi
    ;;
esac

short() {
  if [ "$1" -ge 1000 ]; then echo "$(( ($1 + 500) / 1000 ))k"; else echo "$1"; fi
}

context=""
case "$used" in
  ''|*[!0-9]*) ;;
  *)
    case "$window" in
      ''|0|*[!0-9]*) context="⛁ $(short "$used")" ;;
      *) context="⛁ $(( (used * 100 + window / 2) / window ))% ($(short "$used"))" ;;
    esac
    ;;
esac

if [ -n "$context" ] && [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
  "${HERDR_BIN_PATH:-herdr}" pane report-metadata "$HERDR_PANE_ID" \
    --source alevsk.agent-usage:claude-context --agent claude \
    --token "context=$context" >/dev/null 2>&1 &
fi

printf '%s\n' "${model:-Claude}${context:+ · $context}"
exit 0
