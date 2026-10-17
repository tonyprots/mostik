import Foundation
import MostikCore

/// Автообновление (П8-3): когда Sparkle можно запускать, а когда пункт меню объясняет, почему нельзя.
func runUpdatePolicyTests() {
    let key = "vFN3VIE+RUf1wngsuwVO8xrecSq/7ZroB+K7rkHaScM="
    let feed = "https://mostik.app/appcast.xml"

    equal(UpdatePolicy.availability(feedURL: feed, publicKey: key, frameworkPresent: true),
          .ready(feed: URL(string: feed)!), "всё на месте")
    equal(UpdatePolicy.availability(feedURL: feed, publicKey: key, frameworkPresent: false),
          .frameworkMissing, "без фреймворка — первым делом")
    equal(UpdatePolicy.availability(feedURL: "https://example.invalid/mostik/appcast.xml", publicKey: key, frameworkPresent: true),
          .feedNotConfigured, "заглушка .invalid")
    equal(UpdatePolicy.availability(feedURL: "https://www.example.com/appcast.xml", publicKey: key, frameworkPresent: true),
          .feedNotConfigured, "example.com с поддоменом")
    equal(UpdatePolicy.availability(feedURL: "http://mostik.app/appcast.xml", publicKey: key, frameworkPresent: true),
          .feedNotConfigured, "только https")
    equal(UpdatePolicy.availability(feedURL: "  ", publicKey: key, frameworkPresent: true), .feedNotConfigured, "пусто")
    equal(UpdatePolicy.availability(feedURL: nil, publicKey: key, frameworkPresent: true), .feedNotConfigured, "нет ключа plist")
    equal(UpdatePolicy.availability(feedURL: feed, publicKey: nil, frameworkPresent: true), .keyMissing, "нет ключа EdDSA")
    equal(UpdatePolicy.availability(feedURL: feed, publicKey: "abc", frameworkPresent: true), .keyMissing, "ключ не 32 байта")
    check(UpdatePolicy.configuredFeed("https://notexample.com/a.xml") != nil, "суффикс не цепляет чужой домен")

    check(UpdatePolicy.checksAutomatically(.ready(feed: URL(string: feed)!)))
    check(!UpdatePolicy.checksAutomatically(.feedNotConfigured), "с заглушкой не проверяем")
    check(UpdatePolicy.unavailableMessage(.ready(feed: URL(string: feed)!), russian: true) == nil)
    for state in [UpdateAvailability.frameworkMissing, .keyMissing] {  // заглушка ленты — без окна (runUpdateMenuItemTests)
        for ru in [true, false] {
            let m = UpdatePolicy.unavailableMessage(state, russian: ru)
            check(m != nil && !(m!.title.isEmpty) && !(m!.body.isEmpty), "текст для \(state) ru=\(ru)")
        }
    }

    // Info.plist в репозитории: лента — заглушка (dev-сборки не ходят в сеть), ключ валиден. Настоящий адрес
    // и SUEnableAutomaticChecks = true пишет release.sh из release/release.conf.
    let plistURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Info.plist")
    if let data = try? Data(contentsOf: plistURL),
       let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
        equal(UpdatePolicy.availability(feedURL: plist["SUFeedURL"] as? String, publicKey: plist["SUPublicEDKey"] as? String,
                                        frameworkPresent: true), .feedNotConfigured, "в репозитории лента — заглушка")
        check(Data(base64Encoded: plist["SUPublicEDKey"] as? String ?? "")?.count == 32, "SUPublicEDKey в Info.plist")
    } else {
        check(false, "Info.plist не прочитан: \(plistURL.path)")
    }
}

/// Проверка обновлений всегда включена (решение автора): вопроса и переключателя нет, адрес ленты — один.
func runUpdateChoiceTests() {
    let ready = UpdateAvailability.ready(feed: URL(string: "https://tonyprots.github.io/mostik/appcast.xml")!)
    check(UpdatePolicy.checksAutomatically(ready), "с настоящей лентой — проверяем всегда")
    check(UpdatePolicy.showsUpdateLedgerLine(ready), "строка в «Что уходит с этого Mac»")
    for stub in [UpdateAvailability.feedNotConfigured, .frameworkMissing, .keyMissing] {
        check(!UpdatePolicy.checksAutomatically(stub), "заглушка — не проверяем: \(stub)")
        check(!UpdatePolicy.showsUpdateLedgerLine(stub))
    }

    // Старый settings.json с ответом на вопрос читается, поле не мешает и переживает сохранение как чужое.
    let old = MostikSettings.decode(Data(#"{"updateChecks": false, "language": "en"}"#.utf8))
    equal(old?.language, "en", "старый файл с updateChecks читается")

    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    // Адрес ленты — одно место, release/release.conf; после выпуска 0.1.0 он не меняется никогда.
    if let conf = try? String(contentsOf: root.appendingPathComponent("release/release.conf"), encoding: .utf8) {
        let feeds = conf.split(separator: "\n").filter { $0.hasPrefix("MOSTIK_FEED_URL=") }
        equal(feeds.count, 1, "release.conf: MOSTIK_FEED_URL ровно один")
        let feed = feeds.first.map { String($0.dropFirst("MOSTIK_FEED_URL=".count)) }
        equal(feed, "https://tonyprots.github.io/mostik/appcast.xml",
              "адрес ленты закреплён: установленные копии знают только его")
        check(UpdatePolicy.configuredFeed(feed) != nil, "адрес ленты — настоящий https")
        check(conf.contains("MOSTIK_SIGN_CERT_SHA1="), "release.conf: место под SHA-1 сертификата")
    } else {
        check(false, "release/release.conf не прочитан")
    }
    if let script = try? String(contentsOf: root.appendingPathComponent("scripts/release.sh"), encoding: .utf8) {
        check(script.contains("SUEnableAutomaticChecks true"), "release.sh включает проверку обновлений всегда")
        check(!script.contains("SUEnableAutomaticChecks false"), "release.sh не выключает проверку")
    } else {
        check(false, "scripts/release.sh не прочитан")
    }
}

/// Обновление с другим требованием подписи не ставится молча: macOS забыла бы разрешения.
func runUpdateRequirementTests() {
    let sha = "4A1B2C3D4E5F60718293A4B5C6D7E8F901234567"
    let codesignForm = "designated => identifier \"app.mostik.mac\" and certificate leaf = H\"\(sha.lowercased())\""
    let secForm = "identifier \"app.mostik.mac\" and certificate leaf = H\"\(sha)\""
    equal(UpdateRequirement.normalized(codesignForm), UpdateRequirement.normalized(secForm),
          "вывод codesign и SecRequirementCopyString — одно требование")
    equal(UpdateRequirement.normalized("  identifier  \"a\"\n and  anchor apple "), "identifier \"a\" and anchor apple")
    equal(UpdateRequirement.normalized("   "), nil)
    check(UpdateRequirement.normalized(#"identifier "App.Mostik""#) == #"identifier "App.Mostik""#,
          "регистр меняется только внутри H\"…\"")

    equal(UpdateRequirement.verdict(installed: secForm, offered: codesignForm), .same, "тот же сертификат")
    check(UpdateRequirement.allowsUpdate(.same))
    let other = "identifier \"app.mostik.mac\" and certificate leaf = H\"ffffffffffffffffffffffffffffffffffffffff\""
    if case .changed = UpdateRequirement.verdict(installed: secForm, offered: other) {} else {
        check(false, "другой сертификат — changed")
    }
    let adhoc = "identifier \"app.mostik.mac\""
    check(!UpdateRequirement.allowsUpdate(UpdateRequirement.verdict(installed: adhoc, offered: secForm)),
          "ad-hoc → самоподписанный: разрешения не переживут, молча не ставим")
    let developerID = #"identifier "app.mostik.mac" and anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345""#
    check(!UpdateRequirement.allowsUpdate(UpdateRequirement.verdict(installed: secForm, offered: developerID)),
          "самоподписанный → Developer ID: тоже смена требования")
    equal(UpdateRequirement.verdict(installed: secForm, offered: nil), .offeredUnknown, "лента без требования")
    equal(UpdateRequirement.verdict(installed: nil, offered: secForm), .installedUnknown, "сборка без подписи")
    for verdict in [UpdateRequirementVerdict.offeredUnknown, .installedUnknown] {
        check(!UpdateRequirement.allowsUpdate(verdict), "\(verdict) — не ставим молча")
    }

    // Свойства элемента ленты от Sparkle: ключ с префиксом пространства имён.
    equal(UpdateRequirement.offered(in: ["mostik:designatedRequirement": codesignForm, "sparkle:version": "12"]),
          UpdateRequirement.normalized(secForm))
    equal(UpdateRequirement.offered(in: ["x:designatedRequirement": secForm]), UpdateRequirement.normalized(secForm),
          "другой префикс того же элемента")
    equal(UpdateRequirement.offered(in: ["sparkle:version": "12"]), nil)

    for verdict in [UpdateRequirementVerdict.changed(installed: "a", offered: "b"), .offeredUnknown, .installedUnknown] {
        for ru in [true, false] {
            let m = UpdateRequirement.blockedMessage(verdict, version: "0.2.0", russian: ru)
            check(m != nil && !m!.title.isEmpty && !m!.body.isEmpty, "объяснение для \(verdict) ru=\(ru)")
            check(m!.body.contains(".dmg"), "объяснение говорит, что делать: поставить .dmg вручную")
        }
    }
    check(UpdateRequirement.blockedMessage(.changed(installed: "a", offered: "b"), version: "0.2.0", russian: true)!
            .body.contains("Универсальный доступ"), "объяснение называет разрешения")
    equal(UpdateRequirement.blockedMessage(.same, version: "1", russian: true)?.title, nil)
}

/// Схема settings.json: данные прошлых версий читаются, миграции только вперёд, откат не теряет полей.
func runSettingsSchemaTests() {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixtures = root.appendingPathComponent("Sources/MostikCoreTests/Fixtures")
    // settings.json сборок до версий схемы: без schemaVersion, с полями, которых уже нет.
    guard let legacy = MostikSettings.decode((try? Data(contentsOf: fixtures.appendingPathComponent("settings-v0.json"))) ?? Data()) else {
        check(false, "Fixtures/settings-v0.json не прочитан"); return
    }
    equal(legacy.schemaVersion, MostikSettings.currentSchemaVersion, "файл до версий доведён до текущей схемы")
    equal(legacy.language, "en")
    equal(legacy.holdKey, "rightCommand")
    check(legacy.onboarded, "онбординг пройден — не повторяется после обновления")
    equal(legacy.retentionDays, 14)
    equal(legacy.myName, "Alex Example")
    equal(legacy.polish.style, PolishStyle.business, "вложенные настройки читаются")
    check(legacy.meetingLive.liveTranscript == false, "вложенный флаг из файла, а не умолчание")
    // settings.json версии 1 — формат выпуска 0.1.0. Фикстура заморожена: менять её нельзя, только добавлять новые.
    guard let v1 = MostikSettings.decode((try? Data(contentsOf: fixtures.appendingPathComponent("settings-v1.json"))) ?? Data()) else {
        check(false, "Fixtures/settings-v1.json не прочитан"); return
    }
    equal(v1.schemaVersion, 1)
    equal(v1.language, "ru")
    equal(v1.retentionDays, 7, "поле verifierWaitMs из фикстуры убрано из настроек и молча пропускается")
    check(v1.meetingReminder == false)
    check(v1.launchAtLogin && LaunchAtLogin.wanted(v1), "настройки 0.1.0 без поля: автозапуск включён у прошедших онбординг")

    // Язык первого запуска — из языков Mac.
    equal(MostikSettings.defaultLanguage(["ru-RU", "en-US"]), "ru")
    equal(MostikSettings.defaultLanguage(["en-GB", "ru"]), "en")
    equal(MostikSettings.defaultLanguage(["de-DE", "ru_RU"]), "ru", "первый из поддерживаемых, а не первый вообще")
    equal(MostikSettings.defaultLanguage(["de-DE", "fr"]), "en", "ни ru, ни en — английский")
    equal(MostikSettings.defaultLanguage([]), "en")
    equal(MostikSettings.decode(Data("{\"language\":\"ru\"}".utf8))?.language, "ru", "выбор из файла не перебивается языком Mac")

    // Миграция: только вперёд, файл новее сборки не трогается.
    equal(SettingsMigration.forward([:])["schemaVersion"] as? Int, MostikSettings.currentSchemaVersion)
    let future: [String: Any] = ["schemaVersion": 99, "newThing": "x"]
    equal(SettingsMigration.forward(future)["schemaVersion"] as? Int, 99, "версия новее — без «миграции назад»")

    // Откат: старая сборка читает файл новой и, сохраняя, не теряет её полей и её версии.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mostik-settings-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("settings.json")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? Data(#"{"schemaVersion": 7, "language": "en", "futureFeature": {"on": true}, "updateChecks": true}"#.utf8).write(to: url)
    var loaded = MostikSettings.load(from: url)
    equal(loaded.language, "en", "файл новее читается")
    equal(loaded.schemaVersion, 7, "версия новее сохраняется")
    loaded.language = "ru"
    try? loaded.save(to: url)
    let saved = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
    equal(saved["language"] as? String, "ru", "своё поле записано")
    equal((saved["futureFeature"] as? [String: Any])?["on"] as? Bool, true, "чужое поле новой версии сохранено")
    equal(saved["schemaVersion"] as? Int, 7, "версия файла не понижена")
    equal(saved["updateChecks"] as? Bool, true, "убранное поле не стирается в той же версии")
    // Своё необязательное поле, обнулённое в модели, не воскресает из старого файла.
    loaded.projectPath = "/tmp/p"
    try? loaded.save(to: url)
    loaded.projectPath = nil
    try? loaded.save(to: url)
    equal(MostikSettings.load(from: url).projectPath, nil, "projectPath = nil не возвращается из файла")
    check(MostikSettings.knownKeys.contains("schemaVersion") && MostikSettings.knownKeys.contains("meetingAICloudConsentFor"),
          "knownKeys — все поля модели")
    // Файл без чужих полей пишется как раньше — JSONEncoder, без перепаковки.
    let plain = dir.appendingPathComponent("plain.json")
    try? MostikSettings().save(to: plain)
    let text = (try? String(contentsOf: plain, encoding: .utf8)) ?? ""
    check(text.contains("\"schemaVersion\" : 1"), "новая версия схемы пишется в файл")
}
