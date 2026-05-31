import Cocoa
import Foundation
import ApplicationServices
import Security
import UserNotifications

private let defaultDaemonURLString = normalizedLocalDaemonURLString(
    ProcessInfo.processInfo.environment["AI_MONITOR_URL"] ?? "http://127.0.0.1:4318"
)
private let appSettings = AppSettings.shared
private let completedVisibleSeconds: TimeInterval = 180
private let failedVisibleSeconds: TimeInterval = 300
private let idleVisibleSeconds: TimeInterval = 600
private let browserHeartbeatGraceSeconds: TimeInterval = 90
private let panelFrameDefaultsKey = "AI_Monitor_FloatingPanelFrame"
private let defaultPanelSize = NSSize(width: 320, height: 260)
private let minimumPanelSize = NSSize(width: 240, height: 150)
private let maximumRestoredPanelWidth: CGFloat = 420
private let appNotificationRecentSeconds: TimeInterval = 300
private let notificationCategoryIdentifier = "AI_MONITOR_TASK"
private let notificationOpenActionIdentifier = "AI_MONITOR_OPEN_TASK"
private let localDevelopmentLaunchAgentLabel = "local.ai-monitor.daemon"
private let launchAgentLabel = resolvedLaunchAgentLabel()
private let bundledDaemonResourceName = "ai-monitor-daemon"
private let fallbackDefaultDaemonConfig = """
[api]
auth_enabled = true
cors_allowed_origins = [
  "http://127.0.0.1:",
  "http://localhost:",
  "http://[::1]:",
  "chrome-extension://",
  "moz-extension://",
  "safari-web-extension://",
]

[privacy]
redact_external_workspace_paths = true
redact_external_prompts = true
redact_external_replies = true
redact_storage_prompts = false
redact_storage_replies = false

[quiet_hours]
enabled = false
start = "22:00"
end = "07:00"
allow_priorities = ["P0"]

[[providers]]
id = "desktop"
type = "desktop"
enabled = true

[[rules]]
status = "needs_permission"
priority = "P0"
send_to = ["desktop"]

[[rules]]
status = "waiting_for_input"
priority = "P0"
send_to = ["desktop"]

[[rules]]
status = "failed"
priority = "P0"
send_to = ["desktop"]

[[rules]]
status = "idle_but_not_done"
priority = "P0"
send_to = ["desktop"]

[[rules]]
status = "completed"
priority = "P1"
send_to = ["desktop"]
"""

private func normalizedLocalDaemonURLString(_ rawValue: String) -> String {
    let fallback = "http://127.0.0.1:4318"
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed.isEmpty ? fallback : trimmed),
          url.scheme?.lowercased() == "http",
          isLoopbackHost(url.host)
    else {
        return fallback
    }
    let absolute = url.absoluteString
    return absolute.hasSuffix("/") ? String(absolute.dropLast()) : absolute
}

private func isLoopbackHost(_ host: String?) -> Bool {
    guard let host = host?.lowercased() else {
        return false
    }
    if host == "localhost" || host == "::1" || host == "[::1]" {
        return true
    }
    let parts = host.split(separator: ".")
    guard parts.count == 4, parts[0] == "127" else {
        return false
    }
    return parts.allSatisfy { part in
        guard let value = Int(part) else {
            return false
        }
        return (0...255).contains(value)
    }
}

private let fallbackFirstRunGuide = """
AI Monitor first-run setup

1. Drag AI Monitor.app into Applications, then open it from Applications.
2. Settings opens automatically on first launch. If it does not, open AI Monitor from the menu bar and choose Settings.
3. AI Monitor starts the local daemon automatically when it is offline. Click Test connection; if it says offline, click Start daemon and test again.
4. Click Install login daemon if you want AI Monitor to start after login.
5. Click Copy API token and paste it into the browser extension or IDE setting when asked. Terminal integrations read the same token file automatically.
6. Click Open browser install link, then install the Chrome Web Store or managed browser extension if you want web AI tabs to appear. Use Copy browser install link if you need to paste the link into a managed browser.
7. Install the VS Code/Cursor extension from "AI Monitor IDE Extension.vsix" with Extensions: Install from VSIX.... Use "AI Monitor IDE Extension.zip" only as an unpacked-folder fallback. Run AI Monitor: Send Test Event after installing; if it fails, use AI Monitor: Open Desktop Settings and click Test connection.
8. Install terminal integrations from "AI Monitor Terminal Integrations.zip" if your release channel provides it. Double-click Install AI Monitor Terminal Integrations.command from the unzipped folder, or run ./integrations/terminal/install-terminal-integrations.command --project /path/to/repo for scripted installs.
9. Desktop app observer is optional. Enable it only if you want local desktop app detection, then click Request Accessibility and allow AI Monitor in System Settings.
10. Use Open logs, Open data folder, Copy troubleshooting guide, Copy license notices, Copy privacy notice, Copy uninstall guide, and Copy diagnostics when asking for support. Diagnostics do not include provider secrets or the API token.
"""
private let fallbackLicenseText = """
AI Monitor license

AI Monitor is distributed under the MIT License. Packaged releases include LICENSE.txt with the full license text.
"""
private let fallbackThirdPartyNoticesText = """
AI Monitor third-party notices

Packaged releases include THIRD-PARTY-NOTICES.txt with bundled dependency and integration license notices. If this fallback appears in a packaged release, reinstall from the official DMG or contact support.
"""
private let fallbackUninstallGuide = """
AI Monitor uninstall guide

Standard uninstall:
1. Quit AI Monitor from the menu bar.
2. Open AI Monitor Settings and click Remove login daemon if you enabled startup.
3. Delete /Applications/AI Monitor.app.

Remove local data:
Deleting the app does not automatically delete local history, config, tokens, or logs. Remove these paths only if you want a full cleanup:

- ~/Library/Application Support/AI Monitor
- ~/.ai-monitor
- ~/Library/Logs/AI Monitor
- ~/Library/Preferences/<bundle-id>.plist
- ~/Library/LaunchAgents/<launch-agent-label>.plist

Use Settings -> Copy diagnostics before uninstalling if support needs the exact bundle_identifier, launch_agent_label, or local state paths. Diagnostics do not include provider secrets or the API token.
"""
private let fallbackTroubleshootingGuide = """
AI Monitor troubleshooting guide

Use this when AI Monitor opens but does not show tasks, or when an integration cannot connect.

Daemon offline:
1. Open Settings and click Test connection.
2. If it reports offline, click Start daemon and test again.
3. If it still reports offline, click Open logs and check daemon.err.log.
4. If Start daemon says to move the app, drag AI Monitor.app into Applications, eject the DMG, reopen it from Applications, and test again.

Token or HTTP 401 errors:
1. Open Settings.
2. Click Copy API token.
3. Paste the token into the browser extension popup or IDE setting.
4. Click Save, then Test.
5. From the browser extension popup, Open AI Monitor Settings should open the same Settings panel through ai-monitor://settings.

Terminal tasks do not appear:
- Confirm Node.js is installed.
- Double-click Install AI Monitor Terminal Integrations.command from the unzipped terminal integrations bundle, or run install-terminal-integrations.command with --project for scripted installs.
- In Codex CLI, open /hooks and trust the AI Monitor hooks.

IDE tasks do not appear:
- In VS Code or Cursor, run AI Monitor: Send Test Event from the command palette.
- If delivery fails, run AI Monitor: Open Desktop Settings, click Test connection, then retry the test event.
- If the warning mentions HTTP 401, click Copy API token in Settings or paste the copied token into AI Monitor: Api Token.

Clicking a task does not focus the app:
- When macOS asks whether AI Monitor can control a browser or terminal app, choose Allow.
- If you denied the prompt, open System Settings -> Privacy & Security -> Automation and allow AI Monitor.

Support diagnostics:
- Click Copy diagnostics before asking for support.
- Diagnostics exclude the API token and provider secrets.
"""

private func resolvedLaunchAgentLabel() -> String {
    if let override = ProcessInfo.processInfo.environment["AI_MONITOR_LAUNCH_AGENT_LABEL"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nilIfEmpty
    {
        return override
    }

    guard let bundleIdentifier = Bundle.main.bundleIdentifier?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nilIfEmpty,
        !bundleIdentifier.hasPrefix("local.")
    else {
        return localDevelopmentLaunchAgentLabel
    }

    return "\(bundleIdentifier).daemon"
}

private final class AppSettings {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    private enum Key {
        static let daemonURL = "AI_Monitor_DaemonURL"
        static let daemonConfigPath = "AI_Monitor_DaemonConfigPath"
        static let apiToken = "AI_Monitor_APIToken"
        static let observeBrowser = "AI_Monitor_ObserveBrowser"
        static let observeTerminal = "AI_Monitor_ObserveTerminal"
        static let observeIDE = "AI_Monitor_ObserveIDE"
        static let observeDesktop = "AI_Monitor_ObserveDesktop"
        static let localNotifications = "AI_Monitor_LocalNotifications"
        static let ignoredWorkspacePrefixes = "AI_Monitor_IgnoredWorkspacePrefixes"
        static let settingsLanguage = "AI_Monitor_SettingsLanguage"
        static let firstRunSettingsShown = "AI_Monitor_FirstRunSettingsShown"
    }

    private init() {
        registerDefault(true, for: Key.observeBrowser)
        registerDefault(true, for: Key.observeTerminal)
        registerDefault(true, for: Key.observeIDE)
        registerDefault(false, for: Key.observeDesktop)
        registerDefault(true, for: Key.localNotifications)
        _ = defaultDaemonConfigURL()
        migrateLegacyAPITokenStorage()
    }

    var daemonURLString: String {
        get {
            normalizedLocalDaemonURLString(defaults.string(forKey: Key.daemonURL)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty ?? defaultDaemonURLString)
        }
        set {
            defaults.set(normalizedLocalDaemonURLString(newValue), forKey: Key.daemonURL)
        }
    }

    var daemonURL: URL {
        URL(string: daemonURLString) ?? URL(string: defaultDaemonURLString)!
    }

    var daemonConfigPathString: String {
        get {
            defaults.string(forKey: Key.daemonConfigPath)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty ?? defaultDaemonConfigURL().path
        }
        set {
            defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.daemonConfigPath)
        }
    }

    var daemonConfigURL: URL {
        URL(fileURLWithPath: daemonConfigPathString)
    }

    var apiToken: String? {
        get {
            loadAPITokenFromEnvironmentOrFile() ?? legacyAPITokenFromDefaults()
        }
        set {
            defaults.removeObject(forKey: Key.apiToken)
            guard let token = newValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
                return
            }
            try? writeAPITokenToDefaultFile(token)
        }
    }

    var observeBrowser: Bool {
        get { defaults.bool(forKey: Key.observeBrowser) }
        set { defaults.set(newValue, forKey: Key.observeBrowser) }
    }

    var observeTerminal: Bool {
        get { defaults.bool(forKey: Key.observeTerminal) }
        set { defaults.set(newValue, forKey: Key.observeTerminal) }
    }

    var observeIDE: Bool {
        get { defaults.bool(forKey: Key.observeIDE) }
        set { defaults.set(newValue, forKey: Key.observeIDE) }
    }

    var observeDesktop: Bool {
        get { defaults.bool(forKey: Key.observeDesktop) }
        set { defaults.set(newValue, forKey: Key.observeDesktop) }
    }

    var localNotifications: Bool {
        get { defaults.bool(forKey: Key.localNotifications) }
        set { defaults.set(newValue, forKey: Key.localNotifications) }
    }

    var ignoredWorkspacePrefixesText: String {
        get { defaults.string(forKey: Key.ignoredWorkspacePrefixes) ?? "" }
        set { defaults.set(newValue, forKey: Key.ignoredWorkspacePrefixes) }
    }

    var settingsLanguage: String {
        get {
            let value = defaults.string(forKey: Key.settingsLanguage)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            return value == "en" ? "en" : "zh"
        }
        set {
            defaults.set(newValue == "en" ? "en" : "zh", forKey: Key.settingsLanguage)
        }
    }

    var shouldShowFirstRunSettings: Bool {
        !defaults.bool(forKey: Key.firstRunSettingsShown)
    }

    func markFirstRunSettingsShown() {
        defaults.set(true, forKey: Key.firstRunSettingsShown)
    }

    var ignoredWorkspacePrefixes: [String] {
        ignoredWorkspacePrefixesText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func registerDefault(_ value: Bool, for key: String) {
        if defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }

    private func legacyAPITokenFromDefaults() -> String? {
        defaults.string(forKey: Key.apiToken)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private func migrateLegacyAPITokenStorage() {
        guard let legacyToken = legacyAPITokenFromDefaults() else {
            return
        }

        if loadAPITokenFromEnvironmentOrFile() == nil {
            do {
                try writeAPITokenToDefaultFile(legacyToken)
            } catch {
                NSLog("AI Monitor could not migrate API token from UserDefaults: \(error.localizedDescription)")
                return
            }
        }

        defaults.removeObject(forKey: Key.apiToken)
    }
}

private struct TaskAction: Decodable {
    let label: String?
    let type: String
    let target: String
    let appBundleId: String?
    let filePath: String?
    let lineNumber: Int?
    let metadata: TaskActionMetadata?

    enum CodingKeys: String, CodingKey {
        case label
        case type
        case target
        case appBundleId = "app_bundle_id"
        case filePath = "file_path"
        case lineNumber = "line_number"
        case metadata
    }

    var normalizedTarget: String {
        target.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct TaskActionMetadata: Decodable {
    let tabId: Int?
    let windowId: Int?
    let browserApp: String?
    let browserBundleId: String?
    let extensionId: String?

    enum CodingKeys: String, CodingKey {
        case tabId = "tab_id"
        case windowId = "window_id"
        case browserApp = "browser_app"
        case browserBundleId = "browser_bundle_id"
        case extensionId = "extension_id"
    }
}

private struct TaskMetadata: Decodable {
    let detector: String?
    let detectorDebug: String?
    let url: String?
    let faviconUrl: String?
    let adapterVersion: String?
    let browserTabId: Int?
    let browserWindowId: Int?
    let browserApp: String?
    let browserBundleId: String?
    let extensionId: String?
    let command: String?
    let pid: Int?
    let terminalProgram: String?
    let termSessionId: String?
    let tmuxPane: String?
    let agentHost: String?
    let agentHostLabel: String?
    let agentHostEvidence: String?
    let parentCommand: String?
    let conversationName: String?
    let prompt: String?
    let sessionId: String?
    let hookSessionId: String?
    let supersetSessionId: String?

    init(
        detector: String? = nil,
        detectorDebug: String? = nil,
        url: String? = nil,
        faviconUrl: String? = nil,
        adapterVersion: String? = nil,
        browserTabId: Int? = nil,
        browserWindowId: Int? = nil,
        browserApp: String? = nil,
        browserBundleId: String? = nil,
        extensionId: String? = nil,
        command: String? = nil,
        pid: Int? = nil,
        terminalProgram: String? = nil,
        termSessionId: String? = nil,
        tmuxPane: String? = nil,
        agentHost: String? = nil,
        agentHostLabel: String? = nil,
        agentHostEvidence: String? = nil,
        parentCommand: String? = nil,
        conversationName: String? = nil,
        prompt: String? = nil,
        sessionId: String? = nil,
        hookSessionId: String? = nil,
        supersetSessionId: String? = nil
    ) {
        self.detector = detector
        self.detectorDebug = detectorDebug
        self.url = url
        self.faviconUrl = faviconUrl
        self.adapterVersion = adapterVersion
        self.browserTabId = browserTabId
        self.browserWindowId = browserWindowId
        self.browserApp = browserApp
        self.browserBundleId = browserBundleId
        self.extensionId = extensionId
        self.command = command
        self.pid = pid
        self.terminalProgram = terminalProgram
        self.termSessionId = termSessionId
        self.tmuxPane = tmuxPane
        self.agentHost = agentHost
        self.agentHostLabel = agentHostLabel
        self.agentHostEvidence = agentHostEvidence
        self.parentCommand = parentCommand
        self.conversationName = conversationName
        self.prompt = prompt
        self.sessionId = sessionId
        self.hookSessionId = hookSessionId
        self.supersetSessionId = supersetSessionId
    }

    enum CodingKeys: String, CodingKey {
        case detector
        case detectorDebug = "detector_debug"
        case url
        case faviconUrl = "favicon_url"
        case adapterVersion = "adapter_version"
        case browserTabId = "browser_tab_id"
        case browserWindowId = "browser_window_id"
        case browserApp = "browser_app"
        case browserBundleId = "browser_bundle_id"
        case extensionId = "extension_id"
        case command
        case pid
        case terminalProgram = "terminal_program"
        case termSessionId = "term_session_id"
        case tmuxPane = "tmux_pane"
        case agentHost = "agent_host"
        case agentHostLabel = "agent_host_label"
        case agentHostEvidence = "agent_host_evidence"
        case parentCommand = "parent_command"
        case conversationName = "conversation_name"
        case prompt
        case sessionId = "session_id"
        case hookSessionId = "hook_session_id"
        case supersetSessionId = "superset_session_id"
    }
}

private struct AgentTask: Decodable {
    let taskId: String
    let source: String
    let app: String?
    let workspace: String?
    let sessionName: String?
    let windowTitle: String?
    let title: String
    let status: String
    let step: String?
    let message: String?
    let updatedAt: String
    let actions: [TaskAction]?
    let metadata: TaskMetadata?
    var displayNameOverride: String? = nil

    enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case source
        case app
        case workspace
        case sessionName = "session_name"
        case windowTitle = "window_title"
        case title
        case status
        case step
        case message
        case updatedAt = "updated_at"
        case actions
        case metadata
    }

    var displayName: String {
        if let displayNameOverride {
            return displayNameOverride
        }
        if let name = desktopAgentDisplayName {
            return name
        }

        if isTerminalTask {
            let candidates = [sessionName, title, windowTitle]
            if let name = candidates.compactMap({ $0 }).first(where: { !$0.isGenericDisplayName && !$0.isMachineGeneratedDisplayName }) {
                return name
            }
            if let fallback = terminalReadableFallbackName {
                return fallback
            }
        }

        let candidates = [title, sessionName, windowTitle]
        if let name = candidates.compactMap({ $0 }).first(where: { !$0.isGenericDisplayName && !$0.isMachineGeneratedDisplayName }) {
            return name
        }
        if let name = candidates.compactMap({ $0 }).first(where: { !$0.isEmpty && !$0.isMachineGeneratedDisplayName }) {
            return name
        }
        return "AI task"
    }

    var sourceLabel: String {
        if let app, !app.isEmpty { return "\(source) · \(app)" }
        return source
    }

    var compactSourceName: String {
        if let label = agentHostLabel {
            return label
        }

        switch source {
        case "chatgpt-web":
            return "ChatGPT"
        case "claude-web":
            return "Claude"
        case "gemini-web":
            return "Gemini"
        case "perplexity-web":
            return "Perplexity"
        case "grok-web":
            return "Grok"
        case "github-web":
            return "GitHub"
        case "codex-cli":
            return "Codex"
        case "claude-code":
            return "Claude Code"
        case "gemini-cli":
            return "Gemini CLI"
        default:
            return source
        }
    }

    var kindLabel: String {
        if isTerminalTask { return agentHostLabel ?? "Terminal" }
        if isBrowserTask { return compactSourceName }
        return app ?? source
    }

    var displayStatus: String {
        if status == "unknown", step == "Tab open" { return "open" }
        return status
    }

    var browserURL: URL? {
        guard let action = actions?.first(where: { $0.type == "open_browser_tab" }) else {
            return nil
        }
        return allowedHTTPURL(action.normalizedTarget)
    }

    var primaryAction: TaskAction? {
        if isBrowserTask, let action = actions?.first(where: { $0.type == "open_browser_tab" }) {
            return action
        }
        if isTerminalTask, let action = actions?.first(where: {
            ["open_terminal_session", "open_tmux_pane", "open_iterm_window", "open_warp_session", "open_url"].contains($0.type)
        }) {
            return action
        }
        return actions?.first
    }

    var canOpenTask: Bool {
        if isDesktopAgentTask { return true }
        guard let action = primaryAction else { return false }
        return !action.normalizedTarget.isEmpty || isTerminalTask
    }

    var isDesktopAgentTask: Bool {
        agentHostLabel?.hasSuffix("Desktop") == true
    }

    var deduplicationKey: String? {
        guard ["codex-cli", "claude-code"].contains(source.lowercased()),
              let conversation = agentSessionKey ?? agentConversationName else {
            return nil
        }
        let normalized = conversation
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? nil : "\(source.lowercased()):\(normalized)"
    }

    var agentSessionKey: String? {
        [
            metadata?.sessionId,
            metadata?.hookSessionId,
            metadata?.supersetSessionId,
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            .map { "session:\($0)" }
    }

    func isPreferredDuplicate(over other: AgentTask) -> Bool {
        if isDesktopAgentTask != other.isDesktopAgentTask {
            return isDesktopAgentTask
        }
        if isActive != other.isActive {
            return isActive
        }
        return (updatedDate ?? .distantPast) > (other.updatedDate ?? .distantPast)
    }

    func mergingDisplayName(from duplicate: AgentTask) -> AgentTask {
        guard isDesktopAgentTask, !duplicate.isDesktopAgentTask,
              let duplicateName = duplicate.mergeDisplayNameCandidate else {
            return self
        }

        var merged = self
        merged.displayNameOverride = duplicateName
        return merged
    }

    var mergeDisplayNameCandidate: String? {
        let candidates = [
            metadata?.prompt,
            metadata?.conversationName,
            title,
            sessionName,
            windowTitle,
        ]

        return candidates
            .compactMap { readableCodexConversationName(from: $0) }
            .first
    }

    var isBrowserTask: Bool {
        source.hasSuffix("-web") || app?.lowercased() == "chrome"
    }

    var isTerminalTask: Bool {
        let normalizedSource = source.lowercased()
        let terminalSources = ["terminal", "codex-cli", "claude-code", "gemini-cli", "opencode", "aider"]
        return app?.lowercased() == "terminal" ||
            terminalSources.contains(normalizedSource) ||
            metadata?.command != nil ||
            metadata?.tmuxPane != nil ||
            metadata?.termSessionId != nil
    }

    var symbolName: String {
        if isTerminalTask { return "terminal" }
        if isBrowserTask { return "globe" }
        return "circle.grid.2x2"
    }

    var iconImage: NSImage? {
        officialDesktopIcon(for: agentHostLabel) ?? officialWebIcon(for: source, faviconURL: metadata?.faviconUrl)
    }

    var terminalCommandLabel: String? {
        let raw = metadata?.command ?? step
        guard let raw else { return nil }
        let value = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var compactTerminalDetailLabel: String {
        var parts = [compactSourceName, displayStatus]
        if let workspaceLabel {
            parts.append(workspaceLabel)
        } else if let command = terminalCommandLabel, !isGenericTerminalStep(command) {
            parts.append(command)
        }
        return parts.joined(separator: " · ")
    }

    var workspaceLabel: String? {
        guard let workspace, !workspace.isEmpty else { return nil }
        let name = URL(fileURLWithPath: workspace).lastPathComponent
        return name.isEmpty ? workspace : name
    }

    var terminalContextLabel: String? {
        var parts: [String] = []
        if let workspaceLabel { parts.append(workspaceLabel) }
        if let terminalProgram = metadata?.terminalProgram, !terminalProgram.isEmpty {
            parts.append(terminalProgram)
        }
        if let tmuxPane = metadata?.tmuxPane, !tmuxPane.isEmpty {
            parts.append("tmux \(tmuxPane)")
        } else if let termSessionId = metadata?.termSessionId, !termSessionId.isEmpty {
            parts.append("session \(termSessionId.suffix(8))")
        }
        if let pid = metadata?.pid {
            parts.append("pid \(pid)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var terminalReadableFallbackName: String? {
        if let workspaceLabel {
            return workspaceLabel
        }
        if let agentHostLabel {
            return "\(agentHostLabel) session"
        }
        if isTerminalTask {
            return "\(compactSourceName) session"
        }
        return nil
    }

    var desktopAgentDisplayName: String? {
        guard let agentHostLabel, agentHostLabel.hasSuffix("Desktop") else { return nil }

        if let workspaceLabel, let conversationName = agentConversationName {
            return "\(workspaceLabel) - \(conversationName)"
        }
        if let workspaceLabel {
            return workspaceLabel
        }
        if let conversationName = agentConversationName {
            return conversationName
        }
        return "\(agentHostLabel) session"
    }

    var agentConversationName: String? {
        [
            metadata?.prompt,
            metadata?.conversationName,
            title,
            sessionName,
            windowTitle,
        ]
            .compactMap { readableCodexConversationName(from: $0) }
            .first
    }

    private func readableCodexConversationName(from raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        for prefix in [
            "Codex CLI - ",
            "Codex Desktop - ",
            "Codex VS Code - ",
            "Codex - ",
            "Claude Code CLI - ",
            "Claude Code Desktop - ",
            "Claude Code VS Code - ",
            "Claude Code - ",
        ] {
            if value.lowercased().hasPrefix(prefix.lowercased()) {
                value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if value.isGenericDisplayName || value.isMachineGeneratedDisplayName {
            return nil
        }

        let normalized = value.lowercased()
        if [
            "codex completed",
            "codex failed",
            "codex notification",
            "codex permission request",
            "codex turn complete",
            "codex session",
            "claude code completed",
            "claude code failed",
            "claude code notification",
            "claude code permission request",
            "claude code session",
        ].contains(normalized) {
            return nil
        }

        if let workspaceLabel, normalized == workspaceLabel.lowercased() {
            return nil
        }

        return value
    }

    var debugLabel: String? {
        nil
    }

    var agentHostLabel: String? {
        codexHostLabel ?? claudeCodeHostLabel
    }

    var codexHostLabel: String? {
        guard source.lowercased() == "codex-cli" else { return nil }

        let evidence = [
            metadata?.agentHostEvidence,
            metadata?.parentCommand,
            metadata?.command,
            metadata?.terminalProgram,
            windowTitle,
            sessionName,
            title,
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        if let label = agentHostLabel(from: metadata?.agentHostLabel, source: "codex-cli"),
           label != "Codex CLI" {
            return label
        }
        if let label = agentHostLabel(from: metadata?.agentHost, source: "codex-cli"),
           label != "Codex CLI" {
            return label
        }

        if evidence.contains(".vscode/extensions/openai.chatgpt") ||
            evidence.contains("visual studio code.app") ||
            (evidence.contains("vscode") && evidence.contains("codex")) {
            return "Codex VS Code"
        }

        if evidence.contains("/applications/codex.app/") ||
            evidence.contains("codex.app/contents") ||
            evidence.contains("resources/codex app-server") {
            return "Codex Desktop"
        }

        if metadata?.terminalProgram == nil,
           metadata?.tmuxPane == nil,
           metadata?.termSessionId == nil,
           isCodexDesktopRunning() {
            return "Codex Desktop"
        }

        if let label = agentHostLabel(from: metadata?.agentHostLabel, source: "codex-cli") {
            return label
        }
        if let label = agentHostLabel(from: metadata?.agentHost, source: "codex-cli") {
            return label
        }

        return "Codex CLI"
    }

    var claudeCodeHostLabel: String? {
        guard source.lowercased() == "claude-code" else { return nil }

        if let label = agentHostLabel(from: metadata?.agentHostLabel, source: "claude-code") {
            return label
        }
        if let label = agentHostLabel(from: metadata?.agentHost, source: "claude-code") {
            return label
        }

        let evidence = [
            metadata?.agentHostEvidence,
            metadata?.parentCommand,
            metadata?.command,
            metadata?.terminalProgram,
            windowTitle,
            sessionName,
            title,
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        if evidence.contains(".vscode/extensions/anthropic") ||
            evidence.contains(".vscode/extensions/claude") ||
            evidence.contains("visual studio code.app") && evidence.contains("claude") {
            return "Claude Code VS Code"
        }

        if evidence.contains("/applications/claude.app/") ||
            evidence.contains("claude.app/contents") ||
            evidence.contains("/applications/claude code.app/") ||
            evidence.contains("claude code.app/contents") {
            return "Claude Code Desktop"
        }

        return "Claude Code CLI"
    }

    private func agentHostLabel(from value: String?, source: String) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = trimmed.lowercased().replacingOccurrences(of: "_", with: "-")
        if source == "codex-cli" {
            switch normalized {
            case "desktop", "codex-app", "codex-desktop", "codex desktop":
                return "Codex Desktop"
            case "vscode", "vs-code", "visual-studio-code", "codex-vscode", "codex vs code":
                return "Codex VS Code"
            case "cli", "terminal", "terminal-codex", "codex-cli", "codex cli":
                return "Codex CLI"
            default:
                return trimmed.hasPrefix("Codex") ? trimmed : nil
            }
        }

        if source == "claude-code" {
            switch normalized {
            case "desktop", "claude-desktop", "claude-code-desktop", "claude code desktop":
                return "Claude Code Desktop"
            case "vscode", "vs-code", "visual-studio-code", "claude-code-vscode", "claude code vs code":
                return "Claude Code VS Code"
            case "cli", "terminal", "claude-code", "claude-code-cli", "claude code cli":
                return "Claude Code CLI"
            default:
                return trimmed.hasPrefix("Claude Code") ? trimmed : nil
            }
        }

        return nil
    }

    private func isGenericTerminalStep(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return [
            "running",
            "thinking",
            "executing tool",
            "waiting for input",
            "terminal task started",
            "terminal task completed",
            "command completed",
            "command failed",
        ].contains(normalized) || normalized.hasSuffix("terminal event")
    }

    var updatedDate: Date? {
        parseISO8601(updatedAt)
    }

    var isActive: Bool {
        ["queued", "starting", "running", "thinking", "executing_tool", "waiting_for_input", "needs_permission", "blocked", "idle_but_not_done", "stale", "unknown"].contains(status)
    }

    var needsBrowserHeartbeat: Bool {
        source.hasSuffix("-web") && ["queued", "starting", "running", "thinking", "executing_tool", "unknown"].contains(status)
    }

    func shouldDisplay(now: Date) -> Bool {
        if status == "cancelled" {
            return false
        }
        if source == "browser-test" {
            guard let updatedDate else { return true }
            return now.timeIntervalSince(updatedDate) <= 10
        }
        if isBrowserTask {
            guard let updatedDate else { return true }
            let age = now.timeIntervalSince(updatedDate)
            if status == "completed" { return age <= completedVisibleSeconds }
            if status == "failed" { return age <= failedVisibleSeconds }
            return age <= browserHeartbeatGraceSeconds
        }
        if isActive {
            guard let updatedDate else { return true }
            if status == "idle_but_not_done" || status == "stale" || status == "unknown" {
                return now.timeIntervalSince(updatedDate) <= idleVisibleSeconds
            }
            return true
        }
        guard let updatedDate else { return true }
        let age = now.timeIntervalSince(updatedDate)
        if status == "completed" { return age <= completedVisibleSeconds }
        if status == "failed" { return age <= failedVisibleSeconds }
        return false
    }

    func sortRank() -> Int {
        switch status {
        case "needs_permission", "waiting_for_input", "blocked", "failed":
            return 0
        case "running", "thinking", "executing_tool", "starting", "queued":
            return 1
        case "idle_but_not_done", "stale", "unknown":
            return 2
        case "completed":
            return 3
        default:
            return 4
        }
    }
}

private struct AgentTaskEvent: Decodable {
    let eventId: String
    let status: String
    let step: String?
    let message: String?
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case status
        case step
        case message
        case updatedAt = "updated_at"
    }
}

private struct NotificationDelivery: Decodable {
    let deliveryId: String
    let eventId: String
    let taskId: String
    let providerId: String
    let status: String
    let message: String?
    let createdAt: String
    let completedAt: String?

    enum CodingKeys: String, CodingKey {
        case deliveryId = "delivery_id"
        case eventId = "event_id"
        case taskId = "task_id"
        case providerId = "provider_id"
        case status
        case message
        case createdAt = "created_at"
        case completedAt = "completed_at"
    }
}

private struct TaskDetail: Decodable {
    let task: AgentTask
    let events: [AgentTaskEvent]
    let deliveries: [NotificationDelivery]?
}

private struct ProviderHealth: Decodable {
    let providerId: String
    let providerType: String
    let status: String
    let message: String

    enum CodingKeys: String, CodingKey {
        case providerId = "provider_id"
        case providerType = "provider_type"
        case status
        case message
    }
}

private struct ProviderConfigEntry {
    let id: String
    let type: String
    let enabled: Bool
    let settings: [String: String]
}

private final class FloatingMonitorView: NSView {
    private let header = NSTextField(labelWithString: "AI Monitor")
    private let summary = NSTextField(labelWithString: "Waiting for daemon")
    private let scrollView = NSScrollView()
    private let scrollContent = NSView()
    private let stack = NSStackView()
    private let empty = NSTextField(labelWithString: "No active tasks")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor

        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.alignment = .center
        summary.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        summary.alignment = .center
        summary.textColor = .secondaryLabelColor
        empty.font = .systemFont(ofSize: 12)
        empty.alignment = .left
        empty.textColor = .secondaryLabelColor
        [header, summary, empty].forEach(configureTruncatingLabel)

        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        scrollContent.translatesAutoresizingMaskIntoConstraints = false
        scrollContent.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scrollContent.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scrollContent.addSubview(stack)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = scrollContent
        scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        [header, summary, scrollView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            summary.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            summary.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            summary.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            scrollView.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
            scrollContent.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.widthAnchor.constraint(equalTo: scrollContent.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollContent.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollContent.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollContent.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollContent.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(tasks: [AgentTask]) {
        stack.arrangedSubviews.forEach { view in
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let now = Date()
        let visibleTasks = tasks
            .filter { $0.source != "chrome-extension" }
            .filter { $0.shouldDisplay(now: now) }
            .deduplicatingAgentRows()
            .sorted { left, right in
                if left.sortRank() != right.sortRank() {
                    return left.sortRank() < right.sortRank()
                }
                return (left.updatedDate ?? .distantPast) > (right.updatedDate ?? .distantPast)
            }

        let running = visibleTasks.filter { ["running", "thinking", "executing_tool"].contains($0.status) }.count
        let waiting = visibleTasks.filter { ["needs_permission", "waiting_for_input", "blocked", "idle_but_not_done"].contains($0.status) }.count
        let done = visibleTasks.filter { $0.status == "completed" }.count
        let failed = visibleTasks.filter { $0.status == "failed" }.count
        summary.stringValue = "\(running) run · \(waiting) wait · \(done) done · \(failed) fail"

        if visibleTasks.isEmpty {
            addFullWidthArrangedSubview(empty)
            return
        }

        for task in visibleTasks {
            addFullWidthArrangedSubview(TaskRow(task: task))
        }
    }

    func renderError(_ message: String) {
        summary.stringValue = message
    }

    private func addFullWidthArrangedSubview(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
    }
}

private final class TaskRow: NSView {
    private let task: AgentTask
    private var trackingArea: NSTrackingArea?

    init(task: AgentTask) {
        self.task = task
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        wantsLayer = true
        layer?.cornerRadius = 8

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = color(for: task.status).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        if let iconImage = task.iconImage {
            icon.image = iconImage
            icon.imageScaling = .scaleProportionallyDown
        } else {
            icon.image = NSImage(systemSymbolName: task.symbolName, accessibilityDescription: task.kindLabel)
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            icon.contentTintColor = .secondaryLabelColor
        }
        icon.toolTip = task.kindLabel
        icon.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: task.displayName)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        configureTruncatingLabel(name)

        let detailValue = task.isTerminalTask
            ? task.compactTerminalDetailLabel
            : "\(task.compactSourceName) · \(task.displayStatus)"
        let detail = NSTextField(labelWithString: detailValue)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        configureTruncatingLabel(detail)

        var textViews: [NSView] = [name, detail]
        if let debug = task.debugLabel {
            let debugText = NSTextField(labelWithString: debug)
            debugText.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            debugText.textColor = .tertiaryLabelColor
            configureTruncatingLabel(debugText)
            textViews.append(debugText)
        }

        let text = NSStackView(views: textViews)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(dot)
        addSubview(icon)
        addSubview(text)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: trailingAnchor),
            text.topAnchor.constraint(equalTo: topAnchor),
            text.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        if task.canOpenTask {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        }
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if task.canOpenTask {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func mouseDown(with event: NSEvent) {
        openTask(task)
    }
}

private var detailPanels: [String: NSPanel] = [:]
private var settingsPanelController: SettingsPanelController?
private var launchedDaemonProcess: Process?

private func showTaskDetail(_ task: AgentTask) {
    let url = appSettings.daemonURL.appendingPathComponent("tasks").appendingPathComponent(task.taskId)
    URLSession.shared.dataTask(with: authorizedRequest(url: url)) { data, response, error in
        if let error {
            DispatchQueue.main.async {
                showDetailError("Task detail failed: \(error.localizedDescription)")
            }
            return
        }

        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            DispatchQueue.main.async {
                showTaskDetailPanel(
                    taskId: task.taskId,
                    title: task.displayName,
                    content: taskDetailFallbackView(task: task, message: "No daemon history for this local task.")
                )
            }
            return
        }

        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            DispatchQueue.main.async {
                showDetailError("Daemon auth failed")
            }
            return
        }

        guard let data else { return }
        do {
            let detail = try JSONDecoder().decode(TaskDetail.self, from: data)
            DispatchQueue.main.async {
                showTaskDetailPanel(
                    taskId: detail.task.taskId,
                    title: detail.task.displayName,
                    content: taskDetailView(detail: detail)
                )
            }
        } catch {
            DispatchQueue.main.async {
                showDetailError("Task detail decode failed: \(error.localizedDescription)")
            }
        }
    }.resume()
}

private func taskDetailView(detail: TaskDetail) -> NSView {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)

    stack.addArrangedSubview(detailHeader(task: detail.task))
    stack.addArrangedSubview(sectionLabel("Timeline"))
    if detail.events.isEmpty {
        stack.addArrangedSubview(detailLine("No events recorded"))
    } else {
        for event in detail.events {
            stack.addArrangedSubview(detailLine("\(event.updatedAt)  \(event.status)\n\(event.step ?? "")\(event.message.map { "\n\($0)" } ?? "")"))
        }
    }

    stack.addArrangedSubview(sectionLabel("Deliveries"))
    let deliveries = detail.deliveries ?? []
    if deliveries.isEmpty {
        stack.addArrangedSubview(detailLine("No notification deliveries recorded"))
    } else {
        for delivery in deliveries {
            stack.addArrangedSubview(deliveryRow(delivery: delivery, task: detail.task))
        }
    }

    return scrollableDetailContent(stack)
}

private func taskDetailFallbackView(task: AgentTask, message: String) -> NSView {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
    stack.addArrangedSubview(detailHeader(task: task))
    stack.addArrangedSubview(detailLine(message))
    return scrollableDetailContent(stack)
}

private func detailHeader(task: AgentTask) -> NSView {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 4
    stack.addArrangedSubview(sectionLabel(task.displayName))
    stack.addArrangedSubview(detailLine("\(task.compactSourceName) · \(task.displayStatus)\nupdated: \(task.updatedAt)\nworkspace: \(task.workspaceLabel ?? "none")"))
    return stack
}

private func sectionLabel(_ value: String) -> NSTextField {
    let label = NSTextField(labelWithString: value)
    label.font = .systemFont(ofSize: 13, weight: .semibold)
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 2
    return label
}

private func detailLine(_ value: String) -> NSTextField {
    let label = NSTextField(labelWithString: value)
    label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byWordWrapping
    label.maximumNumberOfLines = 0
    label.isSelectable = true
    label.setContentHuggingPriority(.defaultLow, for: .horizontal)
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
}

private func deliveryRow(delivery: NotificationDelivery, task: AgentTask) -> NSView {
    let completed = delivery.completedAt.map { "\ncompleted: \($0)" } ?? ""
    let message = delivery.message.map { "\n\($0)" } ?? ""
    let line = detailLine("\(delivery.providerId)  \(delivery.status)\nevent: \(delivery.eventId)\ncreated: \(delivery.createdAt)\(completed)\(message)")

    let retryButton = ClosureButton(
        image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Retry") ?? NSImage(),
        handler: {
            retryDelivery(deliveryId: delivery.deliveryId, task: task)
        }
    )
    retryButton.isBordered = false
    retryButton.toolTip = "Retry delivery"
    retryButton.translatesAutoresizingMaskIntoConstraints = false
    retryButton.setContentHuggingPriority(.required, for: .horizontal)
    retryButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    NSLayoutConstraint.activate([
        retryButton.widthAnchor.constraint(equalToConstant: 24),
        retryButton.heightAnchor.constraint(equalToConstant: 24),
    ])

    let row = NSStackView(views: [line, retryButton])
    row.orientation = .horizontal
    row.alignment = .top
    row.spacing = 8
    row.translatesAutoresizingMaskIntoConstraints = false
    line.setContentHuggingPriority(.defaultLow, for: .horizontal)
    line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return row
}

private final class ClosureButton: NSButton {
    private let handler: () -> Void

    init(image: NSImage, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.image = image
        self.target = self
        self.action = #selector(runHandler)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func runHandler() {
        handler()
    }
}

private func retryDelivery(deliveryId: String, task: AgentTask) {
    let url = appSettings.daemonURL
        .appendingPathComponent("notifications")
        .appendingPathComponent("deliveries")
        .appendingPathComponent(deliveryId)
        .appendingPathComponent("retry")
    var request = authorizedRequest(url: url)
    request.httpMethod = "POST"

    URLSession.shared.dataTask(with: request) { _, response, error in
        if let error {
            DispatchQueue.main.async {
                showDetailError("Delivery retry failed: \(error.localizedDescription)")
            }
            return
        }
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            DispatchQueue.main.async {
                showDetailError("Daemon auth failed")
            }
            return
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            DispatchQueue.main.async {
                showDetailError("Delivery retry failed with HTTP \(http.statusCode)")
            }
            return
        }
        DispatchQueue.main.async {
            showTaskDetail(task)
        }
    }.resume()
}

private func scrollableDetailContent(_ content: NSView) -> NSView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.documentView = content
    content.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
    ])
    return scroll
}

private func showTaskDetailPanel(taskId: String, title: String, content: NSView) {
    if let existing = detailPanels[taskId] {
        existing.contentView = content
        existing.title = title
        existing.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return
    }

    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    panel.title = title
    panel.contentView = content
    panel.center()
    panel.isReleasedWhenClosed = false
    panel.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    detailPanels[taskId] = panel
}

private func showDetailError(_ message: String) {
    let alert = NSAlert()
    alert.messageText = "AI Monitor"
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.runModal()
}

private func providerHealthRow(_ provider: ProviderHealth) -> NSView {
    let dot = NSView()
    dot.wantsLayer = true
    dot.layer?.cornerRadius = 4
    switch provider.status {
    case "ok":
        dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
    case "pending":
        dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
    case "disabled":
        dot.layer?.backgroundColor = NSColor.systemGray.cgColor
    default:
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
    }
    dot.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        dot.widthAnchor.constraint(equalToConstant: 8),
        dot.heightAnchor.constraint(equalToConstant: 8),
    ])

    let text = detailLine("\(provider.providerId)  \(provider.providerType)  \(provider.status)\n\(provider.message)")
    let row = NSStackView(views: [dot, text])
    row.orientation = .horizontal
    row.alignment = .top
    row.spacing = 8
    row.translatesAutoresizingMaskIntoConstraints = false
    return row
}

private func configureTruncatingLabel(_ label: NSTextField) {
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.setContentHuggingPriority(.defaultLow, for: .horizontal)
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
}

private func officialDesktopIcon(for agentHostLabel: String?) -> NSImage? {
    switch agentHostLabel {
    case "Codex Desktop":
        return applicationIcon(
            bundleIdentifiers: [
                "com.openai.codex",
                "com.openai.chatgpt.codex",
            ],
            fallbackPaths: [
                "/Applications/Codex.app",
            ]
        )
    case "Claude Code Desktop":
        return applicationIcon(
            bundleIdentifiers: [
                "com.anthropic.claude",
                "com.anthropic.claudefordesktop",
                "com.anthropic.claude-code",
            ],
            fallbackPaths: [
                "/Applications/Claude.app",
                "/Applications/Claude Code.app",
            ]
        )
    default:
        return nil
    }
}

private func applicationIcon(bundleIdentifiers: [String], fallbackPaths: [String]) -> NSImage? {
    for bundleIdentifier in bundleIdentifiers {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: appURL.path)
        }
    }

    for path in fallbackPaths where FileManager.default.fileExists(atPath: path) {
        return NSWorkspace.shared.icon(forFile: path)
    }

    return nil
}

private func menuBarLogoImage() -> NSImage? {
    guard let url = Bundle.main.url(forResource: "AI-Monitor-MenuBar-Logo", withExtension: "png"),
          let image = NSImage(contentsOf: url) else {
        return nil
    }
    image.size = NSSize(width: 22, height: 22)
    image.isTemplate = false
    return image
}

private let webIconCache = WebIconCache()
private var packagedWebIconCache: [String: NSImage] = [:]

private func officialWebIcon(for source: String, faviconURL: String?) -> NSImage? {
    if let image = packagedWebIcon(for: source) {
        return image
    }

    let urls = officialWebIconURLs(for: source, faviconURL: faviconURL)
    return webIconCache.image(for: source, urls: urls)
}

private func packagedWebIcon(for source: String) -> NSImage? {
    if let image = packagedWebIconCache[source] {
        return image
    }

    guard let url = Bundle.main.url(
        forResource: source,
        withExtension: "png",
        subdirectory: "WebIcons"
    ),
    let image = NSImage(contentsOf: url) else {
        return nil
    }

    image.isTemplate = false
    packagedWebIconCache[source] = image
    return image
}

private func officialWebIconURLs(for source: String, faviconURL: String?) -> [URL]? {
    let values: [String]
    switch source {
    case "chatgpt-web":
        values = [
            faviconURL,
            "https://chatgpt.com/apple-touch-icon.png",
            "https://chatgpt.com/favicon.ico",
            "https://chat.openai.com/favicon.ico",
        ].compactMap { $0 }
    case "claude-web":
        values = [
            faviconURL,
            "https://claude.ai/apple-touch-icon.png",
            "https://claude.ai/favicon.ico",
        ].compactMap { $0 }
    case "gemini-web":
        values = [
            faviconURL,
            "https://www.google.com/s2/favicons?domain=gemini.google.com&sz=64",
            "https://gemini.google.com/favicon.ico",
        ].compactMap { $0 }
    case "grok-web":
        values = [
            faviconURL,
            "https://grok.com/apple-touch-icon.png",
            "https://www.google.com/s2/favicons?domain=grok.com&sz=64",
            "https://grok.com/favicon.ico",
        ].compactMap { $0 }
    case "perplexity-web":
        values = [
            faviconURL,
            "https://www.google.com/s2/favicons?domain=perplexity.ai&sz=64",
            "https://www.perplexity.ai/favicon.ico",
            "https://perplexity.ai/favicon.ico",
        ].compactMap { $0 }
    case "github-web":
        values = [
            faviconURL,
            "https://github.githubassets.com/favicons/favicon.svg",
            "https://github.com/favicon.ico",
        ].compactMap { $0 }
    default:
        return nil
    }

    return values.compactMap(URL.init(string:))
}

private final class WebIconCache {
    private var images: [String: NSImage] = [:]
    private var loading: Set<String> = []

    func image(for source: String, urls: [URL]?) -> NSImage? {
        if let image = images[source] {
            return image
        }
        guard let urls, !urls.isEmpty, !loading.contains(source) else {
            return nil
        }

        loading.insert(source)
        load(source: source, urls: urls, index: 0)
        return nil
    }

    private func load(source: String, urls: [URL], index: Int) {
        guard index < urls.count else {
            loading.remove(source)
            return
        }

        let url = urls[index]
        if url.scheme == "data" {
            if let image = image(fromDataURL: url.absoluteString) {
                images[source] = image
                loading.remove(source)
                return
            }
            load(source: source, urls: urls, index: index + 1)
            return
        }

        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            load(source: source, urls: urls, index: index + 1)
            return
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if let data, let image = NSImage(data: data) {
                    self.images[source] = image
                    self.loading.remove(source)
                    return
                }
                self.load(source: source, urls: urls, index: index + 1)
            }
        }.resume()
    }

    private func image(fromDataURL value: String) -> NSImage? {
        guard let commaIndex = value.firstIndex(of: ",") else { return nil }
        let header = value[..<commaIndex]
        let payload = value[value.index(after: commaIndex)...]
        let data: Data?

        if header.lowercased().contains(";base64") {
            data = Data(base64Encoded: String(payload))
        } else {
            data = String(payload).removingPercentEncoding?.data(using: .utf8)
        }

        guard let data else { return nil }
        return NSImage(data: data)
    }
}

private extension Array where Element == AgentTask {
    func deduplicatingAgentRows() -> [AgentTask] {
        var passthrough: [AgentTask] = []
        var bestByKey: [String: AgentTask] = [:]

        for task in self {
            guard let key = task.deduplicationKey else {
                passthrough.append(task)
                continue
            }

            if let existing = bestByKey[key] {
                if task.isPreferredDuplicate(over: existing) {
                    bestByKey[key] = task.mergingDisplayName(from: existing)
                } else {
                    bestByKey[key] = existing.mergingDisplayName(from: task)
                }
            } else {
                bestByKey[key] = task
            }
        }

        return passthrough + bestByKey.values
    }
}

private func color(for status: String) -> NSColor {
    switch status {
    case "needs_permission", "waiting_for_input", "blocked":
        return .systemYellow
    case "completed":
        return .systemGreen
    case "failed":
        return .systemRed
    case "idle_but_not_done", "stale", "unknown":
        return .systemGray
    default:
        return .systemBlue
    }
}

private func parseISO8601(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) {
        return date
    }

    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: value)
}

private struct DesktopAppSnapshot {
    let pid: pid_t
    let workspaceName: String?
    let conversationName: String?
    let windowTitle: String?
    let status: String
    let step: String
}

private func localDesktopTasks(now: Date, existingTasks: [AgentTask]) -> [AgentTask] {
    guard appSettings.observeDesktop, accessibilityPermissionGranted() else { return [] }
    var tasks: [AgentTask] = []
    if let claudeTask = localClaudeCodeDesktopTask(now: now, existingTasks: existingTasks) {
        tasks.append(claudeTask)
    }
    return tasks
}

private func accessibilityPermissionGranted() -> Bool {
    AXIsProcessTrusted()
}

@discardableResult
private func requestAccessibilityPermissionPrompt() -> Bool {
    let options = [
        kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
    ] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}

private func localClaudeCodeDesktopTask(now: Date, existingTasks: [AgentTask]) -> AgentTask? {
    guard let snapshot = detectClaudeDesktopApp() else { return nil }
    if existingTasks.contains(where: { task in
        task.source == "claude-code" && task.shouldDisplay(now: now)
    }) {
        return nil
    }

    let metadata = TaskMetadata(
        detector: "macos-desktop",
        detectorDebug: snapshot.windowTitle,
        pid: Int(snapshot.pid),
        agentHost: "claude-code-desktop",
        agentHostLabel: "Claude Code Desktop",
        agentHostEvidence: snapshot.windowTitle,
        conversationName: snapshot.conversationName
    )

    return AgentTask(
        taskId: "desktop_claude_code_\(snapshot.pid)",
        source: "claude-code",
        app: "Claude",
        workspace: snapshot.workspaceName,
        sessionName: snapshot.conversationName,
        windowTitle: snapshot.windowTitle,
        title: snapshot.conversationName ?? "Claude Code Desktop",
        status: snapshot.status,
        step: snapshot.step,
        message: nil,
        updatedAt: iso8601String(now),
        actions: nil,
        metadata: metadata
    )
}

private func detectClaudeDesktopApp() -> DesktopAppSnapshot? {
    let candidates = NSWorkspace.shared.runningApplications
        .filter { app in
            guard !app.isTerminated else { return false }
            let name = app.localizedName?.lowercased() ?? ""
            let bundle = app.bundleIdentifier?.lowercased() ?? ""
            return name == "claude" ||
                name == "claude code" ||
                bundle.contains("anthropic.claude") ||
                bundle.contains("claude")
        }
        .sorted { left, right in
            if left.isActive != right.isActive { return left.isActive }
            return (left.localizedName ?? "") < (right.localizedName ?? "")
        }

    guard let app = candidates.first else { return nil }
    let title = desktopWindowTitle(for: app.processIdentifier)
    let parsed = parseClaudeDesktopTitle(title)
    let runtime = claudeDesktopRuntimeState(for: app.processIdentifier)
    return DesktopAppSnapshot(
        pid: app.processIdentifier,
        workspaceName: parsed.workspace,
        conversationName: parsed.conversation,
        windowTitle: title,
        status: runtime.status,
        step: runtime.step
    )
}

private func isCodexDesktopRunning() -> Bool {
    NSWorkspace.shared.runningApplications.contains { app in
        guard !app.isTerminated else { return false }
        let name = app.localizedName?.lowercased() ?? ""
        let bundle = app.bundleIdentifier?.lowercased() ?? ""
        return name == "codex" || bundle.contains("codex")
    }
}

private func claudeDesktopRuntimeState(for pid: pid_t) -> (status: String, step: String) {
    let text = accessibilityTexts(for: pid)
        .joined(separator: " ")
        .lowercased()

    if text.contains("stop generating") ||
        text.contains("generating") ||
        text.contains("thinking") ||
        text.contains("running") {
        return ("running", "Desktop app running")
    }

    if text.contains("awaiting input") ||
        text.contains("type / for commands") ||
        text.contains("send") {
        return ("completed", "Awaiting input")
    }

    return ("completed", "Desktop app open")
}

private func desktopWindowTitle(for pid: pid_t) -> String? {
    if let title = accessibilityWindowTitle(for: pid) {
        return title
    }

    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return nil
    }

    return windows.compactMap { window in
        guard let ownerPid = window[kCGWindowOwnerPID as String] as? Int,
              ownerPid == Int(pid),
              let layer = window[kCGWindowLayer as String] as? Int,
              layer == 0,
              let title = window[kCGWindowName as String] as? String else {
            return nil
        }
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "Claude" ? nil : cleaned
    }.first
}

private func accessibilityElement(from value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
        return nil
    }
    return (value as! AXUIElement)
}

private func accessibilityWindowTitle(for pid: pid_t) -> String? {
    let appElement = AXUIElementCreateApplication(pid)
    var focusedWindow: CFTypeRef?
    if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
       let focusedWindow = accessibilityElement(from: focusedWindow),
       let title = accessibilityTitle(from: focusedWindow) {
        return title
    }

    var windowsValue: CFTypeRef?
    if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
       let windows = windowsValue as? [AXUIElement] {
        return windows.compactMap(accessibilityTitle(from:)).first
    }

    return nil
}

private func accessibilityTexts(for pid: pid_t, maxDepth: Int = 9, maxItems: Int = 600) -> [String] {
    let appElement = AXUIElementCreateApplication(pid)
    var roots: [AXUIElement] = []

    var focusedWindow: CFTypeRef?
    if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
       let focusedWindow = accessibilityElement(from: focusedWindow) {
        roots.append(focusedWindow)
    }

    var windowsValue: CFTypeRef?
    if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
       let windows = windowsValue as? [AXUIElement] {
        roots.append(contentsOf: windows)
    }

    if roots.isEmpty {
        roots.append(appElement)
    }

    var texts: [String] = []
    var visitedCount = 0

    func appendText(_ value: String?) {
        guard let value else { return }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty && !texts.contains(cleaned) {
            texts.append(cleaned)
        }
    }

    func visit(_ element: AXUIElement, depth: Int) {
        guard depth <= maxDepth, visitedCount < maxItems else { return }
        visitedCount += 1

        for attribute in [
            kAXTitleAttribute,
            kAXValueAttribute,
            kAXDescriptionAttribute,
            kAXHelpAttribute,
        ] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let string = value as? String {
                appendText(string)
            }
        }

        for childAttribute in [kAXChildrenAttribute, kAXVisibleChildrenAttribute] {
            var childrenValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, childAttribute as CFString, &childrenValue) == .success,
               let children = childrenValue as? [AXUIElement] {
                for child in children {
                    visit(child, depth: depth + 1)
                }
            }
        }
    }

    for root in roots {
        visit(root, depth: 0)
    }

    return texts
}

private func accessibilityTitle(from element: AXUIElement) -> String? {
    var titleValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue) == .success,
          let title = titleValue as? String else {
        return nil
    }
    let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty || cleaned == "Claude" ? nil : cleaned
}

private func parseClaudeDesktopTitle(_ title: String?) -> (workspace: String?, conversation: String?) {
    guard var value = title?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return (nil, nil)
    }

    for suffix in [" - Claude", " — Claude", " | Claude"] {
        if value.hasSuffix(suffix) {
            value = String(value.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    if value.lowercased() == "claude" {
        return (nil, nil)
    }

    let slashParts = value
        .components(separatedBy: "/")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    if slashParts.count >= 2 {
        return (slashParts[0], slashParts.dropFirst().joined(separator: " / "))
    }

    return (nil, value)
}

private func iso8601String(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func openTask(_ task: AgentTask) {
    if task.isDesktopAgentTask {
        activateDesktopAgent(for: task)
        return
    }

    if let url = task.browserURL, task.isBrowserTask {
        openBrowserTab(url, for: task, action: task.primaryAction)
        return
    }

    guard let action = task.primaryAction else {
        if task.isTerminalTask {
            activateTerminal(for: task)
        }
        return
    }

    if openAction(action, for: task) {
        return
    }

    if task.isTerminalTask {
        activateTerminal(for: task)
    }
}

private func activateDesktopAgent(for task: AgentTask) {
    if let pid = task.metadata?.pid,
       let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
        app.activate(options: [.activateAllWindows])
        return
    }

    let candidates = NSWorkspace.shared.runningApplications.filter { app in
        let name = app.localizedName?.lowercased() ?? ""
        let bundle = app.bundleIdentifier?.lowercased() ?? ""

        if task.agentHostLabel == "Claude Code Desktop" {
            return name == "claude" ||
                name == "claude code" ||
                bundle.contains("anthropic.claude") ||
                bundle.contains("claude")
        }

        if task.agentHostLabel == "Codex Desktop" {
            return name == "codex" || bundle.contains("codex")
        }

        return false
    }

    if let app = candidates.first {
        app.activate(options: [.activateAllWindows])
        return
    }

    if task.agentHostLabel == "Claude Code Desktop" {
        openApplication(named: "Claude", fallbackPath: "/Applications/Claude.app")
    } else if task.agentHostLabel == "Codex Desktop" {
        openApplication(named: "Codex", fallbackPath: "/Applications/Codex.app")
    }
}

private func openApplication(named name: String, fallbackPath: String) {
    let url = URL(fileURLWithPath: fallbackPath)
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
        if let error {
            NSLog("AI Monitor could not open \(name): \(error.localizedDescription)")
        }
    }
}

@discardableResult
private func openAction(_ action: TaskAction, for task: AgentTask) -> Bool {
    switch action.type {
    case "open_browser_tab":
        if let url = allowedHTTPURL(action.normalizedTarget) {
            openBrowserTab(url, for: task, action: action)
            return true
        }
    case "open_url":
        if let url = allowedHTTPURL(action.normalizedTarget) {
            if task.isBrowserTask {
                openBrowserTab(url, for: task, action: action)
            } else {
                NSWorkspace.shared.open(url)
            }
            return true
        }
        if let url = allowedFileURL(action.normalizedTarget) {
            NSWorkspace.shared.open(url)
            return true
        }
    case "open_file":
        if let url = allowedFileURL(action.filePath ?? action.normalizedTarget) {
            NSWorkspace.shared.open(url)
            return true
        }
    case "open_terminal_session", "open_tmux_pane", "open_iterm_window", "open_warp_session":
        if let url = allowedTerminalURL(action.normalizedTarget, actionType: action.type) {
            NSWorkspace.shared.open(url)
            return true
        }
    case "open_vscode_workspace":
        if let url = allowedIDEURL(action.normalizedTarget, schemes: ["vscode", "vscode-insiders"]) ??
            allowedFileURL(action.filePath ?? action.normalizedTarget) {
            NSWorkspace.shared.open(url)
            return true
        }
    case "open_cursor_composer":
        if let url = allowedIDEURL(action.normalizedTarget, schemes: ["cursor"]) {
            NSWorkspace.shared.open(url)
            return true
        }
    case "open_github_pr":
        if let url = allowedHTTPURL(action.normalizedTarget, hosts: ["github.com"]) {
            NSWorkspace.shared.open(url)
            return true
        }
    case "open_slack_thread":
        if let url = allowedHTTPURL(action.normalizedTarget, hostSuffixes: [".slack.com"]) {
            NSWorkspace.shared.open(url)
            return true
        }
    case "open_notion_page":
        if let url = allowedHTTPURL(action.normalizedTarget, hosts: ["notion.so", "www.notion.so"], hostSuffixes: [".notion.site"]) ??
            allowedIDEURL(action.normalizedTarget, schemes: ["notion"]) {
            NSWorkspace.shared.open(url)
            return true
        }
    default:
        return false
    }

    if task.isTerminalTask {
        return false
    }
    return false
}

private func allowedHTTPURL(_ value: String) -> URL? {
    allowedHTTPURL(value, allowedHosts: nil, allowedHostSuffixes: [])
}

private func allowedHTTPURL(
    _ value: String,
    hosts: [String],
    hostSuffixes: [String] = []
) -> URL? {
    allowedHTTPURL(
        value,
        allowedHosts: Set(hosts.map { $0.lowercased() }),
        allowedHostSuffixes: hostSuffixes.map { $0.lowercased() }
    )
}

private func allowedHTTPURL(
    _ value: String,
    hostSuffixes: [String]
) -> URL? {
    allowedHTTPURL(value, allowedHosts: nil, allowedHostSuffixes: hostSuffixes.map { $0.lowercased() })
}

private func allowedHTTPURL(
    _ value: String,
    allowedHosts: Set<String>?,
    allowedHostSuffixes: [String]
) -> URL? {
    guard let url = URL(string: value),
          let scheme = url.scheme?.lowercased(),
          ["http", "https"].contains(scheme),
          let host = url.host?.lowercased() else {
        return nil
    }

    if let allowedHosts {
        return allowedHosts.contains(host) ? url : nil
    }
    if !allowedHostSuffixes.isEmpty {
        return allowedHostSuffixes.contains(where: { host.hasSuffix($0) }) ? url : nil
    }
    return url
}

private func allowedFileURL(_ value: String) -> URL? {
    let target = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else { return nil }

    if let url = URL(string: target),
       url.scheme?.lowercased() == "file",
       url.isFileURL,
       url.path.hasPrefix("/") {
        return url
    }

    if target.hasPrefix("/") {
        return URL(fileURLWithPath: target)
    }

    return nil
}

private func allowedTerminalURL(_ value: String, actionType: String) -> URL? {
    guard let url = URL(string: value),
          let scheme = url.scheme?.lowercased() else {
        return nil
    }

    switch actionType {
    case "open_iterm_window":
        return ["iterm", "iterm2"].contains(scheme) ? url : nil
    case "open_warp_session":
        return scheme == "warp" ? url : nil
    case "open_terminal_session", "open_tmux_pane":
        return ["iterm", "iterm2", "warp"].contains(scheme) ? url : nil
    default:
        return nil
    }
}

private func allowedIDEURL(_ value: String, schemes: Set<String>) -> URL? {
    guard let url = URL(string: value),
          let scheme = url.scheme?.lowercased(),
          schemes.contains(scheme) else {
        return nil
    }
    return url
}

private func allowedIDEURL(_ value: String, schemes: [String]) -> URL? {
    allowedIDEURL(value, schemes: Set(schemes.map { $0.lowercased() }))
}

private func handleMonitorDeepLink(_ url: URL) -> String? {
    guard url.scheme?.lowercased() == "ai-monitor" else { return nil }
    let host = url.host?.lowercased()
    let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
    let pathParts = encodedPath
        .split(separator: "/")
        .map { String($0).removingPercentEncoding ?? String($0) }

    if host == "task", let taskId = pathParts.first {
        return taskId
    }
    if host == "tasks", let taskId = pathParts.first {
        return taskId
    }
    if host == "open", pathParts.first == "task", pathParts.count >= 2 {
        return pathParts[1]
    }
    return nil
}

private func isSettingsDeepLink(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "ai-monitor" else { return false }
    let host = url.host?.lowercased()
    let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
    let pathParts = encodedPath
        .split(separator: "/")
        .map { String($0).removingPercentEncoding ?? String($0) }

    return host == "settings" || (host == "open" && pathParts.first == "settings")
}

private func shouldNotifyForTask(_ task: AgentTask, now: Date) -> Bool {
    guard ["needs_permission", "waiting_for_input", "blocked", "idle_but_not_done", "failed", "completed"].contains(task.status) else {
        return false
    }
    guard let updatedDate = task.updatedDate else {
        return true
    }
    return now.timeIntervalSince(updatedDate) <= appNotificationRecentSeconds
}

private func appNotificationKey(for task: AgentTask) -> String {
    "\(task.taskId):\(task.status):\(task.updatedAt)"
}

private func notificationTitle(for task: AgentTask) -> String {
    switch task.status {
    case "needs_permission":
        return "AI Monitor needs permission"
    case "waiting_for_input":
        return "AI Monitor is waiting"
    case "blocked", "idle_but_not_done":
        return "AI Monitor needs attention"
    case "failed":
        return "AI task failed"
    case "completed":
        return "AI task completed"
    default:
        return "AI Monitor"
    }
}

private func notificationBody(for task: AgentTask) -> String {
    let detail = task.step ?? task.message ?? task.compactSourceName
    if let workspace = task.workspaceLabel {
        return "\(task.displayName) - \(workspace) - \(detail)"
    }
    return "\(task.displayName) - \(detail)"
}

private func postClickableTaskNotification(_ task: AgentTask) {
    let content = UNMutableNotificationContent()
    content.title = notificationTitle(for: task)
    content.body = notificationBody(for: task)
    content.categoryIdentifier = notificationCategoryIdentifier
    content.userInfo = [
        "task_id": task.taskId,
        "deep_link": "ai-monitor://task/\(task.taskId)"
    ]
    content.sound = .default

    let request = UNNotificationRequest(
        identifier: appNotificationKey(for: task),
        content: content,
        trigger: nil
    )
    UNUserNotificationCenter.current().add(request) { error in
        if let error {
            NSLog("AI Monitor notification failed: \(error.localizedDescription)")
        }
    }
}

private func fetchTask(taskId: String, completion: @escaping (AgentTask?) -> Void) {
    let url = appSettings.daemonURL.appendingPathComponent("tasks").appendingPathComponent(taskId)
    URLSession.shared.dataTask(with: authorizedRequest(url: url)) { data, response, _ in
        guard let data,
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let detail = try? JSONDecoder().decode(TaskDetail.self, from: data) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        DispatchQueue.main.async { completion(detail.task) }
    }.resume()
}

@discardableResult
private func openURLIfAllowed(_ url: URL) -> Bool {
    if let taskId = handleMonitorDeepLink(url) {
        fetchTask(taskId: taskId) { task in
            guard let task else { return }
            openTask(task)
        }
        return true
    }
    if let http = allowedHTTPURL(url.absoluteString) {
        NSWorkspace.shared.open(http)
        return true
    }
    if let file = allowedFileURL(url.absoluteString) {
        NSWorkspace.shared.open(file)
        return true
    }
    return false
}

private func activateTerminal(for task: AgentTask) {
    let appName = terminalApplicationName(for: task)
    let script = "tell application \(appleScriptString(appName)) to activate"
    var error: NSDictionary?
    NSAppleScript(source: script)?.executeAndReturnError(&error)
}

private func terminalApplicationName(for task: AgentTask) -> String {
    let program = (task.metadata?.terminalProgram ?? task.windowTitle ?? "").lowercased()
    if program.contains("iterm") {
        return "iTerm"
    }
    if program.contains("warp") {
        return "Warp"
    }
    return "Terminal"
}

private struct BrowserOpenTarget {
    let bundleIdentifier: String?
    let applicationName: String?
}

private func openBrowserTab(_ url: URL, for task: AgentTask, action: TaskAction?) {
    let target = browserOpenTarget(for: task, action: action)
    if let helperURL = browserExtensionOpenURL(for: url, task: task, action: action) {
        openURLInBrowser(helperURL, target: target)
        return
    }

    if let appName = target.applicationName {
        if target.bundleIdentifier == "com.apple.Safari" {
            if activateExistingSafariTab(url, applicationName: appName) {
                return
            }
        } else if supportsChromiumTabScripting(target) {
            if activateExistingChromiumTab(url, applicationName: appName) {
                return
            }
        }
    }

    openURLInBrowser(url, target: target)
}

private func browserOpenTarget(for task: AgentTask, action: TaskAction?) -> BrowserOpenTarget {
    if let bundleIdentifier = firstNonEmpty([
        action?.appBundleId,
        action?.metadata?.browserBundleId,
        task.metadata?.browserBundleId,
    ]) {
        return BrowserOpenTarget(
            bundleIdentifier: bundleIdentifier,
            applicationName: browserApplicationName(forBundleIdentifier: bundleIdentifier)
        )
    }

    let hints = [
        task.metadata?.browserApp,
        task.app,
        task.windowTitle,
        task.sourceLabel,
    ]
    .compactMap { $0?.lowercased() }
    .joined(separator: " ")

    if hints.contains("safari") {
        return BrowserOpenTarget(bundleIdentifier: "com.apple.Safari", applicationName: "Safari")
    }
    if hints.contains("edge") {
        return BrowserOpenTarget(bundleIdentifier: "com.microsoft.edgemac", applicationName: "Microsoft Edge")
    }
    if hints.contains("brave") {
        return BrowserOpenTarget(bundleIdentifier: "com.brave.Browser", applicationName: "Brave Browser")
    }
    if hints.contains("arc") {
        return BrowserOpenTarget(bundleIdentifier: "company.thebrowser.Browser", applicationName: "Arc")
    }
    if hints.contains("firefox") {
        return BrowserOpenTarget(bundleIdentifier: "org.mozilla.firefox", applicationName: "Firefox")
    }
    if hints.contains("opera") {
        return BrowserOpenTarget(bundleIdentifier: "com.operasoftware.Opera", applicationName: "Opera")
    }
    if hints.contains("chrome") {
        return BrowserOpenTarget(bundleIdentifier: "com.google.Chrome", applicationName: "Google Chrome")
    }

    return BrowserOpenTarget(bundleIdentifier: nil, applicationName: nil)
}

private func browserExtensionOpenURL(for target: URL, task: AgentTask, action: TaskAction?) -> URL? {
    let tabId = action?.metadata?.tabId ?? task.metadata?.browserTabId
    let windowId = action?.metadata?.windowId ?? task.metadata?.browserWindowId
    guard let extensionId = firstNonEmpty([action?.metadata?.extensionId, task.metadata?.extensionId]),
          tabId != nil else {
        return nil
    }

    var components = URLComponents()
    components.scheme = "chrome-extension"
    components.host = extensionId
    components.path = "/open-tab.html"
    var queryItems = [
        URLQueryItem(name: "target", value: target.absoluteString),
    ]
    if let tabId {
        queryItems.append(URLQueryItem(name: "tab_id", value: String(tabId)))
    }
    if let windowId {
        queryItems.append(URLQueryItem(name: "window_id", value: String(windowId)))
    }
    components.queryItems = queryItems
    return components.url
}

private func firstNonEmpty(_ values: [String?]) -> String? {
    values
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
}

private func browserApplicationName(forBundleIdentifier bundleIdentifier: String) -> String? {
    switch bundleIdentifier.lowercased() {
    case "com.google.chrome":
        return "Google Chrome"
    case "com.apple.safari":
        return "Safari"
    case "com.microsoft.edgemac":
        return "Microsoft Edge"
    case "com.brave.browser":
        return "Brave Browser"
    case "company.thebrowser.browser":
        return "Arc"
    case "org.mozilla.firefox":
        return "Firefox"
    case "com.operasoftware.opera":
        return "Opera"
    default:
        return nil
    }
}

private func supportsChromiumTabScripting(_ target: BrowserOpenTarget) -> Bool {
    guard let bundleIdentifier = target.bundleIdentifier?.lowercased() else { return false }
    return [
        "com.google.chrome",
        "com.microsoft.edgemac",
        "com.brave.browser",
        "com.operasoftware.opera",
    ].contains(bundleIdentifier)
}

private func activateExistingChromiumTab(_ url: URL, applicationName: String) -> Bool {
    let target = url.absoluteString
    let targetPrefix = url.withoutFragment.absoluteString
    let script = """
    tell application \(appleScriptString(applicationName))
      set targetURL to \(appleScriptString(target))
      set targetPrefix to \(appleScriptString(targetPrefix))
      set foundTab to false
      repeat with windowIndex from 1 to count of windows
        set tabCount to count of tabs of window windowIndex
        repeat with tabIndex from 1 to tabCount
          set currentURL to URL of tab tabIndex of window windowIndex
          if currentURL is targetURL or currentURL starts with targetPrefix then
            set active tab index of window windowIndex to tabIndex
            set index of window windowIndex to 1
            set foundTab to true
            exit repeat
          end if
        end repeat
        if foundTab then exit repeat
      end repeat
      activate
      return foundTab
    end tell
    """

    var error: NSDictionary?
    let output = NSAppleScript(source: script)?.executeAndReturnError(&error)
    return output?.booleanValue == true
}

private func activateExistingSafariTab(_ url: URL, applicationName: String) -> Bool {
    let target = url.absoluteString
    let targetPrefix = url.withoutFragment.absoluteString
    let script = """
    tell application \(appleScriptString(applicationName))
      set targetURL to \(appleScriptString(target))
      set targetPrefix to \(appleScriptString(targetPrefix))
      set foundTab to false
      repeat with windowIndex from 1 to count of windows
        set tabCount to count of tabs of window windowIndex
        repeat with tabIndex from 1 to tabCount
          set currentURL to URL of tab tabIndex of window windowIndex
          if currentURL is targetURL or currentURL starts with targetPrefix then
            set current tab of window windowIndex to tab tabIndex of window windowIndex
            set index of window windowIndex to 1
            set foundTab to true
            exit repeat
          end if
        end repeat
        if foundTab then exit repeat
      end repeat
      activate
      return foundTab
    end tell
    """

    var error: NSDictionary?
    let output = NSAppleScript(source: script)?.executeAndReturnError(&error)
    return output?.booleanValue == true
}

private func openURLInBrowser(_ url: URL, target: BrowserOpenTarget) {
    guard let bundleIdentifier = target.bundleIdentifier,
          let browserURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
        NSWorkspace.shared.open(url)
        return
    }

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.open([url], withApplicationAt: browserURL, configuration: configuration) { _, error in
        if let error {
            NSLog("AI Monitor could not open URL in browser \(bundleIdentifier): \(error.localizedDescription)")
            NSWorkspace.shared.open(url)
        }
    }
}

private func appleScriptString(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}

private extension URL {
    var withoutFragment: URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url ?? self
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var isGenericDisplayName: Bool {
        let normalized = trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty || [
            "chatgpt",
            "chatgpt - chrome",
            "claude",
            "claude - chrome",
            "gemini",
            "gemini - chrome",
            "perplexity",
            "perplexity - chrome",
            "grok",
            "grok - chrome",
            "codex",
            "codex cli",
            "codex desktop",
            "codex vs code",
            "ai browser",
            "ai browser task",
        ].contains(normalized)
    }

    var isMachineGeneratedDisplayName: Bool {
        let normalized = trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { return false }

        if let suffix = normalized.machineGeneratedSessionSuffix {
            return suffix.isMachineIdentifier
        }

        if let lastPart = normalized.components(separatedBy: " - ").last,
           lastPart != normalized,
           let suffix = lastPart.machineGeneratedSessionSuffix {
            return suffix.isMachineIdentifier
        }

        return false
    }

    private var machineGeneratedSessionSuffix: String? {
        for prefix in ["codex:", "codex-cli:", "claude-code:", "gemini-cli:"] {
            if hasPrefix(prefix) {
                return String(dropFirst(prefix.count))
            }
        }
        return nil
    }

    private var isMachineIdentifier: Bool {
        count >= 8 && allSatisfy { character in
            character.isASCII && (
                character.isNumber ||
                ("a"..."f").contains(character) ||
                character == "-"
            )
        }
    }
}

private func filterTasksBySettings(_ tasks: [AgentTask]) -> [AgentTask] {
    tasks.filter { task in
        guard taskAllowedBySourceSettings(task) else { return false }
        guard !workspaceIgnoredBySettings(task.workspace) else { return false }
        return true
    }
}

private func taskAllowedBySourceSettings(_ task: AgentTask) -> Bool {
    if task.isDesktopAgentTask {
        return appSettings.observeDesktop
    }
    if isIdeTask(task) {
        return appSettings.observeIDE
    }
    if task.isBrowserTask {
        return appSettings.observeBrowser
    }
    if task.isTerminalTask {
        return appSettings.observeTerminal
    }
    return true
}

private func isIdeTask(_ task: AgentTask) -> Bool {
    ["vscode", "cursor", "jetbrains"].contains(task.source.lowercased()) ||
        task.app?.lowercased() == "vs code" ||
        task.app?.lowercased() == "cursor" ||
        task.app?.lowercased() == "jetbrains"
}

private func workspaceIgnoredBySettings(_ workspace: String?) -> Bool {
    guard let workspace, !workspace.isEmpty else { return false }
    return appSettings.ignoredWorkspacePrefixes.contains { prefix in
        workspace == prefix || workspace.hasPrefix(prefix.hasSuffix("/") ? prefix : "\(prefix)/")
    }
}

private struct KeychainSaveError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return message
        }
        return "Keychain write failed with status \(status)"
    }
}

private struct LaunchAgentError: LocalizedError {
    let status: Int32
    let output: String

    var errorDescription: String? {
        output.nilIfEmpty ?? "launchctl failed with status \(status)"
    }
}

private struct LaunchAgentStatusSnapshot {
    let plistExists: Bool
    let loaded: Bool
    let running: Bool
    let pid: String?
    let state: String?
    let message: String
}

private struct ConfigEditError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

private func providerSecretAccount(providerId: String, settingKey: String) -> String {
    let provider = providerId
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: " ", with: "-")
    let setting = settingKey
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: " ", with: "-")
    return "\(provider)-\(setting)"
}

private func keychainReference(service: String, account: String) -> String {
    "keychain://\(service)/\(account)"
}

private func parseKeychainReference(_ reference: String) -> (service: String, account: String)? {
    guard reference.hasPrefix("keychain://") else {
        return nil
    }
    let rest = String(reference.dropFirst("keychain://".count))
    guard let slash = rest.firstIndex(of: "/") else {
        return nil
    }
    let service = rest[..<slash].trimmingCharacters(in: .whitespacesAndNewlines)
    let account = rest[rest.index(after: slash)...].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !service.isEmpty, !account.isEmpty else { return nil }
    return (service, account)
}

private func keychainItemExists(service: String, account: String) -> Bool {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
}

private func usableExistingSecretReference(_ value: String) -> String? {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, !value.hasPrefix("${") else { return nil }
    if let keychain = parseKeychainReference(value) {
        return keychainItemExists(service: keychain.service, account: keychain.account) ? value : nil
    }
    return value
}

private func saveGenericPasswordToKeychain(service: String, account: String, secret: String) throws {
    let service = service.trimmingCharacters(in: .whitespacesAndNewlines)
    let account = account.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !service.isEmpty, !account.isEmpty, !secret.isEmpty else {
        throw KeychainSaveError(status: errSecParam)
    }

    let secretData = Data(secret.utf8)
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
    ]

    let updateStatus = SecItemUpdate(query as CFDictionary, [
        kSecValueData as String: secretData,
    ] as CFDictionary)
    if updateStatus == errSecSuccess {
        return
    }

    if updateStatus != errSecItemNotFound {
        throw KeychainSaveError(status: updateStatus)
    }

    var addQuery = query
    addQuery[kSecValueData as String] = secretData
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    if addStatus != errSecSuccess {
        throw KeychainSaveError(status: addStatus)
    }
}

private func copyToPasteboard(_ value: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(value, forType: .string)
}

private func pasteboardString() -> String? {
    NSPasteboard.general.string(forType: .string)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nilIfEmpty
}

private func runLaunchAgentCommand(_ action: String) throws -> String {
    switch action {
    case "install", "restart":
        try validateLaunchAgentInstallLocation()
        try stopLaunchedDaemonProcessForLaunchAgentInstall()
        try writeLaunchAgentPlist()
        _ = try? launchctl(["bootout", launchAgentDomain(), launchAgentPlistURL().path])
        _ = try launchctl(["bootstrap", launchAgentDomain(), launchAgentPlistURL().path])
        _ = try? launchctl(["kickstart", "-k", "\(launchAgentDomain())/\(launchAgentLabel)"])
        return "Installed login daemon. \(launchAgentStatusSnapshot().message)"
    case "uninstall":
        _ = try? launchctl(["bootout", launchAgentDomain(), launchAgentPlistURL().path])
        if FileManager.default.fileExists(atPath: launchAgentPlistURL().path) {
            try FileManager.default.removeItem(at: launchAgentPlistURL())
        }
        return "Removed \(launchAgentPlistURL().path)"
    case "status":
        return launchAgentStatusSnapshot().message
    default:
        throw ConfigEditError(message: "Unknown LaunchAgent action: \(action)")
    }
}

private func stopLaunchedDaemonProcessForLaunchAgentInstall() throws {
    guard let process = launchedDaemonProcess else {
        return
    }
    guard process.isRunning else {
        launchedDaemonProcess = nil
        return
    }

    process.terminate()
    for _ in 0..<20 {
        if !process.isRunning {
            launchedDaemonProcess = nil
            return
        }
        Thread.sleep(forTimeInterval: 0.1)
    }

    throw ConfigEditError(message: "Manual daemon is still stopping. Try installing the login daemon again in a moment.")
}

private func stopLaunchedDaemonProcessOnAppQuit() {
    guard let process = launchedDaemonProcess else {
        return
    }

    if process.isRunning {
        process.terminate()
        for _ in 0..<10 {
            if !process.isRunning {
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
    launchedDaemonProcess = nil
}

private func launchAgentStatusSnapshot() -> LaunchAgentStatusSnapshot {
    let plistExists = FileManager.default.fileExists(atPath: launchAgentPlistURL().path)

    do {
        let output = try launchctl(["print", "\(launchAgentDomain())/\(launchAgentLabel)"])
        let state = launchctlValue("state", in: output)
        let pid = launchctlValue("pid", in: output)
        let running = state == "running" || pid != nil
        let message: String
        if let pid, running {
            message = "Login daemon loaded and running (pid \(pid))"
        } else if let state {
            message = "Login daemon loaded (\(state))"
        } else {
            message = "Login daemon loaded"
        }

        return LaunchAgentStatusSnapshot(
            plistExists: plistExists,
            loaded: true,
            running: running,
            pid: pid,
            state: state,
            message: message
        )
    } catch {
        let message = plistExists
            ? "Login daemon plist exists but is not loaded: \(error.localizedDescription)"
            : "Login daemon is not installed"
        return LaunchAgentStatusSnapshot(
            plistExists: plistExists,
            loaded: false,
            running: false,
            pid: nil,
            state: nil,
            message: message
        )
    }
}

private func launchctlValue(_ key: String, in output: String) -> String? {
    let prefix = "\(key) = "
    let matchingLine = output.components(separatedBy: .newlines)
        .lazy
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { $0.hasPrefix(prefix) })
    guard let matchingLine else {
        return nil
    }

    return String(matchingLine.dropFirst(prefix.count))
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nilIfEmpty
}

private func validateLaunchAgentInstallLocation() throws {
    guard !appIsRunningFromTransientLocation() else {
        throw ConfigEditError(message: "Drag AI Monitor.app to Applications and reopen it before installing the login daemon")
    }
}

private func validateDaemonLaunchLocation() throws {
    guard !appIsRunningFromTransientLocation() else {
        throw ConfigEditError(message: "Drag AI Monitor.app to Applications and reopen it before starting the daemon")
    }
}

private func appIsRunningFromTransientLocation() -> Bool {
    let path = Bundle.main.bundleURL.standardizedFileURL.path
    return path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/")
}

private func writeLaunchAgentPlist() throws {
    try persistConfiguredAPITokenToDefaultFile()
    let command = try daemonLaunchCommand()
    let logDirectory = try launchAgentLogDirectory()
    let plistURL = launchAgentPlistURL()

    try FileManager.default.createDirectory(
        at: plistURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    let argumentXML = command.arguments
        .map { "    <string>\(xmlEscaped($0))</string>" }
        .joined(separator: "\n")

    let plist = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>\(xmlEscaped(launchAgentLabel))</string>
  <key>ProgramArguments</key>
  <array>
\(argumentXML)
  </array>
  <key>WorkingDirectory</key>
  <string>\(xmlEscaped(command.workingDirectory.path))</string>
  <key>EnvironmentVariables</key>
  <dict/>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>StandardOutPath</key>
  <string>\(xmlEscaped(logDirectory.appendingPathComponent("daemon.out.log").path))</string>
  <key>StandardErrorPath</key>
  <string>\(xmlEscaped(logDirectory.appendingPathComponent("daemon.err.log").path))</string>
</dict>
</plist>
"""

    let temporaryPlistURL = plistURL.deletingLastPathComponent()
        .appendingPathComponent(".\(plistURL.lastPathComponent).tmp")
    defer {
        try? FileManager.default.removeItem(at: temporaryPlistURL)
    }

    try plist.write(to: temporaryPlistURL, atomically: true, encoding: .utf8)
    _ = try runProcess(URL(fileURLWithPath: "/usr/bin/plutil"), arguments: ["-lint", temporaryPlistURL.path])
    if FileManager.default.fileExists(atPath: plistURL.path) {
        _ = try FileManager.default.replaceItemAt(
            plistURL,
            withItemAt: temporaryPlistURL,
            backupItemName: nil,
            options: []
        )
    } else {
        try FileManager.default.moveItem(at: temporaryPlistURL, to: plistURL)
    }
}

private struct DaemonLaunchCommand {
    let arguments: [String]
    let workingDirectory: URL
}

private func daemonLaunchCommand() throws -> DaemonLaunchCommand {
    let bind = daemonBindAddress()
    let database = try daemonDatabaseURL().path
    let config = appSettings.daemonConfigURL.path
    let tokenFile = defaultAPITokenFileURL().path

    if let daemon = daemonExecutableURL() {
        return DaemonLaunchCommand(
            arguments: [
                daemon.path,
                "--bind", bind,
                "--database", database,
                "--config", config,
                "--api-token-file", tokenFile,
            ],
            workingDirectory: try ensureApplicationSupportDirectory()
        )
    }

    let root = repoRootURL()
    return DaemonLaunchCommand(
        arguments: [
            "/usr/bin/env",
            "cargo", "run", "-p", "ai-monitor-daemon", "--",
            "--bind", bind,
            "--database", database,
            "--config", config,
            "--api-token-file", tokenFile,
        ],
        workingDirectory: root
    )
}

private func launchctl(_ arguments: [String]) throws -> String {
    try runProcess(URL(fileURLWithPath: "/bin/launchctl"), arguments: arguments)
}

private func runProcess(_ executableURL: URL, arguments: [String]) throws -> String {
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    try process.run()
    process.waitUntilExit()

    let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let combined = [output, error]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    if process.terminationStatus != 0 {
        throw LaunchAgentError(status: process.terminationStatus, output: combined)
    }
    return combined
}

private func launchAgentDomain() -> String {
    "gui/\(getuid())"
}

private func launchAgentPlistURL() -> URL {
    URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
}

private func launchAgentLogDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/AI Monitor", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func daemonStdoutLogURL() throws -> URL {
    let url = try launchAgentLogDirectory().appendingPathComponent("daemon.out.log")
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    return url
}

private func daemonStderrLogURL() throws -> URL {
    let url = try launchAgentLogDirectory().appendingPathComponent("daemon.err.log")
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    return url
}

private func xmlEscaped(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}

private func upsertProviderSecretReference(
    configURL: URL,
    providerId: String,
    providerType: String,
    settingKey: String,
    reference: String,
    settings: [String: String] = [:]
) throws {
    let providerId = providerId.trimmingCharacters(in: .whitespacesAndNewlines)
    let providerType = providerType.trimmingCharacters(in: .whitespacesAndNewlines)
    let settingKey = settingKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !providerId.isEmpty, !providerType.isEmpty, !settingKey.isEmpty else {
        throw KeychainSaveError(status: errSecParam)
    }

    var lines = try String(contentsOf: configURL, encoding: .utf8).components(separatedBy: .newlines)
    if let block = providerBlockRange(lines: lines, providerId: providerId) {
        var providerBlock = Array(lines[block])
        upsertAssignment("enabled", value: "true", in: &providerBlock)
        upsertAssignment(settingKey, value: quotedTomlString(reference), in: &providerBlock)
        for (key, value) in settings {
            upsertAssignment(key, value: quotedTomlString(value), in: &providerBlock)
        }
        lines.replaceSubrange(block, with: providerBlock)
    } else {
        if lines.last?.isEmpty == false {
            lines.append("")
        }
        lines.append(contentsOf: [
            "[[providers]]",
            "id = \(quotedTomlString(providerId))",
            "type = \(quotedTomlString(providerType))",
            "enabled = true",
            "\(settingKey) = \(quotedTomlString(reference))",
        ])
        for (key, value) in settings {
            lines.append("\(key) = \(quotedTomlString(value))")
        }
    }

    try lines.joined(separator: "\n").write(to: configURL, atomically: true, encoding: .utf8)
}

private func providerSettingValue(configURL: URL, providerId: String, settingKey: String) -> String? {
    guard let lines = try? String(contentsOf: configURL, encoding: .utf8).components(separatedBy: .newlines),
          let block = providerBlockRange(lines: lines, providerId: providerId) else {
        return nil
    }
    return lines[block]
        .compactMap { assignmentValue(for: settingKey, in: $0) }
        .first
}

private func providerConfigEntries(configURL: URL) throws -> [ProviderConfigEntry] {
    let lines = try String(contentsOf: configURL, encoding: .utf8).components(separatedBy: .newlines)
    var providers: [ProviderConfigEntry] = []
    var index = 0
    while index < lines.count {
        guard lines[index].trimmingCharacters(in: .whitespacesAndNewlines) == "[[providers]]" else {
            index += 1
            continue
        }

        let start = index
        index += 1
        while index < lines.count,
              !isTomlTableHeader(lines[index]) {
            index += 1
        }

        let block = lines[start..<index]
        let settings = Dictionary(
            uniqueKeysWithValues: block.compactMap { tomlAssignment(in: $0) }
        )
        guard let id = settings["id"], let type = settings["type"] else {
            continue
        }
        let enabled = settings["enabled"]?.lowercased() != "false"
        providers.append(ProviderConfigEntry(id: id, type: type, enabled: enabled, settings: settings))
    }

    return providers
}

private func tomlAssignment(in line: String) -> (String, String)? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.hasPrefix("#"),
          let equals = trimmed.firstIndex(of: "=") else {
        return nil
    }

    let key = trimmed[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return nil }
    let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
    return (String(key), unquoteTomlString(String(value)))
}

private func upsertIgnoreRule(
    configURL: URL,
    ruleId: String,
    mode: String,
    app: String,
    source: String,
    siteContains: String,
    workspacePrefix: String,
    workspaceContains: String
) throws {
    let ruleId = ruleId.trimmingCharacters(in: .whitespacesAndNewlines)
    let mode = mode.trimmingCharacters(in: .whitespacesAndNewlines)
    let app = app.trimmingCharacters(in: .whitespacesAndNewlines)
    let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
    let siteContains = siteContains.trimmingCharacters(in: .whitespacesAndNewlines)
    let workspacePrefix = workspacePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
    let workspaceContains = workspaceContains.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !ruleId.isEmpty else {
        throw ConfigEditError(message: "Ignore rule id is required")
    }
    guard ["ignore", "local_only"].contains(mode) else {
        throw ConfigEditError(message: "Ignore rule mode must be ignore or local_only")
    }
    guard [app, source, siteContains, workspacePrefix, workspaceContains].contains(where: { !$0.isEmpty }) else {
        throw ConfigEditError(message: "At least one app, source, site, or workspace matcher is required")
    }

    var lines = try String(contentsOf: configURL, encoding: .utf8).components(separatedBy: .newlines)
    if let block = tableBlockRange(lines: lines, tableName: "ignore_rules", id: ruleId) {
        var ruleBlock = Array(lines[block])
        upsertAssignment("id", value: quotedTomlString(ruleId), in: &ruleBlock)
        upsertAssignment("enabled", value: "true", in: &ruleBlock)
        upsertAssignment("mode", value: quotedTomlString(mode), in: &ruleBlock)
        upsertOptionalAssignment("app", value: app, in: &ruleBlock)
        upsertOptionalAssignment("source", value: source, in: &ruleBlock)
        upsertOptionalAssignment("site_contains", value: siteContains, in: &ruleBlock)
        upsertOptionalAssignment("workspace_prefix", value: workspacePrefix, in: &ruleBlock)
        upsertOptionalAssignment("workspace_contains", value: workspaceContains, in: &ruleBlock)
        lines.replaceSubrange(block, with: ruleBlock)
    } else {
        if lines.last?.isEmpty == false {
            lines.append("")
        }
        var ruleBlock = [
            "[[ignore_rules]]",
            "id = \(quotedTomlString(ruleId))",
            "enabled = true",
            "mode = \(quotedTomlString(mode))",
        ]
        appendOptionalAssignment("app", value: app, to: &ruleBlock)
        appendOptionalAssignment("source", value: source, to: &ruleBlock)
        appendOptionalAssignment("site_contains", value: siteContains, to: &ruleBlock)
        appendOptionalAssignment("workspace_prefix", value: workspacePrefix, to: &ruleBlock)
        appendOptionalAssignment("workspace_contains", value: workspaceContains, to: &ruleBlock)
        lines.append(contentsOf: ruleBlock)
    }

    try lines.joined(separator: "\n").write(to: configURL, atomically: true, encoding: .utf8)
}

private func providerBlockRange(lines: [String], providerId: String) -> Range<Int>? {
    tableBlockRange(lines: lines, tableName: "providers", id: providerId)
}

private func tableBlockRange(lines: [String], tableName: String, id: String) -> Range<Int>? {
    let header = "[[\(tableName)]]"
    var index = 0
    while index < lines.count {
        guard lines[index].trimmingCharacters(in: .whitespacesAndNewlines) == header else {
            index += 1
            continue
        }

        let start = index
        index += 1
        while index < lines.count,
              !isTomlTableHeader(lines[index]) {
            index += 1
        }

        let end = index
        if lines[start..<end].contains(where: { assignmentValue(for: "id", in: $0) == id }) {
            return start..<end
        }
    }

    return nil
}

private func isTomlTableHeader(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.hasPrefix("[") && trimmed.hasSuffix("]")
}

private func upsertAssignment(_ key: String, value: String, in block: inout [String]) {
    for index in block.indices where assignmentValue(for: key, in: block[index]) != nil {
        block[index] = "\(key) = \(value)"
        return
    }

    let insertIndex = block.indices.first { assignmentValue(for: "enabled", in: block[$0]) != nil }
        .map { block.index(after: $0) }
        ?? block.count
    block.insert("\(key) = \(value)", at: insertIndex)
}

private func upsertOptionalAssignment(_ key: String, value: String, in block: inout [String]) {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty {
        block.removeAll { assignmentValue(for: key, in: $0) != nil }
    } else {
        upsertAssignment(key, value: quotedTomlString(value), in: &block)
    }
}

private func appendOptionalAssignment(_ key: String, value: String, to block: inout [String]) {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if !value.isEmpty {
        block.append("\(key) = \(quotedTomlString(value))")
    }
}

private func assignmentValue(for key: String, in line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.hasPrefix("#") else { return nil }
    guard trimmed.hasPrefix("\(key)") else { return nil }
    let remainder = trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespacesAndNewlines)
    guard remainder.hasPrefix("=") else { return nil }
    let rawValue = remainder.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
    return unquoteTomlString(String(rawValue))
}

private func quotedTomlString(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}

private func unquoteTomlString(_ value: String) -> String {
    var value = value
    if let commentStart = value.firstIndex(of: "#") {
        value = String(value[..<commentStart])
    }
    value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
        value.removeFirst()
        value.removeLast()
    }
    return value
        .replacingOccurrences(of: "\\\"", with: "\"")
        .replacingOccurrences(of: "\\\\", with: "\\")
}

private struct ProviderSetupPreset {
    let title: String
    let providerId: String
    let providerType: String
    let settingKey: String
    let secretPlaceholder: String
    let extraSettingKey: String?
    let extraSettingLabel: String?
    let extraSettingPlaceholder: String?
    let zhGuide: String
    let enGuide: String
}

private let providerSetupPresets: [ProviderSetupPreset] = [
    ProviderSetupPreset(
        title: "Slack",
        providerId: "slack",
        providerType: "slack",
        settingKey: "webhook_url",
        secretPlaceholder: "https://hooks.slack.com/services/...",
        extraSettingKey: nil,
        extraSettingLabel: nil,
        extraSettingPlaceholder: nil,
        zhGuide: """
        Slack 配置步骤：
        1. 打开 Slack App 管理页面，创建 Incoming Webhook。
        2. 复制 webhook URL，格式通常是 https://hooks.slack.com/services/...
        3. 把 URL 粘到 Secret。
        4. 点 Save provider。AI Monitor 会保存到 Keychain，并启用 slack provider。
        5. 重启 daemon，然后在 Provider Health 里点 Refresh health 检查。
        """,
        enGuide: """
        Slack setup:
        1. Create an Incoming Webhook in Slack app management.
        2. Copy the webhook URL, usually https://hooks.slack.com/services/...
        3. Paste it into Secret.
        4. Click Save provider. AI Monitor stores it in Keychain and enables the slack provider.
        5. Restart the daemon, then click Refresh health in Provider Health.
        """
    ),
    ProviderSetupPreset(
        title: "Telegram",
        providerId: "telegram",
        providerType: "telegram",
        settingKey: "bot_token",
        secretPlaceholder: "123456:ABCDEF...",
        extraSettingKey: "chat_id",
        extraSettingLabel: "Chat ID",
        extraSettingPlaceholder: "123456789",
        zhGuide: """
        Telegram 配置步骤：
        1. 在 Telegram 找 @BotFather，创建 bot，复制 bot token。
        2. 把 bot token 粘到 Secret，把 chat_id 粘到 Chat ID。
        3. 点 Save provider。AI Monitor 会保存 token 到 Keychain，并写入 chat_id。
        4. 重启 daemon，然后在 Provider Health 里点 Refresh health 检查。
        """,
        enGuide: """
        Telegram setup:
        1. In Telegram, open @BotFather, create a bot, and copy the bot token.
        2. Paste the bot token into Secret and paste chat_id into Chat ID.
        3. Click Save provider. AI Monitor stores the token in Keychain and writes chat_id.
        4. Restart the daemon, then click Refresh health in Provider Health.
        """
    ),
    ProviderSetupPreset(
        title: "Discord",
        providerId: "discord",
        providerType: "discord",
        settingKey: "webhook_url",
        secretPlaceholder: "https://discord.com/api/webhooks/...",
        extraSettingKey: nil,
        extraSettingLabel: nil,
        extraSettingPlaceholder: nil,
        zhGuide: """
        Discord 配置步骤：
        1. 在 Discord 频道设置里创建 Webhook。
        2. 复制 webhook URL。
        3. 把 URL 粘到 Secret。
        4. 点 Save provider，重启 daemon，再点 Refresh health。
        """,
        enGuide: """
        Discord setup:
        1. Create a Webhook from the Discord channel settings.
        2. Copy the webhook URL.
        3. Paste it into Secret.
        4. Click Save provider, restart the daemon, then click Refresh health.
        """
    ),
    ProviderSetupPreset(
        title: "ntfy",
        providerId: "ntfy",
        providerType: "ntfy",
        settingKey: "topic_url",
        secretPlaceholder: "https://ntfy.sh/your-topic",
        extraSettingKey: nil,
        extraSettingLabel: nil,
        extraSettingPlaceholder: nil,
        zhGuide: """
        ntfy 配置步骤：
        1. 选一个私有一点的 topic，比如 https://ntfy.sh/my-ai-monitor-xxxxx。
        2. 把完整 topic URL 粘到 Secret。
        3. 点 Save provider，重启 daemon。
        4. 手机安装 ntfy，订阅同一个 topic。
        """,
        enGuide: """
        ntfy setup:
        1. Pick a private-looking topic URL, e.g. https://ntfy.sh/my-ai-monitor-xxxxx.
        2. Paste the full topic URL into Secret.
        3. Click Save provider and restart the daemon.
        4. Install ntfy on your phone and subscribe to the same topic.
        """
    ),
    ProviderSetupPreset(
        title: "Webhook",
        providerId: "webhook",
        providerType: "webhook",
        settingKey: "url",
        secretPlaceholder: "Paste webhook endpoint URL",
        extraSettingKey: nil,
        extraSettingLabel: nil,
        extraSettingPlaceholder: nil,
        zhGuide: """
        Webhook 配置步骤：
        1. 准备一个能接收 POST JSON 的 URL。
        2. 把 URL 粘到 Secret。
        3. 点 Save provider，重启 daemon。
        4. 点 Refresh health 检查。Webhook 会收到 event/task/message。
        """,
        enGuide: """
        Webhook setup:
        1. Prepare a URL that accepts POST JSON.
        2. Paste the URL into Secret.
        3. Click Save provider and restart the daemon.
        4. Click Refresh health. The webhook receives event/task/message.
        """
    ),
]

private final class SettingsPanelController: NSObject {
    private let panel: NSPanel
    private let languagePopup = NSPopUpButton()
    private let daemonURLField = NSTextField(string: appSettings.daemonURLString)
    private let configPathField = NSTextField(string: appSettings.daemonConfigPathString)
    private let apiTokenField = NSSecureTextField(string: appSettings.apiToken ?? "")
    private let browserCheckbox = NSButton(checkboxWithTitle: "Browser tabs", target: nil, action: nil)
    private let terminalCheckbox = NSButton(checkboxWithTitle: "Terminal sessions", target: nil, action: nil)
    private let ideCheckbox = NSButton(checkboxWithTitle: "IDE integrations", target: nil, action: nil)
    private let desktopCheckbox = NSButton(checkboxWithTitle: "Desktop app observer", target: nil, action: nil)
    private let notificationsCheckbox = NSButton(checkboxWithTitle: "Local clickable notifications", target: nil, action: nil)
    private let accessibilityStatus = NSTextField(labelWithString: "")
    private let keychainServiceField = NSTextField(string: "ai-monitor")
    private let providerPresetPopup = NSPopUpButton()
    private let providerTypePopup = NSPopUpButton()
    private let providerGuide = NSTextField(labelWithString: "")
    private let providerIdField = NSTextField(string: "slack")
    private let providerTypeField = NSTextField(string: "slack")
    private let providerSettingField = NSTextField(string: "webhook_url")
    private let providerSecretField = NSSecureTextField(string: "")
    private let providerExtraSettingLabel = NSTextField(labelWithString: "Extra")
    private let providerExtraSettingField = NSTextField(string: "")
    private let providerReferenceField = NSTextField(labelWithString: "keychain://ai-monitor/slack-webhook_url")
    private let ignoreRuleIdField = NSTextField(string: "private-work")
    private let ignoreRuleMode = NSPopUpButton()
    private let ignoreRuleAppField = NSTextField(string: "")
    private let ignoreRuleSourceField = NSTextField(string: "")
    private let ignoreRuleSiteField = NSTextField(string: "")
    private let ignoreRuleWorkspacePrefixField = NSTextField(string: "")
    private let ignoreRuleWorkspaceContainsField = NSTextField(string: "")
    private let ignoredWorkspaces = NSTextView()
    private let providerHealthStack = NSStackView()
    private let status = NSTextField(labelWithString: "")
    private let onSave: () -> Void
    private var keyDownMonitor: Any?
    private var providerExtraSettingRow: NSView?
    private var providerConfigs: [ProviderConfigEntry] = []
    private let newProviderSelection = "__new_provider__"

    init(onSave: @escaping () -> Void) {
        self.onSave = onSave
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.title = "AI Monitor Settings"
        panel.minSize = NSSize(width: 520, height: 420)
        panel.isReleasedWhenClosed = false
        configureLanguagePopup()
        configureProviderPresetPopup()
        configureProviderTypePopup()
        panel.contentView = buildView()
        loadValues()
    }

    deinit {
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
        }
    }

    func show() {
        installKeyDownMonitor()
        loadValues()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installKeyDownMonitor() {
        guard keyDownMonitor == nil else { return }
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event) ?? event
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard panel.isKeyWindow,
              isPasteShortcut(event),
              let pasteTarget = focusedProviderPasteField else {
            return event
        }

        pasteIntoProviderField(pasteTarget.field, statusLabel: pasteTarget.statusLabel)
        return nil
    }

    private func isPasteShortcut(_ event: NSEvent) -> Bool {
        guard event.charactersIgnoringModifiers?.lowercased() == "v" else {
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags.contains(.command) || flags.contains(.control)
    }

    private var focusedProviderPasteField: (field: NSTextField, statusLabel: String)? {
        for candidate in [
            (providerSecretField as NSTextField, "Secret"),
            (providerExtraSettingField as NSTextField, providerExtraSettingLabel.stringValue),
        ] {
            if panel.firstResponder === candidate.0 {
                return (candidate.0, candidate.1)
            }
            if let editor = candidate.0.currentEditor(),
               panel.firstResponder === editor {
                return (candidate.0, candidate.1)
            }
        }
        return nil
    }

    private func loadValues() {
        languagePopup.selectItem(at: appSettings.settingsLanguage == "en" ? 1 : 0)
        daemonURLField.stringValue = appSettings.daemonURLString
        configPathField.stringValue = appSettings.daemonConfigPathString
        apiTokenField.stringValue = appSettings.apiToken ?? ""
        browserCheckbox.state = appSettings.observeBrowser ? .on : .off
        terminalCheckbox.state = appSettings.observeTerminal ? .on : .off
        ideCheckbox.state = appSettings.observeIDE ? .on : .off
        desktopCheckbox.state = appSettings.observeDesktop ? .on : .off
        notificationsCheckbox.state = appSettings.localNotifications ? .on : .off
        ignoredWorkspaces.string = appSettings.ignoredWorkspacePrefixesText
        updateAccessibilityStatus()
        reloadProviderList()
        refreshProviderHealth()
    }

    private func buildView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        stack.addArrangedSubview(settingsLabel("General / 通用"))
        stack.addArrangedSubview(labeledControl("Language / 语言", languagePopup))

        stack.addArrangedSubview(settingsLabel("Daemon"))
        stack.addArrangedSubview(labeledControl("URL", daemonURLField))
        stack.addArrangedSubview(labeledControl("Config", configPathField))
        stack.addArrangedSubview(labeledControl("API token", apiTokenField))

        let daemonActions = NSStackView()
        daemonActions.orientation = .horizontal
        daemonActions.spacing = 8
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        let startButton = NSButton(title: "Start daemon", target: self, action: #selector(startDaemon))
        let testConnectionButton = NSButton(title: "Test connection", target: self, action: #selector(testDaemonConnection))
        let copyTokenButton = NSButton(title: "Copy API token", target: self, action: #selector(copyAPIToken))
        daemonActions.addArrangedSubview(saveButton)
        daemonActions.addArrangedSubview(startButton)
        daemonActions.addArrangedSubview(testConnectionButton)
        daemonActions.addArrangedSubview(copyTokenButton)
        stack.addArrangedSubview(daemonActions)

        let browserActions = NSStackView()
        browserActions.orientation = .horizontal
        browserActions.spacing = 8
        let openBrowserExtensionInstallLinkButton = NSButton(title: "Open browser install link", target: self, action: #selector(openBrowserExtensionInstallLink))
        let copyBrowserExtensionInstallLinkButton = NSButton(title: "Copy browser install link", target: self, action: #selector(copyBrowserExtensionInstallLink))
        browserActions.addArrangedSubview(openBrowserExtensionInstallLinkButton)
        browserActions.addArrangedSubview(copyBrowserExtensionInstallLinkButton)
        stack.addArrangedSubview(browserActions)

        let launchAgentActions = NSStackView()
        launchAgentActions.orientation = .horizontal
        launchAgentActions.spacing = 8
        let installLaunchAgentButton = NSButton(title: "Install login daemon", target: self, action: #selector(installDaemonLaunchAgent))
        let removeLaunchAgentButton = NSButton(title: "Remove login daemon", target: self, action: #selector(removeDaemonLaunchAgent))
        let statusLaunchAgentButton = NSButton(title: "Daemon login status", target: self, action: #selector(showDaemonLaunchAgentStatus))
        launchAgentActions.addArrangedSubview(installLaunchAgentButton)
        launchAgentActions.addArrangedSubview(removeLaunchAgentButton)
        launchAgentActions.addArrangedSubview(statusLaunchAgentButton)
        stack.addArrangedSubview(launchAgentActions)

        let supportActions = NSStackView()
        supportActions.orientation = .horizontal
        supportActions.spacing = 8
        let openLogsButton = NSButton(title: "Open logs", target: self, action: #selector(openLogsFolder))
        let openDataButton = NSButton(title: "Open data folder", target: self, action: #selector(openDataFolder))
        supportActions.addArrangedSubview(openLogsButton)
        supportActions.addArrangedSubview(openDataButton)
        stack.addArrangedSubview(supportActions)
        let copySupportActions = NSStackView()
        copySupportActions.orientation = .horizontal
        copySupportActions.spacing = 8
        let copyDiagnosticsButton = NSButton(title: "Copy diagnostics", target: self, action: #selector(copyDiagnostics))
        let copySetupGuideButton = NSButton(title: "Copy setup guide", target: self, action: #selector(copySetupGuide))
        let copyTroubleshootingButton = NSButton(title: "Copy troubleshooting guide", target: self, action: #selector(copyTroubleshootingGuide))
        let copyLicenseButton = NSButton(title: "Copy license notices", target: self, action: #selector(copyLicenseNotices))
        let copyPrivacyButton = NSButton(title: "Copy privacy notice", target: self, action: #selector(copyPrivacyNotice))
        copySupportActions.addArrangedSubview(copyDiagnosticsButton)
        copySupportActions.addArrangedSubview(copySetupGuideButton)
        copySupportActions.addArrangedSubview(copyTroubleshootingButton)
        stack.addArrangedSubview(copySupportActions)
        let cleanupActions = NSStackView()
        cleanupActions.orientation = .horizontal
        cleanupActions.spacing = 8
        let copyUninstallButton = NSButton(title: "Copy uninstall guide", target: self, action: #selector(copyUninstallGuide))
        cleanupActions.addArrangedSubview(copyLicenseButton)
        cleanupActions.addArrangedSubview(copyPrivacyButton)
        cleanupActions.addArrangedSubview(copyUninstallButton)
        stack.addArrangedSubview(cleanupActions)

        stack.addArrangedSubview(settingsLabel("Notification Setup / 通知设置"))
        stack.addArrangedSubview(labeledControl("Provider list", providerPresetPopup))
        stack.addArrangedSubview(labeledControl("Type", providerTypePopup))
        stack.addArrangedSubview(labeledControl("Provider ID", providerIdField))
        providerGuide.font = .systemFont(ofSize: 11)
        providerGuide.textColor = .secondaryLabelColor
        providerGuide.lineBreakMode = .byWordWrapping
        providerGuide.maximumNumberOfLines = 0
        providerGuide.isSelectable = true
        providerGuide.widthAnchor.constraint(greaterThanOrEqualToConstant: 460).isActive = true
        stack.addArrangedSubview(providerGuide)

        stack.addArrangedSubview(settingsLabel("Provider Credentials"))
        stack.addArrangedSubview(labeledControl("Secret", providerSecretField))
        providerExtraSettingRow = labeledControl(providerExtraSettingLabel, providerExtraSettingField)
        if let providerExtraSettingRow {
            stack.addArrangedSubview(providerExtraSettingRow)
        }
        let secretActions = NSStackView()
        secretActions.orientation = .horizontal
        secretActions.spacing = 8
        let pasteSecretButton = NSButton(title: "Paste secret", target: self, action: #selector(pasteProviderSecret))
        let saveSecretButton = NSButton(title: "Save provider", target: self, action: #selector(saveProviderSecret))
        secretActions.addArrangedSubview(pasteSecretButton)
        secretActions.addArrangedSubview(saveSecretButton)
        stack.addArrangedSubview(secretActions)

        stack.addArrangedSubview(settingsLabel("Provider Health"))
        let refreshHealthButton = NSButton(title: "Refresh health", target: self, action: #selector(refreshProviderHealth))
        stack.addArrangedSubview(refreshHealthButton)
        providerHealthStack.orientation = .vertical
        providerHealthStack.alignment = .leading
        providerHealthStack.spacing = 8
        stack.addArrangedSubview(providerHealthStack)

        stack.addArrangedSubview(settingsLabel("Observe Sources"))
        for checkbox in [browserCheckbox, terminalCheckbox, ideCheckbox, desktopCheckbox, notificationsCheckbox] {
            checkbox.target = self
            checkbox.action = #selector(save)
            stack.addArrangedSubview(checkbox)
        }
        let accessibilityActions = NSStackView()
        accessibilityActions.orientation = .horizontal
        accessibilityActions.spacing = 8
        accessibilityStatus.textColor = .secondaryLabelColor
        let requestAccessibilityButton = NSButton(title: "Request Accessibility", target: self, action: #selector(requestAccessibilityAccess))
        accessibilityActions.addArrangedSubview(requestAccessibilityButton)
        accessibilityActions.addArrangedSubview(accessibilityStatus)
        stack.addArrangedSubview(accessibilityActions)

        stack.addArrangedSubview(settingsLabel("Daemon Ignore Rule"))
        ignoreRuleMode.addItems(withTitles: ["ignore", "local_only"])
        stack.addArrangedSubview(labeledControl("Rule id", ignoreRuleIdField))
        stack.addArrangedSubview(labeledControl("Mode", ignoreRuleMode))
        stack.addArrangedSubview(labeledControl("App", ignoreRuleAppField))
        stack.addArrangedSubview(labeledControl("Source", ignoreRuleSourceField))
        stack.addArrangedSubview(labeledControl("Site", ignoreRuleSiteField))
        stack.addArrangedSubview(labeledControl("Workspace", ignoreRuleWorkspacePrefixField))
        stack.addArrangedSubview(labeledControl("Contains", ignoreRuleWorkspaceContainsField))
        let ignoreActions = NSStackView()
        ignoreActions.orientation = .horizontal
        ignoreActions.spacing = 8
        let saveIgnoreRuleButton = NSButton(title: "Save daemon ignore rule", target: self, action: #selector(saveDaemonIgnoreRule))
        ignoreActions.addArrangedSubview(saveIgnoreRuleButton)
        stack.addArrangedSubview(ignoreActions)

        stack.addArrangedSubview(settingsLabel("Ignored Workspaces"))
        ignoredWorkspaces.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        ignoredWorkspaces.string = appSettings.ignoredWorkspacePrefixesText
        let ignoredScroll = NSScrollView()
        ignoredScroll.hasVerticalScroller = true
        ignoredScroll.borderType = .bezelBorder
        ignoredScroll.documentView = ignoredWorkspaces
        ignoredScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            ignoredScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 460),
            ignoredScroll.heightAnchor.constraint(equalToConstant: 120),
        ])
        stack.addArrangedSubview(ignoredScroll)

        status.textColor = .secondaryLabelColor
        stack.addArrangedSubview(status)

        return scrollableDetailContent(stack)
    }

    private func configureLanguagePopup() {
        languagePopup.removeAllItems()
        languagePopup.addItems(withTitles: ["中文", "English"])
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
    }

    private func configureProviderPresetPopup() {
        providerPresetPopup.removeAllItems()
        providerPresetPopup.target = self
        providerPresetPopup.action = #selector(providerPresetChanged)
    }

    private func configureProviderTypePopup() {
        providerTypePopup.removeAllItems()
        for preset in providerSetupPresets {
            providerTypePopup.addItem(withTitle: preset.title)
            providerTypePopup.lastItem?.representedObject = preset.providerType
        }
        providerTypePopup.target = self
        providerTypePopup.action = #selector(providerTypeChanged)
        providerTypePopup.selectItem(at: 0)
    }

    private var selectedProviderPreset: ProviderSetupPreset {
        let type = selectedProviderType
        return providerSetupPreset(for: type) ?? providerSetupPresets[0]
    }

    private var selectedProviderType: String {
        providerTypePopup.selectedItem?.representedObject as? String ?? providerSetupPresets[0].providerType
    }

    private var selectedProviderConfig: ProviderConfigEntry? {
        guard let id = providerPresetPopup.selectedItem?.representedObject as? String,
              id != newProviderSelection else {
            return nil
        }
        return providerConfigs.first { $0.id == id }
    }

    private func providerSetupPreset(for type: String) -> ProviderSetupPreset? {
        providerSetupPresets.first { $0.providerType == type || $0.title == type }
    }

    private func selectProviderType(_ type: String) {
        for item in providerTypePopup.itemArray where item.representedObject as? String == type {
            providerTypePopup.select(item)
            return
        }
    }

    private func applySelectedProviderPreset() {
        let preset = selectedProviderPreset
        let selectedConfig = selectedProviderConfig
        if let selectedConfig {
            providerIdField.stringValue = selectedConfig.id
        } else if providerIdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    providerConfigs.contains(where: { $0.id == providerIdField.stringValue }) {
            providerIdField.stringValue = defaultProviderId(for: preset)
        }
        providerTypeField.stringValue = preset.providerType
        providerSettingField.stringValue = preset.settingKey
        providerSecretField.stringValue = ""
        let hasExistingSecret = selectedConfig?.settings[preset.settingKey].flatMap(usableExistingSecretReference) != nil
        providerSecretField.placeholderString = !hasExistingSecret
            ? preset.secretPlaceholder
            : "Leave blank to keep existing secret"
        providerReferenceField.stringValue = currentProviderKeychainReference()
        if let key = preset.extraSettingKey {
            providerExtraSettingLabel.stringValue = preset.extraSettingLabel ?? key
            providerExtraSettingField.placeholderString = preset.extraSettingPlaceholder ?? ""
            providerExtraSettingField.stringValue = selectedConfig?.settings[key].flatMap(nonPlaceholderConfigValue) ?? ""
            providerExtraSettingRow?.isHidden = false
        } else {
            providerExtraSettingField.stringValue = ""
            providerExtraSettingRow?.isHidden = true
        }
        updateProviderGuide()
    }

    private func reloadProviderList(selecting selectedId: String? = nil) {
        let currentId = selectedId ?? providerPresetPopup.selectedItem?.representedObject as? String
        providerConfigs = (try? providerConfigEntries(configURL: appSettings.daemonConfigURL))?
            .filter { $0.type != "desktop" } ?? []

        providerPresetPopup.removeAllItems()
        for provider in providerConfigs {
            let enabledLabel = provider.enabled ? "" : " disabled"
            providerPresetPopup.addItem(withTitle: "\(provider.id) (\(provider.type)\(enabledLabel))")
            providerPresetPopup.lastItem?.representedObject = provider.id
        }
        providerPresetPopup.addItem(withTitle: "New provider...")
        providerPresetPopup.lastItem?.representedObject = newProviderSelection

        if let currentId,
           let item = providerPresetPopup.itemArray.first(where: { $0.representedObject as? String == currentId }) {
            providerPresetPopup.select(item)
        } else if providerConfigs.isEmpty {
            providerPresetPopup.select(providerPresetPopup.lastItem)
        } else {
            providerPresetPopup.selectItem(at: 0)
        }

        applyProviderSelection()
    }

    private func applyProviderSelection() {
        if let selectedProviderConfig {
            selectProviderType(selectedProviderConfig.type)
        } else if providerTypePopup.indexOfSelectedItem < 0 {
            providerTypePopup.selectItem(at: 0)
        }
        applySelectedProviderPreset()
    }

    private func defaultProviderId(for preset: ProviderSetupPreset) -> String {
        if !providerConfigs.contains(where: { $0.id == preset.providerId }) {
            return preset.providerId
        }
        for index in 2...99 {
            let candidate = "\(preset.providerId)-\(index)"
            if !providerConfigs.contains(where: { $0.id == candidate }) {
                return candidate
            }
        }
        return "\(preset.providerId)-new"
    }

    private func nonPlaceholderConfigValue(_ value: String) -> String? {
        value.hasPrefix("${") ? nil : value
    }

    private func updateProviderGuide() {
        let preset = selectedProviderPreset
        providerGuide.stringValue = appSettings.settingsLanguage == "en" ? preset.enGuide : preset.zhGuide
    }

    private func labeledControl(_ label: String, _ control: NSControl) -> NSView {
        let title = NSTextField(labelWithString: label)
        return labeledControl(title, control)
    }

    private func labeledControl(_ title: NSTextField, _ control: NSControl) -> NSView {
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.widthAnchor.constraint(equalToConstant: 82).isActive = true
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        let row = NSStackView(views: [title, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func settingsLabel(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    @objc private func languageChanged() {
        appSettings.settingsLanguage = languagePopup.indexOfSelectedItem == 1 ? "en" : "zh"
        updateProviderGuide()
        status.stringValue = appSettings.settingsLanguage == "en" ? "Language saved" : "语言已保存"
    }

    @objc private func providerPresetChanged() {
        applyProviderSelection()
        status.stringValue = appSettings.settingsLanguage == "en" ? "Provider selected" : "已选择通知渠道"
    }

    @objc private func providerTypeChanged() {
        if selectedProviderConfig == nil {
            providerIdField.stringValue = defaultProviderId(for: selectedProviderPreset)
        }
        applySelectedProviderPreset()
        status.stringValue = appSettings.settingsLanguage == "en" ? "Provider type updated" : "已切换通知渠道类型"
    }

    @objc private func save() {
        appSettings.settingsLanguage = languagePopup.indexOfSelectedItem == 1 ? "en" : "zh"
        appSettings.daemonURLString = daemonURLField.stringValue
        daemonURLField.stringValue = appSettings.daemonURLString
        appSettings.daemonConfigPathString = configPathField.stringValue
        appSettings.apiToken = apiTokenField.stringValue
        appSettings.observeBrowser = browserCheckbox.state == .on
        appSettings.observeTerminal = terminalCheckbox.state == .on
        appSettings.observeIDE = ideCheckbox.state == .on
        appSettings.observeDesktop = desktopCheckbox.state == .on
        appSettings.localNotifications = notificationsCheckbox.state == .on
        appSettings.ignoredWorkspacePrefixesText = ignoredWorkspaces.string
        updateAccessibilityStatus()
        status.stringValue = "Saved"
        onSave()
    }

    @objc private func requestAccessibilityAccess() {
        let granted = requestAccessibilityPermissionPrompt()
        updateAccessibilityStatus()
        status.stringValue = granted
            ? "Accessibility permission granted"
            : "Allow AI Monitor in System Settings -> Privacy & Security -> Accessibility"
    }

    private func updateAccessibilityStatus() {
        if accessibilityPermissionGranted() {
            accessibilityStatus.stringValue = "Accessibility: allowed"
        } else if desktopCheckbox.state == .on {
            accessibilityStatus.stringValue = "Accessibility: required for Desktop app observer"
        } else {
            accessibilityStatus.stringValue = "Accessibility: optional"
        }
    }

    @objc private func startDaemon() {
        save()
        do {
            status.stringValue = try launchDaemonFromSettings()
        } catch {
            status.stringValue = "Daemon launch failed: \(error.localizedDescription)"
        }
    }

    @objc private func testDaemonConnection() {
        save()
        status.stringValue = "Checking daemon..."
        let url = appSettings.daemonURL.appendingPathComponent("tasks")
        URLSession.shared.dataTask(with: authorizedRequest(url: url)) { [weak self] data, response, error in
            let message: String
            if let error {
                message = "Daemon offline: \(error.localizedDescription)"
            } else if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                message = "Daemon auth failed: check API token"
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                message = "Daemon returned HTTP \(http.statusCode)"
            } else if let data,
                      let tasks = try? JSONDecoder().decode([AgentTask].self, from: data) {
                message = "Daemon online: \(tasks.count) active task\(tasks.count == 1 ? "" : "s")"
            } else {
                message = "Daemon online"
            }

            DispatchQueue.main.async {
                self?.status.stringValue = message
            }
        }.resume()
    }

    @objc private func copyAPIToken() {
        do {
            let existingToken = apiTokenField.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
            let token: String
            if let existingToken {
                token = existingToken
            } else {
                token = try loadOrCreateAPITokenForSettings()
            }
            copyToPasteboard(token)
            apiTokenField.stringValue = token
            appSettings.apiToken = token
            status.stringValue = "Copied API token"
        } catch {
            status.stringValue = "API token failed: \(error.localizedDescription)"
        }
    }

    private func loadOrCreateAPITokenForSettings() throws -> String {
        if let token = loadAPITokenFromEnvironmentOrFile() {
            return token
        }

        let token = UUID().uuidString.lowercased()
        try writeAPITokenToDefaultFile(token)
        return token
    }

    @objc private func installDaemonLaunchAgent() {
        save()
        runLaunchAgentAction("install", success: "Installed daemon login item")
    }

    @objc private func removeDaemonLaunchAgent() {
        save()
        runLaunchAgentAction("uninstall", success: "Removed daemon login item")
    }

    @objc private func showDaemonLaunchAgentStatus() {
        save()
        runLaunchAgentAction("status", success: "Daemon login item is installed")
    }

    @objc private func openLogsFolder() {
        do {
            let url = try launchAgentLogDirectory()
            NSWorkspace.shared.open(url)
            status.stringValue = "Opened logs folder"
        } catch {
            status.stringValue = "Open logs failed: \(error.localizedDescription)"
        }
    }

    @objc private func openDataFolder() {
        do {
            let url = try ensureApplicationSupportDirectory()
            NSWorkspace.shared.open(url)
            status.stringValue = "Opened data folder"
        } catch {
            status.stringValue = "Open data failed: \(error.localizedDescription)"
        }
    }

    @objc private func copyDiagnostics() {
        copyToPasteboard(diagnosticsText())
        status.stringValue = "Copied diagnostics"
    }

    @objc private func copySetupGuide() {
        save()
        copyToPasteboard(setupGuideText())
        status.stringValue = "Copied setup guide"
    }

    @objc private func copyBrowserExtensionInstallLink() {
        if let installURL = bundledBrowserExtensionInstallURL() {
            copyToPasteboard(installURL)
            status.stringValue = "Copied browser install link"
        } else {
            status.stringValue = "Browser install link is not configured in this build"
        }
    }

    @objc private func openBrowserExtensionInstallLink() {
        guard let installURL = bundledBrowserExtensionInstallURL(),
              let url = URL(string: installURL) else {
            status.stringValue = "Browser install link is not configured in this build"
            return
        }

        NSWorkspace.shared.open(url)
        status.stringValue = "Opened browser install link"
    }

    @objc private func copyTroubleshootingGuide() {
        copyToPasteboard(bundledTroubleshootingGuideText())
        status.stringValue = "Copied troubleshooting guide"
    }

    @objc private func copyLicenseNotices() {
        copyToPasteboard(bundledLicenseNoticesText())
        status.stringValue = "Copied license notices"
    }

    @objc private func copyPrivacyNotice() {
        copyToPasteboard(bundledPrivacyNoticeText())
        status.stringValue = "Copied privacy notice"
    }

    @objc private func copyUninstallGuide() {
        copyToPasteboard(bundledUninstallGuideText())
        status.stringValue = "Copied uninstall guide"
    }

    @objc private func pasteProviderSecret() {
        pasteIntoProviderField(providerSecretField, statusLabel: "Secret")
    }

    private func pasteIntoProviderField(_ field: NSTextField, statusLabel: String) {
        guard let secret = pasteboardString() else {
            status.stringValue = "Clipboard has no text"
            return
        }

        if let editor = field.currentEditor() {
            editor.string = secret
        } else {
            field.stringValue = secret
        }
        panel.makeFirstResponder(field)
        status.stringValue = "Pasted into \(statusLabel)"
    }

    @objc private func refreshProviderHealth() {
        guard !providerConfigs.isEmpty else {
            renderProviderHealthMessage("No external providers configured")
            return
        }

        renderProviderHealthMessage("Loading provider health...")
        let url = appSettings.daemonURL.appendingPathComponent("notifications").appendingPathComponent("providers")
        URLSession.shared.dataTask(with: authorizedRequest(url: url)) { [weak self] data, response, error in
            if let error {
                DispatchQueue.main.async {
                    self?.renderProviderHealthMessage("Provider health failed: \(error.localizedDescription)")
                }
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                DispatchQueue.main.async {
                    self?.renderProviderHealthMessage("Daemon auth failed")
                }
                return
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let body = data.flatMap { String(data: $0, encoding: .utf8) }?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = body?.isEmpty == false ? ": \(body!)" : ""
                DispatchQueue.main.async {
                    self?.renderProviderHealthMessage(
                        "Provider health unavailable: HTTP \(http.statusCode)\(detail). Restart daemon to load the current build."
                    )
                }
                return
            }
            guard let data else { return }
            do {
                let providers = try JSONDecoder().decode([ProviderHealth].self, from: data)
                DispatchQueue.main.async {
                    self?.renderProviderHealth(providers)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.renderProviderHealthMessage("Provider health decode failed: \(error.localizedDescription)")
                }
            }
        }.resume()
    }

    private func renderProviderHealth(_ providers: [ProviderHealth]) {
        clearProviderHealthRows()
        let healthById = Dictionary(uniqueKeysWithValues: providers.map { ($0.providerId, $0) })
        var renderedIds = Set<String>()

        for provider in providerConfigs {
            if let health = healthById[provider.id] {
                providerHealthStack.addArrangedSubview(providerHealthRow(health))
                renderedIds.insert(provider.id)
            } else {
                let status = provider.enabled ? "pending" : "disabled"
                let message = provider.enabled
                    ? "saved in Settings; restart daemon to load this provider"
                    : "provider is disabled"
                providerHealthStack.addArrangedSubview(providerHealthRow(ProviderHealth(
                    providerId: provider.id,
                    providerType: provider.type,
                    status: status,
                    message: message
                )))
                renderedIds.insert(provider.id)
            }
        }

        for provider in providers where provider.providerType != "desktop" && !renderedIds.contains(provider.providerId) {
            providerHealthStack.addArrangedSubview(providerHealthRow(provider))
        }

        if providerHealthStack.arrangedSubviews.isEmpty {
            providerHealthStack.addArrangedSubview(detailLine("No external providers configured"))
        }
    }

    private func renderProviderHealthMessage(_ message: String) {
        clearProviderHealthRows()
        providerHealthStack.addArrangedSubview(detailLine(message))
    }

    private func clearProviderHealthRows() {
        for view in providerHealthStack.arrangedSubviews {
            providerHealthStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    @objc private func saveProviderSecret() {
        save()
        do {
            let providerSecret = try currentProviderSecretReference()
            let settings = try currentProviderExtraSettings()
            if let secret = providerSecret.secretToSave {
                try saveGenericPasswordToKeychain(
                    service: currentKeychainService(),
                    account: currentProviderSecretAccount(),
                    secret: secret
                )
            }
            try upsertProviderSecretReference(
                configURL: appSettings.daemonConfigURL,
                providerId: providerIdField.stringValue,
                providerType: providerTypeField.stringValue,
                settingKey: providerSettingField.stringValue,
                reference: providerSecret.reference,
                settings: settings
            )
            let savedId = providerIdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            providerSecretField.stringValue = ""
            providerReferenceField.stringValue = providerSecret.reference
            reloadProviderList(selecting: savedId)
            refreshProviderHealth()
            status.stringValue = "Saved provider settings"
        } catch {
            status.stringValue = "Provider save failed: \(error.localizedDescription)"
        }
    }

    @objc private func saveDaemonIgnoreRule() {
        save()
        do {
            try upsertIgnoreRule(
                configURL: appSettings.daemonConfigURL,
                ruleId: ignoreRuleIdField.stringValue,
                mode: ignoreRuleMode.titleOfSelectedItem ?? "ignore",
                app: ignoreRuleAppField.stringValue,
                source: ignoreRuleSourceField.stringValue,
                siteContains: ignoreRuleSiteField.stringValue,
                workspacePrefix: ignoreRuleWorkspacePrefixField.stringValue,
                workspaceContains: ignoreRuleWorkspaceContainsField.stringValue
            )
            status.stringValue = "Saved daemon ignore rule"
        } catch {
            status.stringValue = "Ignore rule save failed: \(error.localizedDescription)"
        }
    }

    private func currentKeychainService() -> String {
        keychainServiceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func currentProviderSecretAccount() -> String {
        providerSecretAccount(
            providerId: providerIdField.stringValue,
            settingKey: providerSettingField.stringValue
        )
    }

    private func currentProviderKeychainReference() -> String {
        keychainReference(service: currentKeychainService(), account: currentProviderSecretAccount())
    }

    private func currentProviderSecretReference() throws -> (reference: String, secretToSave: String?) {
        let secret = providerSecretField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if secret.isEmpty {
            if let existingValue = selectedProviderConfig?.settings[providerSettingField.stringValue],
               let preservedValue = usableExistingSecretReference(existingValue) {
                return (preservedValue, nil)
            }
            throw ConfigEditError(message: "Secret is required")
        }
        guard !secret.hasPrefix("keychain://") else {
            throw ConfigEditError(message: "Paste the actual token or URL, not keychain:// reference")
        }
        return (currentProviderKeychainReference(), secret)
    }

    private func currentProviderExtraSettings() throws -> [String: String] {
        let preset = selectedProviderPreset
        guard let key = preset.extraSettingKey else {
            return [:]
        }

        let value = providerExtraSettingField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw ConfigEditError(message: "\(preset.extraSettingLabel ?? key) is required")
        }
        return [key: value]
    }

    private func runLaunchAgentAction(_ action: String, success: String) {
        status.stringValue = "Running \(action)..."
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let output = try runLaunchAgentCommand(action)
                DispatchQueue.main.async {
                    self.status.stringValue = output.nilIfEmpty ?? success
                }
            } catch {
                DispatchQueue.main.async {
                    self.status.stringValue = "\(action) failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func setupGuideText() -> String {
        let tokenConfigured = apiTokenField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty != nil || loadAPITokenFromEnvironmentOrFile() != nil
        let launchAgentInstalled = FileManager.default.fileExists(atPath: launchAgentPlistURL().path)
        let guide = bundledFirstRunGuideText()

        return """
\(guide)

Current app settings

- Daemon URL: \(appSettings.daemonURLString)
- Config file: \(appSettings.daemonConfigURL.path)
- API token file: \(defaultAPITokenFileURL().path)
- API token configured: \(tokenConfigured ? "yes" : "no")
- Login daemon label: \(launchAgentLabel)
- Login daemon installed: \(launchAgentInstalled ? "yes" : "no")
- Browser tabs: \(appSettings.observeBrowser ? "enabled" : "disabled")
- Terminal sessions: \(appSettings.observeTerminal ? "enabled" : "disabled")
- IDE integrations: \(appSettings.observeIDE ? "enabled" : "disabled")
- Desktop app observer: \(appSettings.observeDesktop ? "enabled" : "disabled")
- Accessibility trusted: \(accessibilityPermissionGranted() ? "yes" : "no")

This setup guide intentionally excludes provider secrets and the API token.
"""
    }

    private func diagnosticsText() -> String {
        save()
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "unknown"
        let minimumMacOSVersion = Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String
        let operatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let apiTokenFileURL = defaultAPITokenFileURL()
        let apiTokenFileExists = FileManager.default.fileExists(atPath: apiTokenFileURL.path)
        let apiTokenFilePermissions = filePOSIXPermissionsOctal(at: apiTokenFileURL)
        let apiTokenConfigured = appSettings.apiToken != nil
        let browserExtensionInstallURLConfigured = bundledBrowserExtensionInstallURL() != nil
        let launchAgentStatus = launchAgentStatusSnapshot()
        let providerSummary = providerConfigs.isEmpty
            ? "none"
            : providerConfigs
                .map { "\($0.id) (\($0.type)) enabled=\($0.enabled)" }
                .joined(separator: ", ")

        return """
AI Monitor diagnostics
generated_at: \(ISO8601DateFormatter().string(from: Date()))
app_version: \(appVersion ?? "unknown")
build_version: \(buildVersion ?? "unknown")
bundle_identifier: \(bundleIdentifier)
minimum_macos_version: \(minimumMacOSVersion ?? "unknown")
operating_system: \(operatingSystemVersion)
daemon_url: \(appSettings.daemonURLString)
config_path: \(appSettings.daemonConfigURL.path)
database_path: \((try? daemonDatabaseURL().path) ?? "unavailable")
application_support: \((try? ensureApplicationSupportDirectory().path) ?? "unavailable")
logs: \((try? launchAgentLogDirectory().path) ?? "unavailable")
stdout_log: \((try? daemonStdoutLogURL().path) ?? "unavailable")
stderr_log: \((try? daemonStderrLogURL().path) ?? "unavailable")
app_bundle_path: \(Bundle.main.bundleURL.standardizedFileURL.path)
running_from_transient_location: \(appIsRunningFromTransientLocation())
launch_agent_label: \(launchAgentLabel)
launch_agent_plist: \(launchAgentPlistURL().path)
launch_agent_installed: \(launchAgentStatus.plistExists)
launch_agent_loaded: \(launchAgentStatus.loaded)
launch_agent_running: \(launchAgentStatus.running)
launch_agent_pid: \(launchAgentStatus.pid ?? "none")
launch_agent_state: \(launchAgentStatus.state ?? "unknown")
launch_agent_status: \(launchAgentStatus.message)
daemon_executable: \(daemonExecutableURL()?.path ?? "not found")
api_token_file: \(apiTokenFileURL.path)
api_token_file_exists: \(apiTokenFileExists)
api_token_file_permissions_octal: \(apiTokenFilePermissions)
api_token_configured: \(apiTokenConfigured)
browser_extension_install_url_configured: \(browserExtensionInstallURLConfigured)
observe_browser: \(appSettings.observeBrowser)
observe_terminal: \(appSettings.observeTerminal)
observe_ide: \(appSettings.observeIDE)
observe_desktop: \(appSettings.observeDesktop)
local_notifications: \(appSettings.localNotifications)
accessibility_trusted: \(accessibilityPermissionGranted())
provider_configs: \(providerSummary)
"""
    }
}

private func launchDaemonFromSettings() throws -> String {
    if launchedDaemonProcess?.isRunning == true {
        return "Daemon already started by AI Monitor"
    }
    launchedDaemonProcess = nil

    let launchAgentStatus = launchAgentStatusSnapshot()
    if launchAgentStatus.running {
        return launchAgentStatus.message
    }

    try validateDaemonLaunchLocation()
    try persistConfiguredAPITokenToDefaultFile()
    let command = try daemonLaunchCommand()
    let stdoutLog = try FileHandle(forWritingTo: daemonStdoutLogURL())
    let stderrLog = try FileHandle(forWritingTo: daemonStderrLogURL())
    try stdoutLog.seekToEnd()
    try stderrLog.seekToEnd()

    let process = Process()
    process.currentDirectoryURL = command.workingDirectory
    process.executableURL = URL(fileURLWithPath: command.arguments[0])
    process.arguments = Array(command.arguments.dropFirst())
    process.standardOutput = stdoutLog
    process.standardError = stderrLog
    try process.run()
    launchedDaemonProcess = process
    return "Daemon starting"
}

private func defaultAPITokenFileURL() -> URL {
    if let value = ProcessInfo.processInfo.environment["AI_MONITOR_API_TOKEN_FILE"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nilIfEmpty {
        return URL(fileURLWithPath: value)
    }
    return URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".ai-monitor", isDirectory: true)
        .appendingPathComponent("api-token")
}

private func filePOSIXPermissionsOctal(at url: URL) -> String {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          let permissions = attributes[.posixPermissions] as? NSNumber else {
        return "unavailable"
    }

    return String(format: "%03o", permissions.intValue & 0o777)
}

private func persistConfiguredAPITokenToDefaultFile() throws {
    guard let token = appSettings.apiToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
        return
    }
    try writeAPITokenToDefaultFile(token)
}

private func writeAPITokenToDefaultFile(_ token: String) throws {
    let tokenURL = defaultAPITokenFileURL()
    let tokenDirectory = tokenURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
        at: tokenDirectory,
        withIntermediateDirectories: true
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o700))],
        ofItemAtPath: tokenDirectory.path
    )
    if (try? FileManager.default.destinationOfSymbolicLink(atPath: tokenURL.path)) != nil {
        throw ConfigEditError(message: "API token file must not be a symbolic link")
    }
    if !FileManager.default.fileExists(atPath: tokenURL.path) {
        FileManager.default.createFile(
            atPath: tokenURL.path,
            contents: nil,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
        )
    }
    let handle = try FileHandle(forWritingTo: tokenURL)
    try handle.truncate(atOffset: 0)
    if let data = "\(token)\n".data(using: .utf8) {
        try handle.write(contentsOf: data)
    }
    try handle.close()
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))],
        ofItemAtPath: tokenURL.path
    )
}

private func daemonBindAddress() -> String {
    let url = appSettings.daemonURL
    let host = url.host ?? "127.0.0.1"
    let port = url.port ?? 4318
    return "\(host):\(port)"
}

private func defaultDaemonConfigURL() -> URL {
    let url = applicationSupportURL()
        .appendingPathComponent("config", isDirectory: true)
        .appendingPathComponent("default.toml")
    ensureDefaultDaemonConfig(at: url)
    return url
}

private func bundledFirstRunGuideText() -> String {
    if let url = Bundle.main.url(forResource: "first-run-guide", withExtension: "txt"),
       let text = try? String(contentsOf: url, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
       !text.isEmpty {
        return text
    }
    return fallbackFirstRunGuide
}

private func bundledBrowserExtensionInstallURL() -> String? {
    guard let url = Bundle.main.url(forResource: "browser-extension-install-url", withExtension: "txt"),
          let text = try? String(contentsOf: url, encoding: .utf8) else {
        return nil
    }

    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.range(of: #"^https://\S+$"#, options: .regularExpression) != nil else {
        return nil
    }
    return value
}

private func bundledPrivacyNoticeText() -> String {
    if let url = Bundle.main.url(forResource: "privacy-notice", withExtension: "txt"),
       let text = try? String(contentsOf: url, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
       !text.isEmpty {
        return text
    }

    return """
AI Monitor privacy notice

AI Monitor is local-first by default. External notification providers are not configured or enabled until you add them. The Desktop app observer is disabled until you enable it. Diagnostics and setup guides do not include provider secrets or the local API token.
"""
}

private func bundledLicenseNoticesText() -> String {
    let licenseText = bundledTextResource(named: "LICENSE") ?? fallbackLicenseText
    let noticesText = bundledTextResource(named: "THIRD-PARTY-NOTICES") ?? fallbackThirdPartyNoticesText
    return "\(licenseText)\n\n---\n\n\(noticesText)"
}

private func bundledTroubleshootingGuideText() -> String {
    if let url = Bundle.main.url(forResource: "troubleshooting-guide", withExtension: "txt"),
       let text = try? String(contentsOf: url, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
       !text.isEmpty {
        return text
    }
    return fallbackTroubleshootingGuide
}

private func bundledUninstallGuideText() -> String {
    if let url = Bundle.main.url(forResource: "uninstall-guide", withExtension: "txt"),
       let text = try? String(contentsOf: url, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
       !text.isEmpty {
        return renderUninstallGuide(text)
    }
    return renderUninstallGuide(fallbackUninstallGuide)
}

private func bundledTextResource(named name: String) -> String? {
    guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
          let text = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty else {
        return nil
    }
    return text
}

private func renderUninstallGuide(_ text: String) -> String {
    let bundleIdentifier = Bundle.main.bundleIdentifier?.nilIfEmpty ?? "local.ai-monitor.desktop"
    return text
        .replacingOccurrences(of: "<bundle-id>", with: bundleIdentifier)
        .replacingOccurrences(of: "<launch-agent-label>", with: launchAgentLabel)
}

private func applicationSupportURL() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
    return base.appendingPathComponent("AI Monitor", isDirectory: true)
}

@discardableResult
private func ensureApplicationSupportDirectory() throws -> URL {
    let url = applicationSupportURL()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func daemonDatabaseURL() throws -> URL {
    try ensureApplicationSupportDirectory().appendingPathComponent("ai-monitor.db")
}

private func ensureDefaultDaemonConfig(at url: URL) {
    guard !FileManager.default.fileExists(atPath: url.path) else {
        return
    }

    do {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let bundled = Bundle.main.url(forResource: "default", withExtension: "toml") {
            try FileManager.default.copyItem(at: bundled, to: url)
            return
        }

        let repoConfig = repoRootURL().appendingPathComponent("config/default.toml")
        if FileManager.default.fileExists(atPath: repoConfig.path) {
            try FileManager.default.copyItem(at: repoConfig, to: url)
            return
        }

        try fallbackDefaultDaemonConfig.write(to: url, atomically: true, encoding: .utf8)
    } catch {
        NSLog("AI Monitor could not create default config: \(error.localizedDescription)")
    }
}

private func daemonExecutableURL() -> URL? {
    let bundledCandidates = [
        Bundle.main.url(forResource: bundledDaemonResourceName, withExtension: nil),
        Bundle.main.resourceURL?.appendingPathComponent(bundledDaemonResourceName),
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(bundledDaemonResourceName),
    ].compactMap { $0 }

    for candidate in bundledCandidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
        return candidate
    }

    let root = repoRootURL()
    let developmentCandidates = [
        root.appendingPathComponent("target/release/ai-monitor-daemon"),
        root.appendingPathComponent("target/debug/ai-monitor-daemon"),
    ]
    return developmentCandidates.first {
        FileManager.default.isExecutableFile(atPath: $0.path)
    }
}

private func repoRootURL() -> URL {
    if let override = ProcessInfo.processInfo.environment["AI_MONITOR_REPO_ROOT"]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
       !override.isEmpty {
        return URL(fileURLWithPath: override)
    }

    if let resourceURL = Bundle.main.url(forResource: "repo-root", withExtension: "txt"),
       let resourceValue = try? String(contentsOf: resourceURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
       !resourceValue.isEmpty {
        return URL(fileURLWithPath: resourceValue)
    }

    return URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    private let content = FloatingMonitorView(frame: NSRect(origin: .zero, size: defaultPanelSize))
    private var panel: NSPanel?
    private var timer: Timer?
    private var statusItem: NSStatusItem?
    private var taskIndex: [String: AgentTask] = [:]
    private var deliveredNotificationKeys: Set<String> = []
    private var autoStartAttempted = false
    private var daemonStartInProgress = false
    private var notificationAuthorizationRequestInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureNotifications()

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = initialPanelFrame(in: screenFrame)

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = content
        panel.minSize = minimumPanelSize
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        configureStatusItem()

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        presentFirstRunSettingsIfNeeded()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if isSettingsDeepLink(url) {
                showSettings()
            } else if let taskId = handleMonitorDeepLink(url) {
                openTaskById(taskId)
            } else {
                _ = openURLIfAllowed(url)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopLaunchedDaemonProcessOnAppQuit()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if #available(macOS 11.0, *) {
            completionHandler([.banner, .list, .sound])
        } else {
            completionHandler([.alert, .sound])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard [
            UNNotificationDefaultActionIdentifier,
            notificationOpenActionIdentifier,
        ].contains(response.actionIdentifier),
            let taskId = response.notification.request.content.userInfo["task_id"] as? String else {
            completionHandler()
            return
        }

        DispatchQueue.main.async {
            self.openTaskById(taskId)
            completionHandler()
        }
    }

    func windowDidMove(_ notification: Notification) {
        persistPanelFrame()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        persistPanelFrame()
    }

    private func initialPanelFrame(in screenFrame: NSRect) -> NSRect {
        if let saved = UserDefaults.standard.string(forKey: panelFrameDefaultsKey) {
            var frame = NSRectFromString(saved)
            if frame.width > maximumRestoredPanelWidth {
                frame.size.width = defaultPanelSize.width
                frame.origin.x = min(frame.origin.x, screenFrame.maxX - frame.width - 20)
            }
            if frame.width >= minimumPanelSize.width,
               frame.height >= minimumPanelSize.height,
               NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                return frame
            }
        }

        return NSRect(
            x: screenFrame.maxX - defaultPanelSize.width - 20,
            y: screenFrame.maxY - defaultPanelSize.height - 20,
            width: defaultPanelSize.width,
            height: defaultPanelSize.height
        )
    }

    private func persistPanelFrame() {
        guard let panel else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: panelFrameDefaultsKey)
    }

    private func configureNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let openAction = UNNotificationAction(
            identifier: notificationOpenActionIdentifier,
            title: "Open",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: notificationCategoryIdentifier,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    private func requestNotificationAuthorizationIfNeeded(completion: @escaping (Bool) -> Void) {
        guard !notificationAuthorizationRequestInProgress else { return }
        notificationAuthorizationRequestInProgress = true

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            let finish: (Bool) -> Void = { granted in
                DispatchQueue.main.async {
                    self?.notificationAuthorizationRequestInProgress = false
                    completion(granted)
                }
            }

            switch settings.authorizationStatus {
            case .authorized, .provisional:
                finish(true)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error {
                        NSLog("AI Monitor notification authorization failed: \(error.localizedDescription)")
                    } else if !granted {
                        NSLog("AI Monitor notification authorization denied")
                    }
                    finish(granted)
                }
            default:
                finish(false)
            }
        }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: 28)
        if let button = item.button {
            button.image = menuBarLogoImage() ??
                NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: "AI Monitor")
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyUpOrDown
            button.toolTip = "AI Monitor"
        }

        let menu = NSMenu()
        let showItem = NSMenuItem(title: "Show Monitor", action: #selector(showMonitor), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let startDaemonItem = NSMenuItem(title: "Start Daemon", action: #selector(startDaemon), keyEquivalent: "")
        startDaemonItem.target = self
        menu.addItem(startDaemonItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    @objc private func showMonitor() {
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showSettings() {
        if settingsPanelController == nil {
            settingsPanelController = SettingsPanelController {
                self.refresh()
            }
        }
        settingsPanelController?.show()
    }

    private func presentFirstRunSettingsIfNeeded() {
        guard appSettings.shouldShowFirstRunSettings else { return }
        if !appIsRunningFromTransientLocation() {
            appSettings.markFirstRunSettingsShown()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.showSettings()
        }
    }

    @objc private func startDaemon() {
        do {
            content.renderError(try launchDaemonFromSettings())
        } catch {
            showDetailError("Daemon launch failed: \(error.localizedDescription)")
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func refresh() {
        let url = appSettings.daemonURL.appendingPathComponent("tasks")
        URLSession.shared.dataTask(with: authorizedRequest(url: url)) { [weak self] data, response, error in
            if let error {
                DispatchQueue.main.async {
                    self?.handleDaemonOffline(error)
                }
                return
            }

            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                DispatchQueue.main.async {
                    self?.content.renderError("Daemon auth failed")
                }
                return
            }

            guard let data else { return }
            do {
                let tasks = try JSONDecoder().decode([AgentTask].self, from: data)
                let now = Date()
                let desktopTasks = appSettings.observeDesktop
                    ? localDesktopTasks(now: now, existingTasks: tasks)
                    : []
                let visibleTasks = filterTasksBySettings(tasks + desktopTasks)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.autoStartAttempted = false
                    self.daemonStartInProgress = false
                    self.taskIndex = Dictionary(uniqueKeysWithValues: visibleTasks.map { ($0.taskId, $0) })
                    self.content.render(tasks: visibleTasks)
                    self.notifyForRelevantTaskUpdates(visibleTasks, now: now)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.content.renderError("Decode failed: \(error.localizedDescription)")
                }
            }
        }.resume()
    }

    private func handleDaemonOffline(_ error: Error) {
        if daemonStartInProgress {
            content.renderError("Daemon starting automatically")
            return
        }

        guard !autoStartAttempted else {
            content.renderError("Daemon offline: \(error.localizedDescription)")
            return
        }

        autoStartAttempted = true
        daemonStartInProgress = true
        content.renderError("Daemon starting automatically")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try launchDaemonFromSettings()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.daemonStartInProgress = false
                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    self.daemonStartInProgress = false
                    self.content.renderError("Daemon launch failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func notifyForRelevantTaskUpdates(_ tasks: [AgentTask], now: Date) {
        guard appSettings.localNotifications else { return }
        let pendingTasks = tasks.filter { task in
            shouldNotifyForTask(task, now: now) &&
                !deliveredNotificationKeys.contains(appNotificationKey(for: task))
        }
        guard !pendingTasks.isEmpty else { return }

        requestNotificationAuthorizationIfNeeded { [weak self] granted in
            guard let self, granted else { return }
            for task in pendingTasks {
                let key = appNotificationKey(for: task)
                guard !deliveredNotificationKeys.contains(key) else {
                    continue
                }
                deliveredNotificationKeys.insert(key)
                postClickableTaskNotification(task)
            }

            if deliveredNotificationKeys.count > 512 {
                deliveredNotificationKeys = Set(deliveredNotificationKeys.suffix(256))
            }
        }
    }

    private func openTaskById(_ taskId: String) {
        if let task = taskIndex[taskId] {
            openTask(task)
            return
        }

        fetchTask(taskId: taskId) { task in
            guard let task else { return }
            self.taskIndex[task.taskId] = task
            openTask(task)
        }
    }
}

private func loadAPITokenFromEnvironmentOrFile() -> String? {
    if let value = ProcessInfo.processInfo.environment["AI_MONITOR_API_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !value.isEmpty {
        return value
    }

    return try? String(contentsOf: defaultAPITokenFileURL(), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nilIfEmpty
}

private func authorizedRequest(url: URL) -> URLRequest {
    var request = URLRequest(url: url)
    if let apiToken = appSettings.apiToken {
        request.setValue(apiToken, forHTTPHeaderField: "x-ai-monitor-token")
    }
    return request
}

let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
