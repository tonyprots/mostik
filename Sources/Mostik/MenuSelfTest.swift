import AppKit
import MostikCore
import MostikKit
import MostikUI

/// Живая проверка меню строки меню без рук. Итог — в файл `MOSTIK_SELFTEST_OUT`
/// (по умолчанию /tmp/mostik-menu-selftest.txt), затем выход.
///
/// - `MOSTIK_SELFTEST=menu`: открыть меню щелчком по значку, закрыть тем же путём, что пункты меню, открыть снова.
/// - `MOSTIK_SELFTEST=menu-voice`: «Записать голос» → меню закрыто → впереди снова прежнее приложение.
///   Запись не начинается (`menuVoiceDryRun`): ни микрофона, ни движка.
///
/// В обоих режимах `AppController.start()` не вызывается: ни движка, ни хоткеев, ни записи в данные —
/// проверка не мешает запущенному рядом Mostik.
@MainActor
enum MenuSelfTest {
    static var mode: String? {
        let value = ProcessInfo.processInfo.environment["MOSTIK_SELFTEST"]
        return value == "menu" || value == "menu-voice" ? value : nil
    }

    static func runIfRequested(controller: AppController) {
        guard let mode else { return }
        let out = ProcessInfo.processInfo.environment["MOSTIK_SELFTEST_OUT"] ?? "/tmp/mostik-menu-selftest.txt"
        var log: [String] = []
        func step(_ delay: Double, _ body: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(body) }
        }
        func finish(_ at: Double) {
            step(at) {
                try? log.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
        }
        func clickIcon() -> Bool {
            for window in NSApp.windows where String(describing: type(of: window)).contains("StatusBar") {
                if let button = findButton(window.contentView) { button.performClick(nil); return true }
            }
            return false
        }
        func windows() -> String {
            NSApp.windows.filter(\.isVisible).map { "\(type(of: $0))" }.joined(separator: ", ")
        }
        func front() -> String {
            guard let app = NSWorkspace.shared.frontmostApplication else { return "none" }
            let own = app.processIdentifier == ProcessInfo.processInfo.processIdentifier
            return "\(app.bundleIdentifier ?? "pid \(app.processIdentifier)")\(own ? " (Mostik)" : "")"
        }

        if mode == "menu" {
            step(3) { log.append("icon click 1: \(clickIcon())") }
            step(4.5) { log.append("open after click 1: \(MenuWindow.isOpen) [\(windows())]") }
            step(5) { controller.model.onOpenMainWindow() }
            step(6.5) { log.append("open after action: \(MenuWindow.isOpen) [\(windows())]") }
            step(7) { log.append("icon click 2: \(clickIcon())") }
            step(8.5) { log.append("open after click 2: \(MenuWindow.isOpen) [\(windows())]") }
            step(9) { MenuWindow.close() }
            step(10) { log.append("open after close: \(MenuWindow.isOpen)") }
            finish(10.2)
            return
        }

        // menu-voice
        var before: Int32 = 0
        var opened = false
        var target: MenuPasteTarget?
        controller.menuVoiceDryRun = { target = $0 }
        step(2) {
            before = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
            log.append("front before menu: \(front())")
        }
        step(2.5) { log.append("icon click: \(clickIcon())") }
        step(3.2) {
            opened = MenuWindow.isOpen
            log.append("open after click: \(opened) [\(windows())]")
            // Ответ на вопрос «крадёт ли меню .window активность»: впереди Mostik — крадёт.
            log.append("front with menu open: \(front())")
        }
        step(3.4) { controller.model.onMenuVoice() }  // то же, что кнопка «Записать голос»
        step(5) {
            let now = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
            log.append("open after record voice: \(MenuWindow.isOpen) [\(windows())]")
            log.append("front after record voice: \(front())")
            switch target {
            case .app(let app)?: log.append("paste target: \(app.bundleID.isEmpty ? "pid \(app.pid)" : app.bundleID) pid \(app.pid)")
            case .clipboard(let reason)?: log.append("paste target: clipboard (\(reason.rawValue))")
            case nil: log.append("paste target: not chosen")
            }
            let targetPID: Int32? = if case .app(let app)? = target { app.pid } else { nil }
            // Меню не открылось — проверять нечего: это не PASS.
            let ok = opened && !MenuWindow.isOpen && before != 0 && now == before && targetPID == before
            log.append("RESULT: \(ok ? "PASS" : "FAIL") — menu opened, then closed, focus and paste target = app before menu")
        }
        finish(5.3)
    }

    private static func findButton(_ view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews { if let b = findButton(sub) { return b } }
        return nil
    }
}
