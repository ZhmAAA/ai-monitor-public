#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIND="${AI_MONITOR_DAEMON_BIND:-127.0.0.1:4318}"
DATABASE="${AI_MONITOR_DATABASE:-${ROOT_DIR}/ai-monitor.db}"
CONFIG="${AI_MONITOR_CONFIG:-${ROOT_DIR}/config/default.toml}"
BINARY="${AI_MONITOR_DAEMON_BINARY:-${ROOT_DIR}/target/debug/ai-monitor-daemon}"

cd "${ROOT_DIR}"

if [[ -x "${BINARY}" ]]; then
  exec "${BINARY}" --bind "${BIND}" --database "${DATABASE}" --config "${CONFIG}"
fi

exec /usr/bin/env cargo run -p ai-monitor-daemon -- \
  --bind "${BIND}" \
  --database "${DATABASE}" \
  --config "${CONFIG}"
