#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export AI_MONITOR_REPO_ROOT="${ROOT_DIR}"
swift "${ROOT_DIR}/apps/desktop-macos/FloatingMonitor.swift"
