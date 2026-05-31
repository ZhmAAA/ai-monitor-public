# Deeplink Router

Notifications become useful when they return the user to the exact work surface.

## Targets

AI Monitor should support opening:

- browser tab
- terminal session
- tmux pane
- iTerm2 window
- Warp session
- VS Code workspace
- Cursor composer
- GitHub PR
- Slack thread
- Notion page
- file path and line number

## Action model

Every task can include `actions`.

```json
{
  "label": "Open Terminal",
  "type": "open_terminal_session",
  "target": "iterm://session/abc"
}
```

The daemon stores actions but does not execute arbitrary commands in this milestone. Desktop clients should validate and route known action types through platform-specific APIs.

The macOS floating monitor currently implements the first allowlist router:

- `open_browser_tab`: `http` and `https` URLs only; opens through Chrome tab activation.
- `open_url`: `http`, `https`, or local `file://` URLs.
- `open_file`: absolute local paths or `file://` URLs.
- `open_terminal_session`, `open_tmux_pane`, `open_iterm_window`, `open_warp_session`: only known terminal URL schemes such as `iterm`, `iterm2`, and `warp`; otherwise it falls back to activating the terminal app.
- `open_vscode_workspace`: `vscode` / `vscode-insiders` URLs or local workspace paths.
- `open_cursor_composer`: `cursor` URLs.
- `open_github_pr`: `https://github.com/...` only.
- `open_slack_thread`: Slack workspace HTTPS URLs.
- `open_notion_page`: Notion HTTPS or `notion://` URLs.

Unknown action types and unknown URL schemes are ignored rather than executed.

Task notification callbacks use `ai-monitor://task/<task_id>`. A desktop client must resolve that ID through `GET /tasks/:id` before executing the task's own allowlisted action.

The browser extension setup popup and VS Code/Cursor extension recovery command may also open `ai-monitor://settings`. The macOS app handles that route locally by opening Settings; it does not execute a task action or forward the URL to the OS.

## Stored context

Useful deeplink metadata includes:

- `browser_tab_id`
- `window_id`
- `process_id`
- `terminal_session_id`
- `workspace_path`
- `repo_url`
- `thread_url`
- `file_path`
- `line_number`
- `app_bundle_id`

## Safety

The deeplink router must be allowlist based. Unknown action types should be shown as plain metadata instead of executed.
