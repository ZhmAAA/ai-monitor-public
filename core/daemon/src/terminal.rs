use ai_monitor_protocol::{AgentTaskEvent, TaskAction, TaskActionType, TaskPriority, TaskStatus};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::{
    collections::hash_map::DefaultHasher,
    hash::{Hash, Hasher},
    path::PathBuf,
};

#[derive(Debug, Default, Deserialize)]
pub struct TerminalEventRequest {
    #[serde(default)]
    source: Option<String>,
    #[serde(default, alias = "taskId")]
    task_id: Option<String>,
    #[serde(default)]
    workspace: Option<String>,
    #[serde(default, alias = "sessionName")]
    session_name: Option<String>,
    #[serde(default, alias = "windowTitle")]
    window_title: Option<String>,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    status: Option<TaskStatus>,
    #[serde(default)]
    step: Option<String>,
    #[serde(default)]
    message: Option<String>,
    #[serde(default)]
    command: Option<String>,
    #[serde(default)]
    target: Option<String>,
    #[serde(default)]
    pid: Option<i64>,
    #[serde(default, alias = "terminalProgram")]
    terminal_program: Option<String>,
    #[serde(default, alias = "termSessionId")]
    term_session_id: Option<String>,
    #[serde(default, alias = "tmuxPane")]
    tmux_pane: Option<String>,
    #[serde(default)]
    confidence: Option<f32>,
    #[serde(default)]
    priority: Option<TaskPriority>,
    #[serde(default, alias = "notifyDesktop")]
    notify_desktop: Option<bool>,
    #[serde(default, alias = "notifyExternal")]
    notify_external: Option<bool>,
    #[serde(default)]
    metadata: Map<String, Value>,
}

pub fn build_terminal_event(request: TerminalEventRequest) -> Result<AgentTaskEvent, String> {
    let source = non_empty(request.source).unwrap_or_else(|| "terminal".to_string());
    let workspace = non_empty(request.workspace);
    let session_name = non_empty(request.session_name).or_else(|| {
        infer_terminal_session_name(
            &source,
            workspace.as_deref(),
            request.tmux_pane.as_deref(),
            request.term_session_id.as_deref(),
        )
    });
    let window_title = non_empty(request.window_title).or_else(|| {
        session_name.as_deref().map(|session| {
            format!(
                "{} - {session}",
                terminal_program_label(request.terminal_program.as_deref())
            )
        })
    });
    let command = non_empty(request.command);
    let title = non_empty(request.title)
        .or_else(|| command.clone())
        .or_else(|| session_name.clone())
        .unwrap_or_else(|| "Terminal task".to_string());
    let status = request.status.unwrap_or(TaskStatus::Running);
    let task_id = non_empty(request.task_id).unwrap_or_else(|| {
        stable_terminal_task_id(
            &source,
            workspace.as_deref(),
            session_name.as_deref(),
            command.as_deref(),
        )
    });
    let target = non_empty(request.target);
    let terminal_program = non_empty(request.terminal_program);
    let term_session_id = non_empty(request.term_session_id);
    let tmux_pane = non_empty(request.tmux_pane);

    let mut event = AgentTaskEvent::new(task_id, source, title, status);
    event.app = Some("terminal".to_string());
    event.workspace = workspace.clone();
    event.session_name = session_name;
    event.window_title = window_title;
    event.step = non_empty(request.step).or_else(|| Some(status_to_step(status).to_string()));
    event.message = non_empty(request.message).or_else(|| {
        command
            .as_deref()
            .map(|command| format!("Terminal command: {command}"))
    });
    event.confidence = request.confidence.unwrap_or(0.98);
    event.priority = request
        .priority
        .unwrap_or_else(|| default_priority_for_status(status));
    event.notify_desktop = request.notify_desktop.unwrap_or(true);
    event.notify_external = request.notify_external.unwrap_or(true);

    let mut metadata = request.metadata;
    insert_metadata(&mut metadata, "command", command.clone())?;
    insert_metadata(&mut metadata, "pid", request.pid)?;
    insert_metadata(&mut metadata, "terminal_program", terminal_program.clone())?;
    insert_metadata(&mut metadata, "term_session_id", term_session_id.clone())?;
    insert_metadata(&mut metadata, "tmux_pane", tmux_pane.clone())?;
    metadata
        .entry("adapter_version".to_string())
        .or_insert_with(|| Value::String("terminal-api-0.1.0".to_string()));
    event.metadata = metadata;

    event.actions = terminal_actions(
        target.as_deref(),
        workspace.as_deref(),
        request.pid,
        tmux_pane.as_deref(),
        term_session_id.as_deref(),
    )?;

    Ok(event)
}

fn terminal_actions(
    target: Option<&str>,
    workspace: Option<&str>,
    pid: Option<i64>,
    tmux_pane: Option<&str>,
    term_session_id: Option<&str>,
) -> Result<Vec<TaskAction>, String> {
    let mut action_metadata = Map::new();
    insert_metadata(&mut action_metadata, "pid", pid)?;
    insert_metadata(
        &mut action_metadata,
        "tmux_pane",
        tmux_pane.map(ToOwned::to_owned),
    )?;
    insert_metadata(
        &mut action_metadata,
        "term_session_id",
        term_session_id.map(ToOwned::to_owned),
    )?;

    let target = target.unwrap_or_default();
    let mut actions = vec![TaskAction {
        label: "Open terminal".to_string(),
        action_type: terminal_action_type(target, tmux_pane),
        target: target.to_string(),
        app_bundle_id: None,
        file_path: None,
        line_number: None,
        metadata: action_metadata,
    }];

    if let Some(workspace) = workspace {
        actions.push(TaskAction {
            label: "Open workspace".to_string(),
            action_type: TaskActionType::OpenUrl,
            target: format!("file://{workspace}"),
            app_bundle_id: None,
            file_path: Some(workspace.to_string()),
            line_number: None,
            metadata: Map::new(),
        });
    }

    Ok(actions)
}

fn terminal_action_type(target: &str, tmux_pane: Option<&str>) -> TaskActionType {
    let normalized = target.to_ascii_lowercase();
    if normalized.starts_with("iterm") {
        TaskActionType::OpenItermWindow
    } else if normalized.starts_with("warp") {
        TaskActionType::OpenWarpSession
    } else if normalized.starts_with("tmux") || tmux_pane.is_some() {
        TaskActionType::OpenTmuxPane
    } else {
        TaskActionType::OpenTerminalSession
    }
}

fn infer_terminal_session_name(
    source: &str,
    workspace: Option<&str>,
    tmux_pane: Option<&str>,
    term_session_id: Option<&str>,
) -> Option<String> {
    if let Some(tmux_pane) = non_empty_ref(tmux_pane) {
        return Some(format!("{source}:{tmux_pane}"));
    }
    if let Some(term_session_id) = non_empty_ref(term_session_id) {
        let suffix = term_session_id
            .char_indices()
            .rev()
            .nth(7)
            .map(|(index, _)| &term_session_id[index..])
            .unwrap_or(term_session_id);
        return Some(format!("{source}:{suffix}"));
    }
    if let Some(workspace) = non_empty_ref(workspace) {
        let name = PathBuf::from(workspace)
            .file_name()
            .and_then(|value| value.to_str())
            .unwrap_or(workspace)
            .to_string();
        return Some(format!("{source}:{name}"));
    }
    None
}

fn terminal_program_label(value: Option<&str>) -> String {
    non_empty_ref(value)
        .map(|value| value.replace('_', " "))
        .unwrap_or_else(|| "Terminal".to_string())
}

fn stable_terminal_task_id(
    source: &str,
    workspace: Option<&str>,
    session_name: Option<&str>,
    command: Option<&str>,
) -> String {
    let mut hasher = DefaultHasher::new();
    source.hash(&mut hasher);
    workspace.unwrap_or_default().hash(&mut hasher);
    session_name.unwrap_or_default().hash(&mut hasher);
    command.unwrap_or_default().hash(&mut hasher);
    format!(
        "terminal_{}_{}",
        sanitize_identifier(source),
        hasher.finish()
    )
}

fn sanitize_identifier(value: &str) -> String {
    let sanitized: String = value
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || character == '_' || character == '-' {
                character
            } else {
                '_'
            }
        })
        .collect();
    if sanitized.is_empty() {
        "terminal".to_string()
    } else {
        sanitized
    }
}

fn default_priority_for_status(status: TaskStatus) -> TaskPriority {
    if status.needs_attention() {
        TaskPriority::P0
    } else if status == TaskStatus::Completed {
        TaskPriority::P1
    } else {
        TaskPriority::P2
    }
}

fn status_to_step(status: TaskStatus) -> &'static str {
    match status {
        TaskStatus::Queued => "Queued",
        TaskStatus::Starting => "Starting",
        TaskStatus::Running => "Running",
        TaskStatus::Thinking => "Thinking",
        TaskStatus::ExecutingTool => "Executing tool",
        TaskStatus::WaitingForInput => "Waiting for input",
        TaskStatus::NeedsPermission => "Needs permission",
        TaskStatus::Blocked => "Blocked",
        TaskStatus::IdleButNotDone => "Idle but not done",
        TaskStatus::Completed => "Completed",
        TaskStatus::Failed => "Failed",
        TaskStatus::Cancelled => "Cancelled",
        TaskStatus::Stale => "Stale",
        TaskStatus::Unknown => "Unknown",
    }
}

fn non_empty(value: Option<String>) -> Option<String> {
    value
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn non_empty_ref(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|value| !value.is_empty())
}

fn insert_metadata<T: Serialize>(
    metadata: &mut Map<String, Value>,
    key: &str,
    value: Option<T>,
) -> Result<(), String> {
    if let Some(value) = value {
        metadata.insert(
            key.to_string(),
            serde_json::to_value(value)
                .map_err(|error| format!("invalid metadata `{key}`: {error}"))?,
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn builds_terminal_event_from_compact_request() {
        let event = build_terminal_event(TerminalEventRequest {
            source: Some("codex-cli".to_string()),
            workspace: Some("/tmp/ai-monitor".to_string()),
            session_name: Some("Daemon tests".to_string()),
            status: Some(TaskStatus::ExecutingTool),
            command: Some("cargo test".to_string()),
            pid: Some(42),
            tmux_pane: Some("%1".to_string()),
            ..TerminalEventRequest::default()
        })
        .unwrap();

        assert_eq!(event.source.as_str(), "codex-cli");
        assert_eq!(event.app.as_deref(), Some("terminal"));
        assert_eq!(event.workspace.as_deref(), Some("/tmp/ai-monitor"));
        assert_eq!(event.title, "cargo test");
        assert_eq!(event.status, TaskStatus::ExecutingTool);
        assert_eq!(event.priority, TaskPriority::P2);
        assert_eq!(event.actions[0].action_type, TaskActionType::OpenTmuxPane);
        assert_eq!(event.actions[1].target, "file:///tmp/ai-monitor");
        assert_eq!(
            event.metadata["command"],
            Value::String("cargo test".to_string())
        );
        assert_eq!(event.metadata["pid"], json!(42));
    }

    #[test]
    fn terminal_task_id_is_stable_per_command_context() {
        let first = build_terminal_event(TerminalEventRequest {
            source: Some("terminal".to_string()),
            workspace: Some("/tmp/ai-monitor".to_string()),
            session_name: Some("Tests".to_string()),
            command: Some("cargo test".to_string()),
            ..TerminalEventRequest::default()
        })
        .unwrap();
        let second = build_terminal_event(TerminalEventRequest {
            source: Some("terminal".to_string()),
            workspace: Some("/tmp/ai-monitor".to_string()),
            session_name: Some("Tests".to_string()),
            command: Some("cargo test".to_string()),
            ..TerminalEventRequest::default()
        })
        .unwrap();
        let different_command = build_terminal_event(TerminalEventRequest {
            source: Some("terminal".to_string()),
            workspace: Some("/tmp/ai-monitor".to_string()),
            session_name: Some("Tests".to_string()),
            command: Some("cargo clippy".to_string()),
            ..TerminalEventRequest::default()
        })
        .unwrap();

        assert_eq!(first.task_id, second.task_id);
        assert_ne!(first.task_id, different_command.task_id);
    }
}
