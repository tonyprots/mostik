import AppKit
import Carbon.HIToolbox
import MostikCore

/// Клавиши диктовки (§12.5): удержание правого ⌥ (или правого ⌘, или fn),
/// ⌥Space — переключатель через Carbon, Esc — отмена во время записи.
@MainActor
public final class HotkeyMonitor {
    public enum Event: Equatable, Sendable { case holdBegan, holdEnded, togglePressed, cancel, latch }

    /// "rightOption" | "rightCommand" | "fn"
    public var holdKey: String = "rightOption" { didSet { gesture.reset() } }
    /// Защёлка (H4): модификатор во время удержания — запись без рук.
    public var latchEnabled: Bool {
        get { gesture.latchEnabled }
        set { gesture.latchEnabled = newValue }
    }
    public var toggleEnabled: Bool = true { didSet { if isStarted { registerToggle() } } }
    /// Контроллер сообщает, идёт ли запись: только тогда Esc отменяет.
    public var isRecording = false

    private let handler: (Event) -> Void
    private var monitors: [Any] = []
    /// Удержание, тап, ⌥+буква и защёлка (H1, H4) — чистая логика в MostikCore.
    private var gesture = HoldGesture()
    /// Прошлые аппаратные флаги модификаторов: по ним видно, какой модификатор добавился.
    private var lastDeviceFlags: UInt = 0
    private var hotKeyRef: EventHotKeyRef?
    private var carbonHandler: EventHandlerRef?
    private var isStarted = false

    // Аппаратно-зависимые биты NSEvent.modifierFlags (NX_DEVICE*KEYMASK).
    /// Подпись своего хоткея (четыре буквы 'MSTK'): по ней чужие сочетания отдаются дальше.
    static let signature: OSType = 0x4D53_544B
    private static let rightOptionMask: UInt = 0x40
    private static let rightCommandMask: UInt = 0x10

    public init(handler: @escaping (Event) -> Void) { self.handler = handler }

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.flagsChanged(event) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.flagsChanged(event) }
            return event
        }) { monitors.append(local) }
        if let keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.keyDown(event) }
        }) { monitors.append(keys) }
        if let localKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.keyDown(event) }
            return event
        }) { monitors.append(localKeys) }
        installCarbonHandler()
        registerToggle()
    }

    public func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        unregisterToggle()
        if let carbonHandler { RemoveEventHandler(carbonHandler) }
        carbonHandler = nil
        isStarted = false
        gesture.reset()
    }

    // MARK: удержание

    private var holdKeyCode: UInt16 {
        switch holdKey {
        case "rightCommand": return UInt16(kVK_RightCommand)  // 54
        case "fn": return UInt16(kVK_Function)               // 63
        default: return UInt16(kVK_RightOption)              // 61
        }
    }

    private func isHoldDown(_ flags: NSEvent.ModifierFlags) -> Bool {
        switch holdKey {
        case "rightCommand": return flags.rawValue & Self.rightCommandMask != 0
        case "fn": return flags.contains(.function)
        default: return flags.rawValue & Self.rightOptionMask != 0
        }
    }

    // Аппаратные биты остальных модификаторов (NX_DEVICE*KEYMASK): ⌃ 0x1/0x2000, ⇧ 0x2/0x4,
    // ⌘ 0x8/0x10, ⌥ 0x20/0x40. Свою клавишу из маски исключаем.
    private var otherModifiersMask: UInt {
        let all: UInt = 0x1 | 0x2000 | 0x2 | 0x4 | 0x8 | 0x10 | 0x20 | 0x40
        switch holdKey {
        case "rightCommand": return all & ~Self.rightCommandMask
        case "fn": return all
        default: return all & ~Self.rightOptionMask
        }
    }

    private func flagsChanged(_ event: NSEvent) {
        let other = event.modifierFlags.rawValue & otherModifiersMask
        let added = other & ~lastDeviceFlags
        lastDeviceFlags = other
        if event.keyCode == holdKeyCode {
            let down = isHoldDown(event.modifierFlags)
            let wasRecording = isRecording
            run(gesture.handle(down ? .holdDown(otherModifiers: other != 0) : .holdUp))
            if down {
                // Считаем по факту: запись могла не начаться (идёт расшифровка, нет микрофона).
                // Иначе ⌥+клавиша или ⌥Space во время расшифровки шлёт `cancel`, машина молча
                // уходит в idle, HUD висит на «расшифровке», а результат теряется.
                gesture.recordingStarted(!wasRecording && isRecording)
            }
        } else if added != 0 {
            run(gesture.handle(.modifierDown))
        }
    }

    private func run(_ actions: [HoldGesture.Action]) {
        for action in actions {
            switch action {
            case .begin: handler(.holdBegan)
            case .end: handler(.holdEnded)
            case .cancel: handler(.cancel)
            case .latch: handler(.latch)
            }
        }
    }

    private func keyDown(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            let actions = gesture.handle(.escape(recording: isRecording))
            // Диагностика Esc: дошло ли нажатие и что с ним сделали. Без текста диктовки.
            AppLog.shared.event("keys", "esc recording=\(isRecording) actions=\(actions)")
            run(actions)
            return
        }
        // ⌥+клавиша — это набор символа, а не диктовка. ⌥Space ловит Carbon.
        let space = event.keyCode == UInt16(kVK_Space) && toggleEnabled
        run(gesture.handle(.keyDown(space: space)))
    }

    // MARK: ⌥Space через Carbon (разрешений не требует)

    private func installCarbonHandler() {
        guard carbonHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData else { return noErr }
            // Сочетания доставки (`DeliveryHotkeys`) — не наши: отдаём дальше по цепочке.
            var hotKey = EventHotKeyID()
            if let event, GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                            nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey) == noErr,
               hotKey.signature != HotkeyMonitor.signature {
                return OSStatus(eventNotHandledErr)
            }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.togglePressed() }
            return noErr
        }, 1, &spec, context, &carbonHandler)
    }

    private func registerToggle() {
        unregisterToggle()
        guard toggleEnabled else { return }
        let id = EventHotKeyID(signature: HotkeyMonitor.signature, id: 1)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func unregisterToggle() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func togglePressed() {
        // Правый ⌥ + Space: удержание уже началось — превращаем его в переключатель.
        run(gesture.handle(.toggle))
        handler(.togglePressed)
    }
}
