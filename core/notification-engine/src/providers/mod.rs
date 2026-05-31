use crate::{
    format_task_message, validate_required_setting, NotificationError, NotificationProvider,
    ProviderConfig, ProviderKind, ProviderSendResult, Result,
};
use ai_monitor_protocol::{AgentTask, AgentTaskEvent, TaskStatus};
use async_trait::async_trait;
use reqwest::Client;
use serde_json::{json, Map, Value};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

pub struct DesktopProvider {
    id: String,
}

impl DesktopProvider {
    pub fn from_config(config: &ProviderConfig) -> Result<Self> {
        Ok(Self {
            id: config.id.clone(),
        })
    }
}

#[async_trait]
impl NotificationProvider for DesktopProvider {
    fn id(&self) -> &str {
        &self.id
    }

    fn kind(&self) -> ProviderKind {
        ProviderKind::Desktop
    }

    async fn send(&self, event: &AgentTaskEvent, task: &AgentTask) -> Result<ProviderSendResult> {
        let title = format!("AI Monitor: {}", task.status);
        let body = format!(
            "{} - {}",
            task.title,
            event.message.as_deref().unwrap_or("")
        );

        #[cfg(target_os = "macos")]
        {
            if let Some(binary) = terminal_notifier_path() {
                let status = Command::new(binary)
                    .arg("-title")
                    .arg(&title)
                    .arg("-message")
                    .arg(&body)
                    .arg("-group")
                    .arg(format!("ai-monitor-{}", task.task_id))
                    .arg("-open")
                    .arg(task_deep_link(task))
                    .status()?;
                if status.success() {
                    return Ok(ProviderSendResult {
                        provider_id: self.id.clone(),
                        provider_type: ProviderKind::Desktop,
                        message: "clickable desktop notification sent".to_string(),
                    });
                }
                tracing::warn!(
                    provider = %self.id,
                    %status,
                    "terminal-notifier failed; falling back to osascript desktop notification"
                );
            }

            send_osascript_notification(&title, &body).map_err(|message| {
                NotificationError::ProviderFailed {
                    provider_id: self.id.clone(),
                    message,
                }
            })?;
        }

        #[cfg(not(target_os = "macos"))]
        {
            tracing::info!(provider = %self.id, title, body, "desktop notification requested");
        }

        Ok(ProviderSendResult {
            provider_id: self.id.clone(),
            provider_type: ProviderKind::Desktop,
            message: "desktop notification sent".to_string(),
        })
    }

    async fn validate_config(&self) -> Result<()> {
        Ok(())
    }

    async fn test_connection(&self) -> Result<ProviderSendResult> {
        let event = test_event(TaskStatus::Completed);
        let task = AgentTask::from_event(&event);
        self.send(&event, &task).await
    }
}

pub struct TelegramProvider {
    id: String,
    bot_token: String,
    chat_id: String,
    client: Client,
}

impl TelegramProvider {
    pub fn from_config(config: &ProviderConfig, client: Client) -> Result<Self> {
        Ok(Self {
            id: config.id.clone(),
            bot_token: config.secret_setting("bot_token")?.unwrap_or_default(),
            chat_id: config.setting("chat_id").unwrap_or_default(),
            client,
        })
    }
}

#[async_trait]
impl NotificationProvider for TelegramProvider {
    fn id(&self) -> &str {
        &self.id
    }

    fn kind(&self) -> ProviderKind {
        ProviderKind::Telegram
    }

    async fn send(&self, event: &AgentTaskEvent, task: &AgentTask) -> Result<ProviderSendResult> {
        let url = format!("https://api.telegram.org/bot{}/sendMessage", self.bot_token);
        let response = self
            .client
            .post(url)
            .json(&json!({
                "chat_id": self.chat_id,
                "text": format_telegram_message(event, task),
                "parse_mode": "HTML",
                "disable_web_page_preview": true
            }))
            .send()
            .await?;

        ensure_success(&self.id, "telegram", response).await?;

        Ok(ProviderSendResult {
            provider_id: self.id.clone(),
            provider_type: ProviderKind::Telegram,
            message: "telegram message sent".to_string(),
        })
    }

    async fn validate_config(&self) -> Result<()> {
        validate_required_setting(&self.id, "bot_token", Some(self.bot_token.clone()))?;
        validate_required_setting(&self.id, "chat_id", Some(self.chat_id.clone()))?;
        Ok(())
    }

    async fn test_connection(&self) -> Result<ProviderSendResult> {
        let event = test_event(TaskStatus::Completed);
        let task = AgentTask::from_event(&event);
        self.send(&event, &task).await
    }
}

pub struct SlackProvider {
    id: String,
    webhook_url: String,
    client: Client,
}

impl SlackProvider {
    pub fn from_config(config: &ProviderConfig, client: Client) -> Result<Self> {
        Ok(Self {
            id: config.id.clone(),
            webhook_url: config.secret_setting("webhook_url")?.unwrap_or_default(),
            client,
        })
    }
}

#[async_trait]
impl NotificationProvider for SlackProvider {
    fn id(&self) -> &str {
        &self.id
    }

    fn kind(&self) -> ProviderKind {
        ProviderKind::Slack
    }

    async fn send(&self, event: &AgentTaskEvent, task: &AgentTask) -> Result<ProviderSendResult> {
        let response = self
            .client
            .post(&self.webhook_url)
            .json(&json!({ "text": format_task_message(event, task) }))
            .send()
            .await?;

        if !response.status().is_success() {
            return Err(NotificationError::ProviderFailed {
                provider_id: self.id.clone(),
                message: format!("slack returned {}", response.status()),
            });
        }

        Ok(ProviderSendResult {
            provider_id: self.id.clone(),
            provider_type: ProviderKind::Slack,
            message: "slack message sent".to_string(),
        })
    }

    async fn validate_config(&self) -> Result<()> {
        validate_required_setting(&self.id, "webhook_url", Some(self.webhook_url.clone()))?;
        Ok(())
    }

    async fn test_connection(&self) -> Result<ProviderSendResult> {
        let event = test_event(TaskStatus::Completed);
        let task = AgentTask::from_event(&event);
        self.send(&event, &task).await
    }
}

pub struct DiscordProvider {
    id: String,
    webhook_url: String,
    username: Option<String>,
    client: Client,
}

impl DiscordProvider {
    pub fn from_config(config: &ProviderConfig, client: Client) -> Result<Self> {
        Ok(Self {
            id: config.id.clone(),
            webhook_url: config.secret_setting("webhook_url")?.unwrap_or_default(),
            username: config.setting("username").filter(|value| !value.is_empty()),
            client,
        })
    }
}

#[async_trait]
impl NotificationProvider for DiscordProvider {
    fn id(&self) -> &str {
        &self.id
    }

    fn kind(&self) -> ProviderKind {
        ProviderKind::Discord
    }

    async fn send(&self, event: &AgentTaskEvent, task: &AgentTask) -> Result<ProviderSendResult> {
        let mut payload = Map::new();
        payload.insert(
            "content".to_string(),
            Value::String(format_task_message(event, task)),
        );
        if let Some(username) = &self.username {
            payload.insert("username".to_string(), Value::String(username.clone()));
        }

        let response = self
            .client
            .post(&self.webhook_url)
            .json(&Value::Object(payload))
            .send()
            .await?;
        ensure_success(&self.id, "discord", response).await?;
        Ok(provider_result(
            &self.id,
            ProviderKind::Discord,
            "discord webhook delivered",
        ))
    }

    async fn validate_config(&self) -> Result<()> {
        validate_required_setting(&self.id, "webhook_url", Some(self.webhook_url.clone()))?;
        Ok(())
    }

    async fn test_connection(&self) -> Result<ProviderSendResult> {
        let event = test_event(TaskStatus::Completed);
        let task = AgentTask::from_event(&event);
        self.send(&event, &task).await
    }
}

pub struct EmailProvider {
    id: String,
    to: String,
    from: String,
    subject_prefix: String,
    sendmail_path: String,
}

impl EmailProvider {
    pub fn from_config(config: &ProviderConfig) -> Result<Self> {
        Ok(Self {
            id: config.id.clone(),
            to: config.setting("to").unwrap_or_default(),
            from: config.setting("from").unwrap_or_default(),
            subject_prefix: config
                .setting("subject_prefix")
                .filter(|value| !value.trim().is_empty())
                .unwrap_or_else(|| "AI Monitor".to_string()),
            sendmail_path: config
                .setting("sendmail_path")
                .filter(|value| !value.trim().is_empty())
                .unwrap_or_else(|| "/usr/sbin/sendmail".to_string()),
        })
    }
}

#[async_trait]
impl NotificationProvider for EmailProvider {
    fn id(&self) -> &str {
        &self.id
    }

    fn kind(&self) -> ProviderKind {
        ProviderKind::Email
    }

    async fn send(&self, event: &AgentTaskEvent, task: &AgentTask) -> Result<ProviderSendResult> {
        let subject = clean_mail_header(&format!("{}: {}", self.subject_prefix, task.status));
        let message = format!(
            "To: {to}\nFrom: {from}\nSubject: {subject}\nContent-Type: text/plain; charset=utf-8\n\n{body}\n",
            to = clean_mail_header(&self.to),
            from = clean_mail_header(&self.from),
            subject = subject,
            body = format_task_message(event, task)
        );

        let mut child = Command::new(&self.sendmail_path)
            .arg("-t")
            .stdin(Stdio::piped())
            .spawn()?;
        if let Some(stdin) = child.stdin.as_mut() {
            stdin.write_all(message.as_bytes())?;
        }
        let status = child.wait()?;
        if !status.success() {
            return Err(NotificationError::ProviderFailed {
                provider_id: self.id.clone(),
                message: format!("sendmail exited with status {status}"),
            });
        }
        Ok(provider_result(
            &self.id,
            ProviderKind::Email,
            "email sent through sendmail",
        ))
    }

    async fn validate_config(&self) -> Result<()> {
        validate_required_setting(&self.id, "to", Some(self.to.clone()))?;
        validate_required_setting(&self.id, "from", Some(self.from.clone()))?;
        validate_required_setting(&self.id, "sendmail_path", Some(self.sendmail_path.clone()))?;
        if self.sendmail_path.contains('/') && !Path::new(&self.sendmail_path).exists() {
            return Err(NotificationError::Config(format!(
                "provider `{}` sendmail_path does not exist",
                self.id
            )));
        }
        Ok(())
    }

    async fn test_connection(&self) -> Result<ProviderSendResult> {
        let event = test_event(TaskStatus::Completed);
        let task = AgentTask::from_event(&event);
        self.send(&event, &task).await
    }
}

pub struct NtfyProvider {
    id: String,
    topic_url: String,
    priority: Option<String>,
    tags: Option<String>,
    client: Client,
}

impl NtfyProvider {
    pub fn from_config(config: &ProviderConfig, client: Client) -> Result<Self> {
        Ok(Self {
            id: config.id.clone(),
            topic_url: ntfy_topic_url(config)?,
            priority: config.setting("priority").filter(|value| !value.is_empty()),
            tags: config.setting("tags").filter(|value| !value.is_empty()),
            client,
        })
    }
}

#[async_trait]
impl NotificationProvider for NtfyProvider {
    fn id(&self) -> &str {
        &self.id
    }

    fn kind(&self) -> ProviderKind {
        ProviderKind::Ntfy
    }

    async fn send(&self, event: &AgentTaskEvent, task: &AgentTask) -> Result<ProviderSendResult> {
        let mut request = self
            .client
            .post(&self.topic_url)
            .header("Content-Type", "text/plain; charset=utf-8")
            .body(format_task_message(event, task));
        if let Some(priority) = &self.priority {
            request = request.header("Priority", priority);
        }
        if let Some(tags) = &self.tags {
            request = request.header("Tags", tags);
        }

        let response = request.send().await?;
        ensure_success(&self.id, "ntfy", response).await?;
        Ok(provider_result(
            &self.id,
            ProviderKind::Ntfy,
            "ntfy notification delivered",
        ))
    }

    async fn validate_config(&self) -> Result<()> {
        validate_required_setting(&self.id, "topic_url", Some(self.topic_url.clone()))?;
        Ok(())
    }

    async fn test_connection(&self) -> Result<ProviderSendResult> {
        let event = test_event(TaskStatus::Completed);
        let task = AgentTask::from_event(&event);
        self.send(&event, &task).await
    }
}

pub struct PushoverProvider {
    id: String,
    token: String,
    user: String,
    device: Option<String>,
    sound: Option<String>,
    client: Client,
}

impl PushoverProvider {
    pub fn from_config(config: &ProviderConfig, client: Client) -> Result<Self> {
        Ok(Self {
            id: config.id.clone(),
            token: config.secret_setting("token")?.unwrap_or_default(),
            user: config.secret_setting("user")?.unwrap_or_default(),
            device: config.setting("device").filter(|value| !value.is_empty()),
            sound: config.setting("sound").filter(|value| !value.is_empty()),
            client,
        })
    }
}

#[async_trait]
impl NotificationProvider for PushoverProvider {
    fn id(&self) -> &str {
        &self.id
    }

    fn kind(&self) -> ProviderKind {
        ProviderKind::Pushover
    }

    async fn send(&self, event: &AgentTaskEvent, task: &AgentTask) -> Result<ProviderSendResult> {
        let mut form = vec![
            ("token", self.token.clone()),
            ("user", self.user.clone()),
            ("title", format!("AI Monitor: {}", task.status)),
            ("message", format_task_message(event, task)),
        ];
        if let Some(device) = &self.device {
            form.push(("device", device.clone()));
        }
        if let Some(sound) = &self.sound {
            form.push(("sound", sound.clone()));
        }

        let response = self
            .client
            .post("https://api.pushover.net/1/messages.json")
            .form(&form)
            .send()
            .await?;
        ensure_success(&self.id, "pushover", response).await?;
        Ok(provider_result(
            &self.id,
            ProviderKind::Pushover,
            "pushover message sent",
        ))
    }

    async fn validate_config(&self) -> Result<()> {
        validate_required_setting(&self.id, "token", Some(self.token.clone()))?;
        validate_required_setting(&self.id, "user", Some(self.user.clone()))?;
        Ok(())
    }

    async fn test_connection(&self) -> Result<ProviderSendResult> {
        let event = test_event(TaskStatus::Completed);
        let task = AgentTask::from_event(&event);
        self.send(&event, &task).await
    }
}

pub struct BarkProvider {
    id: String,
    url: String,
    group: Option<String>,
    client: Client,
}

impl BarkProvider {
    pub fn from_config(config: &ProviderConfig, client: Client) -> Result<Self> {
        Ok(Self {
            id: config.id.clone(),
            url: bark_url(config)?,
            group: config.setting("group").filter(|value| !value.is_empty()),
            client,
        })
    }
}

#[async_trait]
impl NotificationProvider for BarkProvider {
    fn id(&self) -> &str {
        &self.id
    }

    fn kind(&self) -> ProviderKind {
        ProviderKind::Bark
    }

    async fn send(&self, event: &AgentTaskEvent, task: &AgentTask) -> Result<ProviderSendResult> {
        let mut payload = Map::new();
        payload.insert(
            "title".to_string(),
            Value::String(format!("AI Monitor: {}", task.status)),
        );
        payload.insert(
            "body".to_string(),
            Value::String(format_task_message(event, task)),
        );
        if let Some(group) = &self.group {
            payload.insert("group".to_string(), Value::String(group.clone()));
        }
        let response = self
            .client
            .post(&self.url)
            .json(&Value::Object(payload))
            .send()
            .await?;
        ensure_success(&self.id, "bark", response).await?;
        Ok(provider_result(
            &self.id,
            ProviderKind::Bark,
            "bark push sent",
        ))
    }

    async fn validate_config(&self) -> Result<()> {
        validate_required_setting(&self.id, "url", Some(self.url.clone()))?;
        Ok(())
    }

    async fn test_connection(&self) -> Result<ProviderSendResult> {
        let event = test_event(TaskStatus::Completed);
        let task = AgentTask::from_event(&event);
        self.send(&event, &task).await
    }
}

pub struct FeishuProvider {
    id: String,
    webhook_url: String,
    client: Client,
}

impl FeishuProvider {
    pub fn from_config(config: &ProviderConfig, client: Client) -> Result<Self> {
        Ok(Self {
            id: config.id.clone(),
            webhook_url: config.secret_setting("webhook_url")?.unwrap_or_default(),
            client,
        })
    }
}

#[async_trait]
impl NotificationProvider for FeishuProvider {
    fn id(&self) -> &str {
        &self.id
    }

    fn kind(&self) -> ProviderKind {
        ProviderKind::Feishu
    }

    async fn send(&self, event: &AgentTaskEvent, task: &AgentTask) -> Result<ProviderSendResult> {
        let response = self
            .client
            .post(&self.webhook_url)
            .json(&json!({
                "msg_type": "text",
                "content": { "text": format_task_message(event, task) }
            }))
            .send()
            .await?;
        ensure_success(&self.id, "feishu", response).await?;
        Ok(provider_result(
            &self.id,
            ProviderKind::Feishu,
            "feishu webhook delivered",
        ))
    }

    async fn validate_config(&self) -> Result<()> {
        validate_required_setting(&self.id, "webhook_url", Some(self.webhook_url.clone()))?;
        Ok(())
    }

    async fn test_connection(&self) -> Result<ProviderSendResult> {
        let event = test_event(TaskStatus::Completed);
        let task = AgentTask::from_event(&event);
        self.send(&event, &task).await
    }
}

pub struct WecomProvider {
    id: String,
    webhook_url: String,
    client: Client,
}

impl WecomProvider {
    pub fn from_config(config: &ProviderConfig, client: Client) -> Result<Self> {
        Ok(Self {
            id: config.id.clone(),
            webhook_url: config.secret_setting("webhook_url")?.unwrap_or_default(),
            client,
        })
    }
}

#[async_trait]
impl NotificationProvider for WecomProvider {
    fn id(&self) -> &str {
        &self.id
    }

    fn kind(&self) -> ProviderKind {
        ProviderKind::Wecom
    }

    async fn send(&self, event: &AgentTaskEvent, task: &AgentTask) -> Result<ProviderSendResult> {
        let response = self
            .client
            .post(&self.webhook_url)
            .json(&json!({
                "msgtype": "text",
                "text": { "content": format_task_message(event, task) }
            }))
            .send()
            .await?;
        ensure_success(&self.id, "wecom", response).await?;
        Ok(provider_result(
            &self.id,
            ProviderKind::Wecom,
            "wecom webhook delivered",
        ))
    }

    async fn validate_config(&self) -> Result<()> {
        validate_required_setting(&self.id, "webhook_url", Some(self.webhook_url.clone()))?;
        Ok(())
    }

    async fn test_connection(&self) -> Result<ProviderSendResult> {
        let event = test_event(TaskStatus::Completed);
        let task = AgentTask::from_event(&event);
        self.send(&event, &task).await
    }
}

pub struct DingtalkProvider {
    id: String,
    webhook_url: String,
    client: Client,
}

impl DingtalkProvider {
    pub fn from_config(config: &ProviderConfig, client: Client) -> Result<Self> {
        Ok(Self {
            id: config.id.clone(),
            webhook_url: config.secret_setting("webhook_url")?.unwrap_or_default(),
            client,
        })
    }
}

#[async_trait]
impl NotificationProvider for DingtalkProvider {
    fn id(&self) -> &str {
        &self.id
    }

    fn kind(&self) -> ProviderKind {
        ProviderKind::Dingtalk
    }

    async fn send(&self, event: &AgentTaskEvent, task: &AgentTask) -> Result<ProviderSendResult> {
        let response = self
            .client
            .post(&self.webhook_url)
            .json(&json!({
                "msgtype": "text",
                "text": { "content": format_task_message(event, task) }
            }))
            .send()
            .await?;
        ensure_success(&self.id, "dingtalk", response).await?;
        Ok(provider_result(
            &self.id,
            ProviderKind::Dingtalk,
            "dingtalk webhook delivered",
        ))
    }

    async fn validate_config(&self) -> Result<()> {
        validate_required_setting(&self.id, "webhook_url", Some(self.webhook_url.clone()))?;
        Ok(())
    }

    async fn test_connection(&self) -> Result<ProviderSendResult> {
        let event = test_event(TaskStatus::Completed);
        let task = AgentTask::from_event(&event);
        self.send(&event, &task).await
    }
}

pub struct ServerChanProvider {
    id: String,
    url: String,
    client: Client,
}

impl ServerChanProvider {
    pub fn from_config(config: &ProviderConfig, client: Client) -> Result<Self> {
        Ok(Self {
            id: config.id.clone(),
            url: server_chan_url(config)?,
            client,
        })
    }
}

#[async_trait]
impl NotificationProvider for ServerChanProvider {
    fn id(&self) -> &str {
        &self.id
    }

    fn kind(&self) -> ProviderKind {
        ProviderKind::ServerChan
    }

    async fn send(&self, event: &AgentTaskEvent, task: &AgentTask) -> Result<ProviderSendResult> {
        let response = self
            .client
            .post(&self.url)
            .form(&[
                ("title", format!("AI Monitor: {}", task.status)),
                ("desp", format_task_message(event, task)),
            ])
            .send()
            .await?;
        ensure_success(&self.id, "server_chan", response).await?;
        Ok(provider_result(
            &self.id,
            ProviderKind::ServerChan,
            "serverchan message sent",
        ))
    }

    async fn validate_config(&self) -> Result<()> {
        validate_required_setting(&self.id, "url", Some(self.url.clone()))?;
        Ok(())
    }

    async fn test_connection(&self) -> Result<ProviderSendResult> {
        let event = test_event(TaskStatus::Completed);
        let task = AgentTask::from_event(&event);
        self.send(&event, &task).await
    }
}

pub struct WebhookProvider {
    id: String,
    url: String,
    client: Client,
}

impl WebhookProvider {
    pub fn from_config(config: &ProviderConfig, client: Client) -> Result<Self> {
        Ok(Self {
            id: config.id.clone(),
            url: config.secret_setting("url")?.unwrap_or_default(),
            client,
        })
    }
}

#[async_trait]
impl NotificationProvider for WebhookProvider {
    fn id(&self) -> &str {
        &self.id
    }

    fn kind(&self) -> ProviderKind {
        ProviderKind::Webhook
    }

    async fn send(&self, event: &AgentTaskEvent, task: &AgentTask) -> Result<ProviderSendResult> {
        let response = self
            .client
            .post(&self.url)
            .json(&json!({
                "event": event,
                "task": task,
                "message": format_task_message(event, task)
            }))
            .send()
            .await?;

        if !response.status().is_success() {
            return Err(NotificationError::ProviderFailed {
                provider_id: self.id.clone(),
                message: format!("webhook returned {}", response.status()),
            });
        }

        Ok(ProviderSendResult {
            provider_id: self.id.clone(),
            provider_type: ProviderKind::Webhook,
            message: "webhook delivered".to_string(),
        })
    }

    async fn validate_config(&self) -> Result<()> {
        validate_required_setting(&self.id, "url", Some(self.url.clone()))?;
        Ok(())
    }

    async fn test_connection(&self) -> Result<ProviderSendResult> {
        let event = test_event(TaskStatus::Completed);
        let task = AgentTask::from_event(&event);
        self.send(&event, &task).await
    }
}

fn test_event(status: TaskStatus) -> AgentTaskEvent {
    let mut event = AgentTaskEvent::new(
        "task_test_notification",
        "ai-monitor",
        "Test notification",
        status,
    );
    event.message = Some("AI Monitor notification provider test".to_string());
    event
}

async fn ensure_success(
    provider_id: &str,
    provider_name: &str,
    response: reqwest::Response,
) -> Result<()> {
    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        let detail = body.trim();
        let message = if detail.is_empty() {
            format!("{provider_name} returned {status}")
        } else {
            format!("{provider_name} returned {status}: {detail}")
        };
        return Err(NotificationError::ProviderFailed {
            provider_id: provider_id.to_string(),
            message,
        });
    }
    Ok(())
}

fn provider_result(
    provider_id: &str,
    provider_type: ProviderKind,
    message: &str,
) -> ProviderSendResult {
    ProviderSendResult {
        provider_id: provider_id.to_string(),
        provider_type,
        message: message.to_string(),
    }
}

fn format_telegram_message(event: &AgentTaskEvent, task: &AgentTask) -> String {
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
        "<b>AI Monitor task update</b>\n\n\
<b>Project</b>: {project}\n\
<b>Session</b>: {session}\n\
<b>Task</b>: {title}\n\
<b>Source</b>: {source}\n\
<b>Status</b>: <code>{status}</code>\n\
<b>Priority</b>: <code>{priority}</code>\n\
<b>Step</b>: {step}\n\
<b>Message</b>: {message}",
        project = telegram_html_escape(project),
        session = telegram_html_escape(session),
        title = telegram_html_escape(&task.title),
        source = telegram_html_escape(task.source.as_str()),
        status = telegram_html_escape(&task.status.to_string()),
        priority = telegram_html_escape(&task.priority.to_string()),
        step = telegram_html_escape(step),
        message = telegram_html_escape(message),
    )
}

fn telegram_html_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

fn ntfy_topic_url(config: &ProviderConfig) -> Result<String> {
    if let Some(topic_url) = config
        .secret_setting("topic_url")?
        .filter(|value| !value.is_empty())
    {
        return Ok(topic_url);
    }
    let server_url = config
        .setting("server_url")
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "https://ntfy.sh".to_string());
    let topic = config.secret_setting("topic")?.unwrap_or_default();
    if topic.is_empty() {
        return Ok(String::new());
    }
    Ok(format!("{}/{}", server_url.trim_end_matches('/'), topic))
}

fn bark_url(config: &ProviderConfig) -> Result<String> {
    if let Some(url) = config
        .secret_setting("url")?
        .filter(|value| !value.is_empty())
    {
        return Ok(url);
    }
    let server_url = config
        .setting("server_url")
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "https://api.day.app".to_string());
    let device_key = config.secret_setting("device_key")?.unwrap_or_default();
    if device_key.is_empty() {
        return Ok(String::new());
    }
    Ok(format!(
        "{}/{}",
        server_url.trim_end_matches('/'),
        device_key
    ))
}

fn server_chan_url(config: &ProviderConfig) -> Result<String> {
    if let Some(url) = config
        .secret_setting("url")?
        .filter(|value| !value.is_empty())
    {
        return Ok(url);
    }
    let send_key = config.secret_setting("send_key")?.unwrap_or_default();
    if send_key.is_empty() {
        return Ok(String::new());
    }
    Ok(format!("https://sctapi.ftqq.com/{send_key}.send"))
}

fn clean_mail_header(value: &str) -> String {
    value.replace(['\r', '\n'], " ").trim().to_string()
}

fn escape_osascript(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"")
}

#[cfg(target_os = "macos")]
fn send_osascript_notification(title: &str, body: &str) -> std::result::Result<(), String> {
    let script = format!(
        "display notification \"{}\" with title \"{}\"",
        escape_osascript(body),
        escape_osascript(title)
    );
    let status = Command::new("osascript")
        .arg("-e")
        .arg(script)
        .status()
        .map_err(|error| error.to_string())?;
    if !status.success() {
        return Err(format!("osascript exited with status {status}"));
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn terminal_notifier_path() -> Option<PathBuf> {
    let candidates = [
        "/opt/homebrew/bin/terminal-notifier",
        "/usr/local/bin/terminal-notifier",
        "/usr/bin/terminal-notifier",
    ];
    for candidate in candidates {
        let path = PathBuf::from(candidate);
        if path.exists() {
            return Some(path);
        }
    }

    std::env::var_os("PATH")
        .into_iter()
        .flat_map(|paths| std::env::split_paths(&paths).collect::<Vec<_>>())
        .map(|path| path.join("terminal-notifier"))
        .find(|path| path.exists())
}

#[cfg(target_os = "macos")]
fn task_deep_link(task: &AgentTask) -> String {
    format!("ai-monitor://task/{}", percent_encode(&task.task_id))
}

#[cfg(target_os = "macos")]
fn percent_encode(value: &str) -> String {
    value
        .bytes()
        .flat_map(|byte| match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                vec![byte as char]
            }
            _ => format!("%{byte:02X}").chars().collect(),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn telegram_message_uses_html_and_escapes_dynamic_values() {
        let mut event = AgentTaskEvent::new(
            "task",
            "codex-cli",
            "Fix <auth> & notify",
            TaskStatus::NeedsPermission,
        );
        event.workspace = Some("/tmp/a&b".to_string());
        event.session_name = Some("Backend <dev>".to_string());
        event.step = Some("cargo test > output".to_string());
        event.message = Some("Needs <permission> & retry".to_string());
        let task = AgentTask::from_event(&event);

        let message = format_telegram_message(&event, &task);

        assert!(message.contains("<b>AI Monitor task update</b>"));
        assert!(message.contains("Fix &lt;auth&gt; &amp; notify"));
        assert!(message.contains("/tmp/a&amp;b"));
        assert!(message.contains("cargo test &gt; output"));
        assert!(message.contains("<b>Status</b>: <code>needs_permission</code>"));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn task_deep_link_percent_encodes_task_id() {
        let event = AgentTaskEvent::new(
            "task with/slash",
            "ai-monitor",
            "Title",
            TaskStatus::Completed,
        );
        let task = AgentTask::from_event(&event);
        assert_eq!(
            task_deep_link(&task),
            "ai-monitor://task/task%20with%2Fslash"
        );
    }
}
