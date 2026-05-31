use ai_monitor_protocol::{
    AgentTask, AgentTaskEvent, DeliveryStatus, NotificationDelivery, TaskDetail, TaskSource,
    TaskStatus,
};
use chrono::{DateTime, Utc};
use rusqlite::{params, Connection, OptionalExtension};
use std::path::Path;
use std::sync::{Arc, Mutex};
use thiserror::Error;
use uuid::Uuid;

#[derive(Debug, Error)]
pub enum StorageError {
    #[error("sqlite error: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("time parse error: {0}")]
    Time(#[from] chrono::ParseError),
    #[error("storage lock poisoned")]
    LockPoisoned,
}

pub type Result<T> = std::result::Result<T, StorageError>;

#[derive(Clone)]
pub struct SqliteStore {
    conn: Arc<Mutex<Connection>>,
}

#[derive(Debug, Clone, Default)]
pub struct TaskListFilter {
    pub active_only: bool,
    pub status: Option<TaskStatus>,
    pub source: Option<TaskSource>,
    pub workspace_contains: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct DeliveryListFilter {
    pub event_id: Option<String>,
    pub task_id: Option<String>,
    pub provider_id: Option<String>,
    pub status: Option<DeliveryStatus>,
}

impl SqliteStore {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let conn = Connection::open(path)?;
        let store = Self {
            conn: Arc::new(Mutex::new(conn)),
        };
        store.migrate()?;
        Ok(store)
    }

    pub fn open_in_memory() -> Result<Self> {
        let conn = Connection::open_in_memory()?;
        let store = Self {
            conn: Arc::new(Mutex::new(conn)),
        };
        store.migrate()?;
        Ok(store)
    }

    pub fn migrate(&self) -> Result<()> {
        let conn = self.conn()?;
        conn.execute_batch(
            r#"
            PRAGMA journal_mode = WAL;
            PRAGMA foreign_keys = ON;

            CREATE TABLE IF NOT EXISTS events (
              event_id TEXT PRIMARY KEY,
              task_id TEXT NOT NULL,
              source TEXT NOT NULL,
              status TEXT NOT NULL,
              priority TEXT NOT NULL,
              workspace TEXT,
              title TEXT NOT NULL,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              event_json TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_events_task_id_updated_at
              ON events(task_id, updated_at);

            CREATE INDEX IF NOT EXISTS idx_events_status_updated_at
              ON events(status, updated_at);

            CREATE TABLE IF NOT EXISTS tasks (
              task_id TEXT PRIMARY KEY,
              source TEXT NOT NULL,
              app TEXT,
              workspace TEXT,
              session_name TEXT,
              window_title TEXT,
              title TEXT NOT NULL,
              status TEXT NOT NULL,
              step TEXT,
              message TEXT,
              confidence REAL NOT NULL,
              priority TEXT NOT NULL,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              last_event_id TEXT NOT NULL,
              actions_json TEXT NOT NULL,
              metadata_json TEXT NOT NULL,
              event_count INTEGER NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_tasks_status_updated_at
              ON tasks(status, updated_at);

            CREATE INDEX IF NOT EXISTS idx_tasks_source_updated_at
              ON tasks(source, updated_at);

            CREATE TABLE IF NOT EXISTS notification_deliveries (
              delivery_id TEXT PRIMARY KEY,
              event_id TEXT NOT NULL,
              task_id TEXT NOT NULL,
              provider_id TEXT NOT NULL,
              status TEXT NOT NULL,
              message TEXT,
              created_at TEXT NOT NULL,
              completed_at TEXT
            );

            CREATE INDEX IF NOT EXISTS idx_deliveries_event_id
              ON notification_deliveries(event_id);

            CREATE INDEX IF NOT EXISTS idx_deliveries_provider_status
              ON notification_deliveries(provider_id, status);
            "#,
        )?;
        add_column_if_missing(&conn, "tasks", "session_name", "TEXT")?;
        add_column_if_missing(&conn, "tasks", "window_title", "TEXT")?;
        Ok(())
    }

    pub fn record_event(&self, event: &AgentTaskEvent) -> Result<AgentTask> {
        self.insert_event(event)?;
        self.upsert_task_from_event(event)
    }

    pub fn insert_event(&self, event: &AgentTaskEvent) -> Result<()> {
        let conn = self.conn()?;
        let event_json = serde_json::to_string(event)?;
        conn.execute(
            r#"
            INSERT INTO events (
              event_id, task_id, source, status, priority, workspace, title,
              created_at, updated_at, event_json
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            ON CONFLICT(event_id) DO UPDATE SET
              task_id = excluded.task_id,
              source = excluded.source,
              status = excluded.status,
              priority = excluded.priority,
              workspace = excluded.workspace,
              title = excluded.title,
              created_at = excluded.created_at,
              updated_at = excluded.updated_at,
              event_json = excluded.event_json
            "#,
            params![
                event.event_id,
                event.task_id,
                event.source.as_str(),
                enum_to_string(&event.status)?,
                enum_to_string(&event.priority)?,
                event.workspace,
                event.title,
                event.created_at.to_rfc3339(),
                event.updated_at.to_rfc3339(),
                event_json
            ],
        )?;
        Ok(())
    }

    pub fn upsert_task_from_event(&self, event: &AgentTaskEvent) -> Result<AgentTask> {
        let conn = self.conn()?;
        let existing = Self::get_task_with_conn(&conn, &event.task_id)?;
        let task = match existing {
            Some(task) => task.merge_event(event),
            None => AgentTask::from_event(event),
        };

        conn.execute(
            r#"
            INSERT INTO tasks (
              task_id, source, app, workspace, session_name, window_title, title, status, step, message,
              confidence, priority, created_at, updated_at, last_event_id,
              actions_json, metadata_json, event_count
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)
            ON CONFLICT(task_id) DO UPDATE SET
              source = excluded.source,
              app = excluded.app,
              workspace = excluded.workspace,
              session_name = excluded.session_name,
              window_title = excluded.window_title,
              title = excluded.title,
              status = excluded.status,
              step = excluded.step,
              message = excluded.message,
              confidence = excluded.confidence,
              priority = excluded.priority,
              updated_at = excluded.updated_at,
              last_event_id = excluded.last_event_id,
              actions_json = excluded.actions_json,
              metadata_json = excluded.metadata_json,
              event_count = excluded.event_count
            "#,
            params![
                task.task_id,
                task.source.as_str(),
                task.app,
                task.workspace,
                task.session_name,
                task.window_title,
                task.title,
                enum_to_string(&task.status)?,
                task.step,
                task.message,
                task.confidence,
                enum_to_string(&task.priority)?,
                task.created_at.to_rfc3339(),
                task.updated_at.to_rfc3339(),
                task.last_event_id,
                serde_json::to_string(&task.actions)?,
                serde_json::to_string(&task.metadata)?,
                task.event_count as i64,
            ],
        )?;

        Ok(task)
    }

    pub fn list_tasks(&self, filter: TaskListFilter) -> Result<Vec<AgentTask>> {
        let conn = self.conn()?;
        let mut tasks = Vec::new();
        let mut stmt = conn.prepare("SELECT * FROM tasks ORDER BY updated_at DESC")?;
        let rows = stmt.query_map([], task_from_row)?;

        for row in rows {
            let task = row?;
            if filter.active_only && task.status.is_terminal() {
                continue;
            }
            if let Some(status) = filter.status {
                if task.status != status {
                    continue;
                }
            }
            if let Some(source) = &filter.source {
                if task.source != *source {
                    continue;
                }
            }
            if let Some(workspace_contains) = &filter.workspace_contains {
                let matches = task
                    .workspace
                    .as_deref()
                    .map(|workspace| workspace.contains(workspace_contains))
                    .unwrap_or(false);
                if !matches {
                    continue;
                }
            }
            tasks.push(task);
        }

        Ok(tasks)
    }

    pub fn list_stale_candidate_tasks(&self, cutoff: DateTime<Utc>) -> Result<Vec<AgentTask>> {
        let conn = self.conn()?;
        let mut tasks = Vec::new();
        let mut stmt =
            conn.prepare("SELECT * FROM tasks WHERE updated_at < ?1 ORDER BY updated_at ASC")?;
        let rows = stmt.query_map(params![cutoff.to_rfc3339()], task_from_row)?;

        for row in rows {
            let task = row?;
            if task.status.is_stale_candidate() {
                tasks.push(task);
            }
        }

        Ok(tasks)
    }

    pub fn get_task(&self, task_id: &str) -> Result<Option<AgentTask>> {
        let conn = self.conn()?;
        Self::get_task_with_conn(&conn, task_id)
    }

    pub fn delete_task(&self, task_id: &str) -> Result<bool> {
        let mut conn = self.conn()?;
        let tx = conn.transaction()?;

        let task_rows = tx.execute("DELETE FROM tasks WHERE task_id = ?1", params![task_id])?;
        tx.execute(
            "DELETE FROM notification_deliveries WHERE task_id = ?1",
            params![task_id],
        )?;
        tx.execute("DELETE FROM events WHERE task_id = ?1", params![task_id])?;
        tx.commit()?;

        Ok(task_rows > 0)
    }

    pub fn get_task_detail(&self, task_id: &str) -> Result<Option<TaskDetail>> {
        let Some(task) = self.get_task(task_id)? else {
            return Ok(None);
        };
        let events = self.get_task_events(task_id)?;
        let deliveries = self.list_notification_deliveries(DeliveryListFilter {
            task_id: Some(task_id.to_string()),
            ..DeliveryListFilter::default()
        })?;
        Ok(Some(TaskDetail {
            task,
            events,
            deliveries,
        }))
    }

    pub fn get_task_events(&self, task_id: &str) -> Result<Vec<AgentTaskEvent>> {
        let conn = self.conn()?;
        let mut stmt = conn
            .prepare("SELECT event_json FROM events WHERE task_id = ?1 ORDER BY updated_at ASC")?;
        let rows = stmt.query_map(params![task_id], |row| row.get::<_, String>(0))?;

        let mut events = Vec::new();
        for row in rows {
            events.push(serde_json::from_str(&row?)?);
        }
        Ok(events)
    }

    pub fn get_event(&self, event_id: &str) -> Result<Option<AgentTaskEvent>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare("SELECT event_json FROM events WHERE event_id = ?1")?;
        let event_json = stmt
            .query_row(params![event_id], |row| row.get::<_, String>(0))
            .optional()?;
        event_json
            .map(|value| serde_json::from_str(&value).map_err(StorageError::from))
            .transpose()
    }

    pub fn insert_delivery(&self, delivery: &NotificationDelivery) -> Result<()> {
        let conn = self.conn()?;
        conn.execute(
            r#"
            INSERT INTO notification_deliveries (
              delivery_id, event_id, task_id, provider_id, status, message, created_at, completed_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            ON CONFLICT(delivery_id) DO UPDATE SET
              status = excluded.status,
              message = excluded.message,
              completed_at = excluded.completed_at
            "#,
            params![
                delivery.delivery_id,
                delivery.event_id,
                delivery.task_id,
                delivery.provider_id,
                enum_to_string(&delivery.status)?,
                delivery.message,
                delivery.created_at.to_rfc3339(),
                delivery.completed_at.map(|value| value.to_rfc3339()),
            ],
        )?;
        Ok(())
    }

    pub fn create_pending_delivery(
        &self,
        event: &AgentTaskEvent,
        provider_id: impl Into<String>,
    ) -> Result<NotificationDelivery> {
        let delivery = NotificationDelivery {
            delivery_id: format!("delivery_{}", Uuid::new_v4()),
            event_id: event.event_id.clone(),
            task_id: event.task_id.clone(),
            provider_id: provider_id.into(),
            status: DeliveryStatus::Pending,
            message: None,
            created_at: Utc::now(),
            completed_at: None,
        };
        self.insert_delivery(&delivery)?;
        Ok(delivery)
    }

    pub fn update_delivery(
        &self,
        delivery_id: &str,
        status: DeliveryStatus,
        message: Option<String>,
    ) -> Result<NotificationDelivery> {
        let conn = self.conn()?;
        let completed_at = Utc::now();
        conn.execute(
            r#"
            UPDATE notification_deliveries
            SET status = ?1, message = ?2, completed_at = ?3
            WHERE delivery_id = ?4
            "#,
            params![
                enum_to_string(&status)?,
                message,
                completed_at.to_rfc3339(),
                delivery_id
            ],
        )?;

        let mut stmt =
            conn.prepare("SELECT * FROM notification_deliveries WHERE delivery_id = ?1")?;
        let delivery = stmt.query_row(params![delivery_id], delivery_from_row)?;
        Ok(delivery)
    }

    pub fn list_notification_deliveries(
        &self,
        filter: DeliveryListFilter,
    ) -> Result<Vec<NotificationDelivery>> {
        let conn = self.conn()?;
        let mut deliveries = Vec::new();

        let mut stmt =
            conn.prepare("SELECT * FROM notification_deliveries ORDER BY created_at DESC")?;
        let rows = stmt.query_map([], delivery_from_row)?;
        for row in rows {
            let delivery = row?;
            if let Some(event_id) = &filter.event_id {
                if delivery.event_id != *event_id {
                    continue;
                }
            }
            if let Some(task_id) = &filter.task_id {
                if delivery.task_id != *task_id {
                    continue;
                }
            }
            if let Some(provider_id) = &filter.provider_id {
                if delivery.provider_id != *provider_id {
                    continue;
                }
            }
            if let Some(status) = filter.status {
                if delivery.status != status {
                    continue;
                }
            }
            deliveries.push(delivery);
        }
        Ok(deliveries)
    }

    pub fn get_notification_delivery(
        &self,
        delivery_id: &str,
    ) -> Result<Option<NotificationDelivery>> {
        let conn = self.conn()?;
        let mut stmt =
            conn.prepare("SELECT * FROM notification_deliveries WHERE delivery_id = ?1")?;
        let delivery = stmt
            .query_row(params![delivery_id], delivery_from_row)
            .optional()?;
        Ok(delivery)
    }

    fn conn(&self) -> Result<std::sync::MutexGuard<'_, Connection>> {
        self.conn.lock().map_err(|_| StorageError::LockPoisoned)
    }

    fn get_task_with_conn(conn: &Connection, task_id: &str) -> Result<Option<AgentTask>> {
        let mut stmt = conn.prepare("SELECT * FROM tasks WHERE task_id = ?1")?;
        let task = stmt.query_row(params![task_id], task_from_row).optional()?;
        Ok(task)
    }
}

fn task_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<AgentTask> {
    let status: String = row.get("status")?;
    let priority: String = row.get("priority")?;
    let actions_json: String = row.get("actions_json")?;
    let metadata_json: String = row.get("metadata_json")?;
    let created_at: String = row.get("created_at")?;
    let updated_at: String = row.get("updated_at")?;
    let source: String = row.get("source")?;
    let event_count: i64 = row.get("event_count")?;

    Ok(AgentTask {
        task_id: row.get("task_id")?,
        source: TaskSource::new(source),
        app: row.get("app")?,
        workspace: row.get("workspace")?,
        session_name: row.get("session_name")?,
        window_title: row.get("window_title")?,
        title: row.get("title")?,
        status: enum_from_string(&status).map_err(to_sql_error)?,
        step: row.get("step")?,
        message: row.get("message")?,
        confidence: row.get("confidence")?,
        priority: enum_from_string(&priority).map_err(to_sql_error)?,
        created_at: parse_datetime(&created_at).map_err(to_sql_error)?,
        updated_at: parse_datetime(&updated_at).map_err(to_sql_error)?,
        last_event_id: row.get("last_event_id")?,
        actions: serde_json::from_str(&actions_json).map_err(to_sql_error)?,
        metadata: serde_json::from_str(&metadata_json).map_err(to_sql_error)?,
        event_count: event_count as u64,
    })
}

fn delivery_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<NotificationDelivery> {
    let status: String = row.get("status")?;
    let created_at: String = row.get("created_at")?;
    let completed_at: Option<String> = row.get("completed_at")?;

    Ok(NotificationDelivery {
        delivery_id: row.get("delivery_id")?,
        event_id: row.get("event_id")?,
        task_id: row.get("task_id")?,
        provider_id: row.get("provider_id")?,
        status: enum_from_string(&status).map_err(to_sql_error)?,
        message: row.get("message")?,
        created_at: parse_datetime(&created_at).map_err(to_sql_error)?,
        completed_at: completed_at
            .map(|value| parse_datetime(&value).map_err(to_sql_error))
            .transpose()?,
    })
}

fn add_column_if_missing(
    conn: &Connection,
    table_name: &str,
    column_name: &str,
    column_type: &str,
) -> Result<()> {
    let mut stmt = conn.prepare(&format!("PRAGMA table_info({table_name})"))?;
    let columns = stmt.query_map([], |row| row.get::<_, String>(1))?;
    for column in columns {
        if column? == column_name {
            return Ok(());
        }
    }

    conn.execute(
        &format!("ALTER TABLE {table_name} ADD COLUMN {column_name} {column_type}"),
        [],
    )?;
    Ok(())
}

fn enum_to_string<T: serde::Serialize>(value: &T) -> Result<String> {
    let value = serde_json::to_value(value)?;
    Ok(value
        .as_str()
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| value.to_string()))
}

fn enum_from_string<T: serde::de::DeserializeOwned>(value: &str) -> Result<T> {
    Ok(serde_json::from_value(serde_json::Value::String(
        value.to_string(),
    ))?)
}

fn parse_datetime(value: &str) -> Result<DateTime<Utc>> {
    Ok(DateTime::parse_from_rfc3339(value)?.with_timezone(&Utc))
}

fn to_sql_error(error: impl std::error::Error + Send + Sync + 'static) -> rusqlite::Error {
    rusqlite::Error::ToSqlConversionFailure(Box::new(error))
}

#[cfg(test)]
mod tests {
    use super::*;
    use ai_monitor_protocol::{TaskPriority, TaskStatus};
    use chrono::Duration;

    #[test]
    fn records_event_and_updates_task_state() {
        let store = SqliteStore::open_in_memory().unwrap();
        let mut running = AgentTaskEvent::new(
            "task_1",
            "codex-cli",
            "Implement event store",
            TaskStatus::Running,
        );
        running.priority = TaskPriority::P1;

        let task = store.record_event(&running).unwrap();
        assert_eq!(task.status, TaskStatus::Running);

        let mut completed = running.clone();
        completed.event_id = "evt_completed".to_string();
        completed.status = TaskStatus::Completed;
        completed.updated_at = Utc::now();

        let task = store.record_event(&completed).unwrap();
        assert_eq!(task.status, TaskStatus::Completed);
        assert_eq!(task.event_count, 2);

        let detail = store.get_task_detail("task_1").unwrap().unwrap();
        assert_eq!(detail.events.len(), 2);
    }

    #[test]
    fn task_detail_includes_delivery_debug_rows() {
        let store = SqliteStore::open_in_memory().unwrap();
        let event = AgentTaskEvent::new(
            "task_delivery",
            "codex-cli",
            "Delivery detail",
            TaskStatus::Completed,
        );

        store.record_event(&event).unwrap();
        let delivery = store.create_pending_delivery(&event, "desktop").unwrap();
        store
            .update_delivery(
                &delivery.delivery_id,
                DeliveryStatus::Sent,
                Some("ok".to_string()),
            )
            .unwrap();

        let detail = store.get_task_detail("task_delivery").unwrap().unwrap();
        assert_eq!(detail.deliveries.len(), 1);
        assert_eq!(detail.deliveries[0].provider_id, "desktop");
    }

    #[test]
    fn deletes_task_and_history() {
        let store = SqliteStore::open_in_memory().unwrap();
        let event = AgentTaskEvent::new(
            "task_delete",
            "terminal",
            "Temporary terminal task",
            TaskStatus::Running,
        );

        store.record_event(&event).unwrap();
        assert!(store.delete_task("task_delete").unwrap());
        assert!(store.get_task("task_delete").unwrap().is_none());
        assert!(store.get_task_events("task_delete").unwrap().is_empty());
        assert!(!store.delete_task("task_delete").unwrap());
    }

    #[test]
    fn lists_only_old_transient_tasks_as_stale_candidates() {
        let store = SqliteStore::open_in_memory().unwrap();
        let now = Utc::now();
        let old = now - Duration::hours(7);
        let cutoff = now - Duration::hours(6);

        let mut old_running = AgentTaskEvent::new(
            "task_old_running",
            "codex-cli",
            "Old running task",
            TaskStatus::Running,
        );
        old_running.created_at = old;
        old_running.updated_at = old;
        store.record_event(&old_running).unwrap();

        let mut old_completed = AgentTaskEvent::new(
            "task_old_completed",
            "codex-cli",
            "Old completed task",
            TaskStatus::Completed,
        );
        old_completed.created_at = old;
        old_completed.updated_at = old;
        store.record_event(&old_completed).unwrap();

        let fresh_running = AgentTaskEvent::new(
            "task_fresh_running",
            "codex-cli",
            "Fresh running task",
            TaskStatus::Running,
        );
        store.record_event(&fresh_running).unwrap();

        let candidates = store.list_stale_candidate_tasks(cutoff).unwrap();
        let task_ids: Vec<_> = candidates
            .iter()
            .map(|task| task.task_id.as_str())
            .collect();

        assert_eq!(task_ids, vec!["task_old_running"]);
    }
}
