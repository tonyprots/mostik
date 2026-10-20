import AppKit
import ApplicationServices
import MostikCore

/// AX-чтение поля в фокусе (R1, R2, R4). Только чтение: в поле мы ничего не пишем —
/// ни `AXValue`, ни `AXSelectedTextRange`; Electron и Gecko от AX-записи дублируют текст (R3).
@MainActor
public enum FocusedField {
    /// Больше этого значение поля не читаем: огромный документ — секунды на обмен с приложением.
    public static var valueLimit = 200_000
    private static var engines: [String: AppTextEngine] = [:]
    /// Процессы Electron, у которых уже попросили дерево Accessibility.
    private static var manualAccessibilityPIDs: Set<pid_t> = []

    /// Снимок поля в фокусе; nil — нет доступа или ничего не в фокусе.
    public static func snapshot() -> FieldSnapshot? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focused: CFTypeRef?
        let front = NSWorkspace.shared.frontmostApplication
        if let front { requestManualAccessibility(front) }
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            guard let front else { return nil }
            return FieldSnapshot(bundleID: front.bundleIdentifier ?? "", engine: engine(for: front))
        }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let app = NSRunningApplication(processIdentifier: pid) ?? front
        var snapshot = FieldSnapshot(bundleID: app?.bundleIdentifier ?? "", elementToken: Int(bitPattern: UInt(CFHash(element))),
                                     engine: app.map(engine(for:)) ?? .native)
        snapshot.role = string(element, kAXRoleAttribute)
        snapshot.subrole = string(element, kAXSubroleAttribute)
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success {
            snapshot.valueSettable = settable.boolValue
        }
        // Пароль не читаем вовсе.
        guard !snapshot.isSecure else { return snapshot }
        var count: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
           let n = count as? Int, n > valueLimit {
            return snapshot
        }
        snapshot.value = string(element, kAXValueAttribute)
        snapshot.selection = range(element, kAXSelectedTextRangeAttribute)
        return snapshot
    }

    /// Один раз на процесс: Chromium строит дерево лениво, поэтому просьба в снимке начала записи
    /// успевает к проверке вставки, а самый первый снимок поле может ещё не прочитать.
    private static func requestManualAccessibility(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid > 0, !manualAccessibilityPIDs.contains(pid), engine(for: app).needsManualAccessibility else { return }
        manualAccessibilityPIDs.insert(pid)
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.25)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Состояние поля для проверки вставки и отката.
    public static func state() -> FieldState? { snapshot()?.state }

    /// Electron — по фреймворку в бандле, Gecko — по XUL или bundle id Mozilla. Кэш по bundle id.
    public static func engine(for app: NSRunningApplication) -> AppTextEngine {
        let id = app.bundleIdentifier ?? ""
        if let cached = engines[id] { return cached }
        var result = AppTextEngine.native
        if let url = app.bundleURL {
            let fm = FileManager.default
            if fm.fileExists(atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path) {
                result = .electron
            } else if id.hasPrefix("org.mozilla.") || id.hasPrefix("app.zen-browser")
                        || fm.fileExists(atPath: url.appendingPathComponent("Contents/MacOS/XUL").path) {
                result = .gecko
            }
        }
        if !id.isEmpty { engines[id] = result }
        return result
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func range(_ element: AXUIElement, _ attribute: String) -> CaretRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return CaretRange(location: range.location, length: range.length)
    }
}
