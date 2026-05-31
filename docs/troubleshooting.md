# Troubleshooting

This guide is for **source checkout users** who started the daemon with `cargo run`.

## Daemon Not Running

The daemon runs as a process in a terminal window. Check:

- Is the terminal window where you ran `cargo run` still open? Closing it stops the daemon.
- Restart the daemon if needed:

```bash
cargo run -p ai-monitor-daemon -- --bind 127.0.0.1:4318 --database ./ai-monitor.db --config ./config/default.toml
```

- Watch that terminal window for error output.
- If you see "address already in use", something else is already on port 4318:

```bash
lsof -i :4318
```

Kill the conflicting process, then restart the daemon.

## Token or Auth Errors (HTTP 401)

The daemon creates an API token at `~/.ai-monitor/api-token` on first run. Read it:

```bash
cat ~/.ai-monitor/api-token
```

Paste that value into the browser extension popup or the VS Code `AI Monitor: Api Token` setting.

If the file doesn't exist yet, start the daemon once — it creates the file automatically on startup.

## Browser Extension Not Reporting Tabs

- Confirm the daemon terminal window is still open and running.
- Open the extension popup and check:
  - Daemon URL is `http://127.0.0.1:4318`
  - API token matches `cat ~/.ai-monitor/api-token`
  - Popup says the daemon is online
- Reload the AI web page after installing or updating the extension.
- Supported pages: ChatGPT, Claude, Gemini, Perplexity, Grok, and GitHub coding-agent pages.
- Chrome will show a warning that this extension is not from the Web Store — that's expected. The extension is loaded directly from `integrations/browser-extension/chrome`.

## Terminal Tasks Not Appearing

- Confirm Node.js is installed: `node --version`
- Reinstall hooks for your project:

```bash
./integrations/terminal/install-terminal-integrations.command --project /path/to/your/repo
```

- If Node.js is missing, install it and rerun.
- For Codex CLI: open `/hooks` inside Codex CLI and confirm AI Monitor hooks are trusted.

## IDE Tasks Not Appearing

- Run **AI Monitor: Send Test Event** from the VS Code Command Palette (`Cmd+Shift+P`).
- If it fails: confirm the daemon terminal is running, and that `AI Monitor: Api Token` in VS Code settings matches `cat ~/.ai-monitor/api-token`.
- For Cursor: confirm `AI Monitor: Source` is set to `cursor`.

## Clicking a Task Does Not Focus the App

The first time AI Monitor returns focus to a browser or terminal window, macOS will ask for permission. Choose **Allow**.

If you already denied it: System Settings → Privacy & Security → Automation → allow AI Monitor to control the relevant app.

## Desktop App Observer

The Desktop app observer (reads window titles of local AI desktop apps via Accessibility APIs) is controlled by the packaged app's Settings panel. It is not configurable from the source daemon in this release.

## Notifications Not Appearing

- Local desktop notifications use `osascript` in source builds. If they don't appear, check System Settings → Notifications and allow notifications from Terminal (or whichever app is running the daemon).
- Third-party providers are disabled by default. See [docs/third-party-notifications.md](docs/third-party-notifications.md) to configure them. After editing `config/default.toml`, restart the daemon.

## Logs

The daemon logs to the terminal window where you ran `cargo run`. That window is your primary log view.

If you installed a login daemon via `./scripts/install_macos_launch_agent.sh`, logs go to:

```
~/Library/Logs/AI Monitor/daemon.out.log
~/Library/Logs/AI Monitor/daemon.err.log
```

Open that directory:

```bash
open ~/Library/Logs/AI\ Monitor
```

## Clean Reinstall

Preview what will be removed without deleting anything:

```bash
./scripts/uninstall_macos_app.sh --dry-run
```

See [docs/uninstall.md](docs/uninstall.md) for the full cleanup steps.
