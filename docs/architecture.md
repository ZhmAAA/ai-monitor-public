# AI Monitor Architecture

AI Monitor is an AI work control tower. Its job is to make many independent AI workers visible in one place: who is running, who finished, who failed, who is blocked, and where the user should return to act.

## Layers

```txt
Desktop clients and tray surfaces
  ↓
Local Rust daemon
  ↓
Agent Task Protocol
  ↓
Event store, aggregation, notification engine, deeplink router
  ↓
Hooks, browser extensions, IDE extensions, terminal adapters, OS observers
  ↓
AI tools and agent runtimes
```

## Local daemon

The daemon is the stable local control plane. It receives events, stores raw history, aggregates current task state, streams live updates, evaluates notification rules, and dispatches notifications. It does not depend on macOS, Windows, Linux, browser, or IDE UI code.

## Event flow

1. An adapter observes a tool state change.
2. The adapter emits an `AgentTaskEvent` to `POST /events`, or a compact terminal event to `POST /terminal/events`.
3. The daemon validates and stores the raw event.
4. The aggregator merges the event into the current `AgentTask`.
5. The daemon broadcasts the update to `GET /live` WebSocket clients.
6. The notification rule engine decides whether the event should notify.
7. Providers send messages and write delivery results.
8. UI clients render the latest task state and historical event stream.

When a terminal work surface closes, its adapter can call `DELETE /tasks/:id`. The daemon removes that current task and broadcasts a deletion message, so polling clients stop rendering it on the next refresh.

## Floating Surfaces

The macOS floating monitor lives in `apps/desktop-macos/FloatingMonitor.swift`. It can run directly through `scripts/run_macos_floating_window.sh`, be compiled into a local app bundle with `scripts/build_macos_app.sh`, or be packaged with signing and optional notarization through `scripts/package_macos_app.sh`. The app bundle registers the `ai-monitor://` URL scheme, while `scripts/install_macos_launch_agent.sh` installs the daemon as a user LaunchAgent for login startup. The monitor polls `GET /tasks` and renders each task using this display order:

```txt
session_name
> window_title
> task title
```

This separates the human-visible work surface name from the underlying task title. A browser adapter can report a Chrome tab named `生成图片`, while a terminal adapter can report an iTerm or tmux session named `Backend refactor`.

The app also installs a menu bar item for showing the monitor, opening settings, starting the local daemon, installing or removing the daemon LaunchAgent, and quitting. The settings panel stores daemon URL/token/config path, monitor-side source toggles, local notification enablement, and locally hidden workspace prefixes in user defaults. It can create or edit notification providers, write provider secrets into macOS Keychain, update provider config fields to Keychain references, show provider health inline, and edit daemon-side app/source/site/workspace ignore rules. Adapter-side observation and daemon-side ignore rules remain separate controls.

Row clicks and notification clicks go through the same client-side deeplink router. The router accepts known `TaskAction` types and expected schemes or hosts, resolves `ai-monitor://task/<id>` callbacks through the daemon, and ignores unknown actions instead of handing arbitrary targets to the OS.

## Status inference

AI Monitor always prefers explicit signals over guesses:

```txt
official hooks
> plugin events
> browser / IDE extension events
> accessibility tree
> window and process state
> OCR / local vision
> heuristic rules
```

Every inferred event carries a confidence score. UI should expose confidence when a state is uncertain, especially `idle_but_not_done`, `blocked`, and `unknown`.

## Storage model

Raw events and current task state are separate:

- `events` is append-only task history.
- `tasks` stores the latest aggregated state per task.
- `notification_deliveries` stores provider delivery attempts and errors.

This keeps dashboard reads fast while preserving the full event stream for audits, debugging, and future orchestration.

## Extension model

Adapters are intentionally thin. Browser extensions, IDE plugins, shell hooks, and terminal observers should convert local tool state into protocol events and leave persistence, rules, notifications, privacy filtering, and live streaming to the daemon.

The first IDE adapters follow that rule: VS Code/Cursor and JetBrains code posts `AgentTaskEvent` records directly to the daemon and uses task actions for workspace/file return navigation. IDE-specific state inference should stay inside those adapters rather than entering daemon storage or notification code.

## Future expansion

The same core can support:

- official mobile apps and web dashboard sync;
- team-level productivity dashboards;
- low-risk auto approvals;
- automatic test reruns and PR creation;
- agent handoffs and orchestration.

The current release scope remains local-first: one daemon, one protocol, durable local state, live updates, and provider-based notifications.
