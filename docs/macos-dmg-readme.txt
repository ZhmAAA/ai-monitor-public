AI Monitor for macOS
Requires macOS 13.0 or later.
Public releases support Apple Silicon and Intel Macs. Local development builds may only support the build machine's CPU architecture.
Read LICENSE.txt and THIRD-PARTY-NOTICES.txt for license terms and bundled dependency notices. Read PRIVACY.txt before installing if you want the local storage, permissions, and external notification defaults. Keep TROUBLESHOOTING.txt for offline first-run and integration recovery steps. Keep UNINSTALL.txt if you want cleanup steps after deleting the app. Double-click UNINSTALL.command only when you want to preview full cleanup; it asks for DELETE before removing anything.

Install:
1. Drag AI Monitor.app into Applications.
2. Open AI Monitor from Applications.
3. If macOS says it cannot verify the developer, this is not a public release build. Ask for a Developer ID signed and notarized DMG.

First run:
1. Settings opens automatically on first launch.
2. If it does not, open AI Monitor from the menu bar and choose Settings.
3. Click Copy setup guide if you want these steps on the clipboard.
4. AI Monitor starts the local daemon automatically when it is offline. Click Test connection; it should report the daemon online.
5. If Test connection says offline, click Start daemon and test again.
6. Click Copy API token when setting up the browser extension.
7. Click Open browser install link when installing the browser extension. Use Copy browser install link if you need to paste the link into a managed browser.
8. When macOS asks whether AI Monitor can control a browser or terminal app, choose Allow so task clicks can return to the right window.
9. Desktop app observer is optional. If you enable it, click Request Accessibility in Settings and allow AI Monitor in System Settings.
10. Click Install login daemon if you want AI Monitor to start after login. AI Monitor stops its app-started daemon before launchd starts the login daemon.
11. macOS notification permission is requested only when AI Monitor first needs to show a local alert.

Optional integrations:
- Browser: click Open browser install link in Settings, or install the Chrome Web Store or managed extension from <browser-extension-install-url>. Use Copy browser install link if you need to paste the link into a managed browser.
- IDE: if your release channel provides AI Monitor IDE Extension.vsix, install it from VS Code or Cursor with `Extensions: Install from VSIX...`. If VSIX install is unavailable, unzip AI Monitor IDE Extension.zip and use `Developer: Install Extension from Location...`. Run `AI Monitor: Send Test Event` after installing; if it fails, run `AI Monitor: Open Desktop Settings` and click Test connection.
- Terminal: if your release channel provides AI Monitor Terminal Integrations.zip, unzip it, then double-click `Install AI Monitor Terminal Integrations.command` from the unzipped folder. The wrapper checks for Node.js, copies the adapters to a stable user directory, then writes hooks. You can also run `./integrations/terminal/install-terminal-integrations.command --project /path/to/repo`; canceling the folder picker makes no changes.

Support:
- In Settings, click Open logs to reveal daemon.out.log and daemon.err.log.
- In Settings, click Open data folder to reveal config and local database files.
- In Settings, click Copy setup guide to copy first-run instructions without API tokens or provider secrets.
- In Settings, click Copy troubleshooting guide to copy the same recovery steps as TROUBLESHOOTING.txt after the DMG is gone.
- In Settings, click Copy license notices to copy the same license and bundled dependency notices as LICENSE.txt and THIRD-PARTY-NOTICES.txt.
- In Settings, click Copy privacy notice to copy the same privacy summary as PRIVACY.txt.
- In Settings, click Copy uninstall guide to copy the same cleanup steps as UNINSTALL.txt after the DMG is gone.
- In Settings, click Copy diagnostics to copy a support summary without API tokens or provider secrets.

Cleanup command:
- UNINSTALL.command first asks a running AI Monitor app to quit, then previews the cleanup paths.
- It removes app data only after you type DELETE in Terminal.
- Use UNINSTALL.txt if you want to remove files manually instead.

If Start daemon says to move the app, drag AI Monitor.app into Applications, eject the DMG, and reopen AI Monitor from Applications. The daemon is intentionally not started from a mounted DMG or translocated app path.

Quitting AI Monitor stops only the daemon it started itself. Install the login daemon if you want integrations to keep working after the app quits or after login.

Uninstall:
1. Quit AI Monitor.
2. Remove the login daemon in Settings if enabled. If login daemon install fails, make sure AI Monitor.app is in Applications and reopen it.
3. Delete /Applications/AI Monitor.app.
4. To remove all local data, click Copy uninstall guide in Settings or delete the local state folders below. Keep them if you want to preserve history, config, tokens, or logs for a later reinstall.

Local state lives in:
- ~/Library/Application Support/AI Monitor
- ~/.ai-monitor
- ~/Library/Logs/AI Monitor
- ~/Library/Preferences/<bundle-id>.plist
- ~/Library/LaunchAgents/<launch-agent-label>.plist

Packaged builds replace <bundle-id> and <launch-agent-label> with the exact values for that build.
