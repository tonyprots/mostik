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
        switch move(source, to: target) {
        case .moved: relaunch(target)
        case .failed: showManual(source, hint: AppLocation.manualHint(russian: UIText.isRussian))
        case .mismatch: showManual(target, hint: AppLocation.mismatchHint(russian: UIText.isRussian))
        }
    }

    private enum Outcome { case moved, failed, mismatch }

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

    private static func move(_ source: URL, to target: URL) -> Outcome {
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
            // Источник между вопросом и переносом могли подменить: карантин снимаем только с того же
            // кода, что сейчас запущен. Сборке без подписи сверять не с чем — ей как раньше.
            let own = CodeRequirement.runningCodeHash()
            if AppLocation.quarantine(own: own, matches: CodeRequirement.isIntact(target, sameAs: own ?? Data())) == .keep {
                AppLog.shared.event("app", "moved copy does not match the running code, quarantine kept")
                return .mismatch
            }
            // Карантин снят у нашей же копии, уже открытой человеком: иначе macOS снова запустит её
            // из временной папки. Так же делает LetsMove.
            let xattr = Process()
            xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattr.arguments = ["-dr", "com.apple.quarantine", target.path]
            xattr.environment = ToolEnvironment.minimal(ProcessInfo.processInfo.environment)
            try? xattr.run()
            xattr.waitUntilExit()
            return .moved
        } catch {
            AppLog.shared.event("app", "move to Applications failed: \(error.localizedDescription)")
            return .failed
        }
    }

    /// Новая копия стартует, когда эта закроется: два Mostik одновременно делили бы клавишу записи.
    private static func relaunch(_ target: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let waiter = Process()
        // Тот же скрипт и то же урезанное окружение, что у перезапуска после обновления (`Relaunch`).
        waiter.executableURL = URL(fileURLWithPath: Relaunch.shell)
        waiter.arguments = Relaunch.arguments(pid: pid, bundlePath: target.path)
        waiter.environment = Relaunch.environment(ProcessInfo.processInfo.environment)
        try? waiter.run()
        NSApp.terminate(nil)
    }

    @MainActor
    private static func showManual(_ source: URL, hint: String) {
        let alert = NSAlert()
        alert.messageText = AppLocation.title(russian: UIText.isRussian)
        alert.informativeText = hint
        alert.addButton(withTitle: L("Показать в Finder", "Show in Finder"))
        alert.addButton(withTitle: L("Позже", "Later"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.activateFileViewerSelecting([source])
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
    }
}
