import AppKit
import Foundation
import MostikCore
import MostikKit
import MostikUI

/// Голосовая правка выделенного (D5): правый ⌘ → выделение → команда → движок → замена на месте.
///
/// Recorder, Paster и FrontAppInspector общие с диктовкой: одновременно идёт что-то одно
/// (`isDictationBusy` и `isActive` проверяются с обеих сторон). Замена — вставкой поверх
/// выделения через `Paster`, поэтому её отменяет обычный ⌘Z целевого приложения.
@MainActor
final class VoiceEditController {
    private let model: AppModel
    private let recorder: Recorder
    private let paster: Paster
    private let inspector: FrontAppInspector
    private let engine: () -> EngineClient
    private let recordings: URL
    private let isDictationBusy: () -> Bool
    private let reader = SelectionReader()
    private var hotkey: VoiceEditHotkey!

    private struct Edit {
        let id: String
        let bundleID: String
        let wav: URL
        let backend: PolishBackend
        let language: String
        /// nil — AX не дал текста, читаем ⌘C после отпускания клавиши.
        var selection: String?
        /// Пилюля уже показала отказ (нет выделения, защищённое поле): отпускание ничего не шлёт.
        var refused: Bool = false
    }
    private var current: Edit?
    private var hideTask: Task<Void, Never>?

    /// Идёт запись или обработка правки — диктовка в это время не начинается.
    private(set) var isActive = false

    init(model: AppModel, recorder: Recorder, paster: Paster, inspector: FrontAppInspector,
         recordings: URL, engine: @escaping () -> EngineClient, isDictationBusy: @escaping () -> Bool) {
        self.model = model; self.recorder = recorder; self.paster = paster; self.inspector = inspector
        self.recordings = recordings; self.engine = engine; self.isDictationBusy = isDictationBusy
        hotkey = VoiceEditHotkey { [weak self] effect in self?.gesture(effect) }
    }

    func start() {
        hotkey.start()
        settingsChanged()
    }

    func stop() {
        hotkey.stop()
    }

    /// Клавиша правки слушается, только когда правка включена и бэкенд с согласием есть (как у причёсывания).
    /// Клавиша — правый ⌘, а при записи на правом ⌘ — правый ⌥ (`HoldKeys.voiceEditKey`).
    func settingsChanged() {
        hotkey.key = model.settings.voiceEditKey
        hotkey.isEnabled = model.settings.voiceEditAvailability.backend != nil
    }

    /// Живой текст распознавания команды; true — событие наше.
    func partial(session: String, text: String) -> Bool {
        guard let current, current.id == session else { return false }
        if !text.isEmpty, model.voiceEdit.phase == .listening {
            let joined = text.hasPrefix(model.voiceEdit.command) || model.voiceEdit.command.isEmpty
                ? text : model.voiceEdit.command + " " + text
            model.voiceEdit.command = joined
        }
        return true
    }

    // MARK: жест

    private func gesture(_ effect: VoiceEditGesture.Effect) {
        switch effect {
        case .begin: begin()
        case .finish: Task { await finish() }
        case .abort: abort()
        }
    }

    private func begin() {
        guard !isActive, let backend = model.settings.voiceEditAvailability.backend else { return }
        guard !isDictationBusy(), !model.isMeetingRecording else { return }
        let front = inspector.current(agentCLIs: model.settings.agentPolicy.agentCLIs)
        let id = "edit-" + UUID().uuidString.lowercased()
        var edit = Edit(id: id, bundleID: front.bundleID, wav: recordings.appendingPathComponent("\(id).wav"),
                        backend: backend, language: model.settings.language)
        isActive = true
        hideTask?.cancel()
        model.voiceEdit.reset()

        // Приватность: в менеджере паролей и других исключённых приложениях выделение не читаем.
        let excluded = VoiceEditSelection.isExcluded(bundleID: front.bundleID, settings: model.settings.polish.context)
        switch VoiceEditSelection.plan(probe: reader.probe(), secureInput: reader.secureInput, excludedApp: excluded) {
        case .refuse(let failure):
            // Отказ показываем сразу, запись не начинаем; отпускание клавиши его не перебьёт.
            edit.refused = true
            current = edit
            fail(failure)
            return
        case .use(let text):
            edit.selection = text
        case .copyFallback:
            edit.selection = nil
        }
        guard Permissions.microphoneAuthorized else {
            edit.refused = true
            current = edit
            fail(.noMicrophone)
            return
        }
        let engine = self.engine()
        recorder.onPCM = { pcm in engine.sendAudio(session: id, pcm: pcm) }
        // Команда — короткая фраза: без проверяющей, словаря проекта и полировки.
        engine.startSession(id, language: edit.language, project: nil, verify: false, agent: false)
        do { try recorder.begin(to: edit.wav) } catch {
            engine.cancel(session: id)
            edit.refused = true
            current = edit
            fail(.engine, detail: error.localizedDescription)
            return
        }
        current = edit
        model.voiceEdit.selectionLength = edit.selection?.count ?? 0
        model.voiceEdit.phase = .listening
        model.levels = Array(repeating: 0, count: model.levels.count)
        model.elapsed = 0
        model.hud = .recording
    }

    private func abort() {
        guard let edit = current else { isActive = false; return }
        current = nil
        isActive = false
        if edit.refused { return }  // отказ уже на экране и спрячется сам
        recorder.discard()
        engine().cancel(session: edit.id)
        try? FileManager.default.removeItem(at: edit.wav)
        model.voiceEdit.reset()
        model.hud = .hidden
    }

    private func finish() async {
        guard var edit = current else { isActive = false; return }
        if edit.refused { current = nil; isActive = false; return }
        let file = recorder.end()
        if let file { try? FileManager.default.removeItem(at: file.url) }
        let engine = self.engine()
        model.voiceEdit.phase = .working
        model.hud = .transcribing

        if edit.selection == nil {
            // Клавиша уже отпущена: синтетический ⌘C не смешается с удержанием правого ⌘.
            switch await reader.copySelection() {
            case .use(let text):
                edit.selection = text
                model.voiceEdit.selectionLength = text.count
            case .refuse(let failure):
                engine.cancel(session: edit.id)
                done(edit, failure: failure)
                return
            case .copyFallback:
                engine.cancel(session: edit.id)
                done(edit, failure: .noSelection)
                return
            }
        }
        guard let selection = edit.selection else { return }

        let reply: VoiceEditReply
        do {
            reply = try await engine.voiceEdit(session: edit.id, selection: selection, language: edit.language,
                                               backend: edit.backend)
        } catch {
            let failure: VoiceEditFailure
            if case EngineError.timeout = error { failure = .timeout } else { failure = .engine }
            done(edit, failure: failure, detail: error.localizedDescription)
            return
        }
        if !reply.command.isEmpty { model.voiceEdit.command = reply.command }
        guard let replacement = reply.replacement else {
            done(edit, failure: reply.failure ?? .engine, detail: reply.detail)
            return
        }
        // Вставка поверх выделения и есть замена: ⌘Z приложения вернёт исходный текст.
        let outcome = await paster.insert(text: replacement, expectedBundleID: edit.bundleID)
        switch outcome {
        case .inserted:
            done(edit, failure: nil)
        case .clipboard(let reason):
            done(edit, failure: reason == "focus_changed" ? .focusChanged : .noAccessibility)
        case .secureInput:
            done(edit, failure: .secureInput)
        case .failed(let message):
            paster.write(replacement)
            done(edit, failure: .pasteFailed, detail: message)
        }
    }

    // MARK: итог

    private func done(_ edit: Edit, failure: VoiceEditFailure?, detail: String = "") {
        guard current?.id == edit.id else { return }
        current = nil
        isActive = false
        if let failure {
            fail(failure, detail: detail)
        } else {
            model.voiceEdit.phase = .done
            model.hud = .done(summary: L10nShim.replaced, doubts: 0, agent: false)
            scheduleHide(after: 1.6)
        }
    }

    private func fail(_ failure: VoiceEditFailure, detail: String = "") {
        if !detail.isEmpty { NSLog("Mostik voice edit \(failure.rawValue): \(detail)") }
        model.voiceEdit.detail = detail
        model.voiceEdit.phase = .failed(failure)
        model.hud = .error(VoiceEditModel.message(failure))
        if current?.refused == true { isActive = false }
        scheduleHide(after: 2.5)
    }

    private func scheduleHide(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.isActive else { return }
            switch self.model.voiceEdit.phase {
            case .done, .failed:
                self.model.voiceEdit.reset()
                self.model.hud = .hidden
            default: break
            }
        }
    }
}

/// Подпись итога в `model.hud` (её видит строка меню-бара; пилюлю рисует `VoiceEditPill`).
private enum L10nShim {
    static var replaced: String { L10n.isRussian ? "Заменено" : "Replaced" }
}
