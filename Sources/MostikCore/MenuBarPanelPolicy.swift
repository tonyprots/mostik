/// Какие окна — всплывающее окно строки меню (`MenuBarExtra` в стиле `.window`).
/// В этом стиле `dismiss` из SwiftUI окно не закрывает, поэтому его закрывают явно:
/// перед любым окном, панелью выбора файла или действием, которое уводит фокус.
public enum MenuBarPanelPolicy {
    /// Имя класса окна SwiftUI: `MenuBarExtraWindow` (в разных версиях macOS с префиксами модуля).
    public static func isMenuBarExtraWindow(className: String) -> Bool {
        className.contains("MenuBarExtra")
    }
}
