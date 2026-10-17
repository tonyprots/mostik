import AppKit
import Foundation
import MostikCore
import MostikKit
import MostikUI

/// П6-А вокруг диктовки: план на старте (сценарии P2, разовые режимы V3/A4), правила речи (P3, V4),
/// контекст из приложения (P1), стиль по кругу (P4), потоковая вставка (P6), очередь агенту (A6).
///
/// Решения — в MostikCore (`PolishExtras.swift`, `AgentQueue.swift`); здесь — AX, буфер, файлы
/// очереди и связь с движком. `AppController` зовёт отсюда пару методов в начале записи и при вставке.
@MainActor
final class PolishExtrasController {
    private let model: AppModel
    private let paths: MostikPaths
    private let paster: Paster
    private let engine: () -> EngineClient
    /// Карточка в HUD: заголовок и подпись.
    var notice: (String, String) -> Void = { _, _ in }

    /// Домен страницы, прочитанный на старте записи, — для контекста.
    private var startHost: String?

    init(model: AppModel, paths: MostikPaths, paster: Paster, engine: @escaping () -> EngineClient) {
        self.model = model
        self.paths = paths
        self.paster = paster
        self.engine = engine
        let extras = model.polishExtras
        extras.onRefreshPacks = { [weak self] in Task { await self?.refreshPacks() } }
        extras.onOpenStylesFolder = { [weak self] in self?.openStylesFolder() }
        extras.onAddExample = { [weak self] in Task { await self?.refreshPacks(example: true) } }
        extras.onPreview = { [weak self] variant, raw in self?.preview(variant: variant, raw: raw) }
        extras.onPrepareQueueHooks = { [weak self] in self?.prepareQueueHooks() }
        extras.onInstallQueueHooks = { [weak self] in self?.installQueueHooks() }
        extras.onUninstallQueueHooks = { [weak self] in self?.uninstallQueueHooks() }
    }

    func start() {
        settingsChanged()
        refreshQueueHooksStatus()
    }

    func engineReady() async { await refreshPacks() }

    func settingsChanged() {
        syncQueueMarker()
    }

    // MARK: план и старт записи

    /// План диктовки по приложению впереди. Домен страницы читаем до старта, только если он нужен
    /// сценарию; иначе — после старта, для контекста.
    /// `host` — домен страницы, прочитанный на старте вне главного потока; nil — не браузер или не нашли.
    func plan(front: FrontApp, isAgent: Bool, host: String?) -> DictationPlan {
        let settings = model.settings.polish
        startHost = host
        let mode = model.polishExtras.pendingMode
        model.polishExtras.pendingMode = nil
        return settings.plan(bundleID: front.bundleID, host: startHost, isAgent: isAgent, mode: mode)
    }

    /// Поля `start`: правила речи (P3, V4).
    func startFields() -> [String: JSONValue] {
        EngineClient.polishExtraFields(rules: model.settings.polish.rules)
    }

    /// Запись пошла: контекст из поля (снимок R1 уже есть), буфер и домен — движку, пока человек говорит.
    /// Возвращает, ушёл ли в движок контекст из приложения (П10: от этого зависит Enter сценария).
    @discardableResult
    func recordingStarted(session: String, plan: DictationPlan, field: FieldSnapshot?, bundleID: String) -> Bool {
        stream = plan.polish?.stream == true ? StreamState(session: session, bundleID: bundleID, start: field) : nil
        let settings = model.settings.polish.context
        guard let backend = plan.polish?.backend else { return false }
        let source = PolishContextReader.read(field: field, bundleID: bundleID, clipboard: settings.clipboard,
                                              host: startHost)
        guard let context = PolishContext.make(source, settings: settings, backend: backend) else { return false }
        engine().sendContext(session: session, context: context)
        return true
    }

    // MARK: сочетания ⌃⌘Y, ⌃⌘E, ⌃⌘J

    func hotkey(_ event: DeliveryHotkeys.Event) {
        let ru = L10n.isRussian
        switch event {
        case .cycleStyle:
            Task {
                if model.polishExtras.packs.isEmpty { await refreshPacks() }
                var s = model.settings
                let next = s.polish.nextStyle(packs: model.polishExtras.packs.map(\.id))
                s.polish.style = next.style
                s.polish.pack = next.pack
                model.onUpdateSettings(s)
                let name = next.pack.flatMap { id in model.polishExtras.packs.first { $0.id == id }?.name }
                    ?? Self.styleName(next.style)
                notice(ru ? "Стиль: \(name)" : "Style: \(name)",
                       model.settings.polish.effectiveBackend == .off
                        ? (ru ? "Причёсывание выключено в Настройках" : "Polishing is off in Settings")
                        : (ru ? "⌃⌘Y — следующий" : "⌃⌘Y — next"))
            }
        case .translateNext, .taskNext:
            let mode: PolishMode = event == .translateNext ? .translate : .task
            let extras = model.polishExtras
            extras.pendingMode = extras.pendingMode == mode ? nil : mode
            guard model.settings.polish.effectiveBackend != .off else {
                extras.pendingMode = nil
                notice(ru ? "Причёсывание выключено" : "Polishing is off",
                       ru ? "Включите его в Настройках → Текст: перевод и задачу делает модель" : "Turn it on in Settings → Text — the model does this")
                return
            }
            switch extras.pendingMode {
            case .translate?: notice(ru ? "Следующая диктовка — по-английски" : "Next dictation — in English", ru ? "⌃⌘E ещё раз — отмена" : "⌃⌘E again to cancel")
            case .task?: notice(ru ? "Следующая диктовка — задачей" : "Next dictation — as a task", ru ? "⌃⌘J ещё раз — отмена" : "⌃⌘J again to cancel")
            case nil: notice(ru ? "Отменено" : "Cancelled", ru ? "Следующая диктовка — как обычно" : "Next dictation as usual")
            }
        default:
            break
        }
    }

    static func styleName(_ style: PolishStyle) -> String {
        let ru = L10n.isRussian
        switch style {
        case .plain: return ru ? "обычный" : "plain"
        case .business: return ru ? "деловой" : "business"
        case .brief: return ru ? "кратко" : "brief"
        case .list: return ru ? "списком" : "list"
        case .dev: return ru ? "разработчик" : "developer"
        case .task: return ru ? "задача" : "task"
        }
    }

    // MARK: P4 — стили-файлы

    func refreshPacks(example: Bool = false) async {
        guard let reply = try? await engine().stylePacks(example: example) else { return }
        model.polishExtras.packs = reply.packs
        model.polishExtras.stylesFolder = reply.folder
        // Пакет удалили из папки — возвращаемся к встроенному стилю.
        if let pack = model.settings.polish.pack, !reply.packs.contains(where: { $0.id == pack }) {
            var s = model.settings
            s.polish.pack = nil
            model.onUpdateSettings(s)
        }
    }

    private func openStylesFolder() {
        let folder = model.polishExtras.stylesFolder.map { URL(fileURLWithPath: $0) }
            ?? paths.root.appendingPathComponent("styles")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    // MARK: P2 — превью тона

    private func preview(variant: String, raw: String) {
        let s = model.settings.polish
        let backend = s.effectiveBackend
        guard backend != .off else { return }
        var request = PolishRequest(backend: backend, style: .plain)
        switch variant {
        case "business": request.style = .business
        case "brief": request.style = .brief
        case "en": request.translate = PolishTranslate(to: "en", tone: s.translateTone)
        default: break
        }
        let extras = model.polishExtras
        extras.previewBusy = true
        extras.previewMessage = nil
        Task {
            defer { extras.previewBusy = false }
            do {
                let reply = try await engine().polishText(raw, language: "ru", polish: request, rules: s.rules)
                extras.preview[variant] = reply.text
                if !reply.polished {
                    extras.previewMessage = L10n.isRussian ? "Модель не ответила (\(reply.status)) — показан текст как сказано."
                                                           : "The model didn’t answer (\(reply.status)) — showing unpolished text."
                }
            } catch {
                extras.previewMessage = error.localizedDescription
            }
        }
    }

    // MARK: P6 — потоковая вставка

    private struct StreamState {
        let session: String
        let bundleID: String
        let start: FieldSnapshot?
        /// Последний кусок от движка.
        var target = ""
        /// Текст причёсывания, уже вставленный по ходу.
        var inserted = ""
        /// Что реально ушло в поле (с пробелом на стыке у первого куска).
        var typed = ""
        var busy = false
        /// Приложение куски не приняло или окно сменилось — дальше только целиком.
        var stopped = false
    }
    private var stream: StreamState?

    /// Кусок причёсывания (`polish_partial`). true — событие наше, дальше не передавать.
    func partial(session sid: String, text: String) -> Bool {
        guard sid.hasPrefix(EngineCodec.polishPartialPrefix) else { return false }
        let id = String(sid.dropFirst(EngineCodec.polishPartialPrefix.count))
        guard var state = stream, state.session == id, !state.stopped else { return true }
        state.target = text
        stream = state
        if !state.busy { Task { await pump() } }
        return true
    }

    private func pump() async {
        while let state = stream, !state.stopped, !state.busy,
              let chunk = StreamInsert.append(inserted: state.inserted, partial: state.target) {
            stream?.busy = true
            let first = state.inserted.isEmpty
            var ok = false
            var typed = chunk
            if first {
                // Первый кусок — как обычная доставка: пробел на стыке и проверка, что поле его приняло.
                let report = await paster.deliver(text: chunk, expectedBundleID: state.bundleID, start: state.start)
                ok = report.outcome == .inserted && report.check != .notInserted
                typed = report.sent
            } else {
                ok = await paster.insert(text: chunk, expectedBundleID: state.bundleID) == .inserted
            }
            guard stream?.session == state.session else { return }
            stream?.busy = false
            if ok {
                stream?.inserted += chunk
                stream?.typed += typed
            } else {
                stream?.stopped = true
            }
        }
    }

    /// Итог пришёл. nil — по ходу ничего не вставлено, доставка целиком как обычно.
    func finishStream(session: String, text: String) async -> DeliveryReport? {
        guard let state = stream, state.session == session else { return nil }
        for _ in 0..<60 where stream?.busy == true { try? await Task.sleep(nanoseconds: 50_000_000) }
        let done = stream ?? state
        stream = nil
        guard !done.typed.isEmpty else { return nil }
        switch StreamInsert.finish(inserted: done.inserted, final: text) {
        case .whole:
            return nil
        case .append(let rest):
            let outcome: PasteOutcome = rest.isEmpty ? .inserted : await paster.insert(text: rest, expectedBundleID: done.bundleID)
            return DeliveryReport(outcome: outcome, check: nil, before: nil, after: nil, sent: done.typed + rest)
        case .replace(_, let final):
            let field = FocusedField.snapshot()
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == done.bundleID,
               StreamInsert.canReplace(field: field, inserted: done.typed),
               paster.selectBackward(done.typed.utf16.count) {
                try? await Task.sleep(nanoseconds: 80_000_000)
                let outcome = await paster.insert(text: final, expectedBundleID: done.bundleID)
                return DeliveryReport(outcome: outcome, check: nil, before: nil, after: nil, sent: final)
            }
            // Поле правили или курсор ушёл: напечатанное не трогаем, итог — в буфер.
            paster.write(final)
            return DeliveryReport(outcome: .clipboard(reason: "stream_diverged"), check: nil, before: field, after: nil, sent: final)
        }
    }

    func cancelStream(session: String) {
        if stream?.session == session { stream = nil }
    }

    // MARK: A6 — очередь агенту

    private var queueRoot: URL { paths.root.appendingPathComponent(AgentQueue.folderName) }

    private func syncQueueMarker() {
        let fm = FileManager.default
        let marker = queueRoot.appendingPathComponent(AgentQueue.enabledMarker)
        if model.settings.agentVoice.midTurn {
            try? fm.createDirectory(at: queueRoot, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: marker.path) { fm.createFile(atPath: marker.path, contents: Data()) }
        } else if fm.fileExists(atPath: marker.path) {
            try? fm.removeItem(at: marker)
        }
    }

    /// Положить сообщение в очередь занятой сессии Claude Code. false — очередь выключена, хуков
    /// нет или агент свободен: вставка идёт как обычно.
    func enqueueForAgent(_ text: String, front: FrontApp, project: String?) -> Bool {
        let policy = model.settings.agentPolicy
        guard model.settings.agentVoice.midTurn, model.polishExtras.queueHooksInstalled,
              policy.isAgent(front) || policy.terminals.contains(front.bundleID),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let fm = FileManager.default
        let busyDir = queueRoot.appendingPathComponent("busy")
        let names = (try? fm.contentsOfDirectory(atPath: busyDir.path)) ?? []
        let sessions = names.compactMap { name -> BusySession? in
            let url = busyDir.appendingPathComponent(name)
            let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
            return AgentQueue.parseBusy(name: name, content: try? String(contentsOf: url, encoding: .utf8), modified: modified)
        }
        guard let target = AgentQueue.target(sessions, project: project, now: Date()) else { return false }
        let dir = queueRoot.appendingPathComponent("queue/\(target.id)")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = AgentQueue.messageFileName(now: Date(), suffix: UUID().uuidString)
            let tmp = dir.appendingPathComponent("." + name + ".tmp")
            try AgentQueue.encodeMessage(text).write(to: tmp, atomically: false, encoding: .utf8)
            try fm.moveItem(at: tmp, to: dir.appendingPathComponent(name))
            return true
        } catch {
            return false
        }
    }

    // MARK: A6 — хуки очереди, только по кнопке

    private var claudeSettings: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }
    private var installedScript: URL { paths.root.appendingPathComponent("hooks/\(QueueHooks.scriptName)") }

    private var bundledScript: URL? {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL?.appendingPathComponent("hooks/\(QueueHooks.scriptName)"),
           fm.fileExists(atPath: res.path) { return res }
        // В отладочной сборке — из репозитория; в релизе его путь не известен (П8, пункт 1).
        guard let repo = EngineLocator.devRepoRoot()?
            .appendingPathComponent("integrations/claude-code/hooks/\(QueueHooks.scriptName)") else { return nil }
        return fm.fileExists(atPath: repo.path) ? repo : nil
    }

    private func refreshQueueHooksStatus() {
        let settings = ClaudeHooks.load(try? Data(contentsOf: claudeSettings)) ?? [:]
        model.polishExtras.queueHooksInstalled = QueueHooks.isInstalled(settings)
            && FileManager.default.isExecutableFile(atPath: installedScript.path)
    }

    private func backupURL() -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return claudeSettings.deletingLastPathComponent().appendingPathComponent("settings.json.mostik-backup-\(stamp)")
    }

    private func prepareQueueHooks() {
        let ru = L10n.isRussian
        let extras = model.polishExtras
        guard bundledScript != nil else {
            extras.queueHooksMessage = ru ? "Скрипт очереди не найден в сборке." : "Queue script is missing from the build."
            return
        }
        guard ClaudeHooks.load(try? Data(contentsOf: claudeSettings)) != nil else {
            extras.queueHooksMessage = ru ? "~/.claude/settings.json не разобрать как JSON — файл не тронут."
                                          : "~/.claude/settings.json isn’t valid JSON — leaving it alone."
            return
        }
        let exists = FileManager.default.fileExists(atPath: claudeSettings.path)
        extras.queueHooksMessage = nil
        extras.queueHooksPlan = .init(settingsPath: claudeSettings.path, scriptPath: installedScript.path,
                                      preview: QueueHooks.preview(scriptPath: installedScript.path),
                                      backupPath: exists ? backupURL().path : nil)
    }

    private func installQueueHooks() {
        let ru = L10n.isRussian
        let extras = model.polishExtras
        let plan = extras.queueHooksPlan
        extras.queueHooksPlan = nil
        let fm = FileManager.default
        do {
            guard let source = bundledScript else { throw CocoaError(.fileNoSuchFile) }
            try fm.createDirectory(at: installedScript.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: installedScript.path) { try fm.removeItem(at: installedScript) }
            try fm.copyItem(at: source, to: installedScript)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedScript.path)
            try writeClaudeSettings(backup: plan?.backupPath) { QueueHooks.install(into: $0, scriptPath: self.installedScript.path) }
            extras.queueHooksMessage = ru ? "Готово. Новые сессии Claude Code подхватят очередь сами."
                                          : "Done. New Claude Code sessions pick up the hooks."
        } catch {
            extras.queueHooksMessage = (ru ? "Не удалось установить: " : "Couldn’t install: ") + error.localizedDescription
        }
        refreshQueueHooksStatus()
    }

    private func uninstallQueueHooks() {
        let ru = L10n.isRussian
        do {
            try writeClaudeSettings(backup: backupURL().path) { QueueHooks.uninstall(from: $0) }
            model.polishExtras.queueHooksMessage = ru ? "Очередь убрана, остальное в настройках Claude Code не тронуто."
                                                      : "Queue hooks removed; nothing else in Claude Code settings changed."
        } catch {
            model.polishExtras.queueHooksMessage = (ru ? "Не удалось удалить: " : "Couldn’t remove: ") + error.localizedDescription
        }
        refreshQueueHooksStatus()
    }

    private func writeClaudeSettings(backup: String?, _ change: ([String: Any]) -> [String: Any]) throws {
        let fm = FileManager.default
        guard let current = ClaudeHooks.load(try? Data(contentsOf: claudeSettings)) else { throw CocoaError(.fileReadCorruptFile) }
        guard let encoded = ClaudeHooks.encode(change(current)) else { throw CocoaError(.fileWriteUnknown) }
        try fm.createDirectory(at: claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let backup, fm.fileExists(atPath: claudeSettings.path), !fm.fileExists(atPath: backup) {
            try fm.copyItem(at: claudeSettings, to: URL(fileURLWithPath: backup))
        }
        try encoded.write(to: claudeSettings, options: .atomic)
    }
}
