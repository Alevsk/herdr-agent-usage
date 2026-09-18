# Herdr Agent Usage Dashboard 📊

A highly optimized TUI dashboard providing real-time observability into your active AI agents and their API subscription quotas.

## Features

- **Context Memory Tracking:** Displays the current active tokens (e.g., `⛁ 69% (686k)`) and working statuses of all agents natively parsing `herdr agent list`.
- **API Subscription Quotas:** Automatically detects native CLI integrations (like `claude` and `agy` Antigravity) and pulls their billing limits.
- **Smart Progress Bars:** An inline `awk` engine parses raw percentages (e.g. `82%`) and dynamically injects colorized block progress bars (e.g., `[████████░░] 82%`) into the UI without breaking layout alignments.
- **0ms Blocking (Background Caching):** Because pulling API billing data from Claude/Gemini takes several seconds, the dashboard uses asynchronous detached background jobs (`& disown`) and a `/tmp/` cache. The dashboard pops up instantly using 5-minute stale cache windows, guaranteeing a fast UX while saving LLM tokens/API rate limits.

## Requirements
- `herdr` CLI
- `jq` (JSON parsing)
- `awk` & `column` (for UI layout processing)
- Supported Agent CLIs (`claude`, `agy`) for extended quota capabilities.

## Manual Installation

1. Link the plugin to Herdr:
   ```bash
   herdr plugin link /path/to/herdr-agent-usage
   ```

2. Add the keybinding to your `~/.config/herdr/config.toml`:
   ```toml
   [[keys.command]]
   key = "prefix+u"
   command = "herdr plugin invoke herdr-agent-usage"
   ```

3. Reload the Herdr server:
   ```bash
   herdr server reload-config
   ```

## Usage
Press `prefix+u` (or your configured keybinding) to pop open the dashboard over your current workspace. The dashboard operates as an ephemeral overlay and exits upon pressing any key.
