# Development & Release Guide

Everything you need to develop, test, release, and upgrade this plugin —
including the gotchas that have already bitten once.

## Repo facts

- Remote: `github.com:Alevsk/herdr-agent-usage.git` (this plugin is its own repo,
  separate from the `herdr-plugins` monorepo it lives next to locally).
- Herdr installs it **from GitHub by git ref** (`herdr plugin list` shows the
  pinned commit SHA). GitHub Releases are changelog-only — Herdr never reads
  them for installs or updates.
- Manifest: `herdr-plugin.toml` (`id = "alevsk.agent-usage"`). Its `version`
  field is the single source of truth the release workflow validates against.

## Test before anything

```bash
bash tests/test-accounts.sh   # account registry — expect: pass=5 fail=0
bash tests/test-quota.sh      # quota engine    — expect: pass=12 fail=0
printf 'q' | bash usage.sh 2>err.txt | tail -50; wc -c err.txt   # smoke: 0 stderr bytes
```

Tests are hermetic (fixture `$HOME`, no network, no real agent CLIs) — safe to
run anytime. The smoke run exercises the real machine; first open after a cache
clear blocks a few seconds behind "Initializing quota caches..." by design.

## Release process

1. **Sync tags first** (a stale local clone once hid an existing release):

   ```bash
   git fetch --tags origin
   gh release list -R Alevsk/herdr-agent-usage   # what's already published
   ```

2. **Pick the next version** — never reuse an existing tag. Bump `version` in
   `herdr-plugin.toml` and commit:

   ```bash
   git -c commit.gpgsign=false commit -am "chore: bump version to X.Y.Z"
   ```

   The `-c commit.gpgsign=false` matters when working from agents/non-interactive
   shells: commit signing goes through 1Password, which cannot prompt there.

3. **Tag (annotated, unsigned from a shell without 1Password access):**

   ```bash
   git -c tag.gpgsign=false tag -a vX.Y.Z -m "One-line summary of the release"
   ```

   Plain `git tag vX.Y.Z` opens `$EDITOR` (nvim) for the message — always pass
   `-a -m`. Repo config (`tag.gpgsign=true`) signs tags when interactive; the
   `-c` override skips it when you must.

4. **Push main and the tag together:**

   ```bash
   git push origin main vX.Y.Z
   ```

5. **The workflow does the rest.** `.github/workflows/release.yml` fires on
   `v*` tags: it fails if the tag doesn't match `herdr-plugin.toml`'s version,
   then creates the GitHub Release with auto-generated notes:

   ```bash
   gh run watch -R Alevsk/herdr-agent-usage "$(gh run list -R Alevsk/herdr-agent-usage --limit 1 --json databaseId --jq '.[0].databaseId')"
   gh release view vX.Y.Z -R Alevsk/herdr-agent-usage
   ```

## Upgrade the installed plugin

Herdr pulls git refs, so upgrading is a reinstall (or `update` on newer Herdr):

```bash
herdr plugin install alevsk/herdr-agent-usage -y   # Herdr 0.9.0 (current machine)
herdr plugin update  alevsk.agent-usage            # newer Herdr releases

herdr plugin list | grep agent-usage               # SHA should match the pushed commit
```

Reinstalls are live immediately: new invocations (press `prefix+u`) use the new
code without a config reload; already-open panes keep the old files.

## Local development loop

Quick iteration without touching the installed plugin:

```bash
printf 'q' | bash usage.sh        # run the dashboard directly from the repo
bash lib/accounts.sh list         # inspect the account registry
bash lib/accounts.sh resolve claude <session-id>
```

To test inside Herdr properly, link the repo (installing over a link is
refused — unlink first):

```bash
herdr plugin uninstall alevsk.agent-usage
herdr plugin link "$(pwd)"
# ... test with prefix+u ...
herdr plugin unlink alevsk.agent-usage && herdr plugin install alevsk/herdr-agent-usage -y
```

Debugging caches (all per-account, under `$TMPDIR`, usually `/tmp`):

```bash
rm -rf "${TMPDIR:-/tmp}/herdr-agent-usage/quota"      # force quota re-init on next open
ls "${TMPDIR:-/tmp}/herdr-agent-usage/identity/claude" # keychain-identity enrichment (1h TTL)
```

## Known gotchas (each learned the hard way)

- **Version/tag collisions:** the local clone can be behind the remote's tags —
  always `git fetch --tags` + `gh release list` before picking a version
  (v0.3.0 was once bumped into a September release that existed only on the
  remote).
- **Signing:** commits and tags made from agents/non-interactive shells need
  `-c commit.gpgsign=false` / `-c tag.gpgsign=false`. To re-sign pushed history:
  `git rebase --exec 'git commit --amend --no-edit -S' <base>` then force-push.
- **`CLAUDE_CONFIG_DIR` quirk:** setting it explicitly to `~/.claude` breaks
  `claude -p "/usage"` and `claude auth status`. `quota_fetch_claude` already
  scrubs it for the default home — keep that behavior.
- **bash UTF-8:** never write `$var·` (unbraced expansion before a multibyte
  char) — bash 3.2–5.3 mangles it. Always `${var}·`. And `printf %-Ns` pads by
  bytes; use the `pad_cols` helper for cells that may contain `·`/`…`.

## Layout

```
usage.sh            dashboard: rendering + orchestration
lib/accounts.sh     account registry: discovery, identity, overrides, pane attribution
lib/quota.sh        per-account quota fetch/cache engine (atomic stores, TTLs, async refresh)
hooks/              optional Claude statusline + Codex context hook
tests/              hermetic bash test suites (accounts, quota)
docs/specs|plans    design specs and implementation plans
```
