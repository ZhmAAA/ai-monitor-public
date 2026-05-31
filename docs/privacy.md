# Privacy

AI Monitor is local-first. It stores data on your Mac and does not send your prompts, replies, or workspace paths to external services by default.

## What Gets Stored Locally

- Task status, task titles, short step messages, and timestamps
- Which tool reported the task (e.g. `claude-code`, `chatgpt-web`)
- Navigation info used to return you to the right browser tab or terminal window when you click a task

The local database location depends on how you started the daemon:

- **Running from source** (`--database ./ai-monitor.db`): `ai-monitor.db` in the repo folder
- **Packaged app** (future): `~/Library/Application Support/AI Monitor/ai-monitor.db`

## What Is Not Sent Out by Default

AI Monitor does **not** send the following to any external service by default:

- Your prompts or AI replies
- Full workspace paths
- Screenshots

These only leave your Mac if you enable a third-party notification provider (Slack, Telegram, etc.) in `config/default.toml`. Even then, workspace paths, prompts, and replies are redacted from outgoing notifications unless you explicitly change the defaults.

## How to Ignore a Workspace

To stop AI Monitor from monitoring a specific folder or tool, add ignore rules to `config/default.toml` and restart the daemon:

```toml
# Drop all events from this folder before they are stored
[[ignore_rules]]
id = "private-workspace"
mode = "ignore"
workspace_prefix = "/Users/you/private-project"

# Store events locally but never forward them to Slack, Telegram, etc.
[[ignore_rules]]
id = "local-only-chatgpt"
mode = "local_only"
source = "chatgpt-web"
```

`mode = "ignore"` — events are dropped before storage. Nothing is recorded.

`mode = "local_only"` — events are stored locally but never sent to external notification providers.

Rules can also match by app name or site substring. The daemon applies ignore rules before storage, so they act as a firm privacy boundary even if an integration misbehaves.

## API Token

The daemon creates a local API token at `~/.ai-monitor/api-token` with `0600` file permissions (only your user account can read it). All integrations — browser extension, IDE extension, terminal hooks — use this same token to authenticate with the local daemon.

No data is sent to any AI Monitor cloud service.
