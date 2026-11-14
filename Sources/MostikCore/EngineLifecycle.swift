import Foundation

// MARK: - Перезапуск движка по одному (П8, находка ревью)

/// Перезапуски движка идут строго по одному, а события старого процесса не трогают новый.
///
/// Гонка, которую закрывает: `restartEngine` снимал колбэки со старого клиента, но события,
/// уже поставленные в главную очередь (`.failed`, `.stopped`), и недоделанное рукопожатие
/// старого поколения приходили после старта нового — и запускали ещё один перезапуск или
/// перетирали статус «Готов». Два запроса подряд (Настройки + «Проверка») поднимали два
/// Python с моделями одновременно.
///
/// Порядок: `begin()` (поколение сразу растёт — всё старое отныне чужое) → старый процесс
/// остановлен → `finish()` → новый клиент со своим поколением. Пока идёт перезапуск,
/// новые запросы вливаются в него.
public struct EngineRestartGate: Sendable {
    public private(set) var generation = 0
    public private(set) var restarting = false

    public init() {}

    /// Запрос перезапуска. false — перезапуск уже идёт, этот запрос вливается в него.
    public mutating func begin() -> Bool {
        guard !restarting else { return false }
        restarting = true
        generation += 1
        return true
    }

    /// Старый процесс остановлен; новое поколение можно запускать.
    @discardableResult
    public mutating func finish() -> Int {
        restarting = false
        return generation
    }

    /// Событие или ответ поколения `g` ещё актуальны.
    public func isCurrent(_ g: Int) -> Bool { g == generation && !restarting }
}

// MARK: - Тексты падений движка (П8, пункт 6)

/// Две ступени восстановления. Сам `EngineClient` перезапускает упавший процесс с паузами
/// 1, 2, 4, 8, 16, 30 с (до `maxRapid` падений подряд в первую минуту после запуска). Если и это
/// не помогло — `UpkeepController` ещё трижды пробует поднять движок заново с паузами 2, 5, 15 с,
/// и только потом в «Проверке» остаётся красная строка с кнопкой «Перезапустить».
public enum EngineRecovery {
    /// Паузы второй ступени (R7).
    public static let retryDelays: [Double] = [2, 5, 15]
    /// Сколько быстрых падений подряд терпит первая ступень (`EngineClient.maxRapidRestarts`).
    public static let maxRapid = 6

    /// Строка статуса, пока клиент ждёт перезапуска после падения.
    public static func restarting(attempt: Int, delay: Double, crashes: Int, russian ru: Bool) -> String {
        let seconds = formatSeconds(delay, russian: ru)
        let base = ru
            ? "Движок упал — перезапуск через \(seconds), попытка \(attempt) из \(maxRapid)"
            : "Engine crashed — restarting in \(seconds), attempt \(attempt) of \(maxRapid)"
        guard crashes > 1 else { return base }
        return base + (ru ? " · падений за сеанс: \(crashes)" : " · crashes this session: \(crashes)")
    }

    /// Ошибка + «повтор через N с (k из 3)» на второй ступени.
    public static func retrying(_ why: String, after delay: Double, attempt: Int, russian ru: Bool) -> String {
        let seconds = formatSeconds(delay, russian: ru)
        let tail = ru ? "повтор через \(seconds) (\(attempt) из \(retryDelays.count))"
                      : "retrying in \(seconds) (\(attempt) of \(retryDelays.count))"
        return why.isEmpty ? tail.prefix(1).uppercased() + tail.dropFirst() : why + " · " + tail
    }

    /// Обе ступени исчерпаны.
    public static func gaveUp(_ why: String, crashes: Int, logPath: String, russian ru: Bool) -> String {
        let pauses = retryDelays.map { formatSeconds($0, russian: ru) }
        let tried = ru
            ? "Движок не поднимается: ещё \(retryDelays.count) попытки с паузами \(pauses.joined(separator: ", ")) не помогли"
            : "The engine won’t start: \(retryDelays.count) more attempts \(pauses.joined(separator: ", ")) apart didn’t help"
        var parts = [tried]
        if !why.isEmpty { parts.append(why) }
        if crashes > 0 { parts.append(ru ? "падений за сеанс: \(crashes)" : "crashes this session: \(crashes)") }
        parts.append(ru ? "журнал: \(logPath)" : "log: \(logPath)")
        return parts.joined(separator: " · ")
    }

    public static func formatSeconds(_ seconds: Double, russian ru: Bool) -> String {
        let value = seconds == seconds.rounded() ? String(Int(seconds)) : String(format: "%.1f", seconds)
        return ru ? value.replacingOccurrences(of: ".", with: ",") + "\u{00A0}с" : value + "\u{00A0}s"
    }
}

// MARK: - Жизнь процесса движка (аудит 2026-11-14, S6/S8)

/// Кто и когда вправе запустить процесс движка. Все решения — под замком клиента, одним шагом:
/// «проверил и запустил» по частям давало второй Python.
///
/// Гонка, которую закрывает (S6): упавший клиент ждёт паузу и перезапускается сам. Остановка,
/// пришедшая в момент срабатывания таймера, видела «процесса нет» и уходила, а таймер уже решил
/// запускать — Python поднимался у остановленного клиента, и останавливать его было некому
/// (живой прогон: 48 лишних процессов на 208 попыток). То же при явном `start` во время паузы.
///
/// Каждое решение о запуске получает билет. Остановка и новый запуск гасят прежние билеты:
/// опоздавший таймер и запуск, который остановили на полпути, процесс не поднимут.
public struct EngineSupervisor: Sendable, Equatable {
    public enum Phase: Equatable, Sendable {
        /// Клиент создан, запуска ещё не просили.
        case idle
        /// Запуск обещан (перезапуск ждёт остановки старого процесса): команды копятся.
        case pending
        /// Билет выдан, процесс поднимается.
        case launching
        case running
        /// Процесс упал, идёт пауза перед перезапуском.
        case waiting
        case stopped
        case failed
    }

    public enum Exit: Equatable, Sendable {
        /// Остановили сами.
        case stopped
        /// Упал: перезапуск через `delay` по билету `ticket`.
        case restart(attempt: Int, delay: Double, ticket: Int)
        /// Падает раз за разом — первая ступень сдалась.
        case giveUp(attempt: Int)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var ticket = 0
    /// Падений подряд (каждое — раньше `calmAfter` секунд после запуска).
    public private(set) var attempt = 0
    public var maxRapid: Int
    public var calmAfter: Double

    public init(maxRapid: Int = EngineRecovery.maxRapid, calmAfter: Double = 60) {
        self.maxRapid = maxRapid
        self.calmAfter = calmAfter
    }

    /// Процесс скоро будет: команды с ответом можно придержать до запуска, а не отказывать.
    public var holdsCommands: Bool { phase == .pending || phase == .launching || phase == .waiting }

    /// Запуск обещан, но не сейчас: старый процесс ещё останавливается.
    public mutating func expectStart() {
        if phase == .idle || phase == .stopped || phase == .failed { phase = .pending }
    }

    /// Явный запуск. nil — процесс уже поднимается или работает: второй не нужен.
    public mutating func claimStart() -> Int? {
        guard phase != .launching, phase != .running else { return nil }
        return claim()
    }

    /// Отложенный перезапуск по билету из `exited`. nil — за паузу клиента остановили или запустили иначе.
    public mutating func claimRestart(_ pending: Int) -> Int? {
        guard phase == .waiting, pending == ticket else { return nil }
        return claim()
    }

    private mutating func claim() -> Int {
        phase = .launching
        ticket += 1
        return ticket
    }

    /// Последняя проверка перед самим запуском процесса: билет ещё в силе.
    public func mayRun(_ claimed: Int) -> Bool { phase == .launching && claimed == ticket }

    /// Процесс запущен.
    public mutating func launched(_ claimed: Int) {
        guard mayRun(claimed) else { return }
        phase = .running
    }

    /// Запустить не вышло (нет Python, ошибка запуска).
    public mutating func launchFailed(_ claimed: Int) {
        guard mayRun(claimed) else { return }
        phase = .failed
    }

    /// Процесс завершился; `uptime` — сколько он прожил.
    public mutating func exited(uptime: Double) -> Exit {
        guard phase == .running || phase == .launching else { return .stopped }
        if uptime > calmAfter { attempt = 0 }
        attempt += 1
        guard attempt <= maxRapid else {
            phase = .failed
            return .giveUp(attempt: attempt)
        }
        phase = .waiting
        ticket += 1
        return .restart(attempt: attempt, delay: min(30, pow(2, Double(attempt - 1))), ticket: ticket)
    }

    /// Остановка: любой выданный билет гаснет.
    public mutating func shutdown() {
        phase = .stopped
        ticket += 1
    }
}

// MARK: - Команды, пришедшие без процесса (аудит 2026-11-14, S7)

/// Команды с ответом, отданные клиенту, пока процесса нет, но он вот-вот будет (перезапуск, пауза
/// после падения). Раньше такая команда сразу получала «движок не запущен», а вызывающий код
/// глотал ошибку: слово «запомнить» молча терялось. Теперь строка ждёт запуска и уходит первой.
///
/// Потоковые команды сессии (`start`, `audio`, `stop`) сюда не попадают: диктовку без процесса
/// спасает распознавание записанного файла, а половина сессии хуже, чем ни одной.
public struct EngineOutbox: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        public let id: Int
        public let text: String
    }

    public private(set) var lines: [Line] = []
    /// Потолок: не память, а защита от зависшего в ожидании клиента.
    public var limit: Int

    public init(limit: Int = 200) { self.limit = limit }

    public var isEmpty: Bool { lines.isEmpty }
    public var ids: [Int] { lines.map(\.id) }

    /// false — места нет: команда получает прежний отказ.
    public mutating func hold(id: Int, line: String) -> Bool {
        guard lines.count < limit else { return false }
        lines.append(Line(id: id, text: line))
        return true
    }

    /// Вызывающий перестал ждать (таймаут, отмена): строка не должна уйти движку позже.
    public mutating func drop(id: Int) { lines.removeAll { $0.id == id } }

    /// Процесс поднялся: всё придержанное — в порядке поступления.
    public mutating func drain() -> [Line] {
        defer { lines.removeAll() }
        return lines
    }

    /// Команды, которые можно повторить новому процессу, если прежний умер, не ответив: правки
    /// словаря пользователя. Повтор ничего не портит — запись идемпотентна, а потерять её нельзя.
    public static let resendable: Set<String> = ["remember", "forget", "reject_doubt"]
}

extension EngineRecovery {
    /// Рукопожатие (`hello`, `warmup`) не удалось. Процесс умер — клиент перезапускает его сам и сам
    /// сообщит статус: ставить «ошибка» поверх нельзя. Процесс жив, но не ответил — перезапустить его
    /// некому, кроме второй ступени (раньше статус оставался «ошибка» навсегда, S17).
    public enum HandshakeFailure: Equatable, Sendable {
        case leaveToClient
        case secondStage
    }

    public static func handshakeFailure(processGone: Bool) -> HandshakeFailure {
        processGone ? .leaveToClient : .secondStage
    }
}

// MARK: - Очередь расшифровки встреч и перезапуск движка (аудит 2026-11-14, S7/S12)

/// Сколько раз задание встречи уже ушло живому процессу. Команда, отданная, пока процесса нет,
/// никуда не уходит — её не считаем: иначе единственный повтор после настоящего падения тратился
/// на перезапуск из Настроек.
public enum MeetingRetryPolicy {
    /// Заданию, которое роняет движок, — один повтор.
    public static let maxAttempts = 2

    public static func initialAttempts(engineLive: Bool) -> Int { engineLive ? 1 : 0 }

    /// Перезапуск затеяли мы (Настройки, «Проверка»), а не падение на этой встрече: попытка возвращается.
    public static func afterPlannedRestart(attempts: Int) -> Int { max(0, attempts - 1) }

    /// Движок поднялся заново: слать задание ещё раз?
    public static func mayResend(attempts: Int) -> Bool { attempts < maxAttempts }
}

/// Список встреч после чтения с диска. Живая встреча (идёт запись, в очереди расшифровки) на диске
/// выглядит как «не расшифрована»: её состояние знает только приложение, и скан его не перетирает.
public enum MeetingListMerge {
    public static func merge<Item>(scanned: [Item], current: [Item], id: (Item) -> String,
                                   isLive: (Item) -> Bool) -> [Item] {
        let live = Dictionary(current.filter(isLive).map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
        let known = Set(scanned.map(id))
        // Встречи, начатые за время чтения, не теряем.
        let fresh = current.filter { !known.contains(id($0)) }
        return scanned.map { live[id($0)] ?? $0 } + fresh
    }
}
