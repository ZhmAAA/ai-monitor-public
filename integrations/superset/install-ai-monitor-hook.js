#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const ROOT_DIR = path.resolve(__dirname, "../..");
const DEFAULT_NOTIFY_HOOK = path.join(os.homedir(), ".superset", "hooks", "notify.sh");
const BRIDGE = path.join(__dirname, "ai-monitor-superset-hook.js");
const START = "# AI Monitor Superset fan-out start";
const END = "# AI Monitor Superset fan-out end";

function main() {
  const options = parseArgs(process.argv.slice(2));
  const notifyHook = path.resolve(options.file || DEFAULT_NOTIFY_HOOK);
  const bridge = path.resolve(options.bridge || BRIDGE);

  if (!fs.existsSync(notifyHook)) {
    throw new Error(`Superset notify hook not found: ${notifyHook}`);
  }
  if (!fs.existsSync(bridge)) {
    throw new Error(`AI Monitor Superset bridge not found: ${bridge}`);
  }

  let content = fs.readFileSync(notifyHook, "utf8");
  content = removeExistingBlock(content);
  const block = fanOutBlock(bridge);
  const marker = "\nif [ -n \"$SUPERSET_HOST_AGENT_HOOK_URL\" ] && [ -n \"$SUPERSET_TERMINAL_ID\" ]; then";

  if (!content.includes(marker)) {
    throw new Error("could not find Superset host-service dispatch block");
  }

  const next = content.replace(marker, `\n${block}${marker}`);
  if (next !== fs.readFileSync(notifyHook, "utf8")) {
    const backup = `${notifyHook}.ai-monitor-backup-${Date.now()}`;
    fs.copyFileSync(notifyHook, backup);
    fs.writeFileSync(notifyHook, next);
    fs.chmodSync(notifyHook, 0o755);
    process.stdout.write(`Installed AI Monitor Superset fan-out:\n${notifyHook}\nBackup:\n${backup}\n`);
  } else {
    process.stdout.write(`AI Monitor Superset fan-out already installed:\n${notifyHook}\n`);
  }
}

function fanOutBlock(bridge) {
  return `${START}
AI_MONITOR_SUPERSET_BRIDGE="${shellEscape(bridge)}"
if [ "\${AI_MONITOR_SUPERSET_DISABLE:-0}" != "1" ] && [ -f "$AI_MONITOR_SUPERSET_BRIDGE" ] && command -v node >/dev/null 2>&1; then
  AI_MONITOR_SUPERSET_EVENT_TYPE="$EVENT_TYPE" \\
  AI_MONITOR_SUPERSET_V1_EVENT_TYPE="$V1_EVENT_TYPE" \\
  AI_MONITOR_SUPERSET_SESSION_ID="$SESSION_ID" \\
  node "$AI_MONITOR_SUPERSET_BRIDGE" "$INPUT" >/dev/null 2>&1 || true
fi
${END}
`;
}

function removeExistingBlock(content) {
  const pattern = new RegExp(`\\n?${escapeRegExp(START)}[\\s\\S]*?${escapeRegExp(END)}\\n?`, "g");
  return content.replace(pattern, "\n");
}

function parseArgs(args) {
  const options = {};
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (!arg.startsWith("--")) {
      throw new Error(`unexpected argument: ${arg}`);
    }
    const [rawKey, rawValue] = arg.slice(2).split("=", 2);
    const value = rawValue !== undefined ? rawValue : args[index + 1];
    if (rawValue === undefined) index += 1;
    if (value === undefined) throw new Error(`missing value for ${arg}`);
    options[rawKey.replace(/-([a-z])/g, (_, letter) => letter.toUpperCase())] = value;
  }
  return options;
}

function shellEscape(value) {
  return String(value).replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\$/g, "\\$").replace(/`/g, "\\`");
}

function escapeRegExp(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

main();
