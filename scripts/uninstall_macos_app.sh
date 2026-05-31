#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${AI_MONITOR_APP_NAME:-AI Monitor}"
if [[ -z "${APP_NAME}" || "${APP_NAME}" == */* ]]; then
  echo "Unsafe app name: ${APP_NAME}" >&2
  exit 2
fi
APP_PATH="${AI_MONITOR_APP_PATH:-/Applications/${APP_NAME}.app}"

resolve_bundle_id() {
  if [[ -n "${AI_MONITOR_BUNDLE_ID:-}" ]]; then
    printf "%s\n" "${AI_MONITOR_BUNDLE_ID}"
  elif [[ -f "${APP_PATH}/Contents/Info.plist" ]]; then
    /usr/bin/plutil -extract CFBundleIdentifier raw -o - "${APP_PATH}/Contents/Info.plist" 2>/dev/null ||
      printf "%s\n" "local.ai-monitor.desktop"
  else
    printf "%s\n" "local.ai-monitor.desktop"
  fi
}

BUNDLE_ID="$(resolve_bundle_id)"

resolve_launch_agent_label() {
  if [[ -n "${AI_MONITOR_LAUNCH_AGENT_LABEL:-}" ]]; then
    printf "%s\n" "${AI_MONITOR_LAUNCH_AGENT_LABEL}"
  elif [[ "${BUNDLE_ID}" != local.* ]]; then
    printf "%s.daemon\n" "${BUNDLE_ID}"
  else
    printf "%s\n" "local.ai-monitor.daemon"
  fi
}

validate_identifier() {
  local value="$1"
  local label="$2"
  if [[ -z "${value}" || ! "${value}" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Unsafe ${label}: ${value}" >&2
    echo "${label} may only contain letters, numbers, dots, underscores, and hyphens." >&2
    exit 2
  fi
}

normalize_path() {
  local path="$1"
  path="${path%/}"
  [[ -n "${path}" ]] || path="/"
  printf "%s\n" "${path}"
}

assert_safe_remove_path() {
  local path
  path="$(normalize_path "$1")"
  if [[ "${path}" == *"/../"* || "${path}" == */.. ]]; then
    echo "Refusing to remove path containing parent-directory traversal: ${path}" >&2
    exit 2
  fi
  case "${path}" in
    ""|"/"|"/Applications"|"/Library"|"/Users"|"/Users/"*"/Library"|"/Users/"*"/Library/Application Support"|"/Users/"*"/Library/Logs"|"/Users/"*"/Library/Preferences"|"/Users/"*"/Library/LaunchAgents")
      echo "Refusing to remove unsafe broad path: ${path}" >&2
      exit 2
      ;;
  esac
  if [[ "${path}" == "${HOME}" || "${path}" == "${HOME}/." || "${path}" == "${HOME}/.." ]]; then
    echo "Refusing to remove home directory path: ${path}" >&2
    exit 2
  fi
}

LABEL="$(resolve_launch_agent_label)"
validate_identifier "${BUNDLE_ID}" "bundle identifier"
validate_identifier "${LABEL}" "LaunchAgent label"
if [[ "${APP_PATH}" != *.app ]]; then
  echo "Unsafe app path: ${APP_PATH}" >&2
  echo "AI_MONITOR_APP_PATH must point to a .app bundle." >&2
  exit 2
fi
PLIST_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"
DATA_DIR="${HOME}/Library/Application Support/AI Monitor"
TOKEN_DIR="${HOME}/.ai-monitor"
LOG_DIR="${HOME}/Library/Logs/AI Monitor"
PREFERENCES_PLIST="${HOME}/Library/Preferences/${BUNDLE_ID}.plist"
UID_VALUE="$(id -u)"

ASSUME_YES=0
DRY_RUN=0
KEEP_DATA=0
KEEP_TOKEN=0
KEEP_LOGS=0
KEEP_PREFERENCES=0

usage() {
  cat <<USAGE
Usage: $0 [--yes] [--dry-run] [--keep-data] [--keep-token] [--keep-logs] [--keep-preferences]

Removes the macOS app, login daemon, and local AI Monitor state.
Without --yes, this script only prints what it would remove.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)
      ASSUME_YES=1
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    --keep-data)
      KEEP_DATA=1
      ;;
    --keep-token)
      KEEP_TOKEN=1
      ;;
    --keep-logs)
      KEEP_LOGS=1
      ;;
    --keep-preferences)
      KEEP_PREFERENCES=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

run_or_print() {
  if [[ "${ASSUME_YES}" == "1" && "${DRY_RUN}" != "1" ]]; then
    "$@"
  else
    printf 'Would run:'
    printf ' %q' "$@"
    printf '\n'
  fi
}

remove_path() {
  local path="$1"
  assert_safe_remove_path "${path}"
  if [[ ! -e "${path}" ]]; then
    echo "Not present: ${path}"
    return
  fi
  run_or_print rm -rf "${path}"
}

bootout_agent() {
  if [[ "${ASSUME_YES}" == "1" && "${DRY_RUN}" != "1" ]]; then
    launchctl bootout "gui/${UID_VALUE}" "${PLIST_PATH}" >/dev/null 2>&1 || true
  else
    run_or_print launchctl bootout "gui/${UID_VALUE}" "${PLIST_PATH}"
  fi
}

remove_preferences() {
  if [[ "${KEEP_PREFERENCES}" == "1" ]]; then
    echo "Keeping preferences: ${PREFERENCES_PLIST}"
    return
  fi

  assert_safe_remove_path "${PREFERENCES_PLIST}"
  if [[ "${ASSUME_YES}" == "1" && "${DRY_RUN}" != "1" ]]; then
    /usr/bin/defaults delete "${BUNDLE_ID}" >/dev/null 2>&1 || true
    rm -f "${PREFERENCES_PLIST}"
  else
    run_or_print /usr/bin/defaults delete "${BUNDLE_ID}"
    run_or_print rm -f "${PREFERENCES_PLIST}"
  fi
}

quit_running_app() {
  local quit_by_id quit_by_name
  quit_by_id='tell application id "'"${BUNDLE_ID}"'" to quit'
  quit_by_name='tell application "'"${APP_NAME}"'" to quit'

  if [[ "${ASSUME_YES}" == "1" && "${DRY_RUN}" != "1" ]]; then
    /usr/bin/osascript -e "${quit_by_id}" >/dev/null 2>&1 ||
      /usr/bin/osascript -e "${quit_by_name}" >/dev/null 2>&1 ||
      true
    sleep 1
  else
    run_or_print /usr/bin/osascript -e "${quit_by_id}"
  fi
}

quit_running_app
bootout_agent
remove_path "${PLIST_PATH}"
remove_path "${APP_PATH}"
remove_preferences

if [[ "${KEEP_DATA}" != "1" ]]; then
  remove_path "${DATA_DIR}"
else
  echo "Keeping data: ${DATA_DIR}"
fi

if [[ "${KEEP_TOKEN}" != "1" ]]; then
  remove_path "${TOKEN_DIR}"
else
  echo "Keeping token directory: ${TOKEN_DIR}"
fi

if [[ "${KEEP_LOGS}" != "1" ]]; then
  remove_path "${LOG_DIR}"
else
  echo "Keeping logs: ${LOG_DIR}"
fi

if [[ "${ASSUME_YES}" != "1" || "${DRY_RUN}" == "1" ]]; then
  echo "Dry run only. Re-run with --yes to remove these paths."
else
  echo "AI Monitor uninstall cleanup complete."
fi
