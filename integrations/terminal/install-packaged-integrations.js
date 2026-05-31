#!/usr/bin/env node
"use strict";

const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const SOURCE_ROOT = path.resolve(__dirname, "../..");
const DEFAULT_TARGET_ROOT = path.join(
  os.homedir(),
  "Library",
  "Application Support",
  "AI Monitor",
  "terminal-integrations"
);

function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    printHelp();
    return;
  }

  const targetRoot = path.resolve(expandHome(options.targetDir || DEFAULT_TARGET_ROOT));
  const requests = hookInstallRequests(options);
  copyIntegrationBundle(targetRoot);

  process.stdout.write(`Installed stable AI Monitor terminal integrations:\n${targetRoot}\n`);

  if (requests.length === 0) {
    printNextSteps(targetRoot);
    return;
  }

  const installer = path.join(targetRoot, "integrations", "terminal", "install-official-hooks.js");
  for (const request of requests) {
    const args = [installer, request.target];
    if (request.user) {
      args.push("--user");
    } else {
      args.push("--project", request.project);
    }
    execFileSync(process.execPath, args, { stdio: "inherit" });
  }
}

function copyIntegrationBundle(targetRoot) {
  if (samePath(targetRoot, SOURCE_ROOT)) {
    validateIntegrationBundle(targetRoot);
    ensureExecutableHooks(targetRoot);
    return;
  }

  if (isPathInside(targetRoot, SOURCE_ROOT) || isPathInside(SOURCE_ROOT, targetRoot)) {
    throw new Error(`target directory must not overlap the source package: ${targetRoot}`);
  }

  const copies = [
    ["integrations/terminal", path.join(targetRoot, "integrations", "terminal")],
    ["integrations/superset", path.join(targetRoot, "integrations", "superset")],
  ];

  for (const [relativeSource, destination] of copies) {
    const source = path.join(SOURCE_ROOT, relativeSource);
    if (!fs.existsSync(source)) {
      throw new Error(`missing packaged integration directory: ${relativeSource}`);
    }
    replaceDirectory(source, destination);
  }

  const docsSource = path.join(SOURCE_ROOT, "docs", "integrations.md");
  if (fs.existsSync(docsSource)) {
    const docsDestination = path.join(targetRoot, "docs", "integrations.md");
    fs.mkdirSync(path.dirname(docsDestination), { recursive: true });
    fs.copyFileSync(docsSource, docsDestination);
  }

  validateIntegrationBundle(targetRoot);
  ensureExecutableHooks(targetRoot);
}

function validateIntegrationBundle(root) {
  for (const relativePath of [
    "integrations/terminal/ai-monitor-terminal.js",
    "integrations/terminal/install-terminal-integrations.command",
    "integrations/terminal/install-official-hooks.js",
    "integrations/terminal/claude-code/official-hook.sh",
    "integrations/terminal/codex-cli/official-hook.sh",
    "integrations/superset/ai-monitor-superset-hook.js",
  ]) {
    const fullPath = path.join(root, relativePath);
    if (!fs.existsSync(fullPath)) {
      throw new Error(`missing installed integration file: ${relativePath}`);
    }
  }
}

function ensureExecutableHooks(root) {
  for (const hookPath of [
    path.join(root, "integrations", "terminal", "claude-code", "official-hook.sh"),
    path.join(root, "integrations", "terminal", "codex-cli", "official-hook.sh"),
    path.join(root, "integrations", "terminal", "claude-code", "hook.sh"),
    path.join(root, "integrations", "terminal", "codex-cli", "hook.sh"),
    path.join(root, "integrations", "terminal", "install-terminal-integrations.command"),
  ]) {
    if (fs.existsSync(hookPath)) {
      fs.chmodSync(hookPath, 0o755);
    }
  }
}

function replaceDirectory(source, destination) {
  fs.rmSync(destination, { recursive: true, force: true });
  copyDirectory(source, destination);
}

function copyDirectory(source, destination) {
  fs.mkdirSync(destination, { recursive: true });
  for (const entry of fs.readdirSync(source, { withFileTypes: true })) {
    const sourcePath = path.join(source, entry.name);
    const destinationPath = path.join(destination, entry.name);
    if (entry.isDirectory()) {
      copyDirectory(sourcePath, destinationPath);
    } else if (entry.isSymbolicLink()) {
      const target = fs.readlinkSync(sourcePath);
      fs.symlinkSync(target, destinationPath);
    } else if (entry.isFile()) {
      fs.copyFileSync(sourcePath, destinationPath);
      fs.chmodSync(destinationPath, fs.statSync(sourcePath).mode & 0o777);
    }
  }
}

function hookInstallRequests(options) {
  if (options.noHooks) return [];

  const requests = [];
  if (options.project) {
    const project = projectDirectory(options.project, "--project");
    requests.push({ target: "claude-code", project });
    requests.push({ target: "codex-cli", project });
  }
  if (options.user) {
    requests.push({ target: "claude-code", user: true });
    requests.push({ target: "codex-cli", user: true });
  }
  if (options.claudeProject) {
    requests.push({ target: "claude-code", project: projectDirectory(options.claudeProject, "--claude-project") });
  }
  if (options.codexProject) {
    requests.push({ target: "codex-cli", project: projectDirectory(options.codexProject, "--codex-project") });
  }
  if (options.claudeUser) {
    requests.push({ target: "claude-code", user: true });
  }
  if (options.codexUser) {
    requests.push({ target: "codex-cli", user: true });
  }
  return requests;
}

function projectDirectory(value, optionName) {
  const project = path.resolve(expandHome(value));
  let stat;
  try {
    stat = fs.statSync(project);
  } catch {
    throw new Error(`${optionName} must point to an existing project directory: ${project}`);
  }
  if (!stat.isDirectory()) {
    throw new Error(`${optionName} must point to a directory, not a file: ${project}`);
  }
  return project;
}

function parseArgs(args) {
  const options = {};
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "-h" || arg === "--help") {
      options.help = true;
      continue;
    }
    if (arg === "--user") {
      options.user = true;
      continue;
    }
    if (arg === "--claude-user") {
      options.claudeUser = true;
      continue;
    }
    if (arg === "--codex-user") {
      options.codexUser = true;
      continue;
    }
    if (arg === "--no-hooks" || arg === "--only-copy") {
      options.noHooks = true;
      continue;
    }

    const [rawKey, inlineValue] = arg.startsWith("--") ? arg.slice(2).split("=", 2) : [null, null];
    if (!rawKey) throw new Error(`unknown argument: ${arg}`);
    const key = rawKey.replace(/-([a-z])/g, (_, letter) => letter.toUpperCase());
    if (!["targetDir", "project", "claudeProject", "codexProject"].includes(key)) {
      throw new Error(`unknown option: ${arg}`);
    }
    const value = inlineValue !== undefined ? inlineValue : args[index + 1];
    if (inlineValue === undefined) index += 1;
    if (!value) throw new Error(`missing value for ${arg}`);
    options[key] = value;
  }

  if (options.noHooks && hookInstallRequests({ ...options, noHooks: false }).length > 0) {
    throw new Error("--no-hooks cannot be combined with hook install options");
  }
  return options;
}

function expandHome(value) {
  if (value === "~") return os.homedir();
  if (value.startsWith("~/")) return path.join(os.homedir(), value.slice(2));
  return value;
}

function isPathInside(child, parent) {
  const relative = path.relative(canonicalPath(parent), canonicalPath(child));
  return relative === "" || (relative && !relative.startsWith("..") && !path.isAbsolute(relative));
}

function samePath(left, right) {
  return path.relative(canonicalPath(left), canonicalPath(right)) === "";
}

function canonicalPath(value) {
  try {
    return fs.realpathSync.native(value);
  } catch {
    return path.resolve(value);
  }
}

function printNextSteps(targetRoot) {
  const installer = path.join(targetRoot, "integrations", "terminal", "install-official-hooks.js");
  process.stdout.write(`
Next steps:
  node ${shellQuote(installer)} claude-code --project /path/to/repo
  node ${shellQuote(installer)} codex-cli --project /path/to/repo

For user-wide hooks:
  node ${shellQuote(installer)} claude-code --user
  node ${shellQuote(installer)} codex-cli --user
`);
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, "'\\''")}'`;
}

function printHelp() {
  process.stdout.write(`AI Monitor packaged terminal integration installer

Usage:
  ./integrations/terminal/install-terminal-integrations.command --project /path/to/repo
  ./integrations/terminal/install-terminal-integrations.command --user
  node integrations/terminal/install-packaged-integrations.js --project /path/to/repo
  node integrations/terminal/install-packaged-integrations.js --claude-project /path/to/repo --codex-project /path/to/repo
  node integrations/terminal/install-packaged-integrations.js --user
  node integrations/terminal/install-packaged-integrations.js --only-copy

Options:
  --target-dir PATH      Stable install directory.
                         Default: ~/Library/Application Support/AI Monitor/terminal-integrations
  --project PATH         Install Claude Code and Codex CLI project hooks.
  --claude-project PATH  Install Claude Code project hooks only.
  --codex-project PATH   Install Codex CLI project hooks only.
  --user                 Install Claude Code and Codex CLI user hooks.
  --claude-user          Install Claude Code user hooks only.
  --codex-user           Install Codex CLI user hooks only.
  --only-copy            Copy integrations to the stable directory without editing hook config.

Project hook paths must already exist; the installer will not create a project directory for you.
`);
}

try {
  main();
} catch (error) {
  process.stderr.write(`AI Monitor terminal integration install failed: ${error.message}\n`);
  process.exit(1);
}
