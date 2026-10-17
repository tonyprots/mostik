import AppKit
import CoreGraphics

/// Дополнительные триггеры диктовки (H5): боковая кнопка мыши — как клавиша удержания,
/// кнопка гарнитуры ▶︎⏸ — как переключатель. Оба выключены по умолчанию.
///
/// Активный перехват событий (CGEventTap) нужен, чтобы кнопка «назад» не листала страницу
/// в браузере, а ▶︎⏸ не запускала Музыку. Ему хватает Универсального доступа, который
/// у Mostik уже есть; новых разрешений не просим. Гарнитуры шлют ▶︎⏸ как системную
/// медиаклавишу (NX_KEYTYPE_PLAY) — ту же, что F8 на клавиатуре, их не различить.
/// MPRemoteCommandCenter не подходит: он отдаёт кнопку только приложению, которое
/// сейчас играет звук, то есть не нам.
@MainActor
public final class ExtraTriggerMonitor {
    public enum Event: Equatable, Sendable { case holdBegan, holdEnded, togglePressed }

    /// 0 — выкл; иначе номер кнопки по CGEvent: 3 — «назад», 4 — «вперёд».
    public private(set) var mouseButton: Int64 = 0
    public private(set) var headset = false

    private let handler: (Event) -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var mouseDown = false

    /// Подтип NSEvent `.systemDefined` для медиаклавиш и код ▶︎⏸ (IOKit hidsystem/ev_keymap.h).
    private static let auxControlSubtype: Int16 = 8
    private static let keyTypePlay = 16
    /// Сырой тип NX_SYSDEFINED у CGEvent.
    private static let systemDefinedType: UInt32 = 14

    public init(handler: @escaping (Event) -> Void) { self.handler = handler }

    /// "off" | "back" | "forward" и кнопка гарнитуры. Перехват ставится только при включённом триггере.
    public func configure(mouse: String, headset: Bool) {
        let button: Int64 = mouse == "back" ? 3 : (mouse == "forward" ? 4 : 0)
        guard button != mouseButton || headset != self.headset || (tap == nil && (button != 0 || headset)) else { return }
        mouseButton = button
        self.headset = headset
        uninstall()
        if button != 0 || headset { install() }
    }

    public func stop() { uninstall() }

    /// Перехват стоит и не выключен системой.
    public var isActive: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    private func install() {
        var mask: CGEventMask = 0
        if mouseButton != 0 {
            mask |= (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)
        }
        if headset { mask |= 1 << Self.systemDefinedType }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<ExtraTriggerMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            // Колбэк приходит на главном цикле: туда добавлен источник.
            let swallow = MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }, userInfo: context) else {
            NSLog("Mostik: перехват мыши и гарнитуры не поставлен — нет Универсального доступа")
            return
        }
        let src = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        source = src
    }

    private func uninstall() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        mouseDown = false
    }

    /// true — событие наше, дальше не пускаем.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .otherMouseDown:
            guard mouseButton != 0, event.getIntegerValueField(.mouseEventButtonNumber) == mouseButton else { return false }
            if !mouseDown { mouseDown = true; handler(.holdBegan) }
            return true
        case .otherMouseUp:
            guard mouseButton != 0, event.getIntegerValueField(.mouseEventButtonNumber) == mouseButton else { return false }
            if mouseDown { mouseDown = false; handler(.holdEnded) }
            return true
        default:
            guard headset, type.rawValue == Self.systemDefinedType,
                  let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == Self.auxControlSubtype else { return false }
            let data = ns.data1
            let key = (data & 0xFFFF_0000) >> 16
            guard key == Self.keyTypePlay else { return false }
            let state = (data & 0xFF00) >> 8   // 0xA — нажата, 0xB — отпущена
            let isRepeat = data & 0x1 != 0
            if state == 0xA, !isRepeat { handler(.togglePressed) }
            return true
        }
    }
}
