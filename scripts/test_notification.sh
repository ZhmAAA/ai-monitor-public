#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${AI_MONITOR_URL:-http://127.0.0.1:4318}"
PROVIDER_ID="${1:-desktop}"
API_TOKEN="${AI_MONITOR_API_TOKEN:-${AI_MONITOR_TOKEN:-}}"
if [[ -z "$API_TOKEN" && -f "${AI_MONITOR_API_TOKEN_FILE:-$HOME/.ai-monitor/api-token}" ]]; then
  API_TOKEN="$(tr -d '\n\r' < "${AI_MONITOR_API_TOKEN_FILE:-$HOME/.ai-monitor/api-token}")"
fi

curl_auth_args=()
if [[ -n "$API_TOKEN" ]]; then
  curl_auth_args=(-H "x-ai-monitor-token: $API_TOKEN")
fi

curl -sS \
  -X POST "${BASE_URL}/notifications/test" \
  -H "content-type: application/json" \
  "${curl_auth_args[@]}" \
  -d @- <<JSON
{
  "provider_id": "${PROVIDER_ID}",
  "title": "AI Monitor provider test",
  "message": "This is a test notification from AI Monitor.",
  "source": "ai-monitor",
  "workspace": "$(pwd)",
  "status": "completed",
  "priority": "P1"
}
JSON
echo
