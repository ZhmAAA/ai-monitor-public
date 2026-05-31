const fs = require("fs");
const http = require("http");
const os = require("os");
const path = require("path");
const crypto = require("crypto");
const vscode = require("vscode");

const TERMINAL_STATUSES = new Set(["completed", "failed", "cancelled"]);
let statusBar;
let lastTaskId;

function activate(context) {
  statusBar = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 90);
  statusBar.text = "$(radio-tower) AI Monitor";
  statusBar.tooltip = "Send a test event to AI Monitor";
  statusBar.command = "aiMonitor.sendTestEvent";
  statusBar.show();
  context.subscriptions.push(statusBar);

  context.subscriptions.push(
    vscode.commands.registerCommand("aiMonitor.sendTestEvent", async () => {
      try {
        await postEvent({
          title: "IDE adapter test",
          status: "completed",
          priority: "P1",
          step: "IDE extension test",
          message: "VS Code/Cursor extension reached AI Monitor",
          taskIdSuffix: "test",
        });
        setStatus("test sent", false);
        vscode.window.showInformationMessage("AI Monitor test event sent.");
      } catch (error) {
        showDeliveryError(error);
      }
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand("aiMonitor.openDesktopSettings", async () => {
      try {
        await openDesktopSettings();
      } catch (error) {
        vscode.window.showWarningMessage(`Could not open AI Monitor Settings: ${error.message}`);
      }
    })
  );

  registerReportCommand(context, "aiMonitor.reportRunning", {
    status: "running",
    priority: "P2",
    step: "IDE task running",
    message: "IDE agent or task is running",
  });
  registerReportCommand(context, "aiMonitor.reportWaitingForInput", {
    status: "waiting_for_input",
    priority: "P0",
    step: "Waiting for input",
    message: "IDE agent is waiting for user input",
  });
  registerReportCommand(context, "aiMonitor.reportPendingChanges", {
    status: "idle_but_not_done",
    priority: "P0",
    step: "Pending changes",
    message: "IDE agent has pending changes or diff approval",
  });
  registerReportCommand(context, "aiMonitor.reportTestsRunning", {
    status: "running",
    priority: "P2",
    step: "Tests running",
    message: "IDE test task is running",
    taskIdSuffix: "tests",
  });
  registerReportCommand(context, "aiMonitor.reportTestsFailed", {
    status: "failed",
    priority: "P0",
    step: "Tests failed",
    message: "IDE test task failed",
    taskIdSuffix: "tests",
  });
  registerReportCommand(context, "aiMonitor.reportPrCreated", {
    status: "completed",
    priority: "P1",
    step: "PR created",
    message: "IDE agent created or opened a pull request",
    taskIdSuffix: "pull-request",
  });
  registerReportCommand(context, "aiMonitor.reportCompleted", {
    status: "completed",
    priority: "P1",
    step: "IDE task completed",
    message: "IDE agent or task completed",
  });
  registerReportCommand(context, "aiMonitor.reportFailed", {
    status: "failed",
    priority: "P0",
    step: "IDE task failed",
    message: "IDE agent or task failed",
  });

  context.subscriptions.push(
    vscode.commands.registerCommand("aiMonitor.clearTask", async () => {
      const taskId = lastTaskId || stableTaskId("manual");
      await deleteTask(taskId);
      setStatus("cleared", false);
    })
  );

  context.subscriptions.push(
    vscode.tasks.onDidStartTaskProcess((event) => {
      if (!config().get("autoReportTasks", true)) return;
      const definition = taskDefinition(event.execution.task);
      postEvent({
        status: "running",
        priority: isTestTask(event.execution.task) ? "P1" : "P2",
        step: isTestTask(event.execution.task) ? "Tests running" : "VS Code task running",
        message: definition,
        taskIdSuffix: taskSuffix(event.execution.task),
        metadata: {
          vscode_task_name: event.execution.task.name,
          vscode_task_source: event.execution.task.source,
          vscode_task_definition: definition,
          vscode_process_id: event.processId,
        },
      }).catch(showDeliveryError);
    }),
    vscode.tasks.onDidEndTaskProcess((event) => {
      if (!config().get("autoReportTasks", true)) return;
      const failed = typeof event.exitCode === "number" && event.exitCode !== 0;
      const testTask = isTestTask(event.execution.task);
      postEvent({
        status: failed ? "failed" : "completed",
        priority: failed ? "P0" : "P1",
        step: failed && testTask ? "Tests failed" : testTask ? "Tests completed" : failed ? "VS Code task failed" : "VS Code task completed",
        message: `${taskDefinition(event.execution.task)} exited with ${event.exitCode}`,
        taskIdSuffix: taskSuffix(event.execution.task),
        metadata: {
          vscode_task_name: event.execution.task.name,
          vscode_task_source: event.execution.task.source,
          vscode_exit_code: event.exitCode,
        },
      }).catch(showDeliveryError);
    })
  );
}

function deactivate() {}

function registerReportCommand(context, command, defaults) {
  context.subscriptions.push(
    vscode.commands.registerCommand(command, async () => {
      try {
        await postEvent(defaults);
        setStatus(defaults.status, true);
      } catch (error) {
        showDeliveryError(error);
      }
    })
  );
}

async function postEvent(options) {
  const settings = config();
  const source = settings.get("source", "vscode");
  const workspace = workspacePath(settings);
  const taskId = stableTaskId(options.taskIdSuffix || "agent", source, workspace);
  const now = new Date().toISOString();
  const title = titleForEvent(options);
  const event = {
    event_id: `evt_ide_${Date.now()}_${randomId()}`,
    task_id: taskId,
    source,
    app: appName(source),
    workspace,
    session_name: sessionName(workspace),
    window_title: windowTitle(source),
    title,
    status: options.status,
    step: options.step,
    message: options.message,
    confidence: 0.9,
    priority: options.priority || priorityForStatus(options.status),
    notify_desktop: true,
    notify_external: true,
    created_at: now,
    updated_at: now,
    actions: taskActions(source, workspace),
    metadata: {
      ide: source,
      extension: "ai-monitor-vscode",
      active_file: activeFilePath(),
      scm_pending_changes: sourceControlChangeCount(),
      ...options.metadata,
    },
  };

  await requestJson("POST", "/events", event);
  lastTaskId = taskId;
  setStatus(options.status, !TERMINAL_STATUSES.has(options.status));
  return event;
}

async function deleteTask(taskId) {
  await requestJson("DELETE", `/tasks/${encodeURIComponent(taskId)}`);
}

function requestJson(method, route, body) {
  const settings = config();
  const url = localDaemonUrl(settings.get("daemonUrl", "http://127.0.0.1:4318"), route);
  const payload = body ? Buffer.from(JSON.stringify(body)) : null;
  const token = apiToken(settings);

  return new Promise((resolve, reject) => {
    const request = http.request(
      {
        method,
        hostname: url.hostname,
        port: url.port || 80,
        path: `${url.pathname}${url.search}`,
        headers: {
          ...(payload ? { "content-type": "application/json", "content-length": payload.length } : {}),
          ...(token ? { "x-ai-monitor-token": token } : {}),
        },
      },
      (response) => {
        const chunks = [];
        response.on("data", (chunk) => chunks.push(chunk));
        response.on("end", () => {
          const text = Buffer.concat(chunks).toString("utf8");
          if (response.statusCode < 200 || response.statusCode >= 300) {
            reject(new Error(`AI Monitor returned ${response.statusCode}: ${text}`));
            return;
          }
          resolve(text ? safeJson(text) : null);
        });
      }
    );
    request.on("error", reject);
    if (payload) request.write(payload);
    request.end();
  });
}

function localDaemonUrl(rawBaseUrl, route) {
  const baseUrl = String(rawBaseUrl || "http://127.0.0.1:4318").trim().replace(/\/$/, "");
  const url = new URL(`${baseUrl}${route}`);
  if (url.protocol !== "http:" || !isLoopbackHost(url.hostname)) {
    throw new Error("AI Monitor daemon URL must be local HTTP loopback.");
  }
  return url;
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

function config() {
  return vscode.workspace.getConfiguration("aiMonitor");
}

function apiToken(settings) {
  const configured = String(settings.get("apiToken", "") || "").trim();
  if (configured) return configured;
  try {
    return fs.readFileSync(path.join(os.homedir(), ".ai-monitor", "api-token"), "utf8").trim();
  } catch {
    return "";
  }
}

function workspacePath(settings) {
  const configured = String(settings.get("workspace", "") || "").trim();
  if (configured) return configured;
  return vscode.workspace.workspaceFolders?.[0]?.uri?.fsPath || "";
}

function sessionName(workspace) {
  if (!workspace) return appName(config().get("source", "vscode"));
  return path.basename(workspace) || workspace;
}

function windowTitle(source) {
  const workspace = workspacePath(config());
  const label = workspace ? path.basename(workspace) : "No workspace";
  return `${appName(source)} - ${label}`;
}

function titleForEvent(options) {
  const editor = vscode.window.activeTextEditor;
  if (options.title) return options.title;
  if (options.taskIdSuffix === "tests") return "IDE tests";
  if (options.taskIdSuffix === "pull-request") return "IDE pull request";
  if (editor?.document?.fileName) return path.basename(editor.document.fileName);
  return options.step || "IDE task";
}

function activeFilePath() {
  return vscode.window.activeTextEditor?.document?.uri?.fsPath || "";
}

function sourceControlChangeCount() {
  return undefined;
}

function taskActions(source, workspace) {
  const actions = [];
  if (workspace) {
    const scheme = source === "cursor" ? "cursor" : "vscode";
    actions.push({
      label: "Open workspace",
      type: source === "cursor" ? "open_cursor_composer" : "open_vscode_workspace",
      target: `${scheme}://file/${workspace}`,
      file_path: workspace,
      metadata: {},
    });
  }
  const activeFile = activeFilePath();
  if (activeFile) {
    actions.push({
      label: "Open file",
      type: "open_file",
      target: activeFile,
      file_path: activeFile,
      metadata: {},
    });
  }
  return actions;
}

function stableTaskId(suffix, source = config().get("source", "vscode"), workspace = workspacePath(config())) {
  const hash = crypto
    .createHash("sha1")
    .update([source, workspace, suffix].join("\0"))
    .digest("hex")
    .slice(0, 16);
  return `ide_${source}_${hash}`;
}

function taskDefinition(task) {
  return [task.source, task.name].filter(Boolean).join(": ");
}

function taskSuffix(task) {
  return `${task.source || "task"}:${task.name || "unnamed"}`.toLowerCase();
}

function isTestTask(task) {
  const value = `${task.name || ""} ${task.source || ""}`.toLowerCase();
  return /\b(test|spec|jest|vitest|pytest|cargo test|go test|npm test)\b/.test(value);
}

function priorityForStatus(status) {
  if (["needs_permission", "waiting_for_input", "blocked", "failed", "idle_but_not_done"].includes(status)) {
    return "P0";
  }
  if (status === "completed") return "P1";
  return "P2";
}

function appName(source) {
  return source === "cursor" ? "Cursor" : "VS Code";
}

function randomId() {
  return crypto.randomBytes(6).toString("hex");
}

function safeJson(text) {
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

function setStatus(status, active) {
  if (!statusBar) return;
  statusBar.text = active ? `$(radio-tower) AI Monitor: ${status}` : "$(radio-tower) AI Monitor";
}

function showDeliveryError(error) {
  setStatus("offline", false);
  const action = "Open AI Monitor Settings";
  vscode.window
    .showWarningMessage(
      `AI Monitor delivery failed: ${error.message}. Open AI Monitor Settings and click Test connection, then retry.`,
      action
    )
    .then((selection) => {
      if (selection === action) {
        openDesktopSettings().catch((openError) => {
          vscode.window.showWarningMessage(`Could not open AI Monitor Settings: ${openError.message}`);
        });
      }
    });
}

function openDesktopSettings() {
  return vscode.env.openExternal(vscode.Uri.parse("ai-monitor://settings"));
}

module.exports = {
  activate,
  deactivate,
};
