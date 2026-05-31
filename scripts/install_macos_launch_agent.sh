#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

resolve_launch_agent_label() {
  if [[ -n "${AI_MONITOR_LAUNCH_AGENT_LABEL:-}" ]]; then
    printf "%s\n" "${AI_MONITOR_LAUNCH_AGENT_LABEL}"
  elif [[ -n "${AI_MONITOR_BUNDLE_ID:-}" && "${AI_MONITOR_BUNDLE_ID}" != local.* ]]; then
    printf "%s.daemon\n" "${AI_MONITOR_BUNDLE_ID}"
  else
    printf "%s\n" "local.ai-monitor.daemon"
  fi
}

LABEL="$(resolve_launch_agent_label)"
PLIST_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="${HOME}/Library/Logs/AI Monitor"
UID_VALUE="$(id -u)"
ACTION="${1:-install}"

xml_escape() {
  sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&apos;/g"
}

write_plist() {
  mkdir -p "$(dirname "${PLIST_PATH}")" "${LOG_DIR}"

  local root_xml log_xml bind_xml database_xml config_xml
  root_xml="$(printf "%s" "${ROOT_DIR}" | xml_escape)"
  log_xml="$(printf "%s" "${LOG_DIR}" | xml_escape)"
  bind_xml="$(printf "%s" "${AI_MONITOR_DAEMON_BIND:-127.0.0.1:4318}" | xml_escape)"
  database_xml="$(printf "%s" "${AI_MONITOR_DATABASE:-${ROOT_DIR}/ai-monitor.db}" | xml_escape)"
  config_xml="$(printf "%s" "${AI_MONITOR_CONFIG:-${ROOT_DIR}/config/default.toml}" | xml_escape)"

  cat > "${PLIST_PATH}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${root_xml}/scripts/run_daemon_launch_agent.sh</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${root_xml}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>AI_MONITOR_DAEMON_BIND</key>
    <string>${bind_xml}</string>
    <key>AI_MONITOR_DATABASE</key>
    <string>${database_xml}</string>
    <key>AI_MONITOR_CONFIG</key>
    <string>${config_xml}</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>StandardOutPath</key>
  <string>${log_xml}/daemon.out.log</string>
  <key>StandardErrorPath</key>
  <string>${log_xml}/daemon.err.log</string>
</dict>
</plist>
PLIST

  /usr/bin/plutil -lint "${PLIST_PATH}" >/dev/null
}

install_agent() {
  write_plist
  launchctl bootout "gui/${UID_VALUE}" "${PLIST_PATH}" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/${UID_VALUE}" "${PLIST_PATH}"
  launchctl kickstart -k "gui/${UID_VALUE}/${LABEL}" >/dev/null 2>&1 || true
  echo "Installed ${PLIST_PATH}"
}

uninstall_agent() {
  launchctl bootout "gui/${UID_VALUE}" "${PLIST_PATH}" >/dev/null 2>&1 || true
  rm -f "${PLIST_PATH}"
  echo "Removed ${PLIST_PATH}"
}

case "${ACTION}" in
  install)
    install_agent
    ;;
  uninstall)
    uninstall_agent
    ;;
  restart)
    install_agent
    ;;
  status)
    launchctl print "gui/${UID_VALUE}/${LABEL}"
    ;;
  *)
    echo "Usage: $0 [install|uninstall|restart|status]" >&2
    exit 2
    ;;
esac
