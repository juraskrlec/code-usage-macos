#!/usr/bin/env bash
# Claude Code statusLine command.
#
# Renders a normal status line AND caches the whole stdin payload to
# ~/.claude/statusline.json so CodeUsageBar can read the official
# rate_limits numbers — the same ones /usage shows.
#
# Wire it up in ~/.claude/settings.json (absolute path, no ~):
#   { "statusLine": { "type": "command", "command": "/Users/you/.claude/claude-statusline-capture.sh" } }

input=$(cat)

# Cache first, and atomically, so a half-written file is never read.
out="$HOME/.claude/statusline.json"
printf '%s' "$input" > "$out.tmp" && mv "$out.tmp" "$out"

# Everything below is just the terminal status line; drop it if you have one already.
command -v jq >/dev/null || { printf 'claude'; exit 0; }

model=$(printf '%s' "$input" | jq -r '.model.display_name // "claude"')
five=$(printf '%s' "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
week=$(printf '%s' "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

line="$model"
[ -n "$five" ] && line="$line | 5h $(printf '%.0f' "$five")%"
[ -n "$week" ] && line="$line | 7d $(printf '%.0f' "$week")%"
printf '%s' "$line"
