import Foundation

/// То, что приложение знает о переднем окне в момент вставки.
public struct FrontApp: Equatable, Sendable {
    public var bundleID: String
    public var name: String
    public var windowTitle: String
    /// Имена запущенных процессов, по которым узнаём агента в терминале.
    public var runningAgentCLIs: Set<String>

    public init(bundleID: String, name: String = "", windowTitle: String = "", runningAgentCLIs: Set<String> = []) {
        self.bundleID = bundleID; self.name = name; self.windowTitle = windowTitle
        self.runningAgentCLIs = runningAgentCLIs
    }
}

/// Кому дописывать блок сомнений.
public struct AgentAppPolicy: Equatable, Sendable, Codable {
    public var terminals: Set<String>
    public var agentApps: Set<String>
    public var browsers: Set<String>
    public var agentCLIs: Set<String>
    public var browserTitleMarkers: [String]
    /// Ручные исключения и добавления по bundle id.
    public var forcedOn: Set<String>
    public var forcedOff: Set<String>

    public static let standard = AgentAppPolicy(
        terminals: ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
                    "com.github.wez.wezterm", "org.alacritty", "net.kovidgoyal.kitty"],
        agentApps: ["com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "dev.zed.Zed",
                    "com.microsoft.VSCode", "com.anthropic.claudefordesktop", "com.openai.chat"],
        browsers: ["com.apple.Safari", "com.google.Chrome", "com.google.Chrome.beta", "company.thebrowser.Browser",
                   "org.mozilla.firefox", "ru.yandex.desktop.yandex-browser", "com.microsoft.edgemac"],
        agentCLIs: ["claude", "codex", "aider", "gemini", "opencode"],
        browserTitleMarkers: ["Claude", "ChatGPT", "Gemini"],
        forcedOn: [], forcedOff: []
    )

    public init(terminals: Set<String>, agentApps: Set<String>, browsers: Set<String>, agentCLIs: Set<String>,
                browserTitleMarkers: [String], forcedOn: Set<String>, forcedOff: Set<String>) {
        self.terminals = terminals; self.agentApps = agentApps; self.browsers = browsers
        self.agentCLIs = agentCLIs; self.browserTitleMarkers = browserTitleMarkers
        self.forcedOn = forcedOn; self.forcedOff = forcedOff
    }

    public func isAgent(_ app: FrontApp) -> Bool {
        if forcedOff.contains(app.bundleID) { return false }
        if forcedOn.contains(app.bundleID) { return true }
        if agentApps.contains(app.bundleID) { return true }
        if terminals.contains(app.bundleID) { return !app.runningAgentCLIs.isDisjoint(with: agentCLIs) }
        if browsers.contains(app.bundleID) {
            return browserTitleMarkers.contains { app.windowTitle.localizedCaseInsensitiveContains($0) }
        }
        return false
    }
}

/// П10: Enter сценария (`DictationPlan.autoEnter`) не жмём, если в полировщик ушёл контекст из
/// приложения, а впереди агент или терминал. Текст с экрана мог подсказать модели команду, а
/// Enter отправил бы её агенту или в shell без участия человека. Вставка остаётся, Enter — за человеком.
public enum AutoEnterGuard {
    public static func allows(planned: Bool, contextSent: Bool, front: FrontApp, policy: AgentAppPolicy) -> Bool {
        guard planned else { return false }
        guard contextSent else { return true }
        return !(policy.terminals.contains(front.bundleID) || policy.isAgent(front))
    }
}
