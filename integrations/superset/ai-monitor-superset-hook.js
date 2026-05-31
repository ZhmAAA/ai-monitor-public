#!/usr/bin/env node
"use strict";

const http = require("node:http");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

async function main() {
  const input = parseInput(process.argv[2] || (await readStdin()));
  const eventType = normalizeEventType(
    env("AI_MONITOR_SUPERSET_EVENT_TYPE") ||
      input.hook_event_name ||
      input.hookEventName ||
      input.event ||
      input.type
  );

  if (!eventType) return;

  const sessionId =
    env("AI_MONITOR_SUPERSET_SESSION_ID") ||
    input.resourceId ||
    input.resource_id ||
    input.session_id ||
    input.sessionId ||
    input.thread_id ||
    input.conversation_id ||
    "";
  const agentId = env("SUPERSET_AGENT_ID") || input.agent_id || input.agentId || "superset";
  const source = sourceForAgent(agentId);
  const surfaceId =
    env("SUPERSET_PANE_ID") ||
    env("SUPERSET_TAB_ID") ||
    env("SUPERSET_TERMINAL_ID") ||
    env("TERM_SESSION_ID") ||
    os.hostname();
  const workspace = env("SUPERSET_WORKSPACE_PATH") || input.cwd || process.cwd();
  const taskId =
    env("AI_MONITOR_TASK_ID") ||
    `superset_${sanitize(surfaceId)}_${sanitize(source)}_${sanitize(sessionId || surfaceId)}`;

  if (isCloseEvent(eventType)) {
    await deleteTask(taskId);
    return;
  }

  const status = statusForEvent(eventType, input);
  const title = titleForEvent(agentId, status, eventType, input);
  const payload = {
    task_id: taskId,
    source,
    workspace,
    session_name: `${agentLabel(agentId)}:${shortId(sessionId || surfaceId)}`,
    window_title: `Superset - ${agentLabel(agentId)}`,
    title,
    status,
    step: stepForEvent(eventType, input),
    message: messageForEvent(eventType, input, title),
    command: commandFromInput(input),
    pid: process.ppid || process.pid,
    terminal_program: env("TERM_PROGRAM") || "Superset",
    term_session_id: env("TERM_SESSION_ID"),
    tmux_pane: env("TMUX_PANE"),
    confidence: 0.98,
    priority: priorityForStatus(status),
    notify_desktop: ["needs_permission", "waiting_for_input", "blocked", "failed"].includes(status),
    notify_external: ["needs_permission", "waiting_for_input", "blocked", "failed"].includes(status),
    metadata: prune({
      adapter_version: "superset-hook-0.1.0",
      superset_event_type: eventType,
      superset_session_id: sessionId,
      superset_agent_id: agentId,
      superset_terminal_id: env("SUPERSET_TERMINAL_ID"),
      superset_tab_id: env("SUPERSET_TAB_ID"),
      superset_pane_id: env("SUPERSET_PANE_ID"),
      superset_workspace_id: env("SUPERSET_WORKSPACE_ID"),
      superset_workspace_path: env("SUPERSET_WORKSPACE_PATH"),
      superset_env: env("SUPERSET_ENV"),
      superset_hook_version: env("SUPERSET_HOOK_VERSION"),
      hook_session_id: input.session_id || input.sessionId,
      resource_id: input.resourceId || input.resource_id,
      notification_type: input.notification_type,
      tool_name: input.tool_name || input.toolName,
      prompt: truncate(input.prompt, 500),
      last_assistant_message: truncate(input.last_assistant_message, 500),
    }),
  };

  await postJson("/terminal/events", payload);
}

function parseInput(raw) {
  const text = String(raw || "").trim();
  if (!text) return {};
  try {
    return JSON.parse(text);
  } catch {
    return {};
  }
}

function normalizeEventType(value) {
  const raw = String(value || "").trim();
  if (!raw) return "";
  const normalized = raw.toLowerCase().replace(/[-_\s]+/g, "");
  const aliases = {
    agentturncomplete: "Stop",
    taskcomplete: "Stop",
    taskcompleted: "Stop",
    taskstarted: "Start",
    sessionstart: "Start",
    userpromptsubmit: "Start",
    userpromptsubmitted: "Start",
    execapprovalrequest: "PermissionRequest",
    applypatchapprovalrequest: "PermissionRequest",
    requestuserinput: "PermissionRequest",
    sessionend: "SessionEnd",
    detached: "SessionEnd",
    attached: "Start",
  };
  return aliases[normalized] || raw;
}

function sourceForAgent(agentId) {
  const normalized = String(agentId || "").toLowerCase();
  if (normalized === "claude") return "claude-code";
  if (normalized === "codex") return "codex-cli";
  if (normalized === "gemini") return "gemini-cli";
  return normalized || "superset";
}

function agentLabel(agentId) {
  const normalized = String(agentId || "").toLowerCase();
  if (normalized === "claude") return "Claude";
  if (normalized === "codex") return "Codex";
  if (normalized === "gemini") return "Gemini";
  if (normalized === "amp") return "Amp";
  if (normalized === "copilot") return "Copilot";
  return agentId || "Superset";
}

function statusForEvent(eventType, input) {
  const normalized = eventType.toLowerCase();
  if (normalized.includes("permission")) return "needs_permission";
  if (normalized.includes("elicitation") || normalized.includes("input")) return "waiting_for_input";
  if (normalized.includes("failure") || normalized.includes("failed")) return "failed";
  if (normalized.includes("idle") || input.notification_type === "idle_prompt") return "idle_but_not_done";
  if (normalized === "stop" || normalized.includes("complete")) return "completed";
  if (normalized.includes("tool")) return "executing_tool";
  return "running";
}

function isCloseEvent(eventType) {
  const normalized = eventType.toLowerCase();
  return normalized === "sessionend" || normalized === "detached";
}

function titleForEvent(agentId, status, eventType, input) {
  if (input.prompt) return concise(input.prompt, 72);
  const command = commandFromInput(input);
  if (command) return concise(command, 72);
  if (input.title) return concise(input.title, 72);
  if (status === "needs_permission") return `${agentLabel(agentId)} needs permission`;
  if (status === "completed") return `${agentLabel(agentId)} completed`;
  if (status === "failed") return `${agentLabel(agentId)} failed`;
  if (status === "idle_but_not_done") return `${agentLabel(agentId)} is waiting`;
  return `${agentLabel(agentId)} ${eventType}`;
}

function stepForEvent(eventType, input) {
  if (input.tool_name || input.toolName) return `${eventType}: ${input.tool_name || input.toolName}`;
  if (input.notification_type) return `${eventType}: ${input.notification_type}`;
  return eventType.replace(/([a-z])([A-Z])/g, "$1 $2");
}

function messageForEvent(eventType, input, fallback) {
  if (input.message) return concise(input.message, 240);
  if (input.last_assistant_message) return concise(input.last_assistant_message, 240);
  if (input.prompt) return concise(input.prompt, 240);
  const command = commandFromInput(input);
  if (command) return command;
  return fallback || eventType;
}

function commandFromInput(input) {
  const toolInput = input.tool_input || input.toolInput || {};
  return toolInput.command || toolInput.cmd || input.command;
}

function priorityForStatus(status) {
  if (["needs_permission", "waiting_for_input", "blocked", "failed"].includes(status)) return "P0";
  if (status === "completed") return "P1";
  return "P2";
}

function postJson(path, payload) {
  return request(path, "POST", payload);
}

function deleteTask(taskId) {
  return request(`/tasks/${encodeURIComponent(taskId)}`, "DELETE");
}

function request(path, method, payload) {
  const baseUrl = localDaemonBaseUrl(env("AI_MONITOR_URL"));
  const url = new URL(`${baseUrl}${path}`);
  const body = payload === undefined ? "" : JSON.stringify(payload);
  const headers = {
    ...authHeaders(),
    ...(body
    ? { "content-type": "application/json", "content-length": Buffer.byteLength(body) }
    : {}),
  };

  return new Promise((resolve) => {
    const req = http.request(url, { method, headers }, (res) => {
      res.resume();
      res.on("end", resolve);
    });
    req.on("error", resolve);
    req.setTimeout(Number(env("AI_MONITOR_TIMEOUT_MS") || "1500"), () => {
      req.destroy();
      resolve();
    });
    if (body) req.write(body);
    req.end();
  });
}

function localDaemonBaseUrl(value) {
  const raw = String(value || "http://127.0.0.1:4318").trim() || "http://127.0.0.1:4318";
  try {
    const parsed = new URL(raw);
    if (parsed.protocol !== "http:" || !isLoopbackHost(parsed.hostname)) {
      return "http://127.0.0.1:4318";
    }
    return parsed.href.replace(/\/$/, "");
  } catch {
    return "http://127.0.0.1:4318";
  }
}

function isLoopbackHost(hostname) {
  const host = String(hostname || "").toLowerCase();
  if (host === "localhost" || host === "::1" || host === "[::1]") {
    return true;
  }
  if (!/^127(?:\.\d{1,3}){3}$/.test(host)) {
    return false;
  }
  return host.split(".").every((part) => {
    const value = Number(part);
    return Number.isInteger(value) && value >= 0 && value <= 255;
  });
}

function readStdin() {
  return new Promise((resolve) => {
    let input = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => {
      input += chunk;
    });
    process.stdin.on("end", () => resolve(input));
    process.stdin.on("error", () => resolve(input));
  });
}

function sanitize(value) {
  const sanitized = String(value || "")
    .replace(/[^a-zA-Z0-9_-]+/g, "_")
    .replace(/^_+|_+$/g, "");
  return sanitized || "unknown";
}

function shortId(value) {
  const sanitized = sanitize(value);
  return sanitized.length <= 16 ? sanitized : sanitized.slice(-12);
}

function concise(value, maxLength) {
  const text = String(value || "").replace(/\s+/g, " ").trim();
  if (text.length <= maxLength) return text;
  return `${text.slice(0, maxLength - 3)}...`;
}

function truncate(value, maxLength) {
  if (value === undefined || value === null) return undefined;
  return concise(value, maxLength);
}

function prune(value) {
  return Object.fromEntries(
    Object.entries(value).filter(([, entry]) => entry !== undefined && entry !== null && entry !== "")
  );
}

function env(name) {
  return process.env[name];
}

function authHeaders() {
  const token =
    env("AI_MONITOR_API_TOKEN") ||
    env("AI_MONITOR_TOKEN") ||
    readApiTokenFile(env("AI_MONITOR_API_TOKEN_FILE"));
  return token ? { "x-ai-monitor-token": token } : {};
}

function readApiTokenFile(explicitPath) {
  const filePath = explicitPath || path.join(os.homedir(), ".ai-monitor", "api-token");
  try {
    const token = fs.readFileSync(filePath, "utf8").trim();
    return token || undefined;
  } catch {
    return undefined;
  }
}

main().catch(() => {
  process.exit(0);
});
