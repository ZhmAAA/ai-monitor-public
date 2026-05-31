#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER="${AI_MONITOR_TERMINAL_ADAPTER:-$SCRIPT_DIR/ai-monitor-terminal.js}"

exec node "$ADAPTER" hook claude-code "$@"
