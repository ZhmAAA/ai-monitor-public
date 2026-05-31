#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${AI_MONITOR_DIST_DIR:-${ROOT_DIR}/target/macos-dist}"
PUBLIC_DIR="${AI_MONITOR_PUBLIC_RELEASE_DIR:-${ROOT_DIR}/target/macos-public-release}"
CHECKSUMS_PATH="${DIST_DIR}/SHA256SUMS.txt"
RELEASE_MANIFEST_PATH="${DIST_DIR}/RELEASE_MANIFEST.json"

fail() {
  echo "$1" >&2
  exit 2
}

canonical_child_path() {
  local input_path="$1"
  local parent_path
  local parent_real
  local child_name

  if [[ -z "${input_path}" || "${input_path}" == "/" ]]; then
    fail "Public release directory is unsafe: ${input_path}"
  fi

  parent_path="$(dirname "${input_path}")"
  child_name="$(basename "${input_path}")"
  if [[ -z "${child_name}" || "${child_name}" == "." || "${child_name}" == ".." ]]; then
    fail "Public release directory is unsafe: ${input_path}"
  fi

  if ! parent_real="$(cd "${parent_path}" 2>/dev/null && pwd -P)"; then
    fail "Public release parent directory does not exist: ${parent_path}"
  fi

  printf '%s/%s\n' "${parent_real}" "${child_name}"
}

stage_label() {
  if [[ "${AI_MONITOR_ALLOW_DEV_PUBLIC_STAGE:-0}" == "1" ]]; then
    printf '%s\n' "development preview release files"
  else
    printf '%s\n' "public release files"
  fi
}

if [[ ! -f "${CHECKSUMS_PATH}" ]]; then
  fail "Missing checksum manifest: ${CHECKSUMS_PATH}"
fi

if [[ ! -f "${RELEASE_MANIFEST_PATH}" ]]; then
  fail "Missing release manifest: ${RELEASE_MANIFEST_PATH}"
fi

ROOT_REAL="$(cd "${ROOT_DIR}" && pwd -P)"
DIST_REAL="$(cd "${DIST_DIR}" && pwd -P)"
PUBLIC_DIR="$(canonical_child_path "${PUBLIC_DIR}")"

case "${PUBLIC_DIR}" in
  "${ROOT_REAL}/target/"*)
    ;;
  *)
    fail "Public release directory must be under ${ROOT_REAL}/target: ${PUBLIC_DIR}"
    ;;
esac

case "${PUBLIC_DIR}" in
  "${DIST_REAL}"|"${DIST_REAL}/"*)
    fail "Public release directory must not be the distribution directory or one of its children: ${PUBLIC_DIR}"
    ;;
esac

case "${DIST_REAL}" in
  "${PUBLIC_DIR}/"*)
    fail "Public release directory must not contain the distribution directory: ${PUBLIC_DIR}"
    ;;
esac

(
  cd "${DIST_DIR}"
  /usr/bin/shasum -a 256 -c "$(basename "${CHECKSUMS_PATH}")" >/dev/null
)

DIST_DIR="${DIST_DIR}" \
PUBLIC_DIR="${PUBLIC_DIR}" \
RELEASE_MANIFEST_PATH="${RELEASE_MANIFEST_PATH}" \
CHECKSUMS_PATH="${CHECKSUMS_PATH}" \
AI_MONITOR_ALLOW_DEV_PUBLIC_STAGE="${AI_MONITOR_ALLOW_DEV_PUBLIC_STAGE:-0}" \
node <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");

function die(message) {
  console.error(message);
  process.exit(2);
}

const distDir = process.env.DIST_DIR;
const publicDir = process.env.PUBLIC_DIR;
const manifest = JSON.parse(fs.readFileSync(process.env.RELEASE_MANIFEST_PATH, "utf8"));
const allowDevelopmentPreview = process.env.AI_MONITOR_ALLOW_DEV_PUBLIC_STAGE === "1";
if (manifest.release_mode !== true && !allowDevelopmentPreview) {
  die(
    "RELEASE_MANIFEST.json is not from AI_MONITOR_RELEASE=1; refusing to stage public release files. " +
    "Run scripts/release_macos_app.sh for a real public release, or set AI_MONITOR_ALLOW_DEV_PUBLIC_STAGE=1 only for local staging previews."
  );
}

fs.rmSync(publicDir, { recursive: true, force: true });
fs.mkdirSync(publicDir, { recursive: true });

const publishFiles = manifest.distribution?.publish_with_release;
if (!Array.isArray(publishFiles) || publishFiles.length === 0) {
  die("RELEASE_MANIFEST.json is missing distribution.publish_with_release");
}

const checksumRows = new Map(fs.readFileSync(process.env.CHECKSUMS_PATH, "utf8")
  .trim()
  .split(/\n+/)
  .map((line) => {
    const match = line.match(/^([0-9a-f]{64})\s{2}(.+)$/);
    if (!match) die(`invalid checksum line: ${line}`);
    return [match[2], match[1]];
  }));

const artifacts = new Map((manifest.artifacts || []).map((artifact) => [artifact.file, artifact]));
const copied = [];
for (const file of publishFiles) {
  if (file.includes("/") || file.includes("\\")) {
    die(`publish file must be a root-level artifact: ${file}`);
  }
  if (file === "SHA256SUMS.txt") {
    continue;
  }
  const source = path.join(distDir, file);
  const destination = path.join(publicDir, file);
  if (!fs.existsSync(source)) {
    die(`publish file is missing from dist: ${file}`);
  }
  if (file !== "RELEASE_MANIFEST.json") {
    const artifact = artifacts.get(file);
    if (!artifact) die(`publish file is not listed in artifacts: ${file}`);
    if (artifact.publish !== true) {
      die(`publish file is not marked publish=true in release manifest: ${file}`);
    }
  }
  fs.copyFileSync(source, destination);
  copied.push(file);
}

const checksumLines = copied.map((file) => {
  const sha256 = checksumRows.get(file);
  if (!sha256) die(`missing checksum for staged file: ${file}`);
  return `${sha256}  ${file}`;
});

function sha256File(filePath) {
  return crypto.createHash("sha256").update(fs.readFileSync(filePath)).digest("hex");
}

const publicInstaller = manifest.distribution?.public_macos_installer;
if (!publicInstaller || !publishFiles.includes(publicInstaller)) {
  die("RELEASE_MANIFEST.json must mark the public macOS installer for release publishing");
}
const browserExtensionInstallUrl = manifest.distribution?.browser_extension_install_url
  || manifest.browser_extension_install_url
  || "";
const browserExtensionPrivacyPolicyUrl = manifest.distribution?.browser_extension_privacy_policy_url
  || manifest.browser_extension_privacy_policy_url
  || "";
const omittedArtifacts = Array.from(artifacts.values())
  .filter((artifact) => artifact.publish !== true)
  .map((artifact) => {
    const version = artifact.version ? ` v${artifact.version}` : "";
    return `- ${artifact.file}: ${artifact.role}${version}; ${artifact.usage}`;
  });

const summary = [
  allowDevelopmentPreview && manifest.release_mode !== true
    ? "AI Monitor development staging preview - not for public upload"
    : "AI Monitor public release upload set",
  ...(allowDevelopmentPreview && manifest.release_mode !== true ? [
    "",
    "WARNING: This directory was created from a non-release build with AI_MONITOR_ALLOW_DEV_PUBLIC_STAGE=1.",
    "Do not publish these files to ordinary users.",
    "Use it only for private testers who expect a development build.",
    "macOS may show unidentified-developer or security prompts because this preview is not Developer ID signed and notarized.",
  ] : []),
  "",
  `App: ${manifest.app_name} ${manifest.app_version} (${manifest.app_build})`,
  `Bundle ID: ${manifest.bundle_identifier}`,
  `Minimum macOS: ${manifest.minimum_macos_version}`,
  `Release mode: ${manifest.release_mode ? "yes" : "no"}`,
  "",
  "Publish exactly the files in this directory.",
  `Primary ordinary-user download: ${publicInstaller}`,
  browserExtensionInstallUrl
    ? `Browser extension install URL: ${browserExtensionInstallUrl}`
    : "Browser extension install URL: not configured in this preview; real releases require AI_MONITOR_BROWSER_EXTENSION_INSTALL_URL.",
  browserExtensionPrivacyPolicyUrl
    ? `Browser extension privacy policy URL: ${browserExtensionPrivacyPolicyUrl}`
    : "Browser extension privacy policy URL: not configured in this preview; real releases require AI_MONITOR_BROWSER_EXTENSION_PRIVACY_POLICY_URL.",
  "Optional add-ons are included only when they are listed below.",
  "Do not add omitted artifacts to the public upload set.",
  ...(omittedArtifacts.length > 0 ? [
    "",
    "Omitted artifacts:",
    ...omittedArtifacts,
  ] : []),
  "",
  "Files:",
  ...publishFiles.map((file) => {
    const artifact = artifacts.get(file);
    if (!artifact) return `- ${file}`;
    const version = artifact.version ? ` v${artifact.version}` : "";
    return `- ${file}: ${artifact.role}${version}; ${artifact.usage}`;
  }),
  "- PUBLIC_RELEASE_README.txt: upload guidance; keep this file with the staged release files.",
  "",
  "Verify after upload/download:",
  "  shasum -a 256 -c SHA256SUMS.txt",
  "",
];
const publicReadmePath = path.join(publicDir, "PUBLIC_RELEASE_README.txt");
fs.writeFileSync(publicReadmePath, summary.join("\n"));
checksumLines.push(`${sha256File(publicReadmePath)}  PUBLIC_RELEASE_README.txt`);
fs.writeFileSync(path.join(publicDir, "SHA256SUMS.txt"), `${checksumLines.join("\n")}\n`);
NODE

(
  cd "${PUBLIC_DIR}"
  /usr/bin/shasum -a 256 -c SHA256SUMS.txt >/dev/null
)

echo "Staged $(stage_label) in ${PUBLIC_DIR}"
