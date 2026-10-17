import Foundation
import MostikCore

// П4: tmux (G5), голосовая отправка (G6), озвучка хода (A1), автотег (A3), адресация (A5).
// Только синтетика: имена панелей, проектов и файлов выдуманы.
func runAgentVoiceTests() {
    // П10 р3 Н-7: «отправь» и адрес сессии — по тому, что сказал человек, а не по ответу модели.
    do {
        var result = DictationResult(session: "s", text: "Поправь тест, отправь.", rawText: "поправь тест",
                                     language: "ru", verifier: "off")
        equal(SpokenCommands.spoken(result), nil, "без причёсывания модели не было — проверять не по чему")
        result.polished = true
        result.unpolishedText = "поправь тест"
        equal(SpokenCommands.spoken(result), "поправь тест", "текст до модели")
        result.unpolishedText = nil
        equal(SpokenCommands.spoken(result), "поправь тест", "нет промежуточного — сырой")

        let polished = "Поправь тест, отправь."
        equal(SpokenCommands.send(polished, spoken: "поправь тест"), VoiceSendResult(text: polished, submit: false),
              "«отправь» дописала модель — Enter не жмём")
        equal(SpokenCommands.send(polished, spoken: "поправь тест отправь"), VoiceSendResult(text: "Поправь тест.", submit: true),
              "человек сказал «отправь» — жмём")
        equal(SpokenCommands.send(polished, spoken: nil), VoiceSend.detect(polished), "без модели — как было")

        let candidates = [AddressCandidate(id: "%1", names: ["фронтенд"]), AddressCandidate(id: "%2", names: ["бэкенд"])]
        check(SessionAddress.parse("Бэкенду: удали базу", candidates: candidates)?.id == "%2", "адрес находится в тексте")
        check(SpokenCommands.address("Бэкенду: удали базу", spoken: "удали базу", candidates: candidates) == nil,
              "обращение дописала модель — в другую панель не уводим")
        check(SpokenCommands.address("Фронтенду: поправь тест", spoken: "фронтенду поправь тест", candidates: candidates)?.id == "%1",
              "обращение сказано — адресуем")
        check(SpokenCommands.address("Фронтенду: поправь тест", spoken: "бэкенду поправь тест", candidates: candidates) == nil,
              "модель сменила адрес — нет")
        check(SpokenCommands.address("Фронтенду: поправь тест", spoken: nil, candidates: candidates)?.id == "%1", "без модели — как было")
    }
    // П10 р3 Н-8: в терминал и tmux — без управляющих знаков: `ESC[201~` закрыл бы bracketed paste раньше времени.
    do {
        let hostile = "a\u{1B}[201~\nrm x"
        check(!VoiceSend.terminalNewlines(hostile).unicodeScalars.contains("\u{1B}"), "ESC вырезан")
        equal(VoiceSend.terminalNewlines(hostile), "a[201~\nrm x")
        equal(VoiceSend.terminalNewlines("a\u{9B}201~b\u{7F}c\u{07}d\u{0}e"), "a201~bcde", "C1, DEL, BEL и NUL — прочь")
        equal(VoiceSend.terminalNewlines("строка 1\r\nстрока\t2\rитог"), "строка 1\nстрока\t2\nитог", "LF и таб остаются")
        equal(VoiceSend.terminalNewlines("Привет, мир — «ёлки» 🎄"), "Привет, мир — «ёлки» 🎄", "обычный текст не трогаем")
    }
    // MARK: G6 — голосовая отправка
    do {
        equal(VoiceSend.detect("Поправь тест, отправь."), VoiceSendResult(text: "Поправь тест.", submit: true))
        equal(VoiceSend.detect("Поправь тест отправь"), VoiceSendResult(text: "Поправь тест", submit: true), "без запятой")
        equal(VoiceSend.detect("Поправь тест. Отправь"), VoiceSendResult(text: "Поправь тест.", submit: true), "точка остаётся")
        equal(VoiceSend.detect("Run the tests, send."), VoiceSendResult(text: "Run the tests.", submit: true))
        equal(VoiceSend.detect("Run the tests. Send!"), VoiceSendResult(text: "Run the tests.", submit: true))
        equal(VoiceSend.detect("Отправь."), VoiceSendResult(text: "", submit: true), "одно слово — просто Enter")
        let mail = "Отправь письмо Маше"
        equal(VoiceSend.detect(mail), VoiceSendResult(text: mail, submit: false), "«отправь» не в конце")
        equal(VoiceSend.detect("Отправь письмо Маше."), VoiceSendResult(text: "Отправь письмо Маше.", submit: false))
        equal(VoiceSend.detect("Напиши письмо Маше и отправь").submit, false, "«и отправь» — просьба агенту")
        equal(VoiceSend.detect("Только не отправь").submit, false, "отрицание")
        equal(VoiceSend.detect("I want to send").submit, false, "to send")
        equal(VoiceSend.detect("Don't send").submit, false, "don't send")
        equal(VoiceSend.detect("Проверь отправку").submit, false, "другое слово")
        equal(VoiceSend.detect("Проверь sender").submit, false, "часть слова")
        equal(VoiceSend.detect("Напиши письмо и, отправь").submit, true, "запятая — граница фразы")
        equal(VoiceSend.detect(""), VoiceSendResult(text: "", submit: false))
        equal(VoiceSend.terminalNewlines("a\r\nb\rc\nd"), "a\nb\nc\nd", "в терминал — LF")
    }

    // MARK: A5 — адресация по имени
    do {
        let panes = [AddressCandidate(id: "%1", names: ["frontend", "claude", "web-app"]),
                     AddressCandidate(id: "%2", names: ["backend", "zsh", "api-server"]),
                     AddressCandidate(id: "%3", names: ["0", "node", "mostik"])]
        equal(SessionAddress.parse("Фронтенду: поправь тест.", candidates: panes),
              AddressMatch(id: "%1", name: "frontend", rest: "Поправь тест."), "дательный с двоеточием")
        equal(SessionAddress.parse("Бэкенд, стоп", candidates: panes)?.id, "%2", "бэкенд → backend по остову")
        equal(SessionAddress.parse("Бэкенд, стоп", candidates: panes)?.rest, "Стоп")
        equal(SessionAddress.parse("фронтенду поправь тест", candidates: panes)?.id, "%1", "дательный без знака")
        equal(SessionAddress.parse("Мостику: обнови README", candidates: panes)?.id, "%3", "папка проекта")
        equal(SessionAddress.parse("backend: run migrations", candidates: panes)?.rest, "Run migrations")
        equal(SessionAddress.parse("Бэкенд падает на старте", candidates: panes), nil, "без знака и не дательный")
        equal(SessionAddress.parse("Привет, как дела", candidates: panes), nil, "чужое обращение")
        equal(SessionAddress.parse("Клоду: проверь", candidates: panes), nil, "автоматическое имя окна не адрес")
        equal(SessionAddress.parse("Фронтенду:", candidates: panes), nil, "пустой текст")
        let twins = [AddressCandidate(id: "%1", names: ["frontend"]), AddressCandidate(id: "%4", names: ["front-end"])]
        equal(SessionAddress.parse("Фронтенду: собери", candidates: twins), nil, "две сессии с одним именем — неоднозначно")
        equal(NameKey.skeleton(NameKey.key("бэкенд")), NameKey.skeleton(NameKey.key("backend")))
        check(NameKey.skeleton(NameKey.key("фронтенд")) != NameKey.skeleton(NameKey.key("backend")))
    }

    // MARK: G5 — tmux
    do {
        let line1 = ["%1", "frontend", "0", "1", "100", "1", "1", "1", "node", "claude", "/Users/u/code/web-app"].joined(separator: "\t")
        let line2 = ["%2", "backend", "1", "0", "200", "1", "0", "0", "zsh", "zsh", "/Users/u/code/api\tserver"].joined(separator: "\t")
        let panes = Tmux.parsePanes(line1 + "\n" + line2 + "\nмусор\n")
        equal(panes.count, 2, "две панели, мусор пропущен")
        equal(panes.first?.label, "frontend:0.1")
        equal(panes.last?.path, "/Users/u/code/api\tserver", "табуляция в пути не ломает разбор")
        check(panes.first?.visible == true && panes.last?.visible == false, "видна только панель подключённой сессии")
        check(Tmux.listFormat.hasSuffix("#{pane_current_path}"), "путь последним")

        let processes = [ProcessEntry(pid: 100, ppid: 50, name: "zsh"),
                         ProcessEntry(pid: 101, ppid: 100, name: "node", startTime: 10, args: ["node", "/usr/local/lib/claude.js"]),
                         ProcessEntry(pid: 102, ppid: 101, name: "claude", startTime: 20),
                         ProcessEntry(pid: 200, ppid: 50, name: "zsh"),
                         ProcessEntry(pid: 201, ppid: 200, name: "vim"),
                         ProcessEntry(pid: 300, ppid: 1, name: "codex")]
        let agents = Tmux.agentPanes(panes, processes: processes, names: ["claude", "codex"])
        equal(agents.map(\.pane.id), ["%1"], "агент только в первой панели; чужой codex не в tmux")
        equal(agents.first?.agentPID, 101, "самый ранний агент панели — под node")
        equal(agents.first?.agent, "claude", "имя из argv интерпретатора")

        equal(Tmux.pasteCommands(pane: "%1", buffer: "mostik-x"),
              [["load-buffer", "-b", "mostik-x", "-"], ["paste-buffer", "-p", "-d", "-b", "mostik-x", "-t", "%1"]],
              "bracketed paste из своего буфера с удалением")
        equal(Tmux.enterCommand(pane: "%1"), ["send-keys", "-t", "%1", "Enter"])
        equal(Tmux.bufferName("ab/c;d 1"), "mostik-abcd1", "имя буфера без спецсимволов")

        let a = TmuxAgentPane(pane: TmuxPane(id: "%1", session: "frontend", active: true, windowActive: true, attached: 1),
                              agent: "claude", agentPID: 1, project: "/u/web-app")
        let b = TmuxAgentPane(pane: TmuxPane(id: "%2", session: "backend"), agent: "codex", agentPID: 2)
        equal(TmuxTargeting.choose([b], preference: "auto")?.pane.id, "%2", "единственная панель с агентом")
        equal(TmuxTargeting.choose([a, b], preference: "auto")?.pane.id, "%1", "видимая из нескольких")
        equal(TmuxTargeting.choose([b, b], preference: "auto"), nil, "неоднозначно — обычная вставка")
        equal(TmuxTargeting.choose([a, b], preference: "%2")?.pane.id, "%2", "закреплённая")
        equal(TmuxTargeting.choose([a, b], preference: "%9"), nil, "закреплённой нет — не угадываем")
        equal(TmuxTargeting.choose([a, b], preference: "auto", focusedSession: "frontend")?.pane.id, "%1", "сессия терминала впереди")
        equal(TmuxTargeting.choose([a, b], preference: "auto", focusedSession: "backend"), nil,
              "в показанной сессии агент не в активной панели — не уводим текст")
        equal(TmuxTargeting.choose([a, b], preference: "auto", focusedSession: "other"), nil)
        let clients = Tmux.parseClients("501\t1760000100\tfrontend\n502\t1760000200\tbackend\nxx\n")
        equal(clients.count, 2)
        equal(TmuxTargeting.focusedSession(clients, frontClientPIDs: [501]), "frontend")
        equal(TmuxTargeting.focusedSession(clients, frontClientPIDs: [501, 502]), "backend", "свежий ввод")
        equal(TmuxTargeting.focusedSession(clients, frontClientPIDs: [999]), nil)
        equal(a.names, ["frontend", "web-app"], "имена для обращения")
        equal(a.title, "frontend · claude · web-app")
        equal(SessionAddress.parse("Веб апп: собери", candidates: TmuxTargeting.candidates([a, b]))?.id, "%1",
              "имя папки из двух слов")
    }

    // MARK: A3 — автотег файлов
    do {
        let index = FileIndex(paths: ["src/authCheck.ts", "src/auth/session_store.py", "lib/user-profile.tsx",
                                      "README.md", "src/main.py", "tests/main.py", "src/api.ts", "docs/setup.md"])
        equal(FileMentions.split("authCheck"), ["auth", "check"])
        equal(FileMentions.split("session_store"), ["session", "store"])
        equal(FileMentions.split("HTTPServer2"), ["httpserver", "2"])
        equal(FileMentions.apply("Поправь проверку в auth check", index: index).text, "Поправь проверку в @src/authCheck.ts")
        equal(FileMentions.apply("Look at session store and user profile.", index: index).text,
              "Look at @src/auth/session_store.py and @lib/user-profile.tsx.", "snake и kebab")
        equal(FileMentions.apply("Открой authCheck", index: index).text, "Открой @src/authCheck.ts", "одно слово в camelCase")
        equal(FileMentions.apply("Обнови api и readme", index: index).text, "Обнови api и readme", "однословные без «файл» не трогаем")
        equal(FileMentions.apply("Обнови файл readme", index: index).text, "Обнови файл @README.md", "после «файл» — можно")
        equal(FileMentions.apply("в файле setup", index: index).text, "в файле @docs/setup.md")
        equal(FileMentions.apply("в файле main", index: index).text, "в файле main", "два main.py — неоднозначно")
        equal(FileMentions.apply("Глянь @src/authCheck.ts", index: index).text, "Глянь @src/authCheck.ts", "уже тег")
        equal(FileMentions.apply("auth, check", index: index).text, "auth, check", "через запятую — не имя")
        equal(FileMentions.apply("аус чек", index: index).text, "аус чек", "кириллица не трогается")
        equal(FileMentions.apply("auth check", index: FileIndex()).tagged, [], "пустой индекс")
        equal(FileMentions.apply("auth check and session store", index: index).tagged,
              ["src/authCheck.ts", "src/auth/session_store.py"])

        let policy = AgentAppPolicy.standard
        check(FileMentionApps.supports(FrontApp(bundleID: "com.mitchellh.ghostty", runningAgentCLIs: ["claude"]), policy: policy),
              "терминал с claude")
        check(!FileMentionApps.supports(FrontApp(bundleID: "com.mitchellh.ghostty", runningAgentCLIs: ["aider"]), policy: policy),
              "aider не понимает @")
        check(FileMentionApps.supports(FrontApp(bundleID: "com.todesktop.230313mzl4w4u92"), policy: policy), "Cursor")
        check(!FileMentionApps.supports(FrontApp(bundleID: "com.anthropic.claudefordesktop"), policy: policy),
              "Claude для Mac не видит файлы проекта")
        check(!FileMentionApps.supports(FrontApp(bundleID: "ru.keepcoder.Telegram"), policy: policy), "мессенджер")
    }

    // MARK: A1 — события хуков и озвучка
    do {
        let stop = #"{"mostik":1,"event":"stop","tmux_pane":"%3","at":1760000000}"# + "\n"
            + #"{"session_id":"s-1","cwd":"/u/code/web-app","transcript_path":"/tmp/t.jsonl","hook_event_name":"Stop"}"#
        let event = AgentEvents.parse(stop)
        equal(event?.kind, .done)
        equal(event?.tmuxPane, "%3")
        equal(event?.cwd, "/u/code/web-app")
        equal(event?.at, Date(timeIntervalSince1970: 1_760_000_000))
        let permission = #"{"mostik":1,"event":"notification","tmux_pane":"","at":1}"# + "\n"
            + #"{"session_id":"s-1","message":"Claude needs your permission to use Bash","hook_event_name":"Notification"}"#
        equal(AgentEvents.parse(permission)?.kind, .permission, "разрешение по тексту")
        equal(AgentEvents.parse(permission)?.tmuxPane, nil, "пустая панель")
        let typed = #"{"mostik":1,"event":"notification","at":1}"# + "\n" + #"{"notification_type":"permission_prompt","message":"x"}"#
        equal(AgentEvents.parse(typed)?.kind, .permission, "разрешение по типу")
        let idle = #"{"mostik":1,"event":"notification","at":1}"# + "\n" + #"{"message":"Claude is waiting for your input"}"#
        equal(AgentEvents.parse(idle), nil, "ожидание ввода не озвучиваем")
        equal(AgentEvents.parse(#"{"mostik":1,"event":"stop","tmux_pane":"%3;rm","at":1}"#)?.tmuxPane, nil, "панель проверяется")
        equal(AgentEvents.parse("не json"), nil)
        equal(AgentEvents.parse(#"{"event":"stop"}"#), nil, "без заголовка Mostik")

        let transcript = [
            #"{"type":"user","message":{"role":"user","content":"поправь тест"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Смотрю."}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash"},{"type":"text","text":"**Готово:** тест `auth` проходит. Дальше — ревью."}]}}"#,
            #"{"type":"system","subtype":"x"}"#,
        ].joined(separator: "\n")
        equal(AgentEvents.lastAssistantSentence(transcript: transcript), "Готово: тест auth проходит.")
        equal(AgentEvents.lastAssistantSentence(transcript: #"{"type":"assistant","message":{"content":[{"type":"text","text":"```\ncode\n```"}]}}"#),
              nil, "только код — нечего сказать")
        let long = String(repeating: "слово ", count: 60)
        check((AgentEvents.firstSentence(long, limit: 40).count) <= 41, "длинная фраза обрезана")

        let done = AgentEvent(kind: .done)
        equal(AgentEvents.announcement(done, project: "/u/code/mostik", session: nil, summary: "Тесты проходят.", russian: true),
              "mostik: готово. Тесты проходят.")
        equal(AgentEvents.announcement(AgentEvent(kind: .permission), project: "/u/code/mostik", session: nil, summary: nil, russian: true),
              "Проекту mostik нужно разрешение.")
        equal(AgentEvents.announcement(AgentEvent(kind: .permission), project: "/u/code/web-app", session: "frontend",
                                       summary: nil, russian: true),
              "Проекту web-app, сессия frontend, нужно разрешение.", "сессия называется, если отличается")
        equal(AgentEvents.announcement(AgentEvent(kind: .permission), project: "/u/mostik", session: "Mostik", summary: nil, russian: false),
              "mostik needs your permission.", "одинаковые имена не повторяем")
        equal(AgentEvents.announcement(done, project: nil, session: nil, summary: nil, russian: false), "The agent is done.")
        check(AgentEvents.sound(.done) != AgentEvents.sound(.permission), "разные звуки")

        let first = AgentEvent(kind: .done, sessionID: "s", at: Date(timeIntervalSince1970: 100))
        check(AgentEvents.isDuplicate(AgentEvent(kind: .done, sessionID: "s", at: Date(timeIntervalSince1970: 102)), of: first))
        check(!AgentEvents.isDuplicate(AgentEvent(kind: .permission, sessionID: "s", at: Date(timeIntervalSince1970: 102)), of: first))
        check(!AgentEvents.isDuplicate(AgentEvent(kind: .done, sessionID: "s", at: Date(timeIntervalSince1970: 110)), of: first))
    }

    // MARK: A1 — установка хуков
    do {
        let script = "/Users/u/Library/Application Support/Mostik/hooks/mostik-notify.sh"
        let foreign: [String: Any] = ["model": "opus", "hooks": ["Stop": [["hooks": [["type": "command", "command": "afplay x.aiff"]]]],
                                                                  "PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "guard.sh"]]]]]]
        check(!ClaudeHooks.isInstalled(foreign))
        let installed = ClaudeHooks.install(into: foreign, scriptPath: script)
        check(ClaudeHooks.isInstalled(installed), "установлено")
        let hooks = installed["hooks"] as? [String: Any] ?? [:]
        equal((hooks["Stop"] as? [Any])?.count, 2, "чужой Stop остался")
        equal((hooks["PreToolUse"] as? [Any])?.count, 1, "чужой хук не тронут")
        equal(installed["model"] as? String, "opus", "прочие ключи на месте")
        let again = ClaudeHooks.install(into: installed, scriptPath: script)
        equal(((again["hooks"] as? [String: Any])?["Stop"] as? [Any])?.count, 2, "повторная установка не дублирует")
        let removed = ClaudeHooks.uninstall(from: again)
        check(!ClaudeHooks.isInstalled(removed))
        equal(((removed["hooks"] as? [String: Any])?["Stop"] as? [Any])?.count, 1, "удалено только своё")
        equal((removed["hooks"] as? [String: Any])?["Notification"] == nil, true, "пустой список убран")
        let fresh = ClaudeHooks.install(into: [:], scriptPath: script)
        check(ClaudeHooks.isInstalled(fresh), "в пустой файл")
        equal(ClaudeHooks.uninstall(from: fresh)["hooks"] == nil, true, "после удаления hooks не остаётся")
        check(ClaudeHooks.load(Data("{ битый".utf8)) == nil, "битый JSON не трогаем")
        check(ClaudeHooks.load(nil)?.isEmpty == true, "нет файла — пусто")
        check(ClaudeHooks.preview(scriptPath: script).contains("'\(script)' stop"), "команда в кавычках: в пути пробел")
    }

    // MARK: A1 — скрипт-приёмник хука
    do {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = repo.appendingPathComponent("integrations/claude-code/hooks/mostik-notify.sh")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mostik-hooktest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func run(_ arg: String, input: String, pane: String?) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [script.path, arg]
            var env = ["MOSTIK_EVENTS_DIR": dir.path, "PATH": "/usr/bin:/bin"]
            if let pane { env["TMUX_PANE"] = pane }
            p.environment = env
            let pipe = Pipe()
            p.standardInput = pipe
            p.standardOutput = FileHandle.nullDevice
            do { try p.run() } catch { return -1 }
            pipe.fileHandleForWriting.write(Data(input.utf8))
            try? pipe.fileHandleForWriting.close()
            p.waitUntilExit()
            return p.terminationStatus
        }
        func events() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") }
        }
        equal(run("stop", input: #"{"session_id":"s"}"#, pane: "%4"), 0)
        equal(events().count, 0, "без маркера .listening ничего не пишет")
        FileManager.default.createFile(atPath: dir.appendingPathComponent(AgentEvents.listeningMarker).path, contents: Data())
        equal(run("stop", input: #"{"session_id":"s","cwd":"/u/x"}"#, pane: "%4"), 0)
        equal(run("bogus", input: "{}", pane: nil), 0, "чужой аргумент — молча 0")
        equal(run("notification", input: #"{"message":"needs your permission"}"#, pane: "%4;evil"), 0)
        let files = events().sorted()
        equal(files.count, 2, "два события")
        let parsed = files.compactMap { name -> AgentEvent? in
            let text = (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
            return AgentEvents.parse(text)
        }
        equal(Set(parsed.map(\.kind)), [.done, .permission], "оба события разбираются")
        equal(parsed.first(where: { $0.kind == .done })?.tmuxPane, "%4")
        equal(parsed.first(where: { $0.kind == .permission })?.tmuxPane, nil, "подозрительная панель отброшена")
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: настройки П4
    do {
        let d = AgentVoiceSettings()
        check(!d.tmuxPaste && !d.voiceSend && !d.announce, "вставка в tmux, отправка и озвучка выключены по умолчанию")
        check(d.fileMentions, "автотег включён, но только в приложениях с @")
        let decoded = try? JSONDecoder().decode(AgentVoiceSettings.self, from: Data(#"{"voiceSend":true}"#.utf8))
        equal(decoded?.voiceSend, true)
        equal(decoded?.tmuxTarget, "auto", "недостающие поля — по умолчанию")
    }
}
