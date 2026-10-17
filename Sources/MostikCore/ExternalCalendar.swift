import CryptoKit
import Foundation

/// Источник встреч. В приложении их два: календарь macOS (EventKit) и внешняя команда;
/// `CalendarSource` в MostikKit сливает оба.
public protocol CalendarProvider: AnyObject, Sendable {
    /// Источнику есть что отдать: доступ к календарю выдан или команда подключена.
    var isReady: Bool { get }
    /// Встречи (≥2 участника) на ±`days` дней от `now`.
    func meetings(around now: Date, days: Int) -> [CalendarEvent]
}

public extension CalendarProvider {
    func meetings(around now: Date = Date()) -> [CalendarEvent] {
        meetings(around: now, days: CalendarLogic.windowDays)
    }

    /// Встреча, которая идёт сейчас (±10 минут).
    func current(at now: Date = Date()) -> CalendarEvent? {
        CalendarLogic.current(in: meetings(around: now, days: 1), at: now)
    }
}

/// Внешний календарь — команда, которая печатает события JSON (docs/external-calendar.md).
/// Для календаря, которого нет в Календаре macOS: рабочий сервер, Exchange без аккаунта на Mac,
/// свой скрипт. Mostik запускает файл без shell с аргументами `--from <ISO> --to <ISO>`
/// и читает stdout: `{"events": [{"id", "title", "start", "end", "attendees", ...}]}`.
public enum ExternalCalendar {
    /// Дольше — процесс завершается, события остаются прежними.
    public static let timeout: TimeInterval = 20
    /// Вывод больше — не читаем: это не календарь, а ошибка или атака на память.
    public static let maxOutputBytes = 2_000_000
    public static let maxEvents = 2000
    /// Как часто перезапускать команду: чаще календарь не меняется, а запуск стоит процесса.
    public static let refreshInterval: TimeInterval = 300
    /// Окно выборки — то же, что у EventKit.
    public static let windowDays = CalendarLogic.windowDays
    static let maxText = 200
    static let maxNotes = 2000
    static let maxPeople = 200

    public enum ParseError: Error, Equatable {
        case notJSON
        case noEvents
        case tooMany(Int)
    }

    /// Аргументы команды: окно выборки в ISO 8601 (UTC).
    public static func arguments(around now: Date, days: Int = windowDays) -> [String] {
        let span = TimeInterval(days) * 86_400
        return ["--from", iso.string(from: now.addingTimeInterval(-span)),
                "--to", iso.string(from: now.addingTimeInterval(span))]
    }

    /// Окружение команды: только системный PATH, дом, язык и пометка формата.
    /// Ключи и прокси Mostik команде не достаются; свои секреты она берёт сама (например, из связки ключей).
    public static func environment(from parent: [String: String]) -> [String: String] {
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "MOSTIK_CALENDAR_FORMAT": "1"]
        for key in ["HOME", "USER", "LOGNAME", "LANG", "TMPDIR"] { env[key] = parent[key] }
        return env
    }

    /// Разбор вывода. Битые события пропускаются, битый JSON — ошибка: прежний набор остаётся.
    public static func parse(_ data: Data) throws -> [CalendarEvent] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { throw ParseError.notJSON }
        let items: [Any]
        if let list = root as? [Any] {
            items = list
        } else if let object = root as? [String: Any], let list = object["events"] as? [Any] {
            items = list
        } else {
            throw ParseError.noEvents
        }
        guard items.count <= maxEvents else { throw ParseError.tooMany(items.count) }
        return items.compactMap { ($0 as? [String: Any]).flatMap(event) }
    }

    static func event(_ item: [String: Any]) -> CalendarEvent? {
        if item["all_day"] as? Bool == true { return nil }
        guard let start = date(item["start"]), let end = date(item["end"]), end >= start else { return nil }
        let title = text(item["title"]) ?? ""
        let attendees = people(item["attendees"])
        let others = item["others"] == nil ? nil : people(item["others"])
        let emails = people(item["emails"]).filter { $0.contains("@") }
        let id = text(item["id"]) ?? (title + "@" + String(Int(start.timeIntervalSince1970)))
        let link = text(item["link"]).flatMap { MeetingLinks.find(url: $0, location: nil, notes: nil) }
        let notes = (item["notes"] as? String).map { String($0.prefix(maxNotes)) } ?? ""
        return CalendarEvent(id: "ext:" + id, title: title, start: start, end: end, attendees: attendees,
                             others: others, notes: notes, link: link, emails: emails)
    }

    static func text(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(maxText))
    }

    static func people(_ value: Any?) -> [String] {
        var out: [String] = []
        for case let name? in ((value as? [Any]) ?? []).prefix(maxPeople).map(text) where !out.contains(name) {
            out.append(name)
        }
        return out
    }

    static func date(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        return iso.date(from: s) ?? isoFraction.date(from: s)
    }

    /// Слияние с календарём macOS: одна и та же встреча (название без регистра + минута начала)
    /// остаётся в версии `primary` — там участники уже размечены EventKit.
    public static func merge(_ primary: [CalendarEvent], _ secondary: [CalendarEvent]) -> [CalendarEvent] {
        func key(_ e: CalendarEvent) -> String {
            e.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() + "|" + String(Int(e.start.timeIntervalSince1970 / 60))
        }
        var seen = Set(primary.map(key))
        var out = primary
        for e in secondary where seen.insert(key(e)).inserted { out.append(e) }
        return out.sorted { $0.start < $1.start }
    }

    /// События из кеша в окне ±`days` от `now`, только встречи.
    public static func window(_ events: [CalendarEvent], around now: Date, days: Int) -> [CalendarEvent] {
        let span = TimeInterval(days) * 86_400
        let from = now.addingTimeInterval(-span), to = now.addingTimeInterval(span)
        return CalendarLogic.meetings(events.filter { $0.end >= from && $0.start <= to })
    }

    // MARK: файл команды

    public enum PathProblem: Equatable, Sendable {
        case notAbsolute, missing, notFile, notExecutable, foreignOwner, writableByOthers
    }

    /// Запускаем только свой исполняемый файл, который не может переписать другой пользователь.
    /// Ссылка раскрывается: проверяется файл, который действительно запустится, и его папка.
    public static func check(path: String, uid: UInt32 = getuid(), fileManager fm: FileManager = .default) -> PathProblem? {
        guard path.hasPrefix("/") else { return .notAbsolute }
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let attrs = try? fm.attributesOfItem(atPath: real) else { return .missing }
        guard attrs[.type] as? FileAttributeType == .typeRegular else { return .notFile }
        guard fm.isExecutableFile(atPath: real) else { return .notExecutable }
        let owner = (attrs[.ownerAccountID] as? NSNumber)?.uint32Value
        guard owner == uid || owner == 0 else { return .foreignOwner }
        if writableByOthers(attrs) { return .writableByOthers }
        let parent = (real as NSString).deletingLastPathComponent
        if let dir = try? fm.attributesOfItem(atPath: parent), writableByOthers(dir), !sticky(dir) { return .writableByOthers }
        return nil
    }

    static func writableByOthers(_ attrs: [FileAttributeKey: Any]) -> Bool {
        ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o022 != 0
    }

    static func sticky(_ attrs: [FileAttributeKey: Any]) -> Bool {
        ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o1000 != 0
    }

    public static func describe(_ problem: PathProblem) -> String {
        switch problem {
        case .notAbsolute: UIText.pick("нужен полный путь к файлу", "a full file path is required")
        case .missing: UIText.pick("файла нет", "the file is missing")
        case .notFile: UIText.pick("это не файл", "not a file")
        case .notExecutable: UIText.pick("файл не исполняемый (chmod +x)", "the file is not executable (chmod +x)")
        case .foreignOwner: UIText.pick("файл принадлежит другому пользователю", "the file belongs to another user")
        case .writableByOthers: UIText.pick("файл или папку могут менять другие пользователи", "other users can modify the file or its folder")
        }
    }

    // MARK: запуск

    public struct RunError: Error, Equatable { public let message: String }

    /// Запуск без shell, с урезанным окружением, потолком вывода и таймаутом. Блокирует поток — звать в фоне.
    /// Вывод читается асинхронно, а ждём с таймаутом: внук команды (`sleep` из скрипта) может держать
    /// канал открытым и после `terminate()`, и синхронное чтение повисло бы вместе с ним.
    public static func run(path: String, now: Date, timeout: TimeInterval = ExternalCalendar.timeout,
                           maxOutput: Int = ExternalCalendar.maxOutputBytes) -> Result<[CalendarEvent], RunError> {
        if let problem = check(path: path) {
            return .failure(RunError(message: describe(problem)))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments(around: now)
        process.environment = environment(from: ProcessInfo.processInfo.environment)
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        final class Sink: @unchecked Sendable {
            let lock = NSLock()
            var data = Data()
            var overflow = false
            let done = DispatchSemaphore(value: 0)
        }
        let sink = Sink()
        let reader = out.fileHandleForReading
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            let finished: Bool = sink.lock.withLock {
                if chunk.isEmpty { return true }
                sink.data.append(chunk)
                if sink.data.count > maxOutput { sink.overflow = true; return true }
                return false
            }
            if finished {
                handle.readabilityHandler = nil
                sink.done.signal()
            }
        }
        do { try process.run() } catch {
            reader.readabilityHandler = nil
            return .failure(RunError(message: UIText.pick("не запустилась: ", "failed to start: ") + error.localizedDescription))
        }
        let timedOut = sink.done.wait(timeout: .now() + timeout) == .timedOut
        reader.readabilityHandler = nil
        let (data, overflow) = sink.lock.withLock { (sink.data, sink.overflow) }
        if timedOut || overflow, process.isRunning {
            process.terminate()
            // Команда глушит SIGTERM — через секунду SIGKILL: висящий процесс не держит очередь календаря.
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < deadline { usleep(20_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        if overflow {
            return .failure(RunError(message: UIText.pick("вывод больше \(maxOutput / 1_000_000) МБ", "output exceeds \(maxOutput / 1_000_000) MB")))
        }
        if timedOut {
            return .failure(RunError(message: UIText.pick("не ответила за \(Int(timeout)) с", "no answer within \(Int(timeout)) s")))
        }
        guard process.terminationStatus == 0 else {
            return .failure(RunError(message: UIText.pick("код выхода ", "exit code ") + String(process.terminationStatus)))
        }
        do {
            return .success(try parse(data))
        } catch {
            return .failure(RunError(message: UIText.pick("вывод не в формате событий", "output is not in the events format")))
        }
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static let isoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// Путь к команде календаря нельзя подменить правкой `settings.json` (как хук встречи, П10 С3):
/// отпечаток пути, выбранного или подтверждённого в Mostik, лежит в связке ключей.
/// Не совпал — команда не запускается, Mostik показывает путь и спрашивает.
public enum CalendarCommandTrust {
    public static let keychainAccount = "calendar-command"

    public static func digest(_ path: String) -> String {
        SHA256.hash(data: Data(("calendar:" + path).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func isTrusted(_ path: String, store: HookDigestStore) -> Bool {
        if case .value(let stored) = store.read() { return stored == digest(path) }
        return false
    }

    /// Какой путь запускать: только подтверждённый. Неподтверждённый возвращается для вопроса.
    public static func reconcile(_ path: String?, store: HookDigestStore) -> (active: String?, ask: String?) {
        guard let path, !path.isEmpty else { return (nil, nil) }
        return isTrusted(path, store: store) ? (path, nil) : (nil, path)
    }

    /// Файл выбран в Mostik или подтверждён в окне — воля пользователя. false — отпечаток не записан.
    @discardableResult
    public static func approve(_ path: String, store: HookDigestStore) -> Bool {
        store.write(digest(path))
    }
}
