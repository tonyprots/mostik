import AppKit
import SwiftUI
import MostikCore

/// Всплывающее окно строки меню (`MenuBarExtra` в стиле `.window`). `dismiss` из SwiftUI его не закрывает,
/// поиск по имени класса ненадёжен между версиями macOS — поэтому вид меню сам запоминает своё окно,
/// а закрывают именно его.
@MainActor
public enum MenuWindow {
    static weak var window: NSWindow?

    public static func close() {
        var targets: [NSWindow] = []
        if let window, window.isVisible { targets.append(window) }
        targets += NSApp.windows.filter {
            $0.isVisible && !targets.contains($0)
                && MenuBarPanelPolicy.isMenuBarExtraWindow(className: String(describing: type(of: $0)))
        }
        for target in targets {
            target.close()
            if target.isVisible { target.orderOut(nil) }
        }
    }

    public static var isOpen: Bool { window?.isVisible ?? false }
}

/// Невидимый вид в фоне меню: сообщает, в каком окне оно показано.
struct MenuWindowReader: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ReaderView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ReaderView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { MainActor.assumeIsolated { MenuWindow.window = window } }
        }
    }
}
