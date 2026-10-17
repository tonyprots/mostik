import AppKit
import Carbon.HIToolbox

/// Сочетания доставки (H2, H3, R4, A7) — отдельно от клавиш записи в `HotkeyMonitor`.
///
/// - ⌃⌘V — вставить последнюю диктовку ещё раз (H3);
/// - ⌃⌘Z — откатить последнюю вставку (R4);
/// - ⌃⌘R — заменить последнюю вставку сырой расшифровкой (R4);
/// - ⌃⌘Y — следующий стиль причёсывания по кругу, с пакетами (P4);
/// - ⌃⌘E — следующую диктовку перевести (V3), ⌃⌘J — оформить задачей (A4);
/// - ⌃⌘K — следующая диктовка — команда: черновик события, напоминания или письма (D6);
/// - Esc — отмена расшифровки и вставки, а сразу после вставки — откат (H2, A7).
///   Во время записи Esc ловит `HotkeyMonitor`; здесь он работает, только пока контроллер его взвёл.
///
/// ⌃⌘ с этими буквами не занят ни macOS, ни стандартными меню приложений; ⌃⌥ занят VoiceOver.
@MainActor
public final class DeliveryHotkeys {
    public enum Event: Equatable, Sendable { case escape, pasteLast, undoLast, replaceWithRaw, cycleStyle, translateNext, taskNext, intentNext }

    /// Esc значит «отмена»: идёт расшифровка или вставка.
    public var escapeArmed = false
    /// И ещё немного после вставки — «верни как было» (A7).
    public var escapeArmedUntil: Date?

    private let handler: (Event) -> Void
    private var monitors: [Any] = []
    private var hotKeys: [EventHotKeyRef] = []
    private var carbonHandler: EventHandlerRef?
    /// 'MOSD' — своя подпись, чтобы не путать с переключателем ⌥Space (`HotkeyMonitor`).
    static let signature = OSType(0x4D4F5344)
    private static let bindings: [(id: UInt32, key: Int, event: Event)] = [
        (1, kVK_ANSI_V, .pasteLast),
        (2, kVK_ANSI_Z, .undoLast),
        (3, kVK_ANSI_R, .replaceWithRaw),
        (4, kVK_ANSI_Y, .cycleStyle),
        (5, kVK_ANSI_E, .translateNext),
        (6, kVK_ANSI_J, .taskNext),
        (7, kVK_ANSI_K, .intentNext),
    ]

    public init(handler: @escaping (Event) -> Void) { self.handler = handler }

    public func start() {
        guard monitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.keyDown(event) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.keyDown(event) }
            return event
        }) { monitors.append(local) }
        installCarbonHandler()
        for binding in Self.bindings {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: binding.id)
            if RegisterEventHotKey(UInt32(binding.key), UInt32(controlKey | cmdKey), id, GetApplicationEventTarget(), 0, &ref) == noErr,
               let ref { hotKeys.append(ref) }
        }
    }

    public func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys.removeAll()
        if let carbonHandler { RemoveEventHandler(carbonHandler) }
        carbonHandler = nil
    }

    private var isEscapeArmed: Bool {
        escapeArmed || (escapeArmedUntil.map { Date() < $0 } ?? false)
    }

    private func keyDown(_ event: NSEvent) {
        guard event.keyCode == UInt16(kVK_Escape), isEscapeArmed else { return }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty else { return }
        escapeArmedUntil = nil
        handler(.escape)
    }

    private func installCarbonHandler() {
        guard carbonHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            // Чужие сочетания (⌥Space) отдаём дальше по цепочке обработчиков.
            guard status == noErr, id.signature == DeliveryHotkeys.signature,
                  let binding = DeliveryHotkeys.bindings.first(where: { $0.id == id.id }) else {
                return OSStatus(eventNotHandledErr)
            }
            let monitor = Unmanaged<DeliveryHotkeys>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.handler(binding.event) }
            return noErr
        }, 1, &spec, context, &carbonHandler)
    }
}
