#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_ONLY=0

usage() {
  cat <<USAGE
Usage: $0 [--check-only]

Runs the full macOS public release pipeline:
  1. Check release prerequisites.
  2. Build, sign, notarize, and staple the app bundle and DMG.
  3. Verify release artifacts in release mode.
  4. Stage the public upload set from RELEASE_MANIFEST.json.

Required environment includes:
  AI_MONITOR_BUNDLE_ID
  AI_MONITOR_COPYRIGHT
  AI_MONITOR_BROWSER_EXTENSION_INSTALL_URL
  AI_MONITOR_BROWSER_EXTENSION_PRIVACY_POLICY_URL
  AI_MONITOR_CODESIGN_IDENTITY
  AI_MONITOR_NOTARY_PROFILE
    or AI_MONITOR_NOTARY_APPLE_ID / AI_MONITOR_NOTARY_PASSWORD / AI_MONITOR_NOTARY_TEAM_ID

Optional environment:
  AI_MONITOR_APP_VERSION
  AI_MONITOR_APP_BUILD
  AI_MONITOR_MACOS_MIN_VERSION
  AI_MONITOR_MACOS_ARCHS

Run scripts/init_macos_release_env.sh and source the private ignored
.env.release.local before running this script.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only)
      CHECK_ONLY=1
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

export AI_MONITOR_RELEASE=1
export AI_MONITOR_REQUIRE_NOTARIZATION=1
export AI_MONITOR_CHECK_NOTARY_ONLINE="${AI_MONITOR_CHECK_NOTARY_ONLINE:-1}"
export AI_MONITOR_MACOS_ARCHS="${AI_MONITOR_MACOS_ARCHS:-arm64 x86_64}"

"${ROOT_DIR}/scripts/check_macos_release_prereqs.sh"

if [[ "${CHECK_ONLY}" == "1" ]]; then
  echo "macOS release check completed."
  exit 0
fi

"${ROOT_DIR}/scripts/package_macos_app.sh"
AI_MONITOR_RELEASE=1 \
AI_MONITOR_REQUIRE_NOTARIZATION=1 \
"${ROOT_DIR}/scripts/verify_macos_release.sh"
"${ROOT_DIR}/scripts/stage_public_release.sh"

echo "macOS public release upload set is ready in target/macos-public-release."
