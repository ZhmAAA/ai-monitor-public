# Notification System

AI Monitor notifications are event driven:

```txt
AgentTaskEvent
  ↓
NotificationRuleEngine
  ↓
NotificationProvider
  ↓
DeliveryLog
```

## Rule inputs

Rules can match:

- `status`
- `priority`
- `source`
- `workspace_contains`
- event flags: `notify_desktop`, `notify_external`
- quiet hours
- provider availability

The rule engine returns provider IDs. The daemon then sends through those providers and records delivery status.

## Provider contract

Each provider implements:

```txt
send(event, task)
validate_config()
test_connection()
```

Providers must be isolated from one another. A Telegram failure must not prevent Slack, desktop, or webhook delivery.

## Supported providers

- Desktop Notification
- Telegram
- Slack
- Discord
- Email through local `sendmail`
- ntfy
- Pushover
- Bark
- Feishu
- WeCom
- DingTalk
- ServerChan
- Custom Webhook

HTTP-style providers use the same delivery log and retry path as Telegram, Slack, and custom webhooks. Email intentionally avoids a new SMTP dependency for now: it shells out to a configured `sendmail_path`, so production packaging still needs a real mail transport or a later SMTP provider.

When a non-desktop provider delivery fails, the daemon records the failed delivery and sends a local desktop failure alert when the desktop provider is enabled. Desktop alert failures are not recursively alerted, so a broken local notification path cannot cascade.

On macOS, the daemon desktop provider first looks for `terminal-notifier`. When available, notifications include an `ai-monitor://task/<task_id>` open URL so a registered desktop client can route the click back to the exact task. If `terminal-notifier` is not installed, the provider falls back to `osascript display notification`, which is delivery-only and cannot carry a task action.

The floating monitor sends its own clickable local UserNotifications for attention and completion states while it is running. Those notifications register an `Open` action, resolve the task ID through `GET /tasks/:id`, and then execute only allowlisted task actions.

## Delivery log

Every attempt gets a row in `notification_deliveries`.

Stored fields include:

- delivery ID
- event ID
- task ID
- provider ID
- status
- message or error
- timestamps

Diagnostics are available through:

- `GET /notifications/providers` for enabled provider configuration health.
- `GET /notifications/deliveries?task_id=...&event_id=...&provider_id=...&status=...` for delivery debug rows.
- `POST /notifications/deliveries/:id/retry` to retry a recorded delivery through the same provider.

`GET /tasks/:id` also includes delivery rows so task detail views can show timeline and delivery state together.

The macOS settings panel shows provider health inline using `GET /notifications/providers`. Task detail panels expose per-task delivery rows and a retry button backed by `POST /notifications/deliveries/:id/retry`.

## Quiet hours

Quiet hours suppress lower-priority notifications. `P0` can be allowlisted so critical events such as `needs_permission`, `waiting_for_input`, and `failed` still reach the user.
