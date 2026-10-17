import AppKit
import ApplicationServices
import Carbon.HIToolbox
import MostikCore

/// Контекст из приложения для причёсывания (P1): поле в фокусе, буфер обмена, домен страницы.
/// Только чтение AX; читается сразу после начала записи, параллельно с речью, и уходит движку
/// командой `context`. Что из этого можно отдать — решает `PolishContext` в MostikCore.
@MainActor
public enum PolishContextReader {
    /// Браузеры, у которых ищем адрес страницы: AXURL у веб-области или AXDocument у окна.
    public nonisolated static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.beta",
        "com.microsoft.edgemac", "company.thebrowser.Browser", "com.brave.Browser", "ru.yandex.desktop.yandex-browser",
        "org.mozilla.firefox", "app.zen-browser.zen", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    /// `field` — снимок поля в начале записи (R1): значение и выделение уже прочитаны, второй раз не ходим.
    /// `host` — домен страницы, прочитанный вне главного потока на старте (шаг 1, п. 1); здесь AX не ходим.
    public static func read(field: FieldSnapshot?, bundleID: String, clipboard: Bool, host: String?) -> ContextSource {
        var source = ContextSource(bundleID: bundleID, secure: field?.isSecure ?? false,
                                   value: field?.value, selection: field?.selection)
        // П10: буфер с паролем (Concealed/Transient, запись 1Password) в контекст не берём.
        if clipboard, !IsSecureEventInputEnabled(),
           ClipboardPrivacy.restorable((NSPasteboard.general.pasteboardItems ?? []).map { $0.types.map(\.rawValue) }) {
            source.clipboard = NSPasteboard.general.string(forType: .string)
        }
        if browsers.contains(bundleID) { source.host = host }
        return source
    }

    /// Домен страницы в браузере `pid`; не браузер — nil. Можно звать с любого потока:
    /// обход ограничен 100 мс на всё (`AXWalkBudget`), а не 0,2 с на каждый из 40 уровней.
    public nonisolated static func host(bundleID: String, pid: pid_t) -> String? {
        browsers.contains(bundleID) ? PolishContext.host(of: pageURL(pid: pid)) : nil
    }

    /// Адрес страницы: от элемента в фокусе вверх до веб-области, иначе AXDocument окна.
    nonisolated static func pageURL(pid: pid_t, budget start: Double = ProcessInfo.processInfo.systemUptime) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        var budget = AXWalkBudget(startedAt: start)
        let now = { ProcessInfo.processInfo.systemUptime }
        let timeout = { AXWalkBudget.messagingTimeout(left: budget.left(now: now())) }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout())
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            var element = focused as! AXUIElement
            while budget.allowsStep(now: now()) {
                AXUIElementSetMessagingTimeout(element, timeout())
                if let url = url(element, kAXURLAttribute) { return url }
                var parent: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                      let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                element = parent as! AXUIElement
            }
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout())
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return url(window as! AXUIElement, kAXDocumentAttribute)
    }

    private nonisolated static func url(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return nil }
        if let url = value as? URL { return url.absoluteString }
        if let text = value as? String, text.hasPrefix("http") { return text }
        return nil
    }
}
