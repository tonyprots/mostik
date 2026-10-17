import AppKit
import Foundation
import MostikCore
import MostikKit
import MostikUI

/// Голос и агенты (G5, G6, A1, A3, A5).
///
/// Перед вставкой `route` разбирает текст: обращение к сессии («фронтенду: …»), слово «отправь»
/// в конце, упоминания файлов — и решает, идёт ли текст в панель tmux. Озвучка слушает папку
/// событий хуков Claude Code. Решения — в MostikCore (`AgentVoice`, `Tmux`, `FileMentions`,
/// `AgentEvents`); здесь — процессы, файлы, голос и HUD.
@MainActor
final class AgentVoiceController {
    struct Route {
        var text: String
        /// Нажать Enter после вставки (G6).
        var submit: Bool
        /// Панель tmux, куда уходит текст (G5, A5); nil — обычная вставка.
        var pane: TmuxAgentPane?
        /// Имя, по которому обратились к сессии (A5).
        var addressed: String?
        /// Пути, ставшие `@путь` (A3).
        var tagged: [String]
    }

    private let model: AppModel
    private let paths: MostikPaths
    private let tmux = TmuxClient()
    private let files = ProjectFiles()
    private let announcer = AgentAnnouncer()
    private let inbox: AgentEventInbox
    private var lastEvent: AgentEvent?
    /// Идёт запись или голосовая правка: голос ждёт, иначе он попадёт в микрофон.
    var isBusy: () -> Bool = { false }

    init(model: AppModel, paths: MostikPaths) {
        self.model = model
        self.paths = paths
        inbox = AgentEventInbox(root: paths.root)
        let voice = model.agentVoice
        voice.tmuxPath = tmux.binary
        voice.onRefresh = { [weak self] in self?.refresh() }
        voice.onPrepareHooks = { [weak self] in self?.prepareHooks() }
        voice.onInstallHooks = { [weak self] in self?.installHooks() }
        voice.onUninstallHooks = { [weak self] in self?.uninstallHooks() }
        voice.onTestAnnouncement = { [weak self] in self?.testAnnouncement() }
    }

    func start() {
        settingsChanged()
        refresh()
    }

    func stop() {
        if inbox.isListening { inbox.stop() }
        announcer.stop()
    }

    func settingsChanged() {
        let s = model.settings.agentVoice
        // A1: выбранные голоса; удалённый из системы — заменится лучшим установленным.
        announcer.voiceRU = s.voiceRU
        announcer.voiceEN = s.voiceEN
        if s.announce, !inbox.isListening {
            inbox.start { [weak self] event in self?.handle(event) }
        } else if !s.announce, inbox.isListening {
            inbox.stop()
        }
        if s.tmuxPaste { refreshPanes() }
    }

    /// Запись началась: голос замолкает, индекс файлов проекта греется.
    func recordingBegan(project: String?) {
        announcer.stop()
        if model.settings.agentVoice.fileMentions, let project { _ = files.index(root: project) }
    }

    func refresh() {
        refreshPanes()
        refreshHooksStatus()
    }

    private func refreshPanes() {
        guard tmux.isAvailable else { model.agentVoice.panes = []; return }
        let names = model.settings.agentPolicy.agentCLIs
        let tmux = self.tmux
        Task {
            let panes = await Task.detached { tmux.agentPanes(names: names) }.value
            model.agentVoice.panes = panes.map { .init(id: $0.pane.id, title: $0.title, label: $0.pane.label) }
        }
    }

    // MARK: маршрут текста (G5, G6, A3, A5)

    /// `spoken` — текст до модели (`SpokenCommands.spoken`): «отправь» и адрес засчитываются, только если они там есть.
    func route(text: String, front: FrontApp, project: String?, spoken: String? = nil) async -> Route {
        let s = model.settings.agentVoice
        let policy = model.settings.agentPolicy
        var route = Route(text: text, submit: false, pane: nil, addressed: nil, tagged: [])
        let isTerminal = policy.terminals.contains(front.bundleID)

        if s.tmuxPaste, tmux.isAvailable, isTerminal || policy.isAgent(front) {
            let app = NSWorkspace.shared.frontmostApplication
            let pid = app?.processIdentifier
            let bundlePath = app?.bundleURL?.path
            let names = policy.agentCLIs
            let tmux = self.tmux
            let (panes, focus) = await Task.detached { () -> ([TmuxAgentPane], (hasClient: Bool, session: String?)) in
                let panes = tmux.agentPanes(names: names)
                guard isTerminal, let pid, !panes.isEmpty else { return (panes, (false, nil)) }
                return (panes, tmux.focusedSession(appPID: pid, bundlePath: bundlePath))
            }.value
            model.agentVoice.panes = panes.map { .init(id: $0.pane.id, title: $0.title, label: $0.pane.label) }
            if s.addressing, let match = SpokenCommands.address(route.text, spoken: spoken,
                                                                candidates: TmuxTargeting.candidates(panes)) {
                route.pane = panes.first { $0.pane.id == match.id }
                route.addressed = match.name
                route.text = match.rest
            } else if isTerminal, focus.hasClient {
                route.pane = TmuxTargeting.choose(panes, preference: s.tmuxTarget, focusedSession: focus.session)
            }
        }

        if s.voiceSend {
            let send = SpokenCommands.send(route.text, spoken: spoken)
            route.text = send.text
            route.submit = send.submit
        }

        if s.fileMentions {
            let supported = route.pane.map { FileMentionApps.cliAgents.contains($0.agent) }
                ?? FileMentionApps.supports(front, policy: policy)
            if supported, let root = route.pane?.project ?? project,
               let index = await files.index(root: root, waiting: 0.3) {
                let tagged = FileMentions.apply(route.text, index: index)
                route.text = tagged.text
                route.tagged = tagged.tagged
            }
        }

        if isTerminal || route.pane != nil { route.text = VoiceSend.terminalNewlines(route.text) }
        return route
    }

    /// Вставка в панель tmux: bracketed paste, буфер обмена не трогается.
    func deliver(_ text: String, to pane: TmuxAgentPane, id: String) async -> DeliveryReport {
        await tmux.deliver(text, pane: pane.pane.id, id: id)
    }

    /// Enter после вставки (G6): в tmux — `send-keys` через 0,25 с, иначе Return через 0,35 с
    /// и только если впереди всё то же приложение.
    func submit(_ route: Route, bundleID: String) async {
        if let pane = route.pane {
            try? await Task.sleep(nanoseconds: UInt64(VoiceSend.tmuxEnterDelay * 1_000_000_000))
            let tmux = self.tmux
            let id = pane.pane.id
            _ = await Task.detached { tmux.enter(pane: id) }.value
            return
        }
        try? await Task.sleep(nanoseconds: UInt64(VoiceSend.enterDelay * 1_000_000_000))
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID else { return }
        KeyPresser.pressReturn()
    }

    /// Подпись в HUD для вставки в панель: «В frontend».
    func summary(for route: Route) -> String? {
        guard let pane = route.pane else { return nil }
        let name = route.addressed ?? (SessionAddress.usable(pane.pane.session) ? pane.pane.session : pane.pane.label)
        let sent = route.submit
        return L10n.isRussian ? (sent ? "Отправлено в \(name)" : "Вставлено в \(name)")
                              : (sent ? "Sent to \(name)" : "Pasted into \(name)")
    }

    // MARK: озвучка (A1)

    private func handle(_ event: AgentEvent) {
        guard model.settings.agentVoice.announce, !AgentEvents.isDuplicate(event, of: lastEvent) else { return }
        lastEvent = event
        let withSummary = model.settings.agentVoice.announceSummary && event.kind == .done
        let tmux = self.tmux
        Task {
            let (session, summary) = await Task.detached { () -> (String?, String?) in
                var session: String?
                if let id = event.tmuxPane, tmux.isAvailable {
                    session = tmux.panes().first { $0.id == id }?.session
                    if let s = session, !SessionAddress.usable(s) { session = nil }
                }
                var summary: String?
                if withSummary, let path = event.transcriptPath {
                    summary = Self.tail(path).flatMap { AgentEvents.lastAssistantSentence(transcript: $0) }
                }
                return (session, summary)
            }.value
            let project = event.cwd.flatMap { ProjectResolver.projectRoot(of: $0) } ?? event.cwd
            let text = AgentEvents.announcement(event, project: project, session: session, summary: summary,
                                                russian: L10n.isRussian)
            await speakWhenFree(text, kind: event.kind)
        }
    }

    /// Пока идёт запись, голос ждёт — до минуты; потом событие уже неактуально.
    private func speakWhenFree(_ text: String, kind: AgentEventKind) async {
        for _ in 0..<120 where isBusy() {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard !isBusy(), model.settings.agentVoice.announce else { return }
        announcer.announce(text, kind: kind)
    }

    private func testAnnouncement() {
        let project = model.currentProject ?? paths.root.path
        let event = AgentEvent(kind: .permission)
        announcer.announce(AgentEvents.announcement(event, project: project, session: nil, summary: nil,
                                                    russian: L10n.isRussian), kind: .permission)
    }

    /// Хвост транскрипта: он растёт до мегабайт, последняя реплика — в конце.
    nonisolated static func tail(_ path: String, bytes: UInt64 = 262_144) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > bytes ? size - bytes : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: хуки Claude Code — только по кнопке

    private var claudeSettings: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }
    private var installedScript: URL { paths.root.appendingPathComponent("hooks/\(ClaudeHooks.scriptName)") }

    /// Скрипт из бандла; в отладочной сборке — из репозитория.
    private var bundledScript: URL? {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL?.appendingPathComponent("hooks/\(ClaudeHooks.scriptName)"),
           fm.fileExists(atPath: res.path) { return res }
        // В отладочной сборке — из репозитория; в релизе его путь не известен (П8, пункт 1).
        guard let repo = EngineLocator.devRepoRoot()?
            .appendingPathComponent("integrations/claude-code/hooks/\(ClaudeHooks.scriptName)") else { return nil }
        return fm.fileExists(atPath: repo.path) ? repo : nil
    }

    private func refreshHooksStatus() {
        let data = try? Data(contentsOf: claudeSettings)
        let settings = ClaudeHooks.load(data) ?? [:]
        model.agentVoice.hooksInstalled = ClaudeHooks.isInstalled(settings)
            && FileManager.default.isExecutableFile(atPath: installedScript.path)
    }

    private func backupURL() -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return claudeSettings.deletingLastPathComponent().appendingPathComponent("settings.json.mostik-backup-\(stamp)")
    }

    private func prepareHooks() {
        let ru = L10n.isRussian
        guard bundledScript != nil else {
            model.agentVoice.hooksMessage = ru ? "Скрипт подключения не найден в сборке." : "Hook script is missing from the build."
            return
        }
        let exists = FileManager.default.fileExists(atPath: claudeSettings.path)
        guard ClaudeHooks.load(try? Data(contentsOf: claudeSettings)) != nil else {
            model.agentVoice.hooksMessage = ru ? "~/.claude/settings.json не разобрать как JSON — файл не тронут."
                                               : "~/.claude/settings.json isn’t valid JSON — leaving it alone."
            return
        }
        model.agentVoice.hooksMessage = nil
        model.agentVoice.hooksPlan = .init(settingsPath: claudeSettings.path, scriptPath: installedScript.path,
                                           preview: ClaudeHooks.preview(scriptPath: installedScript.path),
                                           backupPath: exists ? backupURL().path : nil)
    }

    private func installHooks() {
        let ru = L10n.isRussian
        let plan = model.agentVoice.hooksPlan
        model.agentVoice.hooksPlan = nil
        let fm = FileManager.default
        do {
            guard let source = bundledScript else { throw CocoaError(.fileNoSuchFile) }
            try fm.createDirectory(at: installedScript.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: installedScript.path) { try fm.removeItem(at: installedScript) }
            try fm.copyItem(at: source, to: installedScript)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedScript.path)
            try writeClaudeSettings(backup: plan?.backupPath) { ClaudeHooks.install(into: $0, scriptPath: self.installedScript.path) }
            model.agentVoice.hooksMessage = ru ? "Готово. Новые сессии Claude Code подхватят подключение сами."
                                               : "Done. New Claude Code sessions pick up the hooks."
        } catch {
            model.agentVoice.hooksMessage = (ru ? "Не удалось установить: " : "Couldn’t install: ") + error.localizedDescription
        }
        refreshHooksStatus()
    }

    private func uninstallHooks() {
        let ru = L10n.isRussian
        do {
            try writeClaudeSettings(backup: backupURL().path) { ClaudeHooks.uninstall(from: $0) }
            model.agentVoice.hooksMessage = ru ? "Подключение Mostik убрано, остальное в настройках Claude Code не тронуто."
                                               : "Mostik hooks removed; nothing else in Claude Code settings changed."
        } catch {
            model.agentVoice.hooksMessage = (ru ? "Не удалось удалить: " : "Couldn’t remove: ") + error.localizedDescription
        }
        refreshHooksStatus()
    }

    /// Прочитать, изменить, сохранить копию прежнего файла и записать атомарно.
    private func writeClaudeSettings(backup: String?, _ change: ([String: Any]) -> [String: Any]) throws {
        let fm = FileManager.default
        let data = try? Data(contentsOf: claudeSettings)
        guard let current = ClaudeHooks.load(data) else { throw CocoaError(.fileReadCorruptFile) }
        guard let encoded = ClaudeHooks.encode(change(current)) else { throw CocoaError(.fileWriteUnknown) }
        try fm.createDirectory(at: claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let backup, fm.fileExists(atPath: claudeSettings.path), !fm.fileExists(atPath: backup) {
            try fm.copyItem(at: claudeSettings, to: URL(fileURLWithPath: backup))
        }
        try encoded.write(to: claudeSettings, options: .atomic)
    }
}
