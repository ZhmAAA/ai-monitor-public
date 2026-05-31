#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_PATH="${1:-${ROOT_DIR}/target/THIRD-PARTY-NOTICES.txt}"
MACOS_ARCHS_RAW="${AI_MONITOR_MACOS_ARCHS:-$(uname -m)}"
read -r -a MACOS_ARCHS <<< "${MACOS_ARCHS_RAW}"

rust_target_for_arch() {
  case "$1" in
    arm64)
      printf "%s\n" "aarch64-apple-darwin"
      ;;
    x86_64)
      printf "%s\n" "x86_64-apple-darwin"
      ;;
    *)
      echo "Unsupported macOS architecture for notices: $1" >&2
      exit 2
      ;;
  esac
}

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ai-monitor-notices.XXXXXX")"
trap 'rm -rf "${tmp_dir}"' EXIT

tree_files=()
for arch in "${MACOS_ARCHS[@]}"; do
  rust_target="$(rust_target_for_arch "${arch}")"
  tree_file="${tmp_dir}/cargo-tree-${arch}.txt"
  cargo tree \
    --manifest-path "${ROOT_DIR}/Cargo.toml" \
    -p ai-monitor-daemon \
    --target "${rust_target}" \
    --edges normal \
    --prefix none \
    --offline \
    > "${tree_file}"
  tree_files+=("${tree_file}")
done

mkdir -p "$(dirname "${OUTPUT_PATH}")"

ROOT_DIR="${ROOT_DIR}" \
OUTPUT_PATH="${OUTPUT_PATH}" \
TREE_FILES="$(IFS=:; printf '%s' "${tree_files[*]}")" \
node <<'NODE'
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const rootDir = process.env.ROOT_DIR;
const outputPath = process.env.OUTPUT_PATH;
const treeFiles = process.env.TREE_FILES.split(":").filter(Boolean);
const registrySrcRoot = path.join(os.homedir(), ".cargo", "registry", "src");
const workspacePackages = new Set([
  "ai-monitor-daemon",
  "ai-monitor-notification-engine",
  "ai-monitor-protocol",
  "ai-monitor-storage",
]);

function parseTomlString(text, key) {
  const patterns = [
    new RegExp(`^${key}\\s*=\\s*"([^"]+)"\\s*$`, "m"),
    new RegExp(`^${key}\\s*=\\s*'([^']+)'\\s*$`, "m"),
  ];
  for (const pattern of patterns) {
    const match = text.match(pattern);
    if (match) return match[1];
  }
  return "";
}

function readPackageJsonLicense(packageJsonPath) {
  const json = JSON.parse(fs.readFileSync(packageJsonPath, "utf8"));
  return {
    name: json.name,
    version: json.version,
    license: typeof json.license === "string" ? json.license : "UNKNOWN",
  };
}

function cargoPackageDir(name, version) {
  if (!fs.existsSync(registrySrcRoot)) return null;
  for (const registryDir of fs.readdirSync(registrySrcRoot)) {
    const candidate = path.join(registrySrcRoot, registryDir, `${name}-${version}`);
    if (fs.existsSync(candidate)) return candidate;
  }
  return null;
}

function cargoPackageLicense(name, version) {
  if (workspacePackages.has(name)) return "MIT";
  const packageDir = cargoPackageDir(name, version);
  if (!packageDir) return "UNKNOWN";
  for (const manifestName of ["Cargo.toml.orig", "Cargo.toml"]) {
    const manifestPath = path.join(packageDir, manifestName);
    if (!fs.existsSync(manifestPath)) continue;
    const text = fs.readFileSync(manifestPath, "utf8");
    const license = parseTomlString(text, "license");
    if (license) return license;
    const licenseFile = parseTomlString(text, "license-file");
    if (licenseFile) return `license file: ${licenseFile}`;
  }
  return "UNKNOWN";
}

const packages = new Map();
for (const treeFile of treeFiles) {
  const text = fs.readFileSync(treeFile, "utf8");
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();
    const match = line.match(/^([A-Za-z0-9_.-]+) v([0-9A-Za-z+_.-]+)/);
    if (!match) continue;
    const [, name, version] = match;
    packages.set(`${name}@${version}`, { name, version });
  }
}

const cargoRows = Array.from(packages.values())
  .sort((a, b) => a.name.localeCompare(b.name) || a.version.localeCompare(b.version))
  .map((pkg) => ({ ...pkg, license: cargoPackageLicense(pkg.name, pkg.version) }));

const unknown = cargoRows.filter((pkg) => pkg.license === "UNKNOWN");
if (unknown.length > 0) {
  console.error(`Unable to resolve license metadata for: ${unknown.map((pkg) => `${pkg.name} ${pkg.version}`).join(", ")}`);
  console.error("Build the target once or inspect upstream metadata before publishing.");
  process.exit(2);
}

const idePackage = readPackageJsonLicense(path.join(rootDir, "integrations", "ide", "vscode", "package.json"));
const lines = [
  "AI Monitor third-party notices",
  "",
  "AI Monitor is distributed under the MIT License. See LICENSE.txt.",
  "",
  "Rust crates included in the bundled daemon build:",
  "",
  ...cargoRows.map((pkg) => `- ${pkg.name} ${pkg.version}: ${pkg.license}`),
  "",
  "Packaged extension and adapter components:",
  "",
  `- ${idePackage.name} ${idePackage.version}: ${idePackage.license}`,
  "- AI Monitor Chrome extension files: MIT",
  "- AI Monitor terminal integration scripts: MIT",
  "- AI Monitor macOS Swift app source: MIT",
  "",
  "System frameworks and user-installed tools:",
  "",
  "- macOS Cocoa, ApplicationServices, Security, and UserNotifications frameworks are provided by Apple with macOS.",
  "- Optional terminal integrations require a user-installed Node.js runtime; Node.js is not bundled in the AI Monitor DMG.",
  "- Optional clickable daemon notifications use terminal-notifier only when the user has installed it separately; it is not bundled in the AI Monitor DMG.",
  "",
  "This notice is generated from Cargo.lock, local Cargo registry metadata, and packaged extension metadata during macOS packaging.",
  "",
];

fs.writeFileSync(outputPath, lines.join("\n"));
NODE

echo "Generated third-party notices: ${OUTPUT_PATH}"
