import Foundation
import MostikCore

// П6-А: контекст (P1), сценарии (P2), правила речи (P3, V4), пакеты стилей (P4), потоковая
// вставка (P6), перевод и задача (V3, A4), очередь агенту (A6). Только синтетика.
func runPolishExtrasTests() {
    let slack = "com.tinyspeck.slackmacgap"
    let chrome = "com.google.Chrome"
    let cursor = "com.todesktop.230313mzl4w4u92"

    // MARK: P3, V4 — правила речи
    do {
        let d = SpeechRuleSettings()
        equal(d.payload, ["commands": true, "scratch": true, "lists": false, "numbers": false], "по умолчанию — команды и «зачеркни»")
        equal(SpeechRuleSettings(commands: false, scratch: false).payload, nil, "все выключены — поле не уходит")
        let decoded = try? JSONDecoder().decode(SpeechRuleSettings.self, from: Data(#"{"numbers":true}"#.utf8))
        equal(decoded, SpeechRuleSettings(numbers: true), "недостающие ключи — по умолчанию")
    }

    // MARK: P1 — контекст
    do {
        let mlx = PolishBackend.mlx
        let value = "Привет, Ярослава! " + String(repeating: "а", count: 300) + "|после курсора"
        let caret = (value as NSString).range(of: "|").location
        let source = ContextSource(bundleID: slack, value: value, selection: CaretRange(location: caret, length: 1),
                                   clipboard: "секрет из буфера", host: nil)
        let settings = PolishContextSettings()
        let ctx = PolishContext.make(source, settings: settings, backend: mlx)
        equal(ctx?["selection"], "|", "выделение")
        equal(ctx?["after"], "после курсора", "после курсора")
        equal(ctx?["before"]?.count, 256, "до курсора — 256 знаков")
        equal(ctx?["clipboard"], nil, "буфер по умолчанию не берём")
        var withClip = settings; withClip.clipboard = true
        equal(PolishContext.make(source, settings: withClip, backend: mlx)?["clipboard"], "секрет из буфера")
        equal(PolishContext.make(source, settings: settings, backend: nil), nil, "без причёсывания контекст не нужен")
        equal(PolishContext.make(source, settings: settings, backend: .claude), nil, "в облако — только с разрешения")
        var cloud = settings; cloud.toCloud = true
        check(PolishContext.make(source, settings: cloud, backend: .claude) != nil, "разрешили облако")
        var secure = source; secure.secure = true
        equal(PolishContext.make(secure, settings: settings, backend: mlx), nil, "поле пароля")
        var keychain = source; keychain.bundleID = "com.1password.1password"
        equal(PolishContext.make(keychain, settings: settings, backend: mlx), nil, "менеджер паролей")
        var bank = source; bank.bundleID = chrome; bank.host = "online.sberbank.ru"
        equal(PolishContext.make(bank, settings: settings, backend: mlx), nil, "банк в браузере")
        var mail = source; mail.bundleID = chrome; mail.host = "mail.yandex.ru"
        equal(PolishContext.make(mail, settings: settings, backend: mlx)?["page"], "mail.yandex.ru", "домен страницы")
        var own = settings; own.excludedHosts = ["yandex.ru"]
        equal(PolishContext.make(mail, settings: own, backend: mlx), nil, "своё исключение по домену — и поддомены")
        var off = settings; off.enabled = false
        equal(PolishContext.make(source, settings: off, backend: mlx), nil, "выключено")
        equal(PolishContext.make(ContextSource(bundleID: slack, value: "   "), settings: settings, backend: mlx), nil, "пусто")
        equal(PolishContext.host(of: "https://mail.yandex.ru/inbox?x=1"), "mail.yandex.ru", "только домен, без пути")
        let emoji = "👍🏽 привет"
        let tail = PolishContext.make(ContextSource(bundleID: slack, value: emoji, selection: CaretRange(location: (emoji as NSString).length, length: 0)),
                                      settings: settings, backend: mlx)
        equal(tail?["before"], emoji, "UTF-16 смещения AX и эмодзи")
    }

    // MARK: P2 — сценарии
    do {
        var p = PolishSettings(backend: .mlx, style: .plain)
        let slackScenario = Scenario(id: "s1", name: "Slack", apps: [slack], hosts: ["app.slack.com"], language: "en",
                                     style: .brief, autoEnter: true)
        let mail = Scenario(id: "s2", name: "Почта", hosts: ["mail.yandex.ru"], style: .business)
        let browser = Scenario(id: "s3", name: "Браузер", apps: [chrome], backend: .off)
        p.scenarios = [browser, slackScenario, mail]
        equal(ScenarioBook.match(p.scenarios, bundleID: chrome, host: "mail.yandex.ru")?.id, "s2", "сайт точнее браузера")
        equal(ScenarioBook.match(p.scenarios, bundleID: chrome, host: "example.org")?.id, "s3", "другой сайт — сценарий браузера")
        equal(ScenarioBook.match(p.scenarios, bundleID: chrome, host: "app.slack.com")?.id, "s1", "Slack в браузере")
        equal(ScenarioBook.match(p.scenarios, bundleID: "com.apple.TextEdit", host: nil), nil)

        let plan = p.plan(bundleID: slack, host: nil, isAgent: false)
        equal(plan.language, "en"); equal(plan.autoEnter, true); equal(plan.scenario, "Slack")
        equal(plan.polish, PolishRequest(backend: .mlx, style: .brief))
        equal(p.plan(bundleID: chrome, host: "example.org", isAgent: false).polish, nil, "сценарий «как сказано»")
        let mailPlan = p.plan(bundleID: chrome, host: "mail.yandex.ru", isAgent: false)
        equal(mailPlan.polish?.style, .business)

        var agentScenario = Scenario(id: "s4", name: "Задача агенту", apps: [cursor], style: .task)
        p.scenarios = [agentScenario]
        equal(p.plan(bundleID: cursor, host: nil, isAgent: true).polish?.style, .task, "сценарий включает причёсывание и у агента")
        equal(p.decide(bundleID: cursor, isAgent: true), nil, "без сценария агент — как сказано")
        agentScenario.enabled = false
        p.scenarios = [agentScenario]
        equal(p.plan(bundleID: cursor, host: nil, isAgent: true).polish, nil, "выключенный сценарий не работает")

        var cloud = PolishSettings(backend: .claude, style: .plain, cloudConsent: false)
        cloud.scenarios = [Scenario(name: "x", apps: [slack], backend: .claude, style: .business)]
        equal(cloud.plan(bundleID: slack, host: nil, isAgent: false).polish, nil, "сценарий не обходит согласие на облако")

        let json = try? JSONEncoder().encode([slackScenario])
        let back = json.flatMap { try? JSONDecoder().decode([Scenario].self, from: $0) }
        equal(back, [slackScenario], "сценарии переживают сохранение")
        let old = try? JSONDecoder().decode(PolishSettings.self, from: Data(#"{"backend":"mlx","style":"brief"}"#.utf8))
        equal(old?.scenarios, [], "старые настройки читаются")
        equal(old?.rules, SpeechRuleSettings()); equal(old?.streamInsert, false); equal(old?.context.clipboard, false)
    }

    // MARK: V3, A4 — разовые режимы
    do {
        var p = PolishSettings(backend: .mlx, style: .business)
        p.translateTone = .dev
        let tr = p.plan(bundleID: slack, host: nil, isAgent: false, mode: .translate).polish
        equal(tr?.translate, PolishTranslate(to: "en", tone: .dev)); equal(tr?.style, .business)
        let task = p.plan(bundleID: cursor, host: nil, isAgent: true, mode: .task).polish
        equal(task?.style, .task, "задача — и в агентном приложении"); equal(task?.translate, nil)
        let none = PolishSettings().plan(bundleID: slack, host: nil, isAgent: false, mode: .translate)
        equal(none.polish, nil, "бэкенд выключен — режим не включает причёсывание")
        p.scenarios = [Scenario(name: "Slack EN", apps: [slack], translate: PolishTranslate(to: "en", tone: .business))]
        equal(p.plan(bundleID: slack, host: nil, isAgent: false).polish?.translate?.tone, .business, "перевод сценарием")
    }

    // MARK: P4 — пакеты стилей
    do {
        var p = PolishSettings(backend: .mlx, style: .plain)
        p.pack = "pismo"
        equal(p.decide(bundleID: slack, isAgent: false)?.pack, "pismo", "пакет уходит в запрос")
        equal(p.decide(bundleID: cursor, isAgent: true), nil)
        p.setOverride(cursor, true)
        equal(p.decide(bundleID: cursor, isAgent: true)?.pack, nil, "агенту — режим разработчика, не пакет")
        let packs = ["pismo", "review"]
        var s = PolishSettings(backend: .mlx, style: .plain)
        var seen: [String] = []
        for _ in 0..<7 {
            let next = s.nextStyle(packs: packs)
            s.style = next.style; s.pack = next.pack
            seen.append(next.pack ?? next.style.rawValue)
        }
        equal(seen, ["business", "brief", "list", "pismo", "review", "plain", "business"], "по кругу: стили, затем пакеты")
        var gone = PolishSettings(); gone.pack = "deleted"
        equal(gone.nextStyle(packs: packs).style, .plain, "пропавший пакет — с начала круга")
    }

    // MARK: P6 — потоковая вставка
    do {
        var p = PolishSettings(backend: .mlx, style: .plain)
        equal(p.plan(bundleID: slack, host: nil, isAgent: false).polish?.stream, false, "по умолчанию выключено")
        p.streamInsert = true
        equal(p.plan(bundleID: slack, host: nil, isAgent: false).polish?.stream, true)
        p.setOverride(cursor, true)
        equal(p.plan(bundleID: cursor, host: nil, isAgent: true).polish?.stream, false, "агенту — целиком, с сомнениями")
        var cloud = PolishSettings(backend: .claude, style: .plain, cloudConsent: true); cloud.streamInsert = true
        equal(cloud.plan(bundleID: slack, host: nil, isAgent: false).polish?.stream, false, "у claude -p кусков нет")

        equal(StreamInsert.complete("Первое. Второе предл"), "Первое. ")
        equal(StreamInsert.complete("Без конца"), "")
        equal(StreamInsert.complete("Строка\nещё"), "Строка\n")
        equal(StreamInsert.complete("Версия 2.5 вышла. Да"), "Версия 2.5 вышла. ", "точка в числе — не конец")
        equal(StreamInsert.append(inserted: "", partial: "Первое. Второе"), "Первое. ")
        equal(StreamInsert.append(inserted: "Первое. ", partial: "Первое. Второе! Тре"), "Второе! ")
        equal(StreamInsert.append(inserted: "Первое. ", partial: "Первое. Втор"), nil, "нового целого нет")
        equal(StreamInsert.append(inserted: "Первое. ", partial: "Иначе. Второе. "), nil, "модель переписала начало")
        equal(StreamInsert.finish(inserted: "", final: "Текст."), .whole)
        equal(StreamInsert.finish(inserted: "Первое. ", final: "Первое. Второе."), .append("Второе."))
        equal(StreamInsert.finish(inserted: "Первое. ", final: "Первое."), .append(""), "итог без хвостового пробела")
        equal(StreamInsert.finish(inserted: "Первое. ", final: "Иначе."), .replace(count: 8, with: "Иначе."))
        let field = FieldSnapshot(bundleID: slack, value: "До. Первое. ", selection: CaretRange(location: 12, length: 0))
        check(StreamInsert.canReplace(field: field, inserted: "Первое. "))
        var moved = field; moved.selection = CaretRange(location: 3, length: 0)
        check(!StreamInsert.canReplace(field: moved, inserted: "Первое. "), "курсор ушёл")
        var edited = field; edited.value = "До. Первое! "
        check(!StreamInsert.canReplace(field: edited, inserted: "Первое. "), "поле правили")
        check(!StreamInsert.canReplace(field: nil, inserted: "Первое. "), "поле не прочитать")
    }

    // MARK: A6 — очередь агенту
    do {
        let now = Date(timeIntervalSince1970: 10_000)
        let a = BusySession(id: "a", cwd: "/Users/u/proj/web", touched: now.addingTimeInterval(-60))
        let b = BusySession(id: "b", cwd: "/Users/u/proj/api", touched: now.addingTimeInterval(-30))
        let stale = BusySession(id: "c", cwd: "/Users/u/old", touched: now.addingTimeInterval(-AgentQueue.staleAfter - 1))
        equal(AgentQueue.target([a], project: nil, now: now)?.id, "a", "одна занятая сессия")
        equal(AgentQueue.target([a, b], project: nil, now: now), nil, "две без проекта — не угадываем")
        equal(AgentQueue.target([a, b], project: "/Users/u/proj/api", now: now)?.id, "b", "по проекту")
        equal(AgentQueue.target([a, b], project: "/Users/u/proj/api/src/", now: now)?.id, "b", "агент в корне, проект глубже")
        equal(AgentQueue.target([stale], project: "/Users/u/old", now: now), nil, "застывшая сессия — свободна")
        equal(AgentQueue.target([], project: nil, now: now), nil)
        equal(AgentQueue.parseBusy(name: "abc-1", content: "/tmp/x\n", modified: now)?.cwd, "/tmp/x")
        equal(AgentQueue.parseBusy(name: "../etc", content: nil, modified: now), nil, "имя не путь")
        equal(AgentQueue.encodeMessage(" Скажи \"да\"\nи 50% \\ "), #"Скажи \"да\"\nи 50\u0025 \\"#)
        equal(AgentQueue.messageFileName(now: now, suffix: "Ab-9/x"), "10000000-Ab9x.msg")

        let script = "/Users/u/Library/Application Support/Mostik/hooks/mostik-queue.sh"
        let notify = ClaudeHooks.install(into: ["hooks": ["Stop": [["hooks": [["type": "command", "command": "afplay x"]]]]]],
                                         scriptPath: "/x/mostik-notify.sh")
        let installed = QueueHooks.install(into: notify, scriptPath: script)
        check(QueueHooks.isInstalled(installed)); check(ClaudeHooks.isInstalled(installed), "озвучка не тронута")
        equal(((installed["hooks"] as? [String: Any])?["Stop"] as? [Any])?.count, 3, "чужой, озвучка и очередь")
        let again = QueueHooks.install(into: installed, scriptPath: script)
        equal(((again["hooks"] as? [String: Any])?["Stop"] as? [Any])?.count, 3, "без дублей")
        let removed = QueueHooks.uninstall(from: again)
        check(!QueueHooks.isInstalled(removed)); check(ClaudeHooks.isInstalled(removed), "удалена только очередь")
        equal((removed["hooks"] as? [String: Any])?["UserPromptSubmit"] == nil, true)
        check(QueueHooks.preview(scriptPath: script).contains("'\(script)' tool"))
        let voice = try? JSONDecoder().decode(AgentVoiceSettings.self, from: Data("{}".utf8))
        equal(voice?.midTurn, false, "очередь выключена по умолчанию")
    }

    // MARK: A6 — скрипт хука очереди
    do {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = repo.appendingPathComponent("integrations/claude-code/hooks/\(QueueHooks.scriptName)")
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("mostik-queuetest-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        func run(_ arg: String, _ input: String) -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [script.path, arg]
            p.environment = ["MOSTIK_QUEUE_DIR": dir.path, "PATH": "/usr/bin:/bin"]
            let stdin = Pipe(), stdout = Pipe()
            p.standardInput = stdin; p.standardOutput = stdout
            do { try p.run() } catch { return "run failed" }
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
            let out = stdout.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: out, as: UTF8.self)
        }
        let busy = dir.appendingPathComponent("busy/s-1")
        equal(run("prompt", #"{"session_id":"s-1","cwd":"/tmp/p"}"#), "", "без .enabled молчит")
        check(!fm.fileExists(atPath: busy.path))
        fm.createFile(atPath: dir.appendingPathComponent(AgentQueue.enabledMarker).path, contents: Data())
        equal(run("prompt", #"{"session_id":"s-1","cwd":"/tmp/p"}"#), "")
        equal((try? String(contentsOf: busy, encoding: .utf8)), "/tmp/p\n", "занят, cwd записан")
        let queue = dir.appendingPathComponent("queue/s-1")
        try? fm.createDirectory(at: queue, withIntermediateDirectories: true)
        try? AgentQueue.encodeMessage("Ещё \"тесты\" на 100%").write(to: queue.appendingPathComponent("1-a.msg"), atomically: true, encoding: .utf8)
        let tool = run("tool", #"{"session_id":"s-1","cwd":"/tmp/p"}"#)
        let parsed = (try? JSONSerialization.jsonObject(with: Data(tool.utf8))) as? [String: Any]
        let ctx = (parsed?["hookSpecificOutput"] as? [String: Any])?["additionalContext"] as? String
        check(ctx?.hasSuffix("Ещё \"тесты\" на 100%") == true, "сообщение дошло после инструмента")
        equal((try? fm.contentsOfDirectory(atPath: queue.path))?.count, 0, "отданное убрано из очереди")
        try? AgentQueue.encodeMessage("Последнее").write(to: queue.appendingPathComponent("2-b.msg"), atomically: true, encoding: .utf8)
        let stop = (try? JSONSerialization.jsonObject(with: Data(run("stop", #"{"session_id":"s-1"}"#).utf8))) as? [String: Any]
        equal(stop?["decision"] as? String, "block", "ход не кончается, пока есть сообщения")
        check(fm.fileExists(atPath: busy.path), "агент ещё занят")
        equal(run("stop", #"{"session_id":"s-1"}"#), "")
        check(!fm.fileExists(atPath: busy.path), "свободен")
        equal(run("tool", #"{"session_id":"../../etc"}"#), "", "чужое имя сессии отброшено")
        try? fm.removeItem(at: dir)
    }
}
