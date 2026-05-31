# AI Monitor Terminal Integration

This adapter lets terminal-based agents and shell commands report task state to the local daemon. It sends compact terminal events to `POST /terminal/events` and falls back to `POST /events` for older daemons.

For non-source installations, unzip:

```txt
target/macos-dist/AI Monitor Terminal Integrations.zip
```

Then double-click the root installer, or install the adapters into a stable user directory from Terminal:

```txt
Install AI Monitor Terminal Integrations.command
```

```bash
./integrations/terminal/install-terminal-integrations.command --project /path/to/repo
```

Both command wrappers check that Node.js is installed, copy the adapter files to `~/Library/Application Support/AI Monitor/terminal-integrations`, and write hook config that points at that stable copy. Double-click setup prompts for an existing project folder and makes no changes if the prompt is canceled.
You can rerun the same command after updates, or run the copied installer from the stable directory when adding hooks for another repo.
Project hook paths must already exist; the installer will not create a missing project directory. If it reports a missing path, open the target repo in Finder or Terminal and rerun the command with that directory.

## Direct Events

```bash
node integrations/terminal/ai-monitor-terminal.js event \
  --source codex-cli \
  --session-name "Codex auth refactor" \
  --title "Fix login bug" \
  --status running
```

Useful statuses:

```txt
running
thinking
executing_tool
waiting_for_input
needs_permission
completed
failed
idle_but_not_done
```

## Wrap A Command

```bash
node integrations/terminal/ai-monitor-terminal.js run \
  --source terminal \
  --session-name "Tests" \
  --title "Run daemon tests" \
  -- cargo test
```

The wrapper emits:

- `running` before the command starts.
- `completed` when it exits with code `0`.
- `failed` when it exits with a non-zero code.
- `cancelled` when the wrapper receives `SIGINT` or `SIGTERM`.
- a task delete when the wrapper receives `SIGHUP`, which is the common terminal-window-close signal.

The wrapper is best-effort by default. If the daemon is offline, the command still runs and exits with the command's real exit code. Add `--strict` or set `AI_MONITOR_STRICT=1` when you want monitor delivery failures to make the wrapper fail.

The adapter sends `x-ai-monitor-token` automatically from `AI_MONITOR_API_TOKEN`, `AI_MONITOR_API_TOKEN_FILE`, or `~/.ai-monitor/api-token`.

To explicitly remove a terminal task from the active task store:

```bash
node integrations/terminal/ai-monitor-terminal.js close --task-id terminal_session_123
```

## Shell Helpers

```bash
source integrations/terminal/shell/ai-monitor.sh

aim-event running "Research auth failure"
aim-event waiting_for_input "Codex needs input"
aim-run "Run tests" cargo test
aim-close
```

When sourced, the helper installs an `EXIT` trap if no existing trap is present. That trap calls `aim-close`, so the shell session task disappears when the terminal window closes. Set `AI_MONITOR_AUTO_CLOSE_TRAP=0` before sourcing to disable this.

## Claude Code / Codex CLI

The generic wrappers still accept status/title arguments or environment variables:

```bash
integrations/terminal/claude-code/hook.sh needs_permission "Claude Code approval"
integrations/terminal/codex-cli/hook.sh waiting_for_input "Codex needs input"
```

Equivalent environment form:

```bash
AI_MONITOR_STATUS=completed \
AI_MONITOR_TITLE="Codex finished auth refactor" \
integrations/terminal/codex-cli/hook.sh
```

Wire these wrappers into official tool hooks when a CLI exposes them. If a tool does not expose hooks yet, call `aim-event` manually at the points where the agent starts, waits, finishes, or fails.

## Official Hooks

Claude Code and Codex CLI can call AI Monitor directly from their official lifecycle hooks.

Install project-local Claude Code hooks:

```bash
./integrations/terminal/install-terminal-integrations.command --claude-project /path/to/repo
```

This writes or updates:

```txt
/path/to/repo/.claude/settings.local.json
```

Install project-local Codex CLI hooks:

```bash
./integrations/terminal/install-terminal-integrations.command --codex-project /path/to/repo
```

This writes or updates:

```txt
/path/to/repo/.codex/hooks.json
```

Codex requires hook trust review before non-managed command hooks run. Open `/hooks` in Codex CLI and trust the AI Monitor hook entries.

To install globally for your user instead of a single repo:

```bash
./integrations/terminal/install-terminal-integrations.command --user
```

For source checkouts, or when you have already copied the package to a permanent location yourself, you can call the lower-level installer directly:

```bash
node integrations/terminal/install-official-hooks.js claude-code --project /path/to/repo
node integrations/terminal/install-official-hooks.js codex-cli --project /path/to/repo
```

The official wrappers read the hook JSON from stdin and emit terminal events:

```bash
integrations/terminal/claude-code/official-hook.sh
integrations/terminal/codex-cli/official-hook.sh
```

They are quiet and best-effort by default so hook output does not pollute the agent transcript. Set `AI_MONITOR_HOOK_DEBUG=1` to print delivery logs.

`SessionEnd` and archive-like lifecycle events delete the matching task through `DELETE /tasks/:id`, so closed or archived Codex sessions do not remain in the active task list.

## Superset

Superset already routes agent lifecycle events through `~/.superset/hooks/notify.sh`. Install the AI Monitor fan-out to mirror those events into the daemon:

```bash
node integrations/superset/install-ai-monitor-hook.js
```

The installer keeps Superset's existing hook behavior and inserts a small call to:

```txt
integrations/superset/ai-monitor-superset-hook.js
```

Superset task identity uses the pane first, then the tab, then the terminal. That lets AI Monitor replace an old agent task when the same Superset pane switches from Codex to Claude, while keeping separate panes independent.

## Environment

```txt
AI_MONITOR_URL              default http://127.0.0.1:4318
AI_MONITOR_WORKSPACE        default current working directory
AI_MONITOR_SESSION          terminal session name shown in the floating panel
AI_MONITOR_TASK_ID          stable task id; defaults to source + workspace + session
AI_MONITOR_SOURCE           terminal, codex-cli, claude-code, gemini-cli, etc.
AI_MONITOR_TERMINAL_TARGET  deep-link target such as iterm://session/abc
AI_MONITOR_API_TOKEN        local daemon API token
AI_MONITOR_API_TOKEN_FILE   token file, default ~/.ai-monitor/api-token
AI_MONITOR_QUIET           set to 1 to suppress adapter stderr logs
AI_MONITOR_STRICT           set to 1 to fail when daemon delivery fails
AI_MONITOR_TIMEOUT_MS       HTTP delivery timeout, default 1500
AI_MONITOR_HOOK_DEBUG       set to 1 to print official-hook delivery logs
AI_MONITOR_AUTO_CLOSE_TRAP  set to 0 to skip shell EXIT trap installation
AI_MONITOR_SUPERSET_DISABLE set to 1 to disable Superset fan-out
```

Use a stable `AI_MONITOR_TASK_ID` when multiple events belong to the same terminal task.

For `run`, the adapter creates a unique task id per wrapped command unless `AI_MONITOR_TASK_ID` or `--task-id` is supplied. This prevents sequential commands in the same terminal session from overwriting each other.

If `AI_MONITOR_TERMINAL_TARGET` is not set, the floating monitor activates the detected terminal app when the row is clicked. The event still includes an `Open workspace` fallback action.
