import Foundation

// MARK: - Журнал и отчёты о сбоях (П8, пункт 6)

/// Где лежат журнал и отчёты: `~/Library/Logs/Mostik/` — там их ищет Console.app.
/// `MOSTIK_LOG_DIR` подменяет корень только в debug-сборке (тесты, второй экземпляр для замеров).
/// П10 хвост р5 Ф-2: в выпуске переменная не читается — сюда же пишется вывод команды после встречи,
/// а `StorageHygiene.secure` закрывает папку журнала (0700), какой бы она ни была.
///
/// Приватность: в журнал идут только события и ошибки — запуск, статус движка, длительность
/// записи, число символов, способ вставки. Текст диктовок, встреч, заголовки окон и
/// содержимое буфера туда не пишутся. Отчёты о сбоях лежат только на этом Mac.
public struct MostikLogPaths: Equatable, Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static var standard: MostikLogPaths {
        resolve(environment: ProcessInfo.processInfo.environment, debug: DebugOverrides.isDebugBuild)
    }

    public static func resolve(environment: [String: String], debug: Bool) -> MostikLogPaths {
        if debug, let custom = environment["MOSTIK_LOG_DIR"], !custom.isEmpty {
            return MostikLogPaths(root: URL(fileURLWithPath: custom, isDirectory: true))
        }
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
        return MostikLogPaths(root: library.appendingPathComponent("Logs/Mostik", isDirectory: true))
    }

    public var app: URL { root.appendingPathComponent("app.log") }
    public var engine: URL { root.appendingPathComponent("engine.log") }
    public var crashes: URL { root.appendingPathComponent("crashes", isDirectory: true) }
    /// Вывод команды после встречи (П10 р5 Р5-3л): до 16 000 знаков на запуск, поэтому с ротацией и рядом с app.log.
    public var meetingHooks: URL { root.appendingPathComponent("meeting-hooks.log") }
}

/// Журнал команды после встречи: дописать запись с ротацией по размеру, файл — только владельцу (0600).
/// `legacy` — старое место (`Application Support/Mostik/logs/meeting-hooks.log`): переносится один раз.
public enum MeetingHookLog {
    public static let rotation = LogRotation(maxBytes: 1_000_000, keep: 3)

    public static func append(_ entry: String, to url: URL, rotation: LogRotation = rotation, legacy: URL? = nil) {
        let fm = FileManager.default
        StorageHygiene.secure([url.deletingLastPathComponent()])
        if let legacy, fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: url.path) {
            try? fm.moveItem(at: legacy, to: url)
        }
        let data = Data(entry.utf8)
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if rotation.shouldRotate(size: size, incoming: data.count) { rotation.rotate(url) }
        StorageHygiene.ensurePrivateFile(url)
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

/// Ротация по размеру: `app.log` → `app.log.1` → … → `app.log.<keep-1>`, старший уходит.
public struct LogRotation: Equatable, Sendable {
    public var maxBytes: Int
    /// Сколько файлов всего, вместе с текущим.
    public var keep: Int

    public init(maxBytes: Int = 1_000_000, keep: Int = 5) {
        self.maxBytes = max(1, maxBytes)
        self.keep = max(1, keep)
    }

    /// Перед записью `incoming` байт в файл размера `size` — пора ротировать?
    public func shouldRotate(size: Int, incoming: Int) -> Bool {
        size > 0 && size + incoming > maxBytes
    }

    /// Переименования по порядку (старшие первыми), чтобы ничего не затереть.
    /// Сдвинуть файлы по плану: ошибки молча пропускаются — журнал не важнее работы.
    public func rotate(_ file: URL) {
        let fm = FileManager.default
        let plan = plan(for: file)
        if let drop = plan.drop { try? fm.removeItem(at: drop) }
        for move in plan.moves where fm.fileExists(atPath: move.from.path) {
            try? fm.removeItem(at: move.to)
            try? fm.moveItem(at: move.from, to: move.to)
        }
    }

    /// Последний элемент пути `drop` — удалить до переименований.
    public func plan(for file: URL) -> (drop: URL?, moves: [(from: URL, to: URL)]) {
        guard keep > 1 else { return (file, []) }
        func numbered(_ n: Int) -> URL { file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".\(n)") }
        var moves: [(URL, URL)] = []
        for n in stride(from: keep - 2, through: 1, by: -1) { moves.append((numbered(n), numbered(n + 1))) }
        moves.append((file, numbered(1)))
        return (numbered(keep - 1), moves)
    }
}

/// Строка журнала: время, категория, событие. Одна строка — одно событие: переводы
/// строк схлопываются, длинное обрезается — в журнал не уедет простыня текста.
public enum LogLine {
    public static let maxMessage = 400

    public static func format(_ date: Date, category: String, message: String, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = timeZone
        return "\(formatter.string(from: date)) [\(clean(category, limit: 24))] \(clean(redact(message), limit: maxMessage))\n"
    }

    /// П10: строки в кавычках → «…», как `crash_report.redact` движка. Сообщения ошибок движка
    /// (`error` в ответе) приходят сырыми, и в них бывает текст диктовки или встречи.
    public static func redact(_ text: String) -> String {
        text.replacingOccurrences(of: #"'[^'\n]*'|"[^"\n]*"|«[^»\n]*»"#, with: "«…»", options: .regularExpression)
    }

    public static func clean(_ text: String, limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\r\n", with: " ")
            .components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit)) + "…"
    }
}

/// Отчёты о сбоях: имя файла и сколько хранить.
public enum CrashReportPolicy {
    /// Храним последние столько отчётов, старшие удаляются при запуске.
    public static let keep = 20

    /// `app-2026-10-11-180501-pid1234.txt`, `engine-…` — сортируются по времени.
    public static func fileName(kind: String, date: Date, pid: Int32, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "\(kind)-\(formatter.string(from: date))-pid\(pid).txt"
    }

    /// Какие отчёты удалить: всё сверх `keep` самых свежих (по времени в имени, затем по имени).
    public static func excess(_ names: [String], keep: Int = keep) -> [String] {
        let reports = names.filter { $0.hasSuffix(".txt") && ($0.hasPrefix("app-") || $0.hasPrefix("engine-")) }
        guard reports.count > keep else { return [] }
        let sorted = reports.sorted { stamp($0) != stamp($1) ? stamp($0) > stamp($1) : $0 > $1 }
        return Array(sorted.dropFirst(keep))
    }

    /// Свежие отчёты для «Проверки»: созданные после `since`.
    public static func recent(_ names: [String], since: Date, timeZone: TimeZone = .current) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return names.filter { name in
            guard let date = formatter.date(from: stamp(name)) else { return false }
            return date >= since
        }.sorted()
    }

    /// `yyyy-MM-dd-HHmmss` из имени без вида и pid.
    static func stamp(_ name: String) -> String {
        guard let dash = name.firstIndex(of: "-") else { return "" }
        let rest = name[name.index(after: dash)...]
        return String(rest.prefix(17))
    }

    /// Текст отчёта о необработанном исключении: что упало, где — без данных пользователя.
    public static func exceptionReport(name: String, reason: String, stack: [String], version: String,
                                       system: String, date: Date) -> String {
        var lines = ["Mostik — отчёт о сбое / crash report",
                     "Только на этом Mac, никуда не отправляется. / Stays on this Mac, never sent.",
                     "", "version: \(version)", "system: \(system)",
                     "date: \(LogLine.format(date, category: "crash", message: "").split(separator: " ").first ?? "")",
                     "kind: uncaught exception", "exception: \(name)",
                     "reason: \(LogLine.clean(reason, limit: 300))", "", "stack:"]
        lines += stack.map { "  " + $0 }
        return lines.joined(separator: "\n") + "\n"
    }
}
