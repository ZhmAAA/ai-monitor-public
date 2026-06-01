# Windows Desktop MVP

The Windows desktop app lives in `apps/desktop-windows`.

It is an experimental Tauri + React shell around the existing Rust daemon. The first Windows milestone focuses on parity for task visibility rather than macOS-specific desktop observation.

## What works

- Starts the existing `ai-monitor-daemon.exe` from the Windows app in development
- Connects to `GET /tasks`
- Listens to `GET /live` over WebSocket
- Shows active, waiting, failed, completed, and all task filters
- Opens task action targets with the Windows shell
- Reads the app-local API token created by the daemon

## Run it

```powershell
cd apps\desktop-windows
npm install
npm run tauri:dev
```

## Package it

```powershell
cd apps\desktop-windows
npm run tauri:build
```

The build script compiles the daemon, copies it into `src-tauri/resources`, and then runs the Tauri build.

## Follow-up work

- Add a Windows tray icon and background lifecycle controls
- Register `ai-monitor://` deep links on Windows
- Add Windows toast notifications
- Add Windows UI Automation observer for local desktop AI apps
- Add CI packaging for NSIS/MSIX
