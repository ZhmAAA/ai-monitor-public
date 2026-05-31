#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON_URL="${AI_MONITOR_URL:-http://127.0.0.1:4318}"
WORKSPACE="${AI_MONITOR_WORKSPACE:-$ROOT_DIR}"
ADAPTER="$ROOT_DIR/integrations/terminal/ai-monitor-terminal.js"
RUN_ID="$(date +%s)"
CLAUDE_SESSION_ID="claude-official-test-$RUN_ID"
CODEX_SESSION_ID="codex-official-test-$RUN_ID"

assert_installer_has_codex_session_end() {
  local temp_project
  temp_project="$(mktemp -d)"
  node "$ROOT_DIR/integrations/terminal/install-official-hooks.js" codex-cli --project "$temp_project" >/dev/null
  node - "$temp_project/.codex/hooks.json" <<'NODE'
const fs = require("node:fs");
const filePath = process.argv[2];
const config = JSON.parse(fs.readFileSync(filePath, "utf8"));
const sessionEnd = config.hooks?.SessionEnd;
if (!Array.isArray(sessionEnd)) {
  throw new Error("Codex installer did not write hooks.SessionEnd");
}
const hasArchiveMatcher = sessionEnd.some((entry) => String(entry.matcher || "").includes("archive"));
if (!hasArchiveMatcher) {
  throw new Error("Codex SessionEnd hook is missing archive matcher");
}
const hasCommand = sessionEnd.some((entry) =>
  Array.isArray(entry.hooks) &&
    entry.hooks.some((hook) =>
      hook?.type === "command" &&
        String(hook.command || "").includes("codex-cli/official-hook.sh")
    )
);
if (!hasCommand) {
  throw new Error("Codex SessionEnd hook is missing AI Monitor command");
}
NODE
	  rm -rf "$temp_project"
}

assert_packaged_installer_uses_stable_hook_path() {
  local temp_project temp_rerun_project temp_install stable_hook stable_installer
  temp_project="$(mktemp -d)"
  temp_rerun_project="$(mktemp -d)"
  temp_install="$(mktemp -d)"
  stable_hook="$temp_install/integrations/terminal/codex-cli/official-hook.sh"
  stable_installer="$temp_install/integrations/terminal/install-packaged-integrations.js"

  node "$ROOT_DIR/integrations/terminal/install-packaged-integrations.js" \
    --target-dir "$temp_install" \
    --codex-project "$temp_project" >/dev/null
  node "$stable_installer" \
    --target-dir "$temp_install" \
    --codex-project "$temp_rerun_project" >/dev/null

  node - "$temp_project/.codex/hooks.json" "$stable_hook" <<'NODE'
const fs = require("node:fs");
const filePath = process.argv[2];
const stableHook = process.argv[3];
const config = JSON.parse(fs.readFileSync(filePath, "utf8"));
const groups = Object.values(config.hooks || {}).flat();
const commands = groups.flatMap((entry) =>
  Array.isArray(entry?.hooks) ? entry.hooks.map((hook) => String(hook.command || "")) : []
);
if (!commands.some((command) => command.includes(stableHook))) {
  throw new Error(`packaged installer did not write stable hook path: ${stableHook}`);
}
NODE
  node - "$temp_rerun_project/.codex/hooks.json" "$stable_hook" <<'NODE'
const fs = require("node:fs");
const filePath = process.argv[2];
const stableHook = process.argv[3];
const config = JSON.parse(fs.readFileSync(filePath, "utf8"));
const groups = Object.values(config.hooks || {}).flat();
const commands = groups.flatMap((entry) =>
  Array.isArray(entry?.hooks) ? entry.hooks.map((hook) => String(hook.command || "")) : []
);
if (!commands.some((command) => command.includes(stableHook))) {
  throw new Error(`packaged installer rerun did not keep stable hook path: ${stableHook}`);
}
NODE

  rm -rf "$temp_project" "$temp_rerun_project" "$temp_install"
}

assert_project_installers_reject_missing_project_path() {
  local temp_parent temp_install missing_project packaged_error official_error
  temp_parent="$(mktemp -d)"
  temp_install="$(mktemp -d)"
  missing_project="$temp_parent/missing-project"
  packaged_error="$temp_parent/packaged.err"
  official_error="$temp_parent/official.err"

  if node "$ROOT_DIR/integrations/terminal/install-packaged-integrations.js" \
    --target-dir "$temp_install" \
    --codex-project "$missing_project" 2>"$packaged_error"; then
    echo "packaged installer accepted missing project path" >&2
    exit 1
  fi

  if [[ -d "$missing_project" ]]; then
    echo "packaged installer created a missing project directory" >&2
    exit 1
  fi

  if ! rg -q "existing project directory" "$packaged_error"; then
    echo "packaged installer did not explain missing project path" >&2
    cat "$packaged_error" >&2
    exit 1
  fi

  if node "$ROOT_DIR/integrations/terminal/install-official-hooks.js" \
    codex-cli \
    --project "$missing_project" 2>"$official_error"; then
    echo "official hook installer accepted missing project path" >&2
    exit 1
  fi

  if [[ -d "$missing_project" ]]; then
    echo "official hook installer created a missing project directory" >&2
    exit 1
  fi

  if ! rg -q "existing project directory" "$official_error"; then
    echo "official hook installer did not explain missing project path" >&2
    cat "$official_error" >&2
    exit 1
  fi

  rm -rf "$temp_parent" "$temp_install"
}

assert_command_wrapper_forwards_help() {
  local wrapper help_output
  wrapper="$ROOT_DIR/integrations/terminal/install-terminal-integrations.command"
  if [[ ! -x "$wrapper" ]]; then
    echo "terminal command wrapper is not executable: $wrapper" >&2
    exit 1
  fi
  help_output="$("$wrapper" --help)"
  if ! rg -q "packaged terminal integration installer" <<< "$help_output"; then
    echo "terminal command wrapper did not forward installer help" >&2
    echo "$help_output" >&2
    exit 1
  fi
}

assert_task_deleted() {
  local task_id="$1"
  node - "$DAEMON_URL" "$task_id" <<'NODE'
const fs = require("node:fs");
const http = require("node:http");
const https = require("node:https");
const os = require("node:os");
const path = require("node:path");

const daemonUrl = process.argv[2].replace(/\/$/, "");
const taskId = process.argv[3];
const tokenPath = process.env.AI_MONITOR_API_TOKEN_FILE ||
  path.join(os.homedir(), ".ai-monitor", "api-token");
const token = process.env.AI_MONITOR_API_TOKEN ||
  (fs.existsSync(tokenPath) ? fs.readFileSync(tokenPath, "utf8").trim() : "");
const url = new URL(`${daemonUrl}/tasks/${encodeURIComponent(taskId)}`);
const client = url.protocol === "https:" ? https : http;
const headers = token ? { "x-ai-monitor-token": token } : {};

const request = client.request(url, { method: "GET", headers }, (response) => {
  response.resume();
  response.on("end", () => {
    if (response.statusCode === 404) {
      process.exit(0);
    }
    throw new Error(`expected ${taskId} to be deleted; daemon returned ${response.statusCode}`);
  });
});
request.on("error", (error) => {
  throw error;
});
request.end();
NODE
}

post_hook() {
  local hook_script="$1"
  local payload="$2"

  printf '%s' "$payload" | "$hook_script" \
    --strict \
    --debug \
    --daemon-url "$DAEMON_URL"
}

cleanup() {
  node "$ADAPTER" close \
    --quiet \
    --daemon-url "$DAEMON_URL" \
    --task-id "claude-code_$CLAUDE_SESSION_ID" || true
  node "$ADAPTER" close \
    --quiet \
    --daemon-url "$DAEMON_URL" \
    --task-id "codex-cli_$CODEX_SESSION_ID" || true
}

trap cleanup EXIT

assert_installer_has_codex_session_end
assert_packaged_installer_uses_stable_hook_path
assert_project_installers_reject_missing_project_path
assert_command_wrapper_forwards_help

post_hook "$ROOT_DIR/integrations/terminal/claude-code/official-hook.sh" \
  "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"$CLAUDE_SESSION_ID\",\"cwd\":\"$WORKSPACE\",\"source\":\"startup\",\"model\":\"claude\"}"

post_hook "$ROOT_DIR/integrations/terminal/claude-code/official-hook.sh" \
  "{\"hook_event_name\":\"Notification\",\"session_id\":\"$CLAUDE_SESSION_ID\",\"cwd\":\"$WORKSPACE\",\"notification_type\":\"permission_prompt\",\"message\":\"Claude Code permission requested\"}"

post_hook "$ROOT_DIR/integrations/terminal/codex-cli/official-hook.sh" \
  "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"$CODEX_SESSION_ID\",\"turn_id\":\"turn-test\",\"cwd\":\"$WORKSPACE\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cargo test\"}}"

post_hook "$ROOT_DIR/integrations/terminal/codex-cli/official-hook.sh" \
  "{\"hook_event_name\":\"Stop\",\"session_id\":\"$CODEX_SESSION_ID\",\"turn_id\":\"turn-test\",\"cwd\":\"$WORKSPACE\",\"last_assistant_message\":\"Codex turn complete\"}"

post_hook "$ROOT_DIR/integrations/terminal/codex-cli/official-hook.sh" \
  "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"$CODEX_SESSION_ID\",\"cwd\":\"$WORKSPACE\",\"reason\":\"archive\"}"

assert_task_deleted "codex-cli_$CODEX_SESSION_ID"

cleanup
trap - EXIT

echo "Posted and cleaned official CLI hook smoke events"
