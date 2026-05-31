#!/usr/bin/env node
"use strict";

const crypto = require("node:crypto");
const fs = require("node:fs");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const { spawn, spawnSync } = require("node:child_process");

const STATUSES = new Set([
  "queued",
  "starting",
  "running",
  "thinking",
  "executing_tool",
  "waiting_for_input",
  "needs_permission",
  "blocked",
  "idle_but_not_done",
  "completed",
  "failed",
  "cancelled",
  "stale",
  "unknown",
]);

const PRIORITIES = new Set(["P0", "P1", "P2", "P3"]);
const DEFAULT_DAEMON_URL = "http://127.0.0.1:4318";

async function main() {
  const [command, ...args] = process.argv.slice(2);
  if (!command || command === "help" || command === "--help" || command === "-h") {
    printHelp();
    return;
  }

  if (command === "event") {
    const parsed = parseArgs(args);
    await postTerminalEvent(
      buildTerminalPayload(parsed.options),
      parsed.options.daemonUrl,
      parsed.options
    );
    return;
  }

  if (command === "run") {
    const parsed = parseArgs(args, { allowCommand: true });
    await runCommand(parsed.options, parsed.command);
    return;
  }

  if (command === "close" || command === "delete") {
    const parsed = parseArgs(args);
    await closeTask(parsed.options);
    return;
  }

  if (command === "hook") {
    const hookArgs = [...args];
    const hookSource = hookArgs[0] && !hookArgs[0].startsWith("--") ? hookArgs.shift() : undefined;
    const parsed = parseArgs(hookArgs);
    await handleOfficialHook({
      ...parsed.options,
      source: parsed.options.source || hookSource,
    });
    return;
  }

  if (command === "notify") {
    const parsed = parseArgs(args, { allowPositionals: true });
    await handleCodexNotify(parsed.options, parsed.positionals);
    return;
  }

  throw new Error(`unknown command: ${command}`);
}

async function runCommand(options, command) {
  if (!command.length) {
    throw new Error("run requires a command after --");
  }

  const commandText = command.join(" ");
  const source = options.source || env("AI_MONITOR_SOURCE") || "terminal";
  const workspace = options.workspace || env("AI_MONITOR_WORKSPACE") || process.cwd();
  const sessionName =
    options.sessionName ||
    options.session_name ||
    env("AI_MONITOR_SESSION") ||
    inferSessionName(source, workspace);
  const taskId =
    options.taskId ||
    env("AI_MONITOR_TASK_ID") ||
    commandTaskId(source, workspace, sessionName, commandText);
  const base = {
    ...options,
    source,
    workspace,
    sessionName,
    taskId,
    title: options.title || commandText,
    step: options.step || "Running command",
    message: options.message || commandText,
    command: commandText,
  };

  const running = buildTerminalPayload({
    ...base,
    status: options.startStatus || "running",
  });
  await postTerminalEvent(running, options.daemonUrl, options);

  const child = spawn(command[0], command.slice(1), {
    stdio: "inherit",
    shell: false,
    env: process.env,
  });

  let terminating = false;
  const signalHandler = async (signal) => {
    if (terminating) return;
    terminating = true;
    try {
      if (signal === "SIGHUP") {
        await deleteTerminalTask(taskId, options.daemonUrl, { ...base, ...options, quiet: true });
      } else {
        await postTerminalEvent(
          buildTerminalPayload({
            ...base,
            status: "cancelled",
            step: `Received ${signal}`,
            message: `Command cancelled by ${signal}`,
            priority: "P2",
            notifyDesktop: false,
            notifyExternal: false,
          }),
          options.daemonUrl,
          options
        );
      }
    } finally {
      child.kill(signal);
    }
  };

  process.once("SIGINT", signalHandler);
  process.once("SIGTERM", signalHandler);
  process.once("SIGHUP", signalHandler);

  const exit = await new Promise((resolve) => {
    child.on("exit", (code, signal) => resolve({ code, signal }));
  });

  process.removeListener("SIGINT", signalHandler);
  process.removeListener("SIGTERM", signalHandler);
  process.removeListener("SIGHUP", signalHandler);

  if (exit.signal) {
    if (exit.signal === "SIGHUP") {
      await deleteTerminalTask(taskId, options.daemonUrl, { ...base, ...options, quiet: true });
      process.exit(129);
    }

    await postTerminalEvent(
      buildTerminalPayload({
        ...base,
        status: "cancelled",
        step: `Exited by ${exit.signal}`,
        message: `Command exited by ${exit.signal}`,
        priority: "P2",
        notifyDesktop: false,
        notifyExternal: false,
      }),
      options.daemonUrl,
      options
    );
    process.exit(130);
  }

  if (exit.code === 0) {
    await postTerminalEvent(
      buildTerminalPayload({
        ...base,
        status: "completed",
        step: options.completedStep || "Command completed",
        message: options.completedMessage || `${commandText} completed`,
        priority: options.completedPriority || "P1",
      }),
      options.daemonUrl,
      options
    );
  } else {
    await postTerminalEvent(
      buildTerminalPayload({
        ...base,
        status: "failed",
        step: options.failedStep || "Command failed",
        message: options.failedMessage || `${commandText} failed with exit code ${exit.code}`,
        priority: "P0",
        metadata: {
          exit_code: exit.code,
        },
      }),
      options.daemonUrl,
      options
    );
  }

  process.exit(exit.code ?? 1);
}

async function closeTask(options) {
  const payload = buildTerminalPayload({
    ...options,
    status: "cancelled",
    notifyDesktop: false,
    notifyExternal: false,
  });
  await deleteTerminalTask(payload.task_id, options.daemonUrl, { ...options, payload });
}

async function handleOfficialHook(options) {
  const source = normalizeOfficialSource(options.source);
  const input = await readJsonInput();
  const payload = buildOfficialHookPayload(source, input, options);
  const deliveryOptions = {
    ...options,
    quiet: !boolOption(options.debug, env("AI_MONITOR_HOOK_DEBUG"), false),
  };

  if (isClosingOfficialHookEvent(payload.metadata?.hook_event_name)) {
    await deleteTerminalTask(payload.task_id, options.daemonUrl, {
      ...deliveryOptions,
      payload,
    });
    return;
  }

  await postTerminalEvent(payload, options.daemonUrl, deliveryOptions);
}

async function handleCodexNotify(options, positionals) {
  const input = positionals[0] ? parseJson(positionals[0]) : await readJsonInput();
  const payload = buildCodexNotifyPayload(input, options);
  await postTerminalEvent(payload, options.daemonUrl, {
    ...options,
    quiet: !boolOption(options.debug, env("AI_MONITOR_HOOK_DEBUG"), false),
  });
}

function buildTerminalPayload(options) {
  const source = options.source || env("AI_MONITOR_SOURCE") || "terminal";
  const workspace =
    options.workspace || env("AI_MONITOR_WORKSPACE") || env("SUPERSET_WORKSPACE_PATH") || process.cwd();
  const sessionName =
    options.sessionName ||
    options.session_name ||
    env("AI_MONITOR_SESSION") ||
    inferSessionName(source, workspace);
  const windowTitle =
    options.windowTitle ||
    options.window_title ||
    env("AI_MONITOR_WINDOW_TITLE") ||
    inferWindowTitle(sessionName);
  const title = options.title || env("AI_MONITOR_TITLE") || sessionName || "Terminal task";
  const status = options.status || env("AI_MONITOR_STATUS") || "running";

  if (!STATUSES.has(status)) {
    throw new Error(`invalid status: ${status}`);
  }

  const priority = options.priority || defaultPriority(status);
  if (!PRIORITIES.has(priority)) {
    throw new Error(`invalid priority: ${priority}`);
  }

  const taskId =
    options.taskId ||
    options.task_id ||
    env("AI_MONITOR_TASK_ID") ||
    stableTaskId(source, workspace, sessionName);
  const pid = process.ppid || process.pid;
  const terminalTarget = options.target || env("AI_MONITOR_TERMINAL_TARGET") || "";
  const processAncestry = collectProcessAncestry();
  const agentHost = inferAgentHost(source, processAncestry);

  return {
    task_id: taskId,
    source,
    workspace,
    session_name: sessionName,
    window_title: windowTitle,
    title,
    status,
    step: options.step || env("AI_MONITOR_STEP") || statusToStep(status),
    message: options.message || env("AI_MONITOR_MESSAGE") || statusToMessage(status, title),
    command: options.command,
    target: terminalTarget,
    pid,
    terminal_program: env("TERM_PROGRAM"),
    term_session_id: env("TERM_SESSION_ID"),
    tmux_pane: env("TMUX_PANE"),
    confidence: Number(options.confidence || env("AI_MONITOR_CONFIDENCE") || "0.98"),
    priority,
    notify_desktop: boolOption(options.notifyDesktop, env("AI_MONITOR_NOTIFY_DESKTOP"), true),
    notify_external: boolOption(options.notifyExternal, env("AI_MONITOR_NOTIFY_EXTERNAL"), true),
    metadata: prune({
      agent_host: agentHost?.kind,
      agent_host_label: agentHost?.label,
      agent_host_evidence: agentHost?.evidence,
      parent_command: processAncestry[0]?.command,
      tmux: env("TMUX"),
      superset_agent_id: env("SUPERSET_AGENT_ID"),
      superset_terminal_id: env("SUPERSET_TERMINAL_ID"),
      superset_tab_id: env("SUPERSET_TAB_ID"),
      superset_pane_id: env("SUPERSET_PANE_ID"),
      superset_workspace_id: env("SUPERSET_WORKSPACE_ID"),
      superset_workspace_path: env("SUPERSET_WORKSPACE_PATH"),
      superset_env: env("SUPERSET_ENV"),
      superset_hook_version: env("SUPERSET_HOOK_VERSION"),
      adapter_version: "terminal-0.2.0",
      ...(options.metadata || {}),
    }),
  };
}

function buildOfficialHookPayload(source, input, options = {}) {
  const eventName = String(
    input.hook_event_name || input.hookEventName || input.event || input.type || "hook"
  );
  const sourceName = source === "claude-code" ? "claude-code" : "codex-cli";
  const workspace = options.workspace || input.cwd || env("AI_MONITOR_WORKSPACE") || process.cwd();
  const sessionId = input.session_id || input.sessionId || input.thread_id || input.conversation_id;
  const turnId = input.turn_id || input.turnId;
  const toolName = input.tool_name || input.toolName;
  const toolInput = input.tool_input || input.toolInput || {};
  const command = commandFromHookInput(input);
  const observedConversationName = conversationNameFromInput(input, options);
  const conversationName = sessionConversationName(sourceName, sessionId, observedConversationName);
  const defaultSessionName = readableSessionName(sourceName, workspace, eventName);
  const sessionName =
    options.sessionName ||
    options.session_name ||
    conversationName ||
    input.agent_type ||
    defaultSessionName;
  const title = titleForOfficialHook(sourceName, eventName, input, command);
  const status = statusForOfficialHook(eventName, input);
  const message = messageForOfficialHook(eventName, input, command);
  const priority = options.priority || priorityForOfficialHook(eventName, status, input);

  return buildTerminalPayload({
    ...options,
    source: sourceName,
    workspace,
    sessionName,
    windowTitle:
      options.windowTitle ||
      options.window_title ||
      `${sourceName === "claude-code" ? "Claude Code" : "Codex CLI"} - ${sessionName}`,
    title,
    status,
    step: stepForOfficialHook(eventName, input),
    message,
    command,
    taskId:
      options.taskId ||
      options.task_id ||
      officialHookTaskId(sourceName, sessionId, input.transcript_path, workspace),
    priority,
    notifyDesktop: notifyDesktopForOfficialHook(eventName, status, input, options),
    notifyExternal: notifyExternalForOfficialHook(eventName, status, input, options),
    metadata: prune({
      hook_event_name: eventName,
      session_id: sessionId,
      turn_id: turnId,
      transcript_path: input.transcript_path,
      permission_mode: input.permission_mode,
      model: input.model,
      agent_id: input.agent_id,
      agent_type: input.agent_type,
      tool_name: toolName,
      tool_use_id: input.tool_use_id,
      notification_type: input.notification_type,
      conversation_name: conversationName,
      hook_source: sourceName,
      hook_adapter_version: "official-hook-0.1.0",
      prompt: truncate(input.prompt || conversationName, 500),
      last_assistant_message: truncate(input.last_assistant_message, 500),
      ...(options.metadata || {}),
    }),
  });
}

function buildCodexNotifyPayload(input, options = {}) {
  const type = input.type || "notification";
  const inputMessages = input.input_messages || input["input-messages"] || [];
  const lastInput = Array.isArray(inputMessages) ? inputMessages.at(-1) : "";
  const status = type === "agent-turn-complete" ? "completed" : "running";
  const workspace = options.workspace || input.cwd || env("AI_MONITOR_WORKSPACE") || process.cwd();
  const conversationName = conversationNameFromInput(input, options);

  return buildTerminalPayload({
    ...options,
    source: "codex-cli",
    workspace,
    sessionName:
      options.sessionName ||
      options.session_name ||
      conversationName ||
      readableSessionName("codex-cli", workspace, type),
    title: options.title || "Codex turn complete",
    status,
    step: type.replace(/[-_]/g, " "),
    message: input.last_assistant_message || lastInput || type,
    taskId:
      options.taskId ||
      options.task_id ||
      officialHookTaskId("codex-cli", input.session_id || input["turn-id"], null, process.cwd()),
    priority: status === "completed" ? "P1" : "P2",
    metadata: prune({
      notification_type: type,
      turn_id: input.turn_id || input["turn-id"],
      conversation_name: conversationName,
      notification_payload_version: "codex-notify-0.1.0",
      input_messages_count: Array.isArray(inputMessages) ? inputMessages.length : undefined,
      ...(options.metadata || {}),
    }),
  });
}

function buildEvent(options) {
  const payload = options.task_id ? options : buildTerminalPayload(options);
  const now = new Date().toISOString();

  return {
    event_id: `evt_terminal_${Date.now()}_${randomId()}`,
    task_id: payload.task_id,
    source: payload.source,
    app: "terminal",
    workspace: payload.workspace,
    session_name: payload.session_name,
    window_title: payload.window_title,
    title: payload.title,
    status: payload.status,
    step: payload.step,
    message: payload.message,
    confidence: payload.confidence,
    priority: payload.priority,
    notify_desktop: payload.notify_desktop,
    notify_external: payload.notify_external,
    created_at: now,
    updated_at: now,
    actions: pruneActions([
      {
        label: "Open terminal",
        type: terminalActionType(payload.target, payload.tmux_pane),
        target: payload.target,
        metadata: {
          pid: payload.pid,
          tmux_pane: payload.tmux_pane,
          term_session_id: payload.term_session_id,
        },
      },
      payload.workspace
        ? {
            label: "Open workspace",
            type: "open_url",
            target: `file://${payload.workspace}`,
            metadata: {},
          }
        : null,
    ]),
    metadata: prune({
      pid: payload.pid,
      terminal_program: payload.terminal_program,
      term_session_id: payload.term_session_id,
      tmux_pane: payload.tmux_pane,
      command: payload.command,
      ...payload.metadata,
    }),
  };
}

function terminalActionType(target, tmuxPane) {
  const normalized = String(target || "").toLowerCase();
  if (normalized.startsWith("file://")) return "open_url";
  if (normalized.startsWith("iterm")) return "open_iterm_window";
  if (normalized.startsWith("warp")) return "open_warp_session";
  if (normalized.startsWith("tmux") || tmuxPane) return "open_tmux_pane";
  return "open_terminal_session";
}

async function postTerminalEvent(payload, daemonUrlOverride, options = {}) {
  const strict = boolOption(options.strict, env("AI_MONITOR_STRICT"), false);
  let baseUrl;

  try {
    baseUrl = localDaemonBaseUrl(daemonUrlOverride || env("AI_MONITOR_URL"));
    const response = await requestJson(`${baseUrl}/terminal/events`, payload, "POST", options);
    logDelivery(payload, options);
    return response;
  } catch (error) {
    if (error.statusCode === 404 || error.statusCode === 405) {
      try {
        const response = await requestJson(`${baseUrl}/events`, buildEvent(payload), "POST", options);
        logDelivery(payload, options);
        return response;
      } catch (fallbackError) {
        return handleDeliveryError(payload, fallbackError, strict, options);
      }
    }
    return handleDeliveryError(payload, error, strict, options);
  }
}

async function deleteTerminalTask(taskId, daemonUrlOverride, options = {}) {
  const strict = boolOption(options.strict, env("AI_MONITOR_STRICT"), false);

  try {
    const baseUrl = localDaemonBaseUrl(daemonUrlOverride || env("AI_MONITOR_URL"));
    const response = await requestJson(
      `${baseUrl}/tasks/${encodeURIComponent(taskId)}`,
      undefined,
      "DELETE",
      options
    );
    logDeletion(taskId, options);
    return response;
  } catch (error) {
    if (error.statusCode === 404) {
      logDeletion(taskId, options);
      return { ok: true, deleted: false };
    }
    if (error.statusCode === 405) {
      return postTerminalEvent(
        buildTerminalPayload({
          ...(options.payload || options),
          taskId,
          status: "cancelled",
          step: "Terminal session closed",
          message: "Terminal session closed",
          priority: "P2",
          notifyDesktop: false,
          notifyExternal: false,
        }),
        daemonUrlOverride,
        options
      );
    }
    return handleDeleteError(taskId, error, strict, options);
  }
}

function handleDeliveryError(payload, error, strict, options = {}) {
  if (strict) {
    throw error;
  }
  if (!process.env.AI_MONITOR_QUIET && !options.quiet) {
    process.stderr.write(
      `AI Monitor: delivery failed for ${payload.status} ${payload.title}: ${error.message}\n`
    );
  }
  return { ok: false, error: error.message };
}

function logDelivery(payload, options = {}) {
  if (!process.env.AI_MONITOR_QUIET && !options.quiet) {
    process.stderr.write(`AI Monitor: ${payload.status} ${payload.title}\n`);
  }
}

function handleDeleteError(taskId, error, strict, options = {}) {
  if (strict) {
    throw error;
  }
  if (!process.env.AI_MONITOR_QUIET && !options.quiet) {
    process.stderr.write(`AI Monitor: close failed for ${taskId}: ${error.message}\n`);
  }
  return { ok: false, error: error.message };
}

function logDeletion(taskId, options = {}) {
  if (!process.env.AI_MONITOR_QUIET && !options.quiet) {
    process.stderr.write(`AI Monitor: closed ${taskId}\n`);
  }
}

function requestJson(url, payload, method = "POST", options = {}) {
  const body = payload === undefined ? "" : JSON.stringify(payload);
  const parsed = new URL(url);
  if (parsed.protocol !== "http:" || !isLoopbackHost(parsed.hostname)) {
    throw new Error("AI Monitor daemon URL must be local HTTP loopback");
  }
  const headers = authHeaders(options);
  if (body) {
    headers["content-type"] = "application/json";
    headers["content-length"] = Buffer.byteLength(body);
  }

  return new Promise((resolve, reject) => {
    const request = http.request(
      parsed,
      {
        method,
        headers,
      },
      (response) => {
        let data = "";
        response.setEncoding("utf8");
        response.on("data", (chunk) => {
          data += chunk;
        });
        response.on("end", () => {
          if (response.statusCode < 200 || response.statusCode >= 300) {
            const error = new Error(`daemon returned ${response.statusCode}: ${data}`);
            error.statusCode = response.statusCode;
            error.body = data;
            reject(error);
            return;
          }
          try {
            resolve(data ? JSON.parse(data) : {});
          } catch {
            resolve({});
          }
        });
      }
    );

    request.on("error", reject);
    const timeoutMs = Number(env("AI_MONITOR_TIMEOUT_MS") || "1500");
    if (timeoutMs > 0) {
      request.setTimeout(timeoutMs, () => {
        request.destroy(new Error(`request timed out after ${timeoutMs}ms`));
      });
    }
    if (body) {
      request.write(body);
    }
    request.end();
  });
}

function localDaemonBaseUrl(value) {
  const raw = String(value || DEFAULT_DAEMON_URL).trim() || DEFAULT_DAEMON_URL;
  const parsed = new URL(raw);
  if (parsed.protocol !== "http:" || !isLoopbackHost(parsed.hostname)) {
    throw new Error("AI Monitor daemon URL must be local HTTP loopback");
  }
  return parsed.href.replace(/\/$/, "");
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

function authHeaders(options = {}) {
  const token = apiToken(options);
  return token ? { "x-ai-monitor-token": token } : {};
}

function apiToken(options = {}) {
  return (
    options.apiToken ||
    options.api_token ||
    env("AI_MONITOR_API_TOKEN") ||
    env("AI_MONITOR_TOKEN") ||
    readApiTokenFile(options)
  );
}

function readApiTokenFile(options = {}) {
  const explicitPath =
    options.apiTokenFile || options.api_token_file || env("AI_MONITOR_API_TOKEN_FILE");
  const filePath = explicitPath || path.join(os.homedir(), ".ai-monitor", "api-token");
  try {
    const token = fs.readFileSync(filePath, "utf8").trim();
    return token || undefined;
  } catch {
    return undefined;
  }
}

function parseArgs(args, config = {}) {
  const options = {};
  const command = [];
  const positionals = [];
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (config.allowCommand && arg === "--") {
      command.push(...args.slice(index + 1));
      break;
    }
    if (!arg.startsWith("--")) {
      if (config.allowPositionals) {
        positionals.push(arg);
        continue;
      }
      throw new Error(`unexpected argument: ${arg}`);
    }

    const [rawKey, rawValue] = arg.slice(2).split("=", 2);
    const key = camelCase(rawKey);

    if (rawKey === "no-notify") {
      options.notifyDesktop = false;
      options.notifyExternal = false;
      continue;
    }

    if (rawKey === "strict") {
      options.strict = true;
      continue;
    }

    if (rawKey === "debug") {
      options.debug = true;
      continue;
    }

    if (rawKey === "quiet") {
      options.quiet = true;
      continue;
    }

    const value = rawValue !== undefined ? rawValue : args[index + 1];
    if (rawValue === undefined) index += 1;

    if (value === undefined) {
      throw new Error(`missing value for --${rawKey}`);
    }

    if (key === "metadata") {
      const metadata = options.metadata || {};
      const [metadataKey, metadataValue] = value.split("=", 2);
      if (!metadataKey || metadataValue === undefined) {
        throw new Error("--metadata expects key=value");
      }
      metadata[metadataKey] = metadataValue;
      options.metadata = metadata;
    } else {
      options[key] = value;
    }
  }
  return { options, command, positionals };
}

function inferSessionName(source, workspace) {
  if (env("TMUX_PANE")) return `${source}:${env("TMUX_PANE")}`;
  if (env("TERM_SESSION_ID")) return `${source}:${env("TERM_SESSION_ID").slice(-8)}`;
  return `${source}:${path.basename(workspace) || os.hostname()}`;
}

function inferWindowTitle(sessionName) {
  const terminal = env("TERM_PROGRAM") || "Terminal";
  return `${terminal} - ${sessionName}`;
}

function stableTaskId(source, workspace, sessionName) {
  const hash = crypto
    .createHash("sha1")
    .update(`${source}|${workspace}|${sessionName}`)
    .digest("hex")
    .slice(0, 12);
  return `terminal_${sanitize(source)}_${hash}`;
}

function commandTaskId(source, workspace, sessionName, commandText) {
  const hash = crypto
    .createHash("sha1")
    .update(
      `${source}|${workspace}|${sessionName}|${commandText}|${process.pid}|${Date.now()}|${randomId()}`
    )
    .digest("hex")
    .slice(0, 12);
  return `terminal_run_${sanitize(source)}_${hash}`;
}

function officialHookTaskId(source, sessionId, transcriptPath, workspace) {
  if (sessionId) {
    return `${sanitize(source)}_${sanitize(String(sessionId)).slice(0, 48)}`;
  }
  return stableTaskId(source, workspace || "", transcriptPath || "unknown");
}

function normalizeOfficialSource(source) {
  const normalized = String(source || env("AI_MONITOR_SOURCE") || "").toLowerCase();
  if (["claude", "claude-code", "claudecode"].includes(normalized)) return "claude-code";
  if (["codex", "codex-cli", "openai-codex"].includes(normalized)) return "codex-cli";
  throw new Error("hook requires source `claude-code` or `codex-cli`");
}

function titleForOfficialHook(source, eventName, input, command) {
  const agentName = humanAgentName(source);
  if (eventName === "UserPromptSubmit" && input.prompt) {
    return concise(input.prompt, 64);
  }
  if (eventName === "PreToolUse" || eventName === "PostToolUse" || eventName === "PostToolUseFailure") {
    return command ? concise(command, 72) : `${agentName} ${input.tool_name || "tool"}`;
  }
  if (eventName === "PermissionRequest") {
    return `${agentName} permission request`;
  }
  if (eventName === "Notification") {
    return input.title || `${agentName} notification`;
  }
  if (eventName === "Stop") {
    return input.session_title || `${agentName} completed`;
  }
  if (eventName === "StopFailure") {
    return `${agentName} failed`;
  }
  return `${agentName} ${humanizeEventName(eventName)}`;
}

function readableSessionName(source, workspace, eventName) {
  const agentName = humanAgentName(source);
  const workspaceName = workspace ? path.basename(workspace) : "";
  if (workspaceName) return `${agentName} - ${workspaceName}`;
  return `${agentName} ${humanizeEventName(eventName || "session")}`;
}

function conversationNameFromInput(input, options = {}) {
  const inputMessages = input.input_messages || input["input-messages"] || [];
  const lastInputMessage = Array.isArray(inputMessages) ? inputMessages.at(-1) : undefined;

  return firstReadableName([
    options.conversationName,
    options.conversation_name,
    input.prompt,
    lastInputMessage,
    input.conversation_name,
    input.conversationName,
    input.session_title,
    input.sessionTitle,
    input.thread_title,
    input.threadTitle,
    input.title,
  ]);
}

function sessionConversationName(source, sessionId, observedName) {
  const key = sessionConversationCacheKey(source, sessionId);
  if (!key) return observedName;

  if (observedName) {
    writeSessionConversationName(key, observedName);
    return observedName;
  }

  return readSessionConversationName(key);
}

function sessionConversationCacheKey(source, sessionId) {
  if (!sessionId) return undefined;
  return crypto
    .createHash("sha1")
    .update(`${source}:${sessionId}`)
    .digest("hex")
    .slice(0, 24);
}

function sessionConversationCachePath(key) {
  return path.join(os.tmpdir(), "ai-monitor", "session-names", `${key}.json`);
}

function writeSessionConversationName(key, name) {
  try {
    const filePath = sessionConversationCachePath(key);
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    fs.writeFileSync(
      filePath,
      JSON.stringify({ name: concise(name, 160), updated_at: new Date().toISOString() })
    );
  } catch {
    // Best-effort cache only; hook delivery should not depend on local writes.
  }
}

function readSessionConversationName(key) {
  try {
    const parsed = JSON.parse(fs.readFileSync(sessionConversationCachePath(key), "utf8"));
    return firstReadableName([parsed.name]);
  } catch {
    return undefined;
  }
}

function firstReadableName(candidates) {
  for (const candidate of candidates) {
    const value = String(candidate || "").replace(/\s+/g, " ").trim();
    if (!value) continue;
    const normalized = value.toLowerCase();
    if (["codex", "codex cli", "codex desktop", "codex completed", "codex turn complete"].includes(normalized)) {
      continue;
    }
    if (/^(codex|codex-cli):[a-f0-9-]{8,}$/i.test(value)) {
      continue;
    }
    return concise(value, 80);
  }
  return undefined;
}

function humanAgentName(source) {
  if (source === "claude-code") return "Claude Code";
  if (source === "codex-cli") return "Codex";
  if (source === "gemini-cli") return "Gemini CLI";
  return String(source || "Agent");
}

function humanizeEventName(value) {
  return String(value || "session")
    .replace(/[-_]/g, " ")
    .replace(/([a-z])([A-Z])/g, "$1 $2")
    .toLowerCase();
}

function statusForOfficialHook(eventName, input) {
  if (eventName === "SessionStart") return "starting";
  if (eventName === "UserPromptSubmit") return "running";
  if (eventName === "PreToolUse" || eventName === "PostToolUse") return "executing_tool";
  if (eventName === "PostToolUseFailure" || eventName === "StopFailure") return "failed";
  if (eventName === "PermissionRequest") return "needs_permission";
  if (eventName === "PermissionDenied") return "blocked";
  if (eventName === "Elicitation" || eventName === "ElicitationResult") return "waiting_for_input";
  if (eventName === "Notification") {
    if (input.notification_type === "permission_prompt") return "needs_permission";
    if (input.notification_type === "idle_prompt") return "idle_but_not_done";
    return "waiting_for_input";
  }
  if (eventName === "TeammateIdle") return "idle_but_not_done";
  if (eventName === "Stop") {
    if (Array.isArray(input.background_tasks) && input.background_tasks.length > 0) {
      return "idle_but_not_done";
    }
    return "completed";
  }
  if (isClosingOfficialHookEvent(eventName)) return "cancelled";
  if (eventName === "TaskCompleted") return "completed";
  if (eventName === "TaskCreated" || eventName === "SubagentStart") return "running";
  if (eventName === "SubagentStop") return "running";
  if (eventName === "PreCompact" || eventName === "PostCompact") return "thinking";
  if (eventName === "InstructionsLoaded" || eventName === "Setup") return "starting";
  if (eventName === "PostToolBatch") return "executing_tool";
  if (eventName === "WorktreeCreate" || eventName === "WorktreeRemove") return "running";
  return "running";
}

function isClosingOfficialHookEvent(eventName) {
  const normalized = String(eventName || "").toLowerCase().replace(/[-_]/g, "");
  return ["sessionend", "archive", "conversationarchive", "sessionarchive"].includes(normalized);
}

function stepForOfficialHook(eventName, input) {
  if (input.tool_name) return `${eventName}: ${input.tool_name}`;
  if (input.notification_type) return `${eventName}: ${input.notification_type}`;
  if (input.source && eventName === "SessionStart") return `Session start: ${input.source}`;
  if (input.trigger) return `${eventName}: ${input.trigger}`;
  return eventName.replace(/([a-z])([A-Z])/g, "$1 $2");
}

function messageForOfficialHook(eventName, input, command) {
  if (input.message) return input.message;
  if (eventName === "UserPromptSubmit" && input.prompt) return concise(input.prompt, 160);
  if (command) return command;
  if (eventName === "Stop" && input.last_assistant_message) {
    return concise(input.last_assistant_message, 240);
  }
  if (eventName === "SessionStart") return "Session started";
  return stepForOfficialHook(eventName, input);
}

function priorityForOfficialHook(eventName, status, input) {
  if (status === "needs_permission" || status === "blocked" || status === "failed") return "P0";
  if (status === "completed") return "P1";
  if (eventName === "Notification" || input.notification_type) return "P1";
  return "P2";
}

function notifyDesktopForOfficialHook(eventName, status, input, options) {
  if (options.notifyDesktop !== undefined) return options.notifyDesktop;
  if (input.notify_desktop !== undefined) return input.notify_desktop;
  return ["needs_permission", "waiting_for_input", "idle_but_not_done", "completed", "failed"].includes(status);
}

function notifyExternalForOfficialHook(eventName, status, input, options) {
  if (options.notifyExternal !== undefined) return options.notifyExternal;
  if (input.notify_external !== undefined) return input.notify_external;
  return ["needs_permission", "waiting_for_input", "idle_but_not_done", "failed"].includes(status);
}

function commandFromHookInput(input) {
  const toolInput = input.tool_input || input.toolInput || {};
  if (typeof toolInput.command === "string") return toolInput.command;
  if (typeof toolInput.cmd === "string") return toolInput.cmd;
  if (typeof input.command === "string") return input.command;
  return undefined;
}

function shortId(value) {
  const sanitized = sanitize(String(value || "session"));
  return sanitized.length <= 24 ? sanitized : sanitized.slice(-12);
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

function parseJson(value) {
  try {
    return JSON.parse(value);
  } catch (error) {
    throw new Error(`invalid JSON: ${error.message}`);
  }
}

async function readJsonInput() {
  const input = await readStdin();
  if (!input.trim()) return {};
  return parseJson(input);
}

function readStdin() {
  return new Promise((resolve, reject) => {
    let input = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => {
      input += chunk;
    });
    process.stdin.on("end", () => resolve(input));
    process.stdin.on("error", reject);
  });
}

function sanitize(value) {
  return String(value).replace(/[^a-zA-Z0-9_-]+/g, "_");
}

function defaultPriority(status) {
  if (["needs_permission", "waiting_for_input", "blocked", "idle_but_not_done", "failed"].includes(status)) {
    return "P0";
  }
  if (status === "completed") return "P1";
  return "P2";
}

function statusToStep(status) {
  return status.replace(/_/g, " ");
}

function statusToMessage(status, title) {
  return `${title} is ${status.replace(/_/g, " ")}`;
}

function boolOption(optionValue, envValue, fallback) {
  const value = optionValue ?? envValue;
  if (value === undefined || value === null || value === "") return fallback;
  return !["0", "false", "no", "off"].includes(String(value).toLowerCase());
}

function prune(value) {
  return Object.fromEntries(
    Object.entries(value).filter(([, entry]) => entry !== undefined && entry !== null && entry !== "")
  );
}

function pruneActions(actions) {
  return actions.filter(Boolean);
}

function collectProcessAncestry() {
  const ancestry = [];
  let pid = process.ppid || process.pid;

  for (let depth = 0; depth < 8 && pid && pid > 1; depth += 1) {
    const result = spawnSync("ps", ["-o", "pid=", "-o", "ppid=", "-o", "command=", "-p", String(pid)], {
      encoding: "utf8",
      timeout: 500,
    });
    if (result.error || result.status !== 0) break;

    const line = String(result.stdout || "").trim();
    const match = line.match(/^(\d+)\s+(\d+)\s+(.+)$/);
    if (!match) break;

    ancestry.push({
      pid: Number(match[1]),
      ppid: Number(match[2]),
      command: concise(match[3], 240),
    });
    pid = Number(match[2]);
  }

  return ancestry;
}

function inferAgentHost(source, processAncestry) {
  const normalizedSource = String(source || "").toLowerCase();
  const explicit = env("AI_MONITOR_AGENT_HOST");
  if (explicit) return agentHostFromKind(explicit, "AI_MONITOR_AGENT_HOST", normalizedSource);

  const commands = processAncestry.map((entry) => entry.command);
  const evidence = (predicate) => commands.find((command) => predicate(command.toLowerCase()));

  if (normalizedSource === "codex-cli") {
    const vscode = evidence(
      (command) =>
        command.includes(".vscode/extensions/openai.chatgpt") ||
        command.includes("visual studio code.app") ||
        command.includes("electron.app/contents") && command.includes("vscode")
    );
    if (vscode) return agentHostFromKind("codex-vscode", vscode);

    const desktop = evidence(
      (command) =>
        command.includes("/applications/codex.app/") ||
        command.includes("codex.app/contents") ||
        command.includes("resources/codex app-server")
    );
    if (desktop) return agentHostFromKind("codex-desktop", desktop);

    if (env("TERM_PROGRAM") || env("TMUX") || env("TERM_SESSION_ID")) {
      return agentHostFromKind("codex-cli", env("TERM_PROGRAM") || "terminal environment");
    }
    return agentHostFromKind("codex-cli", commands[0]);
  }

  if (normalizedSource === "claude-code") {
    const vscode = evidence(
      (command) =>
        command.includes(".vscode/extensions/anthropic") ||
        command.includes(".vscode/extensions/claude") ||
        command.includes("visual studio code.app") && command.includes("claude")
    );
    if (vscode) return agentHostFromKind("claude-code-vscode", vscode);

    const desktop = evidence(
      (command) =>
        command.includes("/applications/claude.app/") ||
        command.includes("claude.app/contents") ||
        command.includes("/applications/claude code.app/") ||
        command.includes("claude code.app/contents")
    );
    if (desktop) return agentHostFromKind("claude-code-desktop", desktop);

    if (env("TERM_PROGRAM") || env("TMUX") || env("TERM_SESSION_ID")) {
      return agentHostFromKind("claude-code-cli", env("TERM_PROGRAM") || "terminal environment");
    }
    return agentHostFromKind("claude-code-cli", commands[0]);
  }

  if (env("TERM_PROGRAM") || env("TMUX") || env("TERM_SESSION_ID")) {
    return agentHostFromKind("terminal", env("TERM_PROGRAM") || "terminal environment");
  }

  return undefined;
}

function agentHostFromKind(kind, evidence, source = "") {
  const normalized = String(kind || "").toLowerCase().replace(/_/g, "-");
  if (["desktop", "app"].includes(normalized) && source === "claude-code") {
    return { kind: "claude-code-desktop", label: "Claude Code Desktop", evidence: concise(evidence, 180) };
  }
  if (["desktop", "app"].includes(normalized) && source === "codex-cli") {
    return { kind: "codex-desktop", label: "Codex Desktop", evidence: concise(evidence, 180) };
  }
  if (["desktop", "codex-desktop", "codex-app"].includes(normalized)) {
    return { kind: "codex-desktop", label: "Codex Desktop", evidence: concise(evidence, 180) };
  }
  if (["claude-desktop", "claude-code-desktop", "claude-app"].includes(normalized)) {
    return { kind: "claude-code-desktop", label: "Claude Code Desktop", evidence: concise(evidence, 180) };
  }
  if (["vscode", "vs-code", "codex-vscode", "visual-studio-code"].includes(normalized)) {
    return { kind: "codex-vscode", label: "Codex VS Code", evidence: concise(evidence, 180) };
  }
  if (["claude-code-vscode", "claude-vscode"].includes(normalized)) {
    return { kind: "claude-code-vscode", label: "Claude Code VS Code", evidence: concise(evidence, 180) };
  }
  if (["cli", "codex-cli", "terminal-codex"].includes(normalized)) {
    return { kind: "codex-cli", label: "Codex CLI", evidence: concise(evidence, 180) };
  }
  if (["claude-code", "claude-code-cli", "terminal-claude"].includes(normalized)) {
    return { kind: "claude-code-cli", label: "Claude Code CLI", evidence: concise(evidence, 180) };
  }
  if (normalized === "terminal") {
    return { kind: "terminal", label: "Terminal", evidence: concise(evidence, 180) };
  }
  return { kind: normalized, label: String(kind), evidence: concise(evidence, 180) };
}

function camelCase(value) {
  return value.replace(/-([a-z])/g, (_, letter) => letter.toUpperCase());
}

function randomId() {
  return Math.random().toString(36).slice(2, 10);
}

function env(name) {
  return process.env[name];
}

function printHelp() {
  process.stdout.write(`AI Monitor terminal adapter

Usage:
  ai-monitor-terminal.js event --status running --title "Fix login bug"
  ai-monitor-terminal.js run --title "Run tests" -- npm test
  ai-monitor-terminal.js close --task-id stable-id
  ai-monitor-terminal.js hook claude-code < hook-event.json
  ai-monitor-terminal.js hook codex-cli < hook-event.json
  ai-monitor-terminal.js notify '{"type":"agent-turn-complete"}'

Options:
  --source codex-cli|claude-code|terminal
  --task-id stable-id
  --title "Task title"
  --status running|completed|failed|waiting_for_input|needs_permission|...
  --step "Current step"
  --message "Human readable message"
  --session-name "Terminal session name"
  --window-title "Terminal - session"
  --workspace /path/to/repo
  --target iterm://session/abc
  --daemon-url http://127.0.0.1:4318
  --api-token token
  --api-token-file /path/to/token
  --no-notify
  --strict
  --debug
  --quiet
  --metadata key=value

Environment:
  AI_MONITOR_URL, AI_MONITOR_WORKSPACE, AI_MONITOR_SESSION,
  AI_MONITOR_TASK_ID, AI_MONITOR_SOURCE, AI_MONITOR_TERMINAL_TARGET,
  AI_MONITOR_API_TOKEN, AI_MONITOR_API_TOKEN_FILE,
  AI_MONITOR_STRICT, AI_MONITOR_TIMEOUT_MS, AI_MONITOR_HOOK_DEBUG
`);
}

main().catch((error) => {
  process.stderr.write(`AI Monitor terminal adapter error: ${error.message}\n`);
  process.exit(1);
});
