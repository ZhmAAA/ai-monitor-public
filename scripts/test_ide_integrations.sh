#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

node --check integrations/ide/vscode/extension.js

node <<'NODE'
const fs = require("fs");
const path = require("path");

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

const pkg = JSON.parse(fs.readFileSync("integrations/ide/vscode/package.json", "utf8"));
assert(pkg.main === "./extension.js", "VS Code extension main must be ./extension.js");
assert(pkg.contributes?.commands?.length >= 10, "VS Code extension should expose task state and support commands");
assert(pkg.contributes?.configuration?.properties?.["aiMonitor.daemonUrl"], "VS Code daemonUrl setting missing");
assert(pkg.contributes?.configuration?.properties?.["aiMonitor.source"], "VS Code source setting missing");
const commandIds = new Set(pkg.contributes.commands.map((entry) => entry.command));
for (const command of ["aiMonitor.sendTestEvent", "aiMonitor.openDesktopSettings"]) {
  assert(commandIds.has(command), `VS Code extension missing ${command}`);
  assert(pkg.activationEvents.includes(`onCommand:${command}`), `VS Code extension activation missing ${command}`);
}

const extension = fs.readFileSync("integrations/ide/vscode/extension.js", "utf8");
for (const needle of [
  "ai-monitor://settings",
  "openDesktopSettings",
  "AI Monitor test event sent",
  "vscode.tasks.onDidStartTaskProcess",
  "vscode.tasks.onDidEndTaskProcess",
  "open_vscode_workspace",
  "open_cursor_composer",
  "x-ai-monitor-token",
]) {
  assert(extension.includes(needle), `VS Code extension missing ${needle}`);
}

const pluginXml = fs.readFileSync("integrations/ide/jetbrains/src/main/resources/META-INF/plugin.xml", "utf8");
for (const needle of [
  "local.ai-monitor.jetbrains",
  "AiMonitorConfigurable",
  "AiMonitorExecutionListener",
  "com.intellij.execution.ExecutionListener",
  "ReportStateAction",
  "ClearTaskAction",
  "ToolsMenu",
]) {
  assert(pluginXml.includes(needle), `JetBrains plugin.xml missing ${needle}`);
}

for (const file of [
  "AiMonitorSettings.kt",
  "AiMonitorConfigurable.kt",
  "AiMonitorClient.kt",
  "AiMonitorExecutionListener.kt",
  "ReportStateAction.kt",
  "ClearTaskAction.kt",
]) {
  const fullPath = path.join("integrations/ide/jetbrains/src/main/kotlin/local/aimonitor/jetbrains", file);
  assert(fs.existsSync(fullPath), `JetBrains source file missing: ${file}`);
}

const client = fs.readFileSync("integrations/ide/jetbrains/src/main/kotlin/local/aimonitor/jetbrains/AiMonitorClient.kt", "utf8");
for (const needle of ["POST", "/events", "DELETE", "/tasks/", "x-ai-monitor-token", "postRunConfigurationState"]) {
  assert(client.includes(needle), `JetBrains client missing ${needle}`);
}

const executionListener = fs.readFileSync(
  "integrations/ide/jetbrains/src/main/kotlin/local/aimonitor/jetbrains/AiMonitorExecutionListener.kt",
  "utf8"
);
for (const needle of [
  "ExecutionListener",
  "processStarted",
  "processNotStarted",
  "processTerminated",
  "autoReportRunConfigurations",
  "Tests running",
  "Tests failed",
]) {
  assert(executionListener.includes(needle), `JetBrains execution listener missing ${needle}`);
}

console.log("IDE integration structure checks passed");
NODE
