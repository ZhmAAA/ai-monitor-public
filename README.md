# AI Monitor

[English](README.md) | [简体中文](README.zh-CN.md)

AI Monitor shows your AI work in one local macOS floating panel.

When you have several AI tools running at the same time, AI Monitor helps you see what is running, what finished, what failed, and what needs your input. It can also send local desktop notifications so you do not have to keep checking every tab, editor, and terminal window by hand.

## Requirements

- macOS 13.0 or later.
- Apple Silicon and Intel Macs are supported.
- Windows and Linux apps are not available yet.

## Preview

![AI Monitor floating panel preview](docs/images/floating-monitor.png)

![AI Monitor clickable notification preview](docs/images/notification.png)

## Download

Download the latest `AI Monitor.dmg` from [GitHub Releases](https://github.com/notracc1210/ai-monitor-public/releases).

## Quick Start

1. Download `AI Monitor.dmg`.
2. Open the DMG and drag `AI Monitor.app` into `/Applications`.
3. Open `AI Monitor.app` from `/Applications`.
4. Settings opens automatically on first launch.
5. Click `Test connection`. If it says offline, click `Start daemon`, then test again.
6. Use `Open browser install link` and `Copy API token` when setting up the browser extension.

## Supported Inputs

| Surface | Support |
| --- | --- |
| Browser | Chrome extension for ChatGPT, Claude, Gemini, Perplexity, Grok, and GitHub coding-agent pages. |
| IDE | VS Code and Cursor extension. |
| Terminal | Terminal integrations for shell commands, Claude Code hooks, and Codex CLI hooks. |
| Desktop app observer | Optional macOS Accessibility-based observer. Disabled by default. |

## Notifications

Local desktop notifications are enabled by default. Third-party notification services are optional and are only used after you configure them in Settings.

macOS notification permission is requested only when AI Monitor first needs to show a local alert.

## Privacy

AI Monitor is local-first. Task state is stored on your Mac, and the local daemon listens on `127.0.0.1` by default.

See [Privacy](docs/privacy.md) and [Security](docs/security.md) for more detail.

## Help

- [Troubleshooting](docs/troubleshooting.md)
- [Uninstall](docs/uninstall.md)
- [Browser extension privacy policy](docs/browser-extension-privacy-policy.md)

Use GitHub Issues on this repository for support reports.
