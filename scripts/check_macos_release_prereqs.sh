#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_ENV_TEMPLATE="${ROOT_DIR}/docs/macos-release-env.example"
IDENTITY="${AI_MONITOR_CODESIGN_IDENTITY:-}"
NOTARY_PROFILE="${AI_MONITOR_NOTARY_PROFILE:-}"
APPLE_ID="${AI_MONITOR_NOTARY_APPLE_ID:-}"
APPLE_PASSWORD="${AI_MONITOR_NOTARY_PASSWORD:-}"
APPLE_TEAM_ID="${AI_MONITOR_NOTARY_TEAM_ID:-}"
CHECK_NOTARY_ONLINE="${AI_MONITOR_CHECK_NOTARY_ONLINE:-0}"
BUNDLE_ID="${AI_MONITOR_BUNDLE_ID:-}"
APP_VERSION="${AI_MONITOR_APP_VERSION:-0.1.0}"
APP_BUILD="${AI_MONITOR_APP_BUILD:-1}"
MIN_MACOS_VERSION="${AI_MONITOR_MACOS_MIN_VERSION:-13.0}"
MACOS_ARCHS_RAW="${AI_MONITOR_MACOS_ARCHS:-arm64 x86_64}"
COPYRIGHT="${AI_MONITOR_COPYRIGHT:-AI Monitor development build}"
BROWSER_EXTENSION_INSTALL_URL="${AI_MONITOR_BROWSER_EXTENSION_INSTALL_URL:-}"
BROWSER_EXTENSION_PRIVACY_POLICY_URL="${AI_MONITOR_BROWSER_EXTENSION_PRIVACY_POLICY_URL:-}"
ENTITLEMENTS_PATH="${AI_MONITOR_ENTITLEMENTS:-${ROOT_DIR}/apps/desktop-macos/AI-Monitor.entitlements}"
SKIP_NOTARIZE="${AI_MONITOR_SKIP_NOTARIZE:-0}"
SKIP_CODESIGN="${AI_MONITOR_SKIP_CODESIGN:-0}"
FAILURES=0
read -r -a MACOS_ARCHS <<< "${MACOS_ARCHS_RAW}"

pass() {
  printf 'ok: %s\n' "$1"
}

warn() {
  printf 'warn: %s\n' "$1"
}

fail() {
  printf 'missing: %s\n' "$1" >&2
  FAILURES=$((FAILURES + 1))
}

require_command() {
  local command_name="$1"
  if command -v "${command_name}" >/dev/null 2>&1; then
    pass "${command_name} available ($(command -v "${command_name}"))"
  else
    fail "${command_name} is required"
  fi
}

require_executable() {
  local path="$1"
  local label="$2"
  if [[ ! -x "${path}" ]]; then
    fail "${label} must be executable: ${path}"
  else
    pass "${label} is executable"
  fi
}

release_launch_agent_label() {
  if [[ -n "${BUNDLE_ID}" && "${BUNDLE_ID}" != local.* ]]; then
    printf "%s.daemon\n" "${BUNDLE_ID}"
  else
    printf "%s\n" "local.ai-monitor.daemon"
  fi
}

is_placeholder_bundle_id() {
  [[ "$1" =~ (^|[.])(example|yourcompany|your-company)([.]|$) ]]
}

is_placeholder_copyright() {
  [[ "$1" =~ development|Development|Local|[Ee]xample|TODO|Your[[:space:]]+Company ]]
}

is_placeholder_url() {
  [[ "$1" =~ example|yourcompany|your-company|localhost|127[.]0[.]0[.]1 ]]
}

rust_target_for_arch() {
  case "$1" in
    arm64)
      printf "%s\n" "aarch64-apple-darwin"
      ;;
    x86_64)
      printf "%s\n" "x86_64-apple-darwin"
      ;;
    *)
      return 1
      ;;
  esac
}

has_arch() {
  local expected="$1"
  local arch
  for arch in "${MACOS_ARCHS[@]}"; do
    if [[ "${arch}" == "${expected}" ]]; then
      return 0
    fi
  done
  return 1
}

if [[ "$(uname -s)" == "Darwin" ]]; then
  pass "running on macOS"
else
  fail "macOS release packaging must run on macOS"
fi

for command_name in cargo rustup swiftc codesign security xcrun hdiutil ditto shasum zip zipinfo unzip rg node plutil iconutil sips spctl lipo otool osascript; do
  require_command "${command_name}"
done

if [[ ! -f "${ENTITLEMENTS_PATH}" ]]; then
  fail "macOS entitlements file is required: ${ENTITLEMENTS_PATH}"
elif plutil -convert json -o - "${ENTITLEMENTS_PATH}" | node -e '
const fs = require("node:fs");
const entitlements = JSON.parse(fs.readFileSync(0, "utf8"));
if (entitlements["com.apple.security.automation.apple-events"] !== true) process.exit(1);
'; then
  pass "Apple Events automation entitlement configured"
else
  fail "entitlements must enable com.apple.security.automation.apple-events"
fi

if [[ ! -f "${ROOT_DIR}/docs/macos-dmg-readme.txt" ]]; then
  fail "docs/macos-dmg-readme.txt is required for the DMG README"
elif rg -q "LICENSE.txt" "${ROOT_DIR}/docs/macos-dmg-readme.txt" &&
     rg -q "THIRD-PARTY-NOTICES.txt" "${ROOT_DIR}/docs/macos-dmg-readme.txt"; then
  pass "DMG README source present"
else
  fail "DMG README must point users to bundled license and third-party notices"
fi

if [[ ! -f "${RELEASE_ENV_TEMPLATE}" ]]; then
  fail "docs/macos-release-env.example is required so release operators have a complete environment template"
elif rg -q "AI_MONITOR_BUNDLE_ID" "${RELEASE_ENV_TEMPLATE}" &&
     rg -q "AI_MONITOR_COPYRIGHT" "${RELEASE_ENV_TEMPLATE}" &&
     rg -q "AI_MONITOR_BROWSER_EXTENSION_INSTALL_URL" "${RELEASE_ENV_TEMPLATE}" &&
     rg -q "AI_MONITOR_BROWSER_EXTENSION_PRIVACY_POLICY_URL" "${RELEASE_ENV_TEMPLATE}" &&
     rg -q "AI_MONITOR_CODESIGN_IDENTITY" "${RELEASE_ENV_TEMPLATE}" &&
     rg -q "AI_MONITOR_NOTARY_PROFILE" "${RELEASE_ENV_TEMPLATE}" &&
     rg -q "AI_MONITOR_NOTARY_APPLE_ID" "${RELEASE_ENV_TEMPLATE}" &&
     rg -q "AI_MONITOR_NOTARY_PASSWORD" "${RELEASE_ENV_TEMPLATE}" &&
     rg -q "AI_MONITOR_NOTARY_TEAM_ID" "${RELEASE_ENV_TEMPLATE}" &&
     rg -q "AI_MONITOR_APP_VERSION" "${RELEASE_ENV_TEMPLATE}" &&
     rg -q "AI_MONITOR_APP_BUILD" "${RELEASE_ENV_TEMPLATE}" &&
     rg -q "AI_MONITOR_MACOS_MIN_VERSION" "${RELEASE_ENV_TEMPLATE}" &&
     rg -q "AI_MONITOR_MACOS_ARCHS" "${RELEASE_ENV_TEMPLATE}" &&
     rg -q "AI_MONITOR_RELEASE" "${RELEASE_ENV_TEMPLATE}" &&
     rg -q "AI_MONITOR_CHECK_NOTARY_ONLINE" "${RELEASE_ENV_TEMPLATE}" &&
     rg -q "init_macos_release_env.sh" "${ROOT_DIR}/README.md" &&
     rg -q "init_macos_release_env.sh" "${ROOT_DIR}/docs/release.md"; then
  pass "release environment template documents required public-release variables"
else
  fail "docs/macos-release-env.example, README.md, and docs/release.md must document every public release environment variable"
fi

if [[ ! -f "${ROOT_DIR}/LICENSE" ]]; then
  fail "LICENSE is required for public distribution"
elif rg -q "MIT License" "${ROOT_DIR}/LICENSE"; then
  pass "project license present"
else
  fail "LICENSE must include the project MIT license text"
fi

if [[ ! -f "${ROOT_DIR}/docs/macos-app-setup-guide.txt" ]]; then
  fail "docs/macos-app-setup-guide.txt is required for the bundled first-run guide"
elif rg -q "Copy API token" "${ROOT_DIR}/docs/macos-app-setup-guide.txt" &&
     rg -q "Open browser install link" "${ROOT_DIR}/docs/macos-app-setup-guide.txt" &&
     rg -q "Copy browser install link" "${ROOT_DIR}/docs/macos-app-setup-guide.txt" &&
     rg -q "Desktop app observer" "${ROOT_DIR}/docs/macos-app-setup-guide.txt" &&
     rg -q "Copy troubleshooting guide" "${ROOT_DIR}/docs/macos-app-setup-guide.txt" &&
     rg -q "Copy privacy notice" "${ROOT_DIR}/docs/macos-app-setup-guide.txt" &&
     rg -q "Copy uninstall guide" "${ROOT_DIR}/docs/macos-app-setup-guide.txt" &&
     rg -q "Copy diagnostics" "${ROOT_DIR}/docs/macos-app-setup-guide.txt" &&
     rg -q "AI Monitor: Send Test Event" "${ROOT_DIR}/docs/macos-app-setup-guide.txt" &&
     rg -q "Install AI Monitor Terminal Integrations.command" "${ROOT_DIR}/docs/macos-app-setup-guide.txt" &&
     rg -q "install-terminal-integrations.command" "${ROOT_DIR}/docs/macos-app-setup-guide.txt" &&
     rg -q "Extensions: Install from VSIX" "${ROOT_DIR}/docs/macos-app-setup-guide.txt"; then
  pass "bundled first-run guide source present"
else
  fail "first-run guide must cover API token setup, browser install link setup, IDE/terminal integration install paths, Desktop app observer permission, troubleshooting/privacy/uninstall notice access, and diagnostics"
fi

if [[ ! -f "${ROOT_DIR}/docs/macos-troubleshooting-guide.txt" ]]; then
  fail "docs/macos-troubleshooting-guide.txt is required for the bundled troubleshooting guide"
elif rg -q "Daemon offline" "${ROOT_DIR}/docs/macos-troubleshooting-guide.txt" &&
     rg -q "HTTP 401" "${ROOT_DIR}/docs/macos-troubleshooting-guide.txt" &&
     rg -q "Browser extension does not report tabs" "${ROOT_DIR}/docs/macos-troubleshooting-guide.txt" &&
     rg -q "IDE tasks do not appear" "${ROOT_DIR}/docs/macos-troubleshooting-guide.txt" &&
     rg -q "AI Monitor: Send Test Event" "${ROOT_DIR}/docs/macos-troubleshooting-guide.txt" &&
     rg -q "Open AI Monitor Settings" "${ROOT_DIR}/docs/macos-troubleshooting-guide.txt" &&
     rg -q "ai-monitor://settings" "${ROOT_DIR}/docs/macos-troubleshooting-guide.txt" &&
     rg -q "Terminal tasks do not appear" "${ROOT_DIR}/docs/macos-troubleshooting-guide.txt" &&
     rg -q "Copy diagnostics" "${ROOT_DIR}/docs/macos-troubleshooting-guide.txt"; then
  pass "bundled troubleshooting guide source present"
else
  fail "troubleshooting guide must cover daemon offline, auth, browser extension Settings recovery, terminal integration, and diagnostics recovery"
fi

if [[ ! -f "${ROOT_DIR}/docs/macos-privacy-notice.txt" ]]; then
  fail "docs/macos-privacy-notice.txt is required for the DMG privacy notice"
elif rg -q "local-first by default" "${ROOT_DIR}/docs/macos-privacy-notice.txt" &&
     rg -q "External notification providers are not configured or enabled by default" "${ROOT_DIR}/docs/macos-privacy-notice.txt" &&
     rg -q "Desktop app observer is optional" "${ROOT_DIR}/docs/macos-privacy-notice.txt" &&
     rg -q "browser install link" "${ROOT_DIR}/docs/macos-privacy-notice.txt"; then
  pass "privacy notice source present"
else
  fail "privacy notice must cover local-first defaults, unconfigured external providers, optional Desktop app observer, and browser install-link actions"
fi

if [[ ! -f "${ROOT_DIR}/docs/macos-uninstall-guide.txt" ]]; then
  fail "docs/macos-uninstall-guide.txt is required for the bundled uninstall guide"
elif rg -q "Remove login daemon" "${ROOT_DIR}/docs/macos-uninstall-guide.txt" &&
     rg -q "Delete /Applications/AI Monitor.app" "${ROOT_DIR}/docs/macos-uninstall-guide.txt" &&
     rg -q "Copy diagnostics" "${ROOT_DIR}/docs/macos-uninstall-guide.txt"; then
  pass "bundled uninstall guide source present"
else
  fail "uninstall guide must cover login daemon removal, app deletion, and diagnostics"
fi

if [[ ! -f "${ROOT_DIR}/apps/desktop-macos/Assets/AI-Monitor-Logo.png" ]]; then
  fail "app icon source is required for ordinary-user Finder and Dock presentation"
elif [[ ! -f "${ROOT_DIR}/apps/desktop-macos/Assets/AI-Monitor-MenuBar-Logo.png" ]]; then
  fail "menu bar logo source is required"
elif [[ ! -f "${ROOT_DIR}/apps/desktop-macos/Assets/WebIcons/chatgpt-web.png" ||
        ! -f "${ROOT_DIR}/apps/desktop-macos/Assets/WebIcons/claude-web.png" ||
        ! -f "${ROOT_DIR}/apps/desktop-macos/Assets/WebIcons/gemini-web.png" ||
        ! -f "${ROOT_DIR}/apps/desktop-macos/Assets/WebIcons/grok-web.png" ||
        ! -f "${ROOT_DIR}/apps/desktop-macos/Assets/WebIcons/perplexity-web.png" ||
        ! -f "${ROOT_DIR}/apps/desktop-macos/Assets/WebIcons/github-web.png" ]]; then
  fail "bundled web source icons are required"
else
  pass "app and web icon sources present"
fi

require_executable "${ROOT_DIR}/scripts/build_macos_app.sh" "app build script"
require_executable "${ROOT_DIR}/scripts/package_macos_app.sh" "package script"
require_executable "${ROOT_DIR}/scripts/generate_third_party_notices.sh" "third-party notices generator"
require_executable "${ROOT_DIR}/scripts/verify_macos_release.sh" "release verifier"
require_executable "${ROOT_DIR}/scripts/release_macos_app.sh" "public release script"
require_executable "${ROOT_DIR}/scripts/init_macos_release_env.sh" "release env initializer"
require_executable "${ROOT_DIR}/scripts/stage_public_release.sh" "public release staging script"
require_executable "${ROOT_DIR}/scripts/install_macos_launch_agent.sh" "LaunchAgent install script"
require_executable "${ROOT_DIR}/scripts/uninstall_macos_app.sh" "uninstall script"

if rg -q "https://example.com/ai-monitor-webhook" "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift"; then
  fail "macOS Settings provider setup must not show example.com webhook placeholders to ordinary users"
fi

if rg -q "isSettingsDeepLink" "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" &&
   rg -q "showSettings()" "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" &&
   rg -q "Open AI Monitor Settings" "${ROOT_DIR}/integrations/browser-extension/chrome/popup.html" &&
   rg -q "openAIMonitorSettings" "${ROOT_DIR}/integrations/browser-extension/chrome/popup.js" &&
   rg -q "ai-monitor://settings" "${ROOT_DIR}/integrations/browser-extension/chrome/popup.js"; then
  pass "browser extension Settings recovery path configured"
else
  fail "browser extension popup must be able to open AI Monitor Settings through ai-monitor://settings"
fi

if rg -q "quit_running_app" "${ROOT_DIR}/scripts/uninstall_macos_app.sh" &&
   rg -q "/usr/bin/osascript" "${ROOT_DIR}/scripts/uninstall_macos_app.sh" &&
   rg -q "ask a running AI Monitor app to quit" "${ROOT_DIR}/docs/macos-uninstall-guide.txt" &&
   rg -q "asks a running AI Monitor app to quit" "${ROOT_DIR}/docs/macos-dmg-readme.txt"; then
  pass "uninstall command quits running app before cleanup"
else
  fail "uninstall command must ask a running AI Monitor app to quit before removing files"
fi

if rg -q "aiMonitor.sendTestEvent" "${ROOT_DIR}/integrations/ide/vscode/package.json" &&
   rg -q "aiMonitor.openDesktopSettings" "${ROOT_DIR}/integrations/ide/vscode/package.json" &&
   rg -q "ai-monitor://settings" "${ROOT_DIR}/integrations/ide/vscode/extension.js" &&
   rg -q "VS Code/Cursor extension recovery command" "${ROOT_DIR}/docs/deeplink-router.md" &&
   rg -q "AI Monitor: Send Test Event" "${ROOT_DIR}/integrations/ide/vscode/README.md"; then
  pass "IDE extension first-run test and Settings recovery commands configured"
else
  fail "IDE extension must expose first-run test and Settings recovery commands"
fi

if [[ -z "${BUNDLE_ID}" || "${BUNDLE_ID}" == local.* ]] || is_placeholder_bundle_id "${BUNDLE_ID}"; then
  fail "set AI_MONITOR_BUNDLE_ID to a real public reverse-DNS bundle identifier, not local.*, example.*, or yourcompany placeholders"
else
  pass "release bundle identifier configured: ${BUNDLE_ID}"
  pass "release login daemon label will be: $(release_launch_agent_label)"
fi

if [[ "${APP_VERSION}" =~ ^[0-9]+([.][0-9]+){1,2}([.-][A-Za-z0-9]+)?$ ]]; then
  pass "app version configured: ${APP_VERSION}"
else
  fail "AI_MONITOR_APP_VERSION must be a valid CFBundleShortVersionString"
fi

if [[ "${APP_BUILD}" =~ ^[0-9]+([.][0-9]+)*$ ]]; then
  pass "app build configured: ${APP_BUILD}"
else
  fail "AI_MONITOR_APP_BUILD must be a valid CFBundleVersion"
fi

if [[ "${MIN_MACOS_VERSION}" =~ ^[0-9]+([.][0-9]+){1,2}$ ]]; then
  pass "minimum macOS version configured: ${MIN_MACOS_VERSION}"
else
  fail "AI_MONITOR_MACOS_MIN_VERSION must be a macOS version like 13.0"
fi

if has_arch arm64 && has_arch x86_64; then
  pass "release macOS architectures configured: ${MACOS_ARCHS_RAW}"
else
  fail "set AI_MONITOR_MACOS_ARCHS to include both arm64 and x86_64 for public release"
fi

installed_rust_targets="$(rustup target list --installed 2>/dev/null || true)"
for arch in "${MACOS_ARCHS[@]}"; do
  if rust_target="$(rust_target_for_arch "${arch}")"; then
    if printf '%s\n' "${installed_rust_targets}" | rg -Fxq "${rust_target}"; then
      pass "Rust target installed for ${arch}: ${rust_target}"
    else
      fail "install Rust target for ${arch}: rustup target add ${rust_target}"
    fi
  else
    fail "unsupported macOS architecture in AI_MONITOR_MACOS_ARCHS: ${arch}"
  fi
done

if is_placeholder_copyright "${COPYRIGHT}"; then
  fail "set AI_MONITOR_COPYRIGHT with real publisher wording, not development/local/example placeholders"
else
  pass "release copyright configured"
fi

if [[ -z "${BROWSER_EXTENSION_INSTALL_URL}" ]]; then
  fail "set AI_MONITOR_BROWSER_EXTENSION_INSTALL_URL to the Chrome Web Store listing or managed-extension install instructions URL"
elif [[ ! "${BROWSER_EXTENSION_INSTALL_URL}" =~ ^https://[^[:space:]]+$ ]] || is_placeholder_url "${BROWSER_EXTENSION_INSTALL_URL}"; then
  fail "AI_MONITOR_BROWSER_EXTENSION_INSTALL_URL must be a real HTTPS URL, not a local/example placeholder"
else
  pass "browser extension install URL configured"
fi

if [[ -z "${BROWSER_EXTENSION_PRIVACY_POLICY_URL}" ]]; then
  fail "set AI_MONITOR_BROWSER_EXTENSION_PRIVACY_POLICY_URL to the public HTTPS privacy policy URL used in the Chrome Web Store listing"
elif [[ ! "${BROWSER_EXTENSION_PRIVACY_POLICY_URL}" =~ ^https://[^[:space:]]+$ ]] || is_placeholder_url "${BROWSER_EXTENSION_PRIVACY_POLICY_URL}"; then
  fail "AI_MONITOR_BROWSER_EXTENSION_PRIVACY_POLICY_URL must be a real HTTPS URL, not a local/example placeholder"
else
  pass "browser extension privacy policy URL configured"
fi

identity_output="$(security find-identity -v -p codesigning 2>/dev/null || true)"
developer_id_lines="$(printf '%s\n' "${identity_output}" | rg 'Developer ID Application:' || true)"

if [[ -n "${IDENTITY}" ]]; then
  if ! printf '%s\n' "${IDENTITY}" | rg -q '^Developer ID Application:'; then
    fail "AI_MONITOR_CODESIGN_IDENTITY must be a Developer ID Application identity"
  elif printf '%s\n' "${identity_output}" | rg -Fq "${IDENTITY}"; then
    pass "Developer ID identity found: ${IDENTITY}"
  else
    fail "AI_MONITOR_CODESIGN_IDENTITY was not found in the login keychain"
  fi
elif [[ -n "${developer_id_lines}" ]]; then
  warn "Developer ID Application identity available, but AI_MONITOR_CODESIGN_IDENTITY is not set"
  printf '%s\n' "${developer_id_lines}" | sed 's/^/  /'
  fail "set AI_MONITOR_CODESIGN_IDENTITY to the exact Developer ID Application identity before release packaging"
else
  fail "install a Developer ID Application certificate and set AI_MONITOR_CODESIGN_IDENTITY"
fi

if xcrun notarytool --help >/dev/null 2>&1; then
  pass "notarytool available"
else
  fail "xcrun notarytool is required"
fi

if xcrun --find stapler >/dev/null 2>&1; then
  pass "stapler available"
else
  fail "xcrun stapler is required"
fi

if [[ -n "${NOTARY_PROFILE}" ]]; then
  pass "AI_MONITOR_NOTARY_PROFILE is set"
  if [[ "${CHECK_NOTARY_ONLINE}" == "1" ]]; then
    if xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" --limit 1 >/dev/null 2>&1; then
      pass "notary profile accepted by notarytool"
    else
      fail "notary profile was not accepted by notarytool"
    fi
  else
    warn "set AI_MONITOR_CHECK_NOTARY_ONLINE=1 to verify the notary profile with Apple"
  fi
elif [[ -n "${APPLE_ID}" && -n "${APPLE_PASSWORD}" && -n "${APPLE_TEAM_ID}" ]]; then
  pass "Apple ID notary credential environment variables are set"
  warn "prefer AI_MONITOR_NOTARY_PROFILE for repeatable local releases"
  if [[ "${CHECK_NOTARY_ONLINE}" == "1" ]]; then
    if xcrun notarytool history \
      --apple-id "${APPLE_ID}" \
      --password "${APPLE_PASSWORD}" \
      --team-id "${APPLE_TEAM_ID}" \
      --limit 1 >/dev/null 2>&1; then
      pass "Apple ID notary credentials accepted by notarytool"
    else
      fail "Apple ID notary credentials were not accepted by notarytool"
    fi
  else
    warn "set AI_MONITOR_CHECK_NOTARY_ONLINE=1 to verify Apple ID notary credentials with Apple"
  fi
else
  fail "set AI_MONITOR_NOTARY_PROFILE or AI_MONITOR_NOTARY_APPLE_ID/PASSWORD/TEAM_ID"
fi

if [[ "${SKIP_NOTARIZE}" == "1" ]]; then
  fail "AI_MONITOR_SKIP_NOTARIZE must not be 1 for a public macOS release"
fi

if [[ "${SKIP_CODESIGN}" == "1" ]]; then
  fail "AI_MONITOR_SKIP_CODESIGN must not be 1 for a public macOS release"
fi

if [[ "${FAILURES}" -eq 0 ]]; then
  echo "macOS release prerequisites satisfied"
  exit 0
fi

echo "macOS release prerequisites missing: ${FAILURES}" >&2
echo "Run scripts/init_macos_release_env.sh, replace placeholders in .env.release.local with real publisher/signing/notary/browser-extension values, source it, then rerun this check." >&2
exit 1
