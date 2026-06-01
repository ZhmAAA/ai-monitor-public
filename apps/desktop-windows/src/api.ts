import type { AgentTask, LiveMessage } from "./types";

export function normalizeDaemonUrl(value: string) {
  const trimmed = value.trim() || "http://127.0.0.1:4318";
  return trimmed.endsWith("/") ? trimmed.slice(0, -1) : trimmed;
}

function headers(token: string) {
  const result: Record<string, string> = {
    "content-type": "application/json",
  };
  if (token.trim()) {
    result["x-ai-monitor-token"] = token.trim();
  }
  return result;
}

export async function fetchTasks(daemonUrl: string, token: string) {
  const response = await fetch(`${normalizeDaemonUrl(daemonUrl)}/tasks`, {
    headers: headers(token),
  });

  if (!response.ok) {
    throw new Error(`Daemon returned HTTP ${response.status}`);
  }

  return (await response.json()) as AgentTask[];
}

export async function deleteTask(
  daemonUrl: string,
  token: string,
  taskId: string,
) {
  const response = await fetch(
    `${normalizeDaemonUrl(daemonUrl)}/tasks/${encodeURIComponent(taskId)}`,
    {
      method: "DELETE",
      headers: headers(token),
    },
  );

  if (!response.ok && response.status !== 204) {
    throw new Error(`Delete failed with HTTP ${response.status}`);
  }
}

export async function postDemoTask(daemonUrl: string, token: string) {
  const now = new Date();
  const response = await fetch(`${normalizeDaemonUrl(daemonUrl)}/terminal/events`, {
    method: "POST",
    headers: headers(token),
    body: JSON.stringify({
      source: "codex-cli",
      taskId: "windows_demo_codex_cli",
      workspace: "D:\\ai-monitor-public",
      sessionName: "Windows MVP",
      title: "Build Windows desktop shell",
      status: "waiting_for_input",
      step: "Ready for review",
      message: `Demo task emitted at ${now.toLocaleTimeString()}`,
      priority: "P0",
      metadata: {
        adapter_version: "windows-demo-0.1.0",
      },
    }),
  });

  if (!response.ok) {
    throw new Error(`Demo event failed with HTTP ${response.status}`);
  }
}

export function connectLive(
  daemonUrl: string,
  token: string,
  onMessage: (message: LiveMessage) => void,
  onError: () => void,
) {
  const url = new URL(normalizeDaemonUrl(daemonUrl));
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
  url.pathname = "/live";
  url.search = "";
  if (token.trim()) {
    url.searchParams.set("token", token.trim());
  }

  const socket = new WebSocket(url);
  socket.addEventListener("message", (event) => {
    try {
      onMessage(JSON.parse(event.data) as LiveMessage);
    } catch {
      onError();
    }
  });
  socket.addEventListener("error", onError);
  return socket;
}
