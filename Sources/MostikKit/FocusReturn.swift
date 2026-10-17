import AppKit
import ApplicationServices
import MostikCore

/// Вернуть фокус приложению, где стоял курсор до меню строки меню (пункт «Записать голос»).
///
/// Меню `MenuBarExtra` в стиле `.window` делает Mostik активным, иначе в нём не работала бы клавиатура.
/// Поэтому прежнее приложение запоминается по уведомлениям `NSWorkspace` (`FrontAppMemory`), а поле
/// в нём — через AX на уровне приложения: `kAXFocusedUIElement` у приложения не сбрасывается, пока оно
/// неактивно. В поле ничего не пишем — ни текста, ни выделения (R3); только просим фокус обратно.
@MainActor
public enum FocusReturn {
    /// Приложение впереди сейчас.
    public static func frontmost() -> AppRef? {
        NSWorkspace.shared.frontmostApplication.map(ref)
    }

    public static func ref(_ app: NSRunningApplication) -> AppRef {
        AppRef(pid: app.processIdentifier, bundleID: app.bundleIdentifier ?? "", name: app.localizedName ?? "")
    }

    public static func isRunning(_ app: AppRef) -> Bool {
        guard let running = NSRunningApplication(processIdentifier: app.pid) else { return false }
        return !running.isTerminated
    }

    /// Поле в фокусе внутри приложения `pid` (без Accessibility — nil).
    public static func focusedElement(pid: Int32) -> AXUIElement? {
        guard AXIsProcessTrusted(), pid > 0 else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return (focused as! AXUIElement)
    }

    public static func token(_ element: AXUIElement?) -> Int? {
        element.map { Int(bitPattern: UInt(CFHash($0))) }
    }

    /// Вывести `app` вперёд и дождаться, пока macOS это подтвердит (до `timeout`); затем, если
    /// приложение поставило фокус не туда, вернуть его запомненному полю. true — приложение впереди.
    @discardableResult
    public static func activate(_ app: AppRef, element: AXUIElement?, timeout: TimeInterval = 0.8) async -> Bool {
        guard let running = NSRunningApplication(processIdentifier: app.pid), !running.isTerminated else { return false }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.pid {
            // macOS 14: активацию нужно уступить явно, иначе просьба чужому приложению может не пройти.
            NSApp.yieldActivation(to: running)
            if !running.activate(from: .current, options: []) { running.activate() }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != app.pid, Date() < deadline {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.pid
        if front, let element,
           MenuVoice.needsRefocus(remembered: token(element), current: token(focusedElement(pid: app.pid))) {
            AXUIElementSetMessagingTimeout(element, 0.25)
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        return front
    }
}
