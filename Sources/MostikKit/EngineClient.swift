import Darwin
import Foundation
import MostikCore

public enum EngineError: Error, LocalizedError, Equatable {
    case notRunning
    case crashed
    case timeout(String)
    case engine(code: String, message: String)
    case launch(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning: return L("Движок не запущен", "Engine isn’t running")
        case .crashed: return L("Движок упал", "Engine crashed")
        case .timeout(let what): return L("Движок не ответил вовремя: \(what)", "Engine timed out: \(what)")
        case .engine(let code, let message): return EngineErrorText.describe(code: code, message: message)
        case .launch(let message): return message
        }
    }
}

/// Процесс движка и протокол JSON-строк (§2, §12.9). Ответы сопоставляются по `id`,
/// `final` — по `session`. stdout и stderr читаются постоянно, stderr — в лог.
/// Упавший процесс перезапускается с нарастающей паузой.
public final class EngineClient: @unchecked Sendable {
    public struct Config: Sendable {
        public var python: String
        public var engineDir: URL
        public var home: URL
        public var logFile: URL
        public var nice: Int32
        /// Куда класть отчёт о сбое движка (П8, пункт 6); nil — не класть.
        public var crashDir: URL?

        public init(python: String, engineDir: URL, home: URL, logFile: URL, nice: Int32 = 5, crashDir: URL? = nil) {
            self.python = python; self.engineDir = engineDir; self.home = home
            self.logFile = logFile; self.nice = nice; self.crashDir = crashDir
        }
    }

    public enum Status: Equatable, Sendable {
        case starting
        case running
        case restarting(attempt: Int, delay: Double)
        case stopped
        case failed(String)
    }

    /// События без ожидающего: partial, progress, meeting_done, error, «чужой» final.
    /// Колбэки ставит главный поток, зовут фоновые (чтение stdout, завершение процесса): доступ под замком.
    public var onEvent: ((EngineEvent) -> Void)? {
        get { lock.withLock { eventHandler } }
        set { lock.withLock { eventHandler = newValue } }
    }
    /// Статусы приходят по одному и в порядке переходов: «работает» не обгонит «упал» того же процесса.
    public var onStatus: ((Status) -> Void)? {
        get { lock.withLock { statusHandler } }
        set { lock.withLock { statusHandler = newValue } }
    }
    /// Последний статус клиента (до первого запуска — `stopped`).
    public var status: Status { lock.withLock { lastStatus } }

    /// Конфигурация запуска. Меняется только до запуска (`reconfigure`): читать под замком нельзя.
    public var config: Config { configLock.withLock { storedConfig } }
    private let configLock = NSLock()
    private var storedConfig: Config
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "mostik.engine.write")
    private let statusQueue = DispatchQueue(label: "mostik.engine.status")
    private var eventHandler: ((EngineEvent) -> Void)?
    private var statusHandler: ((Status) -> Void)?
    private var lastStatus: Status = .stopped
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var logHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var nextID = 1
    private var replyWaiters: [Int: CheckedContinuation<[String: JSONValue], Error>] = [:]
    private struct FinalWaiter { let id: Int; let isFile: Bool; let cont: CheckedContinuation<DictationResult, Error> }
    private var finalWaiters: [String: FinalWaiter] = [:]
    /// Кто вправе запускать процесс: явный запуск, отложенный перезапуск и остановка решаются одним шагом (S6).
    private var supervisor = EngineSupervisor(maxRapid: EngineClient.maxRapidRestarts)
    /// Команды с ответом, пришедшие, пока процесса нет, но он будет (S7).
    private var outbox = EngineOutbox()
    /// Строки правок словаря, ждущих ответа: умер процесс — уходят новому, один раз.
    private var resendable: [Int: String] = [:]
    private var resent: Set<Int> = []
    private var launchedAt = Date()
    /// Сколько падений подряд (каждое — меньше минуты после запуска) терпим до статуса `failed`.
    static let maxRapidRestarts = EngineRecovery.maxRapid
    static let logRotation = LogRotation(maxBytes: 2_000_000, keep: 3)
    /// Проверка: вызывается в запуске перед самим стартом процесса — окно, в которое попадала остановка.
    @_spi(Testing) public var willRun: (() -> Void)?

    public init(config: Config) {
        self.storedConfig = config
        signal(SIGPIPE, SIG_IGN)
    }

    public var isRunning: Bool { lock.withLock { process?.isRunning ?? false } }

    // MARK: процесс

    /// Запуск. Процесс уже поднимается или работает — ничего не делает: второй Python не нужен.
    public func start() throws {
        guard let ticket = lock.withLock({ supervisor.claimStart() }) else { return }
        try launch(ticket)
    }

    /// Запуск будет чуть позже (перезапуск ждёт, пока остановится прежний процесс): команды с ответом,
    /// пришедшие до него, не получают «движок не запущен», а уходят первыми после запуска.
    public func expectStart() {
        lock.withLock { supervisor.expectStart() }
    }

    /// Настройки сменились, пока новый клиент ждал остановки старого процесса: запуск пойдёт с ними.
    /// Работающему или поднимающемуся клиенту конфигурацию не меняем — false.
    @discardableResult
    public func reconfigure(_ config: Config) -> Bool {
        lock.withLock {
            guard supervisor.phase == .idle || supervisor.phase == .pending else { return false }
            configLock.withLock { storedConfig = config }
            return true
        }
    }

    /// Статус — под замком, в порядке переходов; до получателя доходит по одному.
    private func emitLocked(_ status: Status) {
        lastStatus = status
        statusQueue.async { [weak self] in
            guard let self, let handler = self.lock.withLock({ self.statusHandler }) else { return }
            handler(status)
        }
    }

    /// Запуск не состоялся: статус, отказ придержанным командам, исключение.
    private func failLaunch(_ ticket: Int, _ message: String) throws -> Never {
        lock.lock()
        var held: [() -> Void] = []
        if supervisor.mayRun(ticket) {
            supervisor.launchFailed(ticket)
            emitLocked(.failed(message))
            held = takeHeldLocked(EngineError.notRunning)
        }
        lock.unlock()
        held.forEach { $0() }
        throw EngineError.launch(message)
    }

    private func launch(_ ticket: Int) throws {
        let fm = FileManager.default
        let config = self.config
        guard fm.isExecutableFile(atPath: config.python) else {
            try failLaunch(ticket, L("Python не найден: \(config.python)", "Python not found: \(config.python)"))
        }
        guard fm.fileExists(atPath: config.engineDir.appendingPathComponent("mostik_engine").path) else {
            try failLaunch(ticket, L("Движок не найден: \(config.engineDir.path)", "Engine not found: \(config.engineDir.path)"))
        }
        lock.withLock { if supervisor.mayRun(ticket) { emitLocked(.starting) } }
        openLog()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: config.python)
        // П10 С1: `-I` и путь к движку аргументом; без PYTHON*, DYLD_*, LD_* в окружении.
        // Офлайн HF, без телеметрии и проверки обновлений transcriber — как раньше.
        proc.arguments = EngineLaunch.arguments(engineDir: config.engineDir)
        proc.currentDirectoryURL = config.engineDir
        proc.environment = EngineLaunch.environment(base: ProcessInfo.processInfo.environment, home: config.home,
                                                    crashDir: config.crashDir)

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.receiveStdout(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.receiveStderr(data)
        }
        proc.terminationHandler = { [weak self] p in self?.terminated(p) }
        willRun?()

        // Проверка билета, запуск и запись процесса — под одним замком. Остановка, пришедшая, пока запуск
        // готовился, гасит билет, и процесс не поднимается; пришедшая позже — видит процесс и останавливает
        // его. Мгновенная смерть тоже ждёт замка: `terminated` узнаёт процесс (S8).
        lock.lock()
        guard supervisor.mayRun(ticket) else {
            lock.unlock()
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return
        }
        do { try proc.run() } catch {
            lock.unlock()
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            try failLaunch(ticket, L("Не удалось запустить движок: \(error.localizedDescription)",
                                     "Couldn’t start the engine: \(error.localizedDescription)"))
        }
        process = proc
        let stdin = inPipe.fileHandleForWriting
        stdinHandle = stdin
        stdoutBuffer.removeAll()
        stderrBuffer.removeAll()
        launchedAt = Date()
        supervisor.launched(ticket)
        // Диктовка — nice 5 (§5): движок не мешает переднему приложению.
        setpriority(PRIO_PROCESS, id_t(proc.processIdentifier), config.nice)
        // Придержанные команды — первыми, в порядке поступления.
        for line in outbox.drain() { writeLocked(line.text, to: stdin) }
        emitLocked(.running)
        lock.unlock()
    }

    private func openLog() {
        StorageHygiene.secure([config.logFile.deletingLastPathComponent()])
        // Ротация при каждом запуске процесса: больше 2 МБ — engine.log.1, .2 (П8, пункт 6).
        AppLog.rotateIfNeeded(config.logFile, Self.logRotation)
        StorageHygiene.ensurePrivateFile(config.logFile)
        lock.lock()
        try? logHandle?.close()
        logHandle = try? FileHandle(forWritingTo: config.logFile)
        _ = try? logHandle?.seekToEnd()
        lock.unlock()
    }

    private func terminated(_ proc: Process) {
        lock.lock()
        guard proc === process else { lock.unlock(); return }
        process = nil
        stdinHandle = nil
        let exit = supervisor.exited(uptime: Date().timeIntervalSince(launchedAt))
        var replies = replyWaiters; replyWaiters.removeAll()
        let finals = finalWaiters; finalWaiters.removeAll()
        // Правка словаря, оставшаяся без ответа, уходит новому процессу — один раз.
        if case .restart = exit {
            for id in replies.keys.sorted() {
                guard let line = resendable[id], !resent.contains(id), outbox.hold(id: id, line: line) else { continue }
                resent.insert(id)
                replyWaiters[id] = replies.removeValue(forKey: id)
            }
        }
        for id in replies.keys { resendable[id] = nil; resent.remove(id) }
        let line = "[mostik] engine exited with status \(proc.terminationStatus)\n"
        try? logHandle?.write(contentsOf: Data(line.utf8))
        switch exit {
        case .stopped: emitLocked(.stopped)
        case .restart(let attempt, let delay, _): emitLocked(.restarting(attempt: attempt, delay: delay))
        case .giveUp:
            // Падает сразу после запуска раз за разом (сломанное окружение Python) — не
            // перезапускаем бесконечно: каждые 30 с новый Python ест CPU и батарею.
            emitLocked(.failed(L("Движок падает при запуске (код \(proc.terminationStatus)), см. ~/Library/Logs/Mostik/engine.log",
                                 "Engine keeps crashing on start (code \(proc.terminationStatus)), see ~/Library/Logs/Mostik/engine.log")))
        }
        lock.unlock()
        // Нативное падение (сигнал) — отчёт с хвостом журнала: там дамп faulthandler.
        // Исключение Python движок описывает сам (`MOSTIK_CRASH_DIR`).
        if exit != .stopped, proc.terminationReason == .uncaughtSignal { writeSignalReport(status: proc.terminationStatus, pid: proc.processIdentifier) }

        replies.values.forEach { $0.resume(throwing: EngineError.crashed) }
        finals.values.forEach { $0.cont.resume(throwing: EngineError.crashed) }

        guard case .restart(_, let delay, let pending) = exit else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            // Билет гаснет, если за паузу клиента остановили или запустили заново.
            guard let self, let ticket = self.lock.withLock({ self.supervisor.claimRestart(pending) }) else { return }
            try? self.launch(ticket)
        }
    }

    /// Придержанные команды, которым процесса уже не дождаться: снять ожидающих (под замком),
    /// ответить им — после замка.
    private func takeHeldLocked(_ error: Error) -> [() -> Void] {
        outbox.drain().compactMap { line -> (() -> Void)? in
            resendable[line.id] = nil
            resent.remove(line.id)
            if let waiter = replyWaiters.removeValue(forKey: line.id) { return { waiter.resume(throwing: error) } }
            if let key = finalWaiters.first(where: { $0.value.id == line.id })?.key,
               let waiter = finalWaiters.removeValue(forKey: key) { return { waiter.cont.resume(throwing: error) } }
            return nil
        }
    }

    /// Отчёт о падении движка по сигналу: номер сигнала и последние строки `engine.log`
    /// (события, дамп faulthandler) — текста диктовок в журнале нет.
    private func writeSignalReport(status: Int32, pid: Int32) {
        guard let dir = config.crashDir else { return }
        StorageHygiene.secure([dir])
        let tail = (try? String(contentsOf: config.logFile, encoding: .utf8))
            .map { $0.split(separator: "\n", omittingEmptySubsequences: false).suffix(80).joined(separator: "\n") } ?? ""
        let text = """
        Mostik — отчёт о сбое движка / engine crash report
        Только на этом Mac, никуда не отправляется. / Stays on this Mac, never sent.

        kind: engine killed by signal \(status)
        python: \(config.python)

        engine.log (tail):
        \(tail)
        """
        let url = dir.appendingPathComponent(CrashReportPolicy.fileName(kind: "engine", date: Date(), pid: pid))
        StorageHygiene.writePrivate(text, to: url)
    }

    /// Мягкая остановка: `shutdown`, через 2 с — terminate.
    public func shutdown() {
        lock.lock()
        supervisor.shutdown()
        let proc = process
        let held = takeHeldLocked(EngineError.notRunning)
        lock.unlock()
        held.forEach { $0() }
        guard let proc else { return }
        send("shutdown")
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if proc.isRunning { proc.terminate() }
        }
    }

    /// Синхронная остановка для выхода из приложения.
    public func shutdownAndWait(timeout: TimeInterval = 2) {
        shutdown()
        let proc = lock.withLock { process }
        let deadline = Date().addingTimeInterval(timeout)
        while let proc, proc.isRunning, Date() < deadline { usleep(50_000) }
        if let proc, proc.isRunning {
            proc.terminate()
            // Перезапуск ждёт выхода старого процесса: два Python с моделями — двойная память.
            let hard = Date().addingTimeInterval(1)
            while proc.isRunning, Date() < hard { usleep(50_000) }
            // Зависший процесс SIGTERM не слышит (остановлен, застрял в нативном коде): без SIGKILL он
            // остался бы жить рядом с новым.
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
                let last = Date().addingTimeInterval(1)
                while proc.isRunning, Date() < last { usleep(20_000) }
            }
        }
    }

    // MARK: ввод-вывод

    private func receiveStdout(_ data: Data) {
        lock.lock()
        stdoutBuffer.append(data)
        var lines: [Data] = []
        while let nl = stdoutBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(stdoutBuffer[stdoutBuffer.startIndex..<nl])
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
        }
        lock.unlock()
        for line in lines {
            let text = String(decoding: line, as: UTF8.self)
            guard let event = EngineCodec.decode(line: text) else {
                if !text.trimmingCharacters(in: .whitespaces).isEmpty { log("[stdout] \(text)") }
                continue
            }
            dispatch(event)
        }
    }

    private func receiveStderr(_ data: Data) {
        lock.lock()
        try? logHandle?.write(contentsOf: data)
        lock.unlock()
    }

    private func log(_ line: String) {
        lock.lock()
        try? logHandle?.write(contentsOf: Data((line + "\n").utf8))
        lock.unlock()
    }

    private func dispatch(_ event: EngineEvent) {
        switch event {
        case .reply(let id, let ok, let payload):
            guard let waiter = takeReplyWaiter(id) else {
                // Ответ на команду без ожидания (stop, transcribe_file, meeting) — ошибкой считаем только ok:false.
                if !ok, !failFinal(id: id, error: Self.error(from: payload)) { onEvent?(event) }
                return
            }
            if ok { waiter.resume(returning: payload) } else { waiter.resume(throwing: Self.error(from: payload)) }
        case .final(let result):
            if let waiter = takeFinalWaiter(session: result.session) {
                waiter.cont.resume(returning: result)
            } else {
                onEvent?(event)
            }
        case .error(let id, let session, let code, let message):
            let error = EngineError.engine(code: code, message: message)
            if let id, let waiter = takeReplyWaiter(id) {
                waiter.resume(throwing: error); return
            }
            if let session, let waiter = takeFinalWaiter(session: session) {
                waiter.cont.resume(throwing: error); return
            }
            if let id, failFinal(id: id, error: error) { return }
            onEvent?(event)
        default:
            onEvent?(event)
        }
    }

    /// `final` строго по сессии: движок возвращает `session` и для `transcribe_file`.
    /// Подбирать «самый старый transcribe_file» нельзя: опоздавший `final` диктовки после
    /// таймаута `stop` попал бы в чужое «распознать заново» и перезаписал другую запись истории.
    private func takeFinalWaiter(session: String) -> FinalWaiter? {
        lock.withLock {
            guard let waiter = finalWaiters.removeValue(forKey: session) else { return nil }
            outbox.drop(id: waiter.id)
            return waiter
        }
    }

    @discardableResult
    private func failFinal(id: Int, error: Error) -> Bool {
        let waiter: FinalWaiter? = lock.withLock {
            guard let key = finalWaiters.first(where: { $0.value.id == id })?.key else { return nil }
            outbox.drop(id: id)
            return finalWaiters.removeValue(forKey: key)
        }
        waiter?.cont.resume(throwing: error)
        return waiter != nil
    }

    private static func error(from payload: [String: JSONValue]) -> EngineError {
        let code = payload["code"]?.stringValue ?? "error"
        let message = payload["message"]?.stringValue ?? payload["error"]?.stringValue ?? ""
        return .engine(code: code, message: message)
    }

    private func allocateID() -> Int { lock.withLock { defer { nextID += 1 }; return nextID } }

    /// Ожидающий ответа по `id` — вместе с его записями о повторе.
    private func takeReplyWaiter(_ id: Int) -> CheckedContinuation<[String: JSONValue], Error>? {
        lock.withLock {
            resendable[id] = nil
            resent.remove(id)
            outbox.drop(id: id)
            return replyWaiters.removeValue(forKey: id)
        }
    }

    /// Запись строки в stdin — через последовательную очередь, чтобы не держать замок на блокирующей записи.
    /// Постановка в очередь — под замком: порядок строк тот же, что порядок команд.
    private func writeLocked(_ line: String, to handle: FileHandle) {
        writeQueue.async { [weak self] in
            do { try handle.write(contentsOf: Data((line + "\n").utf8)) } catch {
                self?.log("[mostik] stdin write failed: \(error)")
            }
        }
    }

    private func write(_ line: String) -> Bool {
        lock.withLock {
            guard let handle = stdinHandle else { return false }
            writeLocked(line, to: handle)
            return true
        }
    }

    // MARK: команды

    /// Действующие согласия на облако (приватность). Ставит контроллер приложения при каждом
    /// применении настроек; движок отказывает облачной команде без `consent: true`.
    private static let grantsLock = NSLock()
    nonisolated(unsafe) private static var grants = CloudGrants()
    public static var cloudGrants: CloudGrants {
        get { grantsLock.withLock { grants } }
        set { grantsLock.withLock { grants = newValue } }
    }

    /// Ваше имя из Настроек → Общие: движку для расшифровки встречи (`owner`) — по нему он отличает
    /// вас от единственного собеседника в окне звонка. Ставит контроллер при применении настроек.
    nonisolated(unsafe) private static var owner = ""
    public static var ownerName: String {
        get { grantsLock.withLock { owner } }
        set { grantsLock.withLock { owner = newValue } }
    }

    /// Строка команды с полем `consent` для облачного бэкенда (`CloudConsentStamp`).
    static func encode(_ cmd: String, id: Int, fields: [String: JSONValue]) -> String {
        EngineCodec.command(cmd, id: id, fields: CloudConsentStamp.stamp(cmd, fields: fields, grants: cloudGrants))
    }

    /// Команда без ожидания ответа.
    @discardableResult
    public func send(_ cmd: String, fields: [String: JSONValue] = [:]) -> Int {
        let id = allocateID()
        _ = write(Self.encode(cmd, id: id, fields: fields))
        return id
    }

    /// Команда с ответом `{ok, ...}`; ok:false и `error` с тем же id — исключение.
    /// Процесса нет, но он вот-вот будет (перезапуск, пауза после падения) — команда ждёт запуска в
    /// пределах своего таймаута, а не получает «движок не запущен» (S7).
    /// `hold: false` — для проверки связи (`hello`): ей нужен ответ именно этого процесса.
    public func request(_ cmd: String, fields: [String: JSONValue] = [:], timeout: TimeInterval = 30,
                        hold: Bool = true) async throws -> [String: JSONValue] {
        let id = allocateID()
        let line = Self.encode(cmd, id: id, fields: fields)
        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if let handle = stdinHandle {
                writeLocked(line, to: handle)
            } else if !(hold && supervisor.holdsCommands && outbox.hold(id: id, line: line)) {
                lock.unlock()
                cont.resume(throwing: EngineError.notRunning)
                return
            }
            replyWaiters[id] = cont
            if EngineOutbox.resendable.contains(cmd) { resendable[id] = line }
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, let w = self.takeReplyWaiter(id) else { return }
                w.resume(throwing: EngineError.timeout(cmd))
            }
        }
    }

    /// Команда, итог которой — событие `final` с `session`. Распознавание файла ждёт запуска так же, как
    /// команда с ответом; `stop` — нет: без процесса сессии нет, диктовку спасает распознавание записи.
    private func awaitFinal(_ cmd: String, session: String, isFile: Bool, fields: [String: JSONValue],
                            timeout: TimeInterval) async throws -> DictationResult {
        let id = allocateID()
        var all = fields
        all["session"] = .string(session)
        let line = Self.encode(cmd, id: id, fields: all)
        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if let handle = stdinHandle {
                writeLocked(line, to: handle)
            } else if !(isFile && supervisor.holdsCommands && outbox.hold(id: id, line: line)) {
                lock.unlock()
                cont.resume(throwing: EngineError.notRunning)
                return
            }
            finalWaiters[session] = FinalWaiter(id: id, isFile: isFile, cont: cont)
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, let w = self.takeFinalWaiter(session: session) else { return }
                w.cont.resume(throwing: EngineError.timeout(cmd))
            }
        }
    }

    // MARK: диктовка

    /// `polishCLI` — выбор из Настроек («auto», «claude», «codex»): движок отвечает уже о нём.
    public func hello(polishCLI: String? = nil) async throws -> [String: JSONValue] {
        try await request("hello", fields: polishCLI.map { ["polish_cli": .string($0)] } ?? [:], timeout: 30, hold: false)
    }

    /// `polishBackend` — локальная LLM, которую поднять заранее (`WarmupPolicy.polishBackendToWarm`, шаг 1, п. 7).
    public func warmup(language: String, polishBackend: String? = nil) async throws -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["language": .string(language)]
        if let polishBackend { fields["polish"] = .object(["backend": .string(polishBackend)]) }
        return try await request("warmup", fields: fields, timeout: 300)
    }

    /// Начало сессии. Строка уходит в stdin сразу, до первого `audio`: движок читает по порядку.
    /// Ответ не ждём — если старт не удался, `stop` вернёт ошибку и контроллер распознает WAV.
    public func startSession(_ session: String, language: String, project: String?, verify: Bool, agent: Bool,
                             sources: [String] = [], polish: PolishRequest? = nil, languages: [String] = [],
                             extra: [String: JSONValue] = [:]) {
        var fields: [String: JSONValue] = [
            "session": .string(session), "language": .string(language),
            "project": project.map { .string($0) } ?? .null,
            "verify": .bool(verify), "agent": .bool(agent),
            "sources": .array(sources.map { .string($0) }),
        ]
        if let polish { fields["polish"] = Self.polishField(polish) }
        // Автоопределение языка (L5): список пользователя, язык по умолчанию — первым.
        if languages.count > 1 { fields["languages"] = .array(languages.map { .string($0) }) }
        fields.merge(extra) { current, _ in current }  // П6-А: `rules`, `context` (P1, P3)
        send("start", fields: fields)
    }

    /// `polish: {backend, style, pack?, translate?, stream?}` протокола (D3, D4; П6-А: P4, V3, P6).
    public static func polishField(_ polish: PolishRequest) -> JSONValue {
        var object: [String: JSONValue] = ["backend": .string(polish.backend.rawValue), "style": .string(polish.style.rawValue)]
        if let pack = polish.pack { object["pack"] = .string(pack) }
        if let translate = polish.translate {
            object["translate"] = .object(["to": .string(translate.to), "tone": .string(translate.tone.rawValue)])
        }
        if polish.stream { object["stream"] = .bool(true) }
        if polish.late { object["late"] = .bool(true) }
        return .object(object)
    }

    /// Запас таймаута `stop` на полировщик: его собственный таймаут 30 с (V5) плюс запуск процесса.
    public static let polishTimeoutReserve: TimeInterval = 35

    public func sendAudio(session: String, pcm: Data) {
        let fields: [String: JSONValue] = ["session": .string(session), "pcm": .string(pcm.base64EncodedString())]
        _ = write(EngineCodec.command("audio", id: allocateID(), fields: fields))
    }

    /// `stop` → `final`. Таймаут §6: 15 с + 0,5 × длительность записи.
    /// `timeout` — только для симуляции, где звук приходит быстрее реального времени.
    public func stop(session: String, waitVerifierMs: Int, audioSeconds: Double,
                     timeout: TimeInterval? = nil, polishing: Bool = false) async throws -> DictationResult {
        let timeout = timeout ?? (15 + 0.5 * audioSeconds + Double(waitVerifierMs) / 1000
                                  + (audioSeconds >= Self.longDictationSeconds ? Self.longVerifierWaitSeconds : 0)
                                  + (polishing ? Self.polishTimeoutReserve : 0))
        return try await awaitFinal("stop", session: session, isFile: false,
                                    fields: ["wait_verifier_ms": .number(Double(waitVerifierMs))], timeout: timeout)
    }

    /// Как в движке (`LONG_DICTATION_S`, `LONG_WAIT_CAP_S`): длинная диктовка ждёт вторую модель до конца.
    public static let longDictationSeconds: Double = 30
    public static let longVerifierWaitSeconds: Double = 180

    /// «Вставить сразу»: движок перестаёт ждать вторую модель и отдаёт `final` с тем, что готово.
    public func skipVerifier(session: String) {
        send("skip_verifier", fields: ["session": .string(session)])
    }

    public func cancel(session: String) {
        if let w = takeFinalWaiter(session: session) {
            w.cont.resume(throwing: CancellationError())
        }
        send("cancel", fields: ["session": .string(session)])
    }

    /// Распознать WAV целиком (повтор из истории, восстановление после падения, `--simulate`).
    public func transcribeFile(path: String, language: String, project: String?, sources: [String] = [],
                               polish: PolishRequest? = nil, timeout: TimeInterval? = nil,
                               languages: [String] = [], extra: [String: JSONValue] = [:]) async throws -> DictationResult {
        let seconds = WAVInfo.duration(of: URL(fileURLWithPath: path)) ?? 60
        let session = "file-" + UUID().uuidString.lowercased()
        var fields: [String: JSONValue] = [
            "path": .string(path), "language": .string(language),
            "project": project.map { .string($0) } ?? .null,
            "sources": .array(sources.map { .string($0) }),
        ]
        if let polish { fields["polish"] = Self.polishField(polish) }
        if languages.count > 1 { fields["languages"] = .array(languages.map { .string($0) }) }
        fields.merge(extra) { current, _ in current }  // П6-А: `rules`, `context`
        return try await awaitFinal("transcribe_file", session: session, isFile: true, fields: fields,
                                    timeout: timeout ?? (15 + 0.5 * seconds + 120
                                                         + (polish == nil ? 0 : Self.polishTimeoutReserve)))
    }

    /// Кусок живой расшифровки встречи (W10): без сверки большой моделью и без полировки —
    /// строка нужна по ходу разговора, точный текст даст расшифровка после остановки.
    public func transcribeLive(path: String, language: String, languages: [String] = []) async throws -> DictationResult {
        let seconds = WAVInfo.duration(of: URL(fileURLWithPath: path)) ?? 25
        var fields: [String: JSONValue] = [
            "path": .string(path), "language": .string(language), "project": .null,
            "sources": .array([]), "verify": .bool(false), "wait_verifier_ms": .number(0),
        ]
        if languages.count > 1 { fields["languages"] = .array(languages.map { .string($0) }) }
        return try await awaitFinal("transcribe_file", session: "live-" + UUID().uuidString.lowercased(), isFile: true,
                                    fields: fields, timeout: 30 + seconds)
    }

    // MARK: прочее

    public func power(_ state: PowerState) async throws -> Bool {
        let reply = try await request("power", fields: state.commandFields, timeout: 10)
        return reply["verifier_enabled"]?.boolValue ?? true
    }

    public func projectGlossary(path: String) async throws -> [String] {
        let reply = try await request("project_glossary", fields: ["path": .string(path)], timeout: 120)
        guard case .array(let items)? = reply["terms"] else { return [] }
        return items.compactMap { item in
            if let s = item.stringValue { return s }
            if case .object(let o) = item { return o["term"]?.stringValue ?? o["canonical"]?.stringValue }
            return nil
        }
    }

    public func remember(heard: String, canonical: String) async throws {
        _ = try await request("remember", fields: ["heard": .string(heard), "canonical": .string(canonical)])
    }

    public func forget(canonical: String) async throws {
        _ = try await request("forget", fields: ["canonical": .string(canonical)])
    }

    /// Личный словарь: `[{canonical, aliases, source}]` (терпимо к вариантам полей).
    public func glossaryList() async throws -> [(canonical: String, aliases: [String], source: String)] {
        let reply = try await request("glossary_list")
        let raw: [JSONValue]
        if case .array(let a)? = reply["entries"] { raw = a }
        else if case .array(let a)? = reply["terms"] { raw = a }
        else if case .array(let a)? = reply["items"] { raw = a }
        else { raw = [] }
        return raw.compactMap { value in
            guard case .object(let o) = value, let canonical = o["canonical"]?.stringValue else { return nil }
            var aliases: [String] = []
            if case .array(let a)? = o["aliases"] { aliases = a.compactMap(\.stringValue) }
            else if let heard = o["heard"]?.stringValue { aliases = [heard] }
            let source = o["source"]?.stringValue ?? ((o["auto_apply"]?.boolValue ?? false) ? "learned" : "personal")
            return (canonical, aliases, source)
        }
    }

    /// Расшифровка встречи: события `progress` и `meeting_done` приходят в `onEvent`.
    /// `diarize: false` — повтор после нехватки памяти: собеседники одним голосом, без модели голосов (R3a).
    @discardableResult
    public func meeting(mic: URL, system: URL, outDir: URL, language: String, speakers: Int?,
                        marks: [MeetingMarkPayload] = [], title: String? = nil, attendees: [String] = [],
                        diarize: Bool = true) -> Int {
        send("meeting", fields: [
            "mic": .string(mic.path), "system": .string(system.path), "out_dir": .string(outDir.path),
            "language": .string(language), "speakers": speakers.map { .number(Double($0)) } ?? .null,
            "marks": MeetingMarkPayload.fields(marks),
            "title": title.map { .string($0) } ?? .null,
            "attendees": .array(attendees.map { .string($0) }),
            "owner": Self.ownerName.isEmpty ? .null : .string(Self.ownerName),
            "diarize": .bool(diarize),
        ])
    }

    // MARK: источники словаря (S1, S5)

    /// `calendar`: события на ±7 дней заменяют прошлый набор целиком; пустой список — очистка.
    @discardableResult
    public func calendar(_ events: [CalendarEvent]) async throws -> [String: JSONValue] {
        try await request("calendar", fields: CalendarLogic.commandFields(events), timeout: 60)
    }

    /// `sources` (из кэша) или `rescan` (заново): источники со счётчиками и термины с происхождением.
    public func sources(project: String?, sources: [String], rescan: Bool) async throws -> SourcesReply {
        let reply = try await request(rescan ? "rescan" : "sources", fields: [
            "project": project.map { .string($0) } ?? .null,
            "sources": .array(sources.map { .string($0) }),
        ], timeout: rescan ? 600 : 300)
        return SourcesReply.parse(reply)
    }
}
