# Security

AI Monitor should be treated as privileged local software.

## Local API

The daemon binds to `127.0.0.1` by default and requires a local API token unless explicitly disabled.

Default behavior:

- If `AI_MONITOR_API_TOKEN` is set, that value is accepted as the token.
- Otherwise the daemon reads `AI_MONITOR_API_TOKEN_FILE`, or `~/.ai-monitor/api-token` by default.
- If the token file does not exist, the daemon creates it with `0600` permissions. If a token file already exists with broader permissions, the daemon tightens it back to `0600` when reading it. The macOS Settings `Copy API token` action also creates the same file before copying when needed, so browser setup does not require starting the daemon first.
- Clients send either `Authorization: Bearer <token>` or `x-ai-monitor-token: <token>`.
- `GET /live` also accepts `?token=<token>` for clients that cannot set WebSocket headers.

The macOS app starts both manual and login daemon processes with `--api-token-file`. If the Settings token field is populated, or if `Copy API token` needs to create a token, the app writes that value to the token file with `0600` permissions before starting the daemon. The token is not written into UserDefaults, the child-process environment, or the LaunchAgent plist. Legacy UserDefaults tokens from older builds are migrated to the token file and then removed.

Set `AI_MONITOR_DISABLE_API_AUTH=1` or `--disable-api-auth` only for local development.

The daemon no longer uses permissive CORS. Default allowed origins are localhost loopback origins and browser-extension origins. Add explicit origins in `[api].cors_allowed_origins` when building a desktop or web settings UI.

## Provider secrets

Development config can reference environment variables. Production provider fields can reference macOS Keychain items directly:

```toml
[[providers]]
id = "slack"
type = "slack"
enabled = true
webhook_url = "keychain://ai-monitor/slack-webhook-url"
```

The equivalent placeholder form is `${KEYCHAIN:ai-monitor:slack-webhook-url}`. The daemon resolves these with `/usr/bin/security find-generic-password -s <service> -a <account> -w`; the secret value is kept in process memory and is not written to SQLite delivery logs.

Provider delivery failure messages redact URLs before they are persisted, so webhook endpoints and bot-token URLs are not stored in delivery history when a request fails.

Environment variables remain acceptable for local development and CI smoke tests. The macOS settings panel can write provider secrets directly to Keychain through Security.framework and update the configured provider TOML field to the generated `keychain://...` reference.

## Webhooks

Webhook providers can leak task metadata. External providers receive redacted task copies by default: workspace paths are reduced to the folder name, prompt/reply metadata is replaced with `[redacted]`, and file actions lose local file paths.

## Actions

Deep links must be validated before execution. A notification action should open known apps, tabs, files, or URLs, not arbitrary shell commands.

The macOS client enforces action allowlists by `TaskAction.type`, URL scheme, and expected host. Unknown action types, unknown URL schemes, and non-absolute file paths are ignored. `ai-monitor://task/<id>` is treated as an internal callback only; the client resolves the task through the authenticated local API before opening any task action.
