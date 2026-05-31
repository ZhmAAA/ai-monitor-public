# Uninstall

[English](uninstall.md) | [简体中文](uninstall.zh-CN.md)

## Stop the Daemon

If the daemon is running as a terminal process, close that terminal window.

If you installed the login daemon (via `./scripts/install_macos_launch_agent.sh`), unload it first:

```bash
launchctl unload ~/Library/LaunchAgents/local.ai-monitor.daemon.plist
rm ~/Library/LaunchAgents/local.ai-monitor.daemon.plist
```

## Remove Integrations

**Browser extension:** open `chrome://extensions` and remove AI Monitor Browser Adapter.

**VS Code / Cursor extension:** uninstall via the Extensions panel in VS Code or Cursor.

**Terminal hooks:** the hooks are project-local files in `.claude/settings.json` or `.codex/hooks.json` inside each repo where you installed them. Delete the AI Monitor entries from those files, or reinstall with a different project path to overwrite them.

## Remove Local Data

Preview everything that will be removed:

```bash
./scripts/uninstall_macos_app.sh --dry-run
```

Remove everything:

```bash
./scripts/uninstall_macos_app.sh --yes
```

The script removes:

- `~/Library/Application Support/AI Monitor` — config and database
- `~/.ai-monitor` — API token
- `~/Library/Logs/AI Monitor` — daemon logs
- `~/Library/Preferences/<bundle-id>.plist` — if present
- `~/Library/LaunchAgents/local.ai-monitor.daemon.plist` — if installed

Keep selected items if needed:

```bash
./scripts/uninstall_macos_app.sh --yes --keep-data --keep-token --keep-logs
```

The source repo itself (the cloned folder) is not touched by the uninstall script. Delete it separately once you're done.
