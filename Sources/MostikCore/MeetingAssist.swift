import Foundation

// П7: вопросы по ходу встречи (M19), подсказки (M9), кадры окна звонка (W26).
// Решения — здесь, платформа — `MostikKit/MeetingFrameCapture.swift`, связка — `Mostik/MeetingAssistController.swift`.

/// Настройки П7. Согласия на кадры здесь НЕТ: оно даётся на каждую встречу и не запоминается.
public struct MeetingAssistSettings: Codable, Equatable, Sendable {
    /// M19: искать вопросы в живой расшифровке и вести `questions.json`. Локально, модель — только уже загруженная.
    public var questions: Bool = true
    /// M9: карточка-подсказка на вопрос собеседников. Выключено по умолчанию.
    public var hints: Bool = false
    /// W26: раз в сколько секунд смотреть на окно звонка (снимается только при заметной смене кадра).
    public var frameInterval: Int = MeetingAssistSettings.defaultFrameInterval
    /// W26: снимать слайды звонка в каждой встрече. Выключено по умолчанию; в самой встрече можно выключить.
    public var slides: Bool = false

    public static let defaultFrameInterval = 10
    public static let frameIntervals = [5, 10, 20, 30]

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = MeetingAssistSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        questions = try c.decodeIfPresent(Bool.self, forKey: .questions) ?? d.questions
        hints = try c.decodeIfPresent(Bool.self, forKey: .hints) ?? d.hints
        slides = try c.decodeIfPresent(Bool.self, forKey: .slides) ?? d.slides
        let interval = try c.decodeIfPresent(Int.self, forKey: .frameInterval) ?? d.frameInterval
        frameInterval = Self.frameIntervals.contains(interval) ? interval : d.frameInterval
    }
}

// MARK: - M19: вопрос из журнала

public struct MeetingQuestion: Equatable, Sendable, Identifiable {
    public enum Status: String, Sendable { case pending, answered, unanswered }

    public var id: String
    public var at: Double
    public var track: String
    public var speaker: String?
    public var text: String
    public var status: Status
    /// `heuristic` или `judge` — какой слой решил, что это вопрос.
    public var layer: String
    public var answer: String?
    public var answeredBy: String?

    public init(id: String, at: Double, track: String, speaker: String? = nil, text: String,
                status: Status = .pending, layer: String = "heuristic", answer: String? = nil, answeredBy: String? = nil) {
        self.id = id; self.at = at; self.track = track; self.speaker = speaker; self.text = text
        self.status = status; self.layer = layer; self.answer = answer; self.answeredBy = answeredBy
    }

    public init?(_ value: JSONValue) {
        guard case .object(let o) = value, let id = o["id"]?.stringValue, let text = o["text"]?.stringValue else { return nil }
        self.init(id: id, at: o["at"]?.doubleValue ?? 0, track: o["track"]?.stringValue ?? "system",
                  speaker: o["speaker"]?.stringValue, text: text,
                  status: Status(rawValue: o["status"]?.stringValue ?? "") ?? .pending,
                  layer: o["layer"]?.stringValue ?? "heuristic", answer: o["answer"]?.stringValue,
                  answeredBy: o["answered_by"]?.stringValue)
    }

    public static func list(_ value: JSONValue?) -> [MeetingQuestion] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap(MeetingQuestion.init)
    }

    /// Для показа: сначала открытые — без ответа и ещё не разобранные, потом отвеченные;
    /// внутри каждой группы — по времени.
    public static func openFirst(_ items: [MeetingQuestion]) -> [MeetingQuestion] {
        items.filter { $0.status != .answered } + items.filter { $0.status == .answered }
    }

    /// Новые и обновлённые из ответа движка — в список по `id`, порядок по времени.
    public static func merge(_ current: [MeetingQuestion], _ incoming: [MeetingQuestion]) -> [MeetingQuestion] {
        var result = current
        for item in incoming {
            if let index = result.firstIndex(where: { $0.id == item.id }) { result[index] = item } else { result.append(item) }
        }
        return result.sorted { $0.at < $1.at }
    }

    /// Журнал из файла `questions.json` папки встречи.
    public static func load(folder: URL) -> [MeetingQuestion] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let o) = value else { return [] }
        return list(o["items"])
    }

    public static let fileName = "questions.json"
}

// MARK: - M9: подсказка

public struct MeetingHint: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case meeting, source, glossary }

    public var id: String
    public var question: String
    /// Ответ словами — только от локальной модели; иначе nil и карточка показывает фрагмент.
    public var answer: String?
    public var snippet: String?
    public var kind: Kind
    public var title: String
    public var path: String?
    public var line: Int?
    public var meeting: String?
    public var at: Double?
    public var turn: Int?
    /// Ещё 0–2 источника и термин словаря — строкой «откуда ещё».
    public var more: [String]

    public init(id: String, question: String, answer: String? = nil, snippet: String? = nil, kind: Kind, title: String,
                path: String? = nil, line: Int? = nil, meeting: String? = nil, at: Double? = nil, turn: Int? = nil,
                more: [String] = []) {
        self.id = id; self.question = question; self.answer = answer; self.snippet = snippet; self.kind = kind
        self.title = title; self.path = path; self.line = line; self.meeting = meeting; self.at = at; self.turn = turn
        self.more = more
    }

    /// Ответ `meeting_hint`; nil — ничего не нашлось.
    public init?(id: String, payload: [String: JSONValue]) {
        guard payload["status"]?.stringValue == "found" else { return nil }
        let question = payload["question"]?.stringValue ?? ""
        var more: [String] = []
        if case .array(let items)? = payload["more"] {
            for case .object(let o) in items { if let title = o["title"]?.stringValue { more.append(title) } }
        }
        var glossary: [[String: JSONValue]] = []
        if case .array(let items)? = payload["glossary"] {
            for case .object(let o) in items { glossary.append(o) }
        }
        if case .object(let source)? = payload["source"] {
            let kind: Kind = source["kind"]?.stringValue == "meeting" ? .meeting : .source
            self.init(id: id, question: question, answer: payload["answer"]?.stringValue,
                      snippet: payload["snippet"]?.stringValue ?? source["snippet"]?.stringValue,
                      kind: kind, title: source["title"]?.stringValue ?? "",
                      path: source["path"]?.stringValue, line: source["line"]?.doubleValue.map { Int($0) },
                      meeting: source["meeting"]?.stringValue, at: source["at"]?.doubleValue,
                      turn: source["turn"]?.doubleValue.map { Int($0) },
                      more: more + glossary.compactMap { Self.glossaryLabel($0) })
        } else if let first = glossary.first, let term = first["term"]?.stringValue {
            self.init(id: id, question: question, kind: .glossary, title: term, path: first["path"]?.stringValue,
                      line: first["line"]?.doubleValue.map { Int($0) },
                      more: glossary.dropFirst().compactMap { Self.glossaryLabel($0) })
        } else {
            return nil
        }
    }

    private static func glossaryLabel(_ o: [String: JSONValue]) -> String? {
        guard let term = o["term"]?.stringValue else { return nil }
        let file = (o["path"]?.stringValue).map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        let line = o["line"]?.doubleValue.map { ":\(Int($0))" } ?? ""
        return file.isEmpty ? term : "\(term) — \(file)\(line)"
    }

    /// Подпись ссылки: «licenses.md:3», «Встреча «Синк» · 12:34», термин — «README.md:3».
    public var sourceLabel: String {
        switch kind {
        case .meeting:
            return at.map { "\(title) · \(LiveTranscript.clock($0))" } ?? title
        case .source, .glossary:
            let file = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? title
            return line.map { "\(file):\($0)" } ?? file
        }
    }
}

/// Карточки не мешают (M9): не чаще одной за `interval` секунд; закрытая не возвращается.
public struct HintThrottle: Equatable, Sendable {
    public static let interval: Double = 20
    public private(set) var lastShown: Double?
    public init() {}

    public func allows(at now: Double) -> Bool {
        guard let lastShown else { return true }
        return now - lastShown >= Self.interval
    }

    public mutating func shown(at now: Double) { lastShown = now }
}

/// На какие вопросы искать подсказку: только встреча (не диктовка), включено в настройках,
/// вопрос собеседников — свой вопрос подсказка не нужна.
public enum HintPolicy {
    public static func wants(_ question: MeetingQuestion, settings: MeetingAssistSettings, recording: Bool) -> Bool {
        recording && settings.hints && question.track == "system"
    }
}

// MARK: - W26: кадры окна звонка

/// Можно ли снять кадр сейчас. Порядок проверок — от самого строгого запрета.
public enum FrameDecision: Equatable, Sendable {
    case capture
    /// Согласия на эту встречу нет — переключатель выключен (по умолчанию).
    case noConsent
    case textOnly
    /// Нет разрешения «Запись экрана»: запрос — только по кнопке или переключателю пользователя.
    case noPermission

    /// Встреча «только на этом Mac» кадрам не мешает: они, как и расшифровка, остаются здесь.
    public static func decide(consent: Bool, textOnly: Bool, permission: Bool) -> FrameDecision {
        if !consent { return .noConsent }
        if textOnly { return .textOnly }
        if !permission { return .noPermission }
        return .capture
    }
}

/// Заметная смена кадра по уменьшенной копии в оттенках серого (64×36).
///
/// Кадр сохраняется, если он (1) заметно отличается от последнего сохранённого и (2) устоялся —
/// почти не изменился с прошлого взгляда. Второе отсекает видео лиц: оно меняется на каждом
/// взгляде, а слайд стоит. Маленькое окошко видео рядом со слайдом укладывается в допуск.
public struct FrameDelta: Equatable, Sendable {
    /// Ячейка «изменилась», если яркость сдвинулась больше чем на столько из 255.
    public static let cellThreshold = 24
    /// Доля изменившихся ячеек, начиная с которой кадр — новый (смена слайда).
    public static let changed = 0.15
    /// Доля, до которой кадр считается устоявшимся.
    public static let stable = 0.10
    /// Больше кадров за встречу не снимаем.
    public static let maxFrames = 300

    public private(set) var saved: [UInt8]?
    public private(set) var previous: [UInt8]?
    public private(set) var count = 0

    public init() {}

    /// Доля ячеек, где яркость разошлась сильнее порога. Разные размеры — «всё другое».
    public static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var changed = 0
        for i in 0..<a.count where abs(Int(a[i]) - Int(b[i])) > cellThreshold { changed += 1 }
        return Double(changed) / Double(a.count)
    }

    /// Очередной взгляд на окно; true — этот кадр сохранить.
    public mutating func observe(_ thumbnail: [UInt8]) -> Bool {
        defer { previous = thumbnail }
        guard count < Self.maxFrames else { return false }
        let steady = previous.map { Self.difference($0, thumbnail) <= Self.stable } ?? false
        let fresh = saved.map { Self.difference($0, thumbnail) >= Self.changed } ?? true
        guard steady && fresh else { return false }
        saved = thumbnail
        count += 1
        return true
    }

    /// Имя файла кадра — время от начала встречи: `001235.jpg` = 00:12:35.
    public static func fileName(at seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d%02d%02d.jpg", total / 3600, (total % 3600) / 60, total % 60)
    }

    public static let folderName = "frames"
}

/// Запись кадра на диск: картинка и рядом её текст. Пометка «только на этом Mac» кадр не трогает —
/// облаку и агентам его текст не отдаёт движок, по пути в папке встречи (`privacy.drop_sensitive`).
public enum FrameStore {
    /// Текст кадра рядом с ним: `<кадр>.ocr.txt`.
    public static func sidecar(for image: URL) -> URL {
        image.deletingLastPathComponent().appendingPathComponent(image.lastPathComponent + ".ocr.txt")
    }

    /// true — кадр записан (текст рядом — если распознался).
    @discardableResult
    public static func save(to url: URL, write: (URL) -> Bool, ocr: (URL) -> String) -> Bool {
        guard write(url) else { return false }
        try? ocr(url).write(to: sidecar(for: url), atomically: true, encoding: .utf8)
        return true
    }
}

/// Папки для индекса подсказок встречи (M9): источники словаря и проект, выбранный вручную. Проект,
/// найденный по активному окну, не берём: он меняется с каждой диктовкой, и индекс перестраивался бы впустую.
public enum HintSources {
    public static func roots(settings: MostikSettings) -> [String] {
        var roots = settings.extraSources
        if let project = settings.codeProjectPath, !project.isEmpty, !roots.contains(project) {
            roots.append(project)
        }
        return roots
    }
}
