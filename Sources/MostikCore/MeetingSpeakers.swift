import Foundation

/// Говорящие встречи (M14, M15) из `transcript.json`: метки, имена, реплики на проверку, подсказки голосовой памяти.
/// Формат — `docs/voice-memory.md` и `docs/schemas/meeting-transcript.schema.json`.
public struct MeetingSpeakers: Equatable, Sendable {
    public static let me = "Я"
    /// Ниже — реплика на проверку (M15). Движок уже ставит `review`, порог здесь — для старых записей.
    public static let reviewBelow = 0.6

    /// Внешний говорящий (дорожка системы): исходная метка диаризации и видимое имя.
    /// Одно имя у нескольких меток — один человек (E2): `labels` — все его метки, `label` — первая.
    public struct Speaker: Equatable, Sendable, Identifiable {
        public var label: String
        public var name: String
        public var seconds: Double
        public var turns: Int
        public var labels: [String]
        public var id: String { label }
        public var isNamed: Bool { name != label }
        public init(label: String, name: String, seconds: Double, turns: Int, labels: [String]? = nil) {
            self.label = label; self.name = name; self.seconds = seconds; self.turns = turns
            self.labels = labels ?? [label]
        }
    }

    public struct Alternative: Equatable, Sendable {
        public var label: String
        public var name: String
        /// Доля окна реплики под этим голосом, 0…1.
        public var share: Double
        public init(label: String, name: String, share: Double) { self.label = label; self.name = name; self.share = share }
    }

    /// Реплика с неуверенной меткой.
    public struct Review: Equatable, Sendable, Identifiable {
        public var turn: Int
        public var label: String
        public var speaker: String
        public var start: Double
        public var confidence: Double
        public var alternatives: [Alternative]
        public var id: Int { turn }
        public init(turn: Int, label: String, speaker: String, start: Double, confidence: Double, alternatives: [Alternative]) {
            self.turn = turn; self.label = label; self.speaker = speaker; self.start = start
            self.confidence = confidence; self.alternatives = alternatives
        }
    }

    /// «Похоже на X» — подсказка голосовой памяти, ждёт «Это он» или «Не он».
    public struct Suggestion: Equatable, Sendable, Identifiable {
        public var label: String
        public var personID: String
        public var name: String
        public var score: Double
        public var id: String { label }
        public init(label: String, personID: String, name: String, score: Double) {
            self.label = label; self.personID = personID; self.name = name; self.score = score
        }
    }

    public var speakers: [Speaker]
    public var reviews: [Review]
    public var suggestions: [Suggestion]
    /// Голосовая память участвовала в расшифровке; `false` у `memoryAvailable` — не было модели.
    public var memoryUsed: Bool
    public var memoryAvailable: Bool

    public init(speakers: [Speaker] = [], reviews: [Review] = [], suggestions: [Suggestion] = [],
                memoryUsed: Bool = false, memoryAvailable: Bool = true) {
        self.speakers = speakers; self.reviews = reviews; self.suggestions = suggestions
        self.memoryUsed = memoryUsed; self.memoryAvailable = memoryAvailable
    }

    public func suggestion(for label: String) -> Suggestion? { suggestions.first { $0.label == label } }

    /// Говорящий по видимому имени строки расшифровки (E3); «Я» и перекрытия «А + Б» — nil.
    public func speaker(named name: String) -> Speaker? {
        guard name != Self.me, !name.contains(Self.separator) else { return nil }
        let key = Self.key(name)
        return speakers.first { Self.key($0.name) == key }
    }

    /// С кем можно объединить говорящего (E2): все остальные внешние говорящие.
    public func mergeTargets(for speaker: Speaker) -> [Speaker] { speakers.filter { $0.id != speaker.id } }

    public static let separator = " + "

    /// Сколько людей на встрече по видимым именам реплик: перекрытие «А + Б» — это А и Б,
    /// одно имя в разном регистре — один человек, пометки «📌» и пустые имена не считаются.
    public static func peopleCount<S: Sequence>(_ names: S) -> Int where S.Element == String {
        var seen: Set<String> = []
        for name in names where name != "📌" {
            for part in name.components(separatedBy: separator) {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { seen.insert(key(trimmed)) }
            }
        }
        return seen.count
    }

    /// Ключ сравнения имён — как у движка (`casefold`): регистр и лишние пробелы не важны.
    public static func key(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// Проверка для строки окна встречи: по началу и имени (id строк окна — не номера реплик).
    public func review(start: Double, speaker: String) -> Review? {
        reviews.first { abs($0.start - start) < 0.01 && $0.speaker == speaker }
    }

    public static func parse(_ data: Data) -> MeetingSpeakers {
        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return MeetingSpeakers() }
        func number(_ v: Any?) -> Double { (v as? Double) ?? (v as? NSNumber)?.doubleValue ?? 0 }
        let turns = dict["turns"] as? [[String: Any]] ?? []
        let names = dict["speaker_names"] as? [String: String] ?? [:]
        func display(_ label: String) -> String {
            label.components(separatedBy: " + ").map { names[$0] ?? $0 }.joined(separator: " + ")
        }

        var order: [String] = []
        var seconds: [String: Double] = [:]
        var counts: [String: Int] = [:]
        var reviews: [Review] = []
        for (index, turn) in turns.enumerated() {
            let speaker = turn["speaker"] as? String ?? ""
            let source = turn["source"] as? String ?? (speaker == me ? "mic" : "system")
            guard source == "system", speaker != me else { continue }
            let label = turn["label"] as? String ?? speaker
            let start = number(turn["start"])
            let length = max(0, number(turn["end"]) - start)
            // Перекрытие «A + B» не отдельный человек: учитываем каждую часть.
            for part in label.components(separatedBy: " + ") {
                if !order.contains(part) { order.append(part) }
                seconds[part, default: 0] += length
                counts[part, default: 0] += 1
            }
            let reviewed = turn["reviewed"] as? Bool ?? false
            guard !reviewed, let confidence = (turn["speaker_confidence"] as? NSNumber)?.doubleValue else { continue }
            let flagged = turn["review"] as? Bool ?? (confidence < reviewBelow)
            guard flagged else { continue }
            // Альтернатива под тем же именем — тот же человек (E2), её не предлагаем.
            let alternatives = (turn["speaker_alternatives"] as? [[String: Any]] ?? []).compactMap { item -> Alternative? in
                guard let alt = item["label"] as? String, alt != label, key(display(alt)) != key(display(label)) else { return nil }
                return Alternative(label: alt, name: display(alt), share: number(item["share"]))
            }
            reviews.append(Review(turn: (turn["id"] as? Int) ?? index, label: label, speaker: speaker,
                                  start: start, confidence: confidence, alternatives: alternatives))
        }
        // Одно имя — один человек (E2): метки с одинаковым именем складываются в одну строку.
        var speakers: [Speaker] = []
        for label in order {
            let name = names[label] ?? label
            if let i = speakers.firstIndex(where: { key($0.name) == key(name) }) {
                speakers[i].labels.append(label)
                speakers[i].seconds += seconds[label] ?? 0
                speakers[i].turns += counts[label] ?? 0
            } else {
                speakers.append(Speaker(label: label, name: name, seconds: seconds[label] ?? 0, turns: counts[label] ?? 0))
            }
        }

        let voices = dict["voices"] as? [String: Any]
        let suggestions = (voices?["suggestions"] as? [[String: Any]] ?? []).compactMap { item -> Suggestion? in
            guard let label = item["label"] as? String, let id = item["person_id"] as? String,
                  let name = item["name"] as? String, order.contains(label) else { return nil }
            return Suggestion(label: label, personID: id, name: name, score: number(item["score"]))
        }
        return MeetingSpeakers(speakers: speakers, reviews: reviews, suggestions: suggestions,
                               memoryUsed: voices?["enabled"] as? Bool ?? false,
                               memoryAvailable: voices?["available"] as? Bool ?? true)
    }
}

/// Человек голосовой памяти (M14) — без векторов: они остаются в движке.
public struct VoicePerson: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var samples: Int
    public var seconds: Double
    public init(id: String, name: String, samples: Int, seconds: Double) {
        self.id = id; self.name = name; self.samples = samples; self.seconds = seconds
    }
}

/// Состояние голосовой памяти для Настроек: есть ли модель и кого помним.
public struct VoiceMemoryStatus: Equatable, Sendable {
    public var available: Bool
    public var detail: String
    public var model: String
    public var people: [VoicePerson]
    public init(available: Bool = false, detail: String = "", model: String = "", people: [VoicePerson] = []) {
        self.available = available; self.detail = detail; self.model = model; self.people = people
    }

    /// Ответ движка `voices_status` / `voices_forget` / `voices_rename` (поля `available`, `people`).
    public static func parse(_ reply: [String: JSONValue], previous: VoiceMemoryStatus = VoiceMemoryStatus()) -> VoiceMemoryStatus {
        var status = previous
        if let available = reply["available"]?.boolValue { status.available = available }
        if let detail = reply["detail"]?.stringValue { status.detail = detail }
        if let model = reply["model"]?.stringValue { status.model = model }
        if case let .array(items)? = reply["people"] {
            status.people = items.compactMap { item in
                guard case let .object(o) = item, let id = o["id"]?.stringValue, let name = o["name"]?.stringValue else { return nil }
                return VoicePerson(id: id, name: name, samples: Int(o["samples"]?.doubleValue ?? 0),
                                   seconds: o["seconds"]?.doubleValue ?? 0)
            }
        }
        return status
    }
}

/// П10 С8: выключение голосовой памяти — вопрос «Стереть отпечатки?», по умолчанию «да».
/// Стирает движок командой `voices_wipe`: люди, образцы, нерешённые векторы встреч, подсказки.
public enum VoiceMemoryWipe {
    public static let command = "voices_wipe"
    public static let wipeByDefault = true

    /// Спросить, когда память выключают.
    public static func asks(old: Bool, new: Bool) -> Bool { old && !new }

    /// Движок до П10 не знает `voices_wipe` — тогда «Забыть всех» (`voices_forget all`).
    public static func needsFallback(code: String, message: String) -> Bool {
        code == "internal" && message.contains(command)
    }
}
