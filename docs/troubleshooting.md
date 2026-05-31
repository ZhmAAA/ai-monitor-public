# Troubleshooting

Use this when AI Monitor opens but does not show tasks or an integration cannot connect.

If you are setting up AI Monitor for the first time, Settings should open automatically. If it does not, open AI Monitor from the menu bar, choose Settings, and click `Copy setup guide`. That copies the current first-run checklist plus non-secret app settings.

## Daemon Offline

AI Monitor starts the local daemon automatically when it is offline. Open AI Monitor Settings and click `Test connection`; if it reports offline, click `Start daemon` and test again.

If it still reports offline:

- Confirm the URL is `http://127.0.0.1:4318`.
- In Settings, click `Open logs` and check `daemon.err.log`. The same `daemon.out.log` and `daemon.err.log` files are used by both Settings-started and login-daemon-started processes.
- Remove the login daemon in Settings, install it again, then test connection.
- If the login daemon is already running, `Start daemon` reports that running daemon instead of starting a second local daemon.
- If you started the daemon manually and then install the login daemon, AI Monitor stops its app-started daemon first so launchd can bind the local port.
- If `Start daemon` or login daemon install says to move the app, drag `AI Monitor.app` into `/Applications`, eject the DMG, reopen it from Applications, then test again.
- If integrations should keep working after you quit AI Monitor, install the login daemon. Quitting the app stops only the daemon process the app started itself.

## Token Or Auth Errors

If Settings or the browser extension reports HTTP 401:

1. Open AI Monitor Settings.
2. Click `Copy API token`. If the token file does not exist yet, Settings creates it before copying.
3. Paste the token into the browser extension popup.
4. Click `Save`, then `Test`.
5. From the browser extension popup, `Open AI Monitor Settings` should open the same Settings panel through `ai-monitor://settings`.

The default token file is `~/.ai-monitor/api-token`.
The daemon and Settings write this file with `0600` permissions, and the daemon tightens older broader permissions when it reads the file.
The macOS login daemon references that file with `--api-token-file`; it should not contain the API token inside `~/Library/LaunchAgents/*.plist`.
Use `Clear Token` in the browser extension popup before pasting a rotated token or removing the extension from a shared browser profile.

## Browser Extension Does Not Report Tabs

- Confirm the extension popup says the daemon is online.
- Confirm the API token was saved in the popup.
- Click `Open AI Monitor Settings` in the extension popup if you need to return to the desktop settings page.
- In AI Monitor Settings, click `Open browser install link`, or click `Copy browser install link` for managed browsers, and confirm the extension came from that URL.
- Reload the AI web page after installing or updating the extension.
- Supported pages are ChatGPT, Claude, Gemini, Perplexity, Grok, and GitHub pages with explicit coding-agent signals.
- Public users should install the Chrome Web Store or managed extension. Developer Mode is for internal testing.

## Terminal Tasks Do Not Appear

- Confirm Node.js is installed.
- Reinstall hooks from the unzipped terminal integrations bundle:

```bash
./integrations/terminal/install-terminal-integrations.command --project /path/to/repo
```

  Ordinary macOS users can also double-click `Install AI Monitor Terminal Integrations.command` from the unzipped folder and choose the project folder.

- If the command says Node.js is missing, install Node.js and rerun it.
- This copies the adapters to `~/Library/Application Support/AI Monitor/terminal-integrations`; reinstall after replacing that directory.
- If the installer reports a missing project path, rerun it with an existing repo directory; it intentionally does not create project directories.
- In Codex CLI, open `/hooks` and trust the AI Monitor hooks.
- Run `Test connection` in Settings before debugging hooks.

## IDE Tasks Do Not Appear

- In VS Code or Cursor, run `AI Monitor: Send Test Event` from the command palette.
- If delivery fails, choose `Open AI Monitor Settings`, click `Test connection`, then retry the test event.
- If the warning mentions HTTP 401, click `Copy API token` in Settings or paste the copied token into `AI Monitor: Api Token`.
- Cursor users should set `AI Monitor: Source` to `cursor`.

## Clicking A Task Does Not Focus The App

- The first time AI Monitor returns to a browser or terminal window, macOS may ask whether AI Monitor can control that app. Choose `Allow`.
- If you previously denied the prompt, open System Settings -> Privacy & Security -> Automation, then allow AI Monitor to control the relevant browser or terminal app.
- AI Monitor only uses this permission to activate existing browser or terminal windows for click-to-return actions.

## Desktop App Observer Does Not Show Tasks

- The Desktop app observer is off by default because it uses macOS Accessibility APIs to read desktop app window state.
- Open Settings, enable `Desktop app observer`, then click `Request Accessibility`.
- In System Settings -> Privacy & Security -> Accessibility, allow AI Monitor. Reopen AI Monitor if macOS asks you to.
- `Copy diagnostics` includes `accessibility_trusted` so support can tell whether this permission is active.

## Local Notification Permission

AI Monitor does not request macOS notification permission just because the app opened. It asks only when `Local clickable notifications` is enabled and AI Monitor first needs to show a local alert. If notifications do not appear after you denied the prompt, open System Settings -> Notifications and allow AI Monitor.

## Support Diagnostics

Open Settings and click `Copy diagnostics`. The copied text excludes the API token and provider secrets, but includes app version, bundle identifier, minimum macOS version, current macOS version, paths, source toggles, provider IDs, whether the browser install link is configured, app bundle location, login daemon label, whether the login daemon plist is installed, whether the login daemon is loaded/running, and whether the token file exists with the expected permissions. Use `Copy troubleshooting guide` when support needs the exact packaged recovery checklist, `Copy license notices` when support needs bundled license and dependency notices, `Copy privacy notice` when support needs the packaged privacy summary, and `Copy uninstall guide` when the user needs cleanup steps after deleting the app.

Use `Open logs` to reveal daemon logs and `Open data folder` to reveal the config and local database directory.

## Notifications Do Not Appear

- Allow notifications for AI Monitor in macOS System Settings.
- In AI Monitor Settings, keep `Local clickable notifications` enabled.
- Third-party providers are disabled by default. Configure provider credentials, save them, restart the daemon, then click `Refresh health`.

## Clean Reinstall

Use [uninstall.md](uninstall.md) for full cleanup. Preview first:

```bash
./scripts/uninstall_macos_app.sh --dry-run
```
