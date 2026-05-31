# Third-Party Notifications

By default, AI Monitor only sends local desktop notifications. You can optionally configure third-party providers to receive notifications on your phone or in a team channel.

## Supported Providers

- Desktop (default, always on)
- Telegram
- Slack
- Discord
- Email (via local `sendmail`)
- ntfy
- Pushover
- Bark
- Feishu
- WeCom
- DingTalk
- ServerChan
- Custom Webhook

## Setup

Add provider configuration to `config/default.toml`, then restart the daemon. The config file is the one you passed with `--config` when starting the daemon.

**Telegram:**

```toml
[[providers]]
id = "telegram"
type = "telegram"
enabled = true
bot_token = "YOUR_BOT_TOKEN"
chat_id = "YOUR_CHAT_ID"
```

**Slack:**

```toml
[[providers]]
id = "slack"
type = "slack"
enabled = true
webhook_url = "YOUR_INCOMING_WEBHOOK_URL"
```

**Discord:**

```toml
[[providers]]
id = "discord"
type = "discord"
enabled = true
webhook_url = "YOUR_DISCORD_WEBHOOK_URL"
```

**ntfy:**

```toml
[[providers]]
id = "ntfy"
type = "ntfy"
enabled = true
topic_url = "https://ntfy.sh/your-topic"
```

**Pushover:**

```toml
[[providers]]
id = "pushover"
type = "pushover"
enabled = true
user_key = "YOUR_USER_KEY"
api_token = "YOUR_APP_API_TOKEN"
```

**Bark (iOS):**

```toml
[[providers]]
id = "bark"
type = "bark"
enabled = true
device_key = "YOUR_DEVICE_KEY"
```

**ServerChan:**

```toml
[[providers]]
id = "server_chan"
type = "server_chan"
enabled = true
send_key = "YOUR_SEND_KEY"
```

**Custom Webhook:**

```toml
[[providers]]
id = "my-webhook"
type = "webhook"
enabled = true
url = "https://your-endpoint.example.com/hook"
```

The webhook receives a JSON payload:

```json
{
  "event": {},
  "task": {},
  "message": "AI Monitor task update"
}
```

## Notification Rules

By default, all notifications go to the `desktop` provider only. To also send to a configured provider, edit the `[[rules]]` entries in `config/default.toml`.

Example — also send completions to Telegram:

```toml
[[rules]]
status = "completed"
priority = "P1"
send_to = ["desktop", "telegram"]
```

The default rules at the bottom of `config/default.toml` are a good starting point. Copy and modify them.

After any config change, restart the daemon and watch the terminal output for errors confirming the provider loaded correctly.

## Quiet Hours

To suppress lower-priority notifications at night, edit `config/default.toml`:

```toml
[quiet_hours]
enabled = true
start = "22:00"
end = "07:00"
allow_priorities = ["P0"]
```

`P0` events (permission requests, failures, tasks waiting for input) still come through during quiet hours. Lower-priority events are suppressed.
