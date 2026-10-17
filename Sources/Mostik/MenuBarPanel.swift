import AppKit
import MostikCore
import MostikUI

/// Закрыть всплывающее окно строки меню. Через `close()`, а не `orderOut`: SwiftUI слушает
/// закрытие окна и сбрасывает своё «открыто», так что следующий щелчок по значку открывает его снова.
@MainActor
enum MenuBarPanel {
    static func dismiss() { MenuWindow.close() }

    /// Перед показом своего окна или панели: закрыть меню и вывести приложение вперёд.
    static func activateApp() {
        dismiss()
        NSApp.activate(ignoringOtherApps: true)
    }
}
