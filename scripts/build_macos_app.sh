#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${AI_MONITOR_APP_NAME:-AI Monitor}"
BUNDLE_ID="${AI_MONITOR_BUNDLE_ID:-local.ai-monitor.desktop}"
APP_VERSION="${AI_MONITOR_APP_VERSION:-0.1.0}"
APP_BUILD="${AI_MONITOR_APP_BUILD:-1}"
COPYRIGHT="${AI_MONITOR_COPYRIGHT:-AI Monitor development build}"
BROWSER_EXTENSION_INSTALL_URL="${AI_MONITOR_BROWSER_EXTENSION_INSTALL_URL:-}"
MIN_MACOS_VERSION="${AI_MONITOR_MACOS_MIN_VERSION:-13.0}"
REQUIRE_NOTARIZATION="${AI_MONITOR_REQUIRE_NOTARIZATION:-${AI_MONITOR_RELEASE:-0}}"
if [[ "${REQUIRE_NOTARIZATION}" == "1" ]]; then
  DEFAULT_MACOS_ARCHS="arm64 x86_64"
else
  DEFAULT_MACOS_ARCHS="$(uname -m)"
fi
MACOS_ARCHS_RAW="${AI_MONITOR_MACOS_ARCHS:-${DEFAULT_MACOS_ARCHS}}"
BUILD_DIR="${AI_MONITOR_APP_BUILD_DIR:-${ROOT_DIR}/target/macos-app}"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
EXECUTABLE_NAME="AI Monitor"
INFO_PLIST="${CONTENTS_DIR}/Info.plist"
ICON_SOURCE="${ROOT_DIR}/apps/desktop-macos/Assets/AI-Monitor-Logo.png"
ICON_BASENAME="AI-Monitor"
ICONSET_DIR="${BUILD_DIR}/${ICON_BASENAME}.iconset"
LOGO_RESOURCE_NAME="AI-Monitor-Logo.png"
MENU_BAR_LOGO_SOURCE="${ROOT_DIR}/apps/desktop-macos/Assets/AI-Monitor-MenuBar-Logo.png"
MENU_BAR_LOGO_RESOURCE_NAME="AI-Monitor-MenuBar-Logo.png"
WEB_ICONS_SOURCE_DIR="${ROOT_DIR}/apps/desktop-macos/Assets/WebIcons"
WEB_ICONS_RESOURCE_DIR="${RESOURCES_DIR}/WebIcons"
LICENSE_SOURCE="${ROOT_DIR}/LICENSE"
LICENSE_RESOURCE_NAME="LICENSE.txt"
THIRD_PARTY_NOTICES_SCRIPT="${ROOT_DIR}/scripts/generate_third_party_notices.sh"
THIRD_PARTY_NOTICES_RESOURCE_NAME="THIRD-PARTY-NOTICES.txt"
SETUP_GUIDE_SOURCE="${ROOT_DIR}/docs/macos-app-setup-guide.txt"
SETUP_GUIDE_RESOURCE_NAME="first-run-guide.txt"
BROWSER_EXTENSION_INSTALL_URL_RESOURCE_NAME="browser-extension-install-url.txt"
PRIVACY_NOTICE_SOURCE="${ROOT_DIR}/docs/macos-privacy-notice.txt"
PRIVACY_NOTICE_RESOURCE_NAME="privacy-notice.txt"
UNINSTALL_GUIDE_SOURCE="${ROOT_DIR}/docs/macos-uninstall-guide.txt"
UNINSTALL_GUIDE_RESOURCE_NAME="uninstall-guide.txt"
TROUBLESHOOTING_GUIDE_SOURCE="${ROOT_DIR}/docs/macos-troubleshooting-guide.txt"
TROUBLESHOOTING_GUIDE_RESOURCE_NAME="troubleshooting-guide.txt"

read -r -a MACOS_ARCHS <<< "${MACOS_ARCHS_RAW}"

is_placeholder_bundle_id() {
  [[ "$1" =~ (^|[.])(example|yourcompany|your-company)([.]|$) ]]
}

is_placeholder_copyright() {
  [[ "$1" =~ development|Development|Local|[Ee]xample|TODO|Your[[:space:]]+Company ]]
}

is_placeholder_url() {
  [[ "$1" =~ example|yourcompany|your-company|localhost|127[.]0[.]0[.]1 ]]
}

launch_agent_label_for_bundle_id() {
  if [[ "$1" == local.* ]]; then
    printf "%s\n" "local.ai-monitor.daemon"
  else
    printf "%s.daemon\n" "$1"
  fi
}

render_uninstall_guide() {
  local source="$1"
  local destination="$2"
  local launch_agent_label
  launch_agent_label="$(launch_agent_label_for_bundle_id "${BUNDLE_ID}")"

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line//<bundle-id>/${BUNDLE_ID}}"
    line="${line//<launch-agent-label>/${launch_agent_label}}"
    printf '%s\n' "${line}"
  done < "${source}" > "${destination}"
}

render_setup_guide() {
  local source="$1"
  local destination="$2"
  local browser_extension_install_url
  browser_extension_install_url="${BROWSER_EXTENSION_INSTALL_URL:-the browser extension install URL listed in your release channel}"

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line//<browser-extension-install-url>/${browser_extension_install_url}}"
    printf '%s\n' "${line}"
  done < "${source}" > "${destination}"
}

write_browser_extension_install_url_resource() {
  local destination="$1"
  printf '%s\n' "${BROWSER_EXTENSION_INSTALL_URL}" > "${destination}"
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
      echo "Unsupported macOS architecture: $1. Use arm64 and/or x86_64." >&2
      exit 2
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

if [[ "${REQUIRE_NOTARIZATION}" == "1" ]]; then
  if [[ -z "${AI_MONITOR_BUNDLE_ID:-}" || "${BUNDLE_ID}" == local.* ]] || is_placeholder_bundle_id "${BUNDLE_ID}"; then
    echo "Release builds require AI_MONITOR_BUNDLE_ID with a real public reverse-DNS bundle identifier, not local.*, example.*, or yourcompany placeholders." >&2
    exit 2
  fi
  if is_placeholder_copyright "${COPYRIGHT}"; then
    echo "Release builds require AI_MONITOR_COPYRIGHT with real publisher wording, not development/local/example placeholders." >&2
    exit 2
  fi
  if [[ -z "${BROWSER_EXTENSION_INSTALL_URL}" ]]; then
    echo "Release builds require AI_MONITOR_BROWSER_EXTENSION_INSTALL_URL with the Chrome Web Store listing or managed-extension install instructions URL." >&2
    exit 2
  fi
  if [[ ! "${BROWSER_EXTENSION_INSTALL_URL}" =~ ^https://[^[:space:]]+$ ]] || is_placeholder_url "${BROWSER_EXTENSION_INSTALL_URL}"; then
    echo "Release builds require AI_MONITOR_BROWSER_EXTENSION_INSTALL_URL to be a real HTTPS URL, not a local/example placeholder." >&2
    exit 2
  fi
  if ! has_arch arm64 || ! has_arch x86_64; then
    echo "Release builds require a universal macOS app: set AI_MONITOR_MACOS_ARCHS=\"arm64 x86_64\"." >&2
    exit 2
  fi
fi

if [[ ! -f "${SETUP_GUIDE_SOURCE}" ]]; then
  echo "Missing first-run setup guide source: ${SETUP_GUIDE_SOURCE}" >&2
  exit 2
fi

if [[ ! -f "${LICENSE_SOURCE}" ]]; then
  echo "Missing license file: ${LICENSE_SOURCE}" >&2
  exit 2
fi

if [[ ! -x "${THIRD_PARTY_NOTICES_SCRIPT}" ]]; then
  echo "Missing executable third-party notices generator: ${THIRD_PARTY_NOTICES_SCRIPT}" >&2
  exit 2
fi

if [[ ! -f "${PRIVACY_NOTICE_SOURCE}" ]]; then
  echo "Missing privacy notice source: ${PRIVACY_NOTICE_SOURCE}" >&2
  exit 2
fi

if [[ ! -f "${UNINSTALL_GUIDE_SOURCE}" ]]; then
  echo "Missing uninstall guide source: ${UNINSTALL_GUIDE_SOURCE}" >&2
  exit 2
fi

if [[ ! -f "${TROUBLESHOOTING_GUIDE_SOURCE}" ]]; then
  echo "Missing troubleshooting guide source: ${TROUBLESHOOTING_GUIDE_SOURCE}" >&2
  exit 2
fi

if [[ ! -f "${ICON_SOURCE}" ]]; then
  echo "Missing app icon source: ${ICON_SOURCE}" >&2
  exit 2
fi

if [[ ! -f "${MENU_BAR_LOGO_SOURCE}" ]]; then
  echo "Missing menu bar logo source: ${MENU_BAR_LOGO_SOURCE}" >&2
  exit 2
fi

if [[ ! -d "${WEB_ICONS_SOURCE_DIR}" ]]; then
  echo "Missing web icon source directory: ${WEB_ICONS_SOURCE_DIR}" >&2
  exit 2
fi

for required_web_icon in chatgpt-web claude-web gemini-web grok-web perplexity-web github-web; do
  if [[ ! -f "${WEB_ICONS_SOURCE_DIR}/${required_web_icon}.png" ]]; then
    echo "Missing bundled web icon source: ${WEB_ICONS_SOURCE_DIR}/${required_web_icon}.png" >&2
    exit 2
  fi
done

if [[ ! "${MIN_MACOS_VERSION}" =~ ^[0-9]+([.][0-9]+){1,2}$ ]]; then
  echo "AI_MONITOR_MACOS_MIN_VERSION must be a macOS version like 13.0." >&2
  exit 2
fi

if [[ "${#MACOS_ARCHS[@]}" -eq 0 ]]; then
  echo "AI_MONITOR_MACOS_ARCHS must include at least one architecture." >&2
  exit 2
fi

installed_rust_targets="$(rustup target list --installed 2>/dev/null || true)"
for arch in "${MACOS_ARCHS[@]}"; do
  rust_target="$(rust_target_for_arch "${arch}")"
  if ! printf '%s\n' "${installed_rust_targets}" | rg -Fxq "${rust_target}"; then
    echo "Missing Rust target for ${arch}: run rustup target add ${rust_target}" >&2
    exit 2
  fi
done

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

export MACOSX_DEPLOYMENT_TARGET="${MIN_MACOS_VERSION}"
swift_outputs=()
daemon_outputs=()
for arch in "${MACOS_ARCHS[@]}"; do
  rust_target="$(rust_target_for_arch "${arch}")"
  swift_output="${BUILD_DIR}/${EXECUTABLE_NAME}.${arch}"

  cargo build --release -p ai-monitor-daemon --target "${rust_target}"
  daemon_outputs+=("${ROOT_DIR}/target/${rust_target}/release/ai-monitor-daemon")

  swiftc "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift" \
    -target "${arch}-apple-macosx${MIN_MACOS_VERSION}" \
    -o "${swift_output}" \
    -framework Cocoa \
    -framework ApplicationServices \
    -framework Security \
    -framework UserNotifications
  swift_outputs+=("${swift_output}")
done

if [[ "${#swift_outputs[@]}" -eq 1 ]]; then
  cp "${swift_outputs[0]}" "${MACOS_DIR}/${EXECUTABLE_NAME}"
else
  /usr/bin/lipo -create "${swift_outputs[@]}" -output "${MACOS_DIR}/${EXECUTABLE_NAME}"
fi

if [[ "${#daemon_outputs[@]}" -eq 1 ]]; then
  cp "${daemon_outputs[0]}" "${RESOURCES_DIR}/ai-monitor-daemon"
else
  /usr/bin/lipo -create "${daemon_outputs[@]}" -output "${RESOURCES_DIR}/ai-monitor-daemon"
fi
chmod 755 "${MACOS_DIR}/${EXECUTABLE_NAME}"
chmod 755 "${RESOURCES_DIR}/ai-monitor-daemon"
cp "${ROOT_DIR}/config/default.toml" "${RESOURCES_DIR}/default.toml"
cp "${LICENSE_SOURCE}" "${RESOURCES_DIR}/${LICENSE_RESOURCE_NAME}"
render_setup_guide "${SETUP_GUIDE_SOURCE}" "${RESOURCES_DIR}/${SETUP_GUIDE_RESOURCE_NAME}"
write_browser_extension_install_url_resource "${RESOURCES_DIR}/${BROWSER_EXTENSION_INSTALL_URL_RESOURCE_NAME}"
cp "${PRIVACY_NOTICE_SOURCE}" "${RESOURCES_DIR}/${PRIVACY_NOTICE_RESOURCE_NAME}"
render_uninstall_guide "${UNINSTALL_GUIDE_SOURCE}" "${RESOURCES_DIR}/${UNINSTALL_GUIDE_RESOURCE_NAME}"
cp "${TROUBLESHOOTING_GUIDE_SOURCE}" "${RESOURCES_DIR}/${TROUBLESHOOTING_GUIDE_RESOURCE_NAME}"
AI_MONITOR_MACOS_ARCHS="${MACOS_ARCHS_RAW}" "${THIRD_PARTY_NOTICES_SCRIPT}" "${RESOURCES_DIR}/${THIRD_PARTY_NOTICES_RESOURCE_NAME}"

cp "${ICON_SOURCE}" "${RESOURCES_DIR}/${LOGO_RESOURCE_NAME}"
rm -rf "${ICONSET_DIR}"
mkdir -p "${ICONSET_DIR}"
sips -z 16 16 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_16x16.png" >/dev/null
sips -z 32 32 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_32x32.png" >/dev/null
sips -z 64 64 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_128x128.png" >/dev/null
sips -z 256 256 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_256x256.png" >/dev/null
sips -z 512 512 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_512x512.png" >/dev/null
sips -z 1024 1024 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_512x512@2x.png" >/dev/null
iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_DIR}/${ICON_BASENAME}.icns"

cp "${MENU_BAR_LOGO_SOURCE}" "${RESOURCES_DIR}/${MENU_BAR_LOGO_RESOURCE_NAME}"

mkdir -p "${WEB_ICONS_RESOURCE_DIR}"
for icon_file in "${WEB_ICONS_SOURCE_DIR}"/*.png; do
  cp "${icon_file}" "${WEB_ICONS_RESOURCE_DIR}/"
done

xattr -cr "${APP_DIR}" 2>/dev/null || true

cat > "${INFO_PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleExecutable</key>
  <string>${EXECUTABLE_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleIconFile</key>
  <string>${ICON_BASENAME}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${APP_BUILD}</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>AI Monitor Task Links</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>ai-monitor</string>
      </array>
    </dict>
  </array>
  <key>LSUIElement</key>
  <true/>
  <key>LSMinimumSystemVersion</key>
  <string>${MIN_MACOS_VERSION}</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.productivity</string>
  <key>NSAppleEventsUsageDescription</key>
	  <string>AI Monitor uses Apple Events to bring your browser or terminal window to the front when you click a monitored task.</string>
	  <key>NSHumanReadableCopyright</key>
	  <string>${COPYRIGHT}</string>
	</dict>
</plist>
PLIST

/usr/bin/plutil -lint "${INFO_PLIST}" >/dev/null
touch "${APP_DIR}"

echo "Built ${APP_DIR}"
echo "Open it with: open \"${APP_DIR}\""
