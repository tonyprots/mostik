import Foundation

public struct HistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var createdAt: Date
    public var text: String
    public var insertedText: String
    public var doubts: [Doubt]
    public var corrections: [Correction]
    public var language: String
    public var audioSeconds: Double
    public var latencyMs: Double
    public var appName: String
    public var agent: Bool
    public var audioPath: String?
    /// "inserted" | "clipboard" | "failed" | "secure_input" | "cancelled" (Esc, H2) | "undone" (откат, R4)
    /// | "command" (голосовая команда D6: текст стал черновиком события или письма, в поле не вставлялся)
    public var outcome: String
    public var verifier: String
    /// Отметка «агент понял не так» из старых версий: в интерфейсе её не ставят и не показывают,
    /// поле держит чтение прежних `history.jsonl`.
    public var agentMisread: Bool
    /// Как сказано: текст основной модели до словаря и сомнений (D2). Старые записи — nil.
    public var rawText: String? = nil
    /// Проверка вставки (R2): "confirmed" | "not_inserted" | "unknown"; nil — не проверялась.
    public var pasteCheck: String? = nil

    public init(id: String, createdAt: Date = Date(), text: String, insertedText: String = "", doubts: [Doubt] = [],
                corrections: [Correction] = [], language: String = "ru", audioSeconds: Double = 0,
                latencyMs: Double = 0, appName: String = "", agent: Bool = false, audioPath: String? = nil,
                outcome: String = "inserted", verifier: String = "done", agentMisread: Bool = false,
                rawText: String? = nil) {
        self.id = id; self.createdAt = createdAt; self.text = text; self.insertedText = insertedText
        self.doubts = doubts; self.corrections = corrections; self.language = language
        self.audioSeconds = audioSeconds; self.latencyMs = latencyMs; self.appName = appName
        self.agent = agent; self.audioPath = audioPath; self.outcome = outcome
        self.verifier = verifier; self.agentMisread = agentMisread; self.rawText = rawText
    }
}

/// История диктовок: один JSON на строку, новые в конце. Хранение
/// ограничено сроком; аудио удаляется вместе с записью.
public final class HistoryStore: @unchecked Sendable {
    public let fileURL: URL
    /// Папка звука диктовок: `prune` удаляет только внутри неё (П10, инфо). По умолчанию — папка истории.
    public let audioRoot: URL
    /// Папку звука передали явно (`recordings/` приложения): только тогда `prune` ищет в ней осиротевшие WAV.
    private let ownsAudioRoot: Bool
    private let lock = NSLock()
    private let fileManager: FileManager

    public init(fileURL: URL, audioRoot: URL? = nil, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.audioRoot = audioRoot ?? fileURL.deletingLastPathComponent()
        self.ownsAudioRoot = audioRoot != nil
        self.fileManager = fileManager
    }

    private func removeOrphanAudio(referenced: [String], olderThan age: TimeInterval, now: Date) {
        let known = Set(referenced.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path })
        for name in (try? fileManager.contentsOfDirectory(atPath: audioRoot.path)) ?? []
        where name.lowercased().hasSuffix(".wav") {
            let url = audioRoot.appendingPathComponent(name)
            // attributesOfItem не идёт по ссылкам: симлинк из папки звука наружу не удаляем и не читаем.
            guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  let modified = attrs[.modificationDate] as? Date, now.timeIntervalSince(modified) > age,
                  !known.contains(url.standardizedFileURL.resolvingSymlinksInPath().path) else { continue }
            removeAudio(url.path)
        }
    }

    /// Удалить звук записи, если путь внутри `audioRoot`: путь из подложенной истории файлов вне папки не тронет.
    private func removeAudio(_ path: String) {
        let root = audioRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let file = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        guard file.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { return }
        try? fileManager.removeItem(atPath: file)
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Все записи, новые первыми. Повреждённые строки пропускаются.
    public func load() -> [HistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        return loadUnlocked().reversed()
    }

    private func loadUnlocked() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = Self.decoder()
        var byID: [String: Int] = [:]
        var entries: [HistoryEntry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let entry = try? decoder.decode(HistoryEntry.self, from: Data(line)) else { continue }
            if let index = byID[entry.id] { entries[index] = entry } else {
                byID[entry.id] = entries.count
                entries.append(entry)
            }
        }
        return entries
    }

    public func append(_ entry: HistoryEntry) throws {
        lock.lock(); defer { lock.unlock() }
        // П10 р4 Р4-4л: отклонённая вставка в поле пароля — без текста и звука (`SecureDictation`).
        let original = entry
        let entry = SecureDictation.forHistory(entry)
        if entry.audioPath == nil, let path = original.audioPath, original.outcome == SecureDictation.outcome {
            removeAudio(path)
        }
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var line = try Self.encoder().encode(entry)
        line.append(UInt8(ascii: "\n"))
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: fileURL, options: .atomic)
        }
    }

    /// Дописать запись и вернуть то, что легло в файл (П10 р5 Р5-1л): это и кладут в память приложения.
    /// Запись `secure_input` и в файле, и в памяти — без текста, сомнений и звука; ошибка записи — молча, как раньше.
    @discardableResult
    public func record(_ entry: HistoryEntry) -> HistoryEntry {
        try? append(entry)
        return SecureDictation.forHistory(entry)
    }

    /// Обновление записи — дописываем новую версию; при чтении побеждает последняя.
    public func update(_ entry: HistoryEntry) throws { try append(entry) }

    /// Удаляет одну запись (все её версии) и её звук; переписывает файл компактно. false — такой нет.
    @discardableResult
    public func remove(id: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let entries = loadUnlocked()
        guard let gone = entries.first(where: { $0.id == id }) else { return false }
        if let path = gone.audioPath { removeAudio(path) }
        let encoder = Self.encoder()
        var data = Data()
        for entry in entries where entry.id != id {
            data.append(try encoder.encode(entry))
            data.append(UInt8(ascii: "\n"))
        }
        try data.write(to: fileURL, options: .atomic)
        return true
    }

    /// Убирает записи старше `retention` секунд и их аудио; переписывает файл компактно.
    /// `audioRetention`: у записей старше этого срока удаляется звук, текст остаётся (П10: 1 день).
    @discardableResult
    public func prune(retention: TimeInterval, audioRetention: TimeInterval? = nil, now: Date = Date()) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let entries = loadUnlocked()
        var keep = entries.filter { now.timeIntervalSince($0.createdAt) <= retention }
        let dropped = entries.filter { now.timeIntervalSince($0.createdAt) > retention }
        for entry in dropped {
            if let path = entry.audioPath { removeAudio(path) }
        }
        if let audioRetention {
            for index in keep.indices where now.timeIntervalSince(keep[index].createdAt) > audioRetention {
                guard let path = keep[index].audioPath else { continue }
                removeAudio(path)
                keep[index].audioPath = nil
            }
            // П10 р5 Р5-2л: WAV без записи в истории (упали между записью и историей, брошенная сессия)
            // живут не дольше звука диктовок. Свежие не трогаем: их может держать идущая запись.
            if ownsAudioRoot { removeOrphanAudio(referenced: keep.compactMap(\.audioPath), olderThan: audioRetention, now: now) }
        }
        let encoder = Self.encoder()
        var data = Data()
        for entry in keep {
            data.append(try encoder.encode(entry))
            data.append(UInt8(ascii: "\n"))
        }
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        return dropped.count
    }
}
