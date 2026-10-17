import CryptoKit
import Foundation

/// Что лежит в связке ключей под отпечатком команды хука.
public enum HookDigestRead: Equatable, Sendable {
    case value(String)
    case missing
    /// Запись есть, но без запроса пароля её не прочесть (например, после пересборки ad-hoc).
    case unreadable
    /// Запись есть, но её мог сделать не Mostik: расшифровку ACL разрешает не только ему (П10, Н1).
    case foreign
}

/// П10 Н1: чья запись в связке ключей. Подложить отпечаток можно, только создав запись самому, —
/// у такой записи ACL пускает «все приложения» или того, кто её сделал. Своя запись Mostik
/// (`KeychainHookDigestStore.write`) пускает на расшифровку ровно один бинарник — сам Mostik.
public enum KeychainItemOwnership {
    /// `decryptApps` — списки доверенных приложений у записей ACL с правом расшифровки
    /// (`nil` — «любое приложение»); `selfPath` — путь своего бинарника.
    public static func ownedBySelf(decryptApps: [[String]?], selfPath: String) -> Bool {
        guard !decryptApps.isEmpty else { return false }
        let me = normalized(selfPath)
        return decryptApps.allSatisfy { apps in
            guard let apps, apps.count == 1 else { return false }
            return normalized(apps[0]) == me
        }
    }

    /// П10 р3 С-1: запись Mostik лежит в связке «Вход» и расшифровывается только самим Mostik.
    /// Запись из другой связки — чужая, даже с ACL «только Mostik»: такую связку мог сделать кто угодно.
    public static func ownedBySelf(_ record: HookDigestRecord, selfPath: String, loginKeychainPath: String) -> Bool {
        guard let path = record.keychainPath, !path.isEmpty,
              normalized(path) == normalized(loginKeychainPath) else { return false }
        return ownedBySelf(decryptApps: record.decryptApps, selfPath: selfPath)
    }

    /// Связка «Вход» по домашней папке. Папку берут из базы пользователей (`getpwuid`), а не из `$HOME`:
    /// `launchctl setenv HOME` увёл бы «Вход» в чужую папку.
    public static func loginKeychainPath(home: String) -> String {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Keychains/login.keychain-db").path
    }

    /// `SecTrustedApplicationCopyData` отдаёт путь с хвостовым NUL; `/tmp` и `/private/tmp` — одно.
    public static func normalized(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "\u{0}"))
        return URL(fileURLWithPath: trimmed).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

/// П10 р3 С-1: что известно о записи, найденной в связке ключей, — до чтения её данных.
public struct HookDigestRecord: Equatable, Sendable {
    /// Путь файла связки, в которой лежит запись (`SecKeychainItemCopyKeychain` → `SecKeychainGetPath`).
    public var keychainPath: String?
    /// Списки доверенных приложений у записей ACL с правом расшифровки (`nil` — «любое приложение»).
    public var decryptApps: [[String]?]

    public init(keychainPath: String?, decryptApps: [[String]?]) {
        self.keychainPath = keychainPath
        self.decryptApps = decryptApps
    }
}

/// П10 р3 С-1: чтение отпечатка по найденной записи. Источник записей (связка ключей или подделка в
/// тестах) отдаёт первую найденную запись и её данные — по той же ссылке, а не вторым поиском.
///
/// Подделка своей связкой: атакующий создаёт связку с известным паролем, ставит её первой в список
/// поиска и кладёт запись с ACL «только Mostik» и разделом `cdhash:`/`teamid:` Mostik. ACL такой записи
/// проходит `KeychainItemOwnership`, поэтому сверяется и связка: запись Mostik живёт только в «Вход».
public enum HookDigestReader {
    public enum Lookup<Item> {
        case missing
        case unreadable
        case found(Item, HookDigestRecord)
    }

    /// `selfPath` — путь своего бинарника; `loginKeychainPath` — `~/Library/Keychains/login.keychain-db`
    /// по домашней папке из базы пользователей; `data` читает данные именно этой записи.
    public static func read<Item>(_ lookup: Lookup<Item>, selfPath: String?, loginKeychainPath: String,
                                  data: (Item) -> HookDigestRead) -> HookDigestRead {
        switch lookup {
        case .missing: return .missing
        case .unreadable: return .unreadable
        case .found(let item, let record):
            guard let selfPath,
                  KeychainItemOwnership.ownedBySelf(record, selfPath: selfPath, loginKeychainPath: loginKeychainPath)
            else { return .foreign }
            return data(item)
        }
    }
}

/// Хранилище отпечатка: в приложении — связка ключей (`KeychainHookDigestStore`), в тестах — подделка.
public protocol HookDigestStore: AnyObject {
    func read() -> HookDigestRead
    /// true — записано.
    func write(_ digest: String) -> Bool
}

/// П10 С3: команду хука встречи нельзя подменить правкой `settings.json`. Mostik хранит SHA256
/// команды, которую пользователь ввёл или подтвердил в самом приложении, в связке ключей
/// (`app.mostik.mac.hooks`). Не совпало — хук выключается, Mostik показывает команду и спрашивает.
public enum MeetingHookTrust {
    public static let keychainService = "app.mostik.mac.hooks"
    public static let keychainAccount = "meeting-hook"

    public static func digest(_ command: String) -> String {
        SHA256.hash(data: Data(command.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func runnable(_ settings: MeetingHookSettings) -> Bool {
        settings.enabled && !settings.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Отпечаток команды совпадает с записанным.
    public static func isTrusted(_ settings: MeetingHookSettings, store: HookDigestStore) -> Bool {
        if case .value(let stored) = store.read() { return stored == digest(settings.command) }
        return false
    }

    /// Настройки прочитаны с диска: включённый хук с неподтверждённой командой выключается,
    /// команда возвращается для вопроса пользователю.
    public static func reconcileOnLoad(_ settings: MeetingHookSettings, store: HookDigestStore)
        -> (settings: MeetingHookSettings, ask: String?) {
        guard runnable(settings), !isTrusted(settings, store: store) else { return (settings, nil) }
        var off = settings
        off.enabled = false
        return (off, settings.command)
    }

    /// Изменение из Настроек Mostik — воля пользователя: записать отпечаток новой команды.
    ///
    /// П10 р4 Р4-3: если изменился только переключатель (выкл → вкл), а команда та же и не подтверждена, —
    /// пользователь её не вводил и, возможно, не видел (поле появляется только после включения; команду мог
    /// дописать в `settings.json` кто-то другой). Тогда хук остаётся выключенным, а команда уходит на вопрос
    /// «Разрешить?» со всеми защитами окна (`ask`).
    @discardableResult
    public static func applyChange(old: MeetingHookSettings, new: MeetingHookSettings, store: HookDigestStore)
        -> (settings: MeetingHookSettings, ask: String?) {
        guard runnable(new), !runnable(old) || old.command != new.command else { return (new, nil) }
        if old.command == new.command, !isTrusted(new, store: store) {
            var off = new
            off.enabled = false
            return (off, new.command)
        }
        _ = store.write(digest(new.command))
        return (new, nil)
    }

    /// Правка текста команды у включённого хука — ввод в поле Настроек (шаг 2, п. 10): такие правки
    /// подряд сводятся в одну запись отпечатка после паузы. Включение, выключение — сразу, как раньше.
    public static func isCommandEdit(old: MeetingHookSettings, new: MeetingHookSettings) -> Bool {
        old.enabled && new.enabled && old.command != new.command
    }

    /// Ответ на вопрос «Разрешить эту команду?»: да — отпечаток и включение; записать не вышло — выключено.
    /// Р4-3: «Не запускать» стирает команду — отклонённая не дожидается следующего включения переключателем.
    public static func answer(_ allow: Bool, settings: MeetingHookSettings, store: HookDigestStore) -> MeetingHookSettings {
        var result = settings
        result.enabled = allow && store.write(digest(settings.command))
        if !allow { result.command = "" }
        return result
    }
}

/// П10, низкий: текст окна «Разрешить эту команду?». Хвост команды не должен прятаться —
/// ни за переводом строки, ни за невидимыми знаками (bidi-разворот, нулевая ширина).
public enum MeetingHookPrompt {
    /// Невидимые и управляющие знаки, кроме перевода строки и таба, — как `⟨U+XXXX⟩`.
    public static func visible(_ command: String) -> String {
        var out = ""
        for scalar in command.unicodeScalars {
            if isHidden(scalar) {
                out += String(format: "⟨U+%04X⟩", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Предупреждения над командой.
    public static func notes(_ command: String) -> [String] {
        var notes: [String] = []
        let lines = command.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
        if lines.count > 1 {
            notes.append(UIText.pick("Команда в \(lines.count) строк(и) — прокрутите и прочтите целиком.",
                                     "The command has \(lines.count) lines — scroll and read all of it."))
        }
        if command.unicodeScalars.contains(where: isHidden) {
            notes.append(UIText.pick("В команде есть невидимые знаки — они показаны как ⟨U+…⟩.",
                                     "The command contains invisible characters — shown as ⟨U+…⟩."))
        }
        return notes
    }

    static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\n" || scalar == "\t" { return false }
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned, .surrogate: return true
        default: return false
        }
    }
}
