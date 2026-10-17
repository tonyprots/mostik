import AppKit
import Foundation
import MostikCore

/// Sparkle 2 без линковки: фреймворк грузится из `Contents/Frameworks` в рантайме.
///
/// Так `swift build`, `swift run` и CI собираются без `vendor/sparkle` (бинарники Sparkle не в git),
/// а продовая сборка из `scripts/bundle.sh` кладёт фреймворк в бандл и получает обновления.
/// Контроллер — `SPUStandardUpdaterController`: стандартные окна Sparkle, проверка EdDSA-подписи.
/// Делегат — `SparkleUpdateGuard`: обновление с другим требованием подписи не ставится молча, перезапуск
/// ждёт конца записи. Проверка обновлений всегда включена (решение автора), выключателя нет; установка —
/// по кнопке в окне Sparkle, автоматическую пользователь включает там же галочкой.
@MainActor
public final class SparkleUpdater {
    public private(set) var availability: UpdateAvailability
    /// Пункт «Проверить обновления…» есть только с настоящим адресом ленты (`UpdatePolicy.showsCheckForUpdates`).
    public let showsCheckItem: Bool
    private var controller: AnyObject?
    private var guardDelegate: SparkleUpdateGuard?

    /// `isBusy` — идёт запись диктовки или встречи: перезапуск после установки ждёт её конца.
    public init(bundle: Bundle = .main, isBusy: @escaping () -> Bool = { false }) {
        let framework = bundle.privateFrameworksURL?.appendingPathComponent("Sparkle.framework")
        let present = framework.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
        showsCheckItem = UpdatePolicy.showsCheckForUpdates(feedURL: feed)
        availability = UpdatePolicy.availability(
            feedURL: feed,
            publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            frameworkPresent: present)
        // С заглушкой вместо ленты Sparkle не запускаем вовсе: ни вопроса про автопроверку, ни запросов в сеть.
        guard case .ready = availability, let framework else { return }
        let delegate = SparkleUpdateGuard(hostBundleURL: bundle.bundleURL, russian: Self.isRussian,
                                          isBusy: isBusy) { title, body in
            DispatchQueue.main.async { Self.showAlert(title: title, body: body) }
        }
        guardDelegate = delegate  // Sparkle держит делегата слабой ссылкой
        controller = Self.makeController(framework: framework, delegate: delegate)
        if controller == nil { availability = .frameworkMissing; return }
        // Всегда включена: значение из defaults (`defaults write … SUEnableAutomaticChecks`) не выключает.
        if let updater = controller?.value(forKey: "updater") as? NSObject,
           UpdatePolicy.checksAutomatically(availability) {
            updater.setValue(true, forKey: "automaticallyChecksForUpdates")
        }
    }

    /// Пункт «Проверить обновления…»: окно Sparkle или объяснение, почему проверка недоступна.
    public func checkForUpdates() {
        guard showsCheckItem else { return }
        if let controller {
            _ = controller.perform(NSSelectorFromString("checkForUpdates:"), with: nil)
            return
        }
        guard let message = UpdatePolicy.unavailableMessage(availability, russian: Self.isRussian) else { return }
        Self.showAlert(title: message.title, body: message.body)
    }

    private static func showAlert(title: String, body: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.runModal()
    }

    private static var isRussian: Bool {
        Locale.preferredLanguages.first?.lowercased().hasPrefix("ru") ?? true
    }

    /// `[[SPUStandardUpdaterController alloc] initWithStartingUpdater:YES updaterDelegate:delegate userDriverDelegate:nil]`.
    private static func makeController(framework: URL, delegate: AnyObject) -> AnyObject? {
        guard let bundle = Bundle(url: framework), bundle.load(),
              let cls = NSClassFromString("SPUStandardUpdaterController") else {
            NSLog("Mostik: Sparkle.framework не загрузился: \(framework.path)")
            return nil
        }
        let initSel = NSSelectorFromString("initWithStartingUpdater:updaterDelegate:userDriverDelegate:")
        guard let allocated = (cls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              let imp = class_getMethodImplementation(cls, initSel) else { return nil }
        typealias InitFn = @convention(c) (AnyObject, Selector, Bool, AnyObject?, AnyObject?) -> Unmanaged<AnyObject>?
        let initialize = unsafeBitCast(imp, to: InitFn.self)
        // Контроллер живёт всё время работы приложения: лишний retain от alloc не освобождаем.
        return initialize(allocated, initSel, true, delegate, nil)?.takeUnretainedValue()
    }
}
