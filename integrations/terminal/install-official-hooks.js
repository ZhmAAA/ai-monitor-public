#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const ROOT_DIR = path.resolve(__dirname, "../..");
const CLAUDE_HOOK = path.join(__dirname, "claude-code", "official-hook.sh");
const CODEX_HOOK = path.join(__dirname, "codex-cli", "official-hook.sh");

const CLAUDE_EVENTS = [
  ["SessionStart", "startup|resume|clear|compact"],
  ["Setup", "init|maintenance"],
  ["InstructionsLoaded", "*"],
  ["UserPromptSubmit"],
  ["UserPromptExpansion", "*"],
  ["PreToolUse", "*"],
  ["PermissionRequest", "*"],
  ["PermissionDenied", "*"],
  ["PostToolUse", "*"],
  ["PostToolUseFailure", "*"],
  ["PostToolBatch"],
  ["Notification", "*"],
  ["Stop"],
  ["StopFailure", "*"],
  ["SubagentStart", "*"],
  ["SubagentStop", "*"],
  ["TaskCreated"],
  ["TaskCompleted"],
  ["TeammateIdle"],
  ["ConfigChange", "*"],
  ["CwdChanged"],
  ["WorktreeCreate"],
  ["WorktreeRemove"],
  ["PreCompact", "manual|auto"],
  ["PostCompact", "manual|auto"],
  ["SessionEnd", "clear|resume|logout|prompt_input_exit|bypass_permissions_disabled|other"],
  ["Elicitation", "*"],
  ["ElicitationResult", "*"],
];

const CODEX_EVENTS = [
  ["SessionStart", "startup|resume|clear|compact"],
  ["UserPromptSubmit"],
  ["PreToolUse", "*"],
  ["PermissionRequest", "*"],
  ["PostToolUse", "*"],
  ["PreCompact", "manual|auto"],
  ["PostCompact", "manual|auto"],
  ["SubagentStart", "*"],
  ["SubagentStop", "*"],
  ["Stop"],
  ["SessionEnd", "clear|resume|logout|prompt_input_exit|bypass_permissions_disabled|archive|other"],
];

function main() {
  const { target, options } = parseArgs(process.argv.slice(2));
  if (!target || ["claude-code", "claude", "codex-cli", "codex"].includes(target) === false) {
    printHelp();
    process.exit(target ? 1 : 0);
  }

  const normalized = target.startsWith("claude") ? "claude-code" : "codex-cli";
  const filePath = configPathFor(normalized, options);
  const hookPath = normalized === "claude-code" ? CLAUDE_HOOK : CODEX_HOOK;
  const hookCommand = shellQuote(hookPath);
  const events = normalized === "claude-code" ? CLAUDE_EVENTS : CODEX_EVENTS;
  const config = readJson(filePath);

  config.hooks = config.hooks && typeof config.hooks === "object" ? config.hooks : {};

  for (const [eventName, matcher] of events) {
    config.hooks[eventName] = mergeEvent(
      config.hooks[eventName],
      {
        matcher,
        hooks: [
          {
            type: "command",
            command: hookCommand,
            timeout: 5,
            statusMessage: "Reporting to AI Monitor",
          },
        ],
      },
      hookPath,
      hookCommand
    );
  }

  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(config, null, 2)}\n`);

  process.stdout.write(`Installed AI Monitor ${normalized} hooks:\n${filePath}\n`);
  if (normalized === "codex-cli") {
    process.stdout.write("Open /hooks in Codex CLI and trust the new hook definitions before they run.\n");
  } else {
    process.stdout.write("Open /hooks in Claude Code to inspect the installed hooks.\n");
  }
}

function mergeEvent(existing, group, hookPath, hookCommand) {
  const groups = Array.isArray(existing) ? existing : [];
  const filtered = groups.filter((entry) => {
    const hooks = Array.isArray(entry?.hooks) ? entry.hooks : [];
    return hooks.some((hook) => hook?.command === hookPath || hook?.command === hookCommand) === false;
  });
  filtered.push(Object.fromEntries(Object.entries(group).filter(([, value]) => value !== undefined)));
  return filtered;
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, "'\\''")}'`;
}

function configPathFor(target, options) {
  if (options.file) return path.resolve(options.file);
  if (options.user) {
    return target === "claude-code"
      ? path.join(os.homedir(), ".claude", "settings.json")
      : path.join(os.homedir(), ".codex", "hooks.json");
  }

  const project = projectDirectory(options.project || process.cwd());
  return target === "claude-code"
    ? path.join(project, ".claude", "settings.local.json")
    : path.join(project, ".codex", "hooks.json");
}

function projectDirectory(value) {
  const project = path.resolve(value);
  let stat;
  try {
    stat = fs.statSync(project);
  } catch {
    throw new Error(`--project must point to an existing project directory: ${project}`);
  }
  if (!stat.isDirectory()) {
    throw new Error(`--project must point to a directory, not a file: ${project}`);
  }
  return project;
}

function readJson(filePath) {
  if (!fs.existsSync(filePath)) return {};
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch (error) {
    throw new Error(`cannot parse ${filePath}: ${error.message}`);
  }
}

function parseArgs(args) {
  const options = {};
  let target;
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (!arg.startsWith("--") && !target) {
      target = arg;
      continue;
    }
    if (arg === "--user") {
      options.user = true;
      continue;
    }
    const [rawKey, rawValue] = arg.slice(2).split("=", 2);
    const key = rawKey.replace(/-([a-z])/g, (_, letter) => letter.toUpperCase());
    const value = rawValue !== undefined ? rawValue : args[index + 1];
    if (rawValue === undefined) index += 1;
    if (value === undefined) throw new Error(`missing value for ${arg}`);
    options[key] = value;
  }
  return { target, options };
}

function printHelp() {
  process.stdout.write(`AI Monitor official hook installer

Usage:
  node integrations/terminal/install-official-hooks.js claude-code [--project /path/to/repo]
  node integrations/terminal/install-official-hooks.js codex-cli [--project /path/to/repo]
  node integrations/terminal/install-official-hooks.js claude-code --user
  node integrations/terminal/install-official-hooks.js codex-cli --user

Defaults:
  claude-code project config: <project>/.claude/settings.local.json
  codex-cli project config:   <project>/.codex/hooks.json

Project hook paths must already exist; the installer will not create a project directory for you.
`);
}

try {
  main();
} catch (error) {
  process.stderr.write(`AI Monitor official hook install failed: ${error.message}\n`);
  process.exit(1);
}
