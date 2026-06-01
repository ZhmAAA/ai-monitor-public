# AI Monitor for Windows

This is an experimental Windows desktop shell for AI Monitor. It keeps the existing Rust daemon and adds a Windows app surface for task monitoring.

## Scope

- Tauri + React app shell
- Connects to the local daemon at `http://127.0.0.1:4318`
- Shows task state from `/tasks`
- Listens for live task updates from `/live`
- Starts the daemon from the desktop app during development
- Opens task action targets through Windows

Not included yet:

- Windows UI Automation observer for local desktop AI apps
- Packaged updater/signing flow
- Full tray-only background mode

## Development

From this folder:

```powershell
npm install
npm run tauri:dev
```

The app builds the daemon first. In development it launches:

```txt
..\..\target\debug\ai-monitor-daemon.exe
```

Runtime data is written under the app data directory, including:

- `ai-monitor.db`
- `default.toml`
- `api-token`
- `logs\daemon.out.log`
- `logs\daemon.err.log`

## Web-only preview

You can also run the React surface without Tauri:

```powershell
npm run dev
```

Start the daemon separately from the repository root:

```powershell
.\target\debug\ai-monitor-daemon.exe --bind 127.0.0.1:4318 --database .\ai-monitor.db --config .\config\default.toml --api-token-file .\.ai-monitor\api-token
```
