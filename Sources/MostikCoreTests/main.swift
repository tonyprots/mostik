import Foundation
import MostikCore

// Минимальный раннер: в Command Line Tools нет ни XCTest, ни swift-testing.
var failures = 0
var passed = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String = "", file: String = #fileID, line: Int = #line) {
    if condition() { passed += 1 } else {
        failures += 1
        print("FAIL \(file):\(line) — \(message)")
    }
}

func equal<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: String = #fileID, line: Int = #line) {
    check(a == b, "\(message) ожидалось \(b), получено \(a)", file: file, line: line)
}

// Ядро говорит на языке интерфейса (UIText); тесты сверяют русские подписи на любой системе, в том числе в CI.
UIText.isRussian = true

// MARK: DoubtResolution — слова под вопросом решаются в интерфейсе (C3–C5)
do {
    let doubts = [Doubt(heard: "parakeet", suggestion: "parakeet_tdt", context: "bump parakeet in"),
                  Doubt(heard: "warm mike", suggestion: "warm_mic")]
    let entry = HistoryEntry(id: "e", text: "Bump parakeet now. If warm mike fails, revert Warm Mike.",
                             insertedText: "Bump parakeet now. If warm mike fails, revert Warm Mike.", doubts: doubts)
    // C3: сохранённое написание снимает отметку сомнения и правит текст записи.
    let accepted = DoubtResolution.accept(entry, heard: "warm mike", canonical: "warm_mic")
    equal(accepted.text, "Bump parakeet now. If warm_mic fails, revert warm_mic.", "принятая подсказка правит текст")
    equal(accepted.insertedText, accepted.text, "и вставленный текст записи")
    equal(accepted.doubts.map(\.heard), ["parakeet"], "сомнение снято, остальные на месте")
    // «Запомнить написание» с другим услышанным, но тем же вариантом — тоже снимает.
    equal(DoubtResolution.accept(entry, heard: "паракит", canonical: "Parakeet_TDT").doubts.map(\.heard), ["warm mike"],
          "то же написание закрывает сомнение")
    // Слово внутри идентификатора не трогаем.
    let inside = HistoryEntry(id: "i", text: "parakeet_tdt и parakeet", doubts: [doubts[0]])
    equal(DoubtResolution.accept(inside, heard: "parakeet", canonical: "parakeet_tdt").text, "parakeet_tdt и parakeet_tdt",
          "замена только целым словом")
    // C5: отказ снимает сомнение, текст не меняется.
    let rejected = DoubtResolution.reject(entry, doubt: doubts[1])
    equal(rejected.text, entry.text, "отказ не меняет текст")
    equal(rejected.doubts, [doubts[0]], "отказ снимает только это сомнение")
    // Старые записи с блоком для агента: показываем текст без блока.
    equal(DoubtResolution.legacyBody("Сделай.\n\n[Слова под вопросом: «a»? Скажи, как понял.]"), "Сделай.")
    equal(DoubtResolution.legacyBody("Массив [1, 2]"), "Массив [1, 2]", "обычные скобки не блок")
}

// MARK: AgentAppPolicy
do {
    let p = AgentAppPolicy.standard
    check(p.isAgent(FrontApp(bundleID: "com.mitchellh.ghostty", runningAgentCLIs: ["claude"])), "терминал с claude")
    check(!p.isAgent(FrontApp(bundleID: "com.mitchellh.ghostty", runningAgentCLIs: [])), "терминал без агента")
    check(p.isAgent(FrontApp(bundleID: "com.todesktop.230313mzl4w4u92")), "Cursor")
    check(p.isAgent(FrontApp(bundleID: "com.google.Chrome", windowTitle: "Claude — New chat")), "браузер с Claude")
    check(!p.isAgent(FrontApp(bundleID: "com.google.Chrome", windowTitle: "Почта")), "браузер без агента")
    check(!p.isAgent(FrontApp(bundleID: "ru.keepcoder.Telegram")), "мессенджер")
    var q = p; q.forcedOff = ["com.todesktop.230313mzl4w4u92"]; q.forcedOn = ["ru.keepcoder.Telegram"]
    check(!q.isAgent(FrontApp(bundleID: "com.todesktop.230313mzl4w4u92")), "ручное выключение")
    check(q.isAgent(FrontApp(bundleID: "ru.keepcoder.Telegram")), "ручное включение")
}

// MARK: DictationMachine
do {
    var m = DictationMachine(minimumHold: 0.25, makeSessionID: { "s1" })
    equal(m.handle(.holdBegan(at: 0)), [.startRecording(session: "s1")])
    equal(m.handle(.holdEnded(at: 0.1)), [.discardRecording(session: "s1")], "короткое нажатие")
    equal(m.state, .idle)
    m.handle(.holdBegan(at: 1))
    equal(m.handle(.holdEnded(at: 3)), [.stopRecording(session: "s1")])
    equal(m.state, .transcribing(session: "s1", audioSeconds: 2))
    equal(m.handle(.holdBegan(at: 4)), [], "во время расшифровки новое нажатие игнорируется")
    equal(m.handle(.cancel), [], "отмена во время расшифровки не теряет результат")
    equal(m.state, .transcribing(session: "s1", audioSeconds: 2))
    equal(m.handle(.resultReady), [.insertResult(session: "s1")])
    m.handle(.inserted)
    equal(m.state, .idle)
    m.handle(.togglePressed(at: 10))
    equal(m.handle(.holdEnded(at: 10.5)), [], "в режиме переключения отпускание не останавливает")
    equal(m.handle(.togglePressed(at: 20)), [.stopRecording(session: "s1")])
    equal(m.handle(.failure("движок упал")), [.showError("движок упал")])
    equal(m.handle(.holdBegan(at: 30)), [.startRecording(session: "s1")], "после ошибки можно снова диктовать")
    equal(m.handle(.cancel), [.discardRecording(session: "s1")])
    equal(m.handle(.failure("x")), [], "ошибка в покое ничего не делает")
}

// MARK: DictationMachine — без рук (D1)
do {
    final class Counter: @unchecked Sendable { var n = 0 }
    let counter = Counter()
    var m = DictationMachine(minimumHold: 0.25, makeSessionID: { counter.n += 1; return "h\(counter.n)" })
    // Двойное нажатие: первое короткое отбрасывается, второе продолжает запись без рук.
    equal(m.handle(.holdBegan(at: 0)), [.startRecording(session: "h1")])
    equal(m.handle(.holdEnded(at: 0.1)), [.discardRecording(session: "h1")], "первое нажатие")
    equal(m.handle(.holdBegan(at: 0.4)), [.startRecording(session: "h2")], "второе нажатие")
    equal(m.handle(.holdEnded(at: 0.5)), [], "второе отпускание не останавливает")
    check(m.isHandsFree, "режим без рук")
    equal(m.state, .recording(session: "h2", startedAt: 0.4, toggled: true))
    equal(m.handle(.holdBegan(at: 5)), [.stopRecording(session: "h2")], "одиночное нажатие останавливает")
    check(!m.isHandsFree, "режим снят")
    equal(m.handle(.holdEnded(at: 5.1)), [], "отпускание после остановки ничего не делает")
    equal(m.state, .transcribing(session: "h2", audioSeconds: 4.6))
    m.handle(.resultReady); m.handle(.inserted)

    // Пауза больше 0,4 с — это два отдельных нажатия.
    m.handle(.holdBegan(at: 10)); m.handle(.holdEnded(at: 10.1))
    m.handle(.holdBegan(at: 10.6))
    equal(m.handle(.holdEnded(at: 10.7)), [.discardRecording(session: "h4")], "далёкое второе нажатие")
    check(!m.isHandsFree)

    // Второе нажатие длинное — обычная диктовка с удержанием.
    m.handle(.holdBegan(at: 20)); m.handle(.holdEnded(at: 20.1))
    m.handle(.holdBegan(at: 20.3))
    equal(m.handle(.holdEnded(at: 22)), [.stopRecording(session: "h6")], "второе нажатие с удержанием")
    check(!m.isHandsFree)
    m.handle(.resultReady); m.handle(.inserted)

    // Нажатие 0,27 с при включённом режиме — тоже «тап», а не диктовка обрывка.
    m.handle(.holdBegan(at: 30))
    equal(m.handle(.holdEnded(at: 30.27)), [.discardRecording(session: "h7")], "тап короче 0,3 с")

    // Esc в режиме без рук отменяет запись.
    m.handle(.holdBegan(at: 40)); m.handle(.holdEnded(at: 40.1))
    m.handle(.holdBegan(at: 40.3)); m.handle(.holdEnded(at: 40.4))
    equal(m.handle(.cancel), [.discardRecording(session: "h9")], "отмена без рук")
    check(!m.isHandsFree)
    equal(m.state, .idle)

    // Режим выключен: короткие нажатия не включают запись без рук.
    var off = DictationMachine(minimumHold: 0.25, makeSessionID: { "o" })
    off.doubleTapEnabled = false
    off.handle(.holdBegan(at: 0)); off.handle(.holdEnded(at: 0.1))
    off.handle(.holdBegan(at: 0.3))
    equal(off.handle(.holdEnded(at: 0.4)), [.discardRecording(session: "o")], "без режима")
    off.handle(.holdBegan(at: 1))
    equal(off.handle(.holdEnded(at: 1.28)), [.stopRecording(session: "o")], "без режима 0,28 с — диктовка")

    // ⌥Space-переключатель не останавливается нажатием клавиши удержания.
    var t = DictationMachine(minimumHold: 0.25, makeSessionID: { "t" })
    t.handle(.togglePressed(at: 0))
    equal(t.handle(.holdBegan(at: 1)), [], "удержание в режиме ⌥Space")
}

// MARK: D2 — сырой текст
do {
    let ok = DictationResult(session: "s", text: " Готово ", rawText: "готово")
    equal(ok.insertable.text, "Готово"); check(!ok.insertable.raw)
    let broken = DictationResult(session: "s", text: "", rawText: "сырой текст")
    equal(broken.insertable.text, "сырой текст"); check(broken.insertable.raw, "сбой обработки → сырой")
    equal(DictationResult(session: "s", text: "").insertable.text, "")
    equal(DictationResult(session: "s", text: "x", rawText: "  ").rawTextForHistory, nil)
    equal(DictationResult.rawFallback(session: "s", partial: "  черновик ", language: "ru")?.insertable.text, "черновик")
    equal(DictationResult.rawFallback(session: "s", partial: " ", language: "ru"), nil)
    let entry = HistoryEntry(id: "r", text: "Parakeet", rawText: "пара кит")
    let data = try? JSONEncoder().encode(entry)
    equal(data.flatMap { try? JSONDecoder().decode(HistoryEntry.self, from: $0) }?.rawText, "пара кит", "rawText сохраняется")
}

// MARK: ProjectResolver
do {
    let procs = [
        ProcessEntry(pid: 100, ppid: 1, name: "ghostty", path: "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
        ProcessEntry(pid: 101, ppid: 100, name: "login"),
        ProcessEntry(pid: 102, ppid: 101, name: "zsh"),
        ProcessEntry(pid: 103, ppid: 102, name: "claude", path: "/Users/a/.local/share/claude/versions/2.1.3", startTime: 10),
        ProcessEntry(pid: 104, ppid: 102, name: "node", path: "/opt/homebrew/bin/node", startTime: 20,
                     args: ["node", "/opt/homebrew/bin/codex", "--full-auto"]),
        // Чужой терминал.
        ProcessEntry(pid: 200, ppid: 1, name: "Terminal", path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
        ProcessEntry(pid: 201, ppid: 200, name: "claude", startTime: 30),
        // iTerm2: оболочки под iTermServer, родитель которого launchd.
        ProcessEntry(pid: 300, ppid: 1, name: "iTerm2", path: "/Applications/iTerm.app/Contents/MacOS/iTerm2"),
        ProcessEntry(pid: 301, ppid: 1, name: "iTermServer-3.5", path: "/Applications/iTerm.app/Contents/Resources/iTermServer-3.5"),
        ProcessEntry(pid: 302, ppid: 301, name: "zsh"),
        ProcessEntry(pid: 303, ppid: 302, name: "codex", startTime: 5),
        // Петля в данных не вешает обход.
        ProcessEntry(pid: 400, ppid: 401, name: "claude"),
        ProcessEntry(pid: 401, ppid: 400, name: "zsh"),
    ]
    let names: Set<String> = ["claude", "codex"]
    equal(ProjectResolver.agentProcesses(appPID: 100, appBundlePath: "/Applications/Ghostty.app", in: procs, names: names).map(\.pid),
          [104, 103], "агенты Ghostty, новые первыми; codex под node")
    equal(ProjectResolver.agentProcesses(appPID: 200, appBundlePath: nil, in: procs, names: names).map(\.pid), [201])
    equal(ProjectResolver.agentProcesses(appPID: 300, appBundlePath: "/Applications/iTerm.app", in: procs, names: names).map(\.pid),
          [303], "iTerm2 через iTermServer")
    equal(ProjectResolver.agentProcesses(appPID: 999, appBundlePath: nil, in: procs, names: names), [], "нет агента")
    check(!ProjectResolver.isAgent(ProcessEntry(pid: 1, ppid: 0, name: "node", args: ["node", "server.js"]), names: names))
    check(ProjectResolver.isAgent(ProcessEntry(pid: 1, ppid: 0, name: "node", args: ["node", "/x/claude.js"]), names: names))

    let gits: Set<String> = ["/Users/a/code/app", "/Users/a/code/app/vendor/lib"]
    equal(ProjectResolver.gitRoot(of: "/Users/a/code/app/Sources/Core", hasGitMarker: { gits.contains($0) }), "/Users/a/code/app")
    equal(ProjectResolver.gitRoot(of: "/Users/a/code/app/vendor/lib/x", hasGitMarker: { gits.contains($0) }), "/Users/a/code/app/vendor/lib",
          "ближайший корень")
    equal(ProjectResolver.gitRoot(of: "/Users/a/notes", hasGitMarker: { gits.contains($0) }), nil, "не git")
    equal(ProjectResolver.gitRoot(of: "relative/path", hasGitMarker: { _ in true }), nil)
    equal(ProjectResolver.projectRoot(of: "/Users/a/code/app/Sources", home: "/Users/a", hasGitMarker: { gits.contains($0) }),
          "/Users/a/code/app", "проект — корень git")
    equal(ProjectResolver.projectRoot(of: "/Users/a/Work", home: "/Users/a", hasGitMarker: { _ in false }),
          "/Users/a/Work", "без git — рабочая папка")
    equal(ProjectResolver.projectRoot(of: "/Users/a", home: "/Users/a", hasGitMarker: { _ in false }), nil, "домашняя папка — не проект")
    equal(ProjectResolver.projectRoot(of: "/Users/a/notes", home: "/Users/a", hasGitMarker: { $0 == "/Users/a" }),
          "/Users/a/notes", "git в домашней папке не делает её проектом")
    equal(ProjectResolver.gitRoot(of: "/Users/a/code/app/./Sources/../", hasGitMarker: { gits.contains($0) }), "/Users/a/code/app")

    equal(ProjectResolver.chooseRoot(["/c/new", "/c/mostik"], windowTitle: "✳ mostik — claude"), "/c/mostik", "по заголовку")
    equal(ProjectResolver.chooseRoot(["/c/new", "/c/mostik"], windowTitle: ""), "/c/new", "самый свежий")
    equal(ProjectResolver.chooseRoot([], windowTitle: "x"), nil)

    check(ProjectResolver.effectiveProject(detected: "/a", autoEnabled: true, manual: "/m") == ("/a", true), "авто")
    check(ProjectResolver.effectiveProject(detected: nil, autoEnabled: true, manual: "/m") == ("/m", false), "запасной")
    check(ProjectResolver.effectiveProject(detected: "/a", autoEnabled: false, manual: "/m") == ("/m", false), "авто выключено")
    check(ProjectResolver.effectiveProject(detected: nil, autoEnabled: true, manual: nil) == (nil, false), "без проекта")

    // Термины из кода — режим разработчика: по умолчанию выключен, и старый файл настроек его не включает.
    var codeOff = MostikSettings()
    codeOff.projectPath = "/m"
    check(!codeOff.codeTerms, "термины из кода выключены по умолчанию")
    check(codeOff.codeProjectPath == nil && !codeOff.codeAutoProject, "без режима разработчика проект не берётся")
    check(ProjectResolver.effectiveProject(detected: "/a", autoEnabled: codeOff.codeAutoProject,
                                           manual: codeOff.codeProjectPath) == (nil, false), "найденный проект тоже не берётся")
    let oldFile = MostikSettings.decode(Data(#"{"autoProject": true, "projectPath": "/m"}"#.utf8))
    check(oldFile?.codeTerms == false && oldFile?.codeProjectPath == nil, "старые настройки: термины из кода выключены")
    codeOff.codeTerms = true
    check(codeOff.codeProjectPath == "/m" && codeOff.codeAutoProject, "включили — проект и автопоиск как раньше")

    var buf: [UInt8] = [2, 0, 0, 0]
    buf += Array("/opt/homebrew/bin/node".utf8) + [0, 0, 0]
    buf += Array("node".utf8) + [0] + Array("/opt/homebrew/bin/codex".utf8) + [0] + Array("PATH=/bin".utf8) + [0]
    equal(ProjectResolver.parseProcArgs(buf), ["node", "/opt/homebrew/bin/codex"], "KERN_PROCARGS2")
    equal(ProjectResolver.parseProcArgs([1, 0]), [])
}

// MARK: Календарь
do {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    let solo = CalendarEvent(id: "1", title: "Фокус", start: base, end: base + 3600, attendees: ["Я"])
    let sync = CalendarEvent(id: "2", title: "Синк", start: base, end: base + 1800, attendees: ["Антон", "Петя"], others: ["Петя"])
    let next = CalendarEvent(id: "3", title: "Ревью", start: base + 1800 + 300, end: base + 3600, attendees: ["Антон", "Маша"])
    let dup = CalendarEvent(id: "4", title: "Дубль", start: base, end: base + 60, attendees: ["Антон", "Антон"])
    equal(CalendarLogic.meetings([solo, sync, next, dup]).map(\.id), ["2", "3"], "≥2 разных участника")
    equal(CalendarLogic.current(in: [sync, next], at: base + 1700)?.id, "2", "идущая важнее ближайшей")
    equal(CalendarLogic.current(in: [sync, next], at: base + 1900)?.id, "3", "закончилась минуту назад, следующая через 4 мин")
    equal(CalendarLogic.current(in: [sync], at: base - 500)?.id, "2", "за 10 минут до начала")
    equal(CalendarLogic.current(in: [sync], at: base - 700)?.id, nil, "рано")
    equal(CalendarLogic.current(in: [sync], at: base + 1800 + 700)?.id, nil, "поздно")
    let fields = CalendarLogic.commandFields([sync])
    if case .array(let items)? = fields["events"], case .object(let o)? = items.first {
        equal(o["title"]?.stringValue, "Синк")
        check(o["start"]?.stringValue?.hasSuffix("Z") == true, "ISO 8601")
        if case .array(let a)? = o["attendees"] { equal(a.count, 2) } else { check(false, "attendees") }
    } else { check(false, "events") }
    equal(sync.others, ["Петя"])
    equal(solo.others, ["Я"], "others по умолчанию — все")
    equal(CalendarLogic.participantName(name: " ", url: "mailto:petya%40ya.ru"), "petya@ya.ru")
    equal(CalendarLogic.participantName(name: "Петя", url: "mailto:p@ya.ru"), "Петя")
    equal(CalendarLogic.participantName(name: nil, url: nil), nil)
}

// MARK: MeetingClock и метки
do {
    var c = MeetingClock(startedAt: 100)
    equal(c.elapsed(at: 110), 10)
    c.pause(at: 110)
    equal(c.elapsed(at: 130), 10, "на паузе время стоит")
    c.pause(at: 120)
    c.resume(at: 140)
    equal(c.elapsed(at: 150), 20, "пауза вычтена")
    c.resume(at: 160)
    equal(c.elapsed(at: 160), 30, "повторное снятие паузы безвредно")
    check(!c.isPaused)
    let marks = MeetingMarkPayload.fields([MeetingMarkPayload(at: 65.04, text: "б"), MeetingMarkPayload(at: 3, text: "а")])
    if case .array(let a) = marks, case .object(let first)? = a.first {
        equal(first["text"]?.stringValue, "а", "по времени")
        equal(a.count, 2)
    } else { check(false, "marks") }
}

// MARK: SourcesReply
do {
    let line = #"{"id":5,"ok":true,"sources":[{"kind":"repo","label":"mostik","path":"/c/mostik","scanned_at":"2026-10-10T12:00:00Z","counts":{"identifier":40,"tech":2},"total":42},{"kind":"calendar","label":"Календарь","path":null,"scanned_at":1791640000,"counts":{"person":3}},{"label":"без вида"}],"terms":[{"term":"AppModel","kind":"identifier","origins":["Sources/MostikUI/AppModel.swift:7"]},{"term":"AppModel","kind":"identifier","origins":[]},{"term":"Петя","kind":"person","origins":["календарь: Синк"]}]}"#
    if case .reply(_, _, let payload)? = EngineCodec.decode(line: line) {
        let r = SourcesReply.parse(payload)
        equal(r.sources.count, 2, "источник без вида пропущен")
        equal(r.sources.first?.total, 42)
        equal(r.sources.first?.counts["identifier"], 40)
        equal(r.sources.first?.scannedAt, Date(timeIntervalSince1970: 1_791_633_600))
        equal(r.sources.last?.path, nil)
        equal(r.sources.last?.total, 3, "total из суммы")
        equal(r.sources.last?.scannedAt, Date(timeIntervalSince1970: 1_791_640_000))
        equal(r.terms.map(\.term), ["AppModel", "Петя"], "дубли терминов схлопнуты")
        equal(r.terms.first?.origins, ["Sources/MostikUI/AppModel.swift:7"])
    } else { check(false, "sources reply") }
    equal(SourcesReply.parse([:]), SourcesReply())
}

// MARK: EngineCodec
do {
    let cmd = EngineCodec.command("start", id: 3, fields: ["session": .string("a/b"), "verify": .bool(true)])
    equal(cmd, #"{"cmd":"start","id":3,"session":"a/b","verify":true}"#)
    let finalLine = #"{"event":"final","session":"s","text":"Привет, Parakeet","raw_text":"привет пара кит","doubts":[{"heard":"x","suggestion":"X","context":"","kind":"term"}],"corrections":[{"from":"пара кит","to":"Parakeet"}],"language":"ru","timings":{"total_ms":420.5},"verifier":"late"}"#
    if case .final(let r)? = EngineCodec.decode(line: finalLine) {
        equal(r.text, "Привет, Parakeet"); equal(r.doubts.count, 1); equal(r.timings.totalMs, 420.5)
        equal(r.verifier, "late"); equal(r.corrections.first?.to, "Parakeet")
    } else { check(false, "final не разобран") }
    if case .reply(let id, let ok, let payload)? = EngineCodec.decode(line: #"{"id":7,"ok":true,"version":"0.1"}"#) {
        equal(id, 7); check(ok, "ok"); equal(payload["version"]?.stringValue, "0.1")
    } else { check(false, "reply не разобран") }
    if case .partial(let s, let t)? = EngineCodec.decode(line: #"{"event":"partial","session":"s","text":"раз"}"#) {
        equal(s, "s"); equal(t, "раз")
    } else { check(false, "partial") }
    if case .error(let id, _, let code, _)? = EngineCodec.decode(line: #"{"event":"error","id":2,"code":"busy","message":"m"}"#) {
        equal(id, 2); equal(code, "busy")
    } else { check(false, "error") }
    equal(EngineCodec.decode(line: "not json"), nil)
    equal(EngineCodec.decode(line: "[1,2]"), nil)
}

// MARK: HistoryStore
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mostik-tests-\(UUID().uuidString)")
    let store = HistoryStore(fileURL: dir.appendingPathComponent("history.jsonl"))
    equal(store.load().count, 0, "пустая история")
    let audio = dir.appendingPathComponent("a.wav")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: audio.path, contents: Data([1, 2, 3]))
    let old = HistoryEntry(id: "old", createdAt: Date(timeIntervalSince1970: 0), text: "old", audioPath: audio.path)
    let fresh = HistoryEntry(id: "new", createdAt: Date(), text: "new")
    try? store.append(old); try? store.append(fresh)
    equal(store.load().map(\.id), ["new", "old"], "новые первыми")
    var edited = fresh; edited.agentMisread = true
    try? store.update(edited)
    equal(store.load().first?.agentMisread, true, "обновление побеждает")
    equal(store.load().count, 2, "обновление не дублирует")
    equal((try? store.prune(retention: 3600)) ?? -1, 1, "удалена одна старая")
    check(!FileManager.default.fileExists(atPath: audio.path), "аудио удалено вместе с записью")
    equal(store.load().map(\.id), ["new"])
    // Повреждённая строка не ломает чтение.
    if let h = try? FileHandle(forWritingTo: store.fileURL) { _ = try? h.seekToEnd(); try? h.write(contentsOf: Data("{битый\n".utf8)); try? h.close() }
    equal(store.load().count, 1, "битая строка пропущена")
    try? FileManager.default.removeItem(at: dir)
}

// MARK: PolishSettings (D3, D4, G7)
do {
    let telegram = "ru.keepcoder.Telegram", cursor = "com.todesktop.230313mzl4w4u92"
    var p = PolishSettings()
    equal(p.decide(bundleID: telegram, isAgent: false), nil, "по умолчанию выключено")
    p.backend = .claude
    equal(p.decide(bundleID: telegram, isAgent: false), nil, "claude без согласия на облако — не полируем")
    equal(p.effectiveBackend, .off)
    p.cloudConsent = true; p.style = .business
    equal(p.decide(bundleID: telegram, isAgent: false), PolishRequest(backend: .claude, style: .business), "обычное приложение")
    equal(p.decide(bundleID: cursor, isAgent: true), nil, "агентное приложение — выключено по умолчанию")
    p.setOverride(cursor, true)
    equal(p.decide(bundleID: cursor, isAgent: true)?.backend, .claude, "ручное включение побеждает агентность")
    p.setOverride(telegram, false)
    equal(p.decide(bundleID: telegram, isAgent: false), nil, "ручное выключение")
    p.setOverride(telegram, nil)
    equal(p.decide(bundleID: telegram, isAgent: false)?.style, .business, "снятие переопределения")
    p.setOverride(cursor, false)
    check(!p.forcedOn.contains(cursor) && p.forcedOff.contains(cursor), "переопределение не двоится")
    p.setOverride("  ", true)
    check(!p.forcedOn.contains("") && !p.forcedOn.contains("  "), "пустой bundle id не добавляется")
    var m = PolishSettings(backend: .mlx)
    equal(m.decide(bundleID: telegram, isAgent: false)?.backend, .mlx, "mlx согласия на облако не требует")
    m.backend = .off
    m.forcedOn = [telegram]
    equal(m.decide(bundleID: telegram, isAgent: false), nil, "выключенный бэкенд сильнее переопределения")

    // Настройки: старый файл без polish и неизвестное значение не ломают чтение.
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mostik-polish-\(UUID().uuidString).json")
    try? Data(#"{"language":"ru"}"#.utf8).write(to: url)
    equal(MostikSettings.load(from: url).polish, PolishSettings(), "без поля polish — по умолчанию")
    try? Data(#"{"polish":{"backend":"gpt","style":"list","cloudConsent":true,"cloudConsentFor":"claude@v1"}}"#.utf8).write(to: url)
    let odd = MostikSettings.load(from: url).polish
    equal(odd.backend, .off, "неизвестный бэкенд — выкл"); equal(odd.style, .list); check(odd.cloudConsent)
    var saved = MostikSettings(); saved.polish = PolishSettings(backend: .claude, style: .brief, cloudConsent: true, forcedOff: ["a.b"])
    try? saved.save(to: url)
    equal(MostikSettings.load(from: url).polish, saved.polish, "круг сохранения polish")
    try? FileManager.default.removeItem(at: url)

    // final с полировкой и без.
    let line = #"{"event":"final","session":"s","text":"Чисто.","raw_text":"ну чисто","unpolished_text":"ну чисто.","polished":true,"polish":{"backend":"claude","style":"plain","status":"done","ms":2100},"timings":{"polish_ms":2100}}"#
    if case .final(let r)? = EngineCodec.decode(line: line) {
        check(r.polished); equal(r.unpolishedText, "ну чисто."); equal(r.polishStatus, "done")
        equal(r.timings.polishMs, 2100); equal(r.rawText, "ну чисто", "raw_text остаётся сырым")
    } else { check(false, "final с полировкой не разобран") }
    if case .final(let r)? = EngineCodec.decode(line: #"{"event":"final","session":"s","text":"x"}"#) {
        check(!r.polished); equal(r.polishStatus, nil); equal(r.unpolishedText, nil)
    } else { check(false, "final без полировки не разобран") }
    let field = EngineCodec.command("start", id: 1, fields: ["polish": .object(["backend": .string(PolishBackend.claude.rawValue), "style": .string(PolishStyle.list.rawValue)])])
    check(field.contains(#""polish":{"backend":"claude","style":"list"}"#), "поле polish в start")
}

// MARK: Settings
do {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mostik-settings-\(UUID().uuidString).json")
    var s = MostikSettings(); s.language = "en"; s.retentionDays = 30
    try? s.save(to: url)
    equal(MostikSettings.load(from: url), s, "круг сохранения")
    try? Data(#"{"language":"ru"}"#.utf8).write(to: url)
    equal(MostikSettings.load(from: url).retentionDays, 7, "недостающие поля берутся по умолчанию")
    // C4: прежние настройки блока сомнений в файле не мешают чтению.
    try? Data(#"{"language":"en","doubtsToAgents":false,"doubtLimit":3}"#.utf8).write(to: url)
    equal(MostikSettings.load(from: url).language, "en", "старые поля doubtsToAgents и doubtLimit пропускаются")
    try? FileManager.default.removeItem(at: url)
}

// MARK: VoiceEdit (D5)
do {
    // Можно ли: правка включена, бэкенд и согласие — от причёсывания.
    var s = MostikSettings()
    equal(s.voiceEditAvailability, .blocked(.disabled), "по умолчанию выключена")
    s.voiceEdit = true
    equal(s.voiceEditAvailability, .blocked(.noBackend), "без бэкенда LLM")
    s.polish.backend = .claude
    equal(s.voiceEditAvailability, .blocked(.noConsent), "claude без согласия")
    s.polish.cloudConsent = true
    equal(s.voiceEditAvailability, .ready(.claude))
    equal(s.voiceEditAvailability.backend, .claude)
    // Решение автора 2026-10-12: правка на правом ⌘, а при записи на ⌘ — на правом ⌥, без конфликта.
    equal(s.voiceEditKey, HoldKeys.rightCommand, "запись на правом ⌥ — правка на правом ⌘")
    s.holdKey = "rightCommand"
    equal(s.voiceEditAvailability, .ready(.claude), "запись на правом ⌘ правку не блокирует")
    equal(s.voiceEditKey, HoldKeys.rightOption, "запись на правом ⌘ — правка уходит на правый ⌥")
    equal(HoldKeys.voiceEditKey(holdKey: "fn"), HoldKeys.rightCommand, "запись на fn — правка на правом ⌘")
    for key in [HoldKeys.rightOption, HoldKeys.rightCommand, HoldKeys.fn] {
        check(HoldKeys.voiceEditKey(holdKey: key) != key, "правка и запись никогда не на одной клавише (\(key))")
    }
    equal(HoldKeys.name("rightOption"), "правый ⌥")
    equal(HoldKeys.name("rightCommand"), "правый ⌘")
    equal(HoldKeys.name("fn"), "fn")
    equal(HoldKeys.capitalizedName("rightCommand"), "Правый ⌘")
    s.holdKey = "fn"; s.polish.backend = .mlx; s.polish.cloudConsent = false
    equal(s.voiceEditAvailability, .ready(.mlx), "локальной модели согласие не нужно")
    let legacy = (try? JSONDecoder().decode(MostikSettings.self, from: Data(#"{"language":"ru"}"#.utf8))) ?? MostikSettings()
    check(!legacy.voiceEdit, "старый файл настроек — правка выключена")

    // Путь чтения выделения.
    typealias Sel = VoiceEditSelection
    equal(Sel.plan(probe: .text("абзац"), secureInput: false), .use("абзац"))
    equal(Sel.plan(probe: .text("абзац"), secureInput: true), .refuse(.secureInput), "поле пароля")
    equal(Sel.plan(probe: .text(" \n "), secureInput: false), .copyFallback, "пробелы — не выделение, пробуем ⌘C")
    equal(Sel.plan(probe: .empty, secureInput: false), .copyFallback, "Chromium отдаёт пустую строку")
    equal(Sel.plan(probe: .unsupported, secureInput: false), .copyFallback)
    equal(Sel.plan(probe: .noAccess, secureInput: false), .refuse(.noAccessibility), "без AX нет и ⌘C")
    equal(Sel.plan(probe: .text(String(repeating: "а", count: Sel.maxCharacters + 1)), secureInput: false),
          .refuse(.tooLong))
    equal(Sel.copied(changeBefore: 5, changeAfter: 6, text: "из буфера"), .use("из буфера"))
    equal(Sel.copied(changeBefore: 5, changeAfter: 5, text: "старый буфер"), .refuse(.noSelection),
          "буфер не изменился — выделения не было")
    equal(Sel.copied(changeBefore: 5, changeAfter: 6, text: nil), .refuse(.noSelection), "в буфере не текст")

    // Жест правого ⌘: удержание — правка, сочетание или короткое нажатие — отмена.
    var g = VoiceEditGesture(minimumHold: 0.3)
    equal(g.handle(.commandDown(at: 10)), .begin)
    equal(g.handle(.commandDown(at: 10.1)), nil, "автоповтор флагов не начинает заново")
    equal(g.handle(.commandUp(at: 11.5)), .finish)
    equal(g.state, .idle)
    equal(g.handle(.commandDown(at: 20)), .begin)
    equal(g.handle(.otherInput), .abort, "⌘C во время удержания")
    equal(g.handle(.otherInput), nil)
    equal(g.handle(.commandUp(at: 22)), nil, "отпускание после сочетания ничего не шлёт")
    equal(g.handle(.commandDown(at: 30)), .begin)
    equal(g.handle(.commandUp(at: 30.1)), .abort, "короткое нажатие ⌘ — не правка")
    equal(g.handle(.otherInput), nil, "клавиши без удержания не трогаем")
    equal(g.handle(.commandUp(at: 31)), nil)
    _ = g.handle(.commandDown(at: 40))
    equal(g.reset(), .abort, "выключили посреди удержания")
    equal(g.reset(), nil)

    // edit_done: ответ на команду edit по id; замена только при done.
    let line = #"{"event":"edit_done","id":7,"session":"edit-1","command":"Сделать списком","heard":"сделай списком","text":"- раз\n- два","status":"done","ms":2300}"#
    if case .reply(let id, let ok, let payload)? = EngineCodec.decode(line: line) {
        equal(id, 7); check(ok)
        let reply = VoiceEditReply(payload: payload)
        equal(reply.replacement, "- раз\n- два"); equal(reply.failure, nil); equal(reply.command, "Сделать списком")
        equal(reply.ms, 2300)
    } else { check(false, "edit_done не разобран как ответ") }
    check(EngineCodec.decode(line: #"{"event":"edit_done","session":"x","status":"done"}"#) == nil, "edit_done без id")
    for (status, failure) in [("refused", VoiceEditFailure.refused), ("timeout", .timeout), ("unchanged", .unchanged),
                              ("empty_command", .emptyCommand), ("unavailable", .unavailable),
                              ("bad_output", .badOutput), ("что-то новое", .engine)] {
        let reply = VoiceEditReply(status: status, text: "не вставлять")
        equal(reply.replacement, nil, status); equal(reply.failure, failure, status)
    }
    equal(VoiceEditReply(status: "done", text: "").failure, .badOutput, "done без текста не заменяет")
    let command = EngineCodec.command("edit", id: 3, fields: ["session": .string("edit-1"), "selection": .string("текст"),
                                                               "backend": .string(PolishBackend.claude.rawValue)])
    check(command.contains(#""cmd":"edit""#) && command.contains(#""backend":"claude""#), "команда edit")
}


// ИИ встреч (M5–M7) — MeetingAITests.swift.
runMeetingAITests()
runGestureDoctorTests()

// Надёжная доставка (R1–R5, H2, H3, A7) — DeliveryTests.swift.
runDeliveryTests()

// Папка встречи и вокруг неё (M10–M13, W2, W9, W11, W13, W14) — MeetingFolderTests.swift.
runMeetingFolderTests()
runManifestSchemaTests()  // манифест приложения против docs/schemas — ManifestSchemaTests.swift
runLaunchAtLoginTests()
runSharedEnvironmentTests()  // списки окружения против docs/engine-environment.json — SharedEnvironmentTests.swift

// Голос и агенты (G5, G6, A1, A3, A5) — AgentVoiceTests.swift.
runAgentVoiceTests()
// П6-А: контекст, сценарии, правила речи, пакеты, потоковая вставка, перевод, задача, очередь агенту.
runPolishExtrasTests()

// CLI, MCP, скилл и хук для агентов (G1, G2, G4) — AgentIntegrationTests.swift.
runAgentIntegrationTests()

// Обучение на правках и язык диктовки (L1, L5) — EditLearningTests.swift.
runEditLearningTests()

// Говорящие встречи: уверенность меток и голосовая память (M14, M15) — MeetingSpeakersTests.swift.
runMeetingSpeakersTests()
runSpeakerNamesTests()
runVoiceMemorySettingsTests()
runMenuBarPanelTests()
runMeetingMenuTests()  // запись встречи в строке меню вместо окошка внизу экрана — MeetingMenuTests.swift
runHUDPositionTests()  // плашку диктовки можно перетащить — HUDPositionTests.swift
runMeetingLiveTests()
runArchiveTests()
runMeetingAssistTests()  // П7: M19, M9, W26
runFrameRaceTests()  // П10, низкий: гонка кадра и пометки «чувствительная»
runTranscriberTempHygieneTests()  // П10, низкий: transcriber-asr-* и transcriber-download-* в $TMPDIR
runHistoryPruneScopeTests()  // П10, инфо: prune удаляет звук только внутри recordings/

// Голосовые команды-намерения (D6) — VoiceIntentTests.swift.
runVoiceIntentTests()

// Автообновление (П8-3) — UpdatePolicyTests.swift.
runUpdatePolicyTests()

// Поиск движка и Python без жёстких путей (П8, пункт 1) — EnginePathsTests.swift.
runEnginePathsTests()
// Модели по кнопке (П8, пункт 5) — ModelCatalogTests.swift.
runModelCatalogTests()

// Прод-укрепление (П8, пункты 1 и 6) — ProdHardeningTests.swift.
runProdHardeningTests()

// Локализация и доступность (П8, п. 9) — L10nGuardTests.swift, ContrastTests.swift.
runL10nGuardTests()
runContrastTests()
runEngineErrorTextTests()
runPrivacyTests()  // приватность: облачное согласие встреч, чувствительные встречи, consent
runPrivacyEnvironmentTests()
runVoiceEditExclusionTests()
runUpdateChoiceTests()
runUpdateRequirementTests()
runSettingsSchemaTests()
runCalendarAgentPrivacyTests()
runA11yGuardTests()
runSettingsInventoryTests()  // П9-А: опись Настроек — SettingsInventoryTests.swift
runSettingsRouteTests()  // B1/B2: Настройки — вкладка главного окна, Dock пока окно открыто — SettingsRouteTests.swift
runCopyGuardTests()  // copy-clarity 2026-10-12: запрещённые слова в русских строках — CopyGuardTests.swift
runHUDHintTests()  // П9-B: подсказка «⌥ стоп · ⎋ отмена» в плашке записи
runProgressCreepTests()  // полоса «Сверяю» ползёт сама и добегает до 100 % — ProgressCreepTests.swift
runWarmMicSettleTests()  // сбой CoreAudio 2026-10-19: перенастройка после тишины
runMicChoiceTests()  // R3b: выбор микрофона только для Mostik, системный вход не меняется
runSilentInputWatchTests()  // залипший микрофон: нули → без обработки голоса → заново → предупреждение

runEngineIsolationTests()  // П10 С1: изоляция Python движка — IsolationTests.swift
runToolEnvironmentTests()  // П10: внешние утилиты с урезанным окружением

runHookTrustTests()  // П10 С3: отпечаток команды хука в связке ключей — HookTrustTests.swift
runHookDigestOwnershipTests()  // П10 Н1: чужая запись связки ключей не принимается
runHookPromptTests()  // П10, низкий: окно «Разрешить хук?» показывает команду целиком

runTextOnlyAudioTests()  // П10 С7: «только текст» — звук стирается насовсем — TextOnlyAudioTests.swift

runVoiceMemoryWipeTests()  // П10 С8: «Стереть отпечатки?» при выключении голосовой памяти

runLowHardeningTests()  // П10, низкие в приложении — LowHardeningTests.swift

runStorageHygieneTests()  // П10: права 0700/0600, склейки встреч в $TMPDIR

runConsentLabelTests()  // П10: метка claude@v1 у облачных согласий

runApplySettingsGuardTests()  // П10: без обхода applySettings

runAutoEnterGuardTests()  // П10: без Enter после контекста терминала

runSafeGitTests()  // П10: git в чужом репозитории, окружение утилит
runRound4EnvironmentTests()  // П10 р4 Р4-1, Р4-2: белый список окружения, перезапуск — Round4Tests.swift
runRelaunchTests()  // П10 р4 Р4-2
runSecureDictationHistoryTests()  // П10 р4 Р4-4л: поле пароля
runHookEnableConfirmTests()  // П10 р4 Р4-3
runAgentQueueGuardTests()  // П10 р4 Р4-4и
runRound5SecureMemoryTests()  // П10 р5 Р5-1л: поле пароля — в памяти как в файле — Round5Tests.swift
runRound5SecureStopTests()  // П10 р5: поле пароля посреди записи
runRound5TmuxTests()  // П10 р5 Р5-1: TMUX_TMPDIR
runRound5GitPathTests()  // П10 р5 Р5-2: git мимо шима xcrun
runRound5OrphanAudioTests()  // П10 р5 Р5-2л: осиротевшие recordings/*.wav
runRound5HookLogTests()  // П10 р5 Р5-3л: журнал хука с ротацией
runRound5TempNamesTests()  // П10 р5 Р5-4л: временные имена
runP10TailGitOwnerTests()  // П10 хвост р5 Ф-1: git только из цепочки root
runP10TailXcodeSelectTimeoutTests()  // П10 хвост р5 Ф-5: таймаут xcode-select -p
runP10TailLogDirTests()  // П10 хвост р5 Ф-2: MOSTIK_LOG_DIR только в debug
runP10TailInsertSecureFieldTests()  // П10 хвост р5 Ф-4: поле пароля в insert — роль и до команды
runP10TailReleaseDocTests()  // П10 хвост р5 Ф-3: Р5-2 в release.md — claude и хук через шим, Н-10

runLogRedactionTests()  // П10: сырой текст ошибок движка не попадает в app.log


runDictationAudioRetentionTests()  // П10: звук диктовок — 1 день

runMenuVoiceTests()  // «Записать голос» в меню строки меню — MenuVoiceTests.swift
runRecordLocalTests()  // «Локально» в карточке встречи — RecordLocalTests.swift
runUpdateMenuItemTests()  // «Проверить обновления…» только с настоящей лентой
runSettingsCopyTests()  // Настройки, слепой раунд 4: число моделей, имя приложения, нейтральное имя — SettingsCopyTests.swift

runPerfTests()  // «Плавность и быстродействие»: замеры, старт записи, нажатия, уровень, плашка — PerfTests.swift
runMotionSpecTests()
runHookCoalesceTests()
runZoomSpeakersTests()  // имена говорящих из Zoom через Accessibility — ZoomSpeakersTests.swift
runWebCallSpeakersTests()  // говорящие в Meet и Телемосте по дереву страницы — WebCallSpeakersTests.swift

runExternalCalendarTests()  // внешний календарь-команда — ExternalCalendarTests.swift
runCalendarICSTests()  // iCalendar и повторы для CalDAV — CalendarICSTests.swift
runCalDAVTests()  // Яндекс Календарь по CalDAV, поддельный транспорт — CalDAVTests.swift
runGoogleCalendarTests()  // Google: вход, токены, календари, события — GoogleCalendarTests.swift
runCalendarAccountsTests()  // выбор источников календаря — CalendarAccountsTests.swift
runAppLocationTests()  // запуск из .dmg и транслоцированной копии — AppLocationTests.swift

print("MostikCoreTests: \(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
