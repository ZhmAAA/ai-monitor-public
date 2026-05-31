# Integrations

Integrations translate external tool state into `AgentTaskEvent`.

## Browser extension

Initial targets:

- ChatGPT
- Claude
- Gemini
- Perplexity
- Grok
- GitHub

Detected states:

- generating
- completed
- retry/error
- waiting for user input
- page unfocused while work continues

### Chrome Extension

The first Chrome extension lives in `integrations/browser-extension/chrome`.

It is a no-build Manifest V3 extension with:

- `content.js`: observes supported AI pages and classifies `running`, `completed`, `failed`, and `waiting_for_input`.
- `background.js`: turns content-script messages into `AgentTaskEvent` and posts them to `POST /events`.
- `popup.html`: lets the user set the daemon URL, workspace name, and send a test event.

The browser adapter fills:

```txt
app = "chrome"
session_name = cleaned tab title
window_title = full tab title + " - Chrome"
source = chatgpt-web / claude-web / gemini-web / perplexity-web / grok-web / github-web
```

Detection remains heuristic, but selector fixtures now cover ChatGPT, Claude, Gemini, Perplexity, Grok, and GitHub Copilot-style pages. Run `./scripts/test_browser_detectors.sh` before changing browser selectors.

## IDE extensions

Initial targets:

- VS Code
- Cursor
- JetBrains IDEs

Detected states:

- agent started
- running
- pending diff approval
- pending changes
- tests running
- tests failed
- PR created
- completed

### VS Code / Cursor Extension

The first VS Code-compatible extension lives in `integrations/ide/vscode`.

It is a no-build extension with:

- manual commands for `running`, `waiting_for_input`, `idle_but_not_done`, `completed`, and `failed`
- test-specific commands for `tests running` and `tests failed`
- a PR-created completion command
- a first-run `AI Monitor: Send Test Event` command
- `AI Monitor: Open Desktop Settings` for token or daemon recovery through `ai-monitor://settings`
- automatic reporting for VS Code task process start/end
- workspace and active-file actions for return navigation

Cursor can load the same extension. Set `aiMonitor.source = "cursor"` so the daemon records `source = cursor` and emits Cursor-specific return actions.

### JetBrains Plugin

The first JetBrains plugin lives in `integrations/ide/jetbrains`.

It includes plugin metadata, settings, Tools menu actions, an HTTP client for posting `AgentTaskEvent` records, and an `ExecutionListener` for automatic run configuration lifecycle reporting. Run configurations are reported as running/completed/failed, and test-like runs are reported as test states. Manual state reporting and task clearing remain available from the Tools menu. VCS-specific and third-party agent-plugin hooks are still pending.

Run `./scripts/test_ide_integrations.sh` before changing IDE adapter manifests or entrypoints.

## Terminal adapters

Initial targets:

- Claude Code
- Codex CLI
- Gemini CLI
- OpenCode
- Aider
- tmux
- iTerm2
- Warp
- shell commands

Preferred signal order:

```txt
official hooks
> shell integration
> terminal output parser
> process monitor
> tmux / iTerm2 / Warp integration
```

### Terminal Adapters

The first terminal adapter lives in `integrations/terminal`.

It is a no-dependency Node script that can:

- post a single terminal state event with `event`
- wrap any command with `run`
- remove a terminal task with `close`
- send compact terminal events to `POST /terminal/events`
- fall back to `POST /events` when talking to an older daemon
- emit `running`, then `completed`, `failed`, or `cancelled`
- delete a wrapped command task on `SIGHUP` so closing the terminal window clears the task
- attach terminal session metadata such as `TERM_SESSION_ID`, `TMUX_PANE`, parent process id, and workspace
- fail open by default, so monitor delivery failures do not stop the wrapped command

Examples:

```bash
node integrations/terminal/ai-monitor-terminal.js event \
  --source codex-cli \
  --session-name "Codex auth refactor" \
  --title "Fix login bug" \
  --status running
```

```bash
node integrations/terminal/ai-monitor-terminal.js run \
  --source terminal \
  --session-name "Daemon tests" \
  --title "Run cargo test" \
  -- cargo test
```

For interactive agents, the adapters use explicit hook calls rather than parsing terminal output. This keeps Claude Code, Codex CLI, and tmux sessions interactive because their stdin/stdout stay attached to the real terminal.

Use `--strict` or `AI_MONITOR_STRICT=1` when an integration test should fail if the daemon cannot receive the event. Normal shell hooks should usually stay best-effort.

Use `close` or the shell helper's `aim-close` when a terminal session ends. The shell helper installs an `EXIT` trap when no existing trap is present, which removes the session task after the terminal window is closed.

Current wrappers:

```txt
integrations/terminal/claude-code/hook.sh
integrations/terminal/codex-cli/hook.sh
integrations/terminal/shell/ai-monitor.sh
```

### Official Claude Code / Codex CLI hooks

AI Monitor also ships official lifecycle hook adapters:

```txt
integrations/terminal/claude-code/official-hook.sh
integrations/terminal/codex-cli/official-hook.sh
integrations/terminal/install-terminal-integrations.command
integrations/terminal/install-packaged-integrations.js
integrations/terminal/install-official-hooks.js
```

The wrappers read each CLI's official hook JSON from stdin, translate lifecycle events such as `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `Notification`, and `Stop` into terminal task states, and post them to `POST /terminal/events`. `SessionEnd` and archive-like lifecycle events delete the current task through `DELETE /tasks/:id`, so archived or closed Codex sessions do not remain active.

Install project-local hooks:

```bash
./integrations/terminal/install-terminal-integrations.command --project /path/to/repo
```

For packaged installs, `install-terminal-integrations.command` checks that Node.js is available, then calls `install-packaged-integrations.js`. The packaged installer first copies the adapters to `~/Library/Application Support/AI Monitor/terminal-integrations`, then writes hook config pointing at that stable copy. This keeps hooks working after the user deletes the unzipped Downloads folder. Source checkouts can still call `install-official-hooks.js` directly.

The packaged zip also includes `Install AI Monitor Terminal Integrations.command` at the root for ordinary macOS users. It forwards to the same packaged installer and is the preferred double-click entry point.
The packaged installer is idempotent: rerunning it updates the stable copy, and running the copied installer from the stable directory can add hooks for another repo without recopying itself.
Project hook paths must already exist. The installers reject missing project directories instead of creating `.claude` or `.codex` config folders under a typo path.

Claude Code loads project hooks from `.claude/settings.json` or `.claude/settings.local.json`. Codex CLI loads hooks from `.codex/hooks.json` or inline `[hooks]` config, and requires `/hooks` trust review before non-managed command hooks run.

Set `AI_MONITOR_SESSION` to control the name shown in the floating panel. Set `AI_MONITOR_TASK_ID` when several events should merge into the same current task.

Deep-link behavior is provided through `AI_MONITOR_TERMINAL_TARGET`. If it is set, the primary action is `open_terminal_session`; otherwise the floating monitor activates the detected terminal app and exposes the workspace path as a fallback action.

### Superset terminals

Superset is treated as a terminal surface aggregator instead of a single terminal app. The integration hooks into Superset's existing `~/.superset/hooks/notify.sh` pipeline and forwards each lifecycle event to AI Monitor through `integrations/superset/ai-monitor-superset-hook.js`.

Identity is ordered by precision:

```txt
SUPERSET_PANE_ID
> SUPERSET_TAB_ID
> SUPERSET_TERMINAL_ID
> TMUX_PANE
> TERM_SESSION_ID
```

The daemon uses the same surface key to delete older terminal tasks before recording a new one. This means switching one Superset pane from Codex to Claude replaces the pane's previous task, while other panes in the same Superset window stay visible.

Install the fan-out:

```bash
node integrations/superset/install-ai-monitor-hook.js
```
