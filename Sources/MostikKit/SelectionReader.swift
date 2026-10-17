import AppKit
import ApplicationServices
import Carbon.HIToolbox
import MostikCore

/// Чтение выделенного текста в приложении впереди (D5).
///
/// Основной путь — AX: `kAXSelectedTextAttribute` у элемента в фокусе, буфер не трогается.
/// Запасной — ⌘C со снимком буфера и его восстановлением, как в `Paster`: Chromium, Electron
/// и часть редакторов выделение через AX не отдают. Какой путь брать — `VoiceEditSelection`.
@MainActor
public final class SelectionReader {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    /// AX-проба выделения. Быстрая: таймаут обмена 0,25 с.
    public func probe() -> SelectionProbe {
        guard AXIsProcessTrusted() else { return .noAccess }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .unsupported }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String else { return .unsupported }
        return text.isEmpty ? .empty : .text(text)
    }

    public var secureInput: Bool { IsSecureEventInputEnabled() }

    /// Запасной путь: ⌘C, ждём смены буфера до `timeout`, читаем строку, возвращаем буфер как был.
    public func copySelection(timeout: TimeInterval = 0.4) async -> SelectionPlan {
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else { return .refuse(.noAccessibility) }
        let snapshot = takeSnapshot()
        let before = pasteboard.changeCount
        guard postCommandC() else { return .refuse(.noSelection) }
        let deadline = Date().addingTimeInterval(timeout)
        while pasteboard.changeCount == before, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let after = pasteboard.changeCount
        let text = after == before ? nil : pasteboard.string(forType: .string)
        // Буфер поменяли мы — возвращаем прежнее содержимое. Не поменялся — не трогаем вовсе.
        if after != before { restore(snapshot) }
        return VoiceEditSelection.copied(changeBefore: before, changeAfter: after, text: text)
    }

    // MARK: буфер

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
        // П10: пароль из менеджера (Concealed/Transient) не возвращаем — автоочистка менеджера должна сработать.
        guard !snapshot.isEmpty, ClipboardPrivacy.restorable(snapshot.map { $0.keys.map(\.rawValue) }) else { return }
        pasteboard.writeObjects(snapshot.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        })
    }

    /// ⌘C через CGEvent тем же способом, что ⌘V в `Paster`: свой источник состояния, флаги явно.
    private func postCommandC() -> Bool {
        let source = CGEventSource(stateID: .privateState)
        let command = CGKeyCode(kVK_Command)
        let key = CGKeyCode(kVK_ANSI_C)
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

/// Удержание клавиши правки (D5): правый ⌘ (keyCode 54), а если правый ⌘ держит запись —
/// правый ⌥ (keyCode 61). Какая клавиша — решает `HoldKeys.voiceEditKey` в MostikCore.
///
/// Свои мониторы NSEvent рядом с `HotkeyMonitor`: диктовка и правка не делят состояние.
/// Логика жеста — `VoiceEditGesture` в MostikCore: другая клавиша или щелчок за время
/// удержания — сочетание с ⌘, а не правка.
@MainActor
public final class VoiceEditHotkey {
    public var isEnabled = false {
        didSet { if !isEnabled, let effect = gesture.reset() { handler(effect) } }
    }

    /// `HoldKeys.rightCommand` или `HoldKeys.rightOption`. Смена клавиши посреди удержания прерывает жест.
    public var key: String = HoldKeys.rightCommand {
        didSet { if key != oldValue, let effect = gesture.reset() { handler(effect) } }
    }

    private let handler: (VoiceEditGesture.Effect) -> Void
    private var gesture = VoiceEditGesture()
    private var monitors: [Any] = []
    private static let rightCommandMask: UInt = 0x10  // NX_DEVICERCMDKEYMASK
    private static let rightOptionMask: UInt = 0x40   // NX_DEVICERALTKEYMASK

    private var keyCode: UInt16 { key == HoldKeys.rightOption ? UInt16(kVK_RightOption) : UInt16(kVK_RightCommand) }
    private var keyMask: UInt { key == HoldKeys.rightOption ? Self.rightOptionMask : Self.rightCommandMask }

    public init(handler: @escaping (VoiceEditGesture.Effect) -> Void) { self.handler = handler }

    public func start() {
        guard monitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.flagsChanged(event) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.flagsChanged(event) }
            return event
        }) { monitors.append(local) }
        let other: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: other, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.feed(.otherInput) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: other, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.feed(.otherInput) }
            return event
        }) { monitors.append(local) }
    }

    public func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let effect = gesture.reset() { handler(effect) }
    }

    private func flagsChanged(_ event: NSEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        guard event.keyCode == keyCode else {
            // Другой модификатор при зажатой клавише правки (⌘⇧, ⌘⌥) — тоже сочетание.
            if case .holding = gesture.state { feed(.otherInput) }
            return
        }
        let down = event.modifierFlags.rawValue & keyMask != 0
        feed(down ? .commandDown(at: now) : .commandUp(at: now))
    }

    private func feed(_ input: VoiceEditGesture.Input) {
        guard isEnabled || gesture.state != .idle else { return }
        if case .commandDown = input, !isEnabled { return }
        if let effect = gesture.handle(input) { handler(effect) }
    }
}

extension EngineClient {
    /// `edit` → `edit_done` (D5). Таймаут: распознавание команды + собственный таймаут LLM 30 с + запуск.
    public func voiceEdit(session: String, selection: String, language: String, backend: PolishBackend,
                          timeout: TimeInterval = 50) async throws -> VoiceEditReply {
        let payload = try await request("edit", fields: [
            "session": .string(session), "selection": .string(selection),
            "language": .string(language), "backend": .string(backend.rawValue),
        ], timeout: timeout)
        return VoiceEditReply(payload: payload)
    }
}
