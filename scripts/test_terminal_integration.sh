#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER="$ROOT_DIR/integrations/terminal/ai-monitor-terminal.js"
DAEMON_URL="${AI_MONITOR_URL:-http://127.0.0.1:4318}"
TASK_ID="${AI_MONITOR_TASK_ID:-terminal_test_$(date +%s)}"
SESSION_NAME="${AI_MONITOR_SESSION:-Codex CLI smoke test}"
TITLE="${AI_MONITOR_TITLE:-Terminal integration smoke test}"

cleanup() {
  node "$ADAPTER" close \
    --quiet \
    --daemon-url "$DAEMON_URL" \
    --task-id "$TASK_ID" || true
}

trap cleanup EXIT

post_status() {
  local status="$1"
  local step="$2"

  node "$ADAPTER" event \
    --strict \
    --daemon-url "$DAEMON_URL" \
    --source codex-cli \
    --task-id "$TASK_ID" \
    --session-name "$SESSION_NAME" \
    --title "$TITLE" \
    --status "$status" \
    --step "$step"
}

post_status running "Terminal task started"
sleep 0.5
post_status thinking "Agent is thinking"
sleep 0.5
post_status executing_tool "Agent is executing a tool"
sleep 0.5
post_status waiting_for_input "Agent is waiting for user input"
sleep 0.5
post_status running "Agent resumed"
sleep 0.5
post_status completed "Terminal task completed"

cleanup
trap - EXIT

echo "Posted and cleaned terminal smoke task: $TASK_ID"
