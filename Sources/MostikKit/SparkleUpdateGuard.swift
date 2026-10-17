import Foundation
import MostikCore

/// Делегат Sparkle (`SPUUpdaterDelegate`) без линковки фреймворка: Sparkle спрашивает методы через
/// `respondsToSelector:`, объекты Sparkle читаются через KVC.
///
/// 1. Обновление с другим требованием подписи не ставится молча (`UpdateRequirement`): Sparkle принял бы
///    его по верной подписи EdDSA, а macOS забыла бы разрешения Mostik. Ручная проверка — ошибку
///    показывает окно Sparkle, фоновая — `onBlocked`, один раз на версию.
/// 2. Перезапуск после установки ждёт, пока идёт запись (`isBusy`): иначе он оборвал бы встречу.
///
/// Файл собирается и в пробу цепочки обновления (`scripts/update-e2e.sh`) вместе с `UpdatePolicy.swift`.
public class SparkleUpdateGuard: NSObject {
    public static let errorDomain = "app.mostik.update"
    private static let shownKey = "MostikUpdateBlockedShownVersion"

    private let hostBundleURL: URL
    private let russian: Bool
    private let isBusy: () -> Bool
    private let onBlocked: (_ title: String, _ body: String) -> Void
    private var waitTimer: Timer?

    public init(hostBundleURL: URL, russian: Bool, isBusy: @escaping () -> Bool = { false },
                onBlocked: @escaping (_ title: String, _ body: String) -> Void) {
        self.hostBundleURL = hostBundleURL
        self.russian = russian
        self.isBusy = isBusy
        self.onBlocked = onBlocked
    }

    /// Вердикт для элемента ленты: требование установленной копии против требования из ленты.
    public func verdict(for item: NSObject) -> UpdateRequirementVerdict {
        let properties = item.value(forKey: "propertiesDictionary") as? [String: Any] ?? [:]
        return UpdateRequirement.verdict(installed: CodeRequirement.designated(at: hostBundleURL),
                                         offered: UpdateRequirement.offered(in: properties))
    }

    /// `-updater:shouldProceedWithUpdate:updateCheck:error:` (Sparkle ≥ 2.4). `updateCheck`: 0 — по кнопке
    /// пользователя, 1 — фоновая, 2 — только узнать о версии.
    @objc(updater:shouldProceedWithUpdate:updateCheck:error:)
    public func updater(_ updater: NSObject, shouldProceedWithUpdate item: NSObject, updateCheck: Int) throws {
        let verdict = verdict(for: item)
        guard !UpdateRequirement.allowsUpdate(verdict) else { return }
        let version = item.value(forKey: "displayVersionString") as? String ?? ""
        let message = UpdateRequirement.blockedMessage(verdict, version: version, russian: russian)
            ?? (title: "Mostik", body: "")
        NSLog("Mostik: обновление \(version) не ставится — \(verdict)")
        if updateCheck != 0, UserDefaults.standard.string(forKey: Self.shownKey) != version {
            UserDefaults.standard.set(version, forKey: Self.shownKey)
            onBlocked(message.title, message.body)
        }
        throw NSError(domain: Self.errorDomain, code: 1, userInfo: [
            NSLocalizedDescriptionKey: message.title,
            NSLocalizedRecoverySuggestionErrorKey: message.body,
        ])
    }

    /// `-updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:`: идёт запись — перезапуск после неё.
    @objc(updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)
    public func updater(_ updater: NSObject, shouldPostponeRelaunchForUpdate item: NSObject,
                        untilInvokingBlock handler: @escaping @convention(block) () -> Void) -> Bool {
        guard isBusy() else { return false }
        NSLog("Mostik: обновление установится после записи")
        waitTimer?.invalidate()
        waitTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] timer in
            guard let self, !self.isBusy() else { return }
            timer.invalidate()
            self.waitTimer = nil
            handler()
        }
        return true
    }

    @objc(updater:didAbortWithError:)
    public func updater(_ updater: NSObject, didAbortWithError error: NSError) {
        NSLog("Mostik: обновление прервано: \(error.domain) \(error.code) \(error.localizedDescription)")
    }
}
