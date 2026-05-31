# Uninstall AI Monitor

AI Monitor keeps user data outside the app bundle so ordinary app updates do not erase local history.

## Remove the app

1. Quit AI Monitor from the menu bar item.
2. Open AI Monitor settings and choose `Remove login daemon` if you enabled startup.
3. Delete `/Applications/AI Monitor.app`.

For an installed app without a source checkout, open Settings and choose `Copy uninstall guide` before deleting the app. The bundled guide includes the same local state paths and the current support guidance without requiring the DMG or repo. If the DMG is still available, double-click `UNINSTALL.command` to ask a running AI Monitor app to quit, preview the same cleanup, and type `DELETE` only when you intentionally want full removal.

## Remove local data

To remove all local state from a source checkout:

```bash
./scripts/uninstall_macos_app.sh --yes
```

The script removes:

- `/Applications/AI Monitor.app`
- `~/Library/LaunchAgents/<bundle-id>.daemon.plist` for public builds, or `~/Library/LaunchAgents/local.ai-monitor.daemon.plist` for local development builds
- `~/Library/Preferences/<bundle-id>.plist`
- `~/Library/Application Support/AI Monitor`
- `~/.ai-monitor`
- `~/Library/Logs/AI Monitor`

When removing a public build from a source checkout, the script reads the bundle identifier from `/Applications/AI Monitor.app` when it exists. If the app has already been deleted, set `AI_MONITOR_BUNDLE_ID` or `AI_MONITOR_LAUNCH_AGENT_LABEL` so the script targets the same preferences and login daemon label shown in `RELEASE_MANIFEST.json` and `Copy diagnostics`.

Preview the cleanup first:

```bash
./scripts/uninstall_macos_app.sh --dry-run
```

Keep selected state when needed:

```bash
./scripts/uninstall_macos_app.sh --yes --keep-data --keep-token --keep-logs --keep-preferences
```
