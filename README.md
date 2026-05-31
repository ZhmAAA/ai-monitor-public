# AI Monitor

[English](README.md) | [简体中文](README.zh-CN.md)

AI Monitor is an open-source, local-first monitor for AI work.

It collects task state from tools such as Claude Code, Codex CLI, Cursor, browser-based AI apps, IDE extensions, GitHub coding-agent pages, and terminal jobs, then shows what is running, completed, failed, or waiting for input in one local macOS floating panel.

## Current Status

This repository is the source release. There is no packaged installer published from this repo yet.

The current desktop app target is macOS. Windows and Linux desktop apps are not implemented yet.

## Requirements

- macOS 13.0 or later for the desktop panel.
- Rust toolchain for the daemon and core crates.
- Xcode Command Line Tools for Swift-based macOS UI development.
- Node.js for terminal and agent hook integrations.
- Chrome or another Chromium browser for the current browser extension workflow.

## Preview

![AI Monitor floating panel preview](docs/images/floating-monitor.png)

![AI Monitor clickable notification preview](docs/images/notification.png)

## Quick Start From Source

Clone the repository:

```bash
git clone https://github.com/notracc1210/ai-monitor-public.git
cd ai-monitor-public
```

Start the local daemon:

```bash
cargo run -p ai-monitor-daemon -- --bind 127.0.0.1:4318 --database ./ai-monitor.db --config ./config/default.toml
```

In another terminal, open the macOS floating monitor:

```bash
./scripts/run_macos_floating_window.sh
```

The daemon creates a local API token at:

```txt
~/.ai-monitor/api-token
```

Use that token when a browser extension or editor integration asks for one.

## Build A Local App Bundle

For local macOS development, you can build an app bundle:

```bash
./scripts/build_macos_app.sh
open "target/macos-app/AI Monitor.app"
```

This is a local development build. It is useful for testing the menu bar app, settings window, bundled daemon behavior, and click-to-return actions.

## Integrations

AI Monitor is built around small adapters that report task state to the local daemon.

| Surface | Current support |
| --- | --- |
| Browser | Chrome extension for ChatGPT, Claude, Gemini, Perplexity, Grok, and GitHub coding-agent pages. |
| IDE | VS Code and Cursor extension. JetBrains integration exists in source form. |
| Terminal | Shell commands, Claude Code hooks, Codex CLI hooks, compact terminal events, and Superset terminal hooks. |
| Desktop app observer | Optional macOS Accessibility-based observer for local desktop app state. Disabled by default. |

### Browser Extension

Load the extension from source:

```txt
chrome://extensions -> Developer Mode -> Load unpacked -> integrations/browser-extension/chrome
```

Open the extension popup, set the daemon URL to `http://127.0.0.1:4318`, paste the local API token, and click `Test`.

### VS Code Or Cursor

Install the source extension from the editor command palette:

```txt
Developer: Install Extension from Location...
```

Select:

```txt
integrations/ide/vscode
```

Then run:

```txt
AI Monitor: Send Test Event
```

### Terminal And Agent Hooks

Install project-local hooks:

```bash
./integrations/terminal/install-terminal-integrations.command --project /path/to/repo
```

Codex CLI requires `/hooks` trust review before non-managed command hooks run.

You can also wrap a command manually:

```bash
node integrations/terminal/ai-monitor-terminal.js run \
  --source terminal \
  --session-name "Daemon tests" \
  --title "Run daemon tests" \
  -- cargo test
```

## Notifications

Local desktop notifications are the default. Third-party notification providers are optional and are only used after you configure them.

Supported provider code exists for desktop, Slack, Telegram, Discord, Email, ntfy, Pushover, Bark, Feishu, WeCom, DingTalk, ServerChan, and custom webhooks.

## Privacy And Local Data

AI Monitor is local-first. The daemon binds to `127.0.0.1` by default, stores state on your Mac, and requires a local API token.

User data is stored outside the source repo:

- Config: `~/Library/Application Support/AI Monitor/config/default.toml`
- Database: `~/Library/Application Support/AI Monitor/ai-monitor.db`
- API token: `~/.ai-monitor/api-token`
- Logs: `~/Library/Logs/AI Monitor`

The API token file is created with `0600` permissions. Browser, terminal, Swift, and editor clients use the same local token.

See [docs/privacy.md](docs/privacy.md) and [docs/security.md](docs/security.md) for more detail.

## Development Checks

Run focused checks:

```bash
./scripts/test_terminal_integration.sh
./scripts/test_official_cli_hooks.sh
./scripts/test_browser_detectors.sh
./scripts/test_ide_integrations.sh
```

Run Rust tests:

```bash
cargo test --workspace
```

## Project Docs

- [Architecture](docs/architecture.md)
- [Integrations](docs/integrations.md)
- [Protocol and API](docs/protocol.md)
- [Notification system](docs/notification-system.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Uninstall guide](docs/uninstall.md)
