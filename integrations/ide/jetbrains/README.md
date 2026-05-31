# AI Monitor JetBrains Plugin

This is the first JetBrains adapter. It defines plugin metadata, settings, Tools menu actions, and run configuration listeners for reporting IDE task state to the local AI Monitor daemon.

## Current actions

- `AI Monitor > Report Running`
- `AI Monitor > Report Waiting For Input`
- `AI Monitor > Report Pending Changes`
- `AI Monitor > Report Completed`
- `AI Monitor > Report Failed`
- `AI Monitor > Clear Current IDE Task`

When `Auto-report run configurations` is enabled, JetBrains run configurations are reported as running/completed/failed. Test-like configurations are reported as test states.

## Scope

The current implementation posts manual state events, clears the current project task, and reports run configuration lifecycle events. It does not yet hook VCS changes or third-party agent plugins automatically.

## Build

This skeleton uses the IntelliJ Platform Gradle Plugin. From this directory:

```bash
./gradlew buildPlugin
```

The repository does not currently include a Gradle wrapper, so use a local Gradle install or add a wrapper during packaging.
