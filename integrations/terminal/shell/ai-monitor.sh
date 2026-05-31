#!/usr/bin/env bash

if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  _AI_MONITOR_SHELL_SOURCE="${BASH_SOURCE[0]}"
elif [[ -n "${ZSH_VERSION:-}" ]]; then
  _AI_MONITOR_SHELL_SOURCE="${(%):-%N}"
else
  _AI_MONITOR_SHELL_SOURCE="$0"
fi

AI_MONITOR_TERMINAL_ROOT="${AI_MONITOR_TERMINAL_ROOT:-$(cd "$(dirname "$_AI_MONITOR_SHELL_SOURCE")/.." && pwd)}"
AI_MONITOR_TERMINAL_ADAPTER="${AI_MONITOR_TERMINAL_ADAPTER:-$AI_MONITOR_TERMINAL_ROOT/ai-monitor-terminal.js}"
AI_MONITOR_SESSION_TASK_ID="${AI_MONITOR_SESSION_TASK_ID:-terminal_session_$(date +%s)_$$}"

ai_monitor_event() {
  local status="${1:-running}"
  local title="${2:-Terminal task}"
  local task_args=()

  if [[ $# -gt 0 ]]; then shift; fi
  if [[ $# -gt 0 ]]; then shift; fi

  if [[ -z "${AI_MONITOR_TASK_ID:-}" ]]; then
    task_args=(--task-id "$AI_MONITOR_SESSION_TASK_ID")
  fi

  node "$AI_MONITOR_TERMINAL_ADAPTER" event \
    --status "$status" \
    --title "$title" \
    "${task_args[@]}" \
    "$@"
}

ai_monitor_run() {
  local title="${1:-Terminal command}"

  if [[ $# -gt 0 ]]; then shift; fi

  node "$AI_MONITOR_TERMINAL_ADAPTER" run \
    --title "$title" \
    -- "$@"
}

ai_monitor_close() {
  local task_args=()

  if [[ -z "${AI_MONITOR_TASK_ID:-}" ]]; then
    task_args=(--task-id "$AI_MONITOR_SESSION_TASK_ID")
  fi

  node "$AI_MONITOR_TERMINAL_ADAPTER" close \
    --quiet \
    "${task_args[@]}" \
    "$@"
}

ai_monitor_install_terminal_close_trap() {
  if [[ -n "$(trap -p EXIT)" ]]; then
    return
  fi
  trap 'ai_monitor_close >/dev/null 2>&1 || true' EXIT
}

alias aim-event=ai_monitor_event
alias aim-run=ai_monitor_run
alias aim-close=ai_monitor_close

if [[ "${AI_MONITOR_AUTO_CLOSE_TRAP:-1}" != "0" ]]; then
  ai_monitor_install_terminal_close_trap
fi
