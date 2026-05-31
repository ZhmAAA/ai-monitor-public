#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER="${AI_MONITOR_TERMINAL_ADAPTER:-$SCRIPT_DIR/ai-monitor-terminal.js}"

STATUS="${AI_MONITOR_STATUS:-${1:-running}}"
TITLE="${AI_MONITOR_TITLE:-${2:-Codex CLI}}"
STEP="${AI_MONITOR_STEP:-${3:-Codex CLI terminal event}}"
MESSAGE="${AI_MONITOR_MESSAGE:-${4:-$TITLE is $STATUS}}"
SESSION_NAME="${AI_MONITOR_SESSION:-Codex CLI}"
WORKSPACE="${AI_MONITOR_WORKSPACE:-$PWD}"

args=(
  event
  --source codex-cli
  --status "$STATUS"
  --title "$TITLE"
  --step "$STEP"
  --message "$MESSAGE"
  --session-name "$SESSION_NAME"
  --workspace "$WORKSPACE"
)

if [[ -n "${AI_MONITOR_TASK_ID:-}" ]]; then
  args+=(--task-id "$AI_MONITOR_TASK_ID")
fi

if [[ -n "${AI_MONITOR_URL:-}" ]]; then
  args+=(--daemon-url "$AI_MONITOR_URL")
fi

if [[ -n "${AI_MONITOR_TERMINAL_TARGET:-}" ]]; then
  args+=(--target "$AI_MONITOR_TERMINAL_TARGET")
fi

exec node "$ADAPTER" "${args[@]}"
