use chrono::{DateTime, Utc};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::fmt::{Display, Formatter};
use uuid::Uuid;

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize, JsonSchema)]
#[serde(transparent)]
pub struct TaskSource(pub String);

impl TaskSource {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl Default for TaskSource {
    fn default() -> Self {
        Self("unknown".to_string())
    }
}

impl Display for TaskSource {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum TaskStatus {
    Queued,
    Starting,
    Running,
    Thinking,
    ExecutingTool,
    WaitingForInput,
    NeedsPermission,
    Blocked,
    IdleButNotDone,
    Completed,
    Failed,
    Cancelled,
    Stale,
    Unknown,
}

impl TaskStatus {
    pub fn is_terminal(self) -> bool {
        matches!(self, Self::Completed | Self::Failed | Self::Cancelled)
    }

    pub fn is_stale_candidate(self) -> bool {
        matches!(
            self,
            Self::Queued
                | Self::Starting
                | Self::Running
                | Self::Thinking
                | Self::ExecutingTool
                | Self::Unknown
        )
    }

    pub fn needs_attention(self) -> bool {
        matches!(
            self,
            Self::WaitingForInput
                | Self::NeedsPermission
                | Self::Blocked
                | Self::IdleButNotDone
                | Self::Failed
        )
    }

    pub fn as_wire_value(self) -> &'static str {
        match self {
            Self::Queued => "queued",
            Self::Starting => "starting",
            Self::Running => "running",
            Self::Thinking => "thinking",
            Self::ExecutingTool => "executing_tool",
            Self::WaitingForInput => "waiting_for_input",
            Self::NeedsPermission => "needs_permission",
            Self::Blocked => "blocked",
            Self::IdleButNotDone => "idle_but_not_done",
            Self::Completed => "completed",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
            Self::Stale => "stale",
            Self::Unknown => "unknown",
        }
    }
}

impl Display for TaskStatus {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_wire_value())
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash, Serialize, Deserialize, JsonSchema)]
pub enum TaskPriority {
    #[serde(rename = "P0")]
    P0,
    #[serde(rename = "P1")]
    P1,
    #[serde(rename = "P2")]
    #[default]
    P2,
    #[serde(rename = "P3")]
    P3,
}

impl TaskPriority {
    pub fn as_wire_value(self) -> &'static str {
        match self {
            Self::P0 => "P0",
            Self::P1 => "P1",
            Self::P2 => "P2",
            Self::P3 => "P3",
        }
    }
}

impl Display for TaskPriority {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_wire_value())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum NotificationTarget {
    Desktop,
    Telegram,
    Slack,
    Discord,
    Email,
    Ntfy,
    Pushover,
    Webhook,
    Feishu,
    Wecom,
    Dingtalk,
    Bark,
    ServerChan,
    Custom(String),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum TaskActionType {
    OpenBrowserTab,
    OpenTerminalSession,
    OpenTmuxPane,
    OpenItermWindow,
    OpenWarpSession,
    OpenVscodeWorkspace,
    OpenCursorComposer,
    OpenGithubPr,
    OpenSlackThread,
    OpenNotionPage,
    OpenFile,
    OpenUrl,
    Custom(String),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct TaskAction {
    pub label: String,
    #[serde(rename = "type")]
    pub action_type: TaskActionType,
    pub target: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app_bundle_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line_number: Option<u32>,
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub metadata: Map<String, Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct AgentTaskEvent {
    pub event_id: String,
    pub task_id: String,
    pub source: TaskSource,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window_title: Option<String>,
    pub title: String,
    pub status: TaskStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub step: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    #[serde(default = "default_confidence")]
    pub confidence: f32,
    #[serde(default)]
    pub priority: TaskPriority,
    #[serde(default = "default_true")]
    pub notify_desktop: bool,
    #[serde(default = "default_true")]
    pub notify_external: bool,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub actions: Vec<TaskAction>,
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub metadata: Map<String, Value>,
}

impl AgentTaskEvent {
    pub fn new(
        task_id: impl Into<String>,
        source: impl Into<String>,
        title: impl Into<String>,
        status: TaskStatus,
    ) -> Self {
        let now = Utc::now();
        Self {
            event_id: format!("evt_{}", Uuid::new_v4()),
            task_id: task_id.into(),
            source: TaskSource::new(source),
            app: None,
            workspace: None,
            session_name: None,
            window_title: None,
            title: title.into(),
            status,
            step: None,
            message: None,
            confidence: default_confidence(),
            priority: TaskPriority::default(),
            notify_desktop: true,
            notify_external: true,
            created_at: now,
            updated_at: now,
            actions: Vec::new(),
            metadata: Map::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct AgentTask {
    pub task_id: String,
    pub source: TaskSource,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window_title: Option<String>,
    pub title: String,
    pub status: TaskStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub step: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    pub confidence: f32,
    pub priority: TaskPriority,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub last_event_id: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub actions: Vec<TaskAction>,
    #[serde(default)]
    pub event_count: u64,
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub metadata: Map<String, Value>,
}

impl AgentTask {
    pub fn from_event(event: &AgentTaskEvent) -> Self {
        Self {
            task_id: event.task_id.clone(),
            source: event.source.clone(),
            app: event.app.clone(),
            workspace: event.workspace.clone(),
            session_name: event.session_name.clone(),
            window_title: event.window_title.clone(),
            title: event.title.clone(),
            status: event.status,
            step: event.step.clone(),
            message: event.message.clone(),
            confidence: event.confidence,
            priority: event.priority,
            created_at: event.created_at,
            updated_at: event.updated_at,
            last_event_id: event.event_id.clone(),
            actions: event.actions.clone(),
            event_count: 1,
            metadata: event.metadata.clone(),
        }
    }

    pub fn merge_event(mut self, event: &AgentTaskEvent) -> Self {
        self.source = event.source.clone();
        if event.app.is_some() {
            self.app = event.app.clone();
        }
        if event.workspace.is_some() {
            self.workspace = event.workspace.clone();
        }
        if event.session_name.is_some() {
            self.session_name = event.session_name.clone();
        }
        if event.window_title.is_some() {
            self.window_title = event.window_title.clone();
        }
        if !event.title.trim().is_empty() {
            self.title = event.title.clone();
        }
        self.status = event.status;
        if event.step.is_some() {
            self.step = event.step.clone();
        }
        if event.message.is_some() {
            self.message = event.message.clone();
        }
        self.confidence = event.confidence;
        self.priority = event.priority;
        self.updated_at = event.updated_at;
        self.last_event_id = event.event_id.clone();
        if !event.actions.is_empty() {
            self.actions = event.actions.clone();
        }
        if !event.metadata.is_empty() {
            for (key, value) in &event.metadata {
                self.metadata.insert(key.clone(), value.clone());
            }
        }
        self.event_count += 1;
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct TaskDetail {
    pub task: AgentTask,
    pub events: Vec<AgentTaskEvent>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub deliveries: Vec<NotificationDelivery>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum LiveMessage {
    TaskUpdated {
        event: Box<AgentTaskEvent>,
        task: Box<AgentTask>,
    },
    TaskDeleted {
        task_id: String,
    },
    NotificationDelivered {
        delivery: NotificationDelivery,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct NotificationDelivery {
    pub delivery_id: String,
    pub event_id: String,
    pub task_id: String,
    pub provider_id: String,
    pub status: DeliveryStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    pub created_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum DeliveryStatus {
    Pending,
    Sent,
    Skipped,
    Failed,
}

fn default_confidence() -> f32 {
    1.0
}

fn default_true() -> bool {
    true
}
