# AI Monitor VS Code / Cursor Extension

This no-build extension reports IDE task state to the local AI Monitor daemon.

## Packaged Install

For non-source installations, unzip:

```txt
target/macos-dist/AI Monitor IDE Extension.vsix
target/macos-dist/AI Monitor IDE Extension.zip
```

Install the VSIX with `Extensions: Install from VSIX...`. If your editor cannot install the VSIX from your release channel, unzip `AI Monitor IDE Extension.zip`, run `Developer: Install Extension from Location...`, and select the unzipped folder. The extension reads `~/.ai-monitor/api-token` automatically when `AI Monitor: Api Token` is empty.

After installing, run `AI Monitor: Send Test Event` from the command palette. If delivery fails, choose `Open AI Monitor Settings`, click `Test connection`, and use `Copy API token` if the token file needs to be created.

Cursor can load the same extension. Set `AI Monitor: Source` to `cursor` so the daemon records events as `cursor`.

## Source Install

1. Open VS Code or Cursor.
2. Run `Developer: Install Extension from Location...`.
3. Select `integrations/ide/vscode`.
4. Configure `AI Monitor: Daemon Url` and `AI Monitor: Api Token` if the defaults are not enough.

## Commands

- `AI Monitor: Report Running`
- `AI Monitor: Send Test Event`
- `AI Monitor: Open Desktop Settings`
- `AI Monitor: Report Waiting For Input`
- `AI Monitor: Report Pending Changes`
- `AI Monitor: Report Tests Running`
- `AI Monitor: Report Tests Failed`
- `AI Monitor: Report PR Created`
- `AI Monitor: Report Completed`
- `AI Monitor: Report Failed`
- `AI Monitor: Clear Current IDE Task`

When `aiMonitor.autoReportTasks` is enabled, VS Code task starts and exits are also sent to AI Monitor. Test-like tasks are reported as test states.

## Scope

This is the first IDE adapter. It provides local task visibility, workspace/file deep links, task-process reporting, and manual agent-state commands. It does not yet inspect specific third-party IDE agent extensions or JetBrains IDE runtime state.
