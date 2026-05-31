# 第三方通知

[English](third-party-notifications.md) | [简体中文](third-party-notifications.zh-CN.md)

AI Monitor 默认只发送本地桌面通知。你可以选择配置第三方 provider，把通知发到手机或团队频道。

## 支持的 Provider

- Desktop（默认，始终启用）
- Telegram
- Slack
- Discord
- Email（通过本地 `sendmail`）
- ntfy
- Pushover
- Bark
- 飞书
- 企业微信
- 钉钉
- Server 酱
- 自定义 Webhook

## 配置步骤

在 `config/default.toml` 里添加 provider 配置，然后重启 daemon。这里的配置文件就是启动 daemon 时 `--config` 指定的那个文件。

**Telegram：**

```toml
[[providers]]
id = "telegram"
type = "telegram"
enabled = true
bot_token = "YOUR_BOT_TOKEN"
chat_id = "YOUR_CHAT_ID"
```

**Slack：**

```toml
[[providers]]
id = "slack"
type = "slack"
enabled = true
webhook_url = "YOUR_INCOMING_WEBHOOK_URL"
```

**Discord：**

```toml
[[providers]]
id = "discord"
type = "discord"
enabled = true
webhook_url = "YOUR_DISCORD_WEBHOOK_URL"
```

**ntfy：**

```toml
[[providers]]
id = "ntfy"
type = "ntfy"
enabled = true
topic_url = "https://ntfy.sh/your-topic"
```

**Pushover：**

```toml
[[providers]]
id = "pushover"
type = "pushover"
enabled = true
user_key = "YOUR_USER_KEY"
api_token = "YOUR_APP_API_TOKEN"
```

**Bark（iOS）：**

```toml
[[providers]]
id = "bark"
type = "bark"
enabled = true
device_key = "YOUR_DEVICE_KEY"
```

**Server 酱：**

```toml
[[providers]]
id = "server_chan"
type = "server_chan"
enabled = true
send_key = "YOUR_SEND_KEY"
```

**自定义 Webhook：**

```toml
[[providers]]
id = "my-webhook"
type = "webhook"
enabled = true
url = "https://your-endpoint.example.com/hook"
```

Webhook 接收的 JSON payload：

```json
{
  "event": {},
  "task": {},
  "message": "AI Monitor task update"
}
```

## 通知规则

默认情况下，所有通知只发送到 `desktop` provider。如需同时发送到其他 provider，编辑 `config/default.toml` 里的 `[[rules]]` 条目。

例如——同时把完成通知发到 Telegram：

```toml
[[rules]]
status = "completed"
priority = "P1"
send_to = ["desktop", "telegram"]
```

`config/default.toml` 末尾的默认规则是很好的参考起点，复制并修改它们即可。

修改配置后，重启 daemon，观察终端输出确认 provider 加载没有报错。

## 勿扰时段

在夜间屏蔽低优先级通知，编辑 `config/default.toml`：

```toml
[quiet_hours]
enabled = true
start = "22:00"
end = "07:00"
allow_priorities = ["P0"]
```

`P0` 级事件（需要权限的请求、失败、等待输入的任务）在勿扰时段仍会发送，低优先级事件会被屏蔽。
