# Herdr Agent Usage Dashboard 📊

A highly optimized TUI dashboard providing real-time observability into your active AI agents and their API subscription quotas.

## Features

- **Context Memory Tracking:** Displays the current active tokens (e.g., `⛁ 69% (686k)`) and working statuses of all agents natively parsing `herdr agent list`.
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

## Optional: Per-Pane Context Hooks
The **Agent Context Breakdown** column shows the `context` token that each pane reports to Herdr. Herdr's built-in Claude Code and Codex integrations only report agent state, so without a reporter the column shows `-`. The dashboard works fine without these hooks; they only fill that column.

The `hooks/` directory ships two optional Stop hooks that read the session file the agent already writes (no network calls, no credentials) and report `context` for their own pane. They exit silently outside Herdr.

| Hook | Reports | Source |
| --- | --- | --- |
| `hooks/claude-context.sh` | Context tokens of the last main-thread request (e.g. `⛁ 321k`). No percentage: the context window size is not stored on disk. | `transcript_path` from the hook input |
| `hooks/codex-context.sh` | Context usage against the model window (e.g. `⛁ 21% (54k)`). | `last_token_usage` and `model_context_window` in the session rollout |

Requires `python3`.

**Claude Code:** copy the script and add it to the `Stop` hooks in `~/.claude/settings.json`, next to any hooks already there:
```bash
cp hooks/claude-context.sh ~/.claude/hooks/agent-usage-context.sh
```
```json
{
  "hooks": {
    "Stop": [
      { "hooks": [{ "type": "command", "command": "sh ~/.claude/hooks/agent-usage-context.sh", "timeout": 10, "async": true }] }
    ]
  }
}
```

**Codex:** copy the script and add it to the `Stop` hooks in `~/.codex/hooks.json`:
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

Restart open Claude Code and Codex sessions so they pick up the new hook. Each pane updates after its next turn.
