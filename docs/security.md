# Security

AI Monitor should be treated as local software with access to your work context.

## Local API

AI Monitor uses a local daemon so browser, editor, and terminal integrations can report task state to the desktop app.

By default, the daemon listens on `127.0.0.1` and requires a local API token. Do not share this token publicly.

Use `Copy API token` in Settings when a browser extension or integration asks for it.

## macOS Permissions

AI Monitor may request macOS permissions for specific features:

- Notifications: show local task alerts.
- Automation: return to the app, browser tab, editor, or terminal window that produced a task.
- Accessibility: optional desktop app observation, disabled by default.

If you deny a permission, you can change it later in macOS System Settings.

## Browser Extension

The browser extension is limited to supported AI websites and localhost communication with the AI Monitor daemon.

Remove the extension from Chrome if you no longer want browser task monitoring.

## Reporting Issues

Use GitHub Issues on this repository for security or privacy concerns that do not contain secrets. Do not include API tokens, private prompts, logs with secrets, or private workspace paths in public issues.
