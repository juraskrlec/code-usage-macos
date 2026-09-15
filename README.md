# CodeUsageBar

A native macOS menu bar app that shows Claude Code and Codex usage together.
The menu bar keeps both current plan percentages visible; hovering opens a
popover with rolling limits, reset times, and local token totals for today and
the current month. Clicking pins the popover.

## Build

```sh
chmod +x bundle.sh
./bundle.sh
open CodeUsageBar.app
```

The helper used for Claude plan limits is included automatically in the app's
`Contents/Resources` directory. For a local development install, the build
script can also copy and enable it:

```sh
./bundle.sh --install-claude-helper
```

This adds the `statusLine` setting when one is not already configured. It keeps
an existing custom status line unchanged and prints the helper path instead.

`swift run` also works for quick iteration, but the unbundled binary won't
behave like a proper agent app (no `LSUIElement`, no Login Items entry).

To launch at login: System Settings → General → Login Items → add
`CodeUsageBar.app`.

## Claude Code data

### Plan quota

Claude Code pipes a JSON payload to your `statusLine` command on every render.
It carries `rate_limits.five_hour` and `rate_limits.seven_day`, each with a used
percentage and reset time. `claude-statusline-capture.sh` caches that payload to
`~/.claude/statusline.json`; the app reads it. Install and configure the helper
as part of the build:

```sh
./bundle.sh --install-claude-helper
```

When no status line exists, the build script adds this entry to
`~/.claude/settings.json` using the actual absolute home-directory path:

```json
{ "statusLine": { "type": "command", "command": "/Users/you/.claude/claude-statusline-capture.sh" } }
```

The file only updates while a Claude Code session is active and after its first
API response. The app marks it stale after 15 minutes. Plan limits are normally
present for Pro and Max OAuth logins and may be absent for API key, Bedrock, or
Vertex usage.

### Local tokens

Claude Code writes JSONL session files under `~/.claude/projects/`. The app sums
assistant usage records for the local calendar day and month and deduplicates
resumed or compacted turns by message and request ID.

Optional dollar estimates still use
`~/.config/claude-usage-bar/pricing.json`. Plan usage is not billed per token,
so these are estimates only.

## Codex data

### Plan quota

The app launches the installed Codex CLI as a short-lived app-server client and
calls the documented `account/rateLimits/read` method. It uses the user's
existing Codex login and never reads or stores authentication tokens itself.
The current account-wide rolling windows and reset times work while no Codex
session is open.

The app looks for Codex in these locations:

- `CODEX_EXECUTABLE`, when set
- `$CODEX_HOME/packages/standalone/current/bin/codex`
- `~/.local/bin/codex`
- `~/.codex/packages/standalone/current/bin/codex`
- `/opt/homebrew/bin/codex` or `/usr/local/bin/codex`

Run `codex login` first. If the CLI is unavailable or the request times out, the
most recent limit snapshot in the local session logs is shown as stale.

### Local tokens

Codex writes exact per-response token records under
`~/.codex/sessions/**/*.jsonl`. The app sums them for today and the current
month, deduplicating by response ID. Cached input is part of input tokens and
reasoning output is part of output tokens, so neither is counted twice.

These token totals cover sessions stored on this Mac. The rolling plan limits
are account-wide and can also include Codex activity from the desktop app,
cloud, IDE, or another machine.

## Known limits

- Claude plan data is only as fresh as the status-line capture.
- Claude and Codex local JSONL formats can change between client releases.
- Both token scanners perform a full pass over files modified this month.
- The app is intentionally not sandboxed because it reads `~/.claude` and
  `~/.codex`. A sandboxed distribution would need security-scoped bookmarks.
