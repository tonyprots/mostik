import AppKit
import Foundation
import MostikCore
import MostikKit
import MostikUI

/// Надёжная доставка (R1–R4, H2, H3, A7): вставка с проверкой, откат, повтор, Esc.
///
/// Решения принимает `MostikCore/Delivery.swift`; здесь — только связка с `Paster`,
/// AX-чтением поля и HUD. Машиной диктовки владеет `AppController`: Esc сначала
/// предлагается ей (`escapeToMachine`), и только в покое он откатывает свежую вставку.
@MainActor
final class DeliveryController {
    enum RevertMode { case undo, replaceWithRaw, cancel }

    private let model: AppModel
    private let paster: Paster
    private var hotkeys: DeliveryHotkeys!
    private var hideTask: Task<Void, Never>?
    /// Последняя вставка, которую можно откатить.
    private(set) var last: InsertionRecord?

    /// Esc для машины диктовки: true — он ей пригодился (шла расшифровка, вставка, ошибка).
    var escapeToMachine: () -> Bool = { false }
    /// Идёт запись или голосовая правка — сочетания доставки молчат.
    var isBusy: () -> Bool = { false }
    var replaceEntry: (HistoryEntry) -> Void = { _ in }
    /// Вставка дошла: обучение на правках (L1) и «Запомнить написание» (L2).
    var onInserted: (InsertionRecord) -> Void = { _ in }
    /// ⌃⌘Y, ⌃⌘E, ⌃⌘J — стиль по кругу и разовые режимы причёсывания (P4, V3, A4).
    var onPolishHotkey: (DeliveryHotkeys.Event) -> Void = { _ in }
    /// ⌃⌘K — следующая диктовка — команда-намерение (D6).
    var onIntentHotkey: () -> Void = {}

    init(model: AppModel, paster: Paster) {
        self.model = model
        self.paster = paster
        hotkeys = DeliveryHotkeys { [weak self] event in self?.hotkey(event) }
    }

    func start() { hotkeys.start() }
    func stop() { hotkeys.stop() }
    func restart() { hotkeys.stop(); hotkeys.start() }

    /// Esc взведён, пока идёт расшифровка или вставка.
    var escapeArmed: Bool {
        get { hotkeys.escapeArmed }
        set { hotkeys.escapeArmed = newValue }
    }

    /// Началась новая запись: Esc теперь её, а не отката.
    func recordingBegan() { hotkeys.escapeArmedUntil = nil }

    // MARK: вставка

    /// Вставить и запомнить для отката. `raw` — исходник для замены и буфера.
    func deliver(text: String, raw: String, entryID: String, expectedBundleID: String?,
                 start: FieldSnapshot?, onPosted: (() -> Void)? = nil) async -> DeliveryReport {
        // Шаг 1, п. 3: машина свободна сразу после ⌘V, и следующая вставка может прийти, пока
        // прошлая ещё проверяет поле и возвращает буфер. Вставки идут строго по очереди.
        let previous = tail
        let paster = self.paster
        let task = Task { @MainActor in
            await previous?.value
            return await paster.deliver(text: text, expectedBundleID: expectedBundleID, start: start, onPosted: onPosted)
        }
        tail = Task { _ = await task.value }
        let report = await task.value
        remember(report, entryID: entryID, raw: raw)
        return report
    }
    private var tail: Task<Void, Never>?

    private func remember(_ report: DeliveryReport, entryID: String, raw: String) {
        guard report.outcome == .inserted, let field = report.before else { return }
        let check = report.check ?? .unknown
        last = InsertionRecord(entryID: entryID, bundleID: field.bundleID, elementToken: field.elementToken,
                               engine: field.engine, before: field.state, after: report.after,
                               insertedText: report.sent, rawText: raw, check: check)
        // A7: сразу после вставки Esc значит «верни как было».
        hotkeys.escapeArmedUntil = Date().addingTimeInterval(RevertPlanner.escapeWindow)
        if let last { onInserted(last) }
    }

    // MARK: сочетания

    private func hotkey(_ event: DeliveryHotkeys.Event) {
        switch event {
        case .escape:
            let toMachine = escapeToMachine()
            AppLog.shared.event("keys", "esc delivery toMachine=\(toMachine)")
            if toMachine { return }
            guard !isBusy(), RevertPlanner.escapeReverts(last) else { return }
            Task { await revert(.undo) }
        case .pasteLast:
            guard !isBusy() else { return }
            Task { await pasteLast() }
        case .undoLast:
            guard !isBusy() else { return }
            Task { await revert(.undo) }
        case .replaceWithRaw:
            guard !isBusy() else { return }
            Task { await revert(.replaceWithRaw) }
        case .cycleStyle, .translateNext, .taskNext:
            onPolishHotkey(event)
        case .intentNext:
            onIntentHotkey()
        }
    }

    /// H3: последняя диктовка ещё раз — туда, где сейчас курсор.
    func pasteLast() async {
        guard let entry = RecentDictations.lastWithText(model.history) else {
            notice(t("Нечего вставлять", "Nothing to paste"), t("Истории за сутки нет", "No dictations yet"))
            return
        }
        // Впереди сам Mostik (пункт меню, окно истории) — вставлять некуда, кладём в буфер.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier {
            paster.write(entry.text)
            notice(t("Текст в буфере", "Text on clipboard"), t("Вставьте ⌘V там, где нужно", "Paste with ⌘V where you need it"))
            return
        }
        let report = await deliver(text: entry.text, raw: entry.rawText ?? entry.text, entryID: entry.id,
                                   expectedBundleID: nil, start: nil)
        show(report, summary: t("Вставлено ещё раз", "Pasted again"))
    }

    /// R4 и A7: откатить последнюю вставку, при желании — вставить вместо неё сырую расшифровку.
    /// Поле изменили, сменили или не прочитать — не трогаем его, исходник в буфер.
    func revert(_ mode: RevertMode) async {
        let record = last
        let current = FocusedField.snapshot()
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        switch RevertPlanner.plan(record, current: current, frontBundleID: front) {
        case .nothing:
            if mode != .cancel { notice(t("Отменять нечего", "Nothing to undo"), t("Последняя вставка не найдена", "No recent insertion")) }
        case let .clipboard(text, reason):
            paster.write(text)
            if mode == .cancel { mark(record, outcome: "cancelled") }
            notice(refusalTitle(reason), t("Исходник в буфере · ⌘V", "Original on clipboard · ⌘V"))
        case .undo:
            guard let record else { return }
            paster.undo()
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard RevertPlanner.undoWorked(before: record.before, now: FocusedField.state()) else {
                paster.write(record.rawText.isEmpty ? record.insertedText : record.rawText)
                last = nil
                notice(t("Вставку не удалось отменить", "Undo didn't work"), t("Исходный текст в буфере · ⌘V", "Original on clipboard · ⌘V"))
                return
            }
            last = nil
            switch mode {
            case .undo:
                mark(record, outcome: "undone")
                done(t("Вставка отменена", "Insertion undone"))
            case .cancel:
                mark(record, outcome: "cancelled")
                notice(t("Отменено", "Cancelled"), t("Текст сохранён в истории", "Text kept in history"))
            case .replaceWithRaw:
                let raw = record.rawText.isEmpty ? record.insertedText : record.rawText
                let report = await deliver(text: raw, raw: raw, entryID: record.entryID, expectedBundleID: record.bundleID,
                                           start: nil)
                if report.outcome == .inserted, var entry = model.history.first(where: { $0.id == record.entryID }) {
                    entry.insertedText = report.sent
                    entry.pasteCheck = report.check?.rawValue
                    replaceEntry(entry)
                }
                show(report, summary: t("Заменено текстом как сказано", "Replaced with text as spoken"))
            }
        }
    }

    private func mark(_ record: InsertionRecord?, outcome: String) {
        guard let record, var entry = model.history.first(where: { $0.id == record.entryID }) else { return }
        entry.outcome = outcome
        replaceEntry(entry)
    }

    private func refusalTitle(_ reason: RevertRefusal) -> String {
        switch reason {
        case .expired: t("Вставка уже давняя", "Insertion is too old")
        case .focusChanged: t("Курсор в другом поле", "Cursor is in another field")
        case .fieldChanged: t("Поле уже изменилось", "Field has changed")
        case .unreadable: t("Поле не прочитать", "Can't read the field")
        }
    }

    // MARK: HUD

    /// Итог повторной вставки или замены: как у обычной диктовки, без счётчика сомнений.
    func show(_ report: DeliveryReport, summary: String) {
        switch report.outcome {
        case .inserted: done(summary)
        case .clipboard(let reason): notice(clipboardTitle(reason), t("Текст в буфере · ⌘V", "Text on clipboard · ⌘V"))
        case .secureInput: notice(t("Защищённое поле", "Secure field"), t("В поля паролей Mostik не вставляет · текст не сохранён", "Mostik won't type into passwords · text not kept"))
        case .failed: notice(t("Текст не вставлен", "Text not inserted"), t("Текст в буфере · ⌘V", "Text on clipboard · ⌘V"))
        }
    }

    func clipboardTitle(_ reason: String) -> String {
        switch DeliveryReason(rawValue: reason) {
        case .focusChanged: t("Окно сменилось", "Window changed")
        case .notEditable: t("Курсор не в текстовом поле", "Cursor isn't in a text field")
        case .notInserted: t("Текст не вставлен", "Text not inserted")
        case .noAccessibility, .none: t("Нужен Универсальный доступ", "Needs Accessibility")
        }
    }

    func notice(_ title: String, _ detail: String) {
        let phase = AppModel.HUDPhase.notice(title: title, detail: detail)
        model.hud = phase
        hide(phase, after: 3)
    }

    private func done(_ summary: String) {
        let phase = AppModel.HUDPhase.done(summary: summary, doubts: 0, agent: false)
        model.hud = phase
        hide(phase, after: 1.4)
    }

    /// Прячем только свою карточку: если началась запись, HUD уже не наш.
    private func hide(_ phase: AppModel.HUDPhase, after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.model.hud == phase else { return }
            self.model.hud = .hidden
        }
    }

    private func t(_ ru: String, _ en: String) -> String { L10n.isRussian ? ru : en }
}
