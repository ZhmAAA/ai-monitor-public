#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${AI_MONITOR_APP_NAME:-AI Monitor}"
BUILD_DIR="${AI_MONITOR_APP_BUILD_DIR:-${ROOT_DIR}/target/macos-app}"
DIST_DIR="${AI_MONITOR_DIST_DIR:-${ROOT_DIR}/target/macos-dist}"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
ZIP_PATH="${DIST_DIR}/${APP_NAME}.zip"
DMG_PATH="${DIST_DIR}/${APP_NAME}.dmg"
BROWSER_EXTENSION_ZIP_PATH="${DIST_DIR}/${APP_NAME} Browser Extension.zip"
IDE_EXTENSION_ZIP_PATH="${DIST_DIR}/${APP_NAME} IDE Extension.zip"
IDE_EXTENSION_VSIX_PATH="${DIST_DIR}/${APP_NAME} IDE Extension.vsix"
TERMINAL_INTEGRATIONS_ZIP_PATH="${DIST_DIR}/${APP_NAME} Terminal Integrations.zip"
CHECKSUMS_PATH="${DIST_DIR}/SHA256SUMS.txt"
RELEASE_MANIFEST_PATH="${DIST_DIR}/RELEASE_MANIFEST.json"
REQUIRE_NOTARIZATION="${AI_MONITOR_REQUIRE_NOTARIZATION:-${AI_MONITOR_RELEASE:-0}}"
MIN_MACOS_VERSION="${AI_MONITOR_MACOS_MIN_VERSION:-13.0}"
if [[ "${REQUIRE_NOTARIZATION}" == "1" ]]; then
  DEFAULT_MACOS_ARCHS="arm64 x86_64"
else
  DEFAULT_MACOS_ARCHS="$(uname -m)"
fi
MACOS_ARCHS_RAW="${AI_MONITOR_MACOS_ARCHS:-${DEFAULT_MACOS_ARCHS}}"
APPLE_EVENTS_ENTITLEMENT="com.apple.security.automation.apple-events"
read -r -a EXPECTED_MACOS_ARCHS <<< "${MACOS_ARCHS_RAW}"

require_path() {
  local path="$1"
  if [[ ! -e "${path}" ]]; then
    echo "Missing: ${path}" >&2
    exit 1
  fi
}

run_workspace_tests() {
  if ! command -v cargo >/dev/null 2>&1; then
    echo "cargo is required to run release workspace tests" >&2
    exit 1
  fi

  (
    cd "${ROOT_DIR}"
    cargo test --workspace >/dev/null
  )
}

validate_default_config() {
  local config_path="$1"
  CONFIG_PATH="${config_path}" node <<'NODE'
const fs = require("node:fs");

const configPath = process.env.CONFIG_PATH;
const text = fs.readFileSync(configPath, "utf8");
const providers = [];
const rules = [];
let section = "";
let current = null;

function stripComment(line) {
  let quoted = false;
  for (let index = 0; index < line.length; index += 1) {
    const char = line[index];
    if (char === '"' && line[index - 1] !== "\\") quoted = !quoted;
    if (char === "#" && !quoted) return line.slice(0, index);
  }
  return line;
}

function parseValue(raw) {
  const value = raw.trim();
  if (value === "true") return true;
  if (value === "false") return false;
  if (value.startsWith("[") && value.endsWith("]")) {
    return Array.from(value.matchAll(/"([^"]*)"/g), (match) => match[1]);
  }
  const quoted = value.match(/^"(.*)"$/);
  return quoted ? quoted[1] : value;
}

for (const rawLine of text.split(/\r?\n/)) {
  const line = stripComment(rawLine).trim();
  if (!line) continue;
  if (line === "[[providers]]") {
    current = {};
    providers.push(current);
    section = "providers";
    continue;
  }
  if (line === "[[rules]]") {
    current = {};
    rules.push(current);
    section = "rules";
    continue;
  }
  const table = line.match(/^\[([A-Za-z0-9_.-]+)\]$/);
  if (table) {
    current = null;
    section = table[1];
    continue;
  }
  const assignment = line.match(/^([A-Za-z0-9_]+)\s*=\s*(.+)$/);
  if (!assignment) continue;
  const [, key, rawValue] = assignment;
  const value = parseValue(rawValue);
  if (current) {
    current[key] = value;
  } else if (section) {
    current = current;
  }
  if (!current && section) {
    globalThis[section] = globalThis[section] || {};
    globalThis[section][key] = value;
  }
}

function fail(message) {
  throw new Error(`${configPath}: ${message}`);
}

if (globalThis.api?.auth_enabled !== true) {
  fail("api.auth_enabled must be true");
}
for (const key of ["redact_external_workspace_paths", "redact_external_prompts", "redact_external_replies"]) {
  if (globalThis.privacy?.[key] !== true) {
    fail(`privacy.${key} must be true`);
  }
}

const desktop = providers.find((provider) => provider.id === "desktop");
if (!desktop || desktop.type !== "desktop" || desktop.enabled !== true) {
  fail("desktop provider must be enabled by default");
}
const externalProviders = providers.filter((provider) => provider.id !== "desktop");
if (externalProviders.length > 0) {
  fail(`ordinary-user default config must not preconfigure external providers: ${externalProviders.map((provider) => provider.id).join(", ")}`);
}
if (providers.length !== 1) {
  fail(`ordinary-user default config must contain exactly one provider, found ${providers.length}`);
}
if (/\$\{[A-Z0-9_]+}/.test(text)) {
  fail("ordinary-user default config must not contain unresolved environment placeholders");
}
for (const rule of rules) {
  const sendTo = Array.isArray(rule.send_to) ? rule.send_to : [];
  const externalTargets = sendTo.filter((target) => target !== "desktop");
  if (externalTargets.length > 0) {
    fail(`default notification rules must only send to desktop; found ${externalTargets.join(", ")}`);
  }
}
NODE
}

validate_first_run_guide() {
  local guide_path="$1"
  local expected_browser_extension_install_url="${2:-}"
  if ! rg -q "Copy API token" "${guide_path}" ||
     ! rg -q "Desktop app observer" "${guide_path}" ||
     ! rg -q "Copy troubleshooting guide" "${guide_path}" ||
     ! rg -q "Copy license notices" "${guide_path}" ||
     ! rg -q "Copy privacy notice" "${guide_path}" ||
     ! rg -q "Copy uninstall guide" "${guide_path}" ||
     ! rg -q "Copy diagnostics" "${guide_path}" ||
     ! rg -q "Open browser install link" "${guide_path}" ||
     ! rg -q "Copy browser install link" "${guide_path}" ||
     ! rg -q "Settings opens automatically on first launch" "${guide_path}" ||
     ! rg -q "Chrome Web Store or managed browser extension" "${guide_path}" ||
     ! rg -q "AI Monitor IDE Extension.vsix" "${guide_path}" ||
     ! rg -q "AI Monitor IDE Extension.zip" "${guide_path}" ||
     ! rg -q "Extensions: Install from VSIX" "${guide_path}" ||
     ! rg -q "AI Monitor: Send Test Event" "${guide_path}" ||
     ! rg -q "Install AI Monitor Terminal Integrations.command" "${guide_path}" ||
     ! rg -q "install-terminal-integrations.command" "${guide_path}" ||
     ! rg -q "checks for Node.js" "${guide_path}"; then
    echo "${guide_path} is missing setup, permission, or support guidance" >&2
    exit 1
  fi

  if rg -n '<browser-extension-install-url>' "${guide_path}"; then
    echo "${guide_path} contains an unresolved browser extension install URL placeholder" >&2
    exit 1
  fi

  if [[ -n "${expected_browser_extension_install_url}" ]] &&
     ! rg -Fq "${expected_browser_extension_install_url}" "${guide_path}"; then
    echo "${guide_path} must include the browser extension install URL from RELEASE_MANIFEST.json" >&2
    exit 1
  fi

  if rg -n 'AI Monitor Browser Extension\.zip|browser extension zip' "${guide_path}"; then
    echo "${guide_path} must not mention the internal browser extension zip in ordinary-user setup guidance" >&2
    exit 1
  fi

  if rg -n 'AI_MONITOR_API_TOKEN=|x-ai-monitor-token:|keychain://|hooks\.slack\.com/services|TELEGRAM_BOT_TOKEN|DISCORD_WEBHOOK_URL|PUSHOVER_TOKEN' "${guide_path}"; then
    echo "${guide_path} contains token, secret, or provider-secret examples that do not belong in the copied setup guide" >&2
    exit 1
  fi
}

validate_browser_extension_install_url_resource() {
  local resource_path="$1"
  local expected_url="${2:-}"

  require_path "${resource_path}"

  local actual_url
  actual_url="$(tr -d '\r\n' < "${resource_path}")"
  if [[ -n "${expected_url}" ]]; then
    if [[ "${actual_url}" != "${expected_url}" ]]; then
      echo "${resource_path} must exactly match the browser extension install URL from RELEASE_MANIFEST.json" >&2
      exit 1
    fi
  elif [[ -n "${actual_url}" ]]; then
    echo "${resource_path} must be empty when no browser extension install URL is configured" >&2
    exit 1
  fi
}

validate_terminal_installer_package() {
  local test_root package_dir stable_dir project_dir
  test_root="$(mktemp -d "${TMPDIR:-/tmp}/ai-monitor-terminal-installer.XXXXXX")"
  package_dir="${test_root}/package"
  stable_dir="${test_root}/stable"
  project_dir="${test_root}/project"

  if ! (
    set -euo pipefail
    mkdir -p "${package_dir}" "${project_dir}"
    unzip -q "${TERMINAL_INTEGRATIONS_ZIP_PATH}" -d "${package_dir}"
    (
      cd "${package_dir}"
      ./"Install AI Monitor Terminal Integrations.command" \
        --target-dir "${stable_dir}" \
        --project "${project_dir}" >/dev/null
    )

    require_path "${stable_dir}/integrations/terminal/ai-monitor-terminal.js"
    require_path "${stable_dir}/integrations/terminal/install-official-hooks.js"
    require_path "${stable_dir}/integrations/terminal/claude-code/official-hook.sh"
    require_path "${stable_dir}/integrations/terminal/codex-cli/official-hook.sh"
    require_path "${project_dir}/.claude/settings.local.json"
    require_path "${project_dir}/.codex/hooks.json"

    TERMINAL_STABLE_DIR="${stable_dir}" \
    TERMINAL_PACKAGE_DIR="${package_dir}" \
    TERMINAL_PROJECT_DIR="${project_dir}" \
    node <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const stableDir = fs.realpathSync.native(process.env.TERMINAL_STABLE_DIR);
const packageDir = fs.realpathSync.native(process.env.TERMINAL_PACKAGE_DIR);
const projectDir = process.env.TERMINAL_PROJECT_DIR;

function collectCommands(value, commands = []) {
  if (Array.isArray(value)) {
    for (const item of value) collectCommands(item, commands);
    return commands;
  }
  if (value && typeof value === "object") {
    if (typeof value.command === "string") commands.push(value.command);
    for (const item of Object.values(value)) collectCommands(item, commands);
  }
  return commands;
}

for (const relativePath of [".claude/settings.local.json", ".codex/hooks.json"]) {
  const configPath = path.join(projectDir, relativePath);
  const config = JSON.parse(fs.readFileSync(configPath, "utf8"));
  const commands = collectCommands(config);
  if (commands.length === 0) {
    throw new Error(`${relativePath} did not install hook commands`);
  }
  if (!commands.every((command) => command.includes(stableDir))) {
    throw new Error(`${relativePath} hook commands must point at the stable install directory`);
  }
  if (commands.some((command) => command.includes(packageDir))) {
    throw new Error(`${relativePath} hook commands must not point at the temporary extracted package`);
  }
}
NODE
  ); then
    rm -rf "${test_root}"
    echo "Terminal integrations packaged installer smoke test failed." >&2
    exit 1
  fi

  rm -rf "${test_root}"
}

validate_ide_extension_runtime_package() {
  local zip_path="$1"
  local extension_subdir="$2"
  local label="$3"
  local test_root extension_dir
  test_root="$(mktemp -d "${TMPDIR:-/tmp}/ai-monitor-ide-extension.XXXXXX")"

  if ! (
    set -euo pipefail
    unzip -q "${zip_path}" -d "${test_root}/package"
    extension_dir="${test_root}/package/${extension_subdir}"
    require_path "${extension_dir}/package.json"
    require_path "${extension_dir}/extension.js"
    mkdir -p "${extension_dir}/node_modules/vscode"
    cat > "${extension_dir}/node_modules/vscode/index.js" <<'NODE'
const vscode = {
  __registeredCommands: [],
  __warnings: [],
  StatusBarAlignment: { Left: 1 },
  window: {
    activeTextEditor: undefined,
    createStatusBarItem() {
      return {
        text: "",
        tooltip: "",
        command: "",
        show() {},
        dispose() {},
      };
    },
    showWarningMessage(message) {
      vscode.__warnings.push(message);
      return Promise.resolve(message);
    },
    showInformationMessage(message) {
      vscode.__info = vscode.__info || [];
      vscode.__info.push(message);
      return Promise.resolve(message);
    },
  },
  env: {
    openExternal(uri) {
      vscode.__openedExternal = uri.toString();
      return Promise.resolve(true);
    },
  },
  Uri: {
    parse(value) {
      return { toString: () => value };
    },
  },
  commands: {
    registerCommand(command, callback) {
      vscode.__registeredCommands.push(command);
      return { dispose() {} };
    },
  },
  tasks: {
    onDidStartTaskProcess(callback) {
      vscode.__taskStartCallback = callback;
      return { dispose() {} };
    },
    onDidEndTaskProcess(callback) {
      vscode.__taskEndCallback = callback;
      return { dispose() {} };
    },
  },
  workspace: {
    workspaceFolders: [],
    getConfiguration() {
      return {
        get(_key, fallback) {
          return fallback;
        },
      };
    },
  },
};

module.exports = vscode;
NODE

    IDE_EXTENSION_DIR="${extension_dir}" IDE_EXTENSION_LABEL="${label}" node <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const extensionDir = process.env.IDE_EXTENSION_DIR;
const label = process.env.IDE_EXTENSION_LABEL;
const pkg = JSON.parse(fs.readFileSync(path.join(extensionDir, "package.json"), "utf8"));

if (pkg.name !== "ai-monitor-vscode") throw new Error(`${label}: package name mismatch`);
if (pkg.displayName !== "AI Monitor") throw new Error(`${label}: displayName must be AI Monitor`);
if (pkg.license !== "MIT") throw new Error(`${label}: license must be MIT`);
if (pkg.main !== "./extension.js") throw new Error(`${label}: main must be ./extension.js`);
if (!pkg.engines?.vscode) throw new Error(`${label}: VS Code engine support is required`);

const commands = (pkg.contributes?.commands || []).map((entry) => entry.command);
if (commands.length < 10) throw new Error(`${label}: task state and support commands are missing`);
for (const requiredCommand of ["aiMonitor.sendTestEvent", "aiMonitor.openDesktopSettings"]) {
  if (!commands.includes(requiredCommand)) {
    throw new Error(`${label}: ${requiredCommand} command is required for first-run recovery`);
  }
}
for (const command of commands) {
  if (!(pkg.activationEvents || []).includes(`onCommand:${command}`)) {
    throw new Error(`${label}: activationEvents must include onCommand:${command}`);
  }
}

const properties = pkg.contributes?.configuration?.properties || {};
if (properties["aiMonitor.daemonUrl"]?.default !== "http://127.0.0.1:4318") {
  throw new Error(`${label}: daemonUrl must default to the local daemon`);
}
if (!/\.ai-monitor\/api-token/.test(properties["aiMonitor.apiToken"]?.description || "")) {
  throw new Error(`${label}: apiToken setting must document the token-file fallback`);
}
if (properties["aiMonitor.autoReportTasks"]?.default !== true) {
  throw new Error(`${label}: auto task reporting should be enabled by default`);
}

const extension = require(path.join(extensionDir, "extension.js"));
if (typeof extension.activate !== "function" || typeof extension.deactivate !== "function") {
  throw new Error(`${label}: extension must export activate and deactivate`);
}

const context = { subscriptions: [] };
extension.activate(context);
const vscode = require(path.join(extensionDir, "node_modules", "vscode"));
const registered = new Set(vscode.__registeredCommands);
for (const command of commands) {
  if (!registered.has(command)) {
    throw new Error(`${label}: activate() did not register ${command}`);
  }
}
if (context.subscriptions.length < commands.length) {
  throw new Error(`${label}: activate() did not retain command disposables`);
}
if (vscode.__registeredCommands[0] !== "aiMonitor.sendTestEvent") {
  throw new Error(`${label}: first registered command should be the ordinary-user test event`);
}
NODE
  ); then
    rm -rf "${test_root}"
    echo "${label} runtime smoke test failed." >&2
    exit 1
  fi

  rm -rf "${test_root}"
}

validate_privacy_notice() {
  local privacy_path="$1"
  if ! rg -q "local-first by default" "${privacy_path}" ||
     ! rg -q "External notification providers are not configured or enabled by default" "${privacy_path}" ||
     ! rg -q "Local notification permission is requested only when" "${privacy_path}" ||
     ! rg -q "Desktop app observer is optional" "${privacy_path}" ||
     ! rg -q "Apple Events permission" "${privacy_path}" ||
     ! rg -q "browser install link" "${privacy_path}" ||
     ! rg -q "Uninstalling the app does not automatically delete local history" "${privacy_path}"; then
    echo "${privacy_path} is missing local storage, permission, browser install-link, external delivery, or cleanup guidance" >&2
    exit 1
  fi

  if rg -n 'AI_MONITOR_API_TOKEN=|x-ai-monitor-token:|keychain://|hooks\.slack\.com/services|TELEGRAM_BOT_TOKEN|DISCORD_WEBHOOK_URL|PUSHOVER_TOKEN' "${privacy_path}"; then
    echo "${privacy_path} contains token, secret, or provider-secret examples" >&2
    exit 1
  fi
}

validate_uninstall_guide() {
  local uninstall_path="$1"
  if ! rg -q "Remove login daemon" "${uninstall_path}" ||
     ! rg -q "Delete /Applications/AI Monitor.app" "${uninstall_path}" ||
     ! rg -q "Application Support/AI Monitor" "${uninstall_path}" ||
     ! rg -q ".ai-monitor" "${uninstall_path}" ||
     ! rg -q "Copy diagnostics" "${uninstall_path}"; then
    echo "${uninstall_path} is missing app, login-daemon, local-state, or support diagnostics cleanup guidance" >&2
    exit 1
  fi

  if rg -n 'AI_MONITOR_API_TOKEN=|x-ai-monitor-token:|keychain://|hooks\.slack\.com/services|TELEGRAM_BOT_TOKEN|DISCORD_WEBHOOK_URL|PUSHOVER_TOKEN' "${uninstall_path}"; then
    echo "${uninstall_path} contains token, secret, or provider-secret examples" >&2
    exit 1
  fi

  if rg -n '<bundle-id>|<launch-agent-label>' "${uninstall_path}"; then
    echo "${uninstall_path} contains unresolved bundle or LaunchAgent placeholders" >&2
    exit 1
  fi
}

validate_troubleshooting_guide() {
  local troubleshooting_path="$1"
  if ! rg -q "Daemon offline" "${troubleshooting_path}" ||
     ! rg -q "HTTP 401" "${troubleshooting_path}" ||
     ! rg -q "Browser extension does not report tabs" "${troubleshooting_path}" ||
     ! rg -q "IDE tasks do not appear" "${troubleshooting_path}" ||
     ! rg -q "AI Monitor: Send Test Event" "${troubleshooting_path}" ||
     ! rg -q "Open AI Monitor Settings" "${troubleshooting_path}" ||
     ! rg -q "ai-monitor://settings" "${troubleshooting_path}" ||
     ! rg -q "Terminal tasks do not appear" "${troubleshooting_path}" ||
     ! rg -q "Clicking a task does not focus the app" "${troubleshooting_path}" ||
     ! rg -q "Desktop app observer does not show tasks" "${troubleshooting_path}" ||
     ! rg -q "Copy diagnostics" "${troubleshooting_path}"; then
    echo "${troubleshooting_path} is missing daemon, auth, integration, permission, or diagnostics recovery guidance" >&2
    exit 1
  fi

  if rg -n 'AI_MONITOR_API_TOKEN=|x-ai-monitor-token:|keychain://|hooks\.slack\.com/services|TELEGRAM_BOT_TOKEN|DISCORD_WEBHOOK_URL|PUSHOVER_TOKEN' "${troubleshooting_path}"; then
    echo "${troubleshooting_path} contains token, secret, or provider-secret examples" >&2
    exit 1
  fi
}

validate_license_notice_files() {
  local license_path="$1"
  local notices_path="$2"

  if ! rg -q "MIT License" "${license_path}" ||
     ! rg -q "THE SOFTWARE IS PROVIDED" "${license_path}"; then
    echo "${license_path} is missing the bundled MIT license text" >&2
    exit 1
  fi

  if ! rg -q "AI Monitor third-party notices" "${notices_path}" ||
     ! rg -q "Rust crates included in the bundled daemon build" "${notices_path}" ||
     ! rg -q "ai-monitor-daemon 0.1.0: MIT" "${notices_path}" ||
     ! rg -q "rusqlite " "${notices_path}" ||
     ! rg -q "tokio " "${notices_path}" ||
     ! rg -q "ai-monitor-vscode 0.1.1: MIT" "${notices_path}" ||
     ! rg -q "Optional terminal integrations require a user-installed Node.js runtime" "${notices_path}"; then
    echo "${notices_path} is missing bundled dependency or adapter license notices" >&2
    exit 1
  fi

  if rg -q "UNKNOWN" "${notices_path}"; then
    echo "${notices_path} contains unresolved license metadata" >&2
    exit 1
  fi
}

assert_zip_entries_exact() {
  local zip_path="$1"
  local label="$2"
  shift 2

  local actual expected unexpected missing
  actual="$(mktemp "${TMPDIR:-/tmp}/ai-monitor-zip-actual.XXXXXX")"
  expected="$(mktemp "${TMPDIR:-/tmp}/ai-monitor-zip-expected.XXXXXX")"

  zipinfo -1 "${zip_path}" | LC_ALL=C sort > "${actual}"
  printf '%s\n' "$@" | LC_ALL=C sort > "${expected}"

  unexpected="$(comm -13 "${expected}" "${actual}")"
  missing="$(comm -23 "${expected}" "${actual}")"
  rm -f "${actual}" "${expected}"

  if [[ -n "${unexpected}" ]]; then
    echo "${label} zip contains unexpected entries:" >&2
    printf '%s\n' "${unexpected}" >&2
    exit 1
  fi
  if [[ -n "${missing}" ]]; then
    echo "${label} zip is missing entries:" >&2
    printf '%s\n' "${missing}" >&2
    exit 1
  fi
}

assert_zip_png_dimensions() {
  local zip_path="$1"
  local entry_path="$2"
  local expected_width="$3"
  local expected_height="$4"
  local label="$5"

  local tmp_file width height
  tmp_file="$(mktemp "${TMPDIR:-/tmp}/ai-monitor-png.XXXXXX")"
  if ! unzip -p "${zip_path}" "${entry_path}" > "${tmp_file}"; then
    rm -f "${tmp_file}"
    echo "${label} is missing ${entry_path}" >&2
    exit 1
  fi

  width="$(/usr/bin/sips -g pixelWidth "${tmp_file}" 2>/dev/null | awk '/pixelWidth:/ { print $2 }')"
  height="$(/usr/bin/sips -g pixelHeight "${tmp_file}" 2>/dev/null | awk '/pixelHeight:/ { print $2 }')"
  rm -f "${tmp_file}"

  if [[ "${width}" != "${expected_width}" || "${height}" != "${expected_height}" ]]; then
    echo "${label} ${entry_path} must be ${expected_width}x${expected_height}, got ${width:-unknown}x${height:-unknown}" >&2
    exit 1
  fi
}

assert_png_dimensions() {
  local file_path="$1"
  local expected_width="$2"
  local expected_height="$3"
  local label="$4"

  local width height
  width="$(/usr/bin/sips -g pixelWidth "${file_path}" 2>/dev/null | awk '/pixelWidth:/ { print $2 }')"
  height="$(/usr/bin/sips -g pixelHeight "${file_path}" 2>/dev/null | awk '/pixelHeight:/ { print $2 }')"

  if [[ "${width}" != "${expected_width}" || "${height}" != "${expected_height}" ]]; then
    echo "${label} ${file_path} must be ${expected_width}x${expected_height}, got ${width:-unknown}x${height:-unknown}" >&2
    exit 1
  fi
}

validate_web_icon_resources() {
  local app_dir="$1"
  local label="$2"
  local source
  for source in chatgpt-web claude-web gemini-web grok-web perplexity-web github-web; do
    assert_png_dimensions "${app_dir}/Contents/Resources/WebIcons/${source}.png" 32 32 "${label}"
  done
}

validate_app_icon_resources() {
  local app_dir="$1"
  local label="$2"
  local icon_path="${app_dir}/Contents/Resources/AI-Monitor.icns"
  local iconset_dir

  require_path "${icon_path}"
  require_path "${app_dir}/Contents/Resources/AI-Monitor-Logo.png"
  require_path "${app_dir}/Contents/Resources/AI-Monitor-MenuBar-Logo.png"
  iconset_dir="$(mktemp "${TMPDIR:-/tmp}/ai-monitor-iconset.XXXXXX").iconset"
  rm -f "${iconset_dir}"

  if ! /usr/bin/iconutil -c iconset "${icon_path}" -o "${iconset_dir}" >/dev/null 2>&1; then
    rm -rf "${iconset_dir}"
    echo "${label} icon file is not a valid .icns bundle" >&2
    exit 1
  fi

  ICONSET_DIR="${iconset_dir}" LABEL="${label}" node <<'NODE'
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const iconsetDir = process.env.ICONSET_DIR;
const label = process.env.LABEL;
const expected = {
  "icon_16x16.png": [16, 16],
  "icon_16x16@2x.png": [32, 32],
  "icon_32x32.png": [32, 32],
  "icon_32x32@2x.png": [64, 64],
  "icon_128x128.png": [128, 128],
  "icon_128x128@2x.png": [256, 256],
  "icon_256x256.png": [256, 256],
  "icon_256x256@2x.png": [512, 512],
  "icon_512x512.png": [512, 512],
  "icon_512x512@2x.png": [1024, 1024],
};

function pngDimensions(filePath) {
  const output = execFileSync("/usr/bin/sips", ["-g", "pixelWidth", "-g", "pixelHeight", filePath], { encoding: "utf8" });
  const width = Number(output.match(/pixelWidth:\s+([0-9]+)/)?.[1]);
  const height = Number(output.match(/pixelHeight:\s+([0-9]+)/)?.[1]);
  return [width, height];
}

const actual = fs.readdirSync(iconsetDir).filter((file) => file.endsWith(".png")).sort();
const expectedNames = Object.keys(expected).sort();
if (JSON.stringify(actual) !== JSON.stringify(expectedNames)) {
  throw new Error(`${label} iconset entries do not match required macOS icon sizes`);
}
for (const [file, [expectedWidth, expectedHeight]] of Object.entries(expected)) {
  const [width, height] = pngDimensions(path.join(iconsetDir, file));
  if (width !== expectedWidth || height !== expectedHeight) {
    throw new Error(`${label} ${file} must be ${expectedWidth}x${expectedHeight}, got ${width}x${height}`);
  }
}
NODE

  rm -rf "${iconset_dir}"
}

assert_directory_entries_exact() {
  local directory_path="$1"
  local label="$2"
  shift 2

  local actual expected unexpected missing
  actual="$(mktemp "${TMPDIR:-/tmp}/ai-monitor-dir-actual.XXXXXX")"
  expected="$(mktemp "${TMPDIR:-/tmp}/ai-monitor-dir-expected.XXXXXX")"

  (
    cd "${directory_path}"
    find . -mindepth 1 -print | sed 's#^\./##' | LC_ALL=C sort > "${actual}"
  )
  printf '%s\n' "$@" | LC_ALL=C sort > "${expected}"

  unexpected="$(comm -13 "${expected}" "${actual}")"
  missing="$(comm -23 "${expected}" "${actual}")"
  rm -f "${actual}" "${expected}"

  if [[ -n "${unexpected}" ]]; then
    echo "${label} contains unexpected entries:" >&2
    printf '%s\n' "${unexpected}" >&2
    exit 1
  fi
  if [[ -n "${missing}" ]]; then
    echo "${label} is missing entries:" >&2
    printf '%s\n' "${missing}" >&2
    exit 1
  fi
}

assert_directory_top_entries_exact() {
  local directory_path="$1"
  local label="$2"
  shift 2

  local actual expected unexpected missing
  actual="$(mktemp "${TMPDIR:-/tmp}/ai-monitor-dir-top-actual.XXXXXX")"
  expected="$(mktemp "${TMPDIR:-/tmp}/ai-monitor-dir-top-expected.XXXXXX")"

  (
    cd "${directory_path}"
    find . -mindepth 1 -maxdepth 1 -print | sed 's#^\./##' | LC_ALL=C sort > "${actual}"
  )
  printf '%s\n' "$@" | LC_ALL=C sort > "${expected}"

  unexpected="$(comm -13 "${expected}" "${actual}")"
  missing="$(comm -23 "${expected}" "${actual}")"
  rm -f "${actual}" "${expected}"

  if [[ -n "${unexpected}" ]]; then
    echo "${label} contains unexpected entries:" >&2
    printf '%s\n' "${unexpected}" >&2
    exit 1
  fi
  if [[ -n "${missing}" ]]; then
    echo "${label} is missing entries:" >&2
    printf '%s\n' "${missing}" >&2
    exit 1
  fi
}

assert_codesign_runtime() {
  local code_path="$1"
  local label="$2"

  if ! /usr/bin/codesign -dv --verbose=4 "${code_path}" 2>&1 | rg -q 'flags=.*runtime'; then
    echo "${label} is not signed with hardened runtime" >&2
    exit 1
  fi
}

assert_codesign_entitlement_true() {
  local code_path="$1"
  local entitlement_key="$2"
  local label="$3"
  local entitlements_file
  entitlements_file="$(mktemp "${TMPDIR:-/tmp}/ai-monitor-entitlements.XXXXXX")"

  if ! /usr/bin/codesign -d --entitlements :- "${code_path}" > "${entitlements_file}" 2>/dev/null; then
    rm -f "${entitlements_file}"
    echo "Could not read ${label} entitlements" >&2
    exit 1
  fi

  if ! /usr/bin/plutil -convert json -o - "${entitlements_file}" 2>/dev/null | ENTITLEMENT_KEY="${entitlement_key}" node -e '
const fs = require("node:fs");
const key = process.env.ENTITLEMENT_KEY;
const entitlements = JSON.parse(fs.readFileSync(0, "utf8"));
if (entitlements[key] !== true) process.exit(1);
'; then
    rm -f "${entitlements_file}"
    echo "${label} is missing required entitlement: ${entitlement_key}" >&2
    exit 1
  fi

  rm -f "${entitlements_file}"
}

assert_macho_archs_exact() {
  local binary_path="$1"
  local label="$2"
  shift 2

  local actual expected unexpected missing
  actual="$(mktemp "${TMPDIR:-/tmp}/ai-monitor-arch-actual.XXXXXX")"
  expected="$(mktemp "${TMPDIR:-/tmp}/ai-monitor-arch-expected.XXXXXX")"

  /usr/bin/lipo -archs "${binary_path}" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort > "${actual}"
  printf '%s\n' "$@" | LC_ALL=C sort > "${expected}"

  unexpected="$(comm -13 "${expected}" "${actual}")"
  missing="$(comm -23 "${expected}" "${actual}")"
  rm -f "${actual}" "${expected}"

  if [[ -n "${unexpected}" ]]; then
    echo "${label} contains unexpected architectures:" >&2
    printf '%s\n' "${unexpected}" >&2
    exit 1
  fi
  if [[ -n "${missing}" ]]; then
    echo "${label} is missing architectures:" >&2
    printf '%s\n' "${missing}" >&2
    exit 1
  fi
}

assert_macho_min_macos_at_most() {
  local binary_path="$1"
  local max_version="$2"
  local label="$3"

  BINARY_PATH="${binary_path}" \
  MAX_MACOS_VERSION="${max_version}" \
  LABEL="${label}" \
  node <<'NODE'
const { execFileSync } = require("node:child_process");

function parseVersion(version) {
  const parts = version.split(".").map((part) => Number(part));
  while (parts.length < 3) parts.push(0);
  return parts.slice(0, 3);
}

function compareVersions(left, right) {
  const a = parseVersion(left);
  const b = parseVersion(right);
  for (let index = 0; index < 3; index += 1) {
    if (a[index] !== b[index]) return a[index] - b[index];
  }
  return 0;
}

const output = execFileSync("/usr/bin/otool", ["-l", process.env.BINARY_PATH], { encoding: "utf8" });
const versions = Array.from(output.matchAll(/\bminos\s+([0-9]+(?:\.[0-9]+){1,2})/g), (match) => match[1]);
if (versions.length === 0) {
  versions.push(...Array.from(output.matchAll(/\bversion\s+([0-9]+(?:\.[0-9]+){1,2})/g), (match) => match[1]));
}
if (versions.length === 0) {
  throw new Error(`${process.env.LABEL}: could not determine Mach-O minimum macOS version`);
}
for (const version of versions) {
  if (compareVersions(version, process.env.MAX_MACOS_VERSION) > 0) {
    throw new Error(`${process.env.LABEL}: Mach-O minimum macOS ${version} exceeds declared ${process.env.MAX_MACOS_VERSION}`);
  }
}
NODE
}

app_bundle_entries=(
  "Contents"
  "Contents/Info.plist"
  "Contents/MacOS"
  "Contents/MacOS/${APP_NAME}"
  "Contents/Resources"
  "Contents/Resources/AI-Monitor-Logo.png"
  "Contents/Resources/AI-Monitor-MenuBar-Logo.png"
  "Contents/Resources/AI-Monitor.icns"
  "Contents/Resources/WebIcons"
  "Contents/Resources/WebIcons/chatgpt-web.png"
  "Contents/Resources/WebIcons/claude-web.png"
  "Contents/Resources/WebIcons/gemini-web.png"
  "Contents/Resources/WebIcons/grok-web.png"
  "Contents/Resources/WebIcons/perplexity-web.png"
  "Contents/Resources/WebIcons/github-web.png"
  "Contents/Resources/ai-monitor-daemon"
  "Contents/Resources/default.toml"
  "Contents/Resources/LICENSE.txt"
  "Contents/Resources/THIRD-PARTY-NOTICES.txt"
  "Contents/Resources/first-run-guide.txt"
  "Contents/Resources/browser-extension-install-url.txt"
  "Contents/Resources/privacy-notice.txt"
  "Contents/Resources/troubleshooting-guide.txt"
  "Contents/Resources/uninstall-guide.txt"
  "Contents/_CodeSignature"
  "Contents/_CodeSignature/CodeResources"
)

if [[ "${REQUIRE_NOTARIZATION}" == "1" ]]; then
  app_bundle_entries+=("Contents/CodeResources")
fi

require_path "${APP_DIR}"
require_path "${APP_DIR}/Contents/Info.plist"
require_path "${APP_DIR}/Contents/MacOS/${APP_NAME}"
require_path "${APP_DIR}/Contents/Resources/ai-monitor-daemon"
require_path "${APP_DIR}/Contents/Resources/default.toml"
require_path "${APP_DIR}/Contents/Resources/LICENSE.txt"
require_path "${APP_DIR}/Contents/Resources/THIRD-PARTY-NOTICES.txt"
require_path "${APP_DIR}/Contents/Resources/first-run-guide.txt"
require_path "${APP_DIR}/Contents/Resources/browser-extension-install-url.txt"
require_path "${APP_DIR}/Contents/Resources/privacy-notice.txt"
require_path "${APP_DIR}/Contents/Resources/troubleshooting-guide.txt"
require_path "${APP_DIR}/Contents/Resources/uninstall-guide.txt"
require_path "${ZIP_PATH}"
require_path "${DMG_PATH}"
require_path "${BROWSER_EXTENSION_ZIP_PATH}"
require_path "${TERMINAL_INTEGRATIONS_ZIP_PATH}"
require_path "${CHECKSUMS_PATH}"
require_path "${RELEASE_MANIFEST_PATH}"

if [[ -e "${APP_DIR}/Contents/Resources/repo-root.txt" ]]; then
  echo "Bundle contains development-only repo-root.txt" >&2
  exit 1
fi

run_workspace_tests

hygiene_paths=(
  "${ROOT_DIR}/README.md"
  "${ROOT_DIR}/docs"
  "${ROOT_DIR}/config"
  "${ROOT_DIR}/apps"
  "${ROOT_DIR}/core"
  "${ROOT_DIR}/integrations"
  "${ROOT_DIR}/scripts"
)
local_user_path="/Users/${AI_MONITOR_RELEASE_LOCAL_USER:-tracy}"
private_id_prefix="868164"
private_id="${AI_MONITOR_RELEASE_PRIVATE_ID:-${private_id_prefix}4279}"
if rg -n "${local_user_path}|${private_id}" "${hygiene_paths[@]}"; then
  echo "Release hygiene check failed: remove local user paths or private IDs above." >&2
  exit 1
fi

if ! rg -q 'docs/images/floating-monitor.png' "${ROOT_DIR}/README.md" ||
   ! rg -q 'docs/images/notification.png' "${ROOT_DIR}/README.md"; then
  echo "README must show first-time users the floating monitor and notification screenshots." >&2
  exit 1
fi
assert_png_dimensions "${ROOT_DIR}/docs/images/floating-monitor.png" 2400 1520 "README screenshot"
assert_png_dimensions "${ROOT_DIR}/docs/images/notification.png" 2400 1040 "README screenshot"

if rg -n '<key>AI_MONITOR_API_TOKEN</key>|environment\["AI_MONITOR_API_TOKEN"\]\s*=' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift"; then
  echo "macOS app must not write API tokens into LaunchAgent plists or child-process environments; use --api-token-file instead." >&2
  exit 1
fi

if rg -n 'defaults\.set\([^)]*Key\.apiToken' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift"; then
  echo "macOS app must not store API tokens in UserDefaults; write them to the 0600 token file instead." >&2
  exit 1
fi

if ! rg -q 'migrateLegacyAPITokenStorage\(\)' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift"; then
  echo "macOS app must migrate legacy UserDefaults API tokens to the 0600 token file." >&2
  exit 1
fi

if ! rg -q 'secure_token_file_permissions' "${ROOT_DIR}/core/daemon/src/security.rs" ||
   ! rg -q 'existing_token_file_permissions_are_tightened' "${ROOT_DIR}/core/daemon/src/security.rs" ||
   ! rg -q 'tighten existing token-file permissions' "${ROOT_DIR}/docs/release.md"; then
  echo "Daemon must tighten existing API token files to 0600 and keep that behavior covered by tests and release docs." >&2
  exit 1
fi

if ! rg -q 'projectDirectory' "${ROOT_DIR}/integrations/terminal/install-packaged-integrations.js" ||
   ! rg -q 'projectDirectory' "${ROOT_DIR}/integrations/terminal/install-official-hooks.js" ||
   ! rg -q 'existing project directory' "${ROOT_DIR}/scripts/test_official_cli_hooks.sh" ||
   ! rg -q 'reject missing project paths' "${ROOT_DIR}/docs/release.md"; then
  echo "Terminal hook installers must reject missing project directories with a user-facing error and test coverage." >&2
  exit 1
fi

if [[ ! -x "${ROOT_DIR}/scripts/test_browser_detectors.sh" ]] ||
   ! rg -q 'run-detector-fixtures.js' "${ROOT_DIR}/scripts/test_browser_detectors.sh" ||
   ! rg -q 'github-ordinary.html' "${ROOT_DIR}/integrations/browser-extension/chrome/test/run-detector-fixtures.js" ||
   ! rg -q 'perplexity-web' "${ROOT_DIR}/integrations/browser-extension/chrome/test/run-detector-fixtures.js" ||
   ! rg -q 'github-web' "${ROOT_DIR}/integrations/browser-extension/chrome/test/run-detector-fixtures.js"; then
  echo "Browser detector fixtures must cover supported web sources and GitHub negative pages before release." >&2
  exit 1
fi

if [[ ! -x "${ROOT_DIR}/integrations/terminal/install-terminal-integrations.command" ]] ||
   ! rg -q 'command -v node' "${ROOT_DIR}/integrations/terminal/install-terminal-integrations.command" ||
   ! rg -q 'require Node.js' "${ROOT_DIR}/integrations/terminal/install-terminal-integrations.command" ||
   ! rg -q 'Install AI Monitor Terminal Integrations.command' "${ROOT_DIR}/scripts/package_macos_app.sh" ||
   ! rg -q 'Install AI Monitor Terminal Integrations.command' "${ROOT_DIR}/integrations/terminal/README.md" ||
   ! rg -q 'install-terminal-integrations.command' "${ROOT_DIR}/README.md" ||
   ! rg -q 'Install AI Monitor Terminal Integrations.command' "${ROOT_DIR}/docs/macos-dmg-readme.txt"; then
  echo "Terminal integration package must include root and packaged user-facing command wrappers that check for Node.js before running the installer." >&2
  exit 1
fi

if ! rg -q 'openBrowserExtensionInstallLink' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'copyBrowserExtensionInstallLink' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'bundledBrowserExtensionInstallURL' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'NSWorkspace.shared.open\(url\)' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'browser-extension-install-url' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'BROWSER_EXTENSION_INSTALL_URL_RESOURCE_NAME' "${ROOT_DIR}/scripts/build_macos_app.sh" ||
   ! rg -q 'Open browser install link' "${ROOT_DIR}/docs/macos-dmg-readme.txt" ||
   ! rg -q 'Copy browser install link' "${ROOT_DIR}/docs/macos-dmg-readme.txt" ||
   ! rg -q 'Open browser install link' "${ROOT_DIR}/docs/macos-app-setup-guide.txt" ||
   ! rg -q 'Copy browser install link' "${ROOT_DIR}/docs/macos-app-setup-guide.txt" ||
   ! rg -q 'Open browser install link' "${ROOT_DIR}/docs/macos-troubleshooting-guide.txt" ||
   ! rg -q 'Copy browser install link' "${ROOT_DIR}/docs/macos-troubleshooting-guide.txt" ||
   ! rg -q 'Open browser install link' "${ROOT_DIR}/docs/release.md" ||
   ! rg -q 'Copy browser install link' "${ROOT_DIR}/docs/release.md"; then
  echo "macOS Settings must expose direct browser extension install-link open and copy actions backed by the release URL resource." >&2
  exit 1
fi

if ! rg -q 'isSettingsDeepLink' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'showSettings()' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'ai-monitor://settings' "${ROOT_DIR}/integrations/browser-extension/chrome/popup.js" ||
   ! rg -q 'Open AI Monitor Settings' "${ROOT_DIR}/integrations/browser-extension/chrome/popup.html" ||
   ! rg -q 'openAIMonitorSettings' "${ROOT_DIR}/integrations/browser-extension/chrome/popup.js" ||
   ! rg -Fq 'chrome.tabs.create({ url: "ai-monitor://settings", active: true })' "${ROOT_DIR}/integrations/browser-extension/chrome/popup.js" ||
   ! rg -q 'ai-monitor://settings' "${ROOT_DIR}/docs/deeplink-router.md" ||
   ! rg -q 'Open AI Monitor Settings' "${ROOT_DIR}/docs/release.md"; then
  echo "macOS app and browser popup must support ai-monitor://settings recovery from extension token or daemon failures." >&2
  exit 1
fi

if ! rg -q 'aiMonitor.sendTestEvent' "${ROOT_DIR}/integrations/ide/vscode/package.json" ||
   ! rg -q 'aiMonitor.openDesktopSettings' "${ROOT_DIR}/integrations/ide/vscode/package.json" ||
   ! rg -q 'ai-monitor://settings' "${ROOT_DIR}/integrations/ide/vscode/extension.js" ||
   ! rg -q 'VS Code/Cursor extension recovery command' "${ROOT_DIR}/docs/deeplink-router.md" ||
   ! rg -q 'Open AI Monitor Settings' "${ROOT_DIR}/integrations/ide/vscode/extension.js" ||
   ! rg -q 'AI Monitor: Send Test Event' "${ROOT_DIR}/integrations/ide/vscode/README.md"; then
  echo "IDE extension must expose a first-run test event and desktop Settings recovery path." >&2
  exit 1
fi

if ! rg -q 'loadOrCreateAPITokenForSettings' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -Fq 'UUID().uuidString.lowercased' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'Copy API token.*create the token file' "${ROOT_DIR}/docs/release.md"; then
  echo "macOS Copy API token must create the 0600 token file when needed so browser setup does not require starting the daemon first." >&2
  exit 1
fi

if ! rg -q -- '--api-token-file' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift"; then
  echo "macOS app daemon launch command must pass --api-token-file so login daemons do not need token environment variables." >&2
  exit 1
fi

if ! rg -q 'bundle_identifier:' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'minimum_macos_version:' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'operating_system:' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'launch_agent_label:' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
     ! rg -q 'launch_agent_loaded:' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
     ! rg -q 'launch_agent_running:' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
     ! rg -q 'api_token_file_exists:' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
     ! rg -q 'api_token_file_permissions_octal:' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
     ! rg -q 'browser_extension_install_url_configured:' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift"; then
  echo "macOS diagnostics must include bundle, OS, browser install-link configured state, LaunchAgent loaded/running state, and token-file state for installed-user support." >&2
  exit 1
fi

if ! rg -q 'Login daemon is not installed' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'Login daemon loaded and running' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift"; then
  echo "macOS login-daemon status action must show a concise user-facing summary instead of raw launchctl output." >&2
  exit 1
fi

if ! rg -q 'stopLaunchedDaemonProcessForLaunchAgentInstall' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'Manual daemon is still stopping' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'app-started daemon to launchd' "${ROOT_DIR}/docs/macos-app-setup-guide.txt" ||
   ! rg -q 'app-started daemon to launchd' "${ROOT_DIR}/docs/release.md"; then
  echo "macOS login-daemon install must hand off the app-started daemon to launchd to avoid local port conflicts." >&2
  exit 1
fi

if ! rg -q 'applicationWillTerminate' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'stopLaunchedDaemonProcessOnAppQuit' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'Quitting AI Monitor stops only the daemon it started itself' "${ROOT_DIR}/docs/macos-app-setup-guide.txt" ||
   ! rg -q 'app-started daemon stops' "${ROOT_DIR}/docs/release.md"; then
  echo "macOS app must stop its own launched daemon on quit and document when users should install the login daemon." >&2
  exit 1
fi

if ! rg -q 'launchAgentStatus.running' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'Daemon already started by AI Monitor' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'starting a second local daemon' "${ROOT_DIR}/docs/macos-app-setup-guide.txt" ||
   ! rg -q 'starting a second local daemon' "${ROOT_DIR}/docs/release.md"; then
  echo "macOS Start daemon must be idempotent when the app or login daemon has already started the local daemon." >&2
  exit 1
fi

if ! rg -q '/usr/bin/plutil' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -Fq 'temporaryPlistURL' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -Fq 'arguments: ["-lint", temporaryPlistURL.path]' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -Fq 'replaceItemAt(' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -Fq 'withItemAt: temporaryPlistURL' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'moveItem\(at: temporaryPlistURL, to: plistURL\)' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift"; then
  echo "macOS login-daemon install must lint a temporary LaunchAgent plist before replacing the active plist." >&2
  exit 1
fi

if ! rg -q 'Daemon starting automatically' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'starts the local daemon automatically when it is offline' "${ROOT_DIR}/docs/macos-app-setup-guide.txt" ||
   ! rg -q 'manual retry path' "${ROOT_DIR}/README.md"; then
  echo "macOS first-run guidance must match automatic daemon startup and reserve Start daemon as the manual retry path." >&2
  exit 1
fi

if ! rg -q 'requestNotificationAuthorizationIfNeeded' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'notificationAuthorizationRequestInProgress' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'first needs to show a local alert' "${ROOT_DIR}/docs/macos-app-setup-guide.txt" ||
   ! rg -q 'first needs to show a local alert' "${ROOT_DIR}/docs/release.md"; then
  echo "macOS notification permission must be deferred until AI Monitor needs to show a local alert." >&2
  exit 1
fi

if ! rg -q 'providerConfigs.isEmpty' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'No external providers configured' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'No external providers configured' "${ROOT_DIR}/docs/release.md"; then
  echo "macOS Settings must not show a provider-health connection failure on clean installs with no external providers." >&2
  exit 1
fi

if ! rg -q 'presentFirstRunSettingsIfNeeded\(\)' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'AI_Monitor_FirstRunSettingsShown' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'if !appIsRunningFromTransientLocation()' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'transient location must not mark first-run setup as completed' "${ROOT_DIR}/docs/release.md"; then
  echo "macOS app must open Settings on first launch so ordinary users can complete setup." >&2
  exit 1
fi

if ! rg -q 'copyPrivacyNotice' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'bundledPrivacyNoticeText' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'Copy privacy notice' "${ROOT_DIR}/docs/macos-dmg-readme.txt"; then
  echo "macOS Settings must expose the bundled privacy notice." >&2
  exit 1
fi

if ! rg -q 'copyLicenseNotices' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'bundledLicenseNoticesText' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'Copy license notices' "${ROOT_DIR}/docs/macos-dmg-readme.txt"; then
  echo "macOS Settings must expose bundled license and third-party notices." >&2
  exit 1
fi

if ! rg -q 'contentRect: NSRect\(x: 0, y: 0, width: 560, height: 620\)' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'panel\.minSize = NSSize\(width: 520, height: 420\)' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift"; then
  echo "macOS Settings panel must be wide enough for first-run and support controls." >&2
  exit 1
fi

if ! rg -q 'validateDaemonLaunchLocation\(\)' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'before starting the daemon' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'mounted DMG or translocated' "${ROOT_DIR}/docs/macos-app-setup-guide.txt" ||
   ! rg -q 'mounted DMG or translocated' "${ROOT_DIR}/docs/macos-dmg-readme.txt"; then
  echo "macOS app must not start its bundled daemon from a mounted DMG or translocated path." >&2
  exit 1
fi

if rg -n 'Install the browser extension from "AI Monitor Browser Extension\.zip"' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift"; then
  echo "macOS fallback setup guide must not present the browser extension zip as the ordinary-user install path." >&2
  exit 1
fi
if ! rg -q 'Open browser install link, then install the Chrome Web Store or managed browser extension' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift"; then
  echo "macOS fallback setup guide must direct browser users to the Settings browser install-link action." >&2
  exit 1
fi
if ! rg -q 'AI Monitor: Send Test Event' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'AI Monitor: Open Desktop Settings' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'Install AI Monitor Terminal Integrations.command' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift"; then
  echo "macOS fallback setup and troubleshooting guides must cover IDE test/recovery and root terminal installer entry points." >&2
  exit 1
fi
if rg -n 'AI Monitor Browser Extension\.zip|browser extension zip' \
  "${ROOT_DIR}/docs/macos-dmg-readme.txt" \
  "${ROOT_DIR}/docs/macos-app-setup-guide.txt"; then
  echo "ordinary-user macOS guides must not mention the internal browser extension zip artifact." >&2
  exit 1
fi
if ! rg -q 'case "github-web"' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'case "perplexity-web"' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'perplexity-web github-web' "${ROOT_DIR}/scripts/build_macos_app.sh" ||
   ! rg -q 'perplexity-web.png' "${ROOT_DIR}/scripts/check_macos_release_prereqs.sh" ||
   ! rg -q 'github-web.png' "${ROOT_DIR}/scripts/check_macos_release_prereqs.sh"; then
  echo "macOS app must bundle source icons for every ordinary browser source reported by the extension." >&2
  exit 1
fi

if ! rg -q 'CFBundleIdentifier' "${ROOT_DIR}/scripts/uninstall_macos_app.sh" ||
   ! rg -q 'Library/Preferences' "${ROOT_DIR}/scripts/uninstall_macos_app.sh" ||
   ! rg -q -- '--keep-preferences' "${ROOT_DIR}/scripts/uninstall_macos_app.sh" ||
   ! rg -q 'quit_running_app' "${ROOT_DIR}/scripts/uninstall_macos_app.sh" ||
   ! rg -q '/usr/bin/osascript' "${ROOT_DIR}/scripts/uninstall_macos_app.sh" ||
   ! rg -q 'validate_identifier' "${ROOT_DIR}/scripts/uninstall_macos_app.sh" ||
   ! rg -q 'assert_safe_remove_path' "${ROOT_DIR}/scripts/uninstall_macos_app.sh"; then
  echo "Uninstall script must infer the bundle id, quit a running app, validate identifiers/paths, and remove app preferences unless --keep-preferences is set." >&2
  exit 1
fi

unsafe_uninstall_output="$(mktemp "${TMPDIR:-/tmp}/ai-monitor-unsafe-uninstall.XXXXXX")"
if AI_MONITOR_APP_PATH="/" \
   AI_MONITOR_BUNDLE_ID="com.example.ai-monitor" \
   AI_MONITOR_LAUNCH_AGENT_LABEL="com.example.ai-monitor.daemon" \
   "${ROOT_DIR}/scripts/uninstall_macos_app.sh" --dry-run >"${unsafe_uninstall_output}" 2>&1; then
  echo "Uninstall script accepted an unsafe app path" >&2
  cat "${unsafe_uninstall_output}" >&2
  rm -f "${unsafe_uninstall_output}"
  exit 1
fi
if ! rg -q "Unsafe app path|Refusing to remove" "${unsafe_uninstall_output}"; then
  echo "Uninstall script did not explain unsafe app path rejection" >&2
  cat "${unsafe_uninstall_output}" >&2
  rm -f "${unsafe_uninstall_output}"
  exit 1
fi
rm -f "${unsafe_uninstall_output}"

unsafe_uninstall_output="$(mktemp "${TMPDIR:-/tmp}/ai-monitor-unsafe-uninstall.XXXXXX")"
if AI_MONITOR_APP_PATH="/Applications/AI Monitor.app" \
   AI_MONITOR_BUNDLE_ID="com.example.ai-monitor" \
   AI_MONITOR_LAUNCH_AGENT_LABEL="../bad" \
   "${ROOT_DIR}/scripts/uninstall_macos_app.sh" --dry-run >"${unsafe_uninstall_output}" 2>&1; then
  echo "Uninstall script accepted an unsafe LaunchAgent label" >&2
  cat "${unsafe_uninstall_output}" >&2
  rm -f "${unsafe_uninstall_output}"
  exit 1
fi
if ! rg -q "Unsafe LaunchAgent label" "${unsafe_uninstall_output}"; then
  echo "Uninstall script did not explain unsafe LaunchAgent label rejection" >&2
  cat "${unsafe_uninstall_output}" >&2
  rm -f "${unsafe_uninstall_output}"
  exit 1
fi
rm -f "${unsafe_uninstall_output}"

if ! rg -q 'Copy uninstall guide' "${ROOT_DIR}/docs/uninstall.md" ||
   ! rg -q 'UNINSTALL.command' "${ROOT_DIR}/docs/uninstall.md" ||
   ! rg -q 'ask a running AI Monitor app to quit' "${ROOT_DIR}/docs/uninstall.md" ||
   ! rg -q 'DELETE' "${ROOT_DIR}/docs/uninstall.md" ||
   ! rg -q 'Library/Preferences/<bundle-id>.plist' "${ROOT_DIR}/docs/uninstall.md" ||
   ! rg -q -- '--keep-preferences' "${ROOT_DIR}/docs/uninstall.md"; then
  echo "Uninstall docs must mention the bundled uninstall guide, safe DMG uninstall command, preferences cleanup, and --keep-preferences." >&2
  exit 1
fi

if [[ ! -x "${ROOT_DIR}/scripts/release_macos_app.sh" ]] ||
   ! rg -q 'AI_MONITOR_REQUIRE_NOTARIZATION=1' "${ROOT_DIR}/scripts/release_macos_app.sh" ||
   ! rg -q 'AI_MONITOR_CHECK_NOTARY_ONLINE.*:-1' "${ROOT_DIR}/scripts/release_macos_app.sh" ||
   ! rg -q 'check_macos_release_prereqs.sh' "${ROOT_DIR}/scripts/release_macos_app.sh" ||
   ! rg -q 'package_macos_app.sh' "${ROOT_DIR}/scripts/release_macos_app.sh" ||
   ! rg -q 'verify_macos_release.sh' "${ROOT_DIR}/scripts/release_macos_app.sh" ||
   ! rg -q 'stage_public_release.sh' "${ROOT_DIR}/scripts/release_macos_app.sh" ||
   ! rg -q 'init_macos_release_env.sh' "${ROOT_DIR}/scripts/release_macos_app.sh"; then
  echo "Public release script must force notarized release mode, validate notary profile online, point to release env initialization, run prerequisites, package, verify, and stage the public upload set." >&2
  exit 1
fi

if [[ ! -x "${ROOT_DIR}/scripts/init_macos_release_env.sh" ]] ||
   ! rg -q 'security find-identity -v -p codesigning' "${ROOT_DIR}/scripts/init_macos_release_env.sh" ||
   ! rg -q 'AI_MONITOR_CODESIGN_IDENTITY' "${ROOT_DIR}/scripts/init_macos_release_env.sh" ||
   ! rg -q 'AI_MONITOR_BROWSER_EXTENSION_INSTALL_URL' "${ROOT_DIR}/scripts/init_macos_release_env.sh" ||
   ! rg -q 'AI_MONITOR_BROWSER_EXTENSION_PRIVACY_POLICY_URL' "${ROOT_DIR}/scripts/init_macos_release_env.sh" ||
   ! rg -q 'AI_MONITOR_NOTARY_PROFILE' "${ROOT_DIR}/scripts/init_macos_release_env.sh" ||
   ! rg -q 'chmod 600' "${ROOT_DIR}/scripts/init_macos_release_env.sh" ||
   ! rg -q 'init_macos_release_env.sh' "${ROOT_DIR}/README.md" ||
   ! rg -q 'init_macos_release_env.sh' "${ROOT_DIR}/docs/release.md" ||
   ! rg -q 'init_macos_release_env.sh' "${ROOT_DIR}/docs/macos-release-env.example"; then
  echo "Release env initializer must generate a private env file, detect Developer ID identities, and be documented." >&2
  exit 1
fi

if [[ ! -x "${ROOT_DIR}/scripts/stage_private_test_release.sh" ]] ||
   ! rg -q 'package_macos_app.sh' "${ROOT_DIR}/scripts/stage_private_test_release.sh" ||
   ! rg -q 'verify_macos_release.sh' "${ROOT_DIR}/scripts/stage_private_test_release.sh" ||
   ! rg -q 'AI_MONITOR_MACOS_ARCHS.*arm64 x86_64' "${ROOT_DIR}/scripts/stage_private_test_release.sh" ||
   ! rg -q 'AI_MONITOR_ALLOW_DEV_PUBLIC_STAGE=1' "${ROOT_DIR}/scripts/stage_private_test_release.sh" ||
   ! rg -q 'not require.*Developer ID signing or Apple notarization' "${ROOT_DIR}/scripts/stage_private_test_release.sh" ||
   ! rg -q 'stage_private_test_release.sh' "${ROOT_DIR}/README.md" ||
   ! rg -q 'stage_private_test_release.sh' "${ROOT_DIR}/docs/release.md"; then
  echo "Private test release script and docs must provide a one-command staging path without presenting it as the public release path." >&2
  exit 1
fi

if [[ ! -x "${ROOT_DIR}/scripts/stage_public_release.sh" ]] ||
   ! rg -q 'publish_with_release' "${ROOT_DIR}/scripts/stage_public_release.sh" ||
   ! rg -q 'publish !== true' "${ROOT_DIR}/scripts/stage_public_release.sh" ||
   ! rg -q 'AI_MONITOR_ALLOW_DEV_PUBLIC_STAGE' "${ROOT_DIR}/scripts/stage_public_release.sh" ||
   ! rg -q 'manifest.release_mode !== true' "${ROOT_DIR}/scripts/stage_public_release.sh" ||
   ! rg -q 'refusing to stage public release files' "${ROOT_DIR}/scripts/stage_public_release.sh" ||
   ! rg -q 'canonical_child_path' "${ROOT_DIR}/scripts/stage_public_release.sh" ||
   ! rg -q 'artifact.version' "${ROOT_DIR}/scripts/stage_public_release.sh" ||
   ! rg -q 'Public release directory must be under' "${ROOT_DIR}/scripts/stage_public_release.sh" ||
   ! rg -q 'must not be the distribution directory' "${ROOT_DIR}/scripts/stage_public_release.sh" ||
   ! rg -q 'Primary ordinary-user download' "${ROOT_DIR}/scripts/stage_public_release.sh" ||
   ! rg -q 'Browser extension install URL' "${ROOT_DIR}/scripts/stage_public_release.sh" ||
   ! rg -q 'Browser extension privacy policy URL' "${ROOT_DIR}/scripts/stage_public_release.sh" ||
   ! rg -q 'Do not add omitted artifacts to the public upload set' "${ROOT_DIR}/scripts/stage_public_release.sh" ||
   ! rg -q 'PUBLIC_RELEASE_README.txt' "${ROOT_DIR}/scripts/stage_public_release.sh"; then
  echo "Public release staging script must require release-mode manifests, copy only manifest-approved publish=true artifacts, guard destructive staging paths, and write a public release README with the primary installer and omitted-artifact guidance." >&2
  exit 1
fi

if ! rg -q 'AI_MONITOR_BROWSER_EXTENSION_INSTALL_URL' "${ROOT_DIR}/scripts/check_macos_release_prereqs.sh" ||
   ! rg -q '<browser-extension-install-url>' "${ROOT_DIR}/docs/macos-dmg-readme.txt" ||
   ! rg -q '<browser-extension-install-url>' "${ROOT_DIR}/docs/macos-app-setup-guide.txt" ||
   ! rg -q 'AI_MONITOR_BROWSER_EXTENSION_INSTALL_URL' "${ROOT_DIR}/docs/release.md" ||
   ! rg -q 'AI_MONITOR_BROWSER_EXTENSION_PRIVACY_POLICY_URL' "${ROOT_DIR}/docs/release.md" ||
   ! rg -q 'AI_MONITOR_BROWSER_EXTENSION_INSTALL_URL' "${ROOT_DIR}/README.md" ||
   ! rg -q 'AI_MONITOR_BROWSER_EXTENSION_PRIVACY_POLICY_URL' "${ROOT_DIR}/README.md" ||
   ! rg -q 'Public browser users install the Chrome Web Store or managed extension' "${ROOT_DIR}/README.md" ||
   ! rg -q "Public users should install AI Monitor's Chrome Web Store or managed extension" "${ROOT_DIR}/integrations/browser-extension/chrome/README.md" ||
   ! rg -q 'Developer Mode is for source checkouts and internal testing only' "${ROOT_DIR}/integrations/browser-extension/chrome/README.md" ||
   ! rg -q 'AI_MONITOR_BROWSER_EXTENSION_INSTALL_URL' "${ROOT_DIR}/scripts/build_macos_app.sh" ||
   ! rg -q 'render_setup_guide' "${ROOT_DIR}/scripts/build_macos_app.sh" ||
   ! rg -q 'browser_extension_install_url' "${ROOT_DIR}/scripts/package_macos_app.sh" ||
   ! rg -q 'browser_extension_privacy_policy_url' "${ROOT_DIR}/scripts/package_macos_app.sh" ||
   ! rg -q 'Release packaging requires AI_MONITOR_BROWSER_EXTENSION_INSTALL_URL' "${ROOT_DIR}/scripts/package_macos_app.sh" ||
   ! rg -q 'Release packaging requires AI_MONITOR_BROWSER_EXTENSION_PRIVACY_POLICY_URL' "${ROOT_DIR}/scripts/package_macos_app.sh"; then
  echo "Release pipeline must require and publish the browser extension install and privacy policy URLs for ordinary browser users." >&2
  exit 1
fi

if [[ ! -f "${ROOT_DIR}/docs/browser-extension-store-listing.md" ||
      ! -f "${ROOT_DIR}/docs/browser-extension-privacy-policy.md" ]] ||
   ! rg -q 'Single Purpose' "${ROOT_DIR}/docs/browser-extension-store-listing.md" ||
   ! rg -q 'Permission Justifications' "${ROOT_DIR}/docs/browser-extension-store-listing.md" ||
   ! rg -q 'Data Disclosure Notes' "${ROOT_DIR}/docs/browser-extension-store-listing.md" ||
   ! rg -q 'https://developer.chrome.com/docs/webstore/cws-dashboard-privacy' "${ROOT_DIR}/docs/browser-extension-store-listing.md" ||
   ! rg -q 'AI_MONITOR_BROWSER_EXTENSION_PRIVACY_POLICY_URL' "${ROOT_DIR}/docs/browser-extension-store-listing.md" ||
   ! rg -q 'website content from supported AI pages' "${ROOT_DIR}/docs/browser-extension-store-listing.md" ||
   ! rg -q 'authentication information' "${ROOT_DIR}/docs/browser-extension-store-listing.md" ||
   ! rg -q 'AI Monitor Browser Adapter Privacy Policy' "${ROOT_DIR}/docs/browser-extension-privacy-policy.md" ||
   ! rg -q 'does not send data to an AI Monitor cloud service' "${ROOT_DIR}/docs/browser-extension-privacy-policy.md" ||
   ! rg -q 'Chrome Web Store Limited Use' "${ROOT_DIR}/docs/browser-extension-privacy-policy.md" ||
   ! rg -q 'browser-extension-store-listing.md' "${ROOT_DIR}/docs/release.md" ||
   ! rg -q 'browser-extension-privacy-policy.md' "${ROOT_DIR}/docs/release.md" ||
   ! rg -q 'browser-extension-store-listing.md' "${ROOT_DIR}/integrations/browser-extension/chrome/README.md"; then
  echo "Browser extension public release must include Chrome Web Store listing and privacy-policy materials." >&2
  exit 1
fi

release_env_template="${ROOT_DIR}/docs/macos-release-env.example"
if [[ ! -f "${release_env_template}" ]] ||
   ! rg -q 'cp docs/macos-release-env.example .env.release.local' "${release_env_template}" ||
   ! rg -q 'AI_MONITOR_BUNDLE_ID' "${release_env_template}" ||
   ! rg -q 'AI_MONITOR_COPYRIGHT' "${release_env_template}" ||
   ! rg -q 'AI_MONITOR_BROWSER_EXTENSION_INSTALL_URL' "${release_env_template}" ||
   ! rg -q 'AI_MONITOR_BROWSER_EXTENSION_PRIVACY_POLICY_URL' "${release_env_template}" ||
   ! rg -q 'AI_MONITOR_CODESIGN_IDENTITY' "${release_env_template}" ||
   ! rg -q 'AI_MONITOR_NOTARY_PROFILE' "${release_env_template}" ||
   ! rg -q 'AI_MONITOR_NOTARY_APPLE_ID' "${release_env_template}" ||
   ! rg -q 'AI_MONITOR_NOTARY_PASSWORD' "${release_env_template}" ||
   ! rg -q 'AI_MONITOR_NOTARY_TEAM_ID' "${release_env_template}" ||
   ! rg -q 'AI_MONITOR_APP_VERSION' "${release_env_template}" ||
   ! rg -q 'AI_MONITOR_APP_BUILD' "${release_env_template}" ||
   ! rg -q 'AI_MONITOR_MACOS_MIN_VERSION' "${release_env_template}" ||
   ! rg -q 'AI_MONITOR_MACOS_ARCHS="arm64 x86_64"' "${release_env_template}" ||
   ! rg -q 'AI_MONITOR_RELEASE=1' "${release_env_template}" ||
   ! rg -q 'AI_MONITOR_CHECK_NOTARY_ONLINE=1' "${release_env_template}" ||
   ! rg -q 'init_macos_release_env.sh' "${ROOT_DIR}/README.md" ||
   ! rg -q 'init_macos_release_env.sh' "${ROOT_DIR}/docs/release.md" ||
   ! rg -q 'init_macos_release_env.sh' "${ROOT_DIR}/scripts/release_macos_app.sh" ||
   ! rg -q 'init_macos_release_env.sh' "${ROOT_DIR}/scripts/check_macos_release_prereqs.sh" ||
   ! rg -q '^\.env\.\*$' "${ROOT_DIR}/.gitignore"; then
  echo "Release docs must include a complete ignored environment template for publisher, signing, notary, browser-extension, version, and release-mode variables." >&2
  exit 1
fi
if rg -q '^export AI_MONITOR_NOTARY_PASSWORD=' "${release_env_template}"; then
  echo "Release environment template must not enable an Apple ID notary password by default." >&2
  exit 1
fi

unsafe_stage_output="$(mktemp)"
if AI_MONITOR_PUBLIC_RELEASE_DIR="/" "${ROOT_DIR}/scripts/stage_public_release.sh" >"${unsafe_stage_output}" 2>&1; then
  echo "Public release staging script must reject unsafe staging directories before removing anything." >&2
  rm -f "${unsafe_stage_output}"
  exit 1
fi
if ! rg -q 'Public release directory is unsafe|Public release directory must be under' "${unsafe_stage_output}"; then
  echo "Unsafe public release staging rejection should explain the unsafe directory." >&2
  cat "${unsafe_stage_output}" >&2
  rm -f "${unsafe_stage_output}"
  exit 1
fi
rm -f "${unsafe_stage_output}"

if [[ "${REQUIRE_NOTARIZATION}" != "1" ]]; then
  non_release_stage_output="$(mktemp)"
  if AI_MONITOR_PUBLIC_RELEASE_DIR="${ROOT_DIR}/target/macos-public-release-verifier" \
     "${ROOT_DIR}/scripts/stage_public_release.sh" >"${non_release_stage_output}" 2>&1; then
    echo "Public release staging script must reject non-release manifests unless explicitly allowed for local previews." >&2
    rm -f "${non_release_stage_output}"
    exit 1
  fi
  if ! rg -q 'not from AI_MONITOR_RELEASE=1; refusing to stage public release files' "${non_release_stage_output}"; then
    echo "Non-release public staging rejection should explain that release_mode is required." >&2
    cat "${non_release_stage_output}" >&2
    rm -f "${non_release_stage_output}"
    exit 1
  fi
  rm -f "${non_release_stage_output}"

  preview_stage_dir="${ROOT_DIR}/target/macos-public-release-verifier-preview"
  rm -rf "${preview_stage_dir}"
  AI_MONITOR_ALLOW_DEV_PUBLIC_STAGE=1 \
  AI_MONITOR_PUBLIC_RELEASE_DIR="${preview_stage_dir}" \
    "${ROOT_DIR}/scripts/stage_public_release.sh" >/dev/null
  if ! rg -q 'development staging preview - not for public upload' "${preview_stage_dir}/PUBLIC_RELEASE_README.txt" ||
     ! rg -q 'Primary ordinary-user download: AI Monitor.dmg' "${preview_stage_dir}/PUBLIC_RELEASE_README.txt" ||
     ! rg -q 'private testers who expect a development build' "${preview_stage_dir}/PUBLIC_RELEASE_README.txt" ||
     ! rg -q 'not Developer ID signed and notarized' "${preview_stage_dir}/PUBLIC_RELEASE_README.txt" ||
     ! rg -q 'Browser extension install URL: (not configured in this preview|https://)' "${preview_stage_dir}/PUBLIC_RELEASE_README.txt" ||
     ! rg -q 'Browser extension privacy policy URL: (not configured in this preview|https://)' "${preview_stage_dir}/PUBLIC_RELEASE_README.txt" ||
     ! rg -q 'Do not add omitted artifacts to the public upload set' "${preview_stage_dir}/PUBLIC_RELEASE_README.txt" ||
     ! rg -q 'AI Monitor.zip: app_archive v' "${preview_stage_dir}/PUBLIC_RELEASE_README.txt" ||
     ! rg -q 'AI Monitor Browser Extension.zip: browser_extension_package v' "${preview_stage_dir}/PUBLIC_RELEASE_README.txt" ||
     ! rg -q 'AI Monitor IDE Extension.vsix: ide_extension_vsix v' "${preview_stage_dir}/PUBLIC_RELEASE_README.txt" ||
     ! rg -q 'PUBLIC_RELEASE_README.txt: upload guidance' "${preview_stage_dir}/PUBLIC_RELEASE_README.txt"; then
    echo "Development public staging preview README must identify the primary DMG, omitted internal artifacts, and its own upload guidance file." >&2
    rm -rf "${preview_stage_dir}"
    exit 1
  fi
  (
    cd "${preview_stage_dir}"
    /usr/bin/shasum -a 256 -c SHA256SUMS.txt >/dev/null
  )
  rm -rf "${preview_stage_dir}"
fi

if ! rg -q 'Release packaging cannot skip codesigning' "${ROOT_DIR}/scripts/package_macos_app.sh" ||
   ! rg -q 'AI_MONITOR_SKIP_CODESIGN must not be 1' "${ROOT_DIR}/scripts/check_macos_release_prereqs.sh" ||
   ! rg -q 'AI_MONITOR_SKIP_CODESIGN=1' "${ROOT_DIR}/docs/release.md"; then
  echo "Release path must reject AI_MONITOR_SKIP_CODESIGN=1 in package, prereq, and docs." >&2
  exit 1
fi

if ! rg -q 'stapler validate' "${ROOT_DIR}/scripts/package_macos_app.sh" ||
   ! rg -q 'stapler validate' "${ROOT_DIR}/scripts/verify_macos_release.sh" ||
   ! rg -q -- '--type execute' "${ROOT_DIR}/scripts/verify_macos_release.sh" ||
   ! rg -q 'spctl --type execute' "${ROOT_DIR}/docs/release.md"; then
  echo "Release path must validate stapled DMG tickets and Gatekeeper-assess the mounted app bundle." >&2
  exit 1
fi

if ! rg -Fq 'xcrun stapler staple "${APP_DIR}"' "${ROOT_DIR}/scripts/package_macos_app.sh" ||
   ! rg -Fq 'xcrun stapler validate "${APP_DIR}"' "${ROOT_DIR}/scripts/package_macos_app.sh" ||
   ! rg -Fq 'xcrun stapler validate "${MOUNT_DIR}/${APP_NAME}.app"' "${ROOT_DIR}/scripts/verify_macos_release.sh"; then
  echo "Release path must notarize, staple, and validate the app bundle before and inside the DMG." >&2
  exit 1
fi

if ! rg -q 'Apple ID notary credentials accepted by notarytool' "${ROOT_DIR}/scripts/check_macos_release_prereqs.sh" ||
   ! rg -q 'Apple ID notary credential environment variables are verified with Apple' "${ROOT_DIR}/docs/release.md"; then
  echo "Release prereq and docs must online-validate Apple ID notary credentials, not only keychain profiles." >&2
  exit 1
fi

if ! rg -q 'macos-privacy-notice.txt' "${ROOT_DIR}/scripts/build_macos_app.sh" ||
   ! rg -q 'macos-uninstall-guide.txt' "${ROOT_DIR}/scripts/build_macos_app.sh" ||
   ! rg -q 'macos-troubleshooting-guide.txt' "${ROOT_DIR}/scripts/build_macos_app.sh" ||
   ! rg -q 'generate_third_party_notices.sh' "${ROOT_DIR}/scripts/build_macos_app.sh" ||
   ! rg -q 'render_uninstall_guide' "${ROOT_DIR}/scripts/build_macos_app.sh" ||
   ! rg -q 'render_dmg_text_template' "${ROOT_DIR}/scripts/package_macos_app.sh" ||
   ! rg -q 'write_dmg_uninstall_command' "${ROOT_DIR}/scripts/package_macos_app.sh" ||
   ! rg -q 'LICENSE.txt' "${ROOT_DIR}/scripts/package_macos_app.sh" ||
   ! rg -q 'THIRD-PARTY-NOTICES.txt' "${ROOT_DIR}/scripts/package_macos_app.sh" ||
   ! rg -q 'PRIVACY.txt' "${ROOT_DIR}/scripts/package_macos_app.sh" ||
   ! rg -q 'UNINSTALL.txt' "${ROOT_DIR}/scripts/package_macos_app.sh" ||
   ! rg -q 'TROUBLESHOOTING.txt' "${ROOT_DIR}/scripts/package_macos_app.sh" ||
   ! rg -q 'UNINSTALL.command' "${ROOT_DIR}/scripts/package_macos_app.sh" ||
   ! rg -q 'LICENSE.txt' "${ROOT_DIR}/docs/macos-dmg-readme.txt" ||
   ! rg -q 'THIRD-PARTY-NOTICES.txt' "${ROOT_DIR}/docs/macos-dmg-readme.txt" ||
   ! rg -q 'PRIVACY.txt' "${ROOT_DIR}/docs/macos-dmg-readme.txt" ||
   ! rg -q 'UNINSTALL.txt' "${ROOT_DIR}/docs/macos-dmg-readme.txt" ||
   ! rg -q 'TROUBLESHOOTING.txt' "${ROOT_DIR}/docs/macos-dmg-readme.txt" ||
   ! rg -q 'UNINSTALL.command' "${ROOT_DIR}/docs/macos-dmg-readme.txt"; then
  echo "macOS package must include and mention license, third-party notices, privacy, troubleshooting, and uninstall guidance for ordinary users." >&2
  exit 1
fi

if ! rg -q 'Copy troubleshooting guide' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'Copy troubleshooting guide' "${ROOT_DIR}/docs/macos-dmg-readme.txt" ||
   ! rg -q 'Copy troubleshooting guide' "${ROOT_DIR}/docs/release.md" ||
   ! rg -q 'Copy license notices' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'Copy license notices' "${ROOT_DIR}/docs/macos-dmg-readme.txt" ||
   ! rg -q 'Copy license notices' "${ROOT_DIR}/docs/release.md" ||
   ! rg -q 'Copy uninstall guide' "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" ||
   ! rg -q 'Copy uninstall guide' "${ROOT_DIR}/docs/macos-dmg-readme.txt" ||
   ! rg -q 'Copy uninstall guide' "${ROOT_DIR}/docs/release.md"; then
  echo "macOS Settings, DMG README, and release docs must expose bundled troubleshooting, license, and uninstall guides." >&2
  exit 1
fi

if ! rg -q 'release_macos_app.sh' "${ROOT_DIR}/docs/release.md" ||
   ! rg -q 'release_macos_app.sh' "${ROOT_DIR}/README.md" ||
   ! rg -q 'stage_private_test_release.sh' "${ROOT_DIR}/docs/release.md" ||
   ! rg -q 'stage_private_test_release.sh' "${ROOT_DIR}/README.md"; then
  echo "Release docs must use scripts/release_macos_app.sh as the public release entrypoint." >&2
  exit 1
fi

if ! rg -q 'target/macos-public-release/AI Monitor.dmg' "${ROOT_DIR}/README.md" ||
   ! rg -q 'target/macos-public-release/AI Monitor.dmg' "${ROOT_DIR}/docs/release.md" ||
   ! rg -q 'artifact versions' "${ROOT_DIR}/docs/release.md" ||
   ! rg -q 'not raw files from `target/macos-dist`' "${ROOT_DIR}/README.md" ||
   rg -q '^Distribute `target/macos-dist/AI Monitor.dmg`' "${ROOT_DIR}/README.md"; then
  echo "Release docs must direct public uploads to target/macos-public-release, not raw target/macos-dist artifacts." >&2
  exit 1
fi

if rg -n 'first Rust skeleton|environment-variable based local config|secure storage before public release|Desktop clients should replace this with secure storage' \
    "${ROOT_DIR}/docs/privacy.md" \
    "${ROOT_DIR}/docs/security.md" \
    "${ROOT_DIR}/README.md"; then
  echo "Privacy and security docs must describe the shipped token-file and Keychain storage path, not stale pre-release secret-storage guidance." >&2
  exit 1
fi

if ! rg -q 'redact_sensitive_error_message' "${ROOT_DIR}/core/notification-engine/src/lib.rs" ||
   ! rg -q 'redact_urls' "${ROOT_DIR}/core/notification-engine/src/lib.rs" ||
   ! rg -q 'redacts_urls_from_provider_error_messages' "${ROOT_DIR}/core/notification-engine/src/lib.rs" ||
   ! rg -q 'redacts_webhook_urls_without_removing_status_context' "${ROOT_DIR}/core/notification-engine/src/lib.rs" ||
   ! rg -q 'redact_sensitive_error_message\(error.to_string\(\)\)' "${ROOT_DIR}/core/daemon/src/main.rs" ||
   ! rg -q 'Provider delivery failure messages redact URLs' "${ROOT_DIR}/docs/security.md"; then
  echo "Provider delivery failures must redact URL-bearing secrets before persistence and document that behavior." >&2
  exit 1
fi

if [[ ! -x "${APP_DIR}/Contents/Resources/ai-monitor-daemon" ]]; then
  echo "Bundled daemon is not executable" >&2
  exit 1
fi

manifest_browser_extension_install_url="$(
  RELEASE_MANIFEST_PATH="${RELEASE_MANIFEST_PATH}" node <<'NODE'
const fs = require("node:fs");
const manifest = JSON.parse(fs.readFileSync(process.env.RELEASE_MANIFEST_PATH, "utf8"));
const value = manifest.distribution?.browser_extension_install_url
  || manifest.browser_extension_install_url
  || "";
if (value) process.stdout.write(value);
NODE
)"

validate_default_config "${APP_DIR}/Contents/Resources/default.toml"
validate_license_notice_files "${APP_DIR}/Contents/Resources/LICENSE.txt" "${APP_DIR}/Contents/Resources/THIRD-PARTY-NOTICES.txt"
validate_first_run_guide "${APP_DIR}/Contents/Resources/first-run-guide.txt" "${manifest_browser_extension_install_url}"
validate_browser_extension_install_url_resource "${APP_DIR}/Contents/Resources/browser-extension-install-url.txt" "${manifest_browser_extension_install_url}"
validate_privacy_notice "${APP_DIR}/Contents/Resources/privacy-notice.txt"
validate_troubleshooting_guide "${APP_DIR}/Contents/Resources/troubleshooting-guide.txt"
validate_uninstall_guide "${APP_DIR}/Contents/Resources/uninstall-guide.txt"
assert_macho_archs_exact "${APP_DIR}/Contents/MacOS/${APP_NAME}" "app executable" "${EXPECTED_MACOS_ARCHS[@]}"
assert_macho_archs_exact "${APP_DIR}/Contents/Resources/ai-monitor-daemon" "bundled daemon" "${EXPECTED_MACOS_ARCHS[@]}"
assert_macho_min_macos_at_most "${APP_DIR}/Contents/MacOS/${APP_NAME}" "${MIN_MACOS_VERSION}" "app executable"
assert_macho_min_macos_at_most "${APP_DIR}/Contents/Resources/ai-monitor-daemon" "${MIN_MACOS_VERSION}" "bundled daemon"

required_checksum_entries=(
  "${APP_NAME}.dmg"
  "${APP_NAME}.zip"
  "${APP_NAME} Browser Extension.zip"
  "${APP_NAME} IDE Extension.zip"
  "${APP_NAME} IDE Extension.vsix"
  "${APP_NAME} Terminal Integrations.zip"
  "$(basename "${RELEASE_MANIFEST_PATH}")"
)
for entry in "${required_checksum_entries[@]}"; do
  if ! cut -c 67- "${CHECKSUMS_PATH}" | rg -Fxq "${entry}"; then
    echo "SHA256SUMS.txt is missing ${entry}" >&2
    exit 1
  fi
done
(
  cd "${DIST_DIR}"
  /usr/bin/shasum -a 256 -c "$(basename "${CHECKSUMS_PATH}")" >/dev/null
)

DIST_DIR="${DIST_DIR}" \
CHECKSUMS_PATH="${CHECKSUMS_PATH}" \
RELEASE_MANIFEST_PATH="${RELEASE_MANIFEST_PATH}" \
APP_INFO_PLIST="${APP_DIR}/Contents/Info.plist" \
APP_NAME="${APP_NAME}" \
MIN_MACOS_VERSION="${MIN_MACOS_VERSION}" \
EXPECTED_MACOS_ARCHS="${MACOS_ARCHS_RAW}" \
BROWSER_EXTENSION_ZIP_PATH="${BROWSER_EXTENSION_ZIP_PATH}" \
REQUIRE_NOTARIZATION="${REQUIRE_NOTARIZATION}" \
node <<'NODE'
const fs = require("node:fs");
const { execFileSync } = require("node:child_process");
const path = require("node:path");

function plistValue(key) {
  return execFileSync("/usr/bin/plutil", [
    "-extract",
    key,
    "raw",
    "-o",
    "-",
    process.env.APP_INFO_PLIST,
  ], { encoding: "utf8" }).trim();
}

function launchAgentLabel(bundleIdentifier) {
  return bundleIdentifier.startsWith("local.")
    ? "local.ai-monitor.daemon"
    : `${bundleIdentifier}.daemon`;
}

function sortedWords(value) {
  return String(value || "")
    .trim()
    .split(/\s+/)
    .filter(Boolean)
    .sort();
}

function assertStringArrayEqual(actual, expected, label) {
  if (!Array.isArray(actual)) {
    throw new Error(`${label} must be an array`);
  }
  const actualSorted = [...actual].sort();
  if (JSON.stringify(actualSorted) !== JSON.stringify(expected)) {
    throw new Error(`${label} ${JSON.stringify(actualSorted)} does not match expected ${JSON.stringify(expected)}`);
  }
}

const distDir = process.env.DIST_DIR;
const manifest = JSON.parse(fs.readFileSync(process.env.RELEASE_MANIFEST_PATH, "utf8"));
if (manifest.schema_version !== 1) throw new Error("release manifest schema_version must be 1");
if (manifest.app_name !== process.env.APP_NAME) {
  throw new Error("release manifest app_name does not match verifier app name");
}
if (plistValue("CFBundleDisplayName") !== process.env.APP_NAME ||
    plistValue("CFBundleName") !== process.env.APP_NAME ||
    plistValue("CFBundleExecutable") !== process.env.APP_NAME) {
  throw new Error("Info.plist app display name, bundle name, and executable must match the packaged app name");
}
if (plistValue("CFBundleIconFile") !== "AI-Monitor") {
  throw new Error("Info.plist CFBundleIconFile must point at the bundled AI-Monitor.icns");
}
if (plistValue("CFBundlePackageType") !== "APPL") {
  throw new Error("Info.plist CFBundlePackageType must be APPL");
}
if (plistValue("LSApplicationCategoryType") !== "public.app-category.productivity") {
  throw new Error("Info.plist LSApplicationCategoryType must identify AI Monitor as a productivity app");
}
const bundleIdentifier = plistValue("CFBundleIdentifier");
if (manifest.bundle_identifier !== bundleIdentifier) {
  throw new Error("release manifest bundle_identifier does not match Info.plist");
}
if (manifest.application_category !== plistValue("LSApplicationCategoryType")) {
  throw new Error("release manifest application_category does not match Info.plist");
}
if (manifest.launch_agent_label !== launchAgentLabel(bundleIdentifier)) {
  throw new Error("release manifest launch_agent_label does not match expected app LaunchAgent label");
}
if (manifest.app_version !== plistValue("CFBundleShortVersionString")) {
  throw new Error("release manifest app_version does not match Info.plist");
}
if (manifest.app_build !== plistValue("CFBundleVersion")) {
  throw new Error("release manifest app_build does not match Info.plist");
}
const minimumMacosVersion = plistValue("LSMinimumSystemVersion");
if (minimumMacosVersion !== process.env.MIN_MACOS_VERSION) {
  throw new Error("Info.plist LSMinimumSystemVersion does not match verifier minimum macOS version");
}
if (manifest.minimum_macos_version !== minimumMacosVersion) {
  throw new Error("release manifest minimum_macos_version does not match Info.plist");
}
const expectedArchitectures = sortedWords(process.env.EXPECTED_MACOS_ARCHS);
assertStringArrayEqual(manifest.architectures?.app, expectedArchitectures, "release manifest app architectures");
assertStringArrayEqual(manifest.architectures?.daemon, expectedArchitectures, "release manifest daemon architectures");
const appleEventsUsage = plistValue("NSAppleEventsUsageDescription");
if (!/browser/i.test(appleEventsUsage) || !/terminal/i.test(appleEventsUsage)) {
  throw new Error("Info.plist NSAppleEventsUsageDescription must explain browser and terminal activation");
}
const expectedReleaseMode = process.env.REQUIRE_NOTARIZATION === "1";
if (manifest.release_mode !== expectedReleaseMode) {
  throw new Error("release manifest release_mode does not match verifier mode");
}
if (manifest.signing?.identity !== manifest.codesign_identity) {
  throw new Error("release manifest signing.identity must match codesign_identity");
}
if (manifest.signing?.skipped !== false) {
  throw new Error("release manifest must show codesigning was not skipped");
}
if (manifest.signing?.hardened_runtime !== true) {
  throw new Error("release manifest must show hardened runtime signing");
}
if (manifest.signing?.apple_events_entitlement !== true) {
  throw new Error("release manifest must show Apple Events entitlement signing");
}
if (manifest.signing?.ad_hoc !== (manifest.codesign_identity === "ad-hoc")) {
  throw new Error("release manifest signing.ad_hoc does not match codesign_identity");
}
if (manifest.entitlements?.["com.apple.security.automation.apple-events"] !== true) {
  throw new Error("release manifest must declare Apple Events automation entitlement");
}
if (manifest.distribution?.public_macos_installer !== `${process.env.APP_NAME}.dmg`) {
  throw new Error("release manifest must mark the DMG as the public macOS installer");
}
if (manifest.distribution?.app_zip_usage !== "automation_only_not_public_installer") {
  throw new Error("release manifest must mark the app zip as automation-only, not a public installer");
}
if (manifest.distribution?.browser_extension_usage !== "store_or_managed_rollout") {
  throw new Error("release manifest must describe browser extension distribution as store or managed rollout");
}
if (manifest.browser_extension_install_url !== manifest.distribution?.browser_extension_install_url) {
  throw new Error("release manifest browser extension install URL fields must match");
}
if (manifest.browser_extension_privacy_policy_url !== manifest.distribution?.browser_extension_privacy_policy_url) {
  throw new Error("release manifest browser extension privacy policy URL fields must match");
}
if (expectedReleaseMode) {
  if (typeof manifest.browser_extension_install_url !== "string" ||
      !/^https:\/\/\S+$/.test(manifest.browser_extension_install_url) ||
      /example|yourcompany|your-company|localhost|127[.]0[.]0[.]1/i.test(manifest.browser_extension_install_url)) {
    throw new Error("release manifest must include a real HTTPS browser extension install URL in release mode");
  }
  if (typeof manifest.browser_extension_privacy_policy_url !== "string" ||
      !/^https:\/\/\S+$/.test(manifest.browser_extension_privacy_policy_url) ||
      /example|yourcompany|your-company|localhost|127[.]0[.]0[.]1/i.test(manifest.browser_extension_privacy_policy_url)) {
    throw new Error("release manifest must include a real HTTPS browser extension privacy policy URL in release mode");
  }
} else if (manifest.browser_extension_install_url !== null) {
  if (typeof manifest.browser_extension_install_url !== "string" ||
      !/^https:\/\/\S+$/.test(manifest.browser_extension_install_url)) {
    throw new Error("non-release browser extension install URL must be null or a valid HTTPS URL");
  }
}
if (!expectedReleaseMode && manifest.browser_extension_privacy_policy_url !== null) {
  if (typeof manifest.browser_extension_privacy_policy_url !== "string" ||
      !/^https:\/\/\S+$/.test(manifest.browser_extension_privacy_policy_url)) {
    throw new Error("non-release browser extension privacy policy URL must be null or a valid HTTPS URL");
  }
}
if (manifest.distribution?.ide_extension_usage !== "recommended_vsix_installer") {
  throw new Error("release manifest must describe IDE extension distribution as the recommended VSIX installer");
}
if (manifest.distribution?.ide_extension_folder_zip_usage !== "optional_unpacked_install") {
  throw new Error("release manifest must describe IDE extension folder zip as optional unpacked install");
}
if (manifest.distribution?.terminal_integrations_usage !== "optional_user_installer") {
  throw new Error("release manifest must describe terminal integrations as optional user installer");
}
const publishWithRelease = manifest.distribution?.publish_with_release;
const expectedPublishWithRelease = [
  `${process.env.APP_NAME}.dmg`,
  `${process.env.APP_NAME} IDE Extension.vsix`,
  `${process.env.APP_NAME} IDE Extension.zip`,
  `${process.env.APP_NAME} Terminal Integrations.zip`,
  "SHA256SUMS.txt",
  "RELEASE_MANIFEST.json",
].sort();
assertStringArrayEqual(publishWithRelease, expectedPublishWithRelease, "release manifest publish_with_release");
const expectedDmgEntries = [
  `${process.env.APP_NAME}.app`,
  "Applications",
  "README.txt",
  "LICENSE.txt",
  "THIRD-PARTY-NOTICES.txt",
  "PRIVACY.txt",
  "UNINSTALL.txt",
  "TROUBLESHOOTING.txt",
  "UNINSTALL.command",
].sort();
assertStringArrayEqual(manifest.dmg_contents?.root_entries, expectedDmgEntries, "release manifest DMG root entries");
if (manifest.dmg_contents?.support_files?.readme !== "README.txt" ||
    manifest.dmg_contents?.support_files?.license !== "LICENSE.txt" ||
    manifest.dmg_contents?.support_files?.third_party_notices !== "THIRD-PARTY-NOTICES.txt" ||
    manifest.dmg_contents?.support_files?.privacy_notice !== "PRIVACY.txt" ||
    manifest.dmg_contents?.support_files?.uninstall_guide !== "UNINSTALL.txt" ||
    manifest.dmg_contents?.support_files?.troubleshooting_guide !== "TROUBLESHOOTING.txt" ||
    manifest.dmg_contents?.support_files?.uninstall_command?.file !== "UNINSTALL.command" ||
    manifest.dmg_contents?.support_files?.uninstall_command?.behavior !== "preview_then_requires_confirmation" ||
    manifest.dmg_contents?.support_files?.uninstall_command?.confirmation_phrase !== "DELETE") {
  throw new Error("release manifest must describe DMG support files and safe uninstall command behavior");
}
if (expectedReleaseMode) {
  const copyright = plistValue("NSHumanReadableCopyright");
  if (bundleIdentifier.startsWith("local.")) {
    throw new Error("release bundle identifier must not use local.*");
  }
  if (/development|local/i.test(copyright)) {
    throw new Error("release copyright must not contain development/local wording");
  }
  if (manifest.codesign_identity === "ad-hoc") {
    throw new Error("release manifest codesign_identity must be a Developer ID identity, not ad-hoc");
  }
  if (manifest.signing?.developer_id !== true) {
    throw new Error("release manifest must show Developer ID signing in release mode");
  }
}

const expectedNotarizationState = {
  required: expectedReleaseMode,
  submitted: expectedReleaseMode,
  stapled_ticket_validated: expectedReleaseMode,
  app_submitted: expectedReleaseMode,
  app_stapled_ticket_validated: expectedReleaseMode,
  app_gatekeeper_execute_assessed: expectedReleaseMode,
  dmg_submitted: expectedReleaseMode,
  dmg_stapled_ticket_validated: expectedReleaseMode,
  dmg_gatekeeper_open_assessed: expectedReleaseMode,
  mounted_app_stapled_ticket_validated: expectedReleaseMode,
  mounted_app_gatekeeper_execute_assessed: expectedReleaseMode,
  mounted_app_gatekeeper_execute_assessment_required: expectedReleaseMode,
};
for (const [key, expected] of Object.entries(expectedNotarizationState)) {
  if (manifest.notarization?.[key] !== expected) {
    throw new Error(`release manifest notarization.${key} must be ${expected}`);
  }
}
if (!expectedReleaseMode && manifest.signing?.developer_id !== false) {
  throw new Error("non-release manifest must not claim Developer ID signing");
}

const checksumByFile = new Map(fs.readFileSync(process.env.CHECKSUMS_PATH, "utf8")
  .trim()
  .split(/\n+/)
  .map((line) => {
    const match = line.match(/^([0-9a-f]{64})\s{2}(.+)$/);
    if (!match) throw new Error(`invalid checksum line: ${line}`);
    return [match[2], match[1]];
  }));
if (!checksumByFile.has("RELEASE_MANIFEST.json")) {
  throw new Error("SHA256SUMS must include RELEASE_MANIFEST.json");
}

const artifacts = Array.isArray(manifest.artifacts) ? manifest.artifacts : [];
const artifactChecksumByFile = new Map(
  Array.from(checksumByFile.entries()).filter(([file]) => file !== "RELEASE_MANIFEST.json")
);
const expectedArtifactMetadata = {
  [`${process.env.APP_NAME}.dmg`]: {
    role: "public_macos_installer",
    audience: "ordinary_users",
    publish: true,
    version: manifest.app_version,
    build: manifest.app_build,
  },
  [`${process.env.APP_NAME}.zip`]: {
    role: "app_archive",
    audience: "automation_and_internal_deployment",
    publish: false,
    version: manifest.app_version,
    build: manifest.app_build,
  },
  [`${process.env.APP_NAME} Browser Extension.zip`]: {
    role: "browser_extension_package",
    audience: "chrome_web_store_or_managed_rollout",
    publish: false,
    version: manifest.browser_extension_version,
  },
  [`${process.env.APP_NAME} IDE Extension.zip`]: {
    role: "ide_extension_unpacked_folder",
    audience: "vscode_cursor_fallback",
    publish: true,
    version: manifest.ide_extension_version,
  },
  [`${process.env.APP_NAME} IDE Extension.vsix`]: {
    role: "ide_extension_vsix",
    audience: "vscode_cursor_users",
    publish: true,
    version: manifest.ide_extension_version,
  },
  [`${process.env.APP_NAME} Terminal Integrations.zip`]: {
    role: "terminal_integrations_package",
    audience: "terminal_agent_users",
    publish: true,
    version: manifest.app_version,
  },
};
if (artifacts.length !== artifactChecksumByFile.size) {
  throw new Error("release manifest artifact count does not match SHA256SUMS");
}
for (const artifact of artifacts) {
  if (!artifactChecksumByFile.has(artifact.file)) {
    throw new Error(`release manifest has unknown artifact ${artifact.file}`);
  }
  if (artifact.sha256 !== artifactChecksumByFile.get(artifact.file)) {
    throw new Error(`release manifest checksum mismatch for ${artifact.file}`);
  }
  const actualBytes = fs.statSync(path.join(distDir, artifact.file)).size;
  if (artifact.bytes !== actualBytes) {
    throw new Error(`release manifest byte size mismatch for ${artifact.file}`);
  }
  const expectedMetadata = expectedArtifactMetadata[artifact.file];
  if (!expectedMetadata) {
    throw new Error(`release manifest lacks expected artifact metadata for ${artifact.file}`);
  }
  for (const [key, expected] of Object.entries(expectedMetadata)) {
    if (artifact[key] !== expected) {
      throw new Error(`release manifest artifact ${artifact.file} ${key} must be ${expected}`);
    }
  }
  if (typeof artifact.usage !== "string" || artifact.usage.trim().length < 20) {
    throw new Error(`release manifest artifact ${artifact.file} must include user-facing usage text`);
  }
}
NODE

/usr/bin/plutil -lint "${APP_DIR}/Contents/Info.plist" >/dev/null
/usr/bin/codesign --verify --deep --strict --verbose=2 "${APP_DIR}" >/dev/null
/usr/bin/codesign --verify --strict --verbose=2 "${APP_DIR}/Contents/Resources/ai-monitor-daemon" >/dev/null
"${APP_DIR}/Contents/Resources/ai-monitor-daemon" --help >/dev/null
validate_app_icon_resources "${APP_DIR}" "App bundle"
validate_web_icon_resources "${APP_DIR}" "App bundle"
assert_codesign_runtime "${APP_DIR}" "App bundle"
assert_codesign_runtime "${APP_DIR}/Contents/Resources/ai-monitor-daemon" "Bundled daemon"
assert_codesign_entitlement_true "${APP_DIR}" "${APPLE_EVENTS_ENTITLEMENT}" "App bundle"
if [[ "${REQUIRE_NOTARIZATION}" == "1" ]]; then
  xcrun stapler validate "${APP_DIR}" >/dev/null
  /usr/sbin/spctl --assess --type execute --verbose "${APP_DIR}" >/dev/null
fi
assert_directory_entries_exact "${APP_DIR}" "App bundle" "${app_bundle_entries[@]}"

if zipinfo -1 "${ZIP_PATH}" | rg -q '(^|/)\._'; then
  echo "Zip contains AppleDouble metadata files" >&2
  exit 1
fi
unzip -t "${ZIP_PATH}" >/dev/null

app_zip_entries_allowed=(
  "${APP_NAME}.app/"
)
for entry in "${app_bundle_entries[@]}"; do
  if [[ -d "${APP_DIR}/${entry}" ]]; then
    app_zip_entries_allowed+=("${APP_NAME}.app/${entry}/")
  else
    app_zip_entries_allowed+=("${APP_NAME}.app/${entry}")
  fi
done
assert_zip_entries_exact "${ZIP_PATH}" "App archive" "${app_zip_entries_allowed[@]}"

"${ROOT_DIR}/scripts/test_browser_detectors.sh" >/dev/null

if zipinfo -1 "${BROWSER_EXTENSION_ZIP_PATH}" | rg -q '(^|/)(\._|README\.md$|test/|fixtures/)'; then
  echo "Browser extension zip contains development-only or metadata files" >&2
  exit 1
fi
unzip -t "${BROWSER_EXTENSION_ZIP_PATH}" >/dev/null

extension_entries_allowed=(
  "manifest.json"
  "background.js"
  "content.js"
  "popup.css"
  "popup.html"
  "popup.js"
  "open-tab.html"
  "open-tab.js"
  "icons/icon-16.png"
  "icons/icon-32.png"
  "icons/icon-48.png"
  "icons/icon-128.png"
)
assert_zip_entries_exact "${BROWSER_EXTENSION_ZIP_PATH}" "Browser extension" "${extension_entries_allowed[@]}"

manifest_json="$(unzip -p "${BROWSER_EXTENSION_ZIP_PATH}" manifest.json)"
MANIFEST_JSON="${manifest_json}" node <<'NODE'
const manifest = JSON.parse(process.env.MANIFEST_JSON);
if (manifest.manifest_version !== 3) throw new Error("manifest_version must be 3");
if (!manifest.name || !manifest.version || !manifest.description) {
  throw new Error("manifest name, version, and description are required");
}
if (!manifest.background?.service_worker) throw new Error("background service worker required");
if (!Array.isArray(manifest.content_scripts) || manifest.content_scripts.length === 0) {
  throw new Error("content scripts required");
}

const requiredIcons = {
  16: "icons/icon-16.png",
  32: "icons/icon-32.png",
  48: "icons/icon-48.png",
  128: "icons/icon-128.png",
};
for (const [size, path] of Object.entries(requiredIcons)) {
  if (manifest.icons?.[size] !== path) {
    throw new Error(`manifest icons.${size} must be ${path}`);
  }
  if (manifest.action?.default_icon?.[size] !== path) {
    throw new Error(`manifest action.default_icon.${size} must be ${path}`);
  }
}
if (manifest.action?.default_popup !== "popup.html" || manifest.action?.default_title !== "AI Monitor") {
  throw new Error("manifest action must use the packaged popup and AI Monitor title");
}

const expectedPermissions = ["alarms", "scripting", "storage", "tabs"];
const permissions = Array.isArray(manifest.permissions) ? [...manifest.permissions].sort() : [];
if (JSON.stringify(permissions) !== JSON.stringify(expectedPermissions)) {
  throw new Error(`manifest permissions must be exactly ${expectedPermissions.join(", ")}`);
}

const allowedHostPermissions = new Set([
  "http://127.0.0.1/*",
  "http://localhost/*",
  "https://chatgpt.com/*",
  "https://chat.openai.com/*",
  "https://claude.ai/*",
  "https://gemini.google.com/*",
  "https://www.perplexity.ai/*",
  "https://perplexity.ai/*",
  "https://grok.com/*",
  "https://www.grok.com/*",
  "https://github.com/*",
  "https://x.com/grok*",
  "https://x.com/i/grok*",
  "https://www.x.com/grok*",
  "https://www.x.com/i/grok*",
  "https://twitter.com/grok*",
  "https://twitter.com/i/grok*",
  "https://www.twitter.com/grok*",
  "https://www.twitter.com/i/grok*",
]);
const hostPermissions = Array.isArray(manifest.host_permissions) ? manifest.host_permissions : [];
if (!hostPermissions.includes("http://127.0.0.1/*") || !hostPermissions.includes("http://localhost/*")) {
  throw new Error("manifest host_permissions must include local daemon loopback origins");
}
for (const host of hostPermissions) {
  if (host === "<all_urls>" || host.includes("*://*")) {
    throw new Error("manifest must not request broad all-site host permissions");
  }
  if (!allowedHostPermissions.has(host)) {
    throw new Error(`manifest host permission is not allowlisted: ${host}`);
  }
  if (/^https:\/\/(www\.)?(x|twitter)\.com\/\*$/.test(host)) {
    throw new Error("X/Twitter host permissions must be limited to Grok paths");
  }
}

for (const script of manifest.content_scripts) {
  if (JSON.stringify(script.js || []) !== JSON.stringify(["content.js"])) {
    throw new Error("content scripts must only load content.js");
  }
  if (script.run_at !== "document_idle") {
    throw new Error("content script must run at document_idle");
  }
  for (const match of script.matches || []) {
    if (match === "<all_urls>" || match.includes("*://*")) {
      throw new Error("content scripts must not use broad all-site matches");
    }
    if (!allowedHostPermissions.has(match)) {
      throw new Error(`content script match is not allowlisted: ${match}`);
    }
    if (/^https:\/\/(www\.)?(x|twitter)\.com\/\*$/.test(match)) {
      throw new Error("X/Twitter content script matches must be limited to Grok paths");
    }
  }
}
NODE

assert_zip_png_dimensions "${BROWSER_EXTENSION_ZIP_PATH}" "icons/icon-16.png" 16 16 "Browser extension"
assert_zip_png_dimensions "${BROWSER_EXTENSION_ZIP_PATH}" "icons/icon-32.png" 32 32 "Browser extension"
assert_zip_png_dimensions "${BROWSER_EXTENSION_ZIP_PATH}" "icons/icon-48.png" 48 48 "Browser extension"
assert_zip_png_dimensions "${BROWSER_EXTENSION_ZIP_PATH}" "icons/icon-128.png" 128 128 "Browser extension"

popup_html="$(unzip -p "${BROWSER_EXTENSION_ZIP_PATH}" popup.html)"
popup_js="$(unzip -p "${BROWSER_EXTENSION_ZIP_PATH}" popup.js)"
if ! rg -q 'id="clearToken"' <<< "${popup_html}" ||
   ! rg -q 'chrome\.storage\.local\.remove\("apiToken"\)' <<< "${popup_js}"; then
  echo "Browser extension popup must expose Clear Token and remove stored apiToken." >&2
  exit 1
fi
if ! rg -q 'Paste from AI Monitor Settings' <<< "${popup_html}" ||
   ! rg -q 'Copy API token' <<< "${popup_html}" ||
   ! rg -q 'Open AI Monitor from Applications' <<< "${popup_html}" ||
   ! rg -q 'Open AI Monitor Settings' <<< "${popup_html}" ||
   ! rg -q 'id="openSettings"' <<< "${popup_html}" ||
   ! rg -q 'Needs token' <<< "${popup_js}" ||
   ! rg -q 'friendlyErrorMessage' <<< "${popup_js}" ||
   ! rg -q 'Start daemon' <<< "${popup_js}" ||
   ! rg -q 'ai-monitor://settings' <<< "${popup_js}" ||
   ! rg -q 'openAIMonitorSettings' <<< "${popup_js}" ||
   ! rg -Fq 'chrome.tabs.create({ url: "ai-monitor://settings", active: true })' <<< "${popup_js}"; then
  echo "Browser extension popup must guide ordinary users through token setup and daemon offline recovery." >&2
  exit 1
fi

if zipinfo -1 "${TERMINAL_INTEGRATIONS_ZIP_PATH}" | rg -q '(^|/)(\._|__MACOSX/|\.DS_Store$|\.gitkeep$|test/|fixtures/|node_modules/)'; then
  echo "Terminal integrations zip contains development or OS metadata files" >&2
  exit 1
fi
unzip -t "${TERMINAL_INTEGRATIONS_ZIP_PATH}" >/dev/null

terminal_entries_allowed=(
  "Install AI Monitor Terminal Integrations.command"
  "integrations/terminal/README.md"
  "integrations/terminal/ai-monitor-terminal.js"
  "integrations/terminal/install-terminal-integrations.command"
  "integrations/terminal/install-packaged-integrations.js"
  "integrations/terminal/install-official-hooks.js"
  "integrations/terminal/claude-code/hook.sh"
  "integrations/terminal/claude-code/official-hook.sh"
  "integrations/terminal/codex-cli/hook.sh"
  "integrations/terminal/codex-cli/official-hook.sh"
  "integrations/terminal/shell/ai-monitor.sh"
  "integrations/superset/install-ai-monitor-hook.js"
  "integrations/superset/ai-monitor-superset-hook.js"
  "docs/integrations.md"
)
assert_zip_entries_exact "${TERMINAL_INTEGRATIONS_ZIP_PATH}" "Terminal integrations" "${terminal_entries_allowed[@]}"
if ! zipinfo -1 "${TERMINAL_INTEGRATIONS_ZIP_PATH}" | rg -Fxq "Install AI Monitor Terminal Integrations.command"; then
  echo "Terminal integrations zip is missing the root guided install command." >&2
  exit 1
fi
validate_terminal_installer_package

if zipinfo -1 "${IDE_EXTENSION_ZIP_PATH}" | rg -q '(^|/)(\._|__MACOSX/|\.DS_Store$|\.gitkeep$|test/|fixtures/|node_modules/|jetbrains/)'; then
  echo "IDE extension zip contains development, JetBrains skeleton, or OS metadata files" >&2
  exit 1
fi
unzip -t "${IDE_EXTENSION_ZIP_PATH}" >/dev/null

ide_entries_allowed=(
  "package.json"
  "extension.js"
  "README.md"
)
assert_zip_entries_exact "${IDE_EXTENSION_ZIP_PATH}" "IDE extension" "${ide_entries_allowed[@]}"

ide_package_json="$(unzip -p "${IDE_EXTENSION_ZIP_PATH}" package.json)"
node -e '
const fs = require("node:fs");
const pkg = JSON.parse(fs.readFileSync(0, "utf8"));
if (pkg.name !== "ai-monitor-vscode") throw new Error("IDE extension package name mismatch");
if (pkg.main !== "./extension.js") throw new Error("IDE extension main must be ./extension.js");
if (!pkg.engines?.vscode) throw new Error("IDE extension must declare VS Code engine support");
if (!pkg.contributes?.configuration?.properties?.["aiMonitor.apiToken"]) {
  throw new Error("IDE extension must expose apiToken setting");
}
const commands = (pkg.contributes?.commands || []).map((entry) => entry.command);
if (commands.length < 10 ||
    !commands.includes("aiMonitor.sendTestEvent") ||
    !commands.includes("aiMonitor.openDesktopSettings")) {
  throw new Error("IDE extension must expose task state, test event, and Settings recovery commands");
}
' <<< "${ide_package_json}"
validate_ide_extension_runtime_package "${IDE_EXTENSION_ZIP_PATH}" "." "IDE extension zip"

if zipinfo -1 "${IDE_EXTENSION_VSIX_PATH}" | rg -q '(^|/)(\._|__MACOSX/|\.DS_Store$|\.gitkeep$|test/|fixtures/|node_modules/|jetbrains/)'; then
  echo "IDE extension VSIX contains development, JetBrains skeleton, or OS metadata files" >&2
  exit 1
fi
unzip -t "${IDE_EXTENSION_VSIX_PATH}" >/dev/null

ide_vsix_entries_allowed=(
  "[Content_Types].xml"
  "extension.vsixmanifest"
  "extension/package.json"
  "extension/extension.js"
  "extension/README.md"
)
assert_zip_entries_exact "${IDE_EXTENSION_VSIX_PATH}" "IDE extension VSIX" "${ide_vsix_entries_allowed[@]}"

ide_vsix_package_json="$(unzip -p "${IDE_EXTENSION_VSIX_PATH}" extension/package.json)"
node -e '
const fs = require("node:fs");
const pkg = JSON.parse(fs.readFileSync(0, "utf8"));
if (pkg.name !== "ai-monitor-vscode") throw new Error("IDE VSIX package name mismatch");
if (pkg.main !== "./extension.js") throw new Error("IDE VSIX main must be ./extension.js");
if (!pkg.contributes?.configuration?.properties?.["aiMonitor.apiToken"]) {
  throw new Error("IDE VSIX must expose apiToken setting");
}
const commands = (pkg.contributes?.commands || []).map((entry) => entry.command);
if (!commands.includes("aiMonitor.sendTestEvent") || !commands.includes("aiMonitor.openDesktopSettings")) {
  throw new Error("IDE VSIX must expose test event and Settings recovery commands");
}
' <<< "${ide_vsix_package_json}"

ide_vsix_manifest="$(unzip -p "${IDE_EXTENSION_VSIX_PATH}" extension.vsixmanifest)"
if ! rg -q 'Microsoft.VisualStudio.Code.Manifest' <<< "${ide_vsix_manifest}" ||
   ! rg -q 'InstallationTarget Id="Microsoft.VisualStudio.Code"' <<< "${ide_vsix_manifest}"; then
  echo "IDE VSIX manifest must declare VS Code installation target and package manifest asset." >&2
  exit 1
fi
validate_ide_extension_runtime_package "${IDE_EXTENSION_VSIX_PATH}" "extension" "IDE extension VSIX"

/usr/bin/hdiutil verify "${DMG_PATH}" >/dev/null

if [[ "${REQUIRE_NOTARIZATION}" == "1" ]]; then
  xcrun stapler validate "${DMG_PATH}" >/dev/null
  /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose "${DMG_PATH}" >/dev/null
fi

MOUNT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ai-monitor-dmg.XXXXXX")"
cleanup() {
  /usr/bin/hdiutil detach "${MOUNT_DIR}" >/dev/null 2>&1 || true
  rmdir "${MOUNT_DIR}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

/usr/bin/hdiutil attach \
  -nobrowse \
  -readonly \
  -mountpoint "${MOUNT_DIR}" \
  "${DMG_PATH}" >/dev/null

require_path "${MOUNT_DIR}/${APP_NAME}.app"
require_path "${MOUNT_DIR}/${APP_NAME}.app/Contents/Resources/ai-monitor-daemon"
require_path "${MOUNT_DIR}/${APP_NAME}.app/Contents/Resources/default.toml"
require_path "${MOUNT_DIR}/${APP_NAME}.app/Contents/Resources/LICENSE.txt"
require_path "${MOUNT_DIR}/${APP_NAME}.app/Contents/Resources/THIRD-PARTY-NOTICES.txt"
require_path "${MOUNT_DIR}/${APP_NAME}.app/Contents/Resources/first-run-guide.txt"
require_path "${MOUNT_DIR}/${APP_NAME}.app/Contents/Resources/browser-extension-install-url.txt"
require_path "${MOUNT_DIR}/${APP_NAME}.app/Contents/Resources/privacy-notice.txt"
require_path "${MOUNT_DIR}/${APP_NAME}.app/Contents/Resources/troubleshooting-guide.txt"
require_path "${MOUNT_DIR}/${APP_NAME}.app/Contents/Resources/uninstall-guide.txt"
validate_app_icon_resources "${MOUNT_DIR}/${APP_NAME}.app" "DMG app bundle"
validate_web_icon_resources "${MOUNT_DIR}/${APP_NAME}.app" "DMG app bundle"
require_path "${MOUNT_DIR}/Applications"
require_path "${MOUNT_DIR}/README.txt"
require_path "${MOUNT_DIR}/LICENSE.txt"
require_path "${MOUNT_DIR}/THIRD-PARTY-NOTICES.txt"
require_path "${MOUNT_DIR}/PRIVACY.txt"
require_path "${MOUNT_DIR}/UNINSTALL.txt"
require_path "${MOUNT_DIR}/TROUBLESHOOTING.txt"
require_path "${MOUNT_DIR}/UNINSTALL.command"

assert_directory_top_entries_exact "${MOUNT_DIR}" "DMG root" \
  "${APP_NAME}.app" \
  "Applications" \
  "README.txt" \
  "LICENSE.txt" \
  "THIRD-PARTY-NOTICES.txt" \
  "PRIVACY.txt" \
  "UNINSTALL.txt" \
  "TROUBLESHOOTING.txt" \
  "UNINSTALL.command"
assert_directory_entries_exact "${MOUNT_DIR}/${APP_NAME}.app" "DMG app bundle" "${app_bundle_entries[@]}"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${MOUNT_DIR}/${APP_NAME}.app" >/dev/null
/usr/bin/codesign --verify --strict --verbose=2 "${MOUNT_DIR}/${APP_NAME}.app/Contents/Resources/ai-monitor-daemon" >/dev/null
assert_codesign_runtime "${MOUNT_DIR}/${APP_NAME}.app" "DMG app bundle"
assert_codesign_runtime "${MOUNT_DIR}/${APP_NAME}.app/Contents/Resources/ai-monitor-daemon" "DMG bundled daemon"
assert_codesign_entitlement_true "${MOUNT_DIR}/${APP_NAME}.app" "${APPLE_EVENTS_ENTITLEMENT}" "DMG app bundle"

if [[ "${REQUIRE_NOTARIZATION}" == "1" ]]; then
  xcrun stapler validate "${MOUNT_DIR}/${APP_NAME}.app" >/dev/null
  /usr/sbin/spctl --assess --type execute --verbose "${MOUNT_DIR}/${APP_NAME}.app" >/dev/null
fi

validate_default_config "${MOUNT_DIR}/${APP_NAME}.app/Contents/Resources/default.toml"
validate_license_notice_files "${MOUNT_DIR}/${APP_NAME}.app/Contents/Resources/LICENSE.txt" "${MOUNT_DIR}/${APP_NAME}.app/Contents/Resources/THIRD-PARTY-NOTICES.txt"
validate_license_notice_files "${MOUNT_DIR}/LICENSE.txt" "${MOUNT_DIR}/THIRD-PARTY-NOTICES.txt"
validate_first_run_guide "${MOUNT_DIR}/${APP_NAME}.app/Contents/Resources/first-run-guide.txt" "${manifest_browser_extension_install_url}"
validate_browser_extension_install_url_resource "${MOUNT_DIR}/${APP_NAME}.app/Contents/Resources/browser-extension-install-url.txt" "${manifest_browser_extension_install_url}"
validate_privacy_notice "${MOUNT_DIR}/${APP_NAME}.app/Contents/Resources/privacy-notice.txt"
validate_troubleshooting_guide "${MOUNT_DIR}/${APP_NAME}.app/Contents/Resources/troubleshooting-guide.txt"
validate_uninstall_guide "${MOUNT_DIR}/${APP_NAME}.app/Contents/Resources/uninstall-guide.txt"
validate_privacy_notice "${MOUNT_DIR}/PRIVACY.txt"
validate_troubleshooting_guide "${MOUNT_DIR}/TROUBLESHOOTING.txt"
validate_uninstall_guide "${MOUNT_DIR}/UNINSTALL.txt"
if [[ ! -x "${MOUNT_DIR}/UNINSTALL.command" ]]; then
  echo "DMG UNINSTALL.command is not executable" >&2
  exit 1
fi
if rg -n '<bundle-id>|<launch-agent-label>' "${MOUNT_DIR}/UNINSTALL.command"; then
  echo "DMG UNINSTALL.command contains unresolved bundle or LaunchAgent placeholders" >&2
  exit 1
fi
uninstall_preview="$("${MOUNT_DIR}/UNINSTALL.command" --dry-run)"
if ! rg -q "Dry run only" <<< "${uninstall_preview}" ||
   ! rg -q "osascript" <<< "${uninstall_preview}" ||
   ! rg -q "Library/Preferences" <<< "${uninstall_preview}" ||
   ! rg -q "Library/LaunchAgents" <<< "${uninstall_preview}"; then
  echo "DMG UNINSTALL.command must preview running-app quit, preferences, and LaunchAgent cleanup without deleting files" >&2
  exit 1
fi
assert_macho_archs_exact "${MOUNT_DIR}/${APP_NAME}.app/Contents/MacOS/${APP_NAME}" "DMG app executable" "${EXPECTED_MACOS_ARCHS[@]}"
assert_macho_archs_exact "${MOUNT_DIR}/${APP_NAME}.app/Contents/Resources/ai-monitor-daemon" "DMG bundled daemon" "${EXPECTED_MACOS_ARCHS[@]}"
assert_macho_min_macos_at_most "${MOUNT_DIR}/${APP_NAME}.app/Contents/MacOS/${APP_NAME}" "${MIN_MACOS_VERSION}" "DMG app executable"
assert_macho_min_macos_at_most "${MOUNT_DIR}/${APP_NAME}.app/Contents/Resources/ai-monitor-daemon" "${MIN_MACOS_VERSION}" "DMG bundled daemon"

if ! rg -q "Drag AI Monitor.app into Applications" "${MOUNT_DIR}/README.txt"; then
  echo "DMG README.txt is missing install guidance" >&2
  exit 1
fi

if ! rg -q "Settings opens automatically on first launch" "${MOUNT_DIR}/README.txt"; then
  echo "DMG README.txt is missing first-launch Settings guidance" >&2
  exit 1
fi

if ! rg -q "Copy diagnostics" "${MOUNT_DIR}/README.txt"; then
  echo "DMG README.txt is missing support guidance" >&2
  exit 1
fi

if ! rg -q "LICENSE.txt" "${MOUNT_DIR}/README.txt" ||
   ! rg -q "THIRD-PARTY-NOTICES.txt" "${MOUNT_DIR}/README.txt"; then
  echo "DMG README.txt is missing license and third-party notices guidance" >&2
  exit 1
fi

if ! rg -q "Copy license notices" "${MOUNT_DIR}/README.txt"; then
  echo "DMG README.txt is missing license notices support guidance" >&2
  exit 1
fi

if ! rg -q "Copy privacy notice" "${MOUNT_DIR}/README.txt"; then
  echo "DMG README.txt is missing privacy notice support guidance" >&2
  exit 1
fi

if ! rg -q "Copy troubleshooting guide" "${MOUNT_DIR}/README.txt" ||
   ! rg -q "TROUBLESHOOTING.txt" "${MOUNT_DIR}/README.txt"; then
  echo "DMG README.txt is missing troubleshooting guide support guidance" >&2
  exit 1
fi

if ! rg -q "Copy uninstall guide" "${MOUNT_DIR}/README.txt"; then
  echo "DMG README.txt is missing uninstall guide support guidance" >&2
  exit 1
fi

if ! rg -q "To remove all local data" "${MOUNT_DIR}/README.txt"; then
  echo "DMG README.txt is missing local-data removal guidance" >&2
  exit 1
fi

if ! rg -q "Chrome Web Store or managed extension" "${MOUNT_DIR}/README.txt"; then
  echo "DMG README.txt must direct ordinary browser users to the store or managed extension" >&2
  exit 1
fi
if rg -n 'AI Monitor Browser Extension\.zip|browser extension zip' "${MOUNT_DIR}/README.txt"; then
  echo "DMG README.txt must not mention the internal browser extension zip artifact" >&2
  exit 1
fi
if rg -n '<browser-extension-install-url>' "${MOUNT_DIR}/README.txt"; then
  echo "DMG README.txt contains unresolved browser extension install URL placeholder" >&2
  exit 1
fi

if ! rg -q "AI Monitor IDE Extension.vsix" "${MOUNT_DIR}/README.txt" ||
   ! rg -q "AI Monitor IDE Extension.zip" "${MOUNT_DIR}/README.txt"; then
  echo "DMG README.txt must mention the optional VS Code/Cursor IDE extension artifact" >&2
  exit 1
fi

if ! rg -q "Read PRIVACY.txt before installing" "${MOUNT_DIR}/README.txt"; then
  echo "DMG README.txt must point users to PRIVACY.txt" >&2
  exit 1
fi

if rg -n '<bundle-id>|<launch-agent-label>' "${MOUNT_DIR}/README.txt"; then
  echo "DMG README.txt contains unresolved bundle or LaunchAgent placeholders" >&2
  exit 1
fi

if ! rg -q "UNINSTALL.command" "${MOUNT_DIR}/README.txt" ||
   ! rg -q "DELETE" "${MOUNT_DIR}/README.txt"; then
  echo "DMG README.txt must explain the safe uninstall command and DELETE confirmation" >&2
  exit 1
fi

if [[ -e "${MOUNT_DIR}/${APP_NAME}.app/Contents/Resources/repo-root.txt" ]]; then
  echo "DMG app contains development-only repo-root.txt" >&2
  exit 1
fi

if find "${MOUNT_DIR}" -name '._*' -print -quit | rg -q .; then
  echo "DMG contains AppleDouble metadata files" >&2
  exit 1
fi

echo "macOS release artifacts verified:"
echo "  ${APP_DIR}"
echo "  ${ZIP_PATH}"
echo "  ${DMG_PATH}"
echo "  ${BROWSER_EXTENSION_ZIP_PATH}"
echo "  ${IDE_EXTENSION_ZIP_PATH}"
echo "  ${IDE_EXTENSION_VSIX_PATH}"
echo "  ${TERMINAL_INTEGRATIONS_ZIP_PATH}"
echo "  ${CHECKSUMS_PATH}"
echo "  ${RELEASE_MANIFEST_PATH}"
