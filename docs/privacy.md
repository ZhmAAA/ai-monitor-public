# Privacy

AI Monitor is designed as local-first software.

## What Stays Local

AI Monitor stores task state on your Mac. This can include task titles, status, short messages, source information, timestamps, and return-to-app metadata used when you click a task row or notification.

Local data is stored in:

- `~/Library/Application Support/AI Monitor`
- `~/.ai-monitor`
- `~/Library/Logs/AI Monitor`

## Browser Extension

The browser extension detects task state on supported AI websites and reports it to the AI Monitor app running locally on your Mac.

The extension may read lightweight page information such as the current tab title, page URL, visible task status, and short task labels. It stores local settings such as the daemon URL and API token in Chrome extension storage.

The extension does not send data to an AI Monitor cloud service.

## External Notifications

Local desktop notifications are the default.

Third-party notification providers such as Slack, Telegram, Discord, ntfy, email, or webhooks are optional. They are only used after you configure them in Settings.

When external providers are used, AI Monitor is designed to avoid sending full local workspace paths, full prompts, or full AI replies by default.

## Permissions

AI Monitor may ask for:

- Notification permission, to show local alerts.
- Automation permission, to bring a browser, editor, or terminal window forward when you click a task.
- Accessibility permission, only if you enable the optional Desktop app observer.

The Desktop app observer is disabled by default.

## User Control

You can uninstall the app and remove local data at any time. See [Uninstall](uninstall.md).
