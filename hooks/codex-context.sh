#!/bin/sh
# Reports the current Codex context usage to herdr as the pane metadata token
# "context" (shown by the alevsk.agent-usage dashboard). Subscription limits are
# read by the dashboard itself, so they are not reported here.
# Optional hook shipped with herdr-agent-usage; register it as a Codex Stop hook
# (see README). Not managed by herdr.

hook_input_file="$(mktemp "${TMPDIR:-/tmp}/agent-usage-codex.XXXXXX")" || exit 0
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

pane_id = os.environ["HERDR_PANE_ID"]
socket_path = os.environ["HERDR_SOCKET_PATH"]

try:
    with open(os.environ["HERDR_HOOK_INPUT_FILE"], encoding="utf-8") as handle:
        hook_input = json.loads(handle.read() or "{}")
except Exception:
    raise SystemExit(0)

transcript_path = hook_input.get("transcript_path")
if not isinstance(transcript_path, str) or not os.path.isfile(transcript_path):
    raise SystemExit(0)

info = None
with open(transcript_path, encoding="utf-8", errors="replace") as handle:
    for line in handle:
        if '"token_count"' not in line:
            continue
        try:
            payload = json.loads(line).get("payload") or {}
        except Exception:
            continue
        if payload.get("type") != "token_count":
            continue
        if payload.get("info"):
            info = payload["info"]


def short(n):
    return f"{n / 1000:.0f}k" if n >= 1000 else str(n)


tokens = {}

if info:
    used = (info.get("last_token_usage") or {}).get("total_tokens")
    window = info.get("model_context_window")
    if isinstance(used, int) and isinstance(window, int) and window > 0:
        tokens["context"] = f"⛁ {round(used * 100 / window)}% ({short(used)})"

if not tokens:
    raise SystemExit(0)

request = {
    "id": f"alevsk.agent-usage:codex-context:{int(time.time() * 1000)}:{random.randrange(1_000_000):06d}",
    "method": "pane.report_metadata",
    "params": {
        "pane_id": pane_id,
        "source": "alevsk.agent-usage:codex-context",
        "agent": "codex",
        "seq": time.time_ns(),
        "tokens": tokens,
    },
}

try:
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(0.5)
    client.connect(socket_path)
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
