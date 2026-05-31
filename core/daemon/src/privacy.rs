use ai_monitor_protocol::{AgentTask, AgentTaskEvent, TaskAction};
use serde::Deserialize;
use serde_json::{Map, Value};
use std::path::Path;

#[derive(Debug, Clone, Deserialize)]
pub struct PrivacyConfig {
    #[serde(default = "default_true")]
    pub redact_external_workspace_paths: bool,
    #[serde(default = "default_true")]
    pub redact_external_prompts: bool,
    #[serde(default = "default_true")]
    pub redact_external_replies: bool,
    #[serde(default)]
    pub redact_storage_prompts: bool,
    #[serde(default)]
    pub redact_storage_replies: bool,
}

impl Default for PrivacyConfig {
    fn default() -> Self {
        Self {
            redact_external_workspace_paths: true,
            redact_external_prompts: true,
            redact_external_replies: true,
            redact_storage_prompts: false,
            redact_storage_replies: false,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct IgnoreRule {
    #[serde(default)]
    pub id: Option<String>,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default)]
    pub mode: IgnoreMode,
    #[serde(default)]
    pub app: Option<String>,
    #[serde(default)]
    pub source: Option<String>,
    #[serde(default)]
    pub site_contains: Option<String>,
    #[serde(default)]
    pub workspace_prefix: Option<String>,
    #[serde(default)]
    pub workspace_contains: Option<String>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum IgnoreMode {
    #[default]
    Ignore,
    LocalOnly,
}

#[derive(Debug, Clone)]
pub struct PrivacyFilter {
    config: PrivacyConfig,
    ignore_rules: Vec<IgnoreRule>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IngressDecision {
    Accept,
    Ignored { rule_id: String },
}

impl PrivacyFilter {
    pub fn new(config: PrivacyConfig, ignore_rules: Vec<IgnoreRule>) -> Self {
        Self {
            config,
            ignore_rules,
        }
    }

    pub fn apply_ingress(&self, event: &mut AgentTaskEvent) -> IngressDecision {
        for rule in &self.ignore_rules {
            if !rule.enabled || !rule.matches(event) {
                continue;
            }

            let rule_id = rule.id();
            match rule.mode {
                IgnoreMode::Ignore => {
                    return IngressDecision::Ignored { rule_id };
                }
                IgnoreMode::LocalOnly => {
                    event.notify_external = false;
                    event
                        .metadata
                        .insert("privacy_rule".to_string(), Value::String(rule_id));
                }
            }
        }

        if self.config.redact_storage_prompts {
            redact_metadata(&mut event.metadata, true, false, false);
        }
        if self.config.redact_storage_replies {
            redact_metadata(&mut event.metadata, false, true, false);
        }

        IngressDecision::Accept
    }

    pub fn redact_for_external(
        &self,
        event: &AgentTaskEvent,
        task: &AgentTask,
    ) -> (AgentTaskEvent, AgentTask) {
        let mut event = event.clone();
        let mut task = task.clone();

        if self.config.redact_external_workspace_paths {
            event.workspace = event.workspace.as_deref().map(redact_workspace_path);
            task.workspace = task.workspace.as_deref().map(redact_workspace_path);
            redact_actions(&mut event.actions);
            redact_actions(&mut task.actions);
            redact_metadata(&mut event.metadata, false, false, true);
            redact_metadata(&mut task.metadata, false, false, true);
        }

        if self.config.redact_external_prompts {
            let had_prompt =
                metadata_has_prompt(&event.metadata) || metadata_has_prompt(&task.metadata);
            redact_metadata(&mut event.metadata, true, false, false);
            redact_metadata(&mut task.metadata, true, false, false);
            if had_prompt {
                event.title = "AI task".to_string();
                task.title = "AI task".to_string();
                event.session_name = Some("AI task".to_string());
                task.session_name = Some("AI task".to_string());
                event.window_title = Some("AI task".to_string());
                task.window_title = Some("AI task".to_string());
                event.message = Some("Prompt redacted".to_string());
                task.message = Some("Prompt redacted".to_string());
            }
        }

        if self.config.redact_external_replies {
            let had_reply =
                metadata_has_reply(&event.metadata) || metadata_has_reply(&task.metadata);
            redact_metadata(&mut event.metadata, false, true, false);
            redact_metadata(&mut task.metadata, false, true, false);
            if had_reply {
                event.message = Some("Assistant reply redacted".to_string());
                task.message = Some("Assistant reply redacted".to_string());
            }
        }

        (event, task)
    }
}

impl IgnoreRule {
    fn id(&self) -> String {
        self.id.clone().unwrap_or_else(|| "unnamed".to_string())
    }

    fn matches(&self, event: &AgentTaskEvent) -> bool {
        let mut has_condition = false;

        if let Some(expected) = &self.app {
            has_condition = true;
            if event
                .app
                .as_deref()
                .map(|app| !app.eq_ignore_ascii_case(expected))
                .unwrap_or(true)
            {
                return false;
            }
        }

        if let Some(expected) = &self.source {
            has_condition = true;
            if !event.source.as_str().eq_ignore_ascii_case(expected) {
                return false;
            }
        }

        if let Some(expected) = &self.workspace_prefix {
            has_condition = true;
            if event
                .workspace
                .as_deref()
                .map(|workspace| !workspace.starts_with(expected))
                .unwrap_or(true)
            {
                return false;
            }
        }

        if let Some(expected) = &self.workspace_contains {
            has_condition = true;
            if event
                .workspace
                .as_deref()
                .map(|workspace| !workspace.contains(expected))
                .unwrap_or(true)
            {
                return false;
            }
        }

        if let Some(expected) = &self.site_contains {
            has_condition = true;
            if !event_url_candidates(event).any(|value| value.contains(expected)) {
                return false;
            }
        }

        has_condition
    }
}

fn event_url_candidates(event: &AgentTaskEvent) -> impl Iterator<Item = String> + '_ {
    event
        .metadata
        .get("url")
        .and_then(Value::as_str)
        .into_iter()
        .map(ToOwned::to_owned)
        .chain(event.actions.iter().map(|action| action.target.clone()))
}

fn redact_workspace_path(value: &str) -> String {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return "[redacted workspace]".to_string();
    }
    Path::new(trimmed)
        .file_name()
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty())
        .unwrap_or("[redacted workspace]")
        .to_string()
}

fn redact_actions(actions: &mut [TaskAction]) {
    for action in actions {
        if action.target.starts_with("file://") || action.target.starts_with('/') {
            action.target = "file://[redacted]".to_string();
        }
        action.file_path = None;
    }
}

fn redact_metadata(
    metadata: &mut Map<String, Value>,
    redact_prompts: bool,
    redact_replies: bool,
    redact_paths: bool,
) {
    for (key, value) in metadata.iter_mut() {
        let normalized = key.to_ascii_lowercase();
        redact_value_for_key(
            &normalized,
            value,
            redact_prompts,
            redact_replies,
            redact_paths,
        );
    }
}

fn metadata_has_prompt(metadata: &Map<String, Value>) -> bool {
    metadata_has_matching_key(metadata, key_is_prompt)
}

fn metadata_has_reply(metadata: &Map<String, Value>) -> bool {
    metadata_has_matching_key(metadata, key_is_reply)
}

fn redact_value_for_key(
    normalized_key: &str,
    value: &mut Value,
    redact_prompts: bool,
    redact_replies: bool,
    redact_paths: bool,
) {
    let should_redact = (redact_prompts && key_is_prompt(normalized_key))
        || (redact_replies && key_is_reply(normalized_key))
        || (redact_paths && key_is_path(normalized_key));
    if should_redact {
        *value = Value::String("[redacted]".to_string());
        return;
    }

    match value {
        Value::Object(object) => {
            redact_metadata(object, redact_prompts, redact_replies, redact_paths);
        }
        Value::Array(values) => {
            for value in values {
                match value {
                    Value::Object(object) => {
                        redact_metadata(object, redact_prompts, redact_replies, redact_paths);
                    }
                    Value::Array(_) => {
                        redact_value_for_key(
                            "",
                            value,
                            redact_prompts,
                            redact_replies,
                            redact_paths,
                        );
                    }
                    _ => {}
                }
            }
        }
        _ => {}
    }
}

fn metadata_has_matching_key(metadata: &Map<String, Value>, predicate: fn(&str) -> bool) -> bool {
    metadata.iter().any(|(key, value)| {
        predicate(&key.to_ascii_lowercase()) || value_has_matching_key(value, predicate)
    })
}

fn value_has_matching_key(value: &Value, predicate: fn(&str) -> bool) -> bool {
    match value {
        Value::Object(object) => metadata_has_matching_key(object, predicate),
        Value::Array(values) => values
            .iter()
            .any(|value| value_has_matching_key(value, predicate)),
        _ => false,
    }
}

fn key_is_prompt(key: &str) -> bool {
    key.contains("prompt") || key == "input" || key == "input_message"
}

fn key_is_reply(key: &str) -> bool {
    key.contains("reply") || key.contains("assistant_message") || key.contains("assistant_reply")
}

fn key_is_path(key: &str) -> bool {
    key.contains("path") || key == "workspace" || key == "transcript"
}

fn default_true() -> bool {
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use ai_monitor_protocol::{TaskSource, TaskStatus};
    use serde_json::json;

    #[test]
    fn ignore_rule_drops_matching_workspace() {
        let filter = PrivacyFilter::new(
            PrivacyConfig::default(),
            vec![IgnoreRule {
                id: Some("secrets".to_string()),
                workspace_prefix: Some("/secret".to_string()),
                ..ignore_rule()
            }],
        );
        let mut event = AgentTaskEvent::new("task", "codex-cli", "title", TaskStatus::Running);
        event.workspace = Some("/secret/project".to_string());

        assert_eq!(
            filter.apply_ingress(&mut event),
            IngressDecision::Ignored {
                rule_id: "secrets".to_string()
            }
        );
    }

    #[test]
    fn local_only_rule_disables_external_delivery() {
        let filter = PrivacyFilter::new(
            PrivacyConfig::default(),
            vec![IgnoreRule {
                id: Some("local".to_string()),
                mode: IgnoreMode::LocalOnly,
                source: Some("codex-cli".to_string()),
                ..ignore_rule()
            }],
        );
        let mut event = AgentTaskEvent::new("task", "codex-cli", "title", TaskStatus::Running);

        assert_eq!(filter.apply_ingress(&mut event), IngressDecision::Accept);
        assert!(!event.notify_external);
        assert_eq!(event.metadata["privacy_rule"], json!("local"));
    }

    #[test]
    fn ignore_rule_matches_app_name() {
        let filter = PrivacyFilter::new(
            PrivacyConfig::default(),
            vec![IgnoreRule {
                id: Some("cursor".to_string()),
                app: Some("Cursor".to_string()),
                ..ignore_rule()
            }],
        );
        let mut event = AgentTaskEvent::new("task", "cursor", "title", TaskStatus::Running);
        event.app = Some("cursor".to_string());

        assert_eq!(
            filter.apply_ingress(&mut event),
            IngressDecision::Ignored {
                rule_id: "cursor".to_string()
            }
        );
    }

    #[test]
    fn ignore_rule_matches_site_candidates() {
        let filter = PrivacyFilter::new(
            PrivacyConfig::default(),
            vec![IgnoreRule {
                id: Some("private-site".to_string()),
                site_contains: Some("private.example".to_string()),
                ..ignore_rule()
            }],
        );
        let mut event = AgentTaskEvent::new("task", "chatgpt-web", "title", TaskStatus::Running);
        event
            .metadata
            .insert("url".to_string(), json!("https://private.example/chat"));

        assert_eq!(
            filter.apply_ingress(&mut event),
            IngressDecision::Ignored {
                rule_id: "private-site".to_string()
            }
        );
    }

    #[test]
    fn external_redaction_removes_prompt_reply_and_paths() {
        let filter = PrivacyFilter::new(PrivacyConfig::default(), Vec::new());
        let mut event =
            AgentTaskEvent::new("task", "codex-cli", "Fix secret", TaskStatus::Completed);
        event.workspace = Some("/Users/example/secret-project".to_string());
        event.session_name = Some("Fix secret".to_string());
        event.window_title = Some("Fix secret - Chrome".to_string());
        event.message = Some("Original reply".to_string());
        event
            .metadata
            .insert("prompt".to_string(), json!("secret prompt"));
        event
            .metadata
            .insert("last_assistant_message".to_string(), json!("secret reply"));
        event.metadata.insert(
            "tool_input".to_string(),
            json!({
                "nested_prompt": "nested secret prompt",
                "messages": [
                    {
                        "assistant_reply": "nested secret reply",
                        "transcript_path": "/tmp/nested-transcript.jsonl"
                    }
                ]
            }),
        );
        event.metadata.insert(
            "transcript_path".to_string(),
            json!("/tmp/transcript.jsonl"),
        );

        let task = AgentTask {
            task_id: event.task_id.clone(),
            source: TaskSource::new("codex-cli"),
            app: None,
            workspace: event.workspace.clone(),
            session_name: None,
            window_title: None,
            title: event.title.clone(),
            status: event.status,
            step: event.step.clone(),
            message: event.message.clone(),
            confidence: event.confidence,
            priority: event.priority,
            created_at: event.created_at,
            updated_at: event.updated_at,
            last_event_id: event.event_id.clone(),
            actions: Vec::new(),
            event_count: 1,
            metadata: event.metadata.clone(),
        };

        let (event, task) = filter.redact_for_external(&event, &task);
        assert_eq!(event.workspace.as_deref(), Some("secret-project"));
        assert_eq!(task.title, "AI task");
        assert_eq!(event.session_name.as_deref(), Some("AI task"));
        assert_eq!(task.session_name.as_deref(), Some("AI task"));
        assert_eq!(event.window_title.as_deref(), Some("AI task"));
        assert_eq!(task.window_title.as_deref(), Some("AI task"));
        assert_eq!(event.metadata["prompt"], json!("[redacted]"));
        assert_eq!(
            event.metadata["last_assistant_message"],
            json!("[redacted]")
        );
        assert_eq!(
            event.metadata["tool_input"]["nested_prompt"],
            json!("[redacted]")
        );
        assert_eq!(
            event.metadata["tool_input"]["messages"][0]["assistant_reply"],
            json!("[redacted]")
        );
        assert_eq!(
            event.metadata["tool_input"]["messages"][0]["transcript_path"],
            json!("[redacted]")
        );
        assert_eq!(event.metadata["transcript_path"], json!("[redacted]"));
    }

    fn ignore_rule() -> IgnoreRule {
        IgnoreRule {
            id: None,
            enabled: true,
            mode: IgnoreMode::Ignore,
            app: None,
            source: None,
            site_contains: None,
            workspace_prefix: None,
            workspace_contains: None,
        }
    }
}
