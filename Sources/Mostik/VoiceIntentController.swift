import AppKit
import Foundation
import SwiftUI
import MostikCore
import MostikKit
import MostikUI

/// Голосовые команды-намерения (D6): ⌃⌘K → диктовка → разбор движком → карточка над HUD →
/// черновик в Календаре (`.ics`) или Почте (`mailto:`). Пользователь сам сохраняет событие
/// и отправляет письмо: Mostik ничего не создаёт и не отправляет, EventKit и Контакты не трогает.
///
/// Решения — `MostikCore/VoiceIntent.swift`; `AppController` зовёт `consumeArmed()` на старте
/// записи и `handle(text:language:)` перед вставкой.
@MainActor
final class VoiceIntentController {
    private let model: AppModel
    private let engine: () -> EngineClient
    /// Карточка в HUD: заголовок и подпись.
    var notice: (String, String) -> Void = { _, _ in }

    private var intent: VoiceIntentModel { model.voiceIntent }
    private var draft: VoiceIntentDraft?
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    /// Сколько карточка ждёт ответа; без ответа — как «Отмена».
    private let cardSeconds: Double = 30

    init(model: AppModel, engine: @escaping () -> EngineClient) {
        self.model = model
        self.engine = engine
        model.voiceIntent.onOpen = { [weak self] in self?.open() }
        model.voiceIntent.onCancel = { [weak self] in self?.dismiss() }
    }

    // MARK: ⌃⌘K

    func hotkey() {
        let ru = L10n.isRussian
        guard model.settings.voiceIntents.enabled else {
            intent.armed = false
            notice(ru ? "Действия голосом выключены" : "Voice actions are off",
                   ru ? "Включите их в Настройках → Текст" : "Turn them on in Settings → Text")
            return
        }
        intent.armed.toggle()
        if intent.armed {
            notice(ru ? "Следующая диктовка — команда" : "Next dictation is a command",
                   ru ? "«создай встречу завтра в три» · ⌃⌘K — отмена" : "“meeting tomorrow at three” · ⌃⌘K to cancel")
        } else {
            notice(ru ? "Отменено" : "Cancelled", ru ? "Следующая диктовка — как обычно" : "Next dictation as usual")
        }
    }

    /// Старт записи: взведённый режим уходит этой диктовке и сбрасывается.
    func consumeArmed() -> Bool {
        defer { intent.armed = false }
        return intent.armed && model.settings.voiceIntents.enabled
    }

    func settingsChanged() {
        if !model.settings.voiceIntents.enabled { intent.armed = false }
    }

    // MARK: разбор

    /// Текст команды готов. true — показана карточка, вставлять текст не нужно; false — ниже порога
    /// или движок не ответил: обычная вставка.
    func handle(text: String, language: String) async -> Bool {
        let settings = model.settings
        let reply: VoiceIntentReply
        do {
            reply = try await engine().voiceIntent(text: text, language: language,
                                                   backend: settings.polish.effectiveBackend)
        } catch {
            NSLog("Mostik: команда не разобрана — \(error.localizedDescription)")
            return false
        }
        switch VoiceIntentPlan.decide(reply, threshold: settings.voiceIntents.threshold) {
        case .insertText:
            return false
        case .preview(let draft):
            show(draft)
            return true
        }
    }

    // MARK: карточка

    private func show(_ draft: VoiceIntentDraft) {
        self.draft = draft
        intent.card = VoiceIntentModel.Card(draft)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
        hideTask?.cancel()
        hideTask = Task { [weak self, cardSeconds] in
            try? await Task.sleep(nanoseconds: UInt64(cardSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func dismiss() {
        hideTask?.cancel()
        draft = nil
        intent.card = nil
        panel?.orderOut(nil)
    }

    /// «Открыть»: черновик в Календаре или Почте. Дальше — решение пользователя.
    private func open() {
        guard let draft else { dismiss(); return }
        dismiss()
        let ru = L10n.isRussian
        switch draft {
        case .event(let event):
            // П10 р5 Р5-4л: своя папка с префиксом Mostik; прошлые черновики старше 10 минут — убрать.
            let temp = FileManager.default.temporaryDirectory
            StorageHygiene.cleanStaleTemp(in: temp, only: [VoiceIntentICS.draftPrefix])
            let folder = VoiceIntentICS.draftFolder(in: temp)
            let file = folder.appendingPathComponent(VoiceIntentICS.fileName(event))
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try VoiceIntentICS.render(event).write(to: file, atomically: true, encoding: .utf8)
            } catch {
                notice(ru ? "Черновик не сохранился" : "Couldn’t save the draft", error.localizedDescription)
                return
            }
            // Календарь спросит, в какой календарь добавить: без подтверждения событие не появится.
            if let calendar = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
                NSWorkspace.shared.open([file], withApplicationAt: calendar, configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(file)
            }
        case .mail(let mail):
            guard let url = mail.draft.mailtoURL else {
                notice(ru ? "Черновик не открылся" : "Couldn’t open the draft", "mailto")
                return
            }
            NSWorkspace.shared.open(url)
        }
    }

    private func makePanel() -> NSPanel {
        let size = VoiceIntentCardView.size
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        let host = NSHostingView(rootView: VoiceIntentCardView(intent: model.voiceIntent).tint(Palette.accent))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        return panel
    }

    /// Над пилюлей диктовки, снизу по центру экрана с курсором.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = VoiceIntentCardView.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 40 + 44 + 8))
    }
}
