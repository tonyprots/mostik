import Foundation
import MostikCore
import Security

/// Отпечаток команды хука встречи в связке ключей (П10 С3): своя служба `app.mostik.mac.hooks`.
///
/// Чтение — без окна пароля: если запись не прочесть молча (после пересборки ad-hoc), это
/// «не подтверждено», и Mostik сам спросит про команду. Запись — только после «Разрешить»
/// или правки в Настройках.
///
/// П10 Н1: запись, которую сделал не Mostik, не принимается. Своя запись создаётся с ACL,
/// где расшифровка разрешена ровно одному приложению — самому Mostik; перед чтением ACL
/// проверяется (`KeychainItemOwnership`). Подделка с «все приложения» (`security
/// add-generic-password -A`) или с доступом для создателя — `.foreign`. Вторая линия — разделы
/// (partition ID) связки: запись чужого бинарника ad-hoc Mostik молча не прочтёт, проверено
/// пробой, итоги — `docs/release.md`, «Принятые риски П10».
///
/// П10 р3 С-1: только связка «Вход». Её файл открывается по пути (`SecKeychainOpen`), поиск,
/// удаление и запись идут только в ней (`kSecMatchSearchList`, `kSecUseKeychain`), а не по списку
/// поиска пользователя: свою связку с известным паролем атакующий может поставить в нём первой.
/// У найденной записи сверяется связка (`SecKeychainItemCopyKeychain`), данные читаются по той же
/// ссылке (`kSecMatchItemList`), а не вторым поиском. Решение — `HookDigestReader` в MostikCore.
///
/// API ACL (`SecKeychainItemCopyAccess`, `SecAccessCreate`, `SecTrustedApplication…`) устарел,
/// но другого для файловой связки «Вход» нет: связке с защитой данных нужна подпись с командой.
public final class KeychainHookDigestStore: HookDigestStore, @unchecked Sendable {
    let service: String
    let account: String
    let label: String

    public init(service: String = MeetingHookTrust.keychainService, account: String = MeetingHookTrust.keychainAccount,
                label: String = "Mostik: after-meeting command") {
        self.service = service
        self.account = account
        self.label = label
    }

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }

    public func read() -> HookDigestRead {
        guard let login = Self.loginKeychain() else { return .unreadable }
        var refQuery = base
        refQuery[kSecMatchSearchList as String] = [login.keychain]
        refQuery[kSecReturnRef as String] = true
        refQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var ref: CFTypeRef?
        switch SecItemCopyMatching(refQuery as CFDictionary, &ref) {
        case errSecSuccess: break
        case errSecItemNotFound: return .missing
        default: return .unreadable
        }
        guard let ref, CFGetTypeID(ref) == SecKeychainItemGetTypeID() else { return .unreadable }
        return evaluate(ref as! SecKeychainItem, loginKeychainPath: login.path)
    }

    /// Решение по найденной записи: связка, ACL, данные этой же записи. Отдельно от поиска —
    /// чтобы проба могла подать запись из другой связки как «первую найденную».
    func evaluate(_ item: SecKeychainItem, loginKeychainPath: String) -> HookDigestRead {
        let record = HookDigestRecord(keychainPath: Self.keychainPath(of: item), decryptApps: Self.decryptApps(of: item) ?? [])
        return HookDigestReader.read(.found(item, record), selfPath: Self.selfPath(), loginKeychainPath: loginKeychainPath) {
            Self.data(of: $0)
        }
    }

    /// Старую запись (свою или подложенную) в «Вход» — прочь, новую — с ACL «только Mostik», тоже в «Вход».
    /// `SecItemUpdate` не годится: он оставил бы чужой ACL на месте.
    public func write(_ digest: String) -> Bool {
        guard let login = Self.loginKeychain() else { return false }
        for item in Self.items(matching: base, in: login.keychain)
        where Self.keychainPath(of: item).map({ KeychainItemOwnership.normalized($0) }) == KeychainItemOwnership.normalized(login.path) {
            SecKeychainItemDelete(item)
        }
        guard let access = Self.selfOnlyAccess() else { return false }
        var add = base
        add[kSecValueData as String] = Data(digest.utf8)
        add[kSecAttrLabel as String] = label
        add[kSecAttrAccess as String] = access
        add[kSecUseKeychain as String] = login.keychain
        add.removeValue(forKey: kSecUseAuthenticationUI as String)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Удалить запись из «Вход» (отключение аккаунта календаря). true — записи больше нет.
    @discardableResult
    public func delete() -> Bool {
        guard let login = Self.loginKeychain() else { return false }
        for item in Self.items(matching: base, in: login.keychain) { SecKeychainItemDelete(item) }
        return Self.items(matching: base, in: login.keychain).isEmpty
    }

    // MARK: связка «Вход»

    /// `~/Library/Keychains/login.keychain-db` по домашней папке из базы пользователей, не из `$HOME`.
    /// Открытие по пути список поиска пользователя не меняет. Файла нет — nil (а не пустая ссылка).
    static func loginKeychain() -> (keychain: SecKeychain, path: String)? {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return nil }
        let path = KeychainItemOwnership.loginKeychainPath(home: String(cString: dir))
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var keychain: SecKeychain?
        guard SecKeychainOpen(path, &keychain) == errSecSuccess, let keychain else { return nil }
        return (keychain, path)
    }

    /// Путь файла связки, в которой лежит запись.
    static func keychainPath(of item: SecKeychainItem) -> String? {
        var keychain: SecKeychain?
        guard SecKeychainItemCopyKeychain(item, &keychain) == errSecSuccess, let keychain else { return nil }
        return path(of: keychain)
    }

    static func path(of keychain: SecKeychain) -> String? {
        var length = UInt32(PATH_MAX)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        guard SecKeychainGetPath(keychain, &length, &buffer) == errSecSuccess else { return nil }
        return String(cString: buffer)
    }

    /// Данные ровно этой записи, без окна пароля.
    static func data(of item: SecKeychainItem) -> HookDigestRead {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecMatchItemList as String: [item],
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne,
                                    kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            guard let data = result as? Data, let text = String(data: data, encoding: .utf8) else { return .unreadable }
            return .value(text)
        case errSecItemNotFound:
            return .missing
        default:
            return .unreadable
        }
    }

    /// Все записи службы и учётки в одной связке.
    static func items(matching base: [String: Any], in keychain: SecKeychain) -> [SecKeychainItem] {
        var query = base
        query[kSecMatchSearchList as String] = [keychain]
        query[kSecReturnRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return [] }
        if let list = result as? [SecKeychainItem] { return list }
        if let result, CFGetTypeID(result) == SecKeychainItemGetTypeID() { return [result as! SecKeychainItem] }
        return []
    }

    // MARK: ACL

    private static func selfApplication() -> SecTrustedApplication? {
        var app: SecTrustedApplication?
        return SecTrustedApplicationCreateFromPath(nil, &app) == errSecSuccess ? app : nil
    }

    static func selfPath() -> String? {
        selfApplication().flatMap(path(of:))
    }

    private static func path(of app: SecTrustedApplication) -> String? {
        var data: CFData?
        guard SecTrustedApplicationCopyData(app, &data) == errSecSuccess, let data else { return nil }
        return String(decoding: data as Data, as: UTF8.self)
    }

    /// Расшифровка — только самому Mostik.
    private static func selfOnlyAccess() -> SecAccess? {
        guard let me = selfApplication() else { return nil }
        var access: SecAccess?
        let status = SecAccessCreate("Mostik: after-meeting command" as CFString, [me] as CFArray, &access)
        return status == errSecSuccess ? access : nil
    }

    /// Списки приложений у записей ACL с правом расшифровки (без окна); nil — ACL не прочесть.
    static func decryptApps(of item: SecKeychainItem) -> [[String]?]? {
        var access: SecAccess?
        guard SecKeychainItemCopyAccess(item, &access) == errSecSuccess, let access else { return nil }
        var list: CFArray?
        guard SecAccessCopyACLList(access, &list) == errSecSuccess, let acls = list as? [SecACL] else { return nil }
        var decrypt: [[String]?] = []
        for acl in acls {
            let rights = SecACLCopyAuthorizations(acl) as? [String] ?? []
            guard rights.contains(kSecACLAuthorizationDecrypt as String) || rights.contains(kSecACLAuthorizationAny as String)
            else { continue }
            var apps: CFArray?
            var description: CFString?
            var prompt = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &apps, &description, &prompt) == errSecSuccess else { return nil }
            if let list = apps as? [SecTrustedApplication] {
                decrypt.append(list.map { path(of: $0) ?? "" })
            } else {
                decrypt.append(nil)
            }
        }
        return decrypt
    }
}
