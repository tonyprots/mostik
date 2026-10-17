import Foundation
import MostikCore

/// П10, низкие находки в приложении.
func runLowHardeningTests() {
    // MARK: буфер обмена — пароли не возвращаем и не читаем
    do {
        let concealed = ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]
        let transient = ["public.utf8-plain-text", "org.nspasteboard.TransientType"]
        let onePassword = ["public.utf8-plain-text", "com.agilebits.onepassword"]
        let plain = ["public.utf8-plain-text", "public.rtf"]
        check(ClipboardPrivacy.isSensitive(concealed), "ConcealedType — пароль")
        check(ClipboardPrivacy.isSensitive(transient), "TransientType — временная запись")
        check(ClipboardPrivacy.isSensitive(onePassword), "запись 1Password")
        check(!ClipboardPrivacy.isSensitive(plain))
        check(!ClipboardPrivacy.restorable([plain, concealed]), "снимок с паролем не восстанавливаем")
        check(ClipboardPrivacy.restorable([plain]), "обычный — восстанавливаем")
        check(ClipboardPrivacy.restorable([]), "пустой — как раньше")
        equal(ClipboardPrivacy.fallbackMarkers, ["org.nspasteboard.TransientType"], "запасная запись — Transient")
    }

    // MARK: ICS — \r и управляющие символы не дописывают строк свойства
    do {
        let event = MeetingEventDraft(title: "Итоги\rATTACH:http://evil\u{0}\u{7}", start: Date(timeIntervalSince1970: 0),
                                      notes: "a\r\nb\u{1b}[31m", uid: "u1\rX-EVIL:1")
        let ics = ICSWriter.render(event, now: Date(timeIntervalSince1970: 0))
        let lines = ics.components(separatedBy: "\r\n")
        check(!lines.contains { $0.hasPrefix("ATTACH") }, "одиночный \\r не начинает новое свойство")
        check(!ics.unicodeScalars.contains { $0.value < 0x20 && $0 != "\r" && $0 != "\n" }, "управляющих символов нет")
        check(!ics.replacingOccurrences(of: "\r\n", with: "").contains("\r"), "голых \\r нет")
        check(ics.contains("SUMMARY:Итоги\\nATTACH:http://evil"), "\\r стал \\n-экранированием")
    }

    // MARK: хуки Claude Code — путь скрипта через shellQuote
    do {
        let path = "/Applications/My $(rm -rf ~) `x` App.app/Contents/Resources/hooks/mostik-queue.sh"
        equal(QueueHooks.command(scriptPath: path, argument: "stop"), AgentIntegration.shellQuote(path) + " stop")
        equal(ClaudeHooks.command(scriptPath: path, argument: "stop"), AgentIntegration.shellQuote(path) + " stop",
              "хук озвучки — так же")
        check(QueueHooks.isInstalled(["hooks": QueueHooks.entries(scriptPath: path)]), "свои записи узнаются")
        let notify = path.replacingOccurrences(of: "mostik-queue.sh", with: "mostik-notify.sh")
        check(ClaudeHooks.isInstalled(["hooks": ClaudeHooks.entries(scriptPath: notify)]))
    }
}

/// П10, низкие: права на данные и журналы, временные склейки встреч после сбоя.
func runStorageHygieneTests() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("mostik-hygiene-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    func mode(_ url: URL) -> Int { ((try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1 }

    // Каталоги данных и журналов — 0700, даже если уже были 0755; нет — создаются.
    do {
        let data = root.appendingPathComponent("Application Support/Mostik", isDirectory: true)
        let logs = root.appendingPathComponent("Logs/Mostik", isDirectory: true)
        try? fm.createDirectory(at: data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        StorageHygiene.secure([data, logs])
        equal(mode(data), 0o700, "Application Support/Mostik")
        equal(mode(logs), 0o700, "Logs/Mostik создан закрытым")
    }
    // Отчёт о сбое — 0600.
    do {
        let report = root.appendingPathComponent("crash.txt")
        check(StorageHygiene.writePrivate("x", to: report))
        equal(mode(report), 0o600)
        equal(try? String(contentsOf: report, encoding: .utf8), "x")
        check(StorageHygiene.writePrivate("y", to: report), "перезапись")
        equal(mode(report), 0o600)
    }
    // В исходниках журналов и отчётов нет 0o644.
    do {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for file in ["MostikKit/AppLog.swift", "MostikKit/EngineClient.swift"] {
            let text = (try? String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)) ?? ""
            check(!text.isEmpty && !text.contains("0o644"), "\(file): отчёты и журналы — 0600")
        }
    }
    // Склейки встреч `mostik-tracks-*` после SIGKILL движка — убираются при старте; чужое и свежее не трогаем.
    do {
        let tmp = root.appendingPathComponent("tmp", isDirectory: true)
        let old = Date(timeIntervalSinceNow: -3600)
        for name in ["mostik-tracks-abc", "mostik-live-1.wav", "other-tracks-x", "mostik-tracks-fresh"] {
            let url = tmp.appendingPathComponent(name)
            try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            if name.hasSuffix(".wav") { fm.createFile(atPath: url.path, contents: Data([1])) } else {
                try? fm.createDirectory(at: url, withIntermediateDirectories: true)
                fm.createFile(atPath: url.appendingPathComponent("mix.wav").path, contents: Data([1]))
            }
            if name != "mostik-tracks-fresh" { try? fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path) }
        }
        let removed = StorageHygiene.cleanStaleTemp(in: tmp, now: Date())
        equal(removed.sorted(), ["mostik-live-1.wav", "mostik-tracks-abc"])
        equal(((try? fm.contentsOfDirectory(atPath: tmp.path)) ?? []).sorted(), ["mostik-tracks-fresh", "other-tracks-x"])
    }
}

/// П10, низкие: облачное согласие привязано к метке `claude@v1`; без неё при загрузке сбрасывается.
func runConsentLabelTests() {
    equal(CloudConsentLabel.current, "claude@v1")
    func load(_ json: String) -> MostikSettings { try! JSONDecoder().decode(MostikSettings.self, from: Data(json.utf8)) }

    // Файл без меток (подложенный или из старой версии): оба облачных согласия — нет.
    let bare = load(#"{"meetingAIConsent": true, "meetingAICloudConsent": true, "polish": {"backend": "claude", "cloudConsent": true}}"#)
    check(!bare.polish.cloudConsent, "полировка: согласие без метки не принимается")
    check(!bare.meetingAICloudConsent, "встречи: согласие без метки не принимается")
    // Чужая метка (другой бэкенд или версия текста согласия) — тоже нет.
    let other = load(#"{"meetingAIConsent": true, "meetingAICloudConsent": true, "meetingAICloudConsentFor": "claude@v0", "polish": {"backend": "claude", "cloudConsent": true, "cloudConsentFor": "other@v1"}}"#)
    check(!other.polish.cloudConsent && !other.meetingAICloudConsent, "метка не та")

    // Согласие, данное в приложении, сохраняется с меткой и переживает перезапуск.
    var s = MostikSettings()
    s.polish = PolishSettings(backend: .claude, cloudConsent: true)
    s.grantMeetingAI()
    equal(s.polish.cloudConsentFor, "claude@v1")
    equal(s.meetingAICloudConsentFor, "claude@v1")
    let text = String(decoding: try! JSONEncoder().encode(s), as: UTF8.self)
    check(text.contains(#""cloudConsentFor":"claude@v1""#) && text.contains(#""meetingAICloudConsentFor":"claude@v1""#), text)
    let back = try! JSONDecoder().decode(MostikSettings.self, from: Data(text.utf8))
    check(back.polish.cloudConsent && back.meetingAICloudConsent, "с меткой согласие держится")
    equal(back, s)

    // Отзыв снимает и метку; сброс при смене бэкенда (reconcile) — тоже.
    var r = back
    r.polish.cloudConsent = false
    check(r.polish.cloudConsentFor == nil)
    r.revokeMeetingAI()
    check(r.meetingAICloudConsentFor == nil)
    var switched = back
    switched.polish.backend = .mlx
    let after = MeetingCloudPolicy.reconcile(old: back, new: switched)
    check(!after.meetingAICloudConsent && after.meetingAICloudConsentFor == nil)
}

/// П10, инфо: настройки меняются только через `applySettings` (там сброс облачного согласия,
/// отпечаток хука, `CloudGrants`). Прямое `model.settings = …` в контроллерах — обход.
func runApplySettingsGuardTests() {
    let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Mostik", isDirectory: true)
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: app.path)) ?? []).filter { $0.hasSuffix(".swift") }
    check(files.count > 10, "исходники приложения найдены: \(files.count)")
    for file in files where file != "AppController.swift" {
        let text = (try? String(contentsOf: app.appendingPathComponent(file), encoding: .utf8)) ?? ""
        check(!text.contains("model.settings = "), "\(file): настройки — только через onUpdateSettings/applySettings")
    }
}

/// П10, низкие: цепочка «контекст терминала → полировка → Enter в агента». Если в полировщик
/// ушёл контекст из приложения, а впереди агент или терминал — Enter сценария не жмём:
/// текст с экрана мог подсказать модели команду, а Enter её бы отправил.
func runAutoEnterGuardTests() {
    let policy = AgentAppPolicy.standard
    let terminal = FrontApp(bundleID: "com.apple.Terminal", windowTitle: "zsh", runningAgentCLIs: [])
    let claudeTerm = FrontApp(bundleID: "com.apple.Terminal", windowTitle: "claude", runningAgentCLIs: ["claude"])
    let desktop = FrontApp(bundleID: "com.anthropic.claudefordesktop", windowTitle: "Claude", runningAgentCLIs: [])
    let slack = FrontApp(bundleID: "com.tinyspeck.slackmacgap", windowTitle: "general", runningAgentCLIs: [])
    for app in [terminal, claudeTerm, desktop] {
        check(!AutoEnterGuard.allows(planned: true, contextSent: true, front: app, policy: policy), "\(app.bundleID): без Enter")
        check(AutoEnterGuard.allows(planned: true, contextSent: false, front: app, policy: policy), "\(app.bundleID): без контекста — как раньше")
    }
    check(AutoEnterGuard.allows(planned: true, contextSent: true, front: slack, policy: policy), "обычное приложение — Enter сценария")
    check(!AutoEnterGuard.allows(planned: false, contextSent: false, front: slack, policy: policy), "сценарий Enter не просил")
}

/// П10 (от П10-A): движок отдаёт в `error` сырой текст исключения, а приложение пишет его в
/// `app.log` (сбой расшифровки, отказ движка). Строка журнала проходит ту же редакцию, что
/// `crash_report.redact`: строки в кавычках → «…», переводы строк → пробел.
func runLogRedactionTests() {
    let date = Date(timeIntervalSince1970: 0)
    let line = LogLine.format(date, category: "dictation",
                              message: "error: transcription failed: ValueError: invalid literal for int(): 'моя тайна'\nTraceback \"ещё секрет\" «и тут»")
    for secret in ["моя тайна", "ещё секрет", "и тут"] { check(!line.contains(secret), "в app.log нет «\(secret)»: \(line)") }
    check(line.contains("ValueError") && line.contains("«…»"), "тип ошибки и пометка остаются: \(line)")
    equal(LogLine.redact("engine failed (code 1)"), "engine failed (code 1)", "обычное событие не меняется")
    equal(LogLine.redact("a 'b' \"c\" «d» e"), "a «…» «…» «…» e")
}

/// П10, низкий: рабочие папки transcriber (`transcriber-asr-*`, `transcriber-download-*`) со звуком встреч
/// после SIGKILL движка тоже убираются — но только старше суток: тот же `$TMPDIR` у transcriber, запущенного отдельно.
func runTranscriberTempHygieneTests() {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("mostik-hygiene-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: tmp) }
    let now = Date()
    let ages: [String: TimeInterval] = ["transcriber-asr-old": 2 * 86_400, "transcriber-download-old": 2 * 86_400,
                                        "transcriber-asr-hour": 3600, "transcriber-other-old": 2 * 86_400]
    for (name, age) in ages {
        let url = tmp.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        fm.createFile(atPath: url.appendingPathComponent("chunk.wav").path, contents: Data([1]))
        try? fm.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
    }
    let removed = StorageHygiene.cleanStaleTemp(in: tmp, now: now)
    equal(removed.sorted(), ["transcriber-asr-old", "transcriber-download-old"])
    equal(((try? fm.contentsOfDirectory(atPath: tmp.path)) ?? []).sorted(), ["transcriber-asr-hour", "transcriber-other-old"],
          "идущая расшифровка (час) и чужое не тронуты")

    // П10 р3 Н-2: папки движка после SIGKILL — векторы голосов (`mostik-voices-*`) и копия базы
    // Wispr Flow (`mostik-wispr-*`). Старше 10 минут — прочь, свежие держит идущий процесс.
    let engineTmp = fm.temporaryDirectory.appendingPathComponent("mostik-hygiene-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: engineTmp) }
    for (name, age) in ["mostik-voices-old": 1200.0, "mostik-wispr-old": 1200.0, "mostik-voices-now": 60.0] {
        let url = engineTmp.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        fm.createFile(atPath: url.appendingPathComponent("fluid.json").path, contents: Data([1]))
        try? fm.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
    }
    equal(StorageHygiene.cleanStaleTemp(in: engineTmp, now: now).sorted(), ["mostik-voices-old", "mostik-wispr-old"])
    equal((try? fm.contentsOfDirectory(atPath: engineTmp.path)) ?? [], ["mostik-voices-now"], "идущий расчёт не тронут")
}
