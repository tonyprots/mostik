import AppKit
import MostikCore

/// Перенос в «Программы» при запуске из `.dmg` или транслоцированной копии.
/// Спрашивает один раз за запуск; ничего не делает без «Перенести».
public enum AppMover {
    @MainActor
    public static func offerIfNeeded() {
        let bundle = Bundle.main.bundleURL
        guard let problem = AppLocation.problem(bundlePath: bundle.path) else { return }
        AppLog.shared.event("app", "location \(problem)")
        let alert = NSAlert()
        alert.messageText = AppLocation.title(russian: UIText.isRussian)
        alert.informativeText = AppLocation.message(problem, russian: UIText.isRussian)
        alert.addButton(withTitle: L("Перенести и перезапустить", "Move and relaunch"))
        alert.addButton(withTitle: L("Продолжить отсюда", "Keep running from here"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let source = originalURL(of: bundle) ?? bundle
        let target = URL(fileURLWithPath: AppLocation.destination(bundleName: bundle.lastPathComponent))
        if move(source, to: target) {
            relaunch(target)
        } else {
            showManual(source)
        }
    }

    /// Настоящий путь транслоцированной копии — функция Security без публичного заголовка
    /// (её же берёт LetsMove); не нашлась — копируем то, что запущено.
    private static func originalURL(of url: URL) -> URL? {
        typealias Fn = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard url.path.contains("/AppTranslocation/"),
              let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        let original = unsafeBitCast(symbol, to: Fn.self)(url as CFURL, nil)
        return original?.takeRetainedValue() as URL?
    }

    private static func move(_ source: URL, to target: URL) -> Bool {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: target.path) {
                // Старая версия уходит в Корзину, а не удаляется: её можно вернуть.
                try fm.trashItem(at: target, resultingItemURL: nil)
            }
            // С образа — копия (он только для чтения), из «Загрузок» — перенос, чтобы не было двух копий.
            if source.path.hasPrefix("/Volumes/") {
                try fm.copyItem(at: source, to: target)
            } else {
                try fm.moveItem(at: source, to: target)
            }
            // Карантин снят у нашей же копии, уже открытой человеком: иначе macOS снова запустит её
            // из временной папки. Так же делает LetsMove.
            let xattr = Process()
            xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattr.arguments = ["-dr", "com.apple.quarantine", target.path]
            try? xattr.run()
            xattr.waitUntilExit()
            return true
        } catch {
            AppLog.shared.event("app", "move to Applications failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Новая копия стартует, когда эта закроется: два Mostik одновременно делили бы клавишу записи.
    private static func relaunch(_ target: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"", target.path]
        try? waiter.run()
        NSApp.terminate(nil)
    }

    @MainActor
    private static func showManual(_ source: URL) {
        let alert = NSAlert()
        alert.messageText = AppLocation.title(russian: UIText.isRussian)
        alert.informativeText = AppLocation.manualHint(russian: UIText.isRussian)
        alert.addButton(withTitle: L("Показать в Finder", "Show in Finder"))
        alert.addButton(withTitle: L("Позже", "Later"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.activateFileViewerSelecting([source])
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
    }
}
