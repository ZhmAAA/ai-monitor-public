#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBLIC_DIR="${AI_MONITOR_PUBLIC_RELEASE_DIR:-${ROOT_DIR}/target/macos-public-release}"
export AI_MONITOR_MACOS_ARCHS="${AI_MONITOR_MACOS_ARCHS:-arm64 x86_64}"

usage() {
  cat <<USAGE
Usage: $0

Builds, verifies, and stages a private macOS test download set.

This is for invited testers who expect a development build. It does not require Developer ID signing or Apple notarization, so macOS may show unidentified developer or security prompts. Use scripts/release_macos_app.sh for an ordinary public release.

By default, the private test build is universal for Apple Silicon and Intel
Macs. Override AI_MONITOR_MACOS_ARCHS only when you intentionally want a
single-architecture local test package.
USAGE
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  "")
    ;;
  *)
    echo "Unknown option: $1" >&2
    usage >&2
    exit 2
    ;;
esac

"${ROOT_DIR}/scripts/package_macos_app.sh"
"${ROOT_DIR}/scripts/verify_macos_release.sh"
AI_MONITOR_ALLOW_DEV_PUBLIC_STAGE=1 "${ROOT_DIR}/scripts/stage_public_release.sh"

cat <<SUMMARY

Private test download set is ready:
  ${PUBLIC_DIR}

Send these files only to testers who expect a development build.
Do not publish this directory as the ordinary-user release.
For public download, use scripts/release_macos_app.sh after Developer ID signing,
Apple notarization, and the browser extension install URL are configured.
SUMMARY
