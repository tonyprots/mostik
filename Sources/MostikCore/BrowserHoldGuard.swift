import Foundation

/// Удержание клавиши записи в браузере (2026-11-09, Антон): ⌘+клик по вкладке — не диктовка.
/// В браузере запись по удержанию начинается, только когда в фокусе поле ввода.
public enum BrowserHoldGuard {
    /// Браузеры по bundle id: здесь же их берёт контекст причёсывания (`PolishContextReader`).
    public static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.beta",
        "com.microsoft.edgemac", "company.thebrowser.Browser", "com.brave.Browser", "ru.yandex.desktop.yandex-browser",
        "org.mozilla.firefox", "app.zen-browser.zen", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    /// `field` — поле в фокусе; nil — AX недоступен: тогда не мешаем, как было раньше.
    public static func allowsStart(frontBundleID: String, field: FieldSnapshot?) -> Bool {
        guard browsers.contains(frontBundleID), let field else { return true }
        return field.editable == .yes
    }
}
