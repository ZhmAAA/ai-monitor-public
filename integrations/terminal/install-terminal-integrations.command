#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="${SCRIPT_DIR}/install-packaged-integrations.js"

fail() {
  printf 'AI Monitor terminal integration install failed: %s\n' "$*" >&2
  exit 1
}

if ! command -v node >/dev/null 2>&1; then
  cat >&2 <<'EOF'
AI Monitor Terminal Integrations require Node.js, but the `node` command was not found.

Install Node.js from https://nodejs.org/ or with Homebrew:
  brew install node

Then rerun install-terminal-integrations.command.
EOF
  exit 1
fi

if [[ ! -f "${INSTALLER}" ]]; then
  fail "missing packaged installer next to this command file: ${INSTALLER}"
fi

if [[ $# -eq 0 ]]; then
  if [[ -t 0 ]] && command -v osascript >/dev/null 2>&1; then
    cat <<'EOF'
AI Monitor Terminal Integrations

This installer copies the terminal adapters to:
  ~/Library/Application Support/AI Monitor/terminal-integrations

Then it can wire Claude Code and Codex CLI hooks for one existing project folder.
Choose a project folder in the next dialog, or cancel without changing anything.

EOF
    project_path="$(/usr/bin/osascript <<'APPLESCRIPT' || true
try
  set selectedFolder to choose folder with prompt "Choose the repo/project folder for AI Monitor terminal hooks. Cancel makes no changes."
  POSIX path of selectedFolder
on error number -128
  error number -128
end try
APPLESCRIPT
)"
    if [[ -n "${project_path}" ]]; then
      set -- --project "${project_path}"
    else
      echo "No project folder selected; no changes were made."
      echo "To copy adapters without hooks, run: ./integrations/terminal/install-terminal-integrations.command --only-copy"
      exit 0
    fi
  elif [[ -t 0 ]]; then
    echo "No project folder selector is available; no changes were made."
    echo "Run with --project /path/to/repo, --user, or --only-copy."
    exit 2
  else
    exec node "${INSTALLER}" --help
  fi
fi

exec node "${INSTALLER}" "$@"
