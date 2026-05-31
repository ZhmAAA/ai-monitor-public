# Third-Party Notifications

AI Monitor does not require an official mobile app for the current release scope. It reaches phones and teams through provider integrations.

## Supported providers

- Desktop
- Telegram
- Slack
- Discord
- Email
- ntfy
- Pushover
- Bark
- Feishu
- WeCom
- DingTalk
- ServerChan
- Custom Webhook

Email currently uses a configured local `sendmail_path`. The other non-desktop providers are HTTP integrations and use the daemon's shared delivery log, health check, and retry APIs.

## Configuration

Providers are configured in TOML and can reference environment variables:

```toml
[[providers]]
id = "telegram"
type = "telegram"
enabled = true
bot_token = "${TELEGRAM_BOT_TOKEN}"
chat_id = "${TELEGRAM_CHAT_ID}"
```

Sensitive fields such as `bot_token`, `webhook_url`, `token`, `send_key`, `topic`, `device_key`, and custom webhook `url` can reference macOS Keychain items:

```toml
[[providers]]
id = "slack"
type = "slack"
enabled = true
webhook_url = "keychain://ai-monitor/slack-webhook-url"
```

This is equivalent to `${KEYCHAIN:ai-monitor:slack-webhook-url}`. The daemon resolves the item with the macOS `security` tool at provider initialization. The macOS settings panel can create these Keychain items and update the provider config field to the generated `keychain://...` reference.

Common HTTP provider examples:

```toml
[[providers]]
id = "discord"
type = "discord"
enabled = true
webhook_url = "${DISCORD_WEBHOOK_URL}"

[[providers]]
id = "ntfy"
type = "ntfy"
enabled = true
topic_url = "${NTFY_TOPIC_URL}"

[[providers]]
id = "server_chan"
type = "server_chan"
enabled = true
send_key = "${SERVERCHAN_SEND_KEY}"
```

Secrets should come from OS secure storage in production. Environment variables are acceptable for local development and CI smoke tests.

## Webhook payload

Custom webhooks receive:

```json
{
  "event": {},
  "task": {},
  "message": "AI Monitor task update"
}
```

Webhook consumers can route to internal systems, custom phone push gateways, or automation tools.
