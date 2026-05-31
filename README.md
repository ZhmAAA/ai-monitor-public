# AI Monitor

[English](README.md) | [简体中文](README.zh-CN.md)

AI Monitor lets you see all of your AI work in one local floating panel.

If you have several AI tools running at the same time, such as Claude Code, Codex CLI, Cursor, ChatGPT, Claude, Gemini, GitHub agents, browser tabs, and terminal jobs, AI Monitor shows what is running, what finished, what failed, and what needs your input. It can also notify you when a task needs attention.

## Requirements

- macOS 13.0 or later.
- Apple Silicon and Intel Macs are supported by public release builds.
- Windows and Linux desktop apps are not supported yet.

## What It Looks Like

![AI Monitor floating panel preview](docs/images/floating-monitor.png)

![AI Monitor clickable notification preview](docs/images/notification.png)

## What It Helps With

- Keep one small panel open instead of checking every AI tab, editor, and terminal window by hand.
- Notice when an agent is done, stuck, failed, or waiting for permission.
- Click a task row or notification to return to the browser tab, editor, terminal session, or workspace that produced it.
- Send high-signal alerts to local desktop notifications, or optionally to services such as Slack, Telegram, Discord, Email, ntfy, Pushover, Bark, Feishu, WeCom, DingTalk, ServerChan, or a custom webhook.

## Quick Start

1. Download the public `AI Monitor.dmg`.
2. Open the DMG and drag `AI Monitor.app` into `/Applications`.
3. Open `AI Monitor.app` from `/Applications`.
4. In Settings, click `Test connection`. If it says offline, click `Start daemon`, then test again.
5. Use `Open browser install link`, then click `Copy API token`, paste it into the browser extension popup, and click `Test`.

Settings opens automatically on first launch. You can reopen it later from the menu bar item.

The app starts its bundled local daemon automatically when the daemon is offline; `Start daemon` is the manual retry path if `Test connection` still reports offline. If you want integrations to keep working after you quit AI Monitor or after login, install the login daemon from Settings.

## Supported Inputs

AI Monitor is built around small adapters that report task state to the local app.

| Surface | Current support |
| --- | --- |
| Browser | Chrome extension for ChatGPT, Claude, Gemini, Perplexity, Grok, and GitHub coding-agent pages. |
| IDE | VS Code and Cursor extension. JetBrains integration exists in source form. |
| Terminal | Shell commands, Claude Code hooks, Codex CLI hooks, compact terminal events, and Superset terminal hooks. |
| Desktop app observer | Optional macOS Accessibility-based observer for local desktop app state. Disabled by default. |

## Notifications

Local desktop notifications are the default. Third-party notification providers are not configured on a new install, and provider secrets are only saved when you add them in Settings or in the config file.

macOS notification permission is requested only when AI Monitor first needs to show a local alert while local clickable notifications are enabled.

## Privacy And Local Data

AI Monitor is local-first. The daemon binds to `127.0.0.1` by default, stores state on your Mac, and requires a local API token.

User data is stored outside the source repo:

- Config: `~/Library/Application Support/AI Monitor/config/default.toml`
- Database: `~/Library/Application Support/AI Monitor/ai-monitor.db`
- API token: `~/.ai-monitor/api-token`
- Login daemon: `~/Library/LaunchAgents/<bundle-id>.daemon.plist`

The API token file is created with `0600` permissions. The browser extension uses the token you paste into its popup; terminal and Swift clients read the same token file automatically.

See [docs/privacy.md](docs/privacy.md) and [docs/security.md](docs/security.md) for more detail.

## Install Integrations

### Browser Extension

Public browser users install the Chrome Web Store or managed extension from the release install link. Set `AI_MONITOR_BROWSER_EXTENSION_INSTALL_URL` before a public build so Settings can open or copy that link and the release manifest records the same URL. Set `AI_MONITOR_BROWSER_EXTENSION_PRIVACY_POLICY_URL` to the public HTTPS privacy policy URL used in the browser extension listing.

For internal testing from a source checkout:

```txt
chrome://extensions -> Developer Mode -> Load unpacked -> integrations/browser-extension/chrome
```

### VS Code Or Cursor

Install the packaged VSIX with `Extensions: Install from VSIX...`, then run `AI Monitor: Send Test Event`.

If delivery fails, run `AI Monitor: Open Desktop Settings`, click `Test connection`, and copy the API token if the extension reports an auth error.

### Terminal And Agent Hooks

For packaged releases, unzip `AI Monitor Terminal Integrations.zip` and double-click `Install AI Monitor Terminal Integrations.command`.

From a source checkout, install project-local hooks with:

```bash
./integrations/terminal/install-terminal-integrations.command --project /path/to/repo
```

Codex CLI requires `/hooks` trust review before non-managed command hooks run.

## Troubleshooting

- If no tasks appear, open Settings and click `Test connection`.
- If the browser extension reports HTTP 401, click `Copy API token` in Settings, paste it into the extension popup, save, and test again.
- If terminal tasks do not appear, confirm Node.js is installed and reinstall the terminal integrations.
- If clicking a task does not focus the right app, allow AI Monitor in macOS System Settings -> Privacy & Security -> Automation.

See [docs/troubleshooting.md](docs/troubleshooting.md) for the full recovery guide.

## For Developers

Run the local daemon:

```bash
cargo run -p ai-monitor-daemon -- --bind 127.0.0.1:4318 --database ./ai-monitor.db --config ./config/default.toml
```

Run focused integration checks:

```bash
./scripts/test_terminal_integration.sh
./scripts/test_official_cli_hooks.sh
./scripts/test_browser_detectors.sh
./scripts/test_ide_integrations.sh
```

Build a local macOS app bundle:

```bash
./scripts/build_macos_app.sh
open "target/macos-app/AI Monitor.app"
```

## Private Test Download

For a quick internal test, you can package and stage the current app without Apple notarization:

```bash
./scripts/stage_private_test_release.sh
```

Send testers the files in `target/macos-public-release`. This path is only for people who expect a test build: macOS may warn that the app is from an unidentified developer, and browser extension links are not fully configured unless you provide `AI_MONITOR_BROWSER_EXTENSION_INSTALL_URL` and `AI_MONITOR_BROWSER_EXTENSION_PRIVACY_POLICY_URL`.

## Public Release

Prepare release environment values from the template, then run the public release script:

```bash
./scripts/init_macos_release_env.sh
${EDITOR:-vi} .env.release.local
set -a
. ./.env.release.local
set +a
./scripts/release_macos_app.sh
```

Publish `target/macos-public-release/AI Monitor.dmg`, not raw files from `target/macos-dist`.

Developer and maintainer references:

- [Architecture](docs/architecture.md)
- [Integrations](docs/integrations.md)
- [Protocol and API](docs/protocol.md)
- [Notification system](docs/notification-system.md)
- [macOS release checklist](docs/release.md)
- [Uninstall guide](docs/uninstall.md)
