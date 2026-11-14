// Живая проверка жизненного цикла движка на настоящем Python (аудит 2026-11-14, S6/S7/S8/S16/S17).
//   scripts/swift.sh run MostikEngineCheck [race|pause|restart|instant|storm …]
// Поднимает настоящий `EngineClient` с домом во временной папке и убивает процесс движка в нужные
// моменты. Убивает только своих потомков (по pid из `pgrep -P <свой pid>`): установленное
// приложение и его движок не трогает. Python — `MOSTIK_PYTHON` или `vendor/python` репозитория.
import Darwin
import Foundation
import Security
import MostikCore
@_spi(Testing) import MostikKit

setvbuf(stdout, nil, _IONBF, 0)
// Сама себе подставной «агент» для сценария S5: запущенная ссылкой с чужим именем просто спит.
if CommandLine.arguments.dropFirst().first == "--sleep" { sleep(6); exit(0) }

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    @discardableResult func update<R>(_ body: (inout T) -> R) -> R { lock.withLock { body(&stored) } }
}

let failures = Box(0)
func verdict(_ ok: Bool, _ text: String) {
    print(ok ? "  ✓ \(text)" : "  ✗ \(text)")
    if !ok { failures.update { $0 += 1 } }
}
func now() -> Double { ProcessInfo.processInfo.systemUptime }
func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

// MARK: окружение

let fm = FileManager.default
let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
func ancestor(of url: URL, where test: (URL) -> Bool) -> URL? {
    var dir = url.deletingLastPathComponent()
    for _ in 0..<10 {
        if test(dir) { return dir }
        let parent = dir.deletingLastPathComponent()
        if parent.path == dir.path { break }
        dir = parent
    }
    return nil
}
let hasEngine = { (dir: URL) in fm.fileExists(atPath: dir.appendingPathComponent("engine/mostik_engine").path) }
let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
guard let repo = ancestor(of: executable, where: hasEngine) ?? (hasEngine(cwd) ? cwd : nil) else {
    print("Не нашёл engine/mostik_engine ни рядом с исполняемым файлом, ни в текущей папке."); exit(2)
}
let engineDir = repo.appendingPathComponent("engine", isDirectory: true)
/// Python: переменная окружения или `vendor/python` — в этой копии либо в основной (рабочее дерево в `.worktrees/`).
let python: String = {
    if let env = ProcessInfo.processInfo.environment["MOSTIK_PYTHON"], !env.isEmpty { return env }
    var dir = repo
    for _ in 0..<4 {
        let candidate = dir.appendingPathComponent("vendor/python/bin/python3").path
        if fm.isExecutableFile(atPath: candidate) { return candidate }
        dir = dir.deletingLastPathComponent()
    }
    return ""
}()
guard fm.isExecutableFile(atPath: python) else { print("Python не найден: задайте MOSTIK_PYTHON."); exit(2) }

let root = fm.temporaryDirectory.appendingPathComponent("mostik-enginecheck-\(getpid())", isDirectory: true)
try? fm.createDirectory(at: root, withIntermediateDirectories: true)
var homes = 0
func makeConfig() -> EngineClient.Config {
    homes += 1
    let home = root.appendingPathComponent("home-\(homes)", isDirectory: true)
    try? fm.createDirectory(at: home, withIntermediateDirectories: true)
    return EngineClient.Config(python: python, engineDir: engineDir, home: home,
                               logFile: root.appendingPathComponent("engine-\(homes).log"), crashDir: nil)
}

// MARK: свои процессы

/// Потомки этого процесса — только их считаем и только их убиваем.
func children() -> [pid_t] {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    task.arguments = ["-P", String(getpid())]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    guard (try? task.run()) != nil else { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { pid_t($0) }
        .filter { $0 != task.processIdentifier && isPython($0) }
}
func isPython(_ pid: pid_t) -> Bool {
    var buffer = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
    return String(cString: buffer).contains("python")
}
func killOwn(_ pid: pid_t) {
    guard children().contains(pid) else { return }  // чужой pid не трогаем никогда
    kill(pid, SIGKILL)
}
@discardableResult func waitFor(_ timeout: Double, _ condition: () -> Bool) -> Bool {
    let deadline = now() + timeout
    while now() < deadline { if condition() { return true }; pause(0.02) }
    return condition()
}
func killAllOwn() { for pid in children() { kill(pid, SIGKILL) } }

/// Ждём результат async-вызова с потолком по времени.
func await_<T: Sendable>(_ timeout: Double, _ body: @escaping @Sendable () async throws -> T) -> Result<T, Error>? {
    let box = Box<Result<T, Error>?>(nil)
    Task { do { box.value = .success(try await body()) } catch { box.value = .failure(error) } }
    waitFor(timeout) { box.value != nil }
    return box.value
}

struct Timeout: Error {}
let wanted = Set(CommandLine.arguments.dropFirst())
func enabled(_ name: String) -> Bool { wanted.isEmpty || wanted.contains(name) }

print("Python: \(python)\nДвижок: \(engineDir.path)\nДом: \(root.path)")
verdict(children().isEmpty, "до начала у проверки нет своих процессов Python")

// MARK: S6 — остановка в момент отложенного перезапуска

if enabled("race") {
    print("\nS6. Клиент остановлен ровно в момент, когда срабатывает отложенный перезапуск")
    // Упавший клиент ждёт 1 с и перезапускается. Остановка (так делает `restartEngine` приложения) в тот же
    // момент не должна оставить живой Python: останавливать его уже некому.
    var orphans = 0, trials = 0
    let rounds = Int(ProcessInfo.processInfo.environment["RACE_ROUNDS"] ?? "") ?? 6
    let width = 16
    // Калибровка: через сколько после падения клиент на деле начинает перезапуск.
    var fired: [Double] = []
    for round in 0..<rounds {
        let clients = (0..<width).map { _ in EngineClient(config: makeConfig()) }
        let restartAt = clients.map { _ in Box<Double?>(nil) }
        let startedAt = clients.map { _ in Box<Double?>(nil) }
        for (i, client) in clients.enumerated() {
            client.onStatus = { status in
                if case .restarting = status { restartAt[i].value = now() }
                if case .starting = status, let at = restartAt[i].value, startedAt[i].value == nil { startedAt[i].value = now() - at }
            }
            try? client.start()
        }
        if round == 0 {
            waitFor(10) { children().count == width }
            for pid in children() { kill(pid, SIGKILL) }
            waitFor(5) { startedAt.allSatisfy { $0.value != nil } }
            fired = startedAt.compactMap(\.value).sorted()
            print(String(format: "  перезапуск начинается через %.4f…%.4f с после падения", fired.first ?? 0, fired.last ?? 0))
            for client in clients { client.shutdownAndWait(timeout: 1) }
            waitFor(3) { children().isEmpty }
            killAllOwn()
            continue
        }
        waitFor(10) { children().count == width }
        for pid in children() { kill(pid, SIGKILL) }
        waitFor(5) { restartAt.allSatisfy { $0.value != nil } }
        // Каждый клиент останавливаем со своим сдвигом вокруг момента перезапуска (1 с после падения).
        let group = DispatchGroup()
        for (i, client) in clients.enumerated() {
            guard let at = restartAt[i].value else { continue }
            trials += 1
            // Сдвиги покрывают наблюдённый разброс срабатывания таймера.
            let low = (fired.first ?? 1.0) - 0.0005, high = (fired.last ?? 1.0) + 0.0005
            let offset = low + (high - low) * (Double(i) + Double(round) / Double(rounds)) / Double(width)
            group.enter()
            DispatchQueue.global().async {
                while now() < at + offset {}
                client.shutdown()
                group.leave()
            }
        }
        group.wait()
        pause(1.2)
        let left = children()
        orphans += left.count
        for pid in left { kill(pid, SIGKILL) }
        for client in clients { client.shutdownAndWait(timeout: 1) }
        waitFor(3) { children().isEmpty }
        killAllOwn()
    }
    print("  попыток: \(trials), осталось живых Python после остановки: \(orphans)")
    verdict(orphans == 0, "остановленный клиент не поднимает Python (\(trials) попыток)")
}


// MARK: общее для сценариев

func describe(_ status: EngineClient.Status) -> String {
    switch status {
    case .starting: return "starting"
    case .running: return "running"
    case .restarting(let attempt, _): return "restarting\(attempt)"
    case .stopped: return "stopped"
    case .failed: return "failed"
    }
}
/// Клиент с записью статусов.
func tracked(_ config: EngineClient.Config = makeConfig()) -> (EngineClient, Box<[String]>) {
    let client = EngineClient(config: config)
    let log = Box<[String]>([])
    client.onStatus = { status in log.update { $0.append(describe(status)) } }
    return (client, log)
}
#if !LEGACY  // LEGACY — сборка с прежним клиентом: только сценарии на старом API (race, instant)
func hello(_ client: EngineClient, timeout: Double = 30) -> Bool {
    if case .success = await_(timeout + 1, { try await client.request("hello", timeout: timeout, hold: false) }) { return true }
    return false
}
/// Ждём, пока движок ответит на `hello` (после запуска или перезапуска).
func waitAlive(_ client: EngineClient, _ timeout: Double = 40) -> Bool {
    let deadline = now() + timeout
    while now() < deadline {
        if client.isRunning, hello(client, timeout: 5) { return true }
        pause(0.1)
    }
    return false
}
func glossary(_ client: EngineClient) -> Set<String> {
    guard case .success(let items)? = await_(20, { try await client.glossaryList().map(\.canonical) }) else { return [] }
    return Set(items)
}
func stop(_ client: EngineClient) {
    client.shutdownAndWait(timeout: 2)
    waitFor(3) { children().isEmpty }
}

if enabled("race") {
    print("\nS6. То же без подбора времени: остановка приходит точно между решением о запуске и запуском")
    let (client, log) = tracked()
    let relaunches = Box(0)
    client.willRun = {
        // Первый запуск — обычный; на перезапуске после падения в это окно приходит остановка.
        if relaunches.update({ $0 += 1; return $0 }) == 2 { client.shutdown() }
    }
    try? client.start()
    verdict(waitFor(10) { children().count == 1 }, "первый запуск: один Python")
    for pid in children() { killOwn(pid) }
    waitFor(5) { relaunches.value >= 2 }
    pause(1.0)
    verdict(children().isEmpty, "после остановки посреди запуска Python не поднялся (статусы: \(log.value.joined(separator: " → ")))")
    verdict(!client.isRunning && log.value.last != "running", "клиент не считает себя работающим")
    stop(client)
}

// MARK: S6/S7 — пауза после падения

if enabled("pause") {
    print("\nS6/S7. Пауза после падения: команды, явный запуск и ещё одно падение")
    let (client, log) = tracked()
    try? client.start()
    verdict(waitAlive(client), "движок поднялся и ответил на hello")
    let first = children()
    verdict(first.count == 1, "Python один (\(first.count))")
    first.forEach(killOwn)
    verdict(waitFor(5) { log.value.contains("restarting1") }, "клиент заметил падение")
    // Пауза 1 с: команды словаря отданы, пока процесса нет.
    let words = (1...5).map { "пауза\($0)" }
    let answers = Box<[String: Bool]>([:])
    for word in words {
        Task {
            do { try await client.remember(heard: word + " слышно", canonical: word); answers.update { $0[word] = true } }
            catch { answers.update { $0[word] = false } }
        }
    }
    // Явный запуск в ту же паузу (так поступил бы повтор по кнопке) — вместе с таймером.
    for _ in 0..<3 { DispatchQueue.global().async { try? client.start() } }
    verdict(waitFor(40) { answers.value.count == words.count }, "все \(words.count) команд получили ответ")
    verdict(answers.value.values.allSatisfy { $0 }, "ни одна не отклонена: \(answers.value.values.filter { $0 }.count) из \(words.count) приняты")
    pause(1.5)
    verdict(children().count == 1, "после паузы, таймера и трёх явных запусков Python один (\(children().count))")
    verdict(Set(words).isSubset(of: glossary(client)), "все слова, отданные в паузе, в словаре движка")

    // Ещё падение — сразу после перезапуска, с командой в полёте.
    let flying = Box<Bool?>(nil)
    Task {
        do { try await client.remember(heard: "в полёте слышно", canonical: "вполёте"); flying.value = true }
        catch { flying.value = false }
    }
    children().forEach(killOwn)
    verdict(waitFor(40) { flying.value != nil } && flying.value == true,
            "правка словаря, оставшаяся без ответа из-за падения, дошла до нового процесса")
    verdict(waitAlive(client), "восстановление дошло до конца: hello отвечает")
    verdict(glossary(client).contains("вполёте"), "слово из прерванной команды в словаре")
    verdict(children().count == 1, "Python один (\(children().count))")
    let statuses = log.value
    verdict(!zip(statuses, statuses.dropFirst()).contains { $0.hasPrefix("restarting") && $1 == "running" },
            "статусы по порядку: \(statuses.joined(separator: " → "))")
    stop(client)
    verdict(children().isEmpty, "после остановки своих Python нет")
}

// MARK: S7 — перезапуск из приложения

if enabled("restart") {
    print("\nS7. Перезапуск, как его делает приложение: команды за время остановки старого процесса")
    let (old, _) = tracked()
    try? old.start()
    verdict(waitAlive(old), "старый движок работает")
    // Как было: команда уходила старому клиенту, которого уже останавливают.
    let lost = Box<Bool?>(nil)
    old.shutdown()
    Task {
        do { try await old.remember(heard: "старому слышно", canonical: "старому"); lost.value = false }
        catch { lost.value = true }
    }
    // Как стало: новый клиент на месте сразу, запуск обещан.
    let config = makeConfig()
    let (fresh, log) = tracked(config)
    fresh.expectStart()
    let words = (1...5).map { "перезапуск\($0)" }
    let answers = Box<[String: Bool]>([:])
    for word in words {
        Task {
            do { try await fresh.remember(heard: word + " слышно", canonical: word); answers.update { $0[word] = true } }
            catch { answers.update { $0[word] = false } }
        }
    }
    // Диктовка, начатая в это окно: сессии нет, `stop` сразу говорит «не запущен» — приложение
    // распознаёт записанный файл.
    fresh.startSession("check-session", language: "ru", project: nil, verify: false, agent: false)
    let stopped = await_(5) { try await fresh.stop(session: "check-session", waitVerifierMs: 0, audioSeconds: 1) }
    if case .failure(let error)? = stopped {
        verdict((error as? EngineError) == .notRunning, "stop без процесса отвечает сразу «не запущен» → приложение идёт распознавать файл")
    } else { verdict(false, "stop без процесса должен сразу отказать") }
    verdict(children().count <= 1, "новый клиент до запуска процессов не поднимает (\(children().count))")
    old.shutdownAndWait(timeout: 3)
    verdict(waitFor(3) { children().isEmpty }, "старый Python остановлен до запуска нового")
    verdict(waitFor(5) { lost.value != nil } && lost.value == true, "команда старому клиенту терялась (ошибка, которую приложение глотало)")
    try? fresh.start()
    verdict(waitFor(40) { answers.value.count == words.count } && answers.value.values.allSatisfy { $0 },
            "новый клиент: \(answers.value.values.filter { $0 }.count) из \(words.count) команд приняты после запуска")
    verdict(waitAlive(fresh), "новый движок отвечает на hello")
    verdict(Set(words).isSubset(of: glossary(fresh)), "слова в словаре нового движка")
    verdict(children().count == 1, "Python один (\(children().count))")
    verdict(log.value == ["starting", "running"], "статусы нового клиента: \(log.value.joined(separator: " → "))")
    // Обещанный запуск не состоялся (выход из приложения): ждущие команды получают отказ, а не висят.
    let (never, _) = tracked()
    never.expectStart()
    let refused = Box<Bool?>(nil)
    Task {
        do { try await never.remember(heard: "x", canonical: "y"); refused.value = false } catch { refused.value = true }
    }
    pause(0.2)
    never.shutdown()
    verdict(waitFor(3) { refused.value == true }, "остановка клиента, который так и не запустили, отпускает ждущую команду")
    stop(fresh)
    verdict(children().isEmpty, "после остановки своих Python нет")
}

// MARK: S17 — процесс жив, но не отвечает

if enabled("hung") {
    print("\nS17. Движок жив, но hello без ответа: вторая ступень должна его заменить")
    let (client, _) = tracked()
    try? client.start()
    verdict(waitAlive(client), "движок работает")
    let frozen = children()
    for pid in frozen where children().contains(pid) { kill(pid, SIGSTOP) }
    let reply = await_(5) { try await client.request("hello", timeout: 2, hold: false) }
    var gone = true
    if case .failure(let error)? = reply {
        gone = (error as? EngineError) == .crashed || (error as? EngineError) == .notRunning
        print("  hello: \(error)")
    }
    verdict(EngineRecovery.handshakeFailure(processGone: gone) == .secondStage, "ошибка рукопожатия ведёт на вторую ступень")
    verdict(client.isRunning, "клиент сам такой процесс не перезапустит: он жив")
    // Вторая ступень — перезапуск приложением: остановить старый, поднять новый.
    let (fresh, _) = tracked()
    fresh.expectStart()
    let began = now()
    client.shutdownAndWait(timeout: 3)
    print(String(format: "  остановка зависшего процесса: %.1f с", now() - began))
    verdict(waitFor(2) { children().isEmpty }, "зависший Python остановлен до запуска нового")
    try? fresh.start()
    verdict(waitAlive(fresh), "новый движок отвечает")
    verdict(children().count == 1, "Python один (\(children().count))")
    stop(fresh)

    // Процесс, который не слышит ни `shutdown`, ни SIGTERM: подставной «движок» на том же Python.
    let fake = root.appendingPathComponent("deaf-engine/mostik_engine", isDirectory: true)
    try? fm.createDirectory(at: fake, withIntermediateDirectories: true)
    try? "import signal, time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\nwhile True:\n    time.sleep(1)\n"
        .write(to: fake.appendingPathComponent("__main__.py"), atomically: true, encoding: .utf8)
    var deafConfig = makeConfig()
    deafConfig.engineDir = fake.deletingLastPathComponent()
    let (deaf, _) = tracked(deafConfig)
    try? deaf.start()
    verdict(waitFor(10) { children().count == 1 }, "глухой процесс запущен")
    pause(1.0)  // дать ему дойти до установки обработчика
    let deafBegan = now()
    deaf.shutdownAndWait(timeout: 2)
    print(String(format: "  остановка глухого процесса: %.1f с", now() - deafBegan))
    verdict(children().isEmpty, "процесс, не слышащий SIGTERM, к концу остановки убит: рядом с новым он не останется")
}

// MARK: команды под падениями

if enabled("storm") {
    print("\nS6/S7. Поток команд, движок убивают в случайные моменты")
    let (client, log) = tracked()
    try? client.start()
    verdict(waitAlive(client), "движок работает")
    let total = 60
    let answers = Box<[String: Bool]>([:])
    var kills = 0, peak = 1
    for i in 0..<total {
        let word = "шторм\(i)"
        Task {
            do { try await client.request("remember", fields: ["heard": .string(word + " слышно"), "canonical": .string(word)], timeout: 60)
                 answers.update { $0[word] = true } }
            catch { answers.update { $0[word] = false } }
        }
        pause(0.12)
        if i % 12 == 5 { children().forEach(killOwn); kills += 1 }
        peak = max(peak, children().count)
    }
    verdict(waitFor(90) { answers.value.count == total }, "все \(total) команд получили ответ или ошибку — ни одна не повисла")
    let accepted = answers.value.filter(\.value).keys
    print("  убийств: \(kills), принято команд: \(accepted.count) из \(total), статусы: \(log.value.joined(separator: " → "))")
    verdict(accepted.count == total, "команды не потеряны: приняты все")
    verdict(waitAlive(client), "восстановление дошло до конца")
    let stored = glossary(client)
    verdict(Set(accepted).isSubset(of: stored), "каждое принятое слово есть в словаре (\(stored.filter { $0.hasPrefix("шторм") }.count))")
    verdict(peak == 1 && children().count == 1, "Python всё время один (наибольшее число сразу: \(peak))")
    stop(client)
}
#endif

// MARK: S5 — агент, чьё имя видно только в argv[0]

if enabled("agent") {
    print("\nS5. Агент запущен ссылкой с именем агента на бинарник с другим именем (как нативный Claude Code)")
    let link = root.appendingPathComponent("mostikfakeagent")
    try? fm.createSymbolicLink(at: link, withDestinationURL: executable)
    let agent = Process()
    agent.executableURL = link
    agent.arguments = ["--sleep"]
    agent.standardOutput = FileHandle.nullDevice
    try? agent.run()
    pause(0.5)
    var nameBuf = [CChar](repeating: 0, count: 256)
    proc_name(agent.processIdentifier, &nameBuf, UInt32(nameBuf.count))
    print("  имя процесса по proc_name: \(String(cString: nameBuf)) — имени агента в нём нет")
    let inspector = FrontAppInspector()
    inspector.cacheTTL = 0
    let began = now()
    let found = inspector.runningAgentCLIs(candidates: ["mostikfakeagent"])
    let took = now() - began
    verdict(found == ["mostikfakeagent"], "агент найден по argv[0]")
    print(String(format: "  обход всех процессов с чтением argv: %.1f мс", took * 1000))
    verdict(took < 0.25, "обход укладывается в четверть секунды")
    agent.terminate()
    agent.waitUntilExit()
    verdict(inspector.runningAgentCLIs(candidates: ["mostikfakeagent"]).isEmpty, "после выхода агента его нет")
}

// MARK: S8/S16 — мгновенная смерть и порядок статусов

if enabled("instant") {
    print("\nS8/S16. Процесс умирает сразу после запуска: смерть замечена, статусы по порядку")
    // «Python», который выходит мгновенно: /usr/bin/false. Движок при этом настоящий каталог.
    var config = makeConfig()
    config.python = "/usr/bin/false"
    let width = 40
    let logs = (0..<width).map { _ in Box<[String]>([]) }
    let clients = (0..<width).map { i -> EngineClient in
        let client = EngineClient(config: config)
        client.onStatus = { status in logs[i].update { $0.append(describe(status)) } }
        return client
    }
    DispatchQueue.concurrentPerform(iterations: width) { i in try? clients[i].start() }
    pause(4.6)  // падения 1 и 2 и 3: паузы 1 и 2 с
    var unnoticed = 0, disorder = 0
    for log in logs {
        let seq = log.value
        if !seq.contains("restarting1") { unnoticed += 1 }
        // «Работает» сразу после «упал» того же процесса — статус, пришедший не по порядку.
        if zip(seq, seq.dropFirst()).contains(where: { $0.hasPrefix("restarting") && $1 == "running" }) { disorder += 1 }
        if seq.last == "running" { unnoticed += 1 }
    }
    print("  пример: \(logs[0].value.joined(separator: " → "))")
    verdict(unnoticed == 0, "мгновенная смерть замечена у всех \(width) клиентов (не замечена: \(unnoticed))")
    verdict(disorder == 0, "статусы по порядку у всех (нарушений: \(disorder))")
    clients.forEach { $0.shutdown() }
    pause(2.5)
    let after = logs.map { $0.value.count }
    pause(2.5)
    verdict(zip(after, logs.map { $0.value.count }).allSatisfy { $0 == $1 }, "после остановки клиенты больше не запускаются")
}

if enabled("calendar") {
    print("\nН6. Команда календаря: изменённый файл не запускается")
    final class MemoryStore: HookDigestStore, @unchecked Sendable {
        let box = Box<String?>(nil)
        func read() -> HookDigestRead { box.value.map { .value($0) } ?? .missing }
        func write(_ digest: String) -> Bool { box.value = digest; return true }
    }
    let dir = root.appendingPathComponent("calendar")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let script = dir.appendingPathComponent("events"), marks = dir.appendingPathComponent("runs")
    func install(_ tag: String) {
        try? Data("#!/bin/sh\necho \(tag) >> '\(marks.path)'\necho '[]'\n".utf8).write(to: script)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    }
    func runs() -> [String] { ((try? String(contentsOf: marks, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    install("first")
    let store = MemoryStore()
    store.box.value = CalendarCommandTrust.digest(script.path)  // согласие прежнего вида: только путь
    let statuses = Box<[String]>([])
    let command = CommandCalendar()
    command.mayRun = { path in CalendarCommandTrust.gate(path, store: store) == .run }
    command.onUpdate = { status in
        statuses.update { list in
            switch status {
            case .off: list.append("off")
            case .loading: list.append("loading")
            case .ok: list.append("ok")
            case .failed(let message): list.append("failed: \(message)")
            case .changed: list.append("changed")
            }
        }
    }
    func spin(_ seconds: Double, until done: () -> Bool) {
        let deadline = now() + seconds
        while now() < deadline, !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }
    command.setPath(CalendarCommandTrust.reconcile(script.path, store: store).active)
    spin(5) { statuses.value.contains("ok") }
    verdict(runs() == ["first"] && statuses.value.last == "ok", "прежнее согласие: команда запустилась без вопроса (\(statuses.value.joined(separator: " → ")))")
    verdict(store.box.value?.hasPrefix("v2:") == true, "согласие дополнено содержимым файла")
    command.refresh()
    spin(5) { runs().count == 2 }
    verdict(runs() == ["first", "first"], "тот же файл запускается и дальше")
    spin(1) { statuses.value.last == "ok" }
    install("swapped")
    statuses.value = []
    command.refresh()
    spin(5) { statuses.value.contains("changed") }
    spin(0.5) { false }
    verdict(statuses.value.last == "changed" && runs() == ["first", "first"], "подменённый файл не запущен, статус — «изменился» (запусков: \(runs().count))")
    verdict(!command.isReady, "команда выключена до нового согласия")
    command.refresh()
    spin(0.5) { false }
    verdict(runs().count == 2, "«Обновить» без согласия ничего не запускает")
    CalendarCommandTrust.approve(script.path, store: store)
    command.setPath(script.path)
    spin(5) { runs().count == 3 }
    verdict(runs().last == "swapped", "после нового согласия запускается новый файл")
}

// Только по явному имени: нужен установленный Mostik (читаем его бандл, процессы не трогаем).
if wanted.contains("sign") {
    print("\nН2. Сверка подписи перенесённой копии")
    let installed = URL(fileURLWithPath: "/Applications/Mostik.app")
    if let hash = CodeRequirement.codeHash(at: installed) {
        let hex = { (data: Data?) in data.map { $0.map { String(format: "%02x", $0) }.joined() } ?? "нет" }
        print("  требование подписи: \(CodeRequirement.designated(at: installed) ?? "нет"); отпечаток кода: \(hex(hash))")
        var began = now()
        verdict(CodeRequirement.isIntact(installed, sameAs: hash), "целый бандл проходит (\(Int((now() - began) * 1000)) мс)")
        verdict(!CodeRequirement.isIntact(URL(fileURLWithPath: "/System/Applications/Calculator.app"), sameAs: hash), "чужое приложение не проходит")
        do {
            let copy = root.appendingPathComponent("Mostik.app")
            try fm.copyItem(at: installed, to: copy)
            verdict(CodeRequirement.isIntact(copy, sameAs: hash), "нетронутая копия проходит")
            let victim = copy.appendingPathComponent("Contents/Resources/MOSTIK-VENDOR.json")
            try (try Data(contentsOf: victim) + Data(" ".utf8)).write(to: victim)
            began = now()
            verdict(!CodeRequirement.isIntact(copy, sameAs: hash), "копия с изменённым ресурсом не проходит (\(Int((now() - began) * 1000)) мс)")
            // Подменённый код, честно переподписанный тем же именем: требованию ad-hoc сборки он отвечает.
            let resigned = Process()
            resigned.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            resigned.arguments = ["--force", "--sign", "-", "--identifier", "app.mostik.mac",
                                  "--requirements", "=designated => identifier \"app.mostik.mac\"", copy.path]
            resigned.standardError = FileHandle.nullDevice
            try resigned.run(); resigned.waitUntilExit()
            let valid = { () -> Bool in
                var code: SecStaticCode?
                guard SecStaticCodeCreateWithPath(copy as CFURL, [], &code) == errSecSuccess, let code else { return false }
                var requirement: SecRequirement?
                guard let text = CodeRequirement.designated(at: installed),
                      SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return false }
                return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
            }()
            print("  переподписанная копия: codesign вышел с \(resigned.terminationStatus), требованию подписи отвечает — \(valid ? "да" : "нет"), отпечаток \(hex(CodeRequirement.codeHash(at: copy)))")
            verdict(!CodeRequirement.isIntact(copy, sameAs: hash), "изменённая и переподписанная тем же именем копия не проходит")
        } catch { verdict(false, "копия бандла не получилась: \(error.localizedDescription)") }
        print("  отпечаток самой проверки: \(hex(CodeRequirement.runningCodeHash()))")
    } else {
        print("  установленного Mostik с подписью нет — пропущено")
    }
}

killAllOwn()
try? fm.removeItem(at: root)
let failed = failures.value
print(failed == 0 ? "\nИтог: всё сошлось" : "\nИтог: расхождений — \(failed)")
exit(failed == 0 ? 0 : 1)
