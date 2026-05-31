# Uninstall AI Monitor

AI Monitor keeps local data outside the app bundle so ordinary app updates do not erase your history or settings.

## Remove The App

1. Quit AI Monitor from the menu bar.
2. Open Settings and choose `Remove login daemon` if you enabled startup.
3. Delete `/Applications/AI Monitor.app`.

If you still have the DMG, you can read `UNINSTALL.txt` or run `UNINSTALL.command`. The command previews cleanup paths and asks for confirmation before deleting data.

## Remove Local Data

Delete these paths only if you want to remove AI Monitor history, settings, logs, and tokens:

- `~/Library/Application Support/AI Monitor`
- `~/.ai-monitor`
- `~/Library/Logs/AI Monitor`
- `~/Library/Preferences/<bundle-id>.plist`
- `~/Library/LaunchAgents/<launch-agent-label>.plist`

The exact bundle ID and launch agent label can vary by release channel. If you are unsure, use the uninstall guide bundled in the DMG or copy the uninstall guide from AI Monitor Settings before deleting the app.
