# Privacy

AI Monitor has high local visibility, so the default boundary must be conservative.

## Defaults

- Local-first storage.
- Do not upload full prompts by default.
- Do not upload full AI replies by default.
- Do not upload screenshots by default.
- Store only task state, short messages, confidence, actions, and metadata needed for return navigation.
- Let users disable observation per app, site, workspace, or project.

The daemon enforces the external-upload boundary before notification delivery. Local task storage remains precise enough for deep links by default, while external providers get redacted copies.

```toml
[privacy]
redact_external_workspace_paths = true
redact_external_prompts = true
redact_external_replies = true
redact_storage_prompts = false
redact_storage_replies = false
```

## Secrets

Provider tokens must not be stored in plaintext in ordinary-user builds.

Use:

- macOS Keychain
- Windows Credential Manager
- Linux Secret Service

The local API token is stored in `~/.ai-monitor/api-token` with `0600` permissions. The macOS app migrates legacy UserDefaults tokens to that file, removes the old UserDefaults value, and starts both manual and login daemon processes with `--api-token-file`. The token is not written into UserDefaults, LaunchAgent plists, or child-process environment variables.

Provider secrets for the macOS app should use Keychain references such as `keychain://service/account` or `${KEYCHAIN:service:account}`. Settings can write provider secrets into macOS Keychain and update provider config fields to those references. Environment variables remain available for development and CI smoke tests, but they are not the ordinary-user packaged path.

## Sensitive workspaces

Users should be able to mark a workspace as local-only or completely ignored. Integrations must respect ignore rules before sending events to the daemon.

The macOS settings panel can hide ignored workspace prefixes locally and suppress their clickable notifications. It can also write daemon-side ignore rules for app, source, site, and workspace matchers into the selected daemon config file. Daemon-side ignore rules remain the authoritative privacy boundary because they prevent storage and external delivery.

Daemon-side ignore rules are available as a backstop for integrations:

```toml
[[ignore_rules]]
id = "private-workspace"
mode = "ignore"
workspace_prefix = "/Users/you/private-project"

[[ignore_rules]]
id = "local-only-chatgpt"
mode = "local_only"
source = "chatgpt-web"

[[ignore_rules]]
id = "ignore-cursor-private-site"
mode = "ignore"
app = "Cursor"
site_contains = "private.example"
```

`mode = "ignore"` drops matching events before storage. `mode = "local_only"` stores the event locally but forces `notify_external = false`. Rules can match by app, source/site, and workspace prefix or substring.

## Screens and accessibility

Accessibility, OCR, and local vision are last-resort inference layers. They should be opt-in, visible in settings, and scoped to specific apps or sites when possible.

The macOS Desktop app observer is off by default. When enabled, it uses Accessibility APIs only to read desktop AI app window titles and lightweight visible state for local task display. Settings exposes the current Accessibility permission state and a `Request Accessibility` action; diagnostics report `accessibility_trusted` without exposing window contents.
