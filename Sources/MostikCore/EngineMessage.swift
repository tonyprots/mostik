import Foundation

/// Сомнение, которое движок не смог разрешить сам: что услышала основная
/// модель и какой вариант предлагает проверяющая или словарь.
public struct Doubt: Codable, Equatable, Sendable {
    public var heard: String
    public var suggestion: String
    public var context: String
    public var kind: String

    public init(heard: String, suggestion: String, context: String = "", kind: String = "term") {
        self.heard = heard
        self.suggestion = suggestion
        self.context = context
        self.kind = kind
    }
}

public struct Correction: Codable, Equatable, Sendable {
    public var from: String
    public var to: String
    public init(from: String, to: String) { self.from = from; self.to = to }
}

public struct Timings: Codable, Equatable, Sendable {
    public var audioS: Double
    public var tailMs: Double
    public var primaryMs: Double
    public var verifierMs: Double
    public var totalMs: Double
    /// Время полировщика; 0 — стадии не было.
    public var polishMs: Double = 0
    /// Раскладка хвоста (шаг 0, «Плавность и быстродействие»): очередь рабочего потока к stop,
    /// остаток, ожидание проверяющей, подготовка сессии и загрузка модели. nil — старый движок.
    public var queuedMs: Double?
    public var remainderMs: Double?
    public var verifierWaitMs: Double?
    public var prepareMs: Double?
    public var modelLoadMs: Double?

    enum CodingKeys: String, CodingKey {
        case audioS = "audio_s", tailMs = "tail_ms", primaryMs = "primary_ms"
        case verifierMs = "verifier_ms", totalMs = "total_ms", polishMs = "polish_ms"
        case queuedMs = "queued_ms", remainderMs = "remainder_ms", verifierWaitMs = "verifier_wait_ms"
        case prepareMs = "prepare_ms", modelLoadMs = "model_load_ms"
    }

    /// Для журнала: только числа (П10 — без текста).
    public var breakdown: String {
        let parts: [(String, Double?)] = [("tail", tailMs), ("queued", queuedMs), ("remainder", remainderMs),
                                          ("verifier_wait", verifierWaitMs), ("prepare", prepareMs),
                                          ("model_load", modelLoadMs), ("polish", polishMs > 0 ? polishMs : nil)]
        return parts.compactMap { name, value in value.map { "\(name) \(Int($0.rounded())) ms" } }.joined(separator: " · ")
    }

    public init(audioS: Double = 0, tailMs: Double = 0, primaryMs: Double = 0, verifierMs: Double = 0, totalMs: Double = 0) {
        self.audioS = audioS; self.tailMs = tailMs; self.primaryMs = primaryMs
        self.verifierMs = verifierMs; self.totalMs = totalMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        audioS = try c.decodeIfPresent(Double.self, forKey: .audioS) ?? 0
        tailMs = try c.decodeIfPresent(Double.self, forKey: .tailMs) ?? 0
        primaryMs = try c.decodeIfPresent(Double.self, forKey: .primaryMs) ?? 0
        verifierMs = try c.decodeIfPresent(Double.self, forKey: .verifierMs) ?? 0
        totalMs = try c.decodeIfPresent(Double.self, forKey: .totalMs) ?? 0
        polishMs = try c.decodeIfPresent(Double.self, forKey: .polishMs) ?? 0
        queuedMs = try c.decodeIfPresent(Double.self, forKey: .queuedMs)
        remainderMs = try c.decodeIfPresent(Double.self, forKey: .remainderMs)
        verifierWaitMs = try c.decodeIfPresent(Double.self, forKey: .verifierWaitMs)
        prepareMs = try c.decodeIfPresent(Double.self, forKey: .prepareMs)
        modelLoadMs = try c.decodeIfPresent(Double.self, forKey: .modelLoadMs)
    }
}

/// Итог одной диктовки — событие `final` протокола движка.
public struct DictationResult: Codable, Equatable, Sendable {
    public var session: String
    public var text: String
    public var rawText: String
    public var doubts: [Doubt]
    public var corrections: [Correction]
    public var language: String
    public var timings: Timings
    /// "done" | "late" | "off"
    public var verifier: String
    /// Текст прошёл полировщик (D3). При сбое полировки — false, а `text` равен тексту до неё.
    public var polished: Bool = false
    /// Текст после словаря, до полировки; nil — стадии не было.
    public var unpolishedText: String? = nil
    /// Итог стадии: done | unavailable | timeout | refused | bad_output | suspicious | failed; nil — не просили.
    public var polishStatus: String? = nil

    enum CodingKeys: String, CodingKey {
        case session, text, rawText = "raw_text", doubts, corrections, language, timings, verifier
        case polished, unpolishedText = "unpolished_text", polish
    }

    private struct PolishInfo: Codable { var status: String? }

    public init(session: String, text: String, rawText: String = "", doubts: [Doubt] = [],
                corrections: [Correction] = [], language: String = "ru",
                timings: Timings = Timings(), verifier: String = "done") {
        self.session = session; self.text = text; self.rawText = rawText; self.doubts = doubts
        self.corrections = corrections; self.language = language; self.timings = timings
        self.verifier = verifier
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        session = try c.decodeIfPresent(String.self, forKey: .session) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        rawText = try c.decodeIfPresent(String.self, forKey: .rawText) ?? ""
        doubts = try c.decodeIfPresent([Doubt].self, forKey: .doubts) ?? []
        corrections = try c.decodeIfPresent([Correction].self, forKey: .corrections) ?? []
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "ru"
        timings = try c.decodeIfPresent(Timings.self, forKey: .timings) ?? Timings()
        verifier = try c.decodeIfPresent(String.self, forKey: .verifier) ?? "off"
        polished = try c.decodeIfPresent(Bool.self, forKey: .polished) ?? false
        unpolishedText = try c.decodeIfPresent(String.self, forKey: .unpolishedText)
        polishStatus = (try? c.decodeIfPresent(PolishInfo.self, forKey: .polish))?.status
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(session, forKey: .session); try c.encode(text, forKey: .text)
        try c.encode(rawText, forKey: .rawText); try c.encode(doubts, forKey: .doubts)
        try c.encode(corrections, forKey: .corrections); try c.encode(language, forKey: .language)
        try c.encode(timings, forKey: .timings); try c.encode(verifier, forKey: .verifier)
        try c.encode(polished, forKey: .polished)
        try c.encodeIfPresent(unpolishedText, forKey: .unpolishedText)
        if let polishStatus { try c.encode(PolishInfo(status: polishStatus), forKey: .polish) }
    }
}

public struct MeetingDone: Codable, Equatable, Sendable {
    public var transcriptMd: String
    public var transcriptJson: String
    public var speakers: Int
    public var seconds: Double

    enum CodingKeys: String, CodingKey {
        case transcriptMd = "transcript_md", transcriptJson = "transcript_json", speakers, seconds
    }
}

/// Всё, что движок присылает в stdout.
public enum EngineEvent: Equatable, Sendable {
    /// Ответ на команду с `id`; `payload` — сырой JSON-объект ответа.
    case reply(id: Int, ok: Bool, payload: [String: JSONValue])
    case partial(session: String, text: String)
    case final(DictationResult)
    /// `detail` — короткое имя модели расшифровки встречи («Whisper»), иначе пусто.
    case progress(task: String, stage: String, done: Int, total: Int, detail: String = "")
    case meetingDone(MeetingDone)
    case error(id: Int?, session: String?, code: String, message: String)
}

/// Минимальное JSON-значение, чтобы не тащить Any через границы.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var doubleValue: Double? { if case .number(let n) = self { return n }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
}

public enum EngineCodec {
    /// Строка команды для stdin движка (без перевода строки).
    public static func command(_ name: String, id: Int, fields: [String: JSONValue] = [:]) -> String {
        var object = fields
        object["cmd"] = .string(name)
        object["id"] = .number(Double(id))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(JSONValue.object(object))) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// П6-А, P6: `polish_partial` приходит как `.partial` с сессией `polish:<id>`.
    public static let polishPartialPrefix = "polish:"

    /// Разбор одной строки stdout движка. Строки, которые не JSON, возвращают nil.
    public static func decode(line: String) -> EngineEvent? {
        guard let data = line.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let object) = value else { return nil }
        let id = object["id"]?.doubleValue.map { Int($0) }
        if let event = object["event"]?.stringValue {
            switch event {
            case "partial":
                return .partial(session: object["session"]?.stringValue ?? "", text: object["text"]?.stringValue ?? "")
            case "polish_partial":
                // П6-А, P6: кусок причёсывания по ходу; приставка отделяет его от черновика распознавания.
                return .partial(session: EngineCodec.polishPartialPrefix + (object["session"]?.stringValue ?? ""),
                                text: object["text"]?.stringValue ?? "")
            case "final":
                guard let result = try? JSONDecoder().decode(DictationResult.self, from: data) else { return nil }
                return .final(result)
            case "progress":
                return .progress(task: object["task"]?.stringValue ?? "",
                                 stage: object["stage"]?.stringValue ?? "",
                                 done: Int(object["done"]?.doubleValue ?? 0),
                                 total: Int(object["total"]?.doubleValue ?? 0),
                                 detail: object["model"]?.stringValue ?? "")
            case "models_progress":
                // Загрузка моделей по кнопке (П8, пункт 5): байты, задача `models:<key>`.
                return .progress(task: ModelProgress.taskPrefix + (object["key"]?.stringValue ?? ""),
                                 stage: object["file"]?.stringValue ?? "",
                                 done: Int(object["done"]?.doubleValue ?? 0),
                                 total: Int(object["total"]?.doubleValue ?? 0))
            case "meeting_done":
                guard let done = try? JSONDecoder().decode(MeetingDone.self, from: data) else { return nil }
                return .meetingDone(done)
            case "edit_done":
                // Итог голосовой правки (D5) — ответ на команду `edit` с тем же id.
                guard let id else { return nil }
                return .reply(id: id, ok: true, payload: object)
            case "meeting_ai_done":
                // ИИ встречи (M5–M7) — ответ на команду `meeting_ai` с тем же id.
                guard let id else { return nil }
                return .reply(id: id, ok: true, payload: object)
            case "error":
                return .error(id: id, session: object["session"]?.stringValue,
                              code: object["code"]?.stringValue ?? "internal",
                              message: object["message"]?.stringValue ?? "")
            default:
                return nil
            }
        }
        if let id {
            return .reply(id: id, ok: object["ok"]?.boolValue ?? false, payload: object)
        }
        return nil
    }
}

extension DictationResult {
    /// Текст для вставки (D2): обработанный; если обработка не дала текста — сырой.
    public var insertable: (text: String, raw: Bool) {
        let processed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !processed.isEmpty { return (processed, false) }
        let raw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw, !raw.isEmpty)
    }

    /// «Как сказано» для истории: nil, если движок его не прислал.
    public var rawTextForHistory: String? {
        let raw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    /// Обработка упала, а потоковый черновик есть — вставляем его как сырой текст, а не ничего.
    public static func rawFallback(session: String, partial: String, language: String) -> DictationResult? {
        let raw = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return DictationResult(session: session, text: "", rawText: raw, language: language, verifier: "off")
    }
}
