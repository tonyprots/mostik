import Foundation

/// Автообновление через Sparkle 2: можно ли проверять обновления с тем, что лежит в Info.plist и в бандле.
///
/// Sparkle грузится в рантайме из `Contents/Frameworks`, поэтому сборка без него (swift run, CI) работает,
/// а пункт меню честно объясняет, почему проверка недоступна.
public enum UpdateAvailability: Equatable, Sendable {
    /// Лента задана, ключ на месте, фреймворк в бандле.
    case ready(feed: URL)
    /// В бандле нет Sparkle.framework (swift run или сборка без vendor/sparkle).
    case frameworkMissing
    /// `SUFeedURL` пустой, не https или заглушка — адрес ленты ещё не выбран.
    case feedNotConfigured
    /// Нет `SUPublicEDKey`: без ключа Sparkle откажется ставить обновление.
    case keyMissing
}

public enum UpdatePolicy {
    /// Хосты-заглушки: RFC 2606/6761 зарезервированы и никогда не резолвятся.
    public static let placeholderDomains = ["invalid", "example", "test", "localhost", "example.com", "example.org", "example.net"]

    public static func availability(feedURL: String?, publicKey: String?, frameworkPresent: Bool) -> UpdateAvailability {
        guard frameworkPresent else { return .frameworkMissing }
        guard let url = configuredFeed(feedURL) else { return .feedNotConfigured }
        let key = (publicKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // EdDSA-ключ ed25519 — 32 байта, в base64 это 44 символа.
        guard let raw = Data(base64Encoded: key), raw.count == 32 else { return .keyMissing }
        return .ready(feed: url)
    }

    /// Адрес ленты, если он настоящий: https и не зарезервированный хост.
    public static func configuredFeed(_ raw: String?) -> URL? {
        let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if placeholderDomains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return nil
        }
        return url
    }

    /// Проверка обновлений всегда включена (решение автора): ни вопроса при первом запуске, ни выключателя.
    /// Без настоящей ленты Sparkle не запускается вовсе, проверять там нечего.
    public static func checksAutomatically(_ availability: UpdateAvailability) -> Bool {
        if case .ready = availability { return true }
        return false
    }

    /// Строка «Проверка обновлений» в сводке «Что уходит с этого Mac» — только с настоящей лентой.
    public static func showsUpdateLedgerLine(_ availability: UpdateAvailability) -> Bool {
        checksAutomatically(availability)
    }

    /// Пункт «Проверить обновления…» (меню строки меню) есть, только когда `SUFeedURL` — настоящий https-адрес.
    /// С заглушкой (`.invalid`, локальная сборка) пункта нет нигде; появится адрес ленты — пункт вернётся сам.
    /// Решает адрес, а не состояние Sparkle: без модуля Sparkle `availability` — `.frameworkMissing` и до проверки ленты.
    public static func showsCheckForUpdates(feedURL: String?) -> Bool {
        configuredFeed(feedURL) != nil
    }

    /// Текст для пункта «Проверить обновления…», когда проверка недоступна; nil — окна нет.
    public static func unavailableMessage(_ availability: UpdateAvailability, russian: Bool) -> (title: String, body: String)? {
        switch availability {
        case .ready:
            return nil
        case .frameworkMissing:
            return russian
                ? ("Обновления недоступны", "Эта сборка Mostik собрана без модуля обновлений. Новую версию можно поставить из .dmg.")
                : ("Updates unavailable", "This build of Mostik was made without the update module. Install a new version from the .dmg.")
        case .feedNotConfigured:
            // Пункта «Проверить обновления…» с заглушкой ленты нет (`showsCheckForUpdates`) — объяснять нечего.
            return nil
        case .keyMissing:
            return russian
                ? ("Обновления недоступны", "В сборке нет ключа проверки обновлений, поэтому Mostik не станет их ставить.")
                : ("Updates unavailable", "This build has no update verification key, so Mostik will not install updates.")
        }
    }
}

// MARK: - Требование подписи (designated requirement)

/// Сверка требования подписи установленного Mostik и предложенного обновления.
///
/// macOS выдаёт разрешения (микрофон, Универсальный доступ, «Запись экрана», звук системы) по
/// требованию подписи. Sparkle при верной подписи EdDSA ставит и сборку с другим сертификатом, после
/// чего macOS молча забывает все разрешения. Поэтому требование собранного приложения пишется в ленту
/// (`<mostik:designatedRequirement>`, `scripts/appcast.py`), а Mostik до загрузки сравнивает его со своим.
public enum UpdateRequirementVerdict: Equatable, Sendable {
    /// Требование то же — разрешения переживут обновление.
    case same
    /// Обновление подписано иначе: после установки macOS спросит все разрешения заново.
    case changed(installed: String, offered: String)
    /// Лента не сообщает требование подписи — проверить нечем, молча не ставим.
    case offeredUnknown
    /// Своё требование прочитать не удалось (сборка без подписи, swift run).
    case installedUnknown
}

public enum UpdateRequirement {
    /// Элемент `<item>` в ленте; Sparkle кладёт его в `SUAppcastItem.propertiesDictionary` под этим именем.
    public static let appcastElement = "mostik:designatedRequirement"

    /// Текст требования без `designated => `, с одиночными пробелами и хешами `H"…"` в нижнем регистре:
    /// `codesign -d -r-` и `SecRequirementCopyString` пишут одно и то же по-разному.
    public static func normalized(_ raw: String?) -> String? {
        var text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("designated =>") { text = String(text.dropFirst("designated =>".count)) }
        text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        var out = ""
        var rest = Substring(text)
        while let open = rest.range(of: "H\"") {
            out += rest[..<open.upperBound]
            rest = rest[open.upperBound...]
            guard let close = rest.firstIndex(of: "\"") else { break }
            out += rest[..<close].lowercased()
            rest = rest[close...]
        }
        return out + rest
    }

    /// Требование из свойств элемента ленты: ключ с префиксом пространства имён или без него.
    public static func offered(in properties: [String: Any]) -> String? {
        let suffix = ":designatedRequirement"
        let value = properties[appcastElement]
            ?? properties.first(where: { $0.key == "designatedRequirement" || $0.key.hasSuffix(suffix) })?.value
        return normalized(value as? String)
    }

    public static func verdict(installed: String?, offered: String?) -> UpdateRequirementVerdict {
        guard let mine = normalized(installed) else { return .installedUnknown }
        guard let theirs = normalized(offered) else { return .offeredUnknown }
        return mine == theirs ? .same : .changed(installed: mine, offered: theirs)
    }

    /// Можно ли ставить молча. Всё, кроме `.same`, — объяснение и ручная установка из `.dmg`.
    public static func allowsUpdate(_ verdict: UpdateRequirementVerdict) -> Bool {
        verdict == .same
    }

    /// Объяснение, почему обновление не ставится само. `version` — версия из ленты.
    public static func blockedMessage(_ verdict: UpdateRequirementVerdict, version: String,
                                      russian: Bool) -> (title: String, body: String)? {
        let v = version.isEmpty ? (russian ? "новую версию" : "the new version") : version
        switch verdict {
        case .same:
            return nil
        case .changed:
            return russian
                ? ("Mostik \(v) подписан другим сертификатом",
                   "Если поставить его поверх этой копии, macOS забудет разрешения Mostik: микрофон, Универсальный доступ, «Запись экрана» и звук системы. Поэтому сам Mostik его не ставит. Скачайте .dmg со страницы выпуска, установите вручную и выдайте разрешения заново в Системных настройках → Конфиденциальность и безопасность.")
                : ("Mostik \(v) is signed with a different certificate",
                   "Installed over this copy, it would make macOS forget Mostik’s permissions: microphone, Accessibility, Screen Recording and system audio. So Mostik won’t install it by itself. Download the .dmg from the release page, install it manually and grant the permissions again in System Settings → Privacy & Security.")
        case .offeredUnknown:
            return russian
                ? ("Mostik \(v) не ставится сам",
                   "Лента обновлений не сообщает, как подписана новая версия, поэтому Mostik не может убедиться, что macOS сохранит его разрешения. Скачайте .dmg со страницы выпуска и установите вручную.")
                : ("Mostik \(v) won’t install by itself",
                   "The update feed doesn’t say how the new version is signed, so Mostik can’t make sure macOS keeps its permissions. Download the .dmg from the release page and install it manually.")
        case .installedUnknown:
            return russian
                ? ("Эта копия Mostik не обновляется сама",
                   "У этой сборки нет подписи, по которой macOS узнала бы новую версию, — после обновления разрешения пропали бы. Скачайте .dmg со страницы выпуска и установите вручную.")
                : ("This copy of Mostik doesn’t update itself",
                   "This build has no signature macOS could match the new version against, so the permissions would be lost. Download the .dmg from the release page and install it manually.")
        }
    }
}
