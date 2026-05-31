use ai_monitor_protocol::{AgentTask, AgentTaskEvent, TaskPriority, TaskSource, TaskStatus};
use async_trait::async_trait;
use chrono::{Local, NaiveTime};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::path::Path;
#[cfg(target_os = "macos")]
use std::process::Command;
use std::sync::Arc;
use thiserror::Error;

pub mod providers;

#[derive(Debug, Error)]
pub enum NotificationError {
    #[error("configuration error: {0}")]
    Config(String),
    #[error("http error: {0}")]
    Http(#[from] reqwest::Error),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("toml error: {0}")]
    Toml(#[from] toml::de::Error),
    #[error("provider `{provider_id}` is not available")]
    ProviderUnavailable { provider_id: String },
    #[error("provider `{provider_id}` failed: {message}")]
    ProviderFailed {
        provider_id: String,
        message: String,
    },
}

pub type Result<T> = std::result::Result<T, NotificationError>;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderKind {
    Desktop,
    Telegram,
    Slack,
    Discord,
    Email,
    Ntfy,
    Pushover,
    Bark,
    Feishu,
    Wecom,
    Dingtalk,
    ServerChan,
    Webhook,
}

impl ProviderKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Desktop => "desktop",
            Self::Telegram => "telegram",
            Self::Slack => "slack",
            Self::Discord => "discord",
            Self::Email => "email",
            Self::Ntfy => "ntfy",
            Self::Pushover => "pushover",
            Self::Bark => "bark",
            Self::Feishu => "feishu",
            Self::Wecom => "wecom",
            Self::Dingtalk => "dingtalk",
            Self::ServerChan => "server_chan",
            Self::Webhook => "webhook",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NotificationConfig {
    #[serde(default)]
    pub providers: Vec<ProviderConfig>,
    #[serde(default)]
    pub rules: Vec<NotificationRule>,
    #[serde(default)]
    pub quiet_hours: Option<QuietHours>,
}

impl NotificationConfig {
    pub fn from_toml_str(input: &str) -> Result<Self> {
        Ok(toml::from_str(input)?)
    }

    pub fn load(path: impl AsRef<Path>) -> Result<Self> {
        let input = std::fs::read_to_string(path)?;
        Self::from_toml_str(&input)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderConfig {
    pub id: String,
    #[serde(rename = "type")]
    pub provider_type: ProviderKind,
    #[serde(default)]
    pub enabled: bool,
    #[serde(flatten)]
    pub settings: HashMap<String, String>,
}

impl ProviderConfig {
    pub fn setting(&self, key: &str) -> Option<String> {
        self.settings
            .get(key)
            .map(|value| resolve_env_placeholder(value))
    }

    pub fn secret_setting(&self, key: &str) -> Result<Option<String>> {
        self.settings
            .get(key)
            .map(|value| resolve_secret_value(value))
            .transpose()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NotificationRule {
    #[serde(default)]
    pub status: Option<TaskStatus>,
    #[serde(default)]
    pub priority: Option<TaskPriority>,
    #[serde(default)]
    pub source: Option<TaskSource>,
    #[serde(default)]
    pub workspace_contains: Option<String>,
    #[serde(default)]
    pub send_to: Vec<String>,
}

impl NotificationRule {
    pub fn matches(&self, event: &AgentTaskEvent, task: &AgentTask) -> bool {
        if let Some(status) = self.status {
            if event.status != status {
                return false;
            }
        }
        if let Some(priority) = self.priority {
            if event.priority != priority {
                return false;
            }
        }
        if let Some(source) = &self.source {
            if event.source != *source {
                return false;
            }
        }
        if let Some(needle) = &self.workspace_contains {
            let matches = task
                .workspace
                .as_deref()
                .map(|workspace| workspace.contains(needle))
                .unwrap_or(false);
            if !matches {
                return false;
            }
        }
        true
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QuietHours {
    #[serde(default)]
    pub enabled: bool,
    pub start: String,
    pub end: String,
    #[serde(default)]
    pub allow_priorities: Vec<TaskPriority>,
}

impl QuietHours {
    pub fn suppresses(&self, priority: TaskPriority) -> bool {
        if !self.enabled {
            return false;
        }
        if self.allow_priorities.contains(&priority) {
            return false;
        }

        let Ok(start) = NaiveTime::parse_from_str(&self.start, "%H:%M") else {
            return false;
        };
        let Ok(end) = NaiveTime::parse_from_str(&self.end, "%H:%M") else {
            return false;
        };

        let now = Local::now().time();
        if start <= end {
            now >= start && now < end
        } else {
            now >= start || now < end
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderSendResult {
    pub provider_id: String,
    pub provider_type: ProviderKind,
    pub message: String,
}

#[async_trait]
pub trait NotificationProvider: Send + Sync {
    fn id(&self) -> &str;
    fn kind(&self) -> ProviderKind;
    async fn send(&self, event: &AgentTaskEvent, task: &AgentTask) -> Result<ProviderSendResult>;
    async fn validate_config(&self) -> Result<()>;
    async fn test_connection(&self) -> Result<ProviderSendResult>;
}

#[derive(Clone)]
pub struct NotificationEngine {
    config: NotificationConfig,
    providers: Arc<HashMap<String, Arc<dyn NotificationProvider>>>,
    provider_errors: Arc<HashMap<String, ProviderInitError>>,
}

#[derive(Debug, Clone)]
struct ProviderInitError {
    provider_type: ProviderKind,
    message: String,
}

fn build_provider(
    provider_config: &ProviderConfig,
    client: &Client,
) -> Result<Arc<dyn NotificationProvider>> {
    match provider_config.provider_type {
        ProviderKind::Desktop => providers::DesktopProvider::from_config(provider_config)
            .map(|provider| Arc::new(provider) as Arc<dyn NotificationProvider>),
        ProviderKind::Telegram => {
            providers::TelegramProvider::from_config(provider_config, client.clone())
                .map(|provider| Arc::new(provider) as Arc<dyn NotificationProvider>)
        }
        ProviderKind::Slack => {
            providers::SlackProvider::from_config(provider_config, client.clone())
                .map(|provider| Arc::new(provider) as Arc<dyn NotificationProvider>)
        }
        ProviderKind::Discord => {
            providers::DiscordProvider::from_config(provider_config, client.clone())
                .map(|provider| Arc::new(provider) as Arc<dyn NotificationProvider>)
        }
        ProviderKind::Email => providers::EmailProvider::from_config(provider_config)
            .map(|provider| Arc::new(provider) as Arc<dyn NotificationProvider>),
        ProviderKind::Ntfy => providers::NtfyProvider::from_config(provider_config, client.clone())
            .map(|provider| Arc::new(provider) as Arc<dyn NotificationProvider>),
        ProviderKind::Pushover => {
            providers::PushoverProvider::from_config(provider_config, client.clone())
                .map(|provider| Arc::new(provider) as Arc<dyn NotificationProvider>)
        }
        ProviderKind::Bark => providers::BarkProvider::from_config(provider_config, client.clone())
            .map(|provider| Arc::new(provider) as Arc<dyn NotificationProvider>),
        ProviderKind::Feishu => {
            providers::FeishuProvider::from_config(provider_config, client.clone())
                .map(|provider| Arc::new(provider) as Arc<dyn NotificationProvider>)
        }
        ProviderKind::Wecom => {
            providers::WecomProvider::from_config(provider_config, client.clone())
                .map(|provider| Arc::new(provider) as Arc<dyn NotificationProvider>)
        }
        ProviderKind::Dingtalk => {
            providers::DingtalkProvider::from_config(provider_config, client.clone())
                .map(|provider| Arc::new(provider) as Arc<dyn NotificationProvider>)
        }
        ProviderKind::ServerChan => {
            providers::ServerChanProvider::from_config(provider_config, client.clone())
                .map(|provider| Arc::new(provider) as Arc<dyn NotificationProvider>)
        }
        ProviderKind::Webhook => {
            providers::WebhookProvider::from_config(provider_config, client.clone())
                .map(|provider| Arc::new(provider) as Arc<dyn NotificationProvider>)
        }
    }
}

impl NotificationEngine {
    pub fn new(config: NotificationConfig) -> Result<Self> {
        let client = Client::builder().user_agent("AI-Monitor/0.1").build()?;
        let mut providers: HashMap<String, Arc<dyn NotificationProvider>> = HashMap::new();
        let mut provider_errors: HashMap<String, ProviderInitError> = HashMap::new();

        for provider_config in &config.providers {
            if !provider_config.enabled {
                continue;
            }

            match build_provider(provider_config, &client) {
                Ok(provider) => {
                    providers.insert(provider_config.id.clone(), provider);
                }
                Err(error) => {
                    provider_errors.insert(
                        provider_config.id.clone(),
                        ProviderInitError {
                            provider_type: provider_config.provider_type,
                            message: error.to_string(),
                        },
                    );
                }
            }
        }

        Ok(Self {
            config,
            providers: Arc::new(providers),
            provider_errors: Arc::new(provider_errors),
        })
    }

    pub fn provider_ids(&self) -> Vec<String> {
        let mut ids: Vec<String> = self.providers.keys().cloned().collect();
        ids.extend(self.provider_errors.keys().cloned());
        ids.sort();
        ids.dedup();
        ids
    }

    pub fn provider_kind(&self, provider_id: &str) -> Option<ProviderKind> {
        self.providers
            .get(provider_id)
            .map(|provider| provider.kind())
            .or_else(|| {
                self.provider_errors
                    .get(provider_id)
                    .map(|error| error.provider_type)
            })
    }

    pub async fn validate_provider(&self, provider_id: &str) -> Result<ProviderKind> {
        if let Some(error) = self.provider_errors.get(provider_id) {
            return Err(NotificationError::Config(error.message.clone()));
        }
        let provider = self.providers.get(provider_id).ok_or_else(|| {
            NotificationError::ProviderUnavailable {
                provider_id: provider_id.to_string(),
            }
        })?;
        provider.validate_config().await?;
        Ok(provider.kind())
    }

    pub fn notification_plan(&self, event: &AgentTaskEvent, task: &AgentTask) -> Vec<String> {
        if self
            .config
            .quiet_hours
            .as_ref()
            .map(|quiet_hours| quiet_hours.suppresses(event.priority))
            .unwrap_or(false)
        {
            return Vec::new();
        }

        let mut selected = Vec::new();
        let mut seen = HashSet::new();

        for rule in &self.config.rules {
            if !rule.matches(event, task) {
                continue;
            }
            for provider_id in &rule.send_to {
                if !seen.insert(provider_id.clone()) {
                    continue;
                }
                let Some(provider_kind) = self.provider_kind(provider_id) else {
                    continue;
                };
                if provider_kind == ProviderKind::Desktop && !event.notify_desktop {
                    continue;
                }
                if provider_kind != ProviderKind::Desktop && !event.notify_external {
                    continue;
                }
                selected.push(provider_id.clone());
            }
        }

        selected
    }

    pub async fn send(
        &self,
        provider_id: &str,
        event: &AgentTaskEvent,
        task: &AgentTask,
    ) -> Result<ProviderSendResult> {
        if let Some(error) = self.provider_errors.get(provider_id) {
            return Err(NotificationError::Config(error.message.clone()));
        }
        let provider = self.providers.get(provider_id).ok_or_else(|| {
            NotificationError::ProviderUnavailable {
                provider_id: provider_id.to_string(),
            }
        })?;
        provider.validate_config().await?;
        provider.send(event, task).await
    }

    pub async fn test_connection(&self, provider_id: &str) -> Result<ProviderSendResult> {
        if let Some(error) = self.provider_errors.get(provider_id) {
            return Err(NotificationError::Config(error.message.clone()));
        }
        let provider = self.providers.get(provider_id).ok_or_else(|| {
            NotificationError::ProviderUnavailable {
                provider_id: provider_id.to_string(),
            }
        })?;
        provider.validate_config().await?;
        provider.test_connection().await
    }
}

pub fn format_task_message(event: &AgentTaskEvent, task: &AgentTask) -> String {
    let project = task.workspace.as_deref().unwrap_or("unknown workspace");
    let session = task
        .session_name
        .as_deref()
        .or(task.window_title.as_deref())
        .unwrap_or("-");
    let step = event
        .step
        .as_deref()
        .or(task.step.as_deref())
        .unwrap_or("-");
    let message = event
        .message
        .as_deref()
        .or(task.message.as_deref())
        .unwrap_or("-");

    format!(
        "AI Monitor task update\n\nProject: {project}\nSession: {session}\nTask: {title}\nSource: {source}\nStatus: {status}\nPriority: {priority}\nStep: {step}\nMessage: {message}",
        title = task.title,
        source = task.source,
        status = task.status,
        priority = task.priority,
    )
}

pub fn validate_required_setting(
    provider_id: &str,
    key: &str,
    value: Option<String>,
) -> Result<String> {
    let Some(value) = value else {
        return Err(NotificationError::Config(format!(
            "provider `{provider_id}` is missing `{key}`"
        )));
    };
    if value.trim().is_empty() || looks_unresolved_placeholder(&value) {
        return Err(NotificationError::Config(format!(
            "provider `{provider_id}` has unresolved `{key}`"
        )));
    }
    Ok(value)
}

pub fn redact_sensitive_error_message(message: impl AsRef<str>) -> String {
    redact_urls(message.as_ref())
}

fn redact_urls(input: &str) -> String {
    let mut output = String::with_capacity(input.len());
    let mut index = 0;

    while index < input.len() {
        let rest = &input[index..];
        if rest.starts_with("http://") || rest.starts_with("https://") {
            output.push_str("[redacted-url]");
            index += rest
                .find(|character: char| {
                    character.is_whitespace()
                        || matches!(character, '"' | '\'' | '<' | '>' | ')' | ']' | '}')
                })
                .unwrap_or(rest.len());
            continue;
        }

        let Some(character) = rest.chars().next() else {
            break;
        };
        output.push(character);
        index += character.len_utf8();
    }

    output
}

fn resolve_env_placeholder(value: &str) -> String {
    if let Some(name) = value
        .strip_prefix("${")
        .and_then(|rest| rest.strip_suffix('}'))
    {
        std::env::var(name).unwrap_or_else(|_| value.to_string())
    } else {
        value.to_string()
    }
}

fn resolve_secret_value(value: &str) -> Result<String> {
    let expanded = resolve_env_placeholder(value);
    if let Some(reference) = keychain_reference(&expanded) {
        return read_keychain_secret(&reference.service, &reference.account);
    }
    Ok(expanded)
}

#[derive(Debug, PartialEq, Eq)]
struct KeychainReference {
    service: String,
    account: String,
}

fn keychain_reference(value: &str) -> Option<KeychainReference> {
    if let Some(rest) = value.strip_prefix("keychain://") {
        return parse_keychain_reference(rest, '/');
    }

    value
        .strip_prefix("${KEYCHAIN:")
        .and_then(|rest| rest.strip_suffix('}'))
        .and_then(|rest| parse_keychain_reference(rest, ':'))
}

fn parse_keychain_reference(value: &str, separator: char) -> Option<KeychainReference> {
    let (service, account) = value.split_once(separator)?;
    let service = service.trim();
    let account = account.trim();
    if service.is_empty() || account.is_empty() {
        return None;
    }
    Some(KeychainReference {
        service: service.to_string(),
        account: account.to_string(),
    })
}

#[cfg(target_os = "macos")]
fn read_keychain_secret(service: &str, account: &str) -> Result<String> {
    let output = Command::new("/usr/bin/security")
        .arg("find-generic-password")
        .arg("-s")
        .arg(service)
        .arg("-a")
        .arg(account)
        .arg("-w")
        .output()?;
    if !output.status.success() {
        return Err(NotificationError::Config(format!(
            "keychain item `{service}` / `{account}` was not found or is not accessible"
        )));
    }
    let value = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if value.is_empty() {
        return Err(NotificationError::Config(format!(
            "keychain item `{service}` / `{account}` is empty"
        )));
    }
    Ok(value)
}

#[cfg(not(target_os = "macos"))]
fn read_keychain_secret(service: &str, account: &str) -> Result<String> {
    Err(NotificationError::Config(format!(
        "keychain item `{service}` / `{account}` requires macOS Keychain"
    )))
}

fn looks_unresolved_placeholder(value: &str) -> bool {
    value.starts_with("${") && value.ends_with('}')
}

#[cfg(test)]
mod tests {
    use super::*;
    use ai_monitor_protocol::AgentTaskEvent;

    #[test]
    fn plans_matching_rule_only() {
        let config = NotificationConfig::from_toml_str(
            r#"
            [[providers]]
            id = "desktop"
            type = "desktop"
            enabled = true

            [[rules]]
            status = "needs_permission"
            priority = "P0"
            send_to = ["desktop"]
            "#,
        )
        .unwrap();
        let engine = NotificationEngine::new(config).unwrap();
        let mut event = AgentTaskEvent::new(
            "task_1",
            "codex-cli",
            "Fix auth",
            TaskStatus::NeedsPermission,
        );
        event.priority = TaskPriority::P0;
        let task = AgentTask::from_event(&event);

        assert_eq!(engine.notification_plan(&event, &task), vec!["desktop"]);
    }

    #[test]
    fn loads_all_supported_provider_kinds() {
        let config = NotificationConfig::from_toml_str(
            r#"
            [[providers]]
            id = "desktop"
            type = "desktop"
            enabled = true

            [[providers]]
            id = "telegram"
            type = "telegram"
            enabled = true

            [[providers]]
            id = "slack"
            type = "slack"
            enabled = true

            [[providers]]
            id = "discord"
            type = "discord"
            enabled = true

            [[providers]]
            id = "email"
            type = "email"
            enabled = true

            [[providers]]
            id = "ntfy"
            type = "ntfy"
            enabled = true

            [[providers]]
            id = "pushover"
            type = "pushover"
            enabled = true

            [[providers]]
            id = "bark"
            type = "bark"
            enabled = true

            [[providers]]
            id = "feishu"
            type = "feishu"
            enabled = true

            [[providers]]
            id = "wecom"
            type = "wecom"
            enabled = true

            [[providers]]
            id = "dingtalk"
            type = "dingtalk"
            enabled = true

            [[providers]]
            id = "server_chan"
            type = "server_chan"
            enabled = true

            [[providers]]
            id = "webhook"
            type = "webhook"
            enabled = true
            "#,
        )
        .unwrap();
        let engine = NotificationEngine::new(config).unwrap();
        assert_eq!(
            engine.provider_ids(),
            vec![
                "bark",
                "desktop",
                "dingtalk",
                "discord",
                "email",
                "feishu",
                "ntfy",
                "pushover",
                "server_chan",
                "slack",
                "telegram",
                "webhook",
                "wecom",
            ]
        );
        assert_eq!(engine.provider_kind("discord"), Some(ProviderKind::Discord));
        assert_eq!(engine.provider_kind("email"), Some(ProviderKind::Email));
        assert_eq!(
            engine.provider_kind("server_chan"),
            Some(ProviderKind::ServerChan)
        );
    }

    #[test]
    fn parses_keychain_secret_references() {
        assert_eq!(
            keychain_reference("keychain://ai-monitor/slack-webhook"),
            Some(KeychainReference {
                service: "ai-monitor".to_string(),
                account: "slack-webhook".to_string()
            })
        );
        assert_eq!(
            keychain_reference("${KEYCHAIN:ai-monitor:telegram-token}"),
            Some(KeychainReference {
                service: "ai-monitor".to_string(),
                account: "telegram-token".to_string()
            })
        );
        assert_eq!(keychain_reference("keychain://ai-monitor"), None);
        assert_eq!(keychain_reference("${TELEGRAM_BOT_TOKEN}"), None);
    }

    #[test]
    fn redacts_urls_from_provider_error_messages() {
        let message = redact_sensitive_error_message(
            "error sending request for url (https://api.telegram.org/bot123:secret/sendMessage): connection refused",
        );

        assert_eq!(
            message,
            "error sending request for url ([redacted-url]): connection refused"
        );
        assert!(!message.contains("123:secret"));
    }

    #[test]
    fn redacts_webhook_urls_without_removing_status_context() {
        let message = redact_sensitive_error_message(
            "webhook failed at https://hooks.slack.com/services/T000/B000/secret with status 500",
        );

        assert_eq!(message, "webhook failed at [redacted-url] with status 500");
        assert!(!message.contains("secret"));
    }

    #[test]
    fn disabled_keychain_backed_provider_does_not_resolve_secret() {
        let config = NotificationConfig::from_toml_str(
            r#"
            [[providers]]
            id = "slack"
            type = "slack"
            enabled = false
            webhook_url = "keychain://missing/service"
            "#,
        )
        .unwrap();
        let engine = NotificationEngine::new(config).unwrap();
        assert!(engine.provider_ids().is_empty());
    }

    #[test]
    fn misconfigured_enabled_provider_does_not_prevent_engine_startup() {
        let config = NotificationConfig::from_toml_str(
            r#"
            [[providers]]
            id = "telegram"
            type = "telegram"
            enabled = true
            bot_token = "keychain://missing/telegram-token"
            chat_id = "123"
            "#,
        )
        .unwrap();

        let engine = NotificationEngine::new(config).unwrap();

        assert_eq!(engine.provider_ids(), vec!["telegram"]);
        assert_eq!(
            engine.provider_kind("telegram"),
            Some(ProviderKind::Telegram)
        );
    }
}
