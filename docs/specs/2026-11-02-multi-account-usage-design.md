# Multi-Account Subscription Usage — Design

Date: 2026-11-02
Plugin: `alevsk.agent-usage` (herdr-agent-usage)
Status: Approved

## Problem

The dashboard's SUBSCRIPTION LIMITS section assumes one account per agent. In
reality accounts are multiple and will keep growing:

- Claude runs through config dirs: `~/.claude` (default),
  `~/.claude-work` (alevsk@websec.mx), `~/.claude-lenin` (lenin@alevsk.com),
  launched via `wclaude`/`lclaude` aliases that set `CLAUDE_CONFIG_DIR`.
- Grok's `~/.grok/auth.json` is already keyed for several accounts.
- Codex supports the same pattern via `CODEX_HOME`; more profiles may come for
  codex, grok, opencode, agy.

Today only the default `~/.claude` is queried, and two latent bugs exist:
`claude_live_context` reads only the default home (wclaude/lclaude panes fall
back to stale Herdr data), and the `[Claude Subscription]` section frequently
renders nothing because `claude -p "/usage"` prints no percentage lines.

Non-account dirs such as `~/.claude-mem` (claude-mem database) must never be
mistaken for accounts.

## Goals

1. Generalized account model: one mechanism covers "many homes per agent"
   (claude, codex) and "many accounts inside one home" (grok, opencode).
2. Per-account quota display for every agent, unified layout.
3. Pane → account attribution in the AGENT CONTEXT BREAKDOWN.
4. Keep the existing performance contract: instant popup, async quota fetches,
   mtime-guarded caches, minimal process spawns.
5. Reusable registry interface so `herdr-agent-profiles` can later fix its
  (currently wrong-for-profiles) sidebar labels.

## Non-goals (this iteration)

- Changing `herdr-agent-profiles` (follow-up; it will reuse this registry).
- Fetching quota for non-active grok accounts (requires switching accounts).
- opencode quota (identity row only; no known endpoint).
- Network calls beyond what each agent's own CLI already makes for `/usage`.

## Architecture

New library inside the plugin, sourced by `usage.sh` and directly runnable:

```
herdr-agent-usage/
  usage.sh            # rendering + orchestration (existing)
  lib/accounts.sh     # discovery, identity resolution, pane attribution
  lib/quota.sh        # per-account quota fetchers + cache management
  tests/test-accounts.sh
```

### Account record (canonical TSV, `lib/accounts.sh list`)

One line per account:

| field       | meaning                                   | example          |
|-------------|-------------------------------------------|------------------|
| `agent`     | herdr agent name                          | `claude`         |
| `account_id`| stable cache key = home dir basename      | `claude-work`    |
| `label`     | display name: dir suffix or `default`     | `work`           |
| `email`     | from local identity file (no network)     | `alevsk@websec.mx` |
| `plan`      | subscription tier when locally known      | `max5`           |
| `home`      | config dir (or parent home for grok/opencode) | `~/.claude-work` |

`lib/accounts.sh resolve <agent> <session-id|cwd>` → `account_id` of the home
owning that session, empty on no match.

## Discovery rule

A directory is an account **iff it contains a logged-in identity**. Candidate
homes = env override (`CLAUDE_CONFIG_DIR` / `CODEX_HOME` when set) + default
base + sibling glob (`~/.claude-*`, `~/.codex-*`). Directories without a valid
identity (`~/.claude-mem`) are excluded automatically. A profile appears the
moment its CLI logs in; no registration step.

Identity sources per agent:

| agent    | identity file                          | fields                          |
|----------|----------------------------------------|---------------------------------|
| claude   | `<home>/.claude.json` → `oauthAccount` | emailAddress, seatTier (plan)    |
| codex    | `<home>/auth.json` → `tokens.id_token` JWT | email, chatgpt_plan_type    |
| grok     | `~/.grok/auth.json`, each `issuer::uuid` entry | email, tier              |
| agy      | `~/.gemini/google_accounts.json`       | active email                    |
| opencode | `~/.local/share/opencode/auth.json`, each provider key | provider name, email if oauth |
| kimi     | `~/.kimi-code/credentials` exists      | label only                      |

Label rules: base dir → `default`; suffixed dir → suffix (`claude-work` →
`work`); in-file accounts (grok, opencode) → email prefix / provider key.
`account_id` is always the home dir basename — or, for in-file accounts
(grok, opencode), the auth-file entry key — never affected by renames, so
cache keys are stable.

### Optional overrides — `~/.config/herdr-agent-usage/accounts.conf`

INI-style, awk-parsed; file may be absent:

```ini
[claude]
exclude = mem
rename.work = W3B
extra.custom = ~/configs/claude-custom
```

- `exclude` — comma-separated account_ids never listed.
- `rename.<id>` — label override only (id stays).
- `extra.<label>` — additional home outside the convention glob.

## Quota fetching & caching

Cache layout (namespaced, replaces flat `/tmp/*.txt`):

```
/tmp/herdr-agent-usage/quota/<agent>/<account_id>.txt      # text fetches
/tmp/herdr-agent-usage/quota/<agent>/<account_id>.json     # json fetches (kimi)
```

Fetchers:

| agent    | source                                                    | mode              |
|----------|-----------------------------------------------------------|-------------------|
| claude   | `CLAUDE_CONFIG_DIR=<home> claude -p "/usage"`             | async, 300s cache |
| agy      | `agy -p "/usage"`                                         | async, 300s cache |
| codex    | local rollout `rate_limits` under `<home>/sessions`       | local, no cache   |
| grok     | Herdr-reported `tokens.limit`, attached to active account | already fetched   |
| kimi     | existing `/usages` OAuth call                             | async, 300s cache |
| opencode | none (identity row only)                                  | —                 |

Claude rows are hybrid: async `/usage` text when cached (percentages if the CLI
prints them, plus the `Last 7d · N requests · N sessions` line), with instant
local fallback computed from `<home>/stats-cache.json` (sum `dailyActivity` for
the last 7 days, single jq per account only when rendering, results memoized in
a shell variable per run). A claude account never renders an empty row.

First-open initialization runs all missing fetches in parallel behind one
`wait` (existing "Initializing cache…" pattern, parallelized). Later refreshes
use the existing stale-mtime background `& disown` pattern.

### Performance budget

- Discovery is batched: ~5 jq spawns total via multi-file globs +
  `input_filename` (one jq reads `~/.claude*/.claude.json` and emits
  filename → email/plan per file). No per-directory process spawns.
- JWT decode (codex) is per-account; expected count is 1–2.
- `resolve` is stat-only globs across homes, no jq.
- Target: synchronous discovery < 100 ms. If exceeded, specified fallback is an
  mtime-guarded `/tmp/herdr-agent-usage/registry.tsv` cache whose freshness
  check stats identity files only.
- Popup rendering stays single-pass per section (existing `format_bars` awk).

## Pane attribution

- claude: glob `<home>/projects/*/<session>.jsonl` across account homes;
  owning home determines the account label and the transcript used by
  `claude_live_context` (fixes the stale-context bug for wclaude/lclaude).
- codex: newest rollout whose `cwd` matches, searched across all codex homes.
- single-account agents: no suffix, exactly as today.
- Context breakdown `AGENT` column shows `claude·work` (fits the existing
  12-char column, plain text so printf width math is unchanged).

## Rendering

Unified groups replace the ad-hoc `[Claude Subscription]` / `[Antigravity
Quota]` / `[Kimi Code Subscription]` sections:

```
■ SUBSCRIPTION LIMITS

  [claude]
    ACCOUNT                     | PLAN | USAGE & LIMITS
    default · alevsk.8772@gma…  | max5 | 7d · 32334 req · 20 sessions
    work    · alevsk@websec.mx  | max5 | 7d · 1204 req · 6 sessions
    lenin   · lenin@alevsk.com  | pro  | 7d · 331 req · 3 sessions

  [agy]
    default · alevsk@…          |      | Gemini Models weekly [███████░░░] 36% · resets Nov 09
```

- Agents with ≥1 account render as groups in a fixed deterministic order
  (claude, agy, codex, grok, opencode, kimi; then any other herdr-reported
  agents alphabetically).
- Multi-row quotas (agy models) continue as indented rows under the account,
  preserving today's column format; `format_bars` injects bars unchanged.
- Emails > 26 chars truncate with `…`.
- The installed-but-no-account fallback table (devin, cursor, …) remains as-is.
- Herdr-reported limits for agents the registry knows (grok) attach to the
  account row; unknown agents keep the fallback table.

## Error handling

- Unreadable/corrupt identity file → account skipped silently.
- Quota fetch failure → previous cache kept (existing pattern).
- Quota windows already reset → render 0% (existing pattern).
- `resolve` no match → plain agent name, current behavior.
- Missing jq / herdr failures → existing early-exit behavior.

## Testing

`tests/test-accounts.sh` — plain bash + jq, no new dependencies:

- Builds fixture `$HOME` in `mktemp -d`: claude `default`/`-work`/`-lenin`
  dirs with `.claude.json` oauthAccounts, a `-mem` dir without identity,
  codex `auth.json` with a hand-built JWT, grok `auth.json` with two entries,
  agy `google_accounts.json`, opencode `auth.json`.
- Asserts `list` output exactly (TSV equality).
- Asserts `-mem` excluded, `extra`/`rename`/`exclude` honored.
- Asserts `resolve` returns the owning home for a session id and a codex cwd.
- Runs under `HOME=<fixture>` in a subshell; exits nonzero on any failure.

## Versioning

`herdr-plugin.toml` 0.2.0 → 0.3.0. README updated: multi-account section,
`accounts.conf` documentation, new cache location.
