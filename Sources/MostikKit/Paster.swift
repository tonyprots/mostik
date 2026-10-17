import AppKit
import ApplicationServices
import Carbon.HIToolbox
import MostikCore

/// Чем закончилась вставка.
public enum PasteOutcome: Equatable, Sendable {
    case inserted
    /// Текст оставлен в буфере: "focus_changed" | "no_accessibility".
    case clipboard(reason: String)
    /// Включён Secure Input (поле пароля) — вставки нет, буфер не трогали.
    case secureInput
    case failed(String)

    /// Значение поля `outcome` в истории.
    public var historyValue: String {
        switch self {
        case .inserted: return "inserted"
        case .clipboard: return "clipboard"
        case .secureInput: return "secure_input"
        case .failed: return "failed"
        }
    }
}

/// Итог доставки диктовки (R1–R3): что сделали, дошло ли и каким стало поле.
public struct DeliveryReport: Sendable {
    public var outcome: PasteOutcome
    /// nil — вставки не было (буфер, пароль), проверять нечего.
    public var check: PasteCheck?
    /// Поле перед вставкой и после неё — для отката (R4).
    public var before: FieldSnapshot?
    public var after: FieldState?
    /// Что ушло в поле: с пробелом на стыке.
    public var sent: String

    /// Отчёт не от `deliver`: потоковая вставка (P6) и очередь агенту (A6).
    public init(outcome: PasteOutcome, check: PasteCheck? = nil, before: FieldSnapshot? = nil, after: FieldState? = nil,
                sent: String) {
        self.outcome = outcome; self.check = check; self.before = before; self.after = after; self.sent = sent
    }
}

/// Вставка без гонки буфера (§6, §12.11): снимок → текст → Cmd+V →
/// восстановление через 600 мс, только если буфер с тех пор никто не менял.
/// Временная запись помечена Transient/Concealed — менеджеры буфера её не сохраняют (R3).
@MainActor
public final class Paster {
    public var restoreDelay: TimeInterval = 0.6
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    /// `expectedBundleID` — приложение, которое было впереди в начале записи.
    public func insert(text: String, expectedBundleID: String?) async -> PasteOutcome {
        if IsSecureEventInputEnabled() { return .secureInput }

        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let expected = expectedBundleID, !expected.isEmpty, front != expected {
            write(text)
            return .clipboard(reason: "focus_changed")
        }
        // AXIsProcessTrusted оживает сразу после выдачи доступа, а право слать нажатия
        // процесс получает только после перезапуска: без этой проверки Cmd+V уходил в никуда.
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            write(text)
            return .clipboard(reason: "no_accessibility")
        }

        let snapshot = takeSnapshot()
        let ourChange = writeTransient(text)
        guard postCommandV() else {
            return .failed("cgevent")
        }
        try? await Task.sleep(nanoseconds: UInt64(restoreDelay * 1_000_000_000))
        // Буфер поменялся после нас — он уже чужой, не трогаем.
        if pasteboard.changeCount == ourChange { restore(snapshot) }
        return .inserted
    }

    /// Положить текст в буфер; возвращает changeCount после записи.
    @discardableResult
    public func write(_ text: String) -> Int {
        // П10: запасная запись для ⌘V руками — с TransientType, менеджеры буфера её не сохраняют.
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        for marker in ClipboardPrivacy.fallbackMarkers { item.setData(Data(), forType: NSPasteboard.PasteboardType(marker)) }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        return pasteboard.changeCount
    }

    /// Доставка диктовки (R1–R3): снимок поля → решение → ⌘V → два перечитывания поля.
    /// Только ⌘V и никакой AX-записи — так одинаково для Cocoa, Electron и Gecko.
    /// `start` — снимок поля в начале записи; `expectedBundleID` nil — не сверять приложение (H3).
    /// `onPosted` — ⌘V ушёл (замер `paste.posted`; шаг 1, п. 3 — машина свободна, дальше проверка в фоне).
    public func deliver(text: String, expectedBundleID: String?, start: FieldSnapshot?,
                        onPosted: (() -> Void)? = nil) async -> DeliveryReport {
        let canPost = AXIsProcessTrusted() && CGPreflightPostEventAccess()
        let now = FocusedField.snapshot()
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let decision = DeliveryPlanner.decide(text: text, start: start, now: now, expectedBundleID: expectedBundleID,
                                              frontBundleID: front, secureInput: IsSecureEventInputEnabled(), canPost: canPost)
        switch decision {
        case .secureField:
            return DeliveryReport(outcome: .secureInput, before: now, sent: text)
        case .clipboard(let reason):
            write(text)
            return DeliveryReport(outcome: .clipboard(reason: reason.rawValue), before: now, sent: text)
        case .paste(let sent):
            let snapshot = takeSnapshot()
            let ourChange = writeTransient(sent)
            guard postCommandV() else {
                write(text)
                return DeliveryReport(outcome: .failed("cgevent"), before: now, sent: sent)
            }
            onPosted?()
            // Дважды перечитать поле: в Electron и вебе вставка доходит не сразу (R2).
            try? await Task.sleep(nanoseconds: 150_000_000)
            let first = FocusedField.state()
            try? await Task.sleep(nanoseconds: 300_000_000)
            let second = FocusedField.state()
            let before = now?.state
            let check = PasteVerifier.combine(PasteVerifier.judge(before: before, after: first, text: sent),
                                              PasteVerifier.judge(before: before, after: second, text: sent))
            let rest = max(0, restoreDelay - 0.45)
            try? await Task.sleep(nanoseconds: UInt64(rest * 1_000_000_000))
            if check == .notInserted {
                // Не дошло: текст остаётся в буфере уже обычной записью, чтобы вставить руками.
                if pasteboard.changeCount == ourChange { write(text) }
                return DeliveryReport(outcome: .clipboard(reason: DeliveryReason.notInserted.rawValue), check: check,
                                      before: now, after: second ?? first, sent: sent)
            }
            if pasteboard.changeCount == ourChange { restore(snapshot) }
            return DeliveryReport(outcome: .inserted, check: check, before: now, after: second ?? first, sent: sent)
        }
    }

    /// Выделить назад `count` знаков (Shift+←) — потоковая вставка заменяет вставленные куски
    /// итогом (P6). Решает, можно ли, `StreamInsert.canReplace`.
    @discardableResult
    public func selectBackward(_ count: Int) -> Bool {
        guard count > 0, AXIsProcessTrusted(), CGPreflightPostEventAccess() else { return false }
        let source = CGEventSource(stateID: .privateState)
        let left = CGKeyCode(kVK_LeftArrow)
        for _ in 0..<count {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: left, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: left, keyDown: false) else { return false }
            down.flags = .maskShift
            up.flags = .maskShift
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(2_000)
        }
        return true
    }

    /// ⌘Z приложения (R4). Решает, можно ли, `RevertPlanner`.
    @discardableResult
    public func undo() -> Bool { postCommand(key: CGKeyCode(kVK_ANSI_Z)) }

    /// Временная запись для ⌘V: nspasteboard.org Transient + Concealed — Maccy, Paste, Raycast
    /// и прочие менеджеры буфера её не сохраняют.
    @discardableResult
    public func writeTransient(_ text: String) -> Int {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: Self.transientType)
        item.setData(Data(), forType: Self.concealedType)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        return pasteboard.changeCount
    }

    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

    private func takeSnapshot() -> Snapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            var types: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { types[type] = data } }
            return types
        }
    }

    private func restore(_ snapshot: Snapshot) {
        pasteboard.clearContents()
        // П10: пароль из менеджера (Concealed/Transient) не возвращаем — иначе он «перезаряжается»
        // и автоочистка менеджера по changeCount уже не сработает. Буфер остаётся пустым.
        guard !snapshot.isEmpty, ClipboardPrivacy.restorable(snapshot.map { $0.keys.map(\.rawValue) }) else { return }
        let items = snapshot.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }

    /// Cmd+V через CGEvent: ⌘ вниз, V, ⌘ вверх — как с клавиатуры; Chromium и Electron
    /// иначе могут не принять одиночную V с флагом. Флаги заданы явно, чтобы зажатый ⌥
    /// не превратил вставку в ⌥⌘V; свой источник состояния не тянет чужие модификаторы.
    private func postCommandV() -> Bool { postCommand(key: CGKeyCode(kVK_ANSI_V)) }

    private func postCommand(key: CGKeyCode) -> Bool {
        let source = CGEventSource(stateID: .privateState)
        let command = CGKeyCode(kVK_Command)
        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: true),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: false) else { return false }
        cmdDown.flags = .maskCommand
        down.flags = .maskCommand
        up.flags = .maskCommand
        cmdUp.flags = []
        for event in [cmdDown, down, up, cmdUp] {
            event.post(tap: .cghidEventTap)
            usleep(8_000)
        }
        return true
    }
}
