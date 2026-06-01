import {
  Activity,
  AlertCircle,
  CheckCircle2,
  ChevronRight,
  Circle,
  Clock3,
  Code2,
  Copy,
  ExternalLink,
  Globe2,
  ListFilter,
  Loader2,
  Play,
  Power,
  RefreshCw,
  Settings,
  Terminal,
  Trash2,
  XCircle,
} from "lucide-react";
import { useCallback, useEffect, useMemo, useState } from "react";
import {
  connectLive,
  deleteTask,
  fetchTasks,
  normalizeDaemonUrl,
  postDemoTask,
} from "./api";
import {
  getAppPaths,
  getDaemonStatus,
  isTauriRuntime,
  openTarget,
  readApiToken,
  startManagedDaemon,
  stopManagedDaemon,
} from "./tauri";
import type { AgentTask, AppPaths, DaemonStatus, TaskAction } from "./types";

type FilterKey = "active" | "attention" | "failed" | "completed" | "all";

const statusLabels: Record<string, string> = {
  queued: "Queued",
  starting: "Starting",
  running: "Running",
  thinking: "Thinking",
  executing_tool: "Executing",
  waiting_for_input: "Waiting",
  needs_permission: "Permission",
  blocked: "Blocked",
  idle_but_not_done: "Idle",
  completed: "Completed",
  failed: "Failed",
  cancelled: "Cancelled",
  stale: "Stale",
  unknown: "Unknown",
};

const attentionStatuses = new Set([
  "waiting_for_input",
  "needs_permission",
  "blocked",
  "idle_but_not_done",
  "failed",
]);

const terminalStatuses = new Set(["completed", "failed", "cancelled"]);

function sourceIcon(source: string) {
  const value = source.toLowerCase();
  if (value.includes("web") || value.includes("chatgpt") || value.includes("claude")) {
    return Globe2;
  }
  if (value.includes("cursor") || value.includes("vscode") || value.includes("codex")) {
    return Code2;
  }
  if (value.includes("terminal") || value.includes("cli")) {
    return Terminal;
  }
  return Activity;
}

function statusIcon(status: string) {
  if (status === "completed") return CheckCircle2;
  if (status === "failed" || status === "cancelled") return XCircle;
  if (attentionStatuses.has(status)) return AlertCircle;
  if (status === "thinking" || status === "executing_tool") return Loader2;
  if (status === "stale") return Clock3;
  return Circle;
}

function formatTime(value?: string) {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "";
  return new Intl.DateTimeFormat(undefined, {
    hour: "2-digit",
    minute: "2-digit",
  }).format(date);
}

function taskMatchesFilter(task: AgentTask, filter: FilterKey) {
  if (filter === "all") return true;
  if (filter === "failed") return task.status === "failed";
  if (filter === "completed") return task.status === "completed";
  if (filter === "attention") return attentionStatuses.has(task.status);
  return !terminalStatuses.has(task.status);
}

function choosePrimaryAction(task?: AgentTask) {
  return task?.actions?.find((action) => action.target?.trim()) ?? null;
}

function classNames(...values: Array<string | false | null | undefined>) {
  return values.filter(Boolean).join(" ");
}

export default function App() {
  const [daemonUrl, setDaemonUrl] = useState(() =>
    localStorage.getItem("ai-monitor-url") ?? "http://127.0.0.1:4318",
  );
  const [apiToken, setApiToken] = useState(
    () => localStorage.getItem("ai-monitor-token") ?? "",
  );
  const [tasks, setTasks] = useState<AgentTask[]>([]);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [filter, setFilter] = useState<FilterKey>("active");
  const [status, setStatus] = useState<DaemonStatus | null>(null);
  const [httpOnline, setHttpOnline] = useState(false);
  const [paths, setPaths] = useState<AppPaths | null>(null);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("Ready");
  const [settingsOpen, setSettingsOpen] = useState(false);

  const normalizedUrl = useMemo(() => normalizeDaemonUrl(daemonUrl), [daemonUrl]);

  const refreshStatus = useCallback(async () => {
    if (!isTauriRuntime()) {
      return;
    }
    try {
      const [daemonStatus, appPaths] = await Promise.all([
        getDaemonStatus(),
        getAppPaths(),
      ]);
      setStatus(daemonStatus);
      setPaths(appPaths);
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "Unable to read app status");
    }
  }, []);

  const refreshTasks = useCallback(async () => {
    try {
      const nextTasks = await fetchTasks(normalizedUrl, apiToken);
      setHttpOnline(true);
      setTasks(nextTasks);
      setSelectedId((current) => {
        if (current && nextTasks.some((task) => task.task_id === current)) {
          return current;
        }
        return nextTasks[0]?.task_id ?? null;
      });
      setMessage(`Updated ${formatTime(new Date().toISOString())}`);
    } catch (error) {
      setHttpOnline(false);
      setMessage(error instanceof Error ? error.message : "Daemon is offline");
    }
  }, [apiToken, normalizedUrl]);

  useEffect(() => {
    localStorage.setItem("ai-monitor-url", normalizedUrl);
  }, [normalizedUrl]);

  useEffect(() => {
    localStorage.setItem("ai-monitor-token", apiToken);
  }, [apiToken]);

  useEffect(() => {
    if (!isTauriRuntime() || apiToken.trim()) {
      return;
    }
    readApiToken()
      .then((token) => {
        if (token) setApiToken(token);
      })
      .catch(() => undefined);
  }, [apiToken]);

  useEffect(() => {
    refreshStatus();
    refreshTasks();
    const interval = window.setInterval(() => {
      refreshStatus();
      refreshTasks();
    }, 4000);
    return () => window.clearInterval(interval);
  }, [refreshStatus, refreshTasks]);

  useEffect(() => {
    let closed = false;
    let socket: WebSocket | null = null;

    try {
      socket = connectLive(
        normalizedUrl,
        apiToken,
        (liveMessage) => {
          if (closed) return;
          if (liveMessage.type === "task_updated") {
            setTasks((current) => {
              const existing = current.findIndex(
                (task) => task.task_id === liveMessage.task.task_id,
              );
              if (existing === -1) return [liveMessage.task, ...current];
              const next = [...current];
              next[existing] = liveMessage.task;
              return next;
            });
            setSelectedId((current) => current ?? liveMessage.task.task_id);
          }
          if (liveMessage.type === "task_deleted") {
            setTasks((current) =>
              current.filter((task) => task.task_id !== liveMessage.task_id),
            );
            setSelectedId((current) =>
              current === liveMessage.task_id ? null : current,
            );
          }
        },
        () => undefined,
      );
    } catch {
      return undefined;
    }

    return () => {
      closed = true;
      socket?.close();
    };
  }, [apiToken, normalizedUrl]);

  const sortedTasks = useMemo(
    () =>
      [...tasks].sort(
        (a, b) =>
          new Date(b.updated_at).getTime() - new Date(a.updated_at).getTime(),
      ),
    [tasks],
  );

  const visibleTasks = useMemo(
    () => sortedTasks.filter((task) => taskMatchesFilter(task, filter)),
    [filter, sortedTasks],
  );

  const selectedTask =
    sortedTasks.find((task) => task.task_id === selectedId) ?? visibleTasks[0] ?? null;

  const counts = useMemo(
    () => ({
      active: sortedTasks.filter((task) => taskMatchesFilter(task, "active")).length,
      attention: sortedTasks.filter((task) => taskMatchesFilter(task, "attention")).length,
      failed: sortedTasks.filter((task) => task.status === "failed").length,
      completed: sortedTasks.filter((task) => task.status === "completed").length,
      all: sortedTasks.length,
    }),
    [sortedTasks],
  );

  async function runWithBusy(action: () => Promise<void>) {
    setBusy(true);
    try {
      await action();
    } finally {
      setBusy(false);
    }
  }

  async function handleStartDaemon() {
    await runWithBusy(async () => {
      const nextStatus = await startManagedDaemon();
      setStatus(nextStatus);
      const token = await readApiToken();
      if (token) setApiToken(token);
      setMessage(nextStatus.message);
      await refreshTasks();
    });
  }

  async function handleStopDaemon() {
    await runWithBusy(async () => {
      const nextStatus = await stopManagedDaemon();
      setStatus(nextStatus);
      setMessage(nextStatus.message);
    });
  }

  async function handleOpen(action: TaskAction | null) {
    if (!action?.target) return;
    if (isTauriRuntime()) {
      await openTarget(action.target);
      return;
    }
    window.open(action.target, "_blank", "noopener,noreferrer");
  }

  async function handleClear(task: AgentTask) {
    await runWithBusy(async () => {
      await deleteTask(normalizedUrl, apiToken, task.task_id);
      setTasks((current) => current.filter((item) => item.task_id !== task.task_id));
      setSelectedId(null);
      setMessage("Task cleared");
    });
  }

  async function handleCopyToken() {
    let token = apiToken;
    if (!token && isTauriRuntime()) {
      token = (await readApiToken()) ?? "";
      setApiToken(token);
    }
    if (token) {
      await navigator.clipboard.writeText(token);
      setMessage("API token copied");
    }
  }

  async function handleDemoTask() {
    await runWithBusy(async () => {
      await postDemoTask(normalizedUrl, apiToken);
      await refreshTasks();
      setMessage("Demo task sent");
    });
  }

  const online = status?.online ?? httpOnline;
  const primaryAction = choosePrimaryAction(selectedTask ?? undefined);

  return (
    <main className="shell">
      <aside className="rail">
        <div className="brand">
          <img src="/assets/ai-monitor-logo.png" alt="" />
        </div>
        <button
          className={classNames("rail-button", filter === "active" && "selected")}
          onClick={() => setFilter("active")}
          title="Active"
        >
          <Activity size={18} />
          <span>{counts.active}</span>
        </button>
        <button
          className={classNames("rail-button", filter === "attention" && "selected")}
          onClick={() => setFilter("attention")}
          title="Waiting"
        >
          <AlertCircle size={18} />
          <span>{counts.attention}</span>
        </button>
        <button
          className={classNames("rail-button", filter === "failed" && "selected")}
          onClick={() => setFilter("failed")}
          title="Failed"
        >
          <XCircle size={18} />
          <span>{counts.failed}</span>
        </button>
        <button
          className={classNames("rail-button", filter === "completed" && "selected")}
          onClick={() => setFilter("completed")}
          title="Completed"
        >
          <CheckCircle2 size={18} />
          <span>{counts.completed}</span>
        </button>
        <button
          className={classNames("rail-button", filter === "all" && "selected")}
          onClick={() => setFilter("all")}
          title="Tasks"
        >
          <ListFilter size={18} />
          <span>{counts.all}</span>
        </button>
      </aside>

      <section className="workspace">
        <header className="topbar">
          <div>
            <h1>AI Monitor</h1>
            <div className="daemon-line">
              <span className={classNames("daemon-dot", online && "online")} />
              <span>{online ? "Daemon online" : "Daemon offline"}</span>
              {status?.managed && status.pid ? <span>PID {status.pid}</span> : null}
            </div>
          </div>
          <div className="toolbar">
            <button className="icon-button" onClick={refreshTasks} title="Refresh">
              <RefreshCw size={17} />
            </button>
            {isTauriRuntime() ? (
              online && status?.managed ? (
                <button className="icon-button" onClick={handleStopDaemon} title="Stop daemon">
                  <Power size={17} />
                </button>
              ) : (
                <button className="command-button" onClick={handleStartDaemon}>
                  <Play size={16} />
                  Start daemon
                </button>
              )
            ) : null}
            <button
              className="icon-button"
              onClick={() => setSettingsOpen((value) => !value)}
              title="Settings"
            >
              <Settings size={17} />
            </button>
          </div>
        </header>

        {settingsOpen ? (
          <section className="settings-strip">
            <label>
              <span>Daemon URL</span>
              <input
                value={daemonUrl}
                onChange={(event) => setDaemonUrl(event.target.value)}
                spellCheck={false}
              />
            </label>
            <label>
              <span>API token</span>
              <input
                value={apiToken}
                onChange={(event) => setApiToken(event.target.value)}
                spellCheck={false}
              />
            </label>
            <button className="icon-button" onClick={handleCopyToken} title="Copy API token">
              <Copy size={17} />
            </button>
          </section>
        ) : null}

        <div className="content-grid">
          <section className="task-list" aria-label="Tasks">
            <div className="list-title">
              <span>Tasks</span>
              <small>{message}</small>
            </div>
            {visibleTasks.length ? (
              visibleTasks.map((task) => (
                <TaskRow
                  key={task.task_id}
                  task={task}
                  selected={selectedTask?.task_id === task.task_id}
                  onSelect={() => setSelectedId(task.task_id)}
                />
              ))
            ) : (
              <div className="empty-state">
                <Activity size={28} />
                <strong>No active tasks</strong>
                <span>Start daemon or send a demo task.</span>
                <button className="command-button" onClick={handleDemoTask}>
                  <Play size={16} />
                  Demo event
                </button>
              </div>
            )}
          </section>

          <aside className="detail-pane" aria-label="Task details">
            {selectedTask ? (
              <>
                <div className="detail-header">
                  <div className={classNames("status-badge", selectedTask.status)}>
                    {statusLabels[selectedTask.status] ?? selectedTask.status}
                  </div>
                  <h2>{selectedTask.title}</h2>
                  <p>{selectedTask.message ?? selectedTask.step ?? "Task activity"}</p>
                </div>

                <div className="detail-actions">
                  <button
                    className="command-button"
                    disabled={!primaryAction || busy}
                    onClick={() => handleOpen(primaryAction)}
                  >
                    <ExternalLink size={16} />
                    Open
                  </button>
                  <button
                    className="icon-button"
                    disabled={busy}
                    onClick={() => handleClear(selectedTask)}
                    title="Clear"
                  >
                    <Trash2 size={17} />
                  </button>
                </div>

                <div className="detail-section">
                  <span>Source</span>
                  <strong>{selectedTask.source}</strong>
                </div>
                <div className="detail-section">
                  <span>Workspace</span>
                  <strong>{selectedTask.workspace ?? "Not reported"}</strong>
                </div>
                <div className="detail-section">
                  <span>Updated</span>
                  <strong>{formatTime(selectedTask.updated_at)}</strong>
                </div>

                <div className="timeline">
                  <TimelineItem label="Created" value={formatTime(selectedTask.created_at)} />
                  <TimelineItem
                    label={statusLabels[selectedTask.status] ?? selectedTask.status}
                    value={selectedTask.step ?? "Latest state"}
                    active
                  />
                  <TimelineItem
                    label="Events"
                    value={`${selectedTask.event_count ?? 1} received`}
                  />
                </div>

                {paths ? (
                  <div className="paths">
                    <span>Token</span>
                    <code>{paths.token_file}</code>
                  </div>
                ) : null}
              </>
            ) : (
              <div className="empty-state detail-empty">
                <ChevronRight size={28} />
                <strong>Select a task</strong>
                <span>Task details appear here.</span>
              </div>
            )}
          </aside>
        </div>
      </section>
    </main>
  );
}

function TaskRow({
  task,
  selected,
  onSelect,
}: {
  task: AgentTask;
  selected: boolean;
  onSelect: () => void;
}) {
  const SourceIcon = sourceIcon(task.source);
  const StatusIcon = statusIcon(task.status);

  return (
    <button className={classNames("task-row", selected && "selected")} onClick={onSelect}>
      <span className="source-mark">
        <SourceIcon size={17} />
      </span>
      <span className="task-main">
        <strong>{task.title}</strong>
        <small>{task.workspace ?? task.session_name ?? task.window_title ?? task.source}</small>
      </span>
      <span className={classNames("row-status", task.status)}>
        <StatusIcon size={15} />
        {statusLabels[task.status] ?? task.status}
      </span>
      <span className="row-time">{formatTime(task.updated_at)}</span>
    </button>
  );
}

function TimelineItem({
  label,
  value,
  active,
}: {
  label: string;
  value: string;
  active?: boolean;
}) {
  return (
    <div className={classNames("timeline-item", active && "active")}>
      <span />
      <div>
        <strong>{label}</strong>
        <small>{value}</small>
      </div>
    </div>
  );
}
