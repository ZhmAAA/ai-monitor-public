# Agent Task Protocol

The Agent Task Protocol is the common language between integrations and AI Monitor.

## Event

`AgentTaskEvent` is the write model. Integrations send one event whenever observed task state changes.

```json
{
  "event_id": "evt_123",
  "task_id": "task_456",
  "source": "claude-code",
  "app": "terminal",
  "workspace": "/Users/you/ai-monitor-project",
  "session_name": "Backend refactor",
  "window_title": "Terminal - Backend refactor",
  "title": "Implement SQLite event store",
  "status": "needs_permission",
  "step": "Waiting for file edit approval",
  "message": "Claude Code wants permission to edit storage.rs",
  "confidence": 0.98,
  "priority": "P0",
  "notify_desktop": true,
  "notify_external": true,
  "created_at": "2026-05-28T12:30:00Z",
  "updated_at": "2026-05-28T12:31:00Z",
  "actions": [
    {
      "label": "Open Terminal",
      "type": "open_terminal_session",
      "target": "iterm://session/abc"
    }
  ],
  "metadata": {
    "process_id": 12345
  }
}
```

## Current task

`AgentTask` is the read model. It is aggregated from all events with the same `task_id`.

The dashboard should show the current task, while task detail views can show the raw event timeline and notification delivery debug rows.

`GET /tasks/:id` returns:

```json
{
  "task": {},
  "events": [],
  "deliveries": []
}
```

## Terminal event shortcut

Terminal integrations can either send a full `AgentTaskEvent` to `POST /events` or a compact terminal event to `POST /terminal/events`.

```json
{
  "source": "codex-cli",
  "task_id": "terminal_run_codex_123",
  "workspace": "/Users/you/ai-monitor-project",
  "session_name": "Daemon tests",
  "title": "cargo test",
  "status": "executing_tool",
  "step": "Running command",
  "message": "cargo test",
  "command": "cargo test",
  "pid": 12345,
  "terminal_program": "Apple_Terminal",
  "term_session_id": "ABCDEF",
  "tmux_pane": "%1",
  "target": "iterm://session/abc",
  "priority": "P2",
  "notify_desktop": true,
  "notify_external": true,
  "metadata": {
    "adapter_version": "terminal-0.2.0"
  }
}
```

The daemon expands this shortcut into a normal terminal `AgentTaskEvent`, adds `Open terminal` and `Open workspace` actions, and then uses the same storage, live stream, and notification path as `POST /events`.

When a terminal session closes, integrations should call `DELETE /tasks/:id`. This removes the current task row and its stored event history, so the task disappears from `/tasks` on the next dashboard refresh.

The daemon also runs a global stale-task GC. By default, `queued`, `starting`, `running`, `thinking`, `executing_tool`, and `unknown` tasks with no updates for 6 hours are converted to `stale` with a synthetic event. This prevents dead integrations from leaving a task permanently displayed as active. Set `AI_MONITOR_STALE_AFTER_SECONDS=0` to disable it.

Terminal aggregators can include surface metadata so newer tasks replace stale tasks from the same pane or terminal:

```json
{
  "metadata": {
    "superset_pane_id": "pane-123",
    "superset_tab_id": "tab-123",
    "superset_terminal_id": "terminal-123",
    "superset_agent_id": "claude"
  }
}
```

The daemon matches terminal surfaces in this order: `superset_pane_id`, `superset_tab_id`, `superset_terminal_id`, `tmux_pane`, `term_session_id`.

## Session and Window Names

`title` describes the AI task. `session_name` and `window_title` describe where the task is happening.

Display priority:

```txt
session_name
> window_title
> title
```

Examples:

- Chrome tab: `session_name = "生成图片"`, `window_title = "ChatGPT - 生成图片 - Chrome"`.
- Terminal: `session_name = "Backend refactor"`, `window_title = "Terminal - Backend refactor"`.
- tmux: `session_name = "agent:auth-tests"`, `window_title = "tmux ai-monitor:2.1"`.

## Status values

- `queued`
- `starting`
- `running`
- `thinking`
- `executing_tool`
- `waiting_for_input`
- `needs_permission`
- `blocked`
- `idle_but_not_done`
- `completed`
- `failed`
- `cancelled`
- `stale`
- `unknown`

The most urgent user-facing statuses are `needs_permission`, `waiting_for_input`, `blocked`, `idle_but_not_done`, `failed`, and `completed`.

## Priority

- `P0`: immediate user attention.
- `P1`: important completion or failure.
- `P2`: normal update.
- `P3`: low priority or historical update.

## Aggregation rules

The current implementation treats the newest event for a task as authoritative and merges missing fields from previous task state. Raw history stays unchanged.

Example:

```txt
running → executing_tool → needs_permission → running → completed
```

The resulting dashboard task is `completed`, while the history keeps every intermediate state.

## Actions

`TaskAction` stores deeplinkable return paths such as:

- browser tab URL;
- terminal or tmux pane target;
- IDE workspace URL;
- GitHub PR URL;
- file path and line number.

Actions should be precise enough that clicking a notification returns the user to the correct work surface.
