import type { AppPaths, DaemonStatus } from "./types";

declare global {
  interface Window {
    __TAURI_INTERNALS__?: unknown;
  }
}

export function isTauriRuntime() {
  return typeof window !== "undefined" && Boolean(window.__TAURI_INTERNALS__);
}

async function invokeCommand<T>(command: string, args?: Record<string, unknown>) {
  if (!isTauriRuntime()) {
    throw new Error("Tauri runtime is not available");
  }

  const { invoke } = await import("@tauri-apps/api/core");
  return invoke<T>(command, args);
}

export function getDaemonStatus() {
  return invokeCommand<DaemonStatus>("daemon_status");
}

export function startManagedDaemon() {
  return invokeCommand<DaemonStatus>("start_daemon");
}

export function stopManagedDaemon() {
  return invokeCommand<DaemonStatus>("stop_daemon");
}

export function readApiToken() {
  return invokeCommand<string | null>("read_api_token");
}

export function getAppPaths() {
  return invokeCommand<AppPaths>("app_paths");
}

export function openTarget(target: string) {
  return invokeCommand<void>("open_target", { target });
}
