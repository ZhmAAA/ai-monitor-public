export type TaskStatus =
  | "queued"
  | "starting"
  | "running"
  | "thinking"
  | "executing_tool"
  | "waiting_for_input"
  | "needs_permission"
  | "blocked"
  | "idle_but_not_done"
  | "completed"
  | "failed"
  | "cancelled"
  | "stale"
  | "unknown";

export interface TaskAction {
  label: string;
  type: string;
  target: string;
  app_bundle_id?: string;
  file_path?: string;
  line_number?: number;
  metadata?: Record<string, unknown>;
}

export interface AgentTask {
  task_id: string;
  source: string;
  app?: string;
  workspace?: string;
  session_name?: string;
  window_title?: string;
  title: string;
  status: TaskStatus;
  step?: string;
  message?: string;
  confidence: number;
  priority: "P0" | "P1" | "P2" | "P3";
  created_at: string;
  updated_at: string;
  last_event_id: string;
  actions?: TaskAction[];
  event_count?: number;
  metadata?: Record<string, unknown>;
}

export type LiveMessage =
  | {
      type: "task_updated";
      task: AgentTask;
      event: unknown;
    }
  | {
      type: "task_deleted";
      task_id: string;
    }
  | {
      type: "notification_delivered";
      delivery: unknown;
    };

export interface DaemonStatus {
  online: boolean;
  managed: boolean;
  pid?: number;
  message: string;
}

export interface AppPaths {
  data_dir: string;
  config_file: string;
  database_file: string;
  token_file: string;
  log_dir: string;
}
