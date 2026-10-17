import Foundation
import MostikCore

/// П8: находки ревью и устойчивость — агенты под node, поколение движка, тёплый микрофон,
/// журнал и отчёты о сбоях.
func runProdHardeningTests() {
    runAgentUnderNodeTests()
    runEngineRestartGateTests()
    runEngineRecoveryTextTests()
    runLogPolicyTests()
    runWarmMicTests()
}

/// Буфер `KERN_PROCARGS2`: argc, путь exec, выравнивание нулями, argv, окружение.
private func procArgs(_ exec: String, _ argv: [String], env: [String] = ["HOME=/Users/x"]) -> [UInt8] {
    var argc = Int32(argv.count).littleEndian
    var bytes = withUnsafeBytes(of: &argc) { Array($0) }
    bytes += Array(exec.utf8) + [0, 0, 0, 0]
    for arg in argv + env { bytes += Array(arg.utf8) + [0] }
    return bytes
}

private func runAgentUnderNodeTests() {
    let names: Set<String> = ["claude", "codex", "gemini", "aider", "opencode"]
    func node(_ argv: [String], name: String = "node", path: String = "/opt/homebrew/bin/node") -> ProcessEntry {
        let args = ProjectResolver.parseProcArgs(procArgs(path, argv))
        return ProcessEntry(pid: 10, ppid: 1, name: name, path: path, args: args)
    }
    equal(ProjectResolver.parseProcArgs(procArgs("/opt/homebrew/bin/node", ["node", "/opt/homebrew/bin/gemini", "-p"])),
          ["node", "/opt/homebrew/bin/gemini", "-p"], "argv из синтетического KERN_PROCARGS2, окружение отброшено")
    equal(ProjectResolver.agentName(node(["node", "/opt/homebrew/bin/gemini"]), names: names), "gemini", "gemini из npm: ссылка в bin")
    equal(ProjectResolver.agentName(node(["node", "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js", "--resume"]), names: names),
          "claude", "claude: cli.js внутри пакета")
    equal(ProjectResolver.agentName(node(["node", "/Users/x/.npm/_npx/1/node_modules/@openai/codex/bin/codex.js"]), names: names),
          "codex", "codex через npx")
    equal(ProjectResolver.agentName(node(["node", "--no-warnings", "--require", "/tmp/hook.js", "/opt/homebrew/lib/node_modules/@google/gemini-cli/dist/index.js"]), names: names),
          "gemini", "флаги node и значение --require пропускаются")
    equal(ProjectResolver.agentName(node(["claude"]), names: names), "claude", "process.title переписал argv[0]")
    equal(ProjectResolver.agentName(node(["bun", "run", "/Users/x/bin/opencode"], name: "bun", path: "/Users/x/.bun/bin/bun"), names: names),
          "opencode", "bun run")
    equal(ProjectResolver.agentName(node(["node", "/Users/x/app/server.js", "claude"]), names: names), nil,
          "имя агента аргументом скрипта — не агент")
    equal(ProjectResolver.agentName(node(["node", "/Users/x/app/node_modules/vite/bin/vite.js"]), names: names), nil, "обычный node")
    equal(ProjectResolver.agentName(node(["node"]), names: names), nil, "голый node")
    equal(ProjectResolver.agentName(ProcessEntry(pid: 1, ppid: 0, name: "codex", path: "/opt/homebrew/bin/codex"), names: names),
          "codex", "нативный бинарник")
    equal(ProjectResolver.agentName(ProcessEntry(pid: 1, ppid: 0, name: "python3", path: "/usr/bin/python3",
                                                 args: ["python3", "/x/claude"]), names: names), nil,
          "argv смотрим только у интерпретаторов JS")
    check(ProjectResolver.isAgent(node(["node", "/opt/homebrew/bin/gemini"]), names: ["gemini"]), "isAgent через argv")
    check(!ProjectResolver.isAgent(node(["node", "/opt/homebrew/bin/gemini"]), names: ["claude"]), "агент не из списка")
    // Панель tmux с gemini под node называется gemini, а не node.
    let pane = TmuxPane(id: "%1", session: "s", pid: 100)
    let found = Tmux.agentPanes([pane], processes: [ProcessEntry(pid: 100, ppid: 1, name: "zsh"),
                                                   node(["node", "/opt/homebrew/bin/gemini"]).with(pid: 101, ppid: 100)],
                                names: names)
    equal(found.first?.agent, "gemini", "имя агента в панели tmux")
}

private extension ProcessEntry {
    func with(pid: Int32, ppid: Int32) -> ProcessEntry {
        var copy = self; copy.pid = pid; copy.ppid = ppid; return copy
    }
}

private func runEngineRestartGateTests() {
    var gate = EngineRestartGate()
    let first = gate.generation
    check(gate.isCurrent(first), "первое поколение актуально")
    check(gate.begin(), "перезапуск начат")
    check(!gate.isCurrent(first), "события старого процесса после begin — чужие")
    check(!gate.begin(), "второй запрос во время перезапуска вливается в первый")
    check(!gate.isCurrent(gate.generation), "пока старый не остановлен, нового поколения ещё нет")
    let second = gate.finish()
    check(second != first && gate.isCurrent(second), "новое поколение актуально после finish")
    check(!gate.isCurrent(first), "старое так и остаётся чужим")
    check(gate.begin(), "следующий перезапуск снова возможен")
    let third = gate.finish()
    equal(third, second + 1, "поколения растут на единицу")
    // Сценарий гонки: старое рукопожатие досчитало warmup после перезапуска.
    var race = EngineRestartGate()
    let handshakeOf = race.generation
    _ = race.begin(); race.finish()
    check(!race.isCurrent(handshakeOf), "рукопожатие старого поколения не ставит «Готов»")
}

private func runEngineRecoveryTextTests() {
    equal(EngineRecovery.retryDelays, [2, 5, 15], "вторая ступень — 2, 5, 15 с")
    equal(EngineRecovery.restarting(attempt: 1, delay: 1, crashes: 1, russian: true),
          "Движок упал — перезапуск через 1\u{00A0}с, попытка 1 из 6")
    equal(EngineRecovery.restarting(attempt: 3, delay: 4, crashes: 7, russian: false),
          "Engine crashed — restarting in 4\u{00A0}s, attempt 3 of 6 · crashes this session: 7")
    equal(EngineRecovery.retrying("Движок падает при запуске (код 1)", after: 5, attempt: 2, russian: true),
          "Движок падает при запуске (код 1) · повтор через 5\u{00A0}с (2 из 3)")
    equal(EngineRecovery.retrying("", after: 2, attempt: 1, russian: false), "Retrying in 2\u{00A0}s (1 of 3)")
    let gaveUp = EngineRecovery.gaveUp("код 1", crashes: 4, logPath: "~/Library/Logs/Mostik/engine.log", russian: true)
    check(gaveUp.contains("2\u{00A0}с, 5\u{00A0}с, 15\u{00A0}с") && gaveUp.contains("падений за сеанс: 4")
          && gaveUp.hasSuffix("журнал: ~/Library/Logs/Mostik/engine.log"), "итог: паузы, счётчик, журнал — \(gaveUp)")
    equal(EngineRecovery.formatSeconds(1.5, russian: true), "1,5\u{00A0}с")
}

private func runLogPolicyTests() {
    let dir = URL(fileURLWithPath: "/tmp/logs", isDirectory: true)
    let paths = MostikLogPaths(root: dir)
    equal(paths.app.path, "/tmp/logs/app.log")
    equal(paths.crashes.path, "/tmp/logs/crashes")
    check(MostikLogPaths.standard.root.path.hasSuffix("Library/Logs/Mostik")
          || ProcessInfo.processInfo.environment["MOSTIK_LOG_DIR"] != nil, "по умолчанию — ~/Library/Logs/Mostik")

    let rotation = LogRotation(maxBytes: 100, keep: 3)
    check(!rotation.shouldRotate(size: 0, incoming: 500), "пустой файл не ротируем даже под длинную строку")
    check(!rotation.shouldRotate(size: 60, incoming: 40), "ровно лимит — ещё влезает")
    check(rotation.shouldRotate(size: 61, incoming: 40), "сверх лимита — ротация")
    let plan = rotation.plan(for: paths.app)
    equal(plan.drop?.lastPathComponent, "app.log.2", "старший файл уходит")
    equal(plan.moves.map { "\($0.from.lastPathComponent)>\($0.to.lastPathComponent)" },
          ["app.log.1>app.log.2", "app.log>app.log.1"], "переименования от старших к младшим")
    equal(LogRotation(maxBytes: 10, keep: 1).plan(for: paths.app).moves.count, 0, "keep 1 — файл просто начинается заново")

    // Ротация на настоящих файлах во временной папке: файлов не больше keep, порядок сохраняется.
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mostik-logtest-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let file = tmp.appendingPathComponent("app.log")
    for round in 1...5 {
        let p = rotation.plan(for: file)
        if let drop = p.drop { try? FileManager.default.removeItem(at: drop) }
        for move in p.moves where FileManager.default.fileExists(atPath: move.from.path) {
            try? FileManager.default.moveItem(at: move.from, to: move.to)
        }
        try? "round \(round)".write(to: file, atomically: true, encoding: .utf8)
    }
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []).sorted()
    equal(names, ["app.log", "app.log.1", "app.log.2"], "после пяти ротаций — три файла")
    equal(try? String(contentsOf: tmp.appendingPathComponent("app.log.2"), encoding: .utf8), "round 3", "старший — третий раунд")
    try? FileManager.default.removeItem(at: tmp)

    let utc = TimeZone(identifier: "UTC")!
    let date = Date(timeIntervalSince1970: 1_791_741_600)
    let line = LogLine.format(date, category: "engine", message: "ready\nsecond line", timeZone: utc)
    check(line.hasSuffix(" [engine] ready second line\n") && line.hasPrefix("2026-"), "одна строка на событие: \(line)")
    let long = LogLine.format(date, category: "x", message: String(repeating: "а", count: 1000), timeZone: utc)
    check(long.count < LogLine.maxMessage + 60, "длинное сообщение обрезается")

    equal(CrashReportPolicy.fileName(kind: "app", date: date, pid: 42, timeZone: utc), "app-2026-10-11-180000-pid42.txt")
    let reports = (0..<25).map { String(format: "engine-2026-10-%02d-120000-pid1.txt", $0 + 1) } + ["app-2026-10-30-000000-pid9.txt", "notes.md"]
    let excess = CrashReportPolicy.excess(reports, keep: 20)
    equal(excess.count, 6, "храним 20 отчётов")
    check(excess.contains("engine-2026-10-01-120000-pid1.txt") && !excess.contains("app-2026-10-30-000000-pid9.txt"),
          "удаляются старшие, свежий остаётся")
    check(!excess.contains("notes.md"), "чужие файлы не трогаем")
    let since = Date(timeIntervalSince1970: 1_792_500_000)  // 2026-10-20
    equal(CrashReportPolicy.recent(reports, since: since, timeZone: utc).count, 6, "отчёты за последние дни")
    let report = CrashReportPolicy.exceptionReport(name: "NSRangeException", reason: "index 5\nbeyond", stack: ["0 Mostik", "1 AppKit"],
                                                   version: "0.1 (1)", system: "macOS 26", date: date)
    check(report.contains("никуда не отправляется") && report.contains("reason: index 5 beyond") && report.contains("  1 AppKit"),
          "отчёт об исключении")

    // «Проверка»: строка журнала всегда с «Показать в Finder», сбои — предупреждение.
    var facts = DoctorFacts()
    var logs = Doctor.evaluate(facts, russian: true).first { $0.kind == .logs }
    equal(logs?.status, .ok); equal(logs?.fix, .showLogs, "кнопка есть и без сбоев")
    facts.crashReports = 2
    logs = Doctor.evaluate(facts, russian: false).first { $0.kind == .logs }
    equal(logs?.status, .warning)
    check(logs?.detail.contains("never sent") == true, "в тексте — что ничего не отправляется")
    facts.engine = .ready; facts.engineCrashes = 3
    check(Doctor.evaluate(facts, russian: true).first { $0.kind == .engine }?.detail.contains("Падал за сеанс: 3") == true,
          "счётчик падений движка в «Проверке»")
}

func runWarmMicTests() {
    typealias S = WarmMicPolicy.State
    let builtIn: UInt32 = 77, airpods: UInt32 = 91
    // Встроенный, тёплый: движок запускается.
    var s = S(warmWanted: true, authorized: true, recording: false, running: false,
              boundDevice: nil, currentDevice: builtIn, currentTransport: .builtIn)
    equal(WarmMicPolicy.decide(s), .start(rebuild: false), "встроенный вход — тёплый микрофон включается")
    s.running = true; s.boundDevice = builtIn
    equal(WarmMicPolicy.decide(s), .none, "уже работает")
    // Подключили AirPods: вход по умолчанию — Bluetooth, тёплый гасим.
    s.currentDevice = airpods; s.currentTransport = .bluetooth
    equal(WarmMicPolicy.decide(s), .stop, "Bluetooth — тёплый выключается, гарнитура не уходит в HFP")
    s.running = false
    equal(WarmMicPolicy.decide(s), .none, "на Bluetooth движок стоит")
    // Сняли AirPods: вход снова встроенный — тёплый возвращается на пересобранном движке.
    s.currentDevice = builtIn; s.currentTransport = .builtIn
    equal(WarmMicPolicy.decide(s), .start(rebuild: false), "вернулись на то же устройство — пересборка не нужна")
    s.boundDevice = airpods  // движок последний раз собирался под гарнитуру (запись шла с неё)
    equal(WarmMicPolicy.decide(s), .start(rebuild: true), "Bluetooth → встроенный: движок пересобирается и тёплый включается")
    // Запись с гарнитуры идёт, тёплого нет — запись не обрывается.
    var r = S(warmWanted: true, authorized: true, recording: true, running: true,
              boundDevice: airpods, currentDevice: airpods, currentTransport: .bluetooth)
    equal(WarmMicPolicy.decide(r), .none, "запись с Bluetooth продолжается")
    r.currentDevice = builtIn; r.currentTransport = .builtIn
    equal(WarmMicPolicy.decide(r), .restart, "гарнитуру сняли посреди записи — запись переезжает на встроенный")
    r.currentDevice = nil; r.currentTransport = nil
    equal(WarmMicPolicy.decide(r), .stop, "входа нет вовсе")
    // Тёплый выключен в настройках или нет разрешения.
    var off = S(warmWanted: false, authorized: true, recording: false, running: true,
                boundDevice: builtIn, currentDevice: builtIn, currentTransport: .builtIn)
    equal(WarmMicPolicy.decide(off), .stop, "настройка выключена")
    off.warmWanted = true; off.authorized = false
    equal(WarmMicPolicy.decide(off), .stop, "без разрешения микрофона")
    check(WarmMicPolicy.suitsWarm(.usb) && !WarmMicPolicy.suitsWarm(.bluetoothLE) && !WarmMicPolicy.suitsWarm(.airPlay)
          && !WarmMicPolicy.suitsWarm(nil), "какие входы годятся")
}
