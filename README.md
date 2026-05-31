# AI Monitor

[English](README.md) | [简体中文](README.zh-CN.md)

> ⚠️ **Status:** This repo ships source code only — no packaged installer yet. Running it requires Rust, Xcode Command Line Tools, and Node.js. If you're not comfortable with a command-line setup, watch for the upcoming packaged app in [Releases](../../releases).

AI Monitor is an open-source, local-first monitor for AI work.

**Example:** When you have Claude Code, Cursor, and several ChatGPT tabs all running at once, AI Monitor shows you at a glance which ones finished, which ones failed, and which are waiting for you to click "approve" — all in one floating panel on your Mac.

It collects task state from Claude Code, Codex CLI, Cursor, browser-based AI apps, IDE extensions, GitHub coding-agent pages, and terminal jobs, then shows what is running, completed, failed, or waiting for input in one local macOS floating panel.

## Current Status

Source-only release. No packaged installer is published from this repo yet.

The current desktop target is macOS. Windows and Linux desktop apps are not implemented yet.

## Requirements

- macOS 13.0 or later
- [Rust toolchain](https://rustup.rs) — for the daemon
- Xcode Command Line Tools — for the floating panel (`xcode-select --install`)
- Node.js — for terminal and agent hook integrations

## Preview

![AI Monitor floating panel preview](docs/images/floating-monitor.png)

![AI Monitor notification preview](docs/images/notification.png)

## Quick Start

### Step 1 — Install prerequisites

Install Rust if you don't have it:

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

Install Xcode Command Line Tools if you don't have them:

```bash
xcode-select --install
```

### Step 2 — Clone the repo

```bash
git clone https://github.com/notracc1210/ai-monitor-public.git
cd ai-monitor-public
```

### Step 3 — Start the daemon

```bash
cargo run -p ai-monitor-daemon -- --bind 127.0.0.1:4318 --database ./ai-monitor.db --config ./config/default.toml
```

The daemon is the background service that receives task events from all your AI tools. **Keep this terminal window open the entire time you use AI Monitor.** Closing it stops all monitoring.

The first time you run this, Cargo downloads and compiles dependencies — it can take a few minutes.

### Step 4 — Build and open the floating panel

Open a **new terminal window** (leave the daemon window from Step 3 running), then:

```bash
./scripts/build_macos_app.sh
open "target/macos-app/AI Monitor.app"
```

The build step compiles FloatingMonitor.swift into a local app bundle. This takes a minute the first time. It requires Xcode Command Line Tools.

If macOS says it can't verify the developer, right-click the app → Open → Open anyway. This is expected for a local development build.

### Step 5 — Get your API token

```bash
cat ~/.ai-monitor/api-token
```

The daemon creates this file automatically on first run. You'll paste this token into the browser extension and IDE extension when setting them up below.

## Integrations

Set up the adapters for the tools you use. Each adapter reports task state to the daemon.

| Surface | What's supported |
| --- | --- |
| Browser | Chrome extension for ChatGPT, Claude, Gemini, Perplexity, Grok, and GitHub coding-agent pages |
| IDE | VS Code and Cursor extension; JetBrains plugin (source only) |
| Terminal | Claude Code hooks, Codex CLI hooks, shell command wrapper |
| Desktop app observer | Optional macOS Accessibility observer (disabled by default) |

### Browser Extension (Chrome)

1. Open `chrome://extensions` in Chrome
2. Enable **Developer Mode** (toggle in the top-right corner)
3. Click **Load unpacked** and select the folder: `integrations/browser-extension/chrome`

Then open the extension popup:
- Set **Daemon URL** to `http://127.0.0.1:4318`
- Paste your API token (from `cat ~/.ai-monitor/api-token`)
- Click **Test** — it should confirm the daemon is online

After installing, reload any open ChatGPT, Claude, Gemini, Perplexity, Grok, or GitHub coding-agent tabs.

### VS Code or Cursor

1. Open the Command Palette (`Cmd+Shift+P`)
2. Run **Developer: Install Extension from Location...**
3. Select the folder: `integrations/ide/vscode`
4. Run **AI Monitor: Send Test Event** to confirm it's working

For Cursor: after installing, set `AI Monitor: Source` to `cursor` in VS Code settings.

### Terminal and Agent Hooks (Claude Code, Codex CLI)

Install project-local hooks for a specific repo:

```bash
./integrations/terminal/install-terminal-integrations.command --project /path/to/your/repo
```

This requires Node.js. If Node.js is not installed, the script will say so and exit without making changes.

For Codex CLI: after the installer runs, open `/hooks` inside Codex CLI and trust the AI Monitor hooks.

**Wrap any command manually:**

```bash
node integrations/terminal/ai-monitor-terminal.js run \
  --source terminal \
  --session-name "My session" \
  --title "My task description" \
  -- your-command-here
```

## Notifications

Local desktop notifications are on by default. Third-party providers (Slack, Telegram, Discord, ntfy, Pushover, and more) are optional. See [docs/third-party-notifications.md](docs/third-party-notifications.md) to configure them.

## Privacy and Local Data

AI Monitor is local-first. The daemon binds to `127.0.0.1`, all data stays on your Mac, and every client uses the same local API token.

When running from source, the active config file is `./config/default.toml` (the one you passed to `--config`). Edit it to configure notifications, privacy rules, and quiet hours, then restart the daemon.

| What | Where |
| --- | --- |
| Config (source run) | `./config/default.toml` in the repo |
| Database | `./ai-monitor.db` in the repo (from the `--database` flag) |
| API token | `~/.ai-monitor/api-token` |
| Logs | daemon terminal window output |

See [docs/privacy.md](docs/privacy.md) for what gets stored and how to exclude specific workspaces.

## Docs

**For users:**
- [Troubleshooting](docs/troubleshooting.md) — daemon offline, token errors, integrations not working
- [Uninstall](docs/uninstall.md) — remove the daemon and all local data
- [Privacy](docs/privacy.md) — what's stored, what's not sent out, how to ignore a workspace
- [Third-party notifications](docs/third-party-notifications.md) — Slack, Telegram, Discord, and more
