#!/bin/sh
# Reports the current Claude Code context size to herdr as the pane metadata
# token "context" (shown by the alevsk.agent-usage dashboard).
# Optional hook shipped with herdr-agent-usage; register it as a Claude Code Stop
# hook (see README). Not managed by herdr.
# Only the token count is reported: the context window size is not stored on disk.

hook_input_file="$(mktemp "${TMPDIR:-/tmp}/agent-usage-claude.XXXXXX")" || exit 0
trap 'rm -f "$hook_input_file"' EXIT HUP INT TERM
cat >"$hook_input_file" 2>/dev/null || true

[ "${HERDR_ENV:-}" = "1" ] || exit 0
[ -n "${HERDR_SOCKET_PATH:-}" ] || exit 0
[ -n "${HERDR_PANE_ID:-}" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

HERDR_HOOK_INPUT_FILE="$hook_input_file" python3 - <<'PY' || true
import json
import os
import random
import socket
import time

try:
    with open(os.environ["HERDR_HOOK_INPUT_FILE"], encoding="utf-8") as handle:
        hook_input = json.loads(handle.read() or "{}")
except Exception:
    raise SystemExit(0)

transcript_path = hook_input.get("transcript_path")
if not isinstance(transcript_path, str) or not os.path.isfile(transcript_path):
    raise SystemExit(0)

# Context of the last main-thread request: every input token sent to the model.
context = None
with open(transcript_path, encoding="utf-8", errors="replace") as handle:
    for line in handle:
        if '"usage"' not in line:
            continue
        try:
            entry = json.loads(line)
        except Exception:
            continue
        if entry.get("type") != "assistant" or entry.get("isSidechain"):
            continue
        usage = (entry.get("message") or {}).get("usage") or {}
        parts = [usage.get(k) for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")]
        if all(isinstance(p, int) or p is None for p in parts) and any(isinstance(p, int) for p in parts):
            context = sum(p or 0 for p in parts)

if context is None:
    raise SystemExit(0)

text = f"⛁ {context / 1000:.0f}k" if context >= 1000 else f"⛁ {context}"
request = {
    "id": f"alevsk.agent-usage:claude-context:{int(time.time() * 1000)}:{random.randrange(1_000_000):06d}",
    "method": "pane.report_metadata",
    "params": {
        "pane_id": os.environ["HERDR_PANE_ID"],
        "source": "alevsk.agent-usage:claude-context",
        "agent": "claude",
        "seq": time.time_ns(),
        "tokens": {"context": text},
    },
}

try:
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(0.5)
    client.connect(os.environ["HERDR_SOCKET_PATH"])
    client.sendall((json.dumps(request) + "\n").encode())
    try:
        reply = client.recv(4096)
        if os.environ.get("AGENT_USAGE_DEBUG"):
            print(reply.decode(errors="replace"))
    except Exception:
        pass
    client.close()
except Exception:
    pass
PY
exit 0
