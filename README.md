# Herdr Agent Usage Dashboard 📊

A highly optimized TUI dashboard providing real-time observability into your active AI agents and their API subscription quotas.

## Features

- **Live Context Tracking:** Shows the current context of every agent pane (e.g., `⛁ 493k`, `⛁ 16% (41k)`) and its working status. For Claude Code and Codex it is read live from the session file each pane is writing, so it is current even mid-turn and needs no hooks: Claude through the session id Herdr tracks for the pane, Codex through the newest rollout started in the pane's working directory. Claude shows a percentage when the optional status line below is installed. Other agents show the `context` token reported to Herdr.
- **API Subscription Quotas:** Automatically detects native CLI integrations (like `claude` and `agy` Antigravity) and pulls their billing limits.
- **Smart Progress Bars:** An inline `awk` engine parses raw percentages (e.g. `82%`) and dynamically injects colorized block progress bars (e.g., `[████████░░] 82%`) into the UI without breaking layout alignments.
- **0ms Blocking (Background Caching):** Because pulling API billing data from Claude/Gemini takes several seconds, the dashboard uses asynchronous detached background jobs (`& disown`) and a `/tmp/` cache. The dashboard pops up instantly using 5-minute stale cache windows, guaranteeing a fast UX while saving LLM tokens/API rate limits.
- **Offline Agent Detection:** Seamlessly merges active Herdr socket limits with fallback scans of installed configuration directories (`~/.codex`, `~/.grok`, etc.) so you have a complete picture of your machine's AI capabilities even when panes are closed.
- **Local Session Fallback:** When Herdr reports no limit for an agent, the dashboard reads what the agent CLI already writes to disk, with no network calls or credentials: Codex subscription limits from the latest `rate_limits` snapshot in `~/.codex/sessions` (or `$CODEX_HOME`), and Kimi Code context usage from the newest session log in `~/.kimi-code/sessions` against the model's `max_context_size`. Only sessions from the last 7 days are used.
- **Kimi Code Quota:** Kimi Code keeps no quota on disk and has no non-interactive `/usage`, so the dashboard queries the same `/usages` endpoint as Kimi's `/usage` command, using the OAuth token Kimi already stores in `~/.kimi-code/credentials` (sent through stdin, never on the command line). It shows the 5-hour and weekly windows with the same 5-minute background cache as Claude. The token is short-lived and refreshed by a running `kimi`; if it has expired the last cached values are kept, and windows that have already reset show 0%.

## Requirements
- `herdr` CLI
- `jq` (JSON parsing)
- `awk` (for UI layout processing)
- `curl` (for the Kimi Code quota)
- Supported Agent CLIs (`claude`, `agy`, `codex`, `kimi`) for extended quota capabilities.

## Installation

1. Install the plugin directly from GitHub:
   ```bash
   herdr plugin install alevsk/herdr-agent-usage
   ```

2. Add the keybinding to your `~/.config/herdr/config.toml`:
   ```toml
   [[keys.command]]
   key = "prefix+u"
   type = "plugin_action"
   command = "alevsk.agent-usage.show"
   description = "Agent Usage Dashboard"
   ```

3. Reload the Herdr server:
   ```bash
   herdr server reload-config
   ```

## Usage
Press `prefix+u` (or your configured keybinding) to pop open the dashboard over your current workspace. The dashboard operates as an ephemeral overlay and exits upon pressing any key.

## Optional: Claude Code Status Line (context percentage)
The dashboard reads Claude Code context tokens from the session transcript, but Claude Code gives the context window size (200k or 1M) only to its status line, never to disk or to hooks. Without it Claude rows show tokens only (e.g. `⛁ 493k`).

`hooks/claude-statusline.sh` is a status line that, on every assistant message:
- saves the session's `context_window` to `~/.cache/herdr-agent-usage/claude/<session_id>.json`, which the dashboard uses for the percentage and bar (e.g. `⛁ 49% (493k)`);
- reports the same value to Herdr as the pane's `context` metadata token (only inside Herdr);
- prints `<model> · ⛁ 49% (493k)` as the status line.

Requires `jq`. Claude Code has a single `statusLine`, so this replaces any status line you have:
```bash
cp hooks/claude-statusline.sh ~/.claude/hooks/agent-usage-statusline.sh
```
```json
{
  "statusLine": { "type": "command", "command": "sh ~/.claude/hooks/agent-usage-statusline.sh", "padding": 0 }
}
```
Open sessions pick it up right away.

## Optional: Codex Context Hook
The dashboard reads Codex context by itself. `hooks/codex-context.sh` is a Stop hook that only reports it to Herdr as the pane's `context` metadata token, for other Herdr consumers; the value is as of the last finished turn. It reads the session rollout (no network calls, no credentials), exits silently outside Herdr, and requires `python3`.

Copy the script and add it to the `Stop` hooks in `~/.codex/hooks.json`:
```bash
cp hooks/codex-context.sh ~/.codex/agent-usage-context.sh
```
```json
{
  "hooks": {
    "Stop": [
      { "hooks": [{ "type": "command", "command": "sh ~/.codex/agent-usage-context.sh", "timeout": 10 }] }
    ]
  }
}
```
Restart open Codex sessions so they pick up the hook.
