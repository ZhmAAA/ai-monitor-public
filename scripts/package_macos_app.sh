#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${AI_MONITOR_APP_NAME:-AI Monitor}"
BUILD_DIR="${AI_MONITOR_APP_BUILD_DIR:-${ROOT_DIR}/target/macos-app}"
DIST_DIR="${AI_MONITOR_DIST_DIR:-${ROOT_DIR}/target/macos-dist}"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
ZIP_PATH="${DIST_DIR}/${APP_NAME}.zip"
DMG_PATH="${DIST_DIR}/${APP_NAME}.dmg"
DMG_STAGING_DIR="${DIST_DIR}/dmg-staging"
DMG_README_SRC="${AI_MONITOR_DMG_README_SRC:-${ROOT_DIR}/docs/macos-dmg-readme.txt}"
DMG_LICENSE_SRC="${AI_MONITOR_DMG_LICENSE_SRC:-${APP_DIR}/Contents/Resources/LICENSE.txt}"
DMG_THIRD_PARTY_NOTICES_SRC="${AI_MONITOR_DMG_THIRD_PARTY_NOTICES_SRC:-${APP_DIR}/Contents/Resources/THIRD-PARTY-NOTICES.txt}"
DMG_PRIVACY_SRC="${AI_MONITOR_DMG_PRIVACY_SRC:-${ROOT_DIR}/docs/macos-privacy-notice.txt}"
DMG_UNINSTALL_SRC="${AI_MONITOR_DMG_UNINSTALL_SRC:-${APP_DIR}/Contents/Resources/uninstall-guide.txt}"
DMG_TROUBLESHOOTING_SRC="${AI_MONITOR_DMG_TROUBLESHOOTING_SRC:-${APP_DIR}/Contents/Resources/troubleshooting-guide.txt}"
UNINSTALL_SCRIPT_SRC="${AI_MONITOR_UNINSTALL_SCRIPT_SRC:-${ROOT_DIR}/scripts/uninstall_macos_app.sh}"
BROWSER_EXTENSION_SRC="${AI_MONITOR_BROWSER_EXTENSION_SRC:-${ROOT_DIR}/integrations/browser-extension/chrome}"
BROWSER_EXTENSION_ZIP_PATH="${DIST_DIR}/${APP_NAME} Browser Extension.zip"
BROWSER_EXTENSION_INSTALL_URL="${AI_MONITOR_BROWSER_EXTENSION_INSTALL_URL:-}"
BROWSER_EXTENSION_PRIVACY_POLICY_URL="${AI_MONITOR_BROWSER_EXTENSION_PRIVACY_POLICY_URL:-}"
IDE_EXTENSION_SRC="${AI_MONITOR_IDE_EXTENSION_SRC:-${ROOT_DIR}/integrations/ide/vscode}"
IDE_EXTENSION_ZIP_PATH="${DIST_DIR}/${APP_NAME} IDE Extension.zip"
IDE_EXTENSION_VSIX_PATH="${DIST_DIR}/${APP_NAME} IDE Extension.vsix"
IDE_EXTENSION_VSIX_STAGING_DIR="${DIST_DIR}/ide-vsix-staging"
TERMINAL_INTEGRATIONS_ZIP_PATH="${DIST_DIR}/${APP_NAME} Terminal Integrations.zip"
TERMINAL_INTEGRATIONS_STAGING_DIR="${DIST_DIR}/terminal-integrations-staging"
CHECKSUMS_PATH="${DIST_DIR}/SHA256SUMS.txt"
RELEASE_MANIFEST_PATH="${DIST_DIR}/RELEASE_MANIFEST.json"
ENTITLEMENTS_PATH="${AI_MONITOR_ENTITLEMENTS:-${ROOT_DIR}/apps/desktop-macos/AI-Monitor.entitlements}"
IDENTITY="${AI_MONITOR_CODESIGN_IDENTITY:--}"
NOTARY_PROFILE="${AI_MONITOR_NOTARY_PROFILE:-}"
APPLE_ID="${AI_MONITOR_NOTARY_APPLE_ID:-}"
APPLE_PASSWORD="${AI_MONITOR_NOTARY_PASSWORD:-}"
APPLE_TEAM_ID="${AI_MONITOR_NOTARY_TEAM_ID:-}"
SKIP_NOTARIZE="${AI_MONITOR_SKIP_NOTARIZE:-0}"
SKIP_CODESIGN="${AI_MONITOR_SKIP_CODESIGN:-0}"
REQUIRE_NOTARIZATION="${AI_MONITOR_REQUIRE_NOTARIZATION:-${AI_MONITOR_RELEASE:-0}}"
APP_NOTARY_ZIP=""

cleanup() {
  if [[ -n "${APP_NOTARY_ZIP}" ]]; then
    rm -f "${APP_NOTARY_ZIP}"
  fi
  rm -rf "${IDE_EXTENSION_VSIX_STAGING_DIR}" "${TERMINAL_INTEGRATIONS_STAGING_DIR}"
}
trap cleanup EXIT

notarization_configured() {
  [[ -n "${NOTARY_PROFILE}" || ( -n "${APPLE_ID}" && -n "${APPLE_PASSWORD}" && -n "${APPLE_TEAM_ID}" ) ]]
}

submit_notarization() {
  local artifact_path="$1"

  if [[ -n "${NOTARY_PROFILE}" ]]; then
    xcrun notarytool submit "${artifact_path}" \
      --keychain-profile "${NOTARY_PROFILE}" \
      --wait
  else
    xcrun notarytool submit "${artifact_path}" \
      --apple-id "${APPLE_ID}" \
      --password "${APPLE_PASSWORD}" \
      --team-id "${APPLE_TEAM_ID}" \
      --wait
  fi
}

plist_value() {
  local key="$1"
  /usr/bin/plutil -extract "${key}" raw -o - "${APP_DIR}/Contents/Info.plist"
}

launch_agent_label_for_bundle_id() {
  if [[ "$1" == local.* ]]; then
    printf "%s\n" "local.ai-monitor.daemon"
  else
    printf "%s.daemon\n" "$1"
  fi
}

is_placeholder_url() {
  [[ "$1" =~ example|yourcompany|your-company|localhost|127[.]0[.]0[.]1 ]]
}

render_dmg_text_template() {
  local source="$1"
  local destination="$2"
  local bundle_id launch_agent_label browser_extension_install_url
  bundle_id="$(plist_value CFBundleIdentifier)"
  launch_agent_label="$(launch_agent_label_for_bundle_id "${bundle_id}")"
  browser_extension_install_url="${BROWSER_EXTENSION_INSTALL_URL:-the Chrome Web Store or managed extension link from your release channel}"

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line//<bundle-id>/${bundle_id}}"
    line="${line//<launch-agent-label>/${launch_agent_label}}"
    line="${line//<browser-extension-install-url>/${browser_extension_install_url}}"
    printf '%s\n' "${line}"
  done < "${source}" > "${destination}"
}

write_dmg_uninstall_command() {
  local destination="$1"
  local bundle_id launch_agent_label app_name_shell bundle_id_shell launch_agent_label_shell
  bundle_id="$(plist_value CFBundleIdentifier)"
  launch_agent_label="$(launch_agent_label_for_bundle_id "${bundle_id}")"
  app_name_shell="$(printf '%q' "${APP_NAME}")"
  bundle_id_shell="$(printf '%q' "${bundle_id}")"
  launch_agent_label_shell="$(printf '%q' "${launch_agent_label}")"

  {
    cat <<COMMAND
#!/usr/bin/env bash
set -euo pipefail

export AI_MONITOR_APP_NAME=${app_name_shell}
export AI_MONITOR_BUNDLE_ID=${bundle_id_shell}
export AI_MONITOR_LAUNCH_AGENT_LABEL=${launch_agent_label_shell}

if [[ \$# -eq 0 ]]; then
  cat <<'INTRO'
AI Monitor uninstall cleanup

This command can remove AI Monitor.app, the login daemon, preferences, local history, token files, and logs for this packaged build.
It will preview the cleanup first. Nothing is removed unless you type DELETE.

INTRO
  "\$0" --dry-run
  if [[ ! -t 0 ]]; then
    echo
    echo "No interactive terminal is available, so no changes were made."
    echo "Run this command from Terminal with --yes if you intentionally want full cleanup."
    exit 0
  fi
  echo
  printf 'Type DELETE to remove the paths above, or press Return to cancel: '
  read -r confirmation
  if [[ "\${confirmation}" != "DELETE" ]]; then
    echo "Canceled. No changes were made."
    exit 0
  fi
  set -- --yes
fi

COMMAND
    sed '1,2d' "${UNINSTALL_SCRIPT_SRC}"
  } > "${destination}"
  chmod 755 "${destination}"
}

write_terminal_root_install_command() {
  local destination="$1"
  cat > "${destination}" <<'COMMAND'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/integrations/terminal/install-terminal-integrations.command" "$@"
COMMAND
  chmod 755 "${destination}"
}

if [[ "${REQUIRE_NOTARIZATION}" == "1" ]]; then
  if [[ -z "${BROWSER_EXTENSION_INSTALL_URL}" ]]; then
    echo "Release packaging requires AI_MONITOR_BROWSER_EXTENSION_INSTALL_URL with the Chrome Web Store listing or managed-extension install instructions URL." >&2
    exit 2
  fi
  if [[ ! "${BROWSER_EXTENSION_INSTALL_URL}" =~ ^https://[^[:space:]]+$ ]] || is_placeholder_url "${BROWSER_EXTENSION_INSTALL_URL}"; then
    echo "Release packaging requires AI_MONITOR_BROWSER_EXTENSION_INSTALL_URL to be a real HTTPS URL, not a local/example placeholder." >&2
    exit 2
  fi
  if [[ -z "${BROWSER_EXTENSION_PRIVACY_POLICY_URL}" ]]; then
    echo "Release packaging requires AI_MONITOR_BROWSER_EXTENSION_PRIVACY_POLICY_URL with the public HTTPS privacy policy URL used in the Chrome Web Store listing." >&2
    exit 2
  fi
  if [[ ! "${BROWSER_EXTENSION_PRIVACY_POLICY_URL}" =~ ^https://[^[:space:]]+$ ]] || is_placeholder_url "${BROWSER_EXTENSION_PRIVACY_POLICY_URL}"; then
    echo "Release packaging requires AI_MONITOR_BROWSER_EXTENSION_PRIVACY_POLICY_URL to be a real HTTPS URL, not a local/example placeholder." >&2
    exit 2
  fi
  if [[ "${IDENTITY}" == "-" ]]; then
    echo "Release packaging requires AI_MONITOR_CODESIGN_IDENTITY with a Developer ID Application certificate." >&2
    exit 2
  fi
  if [[ "${SKIP_NOTARIZE}" == "1" ]]; then
    echo "Release packaging cannot skip notarization." >&2
    exit 2
  fi
  if [[ "${SKIP_CODESIGN}" == "1" ]]; then
    echo "Release packaging cannot skip codesigning." >&2
    exit 2
  fi
  if [[ -z "${NOTARY_PROFILE}" && ( -z "${APPLE_ID}" || -z "${APPLE_PASSWORD}" || -z "${APPLE_TEAM_ID}" ) ]]; then
    echo "Release packaging requires AI_MONITOR_NOTARY_PROFILE or Apple ID notary credentials." >&2
    exit 2
  fi
fi

"${ROOT_DIR}/scripts/build_macos_app.sh"
mkdir -p "${DIST_DIR}"
xattr -cr "${APP_DIR}" 2>/dev/null || true

if [[ "${SKIP_CODESIGN}" != "1" ]]; then
  if [[ ! -f "${ENTITLEMENTS_PATH}" ]]; then
    echo "Missing entitlements file: ${ENTITLEMENTS_PATH}" >&2
    exit 2
  fi
  if ! /usr/bin/plutil -convert json -o - "${ENTITLEMENTS_PATH}" | node -e '
const fs = require("node:fs");
const key = "com.apple.security.automation.apple-events";
const entitlements = JSON.parse(fs.readFileSync(0, "utf8"));
if (entitlements[key] !== true) process.exit(1);
'; then
    echo "Entitlements must enable com.apple.security.automation.apple-events for browser and terminal activation." >&2
    exit 2
  fi

  daemon_codesign_args=(
    --force
    --options runtime
    --sign "${IDENTITY}"
  )
  if [[ "${IDENTITY}" != "-" ]]; then
    daemon_codesign_args+=(--timestamp)
  fi
  /usr/bin/codesign "${daemon_codesign_args[@]}" "${APP_DIR}/Contents/Resources/ai-monitor-daemon"
  /usr/bin/codesign --verify --strict --verbose=2 "${APP_DIR}/Contents/Resources/ai-monitor-daemon"

  app_codesign_args=(
    --force
    --deep
    --entitlements "${ENTITLEMENTS_PATH}"
    --options runtime
    --sign "${IDENTITY}"
  )
  if [[ "${IDENTITY}" != "-" ]]; then
    app_codesign_args+=(--timestamp)
  fi
  /usr/bin/codesign "${app_codesign_args[@]}" "${APP_DIR}"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "${APP_DIR}"
fi

if [[ "${SKIP_NOTARIZE}" != "1" && "${IDENTITY}" != "-" ]]; then
  if notarization_configured; then
    APP_NOTARY_ZIP="$(mktemp "${TMPDIR:-/tmp}/ai-monitor-app-notary.XXXXXX")"
    rm -f "${APP_NOTARY_ZIP}"
    APP_NOTARY_ZIP="${APP_NOTARY_ZIP}.zip"
    /usr/bin/ditto -c -k --keepParent "${APP_DIR}" "${APP_NOTARY_ZIP}"
    submit_notarization "${APP_NOTARY_ZIP}"
    rm -f "${APP_NOTARY_ZIP}"
    APP_NOTARY_ZIP=""
    xcrun stapler staple "${APP_DIR}"
    xcrun stapler validate "${APP_DIR}"
    /usr/sbin/spctl --assess --type execute --verbose "${APP_DIR}"
  else
    echo "Notarization skipped: set AI_MONITOR_NOTARY_PROFILE or Apple ID credentials." >&2
  fi
elif [[ "${REQUIRE_NOTARIZATION}" == "1" ]]; then
  echo "Release packaging failed: app notarization did not run." >&2
  exit 2
fi

rm -f "${BROWSER_EXTENSION_ZIP_PATH}"
(
  cd "${BROWSER_EXTENSION_SRC}"
  COPYFILE_DISABLE=1 /usr/bin/zip -qry "${BROWSER_EXTENSION_ZIP_PATH}" \
    manifest.json \
    background.js \
    content.js \
    popup.css \
    popup.html \
    popup.js \
    open-tab.html \
    open-tab.js \
    icons/icon-16.png \
    icons/icon-32.png \
    icons/icon-48.png \
    icons/icon-128.png
)

rm -rf "${TERMINAL_INTEGRATIONS_STAGING_DIR}" "${TERMINAL_INTEGRATIONS_ZIP_PATH}"
mkdir -p \
  "${TERMINAL_INTEGRATIONS_STAGING_DIR}/integrations/terminal/claude-code" \
  "${TERMINAL_INTEGRATIONS_STAGING_DIR}/integrations/terminal/codex-cli" \
  "${TERMINAL_INTEGRATIONS_STAGING_DIR}/integrations/terminal/shell" \
  "${TERMINAL_INTEGRATIONS_STAGING_DIR}/integrations/superset" \
  "${TERMINAL_INTEGRATIONS_STAGING_DIR}/docs"
write_terminal_root_install_command "${TERMINAL_INTEGRATIONS_STAGING_DIR}/Install AI Monitor Terminal Integrations.command"
cp "${ROOT_DIR}/integrations/terminal/README.md" "${TERMINAL_INTEGRATIONS_STAGING_DIR}/integrations/terminal/README.md"
cp "${ROOT_DIR}/integrations/terminal/ai-monitor-terminal.js" "${TERMINAL_INTEGRATIONS_STAGING_DIR}/integrations/terminal/ai-monitor-terminal.js"
cp "${ROOT_DIR}/integrations/terminal/install-terminal-integrations.command" "${TERMINAL_INTEGRATIONS_STAGING_DIR}/integrations/terminal/install-terminal-integrations.command"
cp "${ROOT_DIR}/integrations/terminal/install-official-hooks.js" "${TERMINAL_INTEGRATIONS_STAGING_DIR}/integrations/terminal/install-official-hooks.js"
cp "${ROOT_DIR}/integrations/terminal/install-packaged-integrations.js" "${TERMINAL_INTEGRATIONS_STAGING_DIR}/integrations/terminal/install-packaged-integrations.js"
cp "${ROOT_DIR}/integrations/terminal/claude-code/hook.sh" "${TERMINAL_INTEGRATIONS_STAGING_DIR}/integrations/terminal/claude-code/hook.sh"
cp "${ROOT_DIR}/integrations/terminal/claude-code/official-hook.sh" "${TERMINAL_INTEGRATIONS_STAGING_DIR}/integrations/terminal/claude-code/official-hook.sh"
cp "${ROOT_DIR}/integrations/terminal/codex-cli/hook.sh" "${TERMINAL_INTEGRATIONS_STAGING_DIR}/integrations/terminal/codex-cli/hook.sh"
cp "${ROOT_DIR}/integrations/terminal/codex-cli/official-hook.sh" "${TERMINAL_INTEGRATIONS_STAGING_DIR}/integrations/terminal/codex-cli/official-hook.sh"
cp "${ROOT_DIR}/integrations/terminal/shell/ai-monitor.sh" "${TERMINAL_INTEGRATIONS_STAGING_DIR}/integrations/terminal/shell/ai-monitor.sh"
cp "${ROOT_DIR}/integrations/superset/ai-monitor-superset-hook.js" "${TERMINAL_INTEGRATIONS_STAGING_DIR}/integrations/superset/ai-monitor-superset-hook.js"
cp "${ROOT_DIR}/integrations/superset/install-ai-monitor-hook.js" "${TERMINAL_INTEGRATIONS_STAGING_DIR}/integrations/superset/install-ai-monitor-hook.js"
cp "${ROOT_DIR}/docs/integrations.md" "${TERMINAL_INTEGRATIONS_STAGING_DIR}/docs/integrations.md"
(
  cd "${TERMINAL_INTEGRATIONS_STAGING_DIR}"
  COPYFILE_DISABLE=1 /usr/bin/zip -qry "${TERMINAL_INTEGRATIONS_ZIP_PATH}" \
    "Install AI Monitor Terminal Integrations.command" \
    integrations/terminal/README.md \
    integrations/terminal/ai-monitor-terminal.js \
    integrations/terminal/install-terminal-integrations.command \
    integrations/terminal/install-official-hooks.js \
    integrations/terminal/install-packaged-integrations.js \
    integrations/terminal/claude-code/hook.sh \
    integrations/terminal/claude-code/official-hook.sh \
    integrations/terminal/codex-cli/hook.sh \
    integrations/terminal/codex-cli/official-hook.sh \
    integrations/terminal/shell/ai-monitor.sh \
    integrations/superset/ai-monitor-superset-hook.js \
    integrations/superset/install-ai-monitor-hook.js \
    docs/integrations.md
)

rm -f "${IDE_EXTENSION_ZIP_PATH}"
(
  cd "${IDE_EXTENSION_SRC}"
  COPYFILE_DISABLE=1 /usr/bin/zip -qry "${IDE_EXTENSION_ZIP_PATH}" \
    package.json \
    extension.js \
    README.md
)

rm -rf "${IDE_EXTENSION_VSIX_STAGING_DIR}" "${IDE_EXTENSION_VSIX_PATH}"
mkdir -p "${IDE_EXTENSION_VSIX_STAGING_DIR}/extension"
cp "${IDE_EXTENSION_SRC}/package.json" "${IDE_EXTENSION_VSIX_STAGING_DIR}/extension/package.json"
cp "${IDE_EXTENSION_SRC}/extension.js" "${IDE_EXTENSION_VSIX_STAGING_DIR}/extension/extension.js"
cp "${IDE_EXTENSION_SRC}/README.md" "${IDE_EXTENSION_VSIX_STAGING_DIR}/extension/README.md"
IDE_EXTENSION_PACKAGE="${IDE_EXTENSION_SRC}/package.json" \
IDE_EXTENSION_VSIX_STAGING_DIR="${IDE_EXTENSION_VSIX_STAGING_DIR}" \
node <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const pkg = JSON.parse(fs.readFileSync(process.env.IDE_EXTENSION_PACKAGE, "utf8"));
const stagingDir = process.env.IDE_EXTENSION_VSIX_STAGING_DIR;

function escapeXml(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

const contentTypes = `<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="json" ContentType="application/json"/>
  <Default Extension="js" ContentType="application/javascript"/>
  <Default Extension="md" ContentType="text/markdown"/>
  <Default Extension="vsixmanifest" ContentType="text/xml"/>
</Types>
`;

const manifest = `<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
  <Metadata>
    <Identity Language="en-US" Id="${escapeXml(pkg.name)}" Version="${escapeXml(pkg.version)}" Publisher="${escapeXml(pkg.publisher)}"/>
    <DisplayName>${escapeXml(pkg.displayName || pkg.name)}</DisplayName>
    <Description xml:space="preserve">${escapeXml(pkg.description || pkg.displayName || pkg.name)}</Description>
    <Categories>${escapeXml((pkg.categories || ["Other"]).join(","))}</Categories>
  </Metadata>
  <Installation>
    <InstallationTarget Id="Microsoft.VisualStudio.Code"/>
  </Installation>
  <Dependencies/>
  <Assets>
    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/>
  </Assets>
</PackageManifest>
`;

fs.writeFileSync(path.join(stagingDir, "[Content_Types].xml"), contentTypes);
fs.writeFileSync(path.join(stagingDir, "extension.vsixmanifest"), manifest);
NODE
(
  cd "${IDE_EXTENSION_VSIX_STAGING_DIR}"
  COPYFILE_DISABLE=1 /usr/bin/zip -qry "${IDE_EXTENSION_VSIX_PATH}" \
    '[Content_Types].xml' \
    extension.vsixmanifest \
    extension/package.json \
    extension/extension.js \
    extension/README.md
)
rm -rf "${IDE_EXTENSION_VSIX_STAGING_DIR}"

rm -f "${ZIP_PATH}"
(
  cd "${BUILD_DIR}"
  COPYFILE_DISABLE=1 /usr/bin/zip -qry --symlinks "${ZIP_PATH}" "${APP_NAME}.app"
)

rm -rf "${DMG_STAGING_DIR}" "${DMG_PATH}"
mkdir -p "${DMG_STAGING_DIR}"
cp -R "${APP_DIR}" "${DMG_STAGING_DIR}/"
render_dmg_text_template "${DMG_README_SRC}" "${DMG_STAGING_DIR}/README.txt"
cp "${DMG_LICENSE_SRC}" "${DMG_STAGING_DIR}/LICENSE.txt"
cp "${DMG_THIRD_PARTY_NOTICES_SRC}" "${DMG_STAGING_DIR}/THIRD-PARTY-NOTICES.txt"
cp "${DMG_PRIVACY_SRC}" "${DMG_STAGING_DIR}/PRIVACY.txt"
cp "${DMG_UNINSTALL_SRC}" "${DMG_STAGING_DIR}/UNINSTALL.txt"
cp "${DMG_TROUBLESHOOTING_SRC}" "${DMG_STAGING_DIR}/TROUBLESHOOTING.txt"
write_dmg_uninstall_command "${DMG_STAGING_DIR}/UNINSTALL.command"
ln -s /Applications "${DMG_STAGING_DIR}/Applications"
xattr -cr "${DMG_STAGING_DIR}" 2>/dev/null || true
/usr/bin/hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${DMG_STAGING_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}" >/dev/null
rm -rf "${DMG_STAGING_DIR}"

if [[ "${SKIP_NOTARIZE}" != "1" && "${IDENTITY}" != "-" ]]; then
  if notarization_configured; then
    submit_notarization "${DMG_PATH}"
    xcrun stapler staple "${DMG_PATH}"
    xcrun stapler validate "${DMG_PATH}"
    /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose "${DMG_PATH}"
  else
    echo "Notarization skipped: set AI_MONITOR_NOTARY_PROFILE or Apple ID credentials." >&2
  fi
elif [[ "${REQUIRE_NOTARIZATION}" == "1" ]]; then
  echo "Release packaging failed: DMG notarization did not run." >&2
  exit 2
fi

(
  cd "${DIST_DIR}"
  /usr/bin/shasum -a 256 \
    "${APP_NAME}.dmg" \
    "${APP_NAME}.zip" \
    "${APP_NAME} Browser Extension.zip" \
    "${APP_NAME} IDE Extension.zip" \
    "${APP_NAME} IDE Extension.vsix" \
    "${APP_NAME} Terminal Integrations.zip" \
    > "${CHECKSUMS_PATH}"
)

APP_NAME="${APP_NAME}" \
APP_INFO_PLIST="${APP_DIR}/Contents/Info.plist" \
APP_EXECUTABLE="${APP_DIR}/Contents/MacOS/${APP_NAME}" \
DAEMON_EXECUTABLE="${APP_DIR}/Contents/Resources/ai-monitor-daemon" \
BROWSER_EXTENSION_MANIFEST="${BROWSER_EXTENSION_SRC}/manifest.json" \
IDE_EXTENSION_PACKAGE="${IDE_EXTENSION_SRC}/package.json" \
DIST_DIR="${DIST_DIR}" \
CHECKSUMS_PATH="${CHECKSUMS_PATH}" \
RELEASE_MANIFEST_PATH="${RELEASE_MANIFEST_PATH}" \
REQUIRE_NOTARIZATION="${REQUIRE_NOTARIZATION}" \
AI_MONITOR_CODESIGN_IDENTITY="${IDENTITY}" \
AI_MONITOR_SKIP_CODESIGN="${SKIP_CODESIGN}" \
AI_MONITOR_BROWSER_EXTENSION_INSTALL_URL="${BROWSER_EXTENSION_INSTALL_URL}" \
AI_MONITOR_BROWSER_EXTENSION_PRIVACY_POLICY_URL="${BROWSER_EXTENSION_PRIVACY_POLICY_URL}" \
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

function machoArchitectures(binaryPath) {
  return execFileSync("/usr/bin/lipo", ["-archs", binaryPath], { encoding: "utf8" })
    .trim()
    .split(/\s+/)
    .filter(Boolean)
    .sort();
}

const distDir = process.env.DIST_DIR;
const checksumRows = fs.readFileSync(process.env.CHECKSUMS_PATH, "utf8")
  .trim()
  .split(/\n+/)
  .map((line) => {
    const match = line.match(/^([0-9a-f]{64})\s{2}(.+)$/);
    if (!match) throw new Error(`invalid checksum line: ${line}`);
    return { sha256: match[1], file: match[2] };
  });

const browserManifest = JSON.parse(fs.readFileSync(process.env.BROWSER_EXTENSION_MANIFEST, "utf8"));
const ideExtensionPackage = JSON.parse(fs.readFileSync(process.env.IDE_EXTENSION_PACKAGE, "utf8"));
const identity = process.env.AI_MONITOR_CODESIGN_IDENTITY || "-";
const releaseMode = process.env.REQUIRE_NOTARIZATION === "1";
const codesignSkipped = process.env.AI_MONITOR_SKIP_CODESIGN === "1";
const bundleIdentifier = plistValue("CFBundleIdentifier");
const appName = process.env.APP_NAME;
const appVersion = plistValue("CFBundleShortVersionString");
const appBuild = plistValue("CFBundleVersion");
const minimumMacosVersion = plistValue("LSMinimumSystemVersion");
const applicationCategory = plistValue("LSApplicationCategoryType");
const browserExtensionInstallUrl = (process.env.AI_MONITOR_BROWSER_EXTENSION_INSTALL_URL || "").trim();
const browserExtensionPrivacyPolicyUrl = (process.env.AI_MONITOR_BROWSER_EXTENSION_PRIVACY_POLICY_URL || "").trim();
const artifactRoles = {
  [`${appName}.dmg`]: {
    role: "public_macos_installer",
    audience: "ordinary_users",
    publish: true,
    version: appVersion,
    build: appBuild,
    usage: "Open the DMG, read README.txt, drag the app to Applications, and open it from Applications.",
  },
  [`${appName}.zip`]: {
    role: "app_archive",
    audience: "automation_and_internal_deployment",
    publish: false,
    version: appVersion,
    build: appBuild,
    usage: "Automation-only app archive; do not use as the ordinary-user public installer.",
  },
  [`${appName} Browser Extension.zip`]: {
    role: "browser_extension_package",
    audience: "chrome_web_store_or_managed_rollout",
    publish: false,
    version: browserManifest.version,
    usage: "Use for Chrome Web Store submission or managed internal browser rollout.",
  },
  [`${appName} IDE Extension.zip`]: {
    role: "ide_extension_unpacked_folder",
    audience: "vscode_cursor_fallback",
    publish: true,
    version: ideExtensionPackage.version,
    usage: "Optional unpacked-folder fallback when VSIX install is unavailable.",
  },
  [`${appName} IDE Extension.vsix`]: {
    role: "ide_extension_vsix",
    audience: "vscode_cursor_users",
    publish: true,
    version: ideExtensionPackage.version,
    usage: "Recommended VS Code/Cursor offline installer.",
  },
  [`${appName} Terminal Integrations.zip`]: {
    role: "terminal_integrations_package",
    audience: "terminal_agent_users",
    publish: true,
    version: appVersion,
    usage: "Optional Claude Code, Codex CLI, shell command, and Superset terminal integrations; double-click the root Install AI Monitor Terminal Integrations.command for guided setup.",
  },
};

const artifacts = checksumRows.map(({ sha256, file }) => {
  const role = artifactRoles[file];
  if (!role) throw new Error(`missing release manifest artifact role for ${file}`);
  return {
    file,
    ...role,
    bytes: fs.statSync(path.join(distDir, file)).size,
    sha256,
  };
});

const manifest = {
  schema_version: 1,
  generated_at: new Date().toISOString(),
  app_name: appName,
  bundle_identifier: bundleIdentifier,
  launch_agent_label: launchAgentLabel(bundleIdentifier),
  app_version: appVersion,
  app_build: appBuild,
  minimum_macos_version: minimumMacosVersion,
  application_category: applicationCategory,
  architectures: {
    app: machoArchitectures(process.env.APP_EXECUTABLE),
    daemon: machoArchitectures(process.env.DAEMON_EXECUTABLE),
  },
  browser_extension_version: browserManifest.version,
  browser_extension_install_url: browserExtensionInstallUrl || null,
  browser_extension_privacy_policy_url: browserExtensionPrivacyPolicyUrl || null,
  ide_extension_version: ideExtensionPackage.version,
  release_mode: releaseMode,
  codesign_identity: identity === "-" ? "ad-hoc" : identity,
  signing: {
    identity: identity === "-" ? "ad-hoc" : identity,
    developer_id: /^Developer ID Application:/.test(identity),
    ad_hoc: identity === "-" && !codesignSkipped,
    skipped: codesignSkipped,
    hardened_runtime: !codesignSkipped,
    apple_events_entitlement: !codesignSkipped,
  },
  notarization: {
    required: releaseMode,
    submitted: releaseMode,
    stapled_ticket_validated: releaseMode,
    app_submitted: releaseMode,
    app_stapled_ticket_validated: releaseMode,
    app_gatekeeper_execute_assessed: releaseMode,
    dmg_submitted: releaseMode,
    dmg_stapled_ticket_validated: releaseMode,
    dmg_gatekeeper_open_assessed: releaseMode,
    mounted_app_stapled_ticket_validated: releaseMode,
    mounted_app_gatekeeper_execute_assessed: releaseMode,
    mounted_app_gatekeeper_execute_assessment_required: releaseMode,
  },
  distribution: {
    public_macos_installer: `${appName}.dmg`,
    app_zip_usage: "automation_only_not_public_installer",
    browser_extension_usage: "store_or_managed_rollout",
    browser_extension_install_url: browserExtensionInstallUrl || null,
    browser_extension_privacy_policy_url: browserExtensionPrivacyPolicyUrl || null,
    ide_extension_usage: "recommended_vsix_installer",
    ide_extension_folder_zip_usage: "optional_unpacked_install",
    terminal_integrations_usage: "optional_user_installer",
    publish_with_release: [
      `${appName}.dmg`,
      `${appName} IDE Extension.vsix`,
      `${appName} IDE Extension.zip`,
      `${appName} Terminal Integrations.zip`,
      "SHA256SUMS.txt",
      "RELEASE_MANIFEST.json",
    ],
  },
  dmg_contents: {
    root_entries: [
      `${appName}.app`,
      "Applications",
      "README.txt",
      "LICENSE.txt",
      "THIRD-PARTY-NOTICES.txt",
      "PRIVACY.txt",
      "UNINSTALL.txt",
      "TROUBLESHOOTING.txt",
      "UNINSTALL.command",
    ],
    support_files: {
      readme: "README.txt",
      license: "LICENSE.txt",
      third_party_notices: "THIRD-PARTY-NOTICES.txt",
      privacy_notice: "PRIVACY.txt",
      uninstall_guide: "UNINSTALL.txt",
      troubleshooting_guide: "TROUBLESHOOTING.txt",
      uninstall_command: {
        file: "UNINSTALL.command",
        behavior: "preview_then_requires_confirmation",
        confirmation_phrase: "DELETE",
      },
    },
  },
  entitlements: {
    "com.apple.security.automation.apple-events": true,
  },
  artifacts,
};

fs.writeFileSync(process.env.RELEASE_MANIFEST_PATH, `${JSON.stringify(manifest, null, 2)}\n`);
NODE

(
  cd "${DIST_DIR}"
  /usr/bin/shasum -a 256 "$(basename "${RELEASE_MANIFEST_PATH}")" >> "${CHECKSUMS_PATH}"
)

echo "Packaged ${APP_DIR}"
echo "Archive: ${ZIP_PATH}"
echo "Disk image: ${DMG_PATH}"
echo "Browser extension: ${BROWSER_EXTENSION_ZIP_PATH}"
echo "IDE extension: ${IDE_EXTENSION_ZIP_PATH}"
echo "IDE extension VSIX: ${IDE_EXTENSION_VSIX_PATH}"
echo "Terminal integrations: ${TERMINAL_INTEGRATIONS_ZIP_PATH}"
echo "Checksums: ${CHECKSUMS_PATH}"
echo "Release manifest: ${RELEASE_MANIFEST_PATH}"
