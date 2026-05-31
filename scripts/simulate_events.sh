#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${AI_MONITOR_URL:-http://127.0.0.1:4318}"
WORKSPACE_PATH="${AI_MONITOR_WORKSPACE:-$(pwd)}"
API_TOKEN="${AI_MONITOR_API_TOKEN:-${AI_MONITOR_TOKEN:-}}"
if [[ -z "$API_TOKEN" && -f "${AI_MONITOR_API_TOKEN_FILE:-$HOME/.ai-monitor/api-token}" ]]; then
  API_TOKEN="$(tr -d '\n\r' < "${AI_MONITOR_API_TOKEN_FILE:-$HOME/.ai-monitor/api-token}")"
fi

curl_auth_args=()
if [[ -n "$API_TOKEN" ]]; then
  curl_auth_args=(-H "x-ai-monitor-token: $API_TOKEN")
fi

post_event() {
  local task_id="$1"
  local status="$2"
  local priority="$3"
  local title="$4"
  local step="$5"
  local message="$6"
  local confidence="${7:-0.98}"
  local session_name="${8:-${title}}"
  local window_title="${9:-${session_name}}"
  local now
  now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  local event_id
  event_id="evt_${task_id}_${status}_$(date +%s%N)"

  curl -sS \
    -X POST "${BASE_URL}/events" \
    -H "content-type: application/json" \
    "${curl_auth_args[@]}" \
    -d @- <<JSON
{
  "event_id": "${event_id}",
  "task_id": "${task_id}",
  "source": "codex-cli",
  "app": "terminal",
  "workspace": "${WORKSPACE_PATH}",
  "session_name": "${session_name}",
  "window_title": "${window_title}",
  "title": "${title}",
  "status": "${status}",
  "step": "${step}",
  "message": "${message}",
  "confidence": ${confidence},
  "priority": "${priority}",
  "notify_desktop": true,
  "notify_external": true,
  "created_at": "${now}",
  "updated_at": "${now}",
  "actions": [
    {
      "label": "Open workspace",
      "type": "open_url",
      "target": "file://${WORKSPACE_PATH}"
    }
  ],
  "metadata": {
    "simulated": true
  }
}
JSON
  echo
}

echo "Posting simulated AI Monitor events to ${BASE_URL}"

post_event "task_simulated_flow" "running" "P2" "Implement SQLite event store" "Starting daemon task" "Codex CLI task is running" "0.98" "Backend refactor" "Terminal - Backend refactor"
sleep 1
post_event "task_simulated_flow" "thinking" "P2" "Implement SQLite event store" "Planning storage schema" "Agent is reasoning about schema" "0.98" "Backend refactor" "Terminal - Backend refactor"
sleep 1
post_event "task_simulated_flow" "executing_tool" "P2" "Implement SQLite event store" "Running cargo test" "Agent is executing a tool" "0.98" "Backend refactor" "Terminal - Backend refactor"
sleep 1
post_event "task_simulated_flow" "needs_permission" "P0" "Implement SQLite event store" "Waiting for permission" "Agent needs approval to edit storage.rs" "0.98" "Backend refactor" "Terminal - Backend refactor"
sleep 1
post_event "task_simulated_flow" "waiting_for_input" "P0" "Implement SQLite event store" "Waiting for user input" "Agent needs clarification before continuing" "0.98" "Backend refactor" "Terminal - Backend refactor"
sleep 1
post_event "task_simulated_flow" "completed" "P1" "Implement SQLite event store" "Done" "Task completed" "0.98" "Backend refactor" "Terminal - Backend refactor"

post_event "task_simulated_chrome" "running" "P2" "Generate product images" "Generating image" "ChatGPT is generating images" "0.90" "生成图片" "ChatGPT - 生成图片 - Chrome"
sleep 1
post_event "task_simulated_chrome" "completed" "P1" "Generate product images" "Done" "Image generation completed" "0.88" "生成图片" "ChatGPT - 生成图片 - Chrome"

post_event "task_simulated_failed" "running" "P2" "Run integration tests" "Running tests" "Tests are running" "0.98" "Test runner" "Terminal - Test runner"
sleep 1
post_event "task_simulated_failed" "failed" "P0" "Run integration tests" "Tests failed" "Integration tests failed" "0.98" "Test runner" "Terminal - Test runner"

post_event "task_simulated_idle" "running" "P2" "Research browser adapter" "Observing browser tab" "Browser adapter is running" "0.98" "Browser adapter" "Terminal - Browser adapter"
sleep 1
post_event "task_simulated_idle" "idle_but_not_done" "P0" "Research browser adapter" "No recent activity" "No output for 10 minutes" "0.72" "Browser adapter" "Terminal - Browser adapter"

echo "Current tasks:"
curl -sS "${curl_auth_args[@]}" "${BASE_URL}/tasks"
echo
