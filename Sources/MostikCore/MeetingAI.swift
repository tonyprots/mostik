import Foundation

// ИИ встреч после расшифровки (M5–M7): чистая логика без интерфейса и движка.
// Договор с движком — docs/polish-contract.md, раздел «ИИ встреч».

/// Режим заметок и сводки: «Подробно» и «Кратко».
public enum MeetingAIMode: String, Codable, CaseIterable, Sendable {
    case detailed, brief
}

/// Пункт сводки со ссылками на реплики (`refs` — номера в `transcript.json.turns`).
public struct MeetingAIPoint: Equatable, Sendable {
    public var text: String
    public var refs: [Int]
    /// Заголовок раздела (M17): настоящая тема или метка говорящего.
    public var section: String?
    /// Пункт только из своих записей или картинок пользователя (W23) — без ссылок на реплики.
    public var fromNotes: Bool
    /// Пункт «РЕШИЛИ» протокола начинается с глагола в неопределённой форме (W8).
    public var formOK: Bool
    public init(text: String, refs: [Int], section: String? = nil, fromNotes: Bool = false, formOK: Bool = true) {
        self.text = text; self.refs = refs; self.section = section; self.fromNotes = fromNotes; self.formOK = formOK
    }
}

/// Раздел сводки (M17): заголовок и номера пунктов в `points`.
public struct MeetingAISummarySection: Equatable, Sendable {
    public var title: String
    public var points: [Int]
    public init(title: String, points: [Int]) { self.title = title; self.points = points }
}

/// Вопрос протокола (W8): СЛУШАЛИ и РЕШИЛИ.
public struct MeetingAIAgendaItem: Equatable, Sendable {
    public var question: String
    public var heard: [MeetingAIPoint]
    public var decided: [MeetingAIPoint]
    public init(question: String, heard: [MeetingAIPoint], decided: [MeetingAIPoint]) {
        self.question = question; self.heard = heard; self.decided = decided
    }
}

/// Свой вход сводки (W23): сколько пользовательских записей и картинок ушло модели.
public struct MeetingAIInputs: Equatable, Sendable {
    public var used: Bool
    public var agenda: Int
    public var notesChars: Int
    public var images: Int
    public init(used: Bool = true, agenda: Int = 0, notesChars: Int = 0, images: Int = 0) {
        self.used = used; self.agenda = agenda; self.notesChars = notesChars; self.images = images
    }
}

/// Заметка по пометке (M5): пометка пользователя и её полная версия по расшифровке.
public struct MeetingAINote: Equatable, Sendable {
    public var markIndex: Int
    public var at: Double
    /// Текст пометки на момент обработки — по нему видно, что пометку потом поправили.
    public var mark: String
    public var text: String
    public var refs: [Int]
    /// Пометка уже была полной — её не переписывали.
    public var kept: Bool
    /// Модель не дополнила пометку — показана сама пометка со ссылкой на место.
    public var fallback: Bool

    public init(markIndex: Int, at: Double, mark: String, text: String, refs: [Int], kept: Bool = false, fallback: Bool = false) {
        self.markIndex = markIndex; self.at = at; self.mark = mark; self.text = text; self.refs = refs
        self.kept = kept; self.fallback = fallback
    }
}

/// Задача (M7): люди — только метки говорящих, «группа» или никто.
public struct MeetingAITask: Equatable, Sendable {
    public enum Assignee: Equatable, Sendable {
        case speaker(String), group, none
    }
    public var text: String
    public var owner: String?
    public var assignee: Assignee
    public var due: String?
    public var refs: [Int]
    /// Протокол (W8): у поручения нет одного ответственного или срока — показать, не выдумывать.
    public var needsOwner: Bool
    public var needsDue: Bool
    /// Отмечена сделанной в окне встречи (`done` в `notes.json`; пересборка сводки отметки не хранит).
    public var done: Bool

    public init(text: String, owner: String?, assignee: Assignee, due: String?, refs: [Int],
                needsOwner: Bool = false, needsDue: Bool = false, done: Bool = false) {
        self.text = text; self.owner = owner; self.assignee = assignee; self.due = due; self.refs = refs
        self.needsOwner = needsOwner; self.needsDue = needsDue; self.done = done
    }
}

/// Где лежат задачи в `notes.json`: основная сводка режима или дополнительный вид (W22).
public enum MeetingAITaskPlace: Equatable, Sendable {
    case mode(MeetingAIMode)
    case variant(String)
}

/// Правка задачи из окна встречи: сделано, новый текст, удалить. Пишется прямо в `notes.json`.
public enum MeetingAITaskEdit: Equatable, Sendable {
    case done(Bool)
    case text(String)
    case delete

    /// Новый `notes.json` с правкой или nil, если задачи по этому номеру нет. Номер — как в разборе:
    /// задачи с пустым текстом не считаются (`MeetingAIFile.parse` их выбрасывает).
    public func applied(to data: Data, place: MeetingAITaskPlace, index: Int) -> Data? {
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let (group, key): (String, String) = switch place {
        case let .mode(mode): ("modes", mode.rawValue)
        case let .variant(name): ("variants", name)
        }
        guard var container = root[group] as? [String: Any], var result = container[key] as? [String: Any],
              var tasks = result["tasks"] as? [[String: Any]] else { return nil }
        let visible = tasks.indices.filter {
            !((tasks[$0]["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard visible.indices.contains(index) else { return nil }
        let raw = visible[index]
        switch self {
        case let .done(value): tasks[raw]["done"] = value
        case let .text(value):
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            tasks[raw]["text"] = text
        case .delete: tasks.remove(at: raw)
        }
        result["tasks"] = tasks
        container[key] = result
        root[group] = container
        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}

/// Итог одного режима из `notes.json`.
public struct MeetingAIResult: Equatable, Sendable {
    public enum Status: String, Sendable { case done, partial, failed }
    public var mode: MeetingAIMode
    public var status: Status
    public var error: String?
    public var overview: String
    public var points: [MeetingAIPoint]
    public var notes: [MeetingAINote]
    public var tasks: [MeetingAITask]
    public var backend: String
    public var model: String?
    public var seconds: Double
    public var calls: Int
    public var chunks: Int
    public var coverage: Double
    /// Тема встречи из сводки (W21) и шаблон (M16): id, имя, раскладка `topics | people | protocol`.
    public var topic: String = ""
    public var template: String = "general"
    public var templateName: String = ""
    public var layout: String = "topics"
    public var sections: [MeetingAISummarySection] = []
    public var decisions: [MeetingAIPoint] = []
    public var agenda: [MeetingAIAgendaItem] = []
    public var inputs: MeetingAIInputs? = nil
    /// Вид сводки (W22): название («Для руководителя») и описание словами у своей.
    public var title: String? = nil
    public var instruction: String? = nil

    public init(mode: MeetingAIMode, status: Status, error: String? = nil, overview: String = "",
                points: [MeetingAIPoint] = [], notes: [MeetingAINote] = [], tasks: [MeetingAITask] = [],
                backend: String = "claude", model: String? = nil, seconds: Double = 0, calls: Int = 0,
                chunks: Int = 1, coverage: Double = 0) {
        self.mode = mode; self.status = status; self.error = error; self.overview = overview
        self.points = points; self.notes = notes; self.tasks = tasks; self.backend = backend; self.model = model
        self.seconds = seconds; self.calls = calls; self.chunks = chunks; self.coverage = coverage
    }

    /// Есть что показать: сводка или хотя бы заметки.
    public var usable: Bool { status != .failed && (!overview.isEmpty || !points.isEmpty || !agenda.isEmpty) }

    public var isProtocol: Bool { layout == "protocol" }

    /// Разделы с пунктами по порядку; пункты вне разделов — в конце без заголовка.
    public var groupedPoints: [(title: String?, points: [MeetingAIPoint])] {
        guard !sections.isEmpty else { return points.isEmpty ? [] : [(nil, points)] }
        var used = Set<Int>()
        var groups: [(title: String?, points: [MeetingAIPoint])] = sections.map { section in
            let items = section.points.filter { points.indices.contains($0) }
            used.formUnion(items)
            return (section.title, items.map { points[$0] })
        }.filter { !$0.points.isEmpty }
        let rest = points.indices.filter { !used.contains($0) }.map { points[$0] }
        if !rest.isEmpty { groups.append((nil, rest)) }
        return groups
    }
}

/// `notes.json` целиком: режимы лежат рядом, последний обработанный — `lastMode`.
/// Дополнительные сводки (W22) — `variants` по ключу вида (`exec`, `protocol`, `custom-…`).
public struct MeetingAIFile: Equatable, Sendable {
    public var lastMode: MeetingAIMode
    public var results: [MeetingAIMode: MeetingAIResult]
    public var variants: [String: MeetingAIResult] = [:]
    /// Шаблон основной сводки (M16): id и «выбран сам по событию».
    public var template: String? = nil
    public var templateAuto: Bool = true

    public init(lastMode: MeetingAIMode, results: [MeetingAIMode: MeetingAIResult],
                variants: [String: MeetingAIResult] = [:]) {
        self.lastMode = lastMode; self.results = results; self.variants = variants
    }

    /// Ключи видов в порядке создания результата (старые первыми).
    public var variantKeys: [String] { variants.keys.sorted() }

    public static func parse(_ data: Data) -> MeetingAIFile? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let modes = root["modes"] as? [String: Any] ?? [:]
        var results: [MeetingAIMode: MeetingAIResult] = [:]
        for (key, value) in modes {
            guard let mode = MeetingAIMode(rawValue: key), let raw = value as? [String: Any] else { continue }
            results[mode] = parseResult(raw, mode: mode)
        }
        var variants: [String: MeetingAIResult] = [:]
        for (key, value) in root["variants"] as? [String: Any] ?? [:] {
            guard let raw = value as? [String: Any] else { continue }
            let mode = (raw["mode"] as? String).flatMap(MeetingAIMode.init(rawValue:)) ?? .brief
            variants[key] = parseResult(raw, mode: mode)
        }
        guard !results.isEmpty || !variants.isEmpty else { return nil }
        let last = (root["last_mode"] as? String).flatMap(MeetingAIMode.init(rawValue:))
            ?? results.keys.sorted { $0.rawValue < $1.rawValue }.first ?? .detailed
        var file = MeetingAIFile(lastMode: results[last] != nil ? last : (results.keys.first ?? .detailed),
                                 results: results, variants: variants)
        if let template = root["template"] as? [String: Any] {
            file.template = template["id"] as? String
            file.templateAuto = template["auto"] as? Bool ?? true
        }
        return file
    }

    static func parseResult(_ raw: [String: Any], mode: MeetingAIMode) -> MeetingAIResult {
        func str(_ v: Any?) -> String? {
            guard let s = v as? String else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
        func refs(_ v: Any?) -> [Int] { ((v as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.intValue } }
        func point(_ p: [String: Any]) -> MeetingAIPoint? {
            guard let text = str(p["text"]) else { return nil }
            return MeetingAIPoint(text: text, refs: refs(p["refs"]), section: str(p["section"]),
                                  fromNotes: (p["src"] as? String) == "notes", formOK: p["form_ok"] as? Bool ?? true)
        }
        func pointList(_ v: Any?) -> [MeetingAIPoint] { ((v as? [[String: Any]]) ?? []).compactMap(point) }
        // Пустые пункты выбрасываются — номера разделов пересчитываются на оставшиеся.
        let rawPoints = (raw["points"] as? [[String: Any]]) ?? []
        var remap: [Int: Int] = [:]
        var points: [MeetingAIPoint] = []
        for (index, item) in rawPoints.enumerated() {
            if let parsed = point(item) { remap[index] = points.count; points.append(parsed) }
        }
        let notes = ((raw["notes"] as? [[String: Any]]) ?? []).compactMap { n -> MeetingAINote? in
            guard let mark = str(n["mark"]) else { return nil }
            return MeetingAINote(markIndex: Int(num(n["mark_index"])), at: num(n["at"]), mark: mark,
                                 text: str(n["text"]) ?? mark, refs: refs(n["refs"]),
                                 kept: n["kept"] as? Bool ?? false, fallback: n["fallback"] as? Bool ?? false)
        }
        let tasks = ((raw["tasks"] as? [[String: Any]]) ?? []).compactMap { t -> MeetingAITask? in
            guard let text = str(t["text"]) else { return nil }
            let assignee: MeetingAITask.Assignee
            switch t["assignee_kind"] as? String {
            case "group": assignee = .group
            case "speaker": assignee = str(t["assignee"]).map { .speaker($0) } ?? .none
            default: assignee = .none
            }
            return MeetingAITask(text: text, owner: str(t["owner"]), assignee: assignee, due: str(t["due"]),
                                 refs: refs(t["refs"]), needsOwner: t["needs_owner"] as? Bool ?? false,
                                 needsDue: t["needs_due"] as? Bool ?? false, done: t["done"] as? Bool ?? false)
        }
        var result = MeetingAIResult(
            mode: mode, status: MeetingAIResult.Status(rawValue: raw["status"] as? String ?? "") ?? .failed,
            error: str(raw["error"]), overview: str(raw["overview"]) ?? "", points: points, notes: notes,
            tasks: tasks, backend: str(raw["backend"]) ?? "claude", model: str(raw["model"]),
            seconds: num(raw["seconds"]), calls: Int(num(raw["calls"])), chunks: max(1, Int(num(raw["chunks"]))),
            coverage: num(raw["coverage"]))
        result.topic = str(raw["topic"]) ?? ""
        result.template = str(raw["template"]) ?? "general"
        result.templateName = str(raw["template_name"]) ?? ""
        result.layout = str(raw["layout"]) ?? "topics"
        result.sections = ((raw["sections"] as? [[String: Any]]) ?? []).compactMap { s in
            guard let title = str(s["title"]) else { return nil }
            let items = ((s["points"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.intValue }.compactMap { remap[$0] }
            return MeetingAISummarySection(title: title, points: items)
        }
        result.decisions = pointList(raw["decisions"])
        result.agenda = ((raw["agenda"] as? [[String: Any]]) ?? []).compactMap { a in
            guard let question = str(a["question"]) else { return nil }
            return MeetingAIAgendaItem(question: question, heard: pointList(a["heard"]), decided: pointList(a["decided"]))
        }
        if let inputs = raw["inputs"] as? [String: Any], !inputs.isEmpty {
            result.inputs = MeetingAIInputs(used: inputs["used"] as? Bool ?? true, agenda: Int(num(inputs["agenda"])),
                                            notesChars: Int(num(inputs["notes_chars"])), images: Int(num(inputs["images"])))
        }
        result.title = str(raw["title"])
        result.instruction = str(raw["instruction"])
        return result
    }
}

/// Пометка встречи в `transcript.json.marks`.
public struct MeetingAIMark: Equatable, Sendable {
    public var at: Double
    public var text: String
    public init(at: Double, text: String) { self.at = at; self.text = text }
}

/// Связь заметок с пометками и репликами.
public enum MeetingAILink {
    /// Пометки из `transcript.json` в порядке времени (как их нумерует движок).
    public static func marks(transcriptJSON data: Data) -> [MeetingAIMark] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return ((root["marks"] as? [[String: Any]]) ?? []).compactMap { m in
            guard let text = (m["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
            else { return nil }
            return MeetingAIMark(at: (m["at"] as? NSNumber)?.doubleValue ?? 0, text: text)
        }.sorted { $0.at < $1.at }
    }

    /// Связь разорвана: пометку поправили (или убрали) после обработки — заметка о старом тексте.
    public static func isStale(_ note: MeetingAINote, marks: [MeetingAIMark]) -> Bool {
        guard marks.indices.contains(note.markIndex) else { return true }
        return normalized(marks[note.markIndex].text) != normalized(note.mark)
    }

    /// Номер строки расшифровки в интерфейсе для реплики `turn`: строки-пометки в нумерации реплик не участвуют.
    public static func line(forTurn turn: Int, isMark: [Bool]) -> Int? {
        guard turn >= 0 else { return nil }
        var seen = -1
        for (index, mark) in isMark.enumerated() where !mark {
            seen += 1
            if seen == turn { return index }
        }
        return nil
    }

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Поправить текст пометки в `transcript.json`; nil — пометки с таким номером нет.
    public static func replacingMark(in transcriptJSON: Data, index: Int, text: String) -> Data? {
        guard var root = try? JSONSerialization.jsonObject(with: transcriptJSON) as? [String: Any],
              let raw = root["marks"] as? [[String: Any]] else { return nil }
        let clean = normalized(text)
        guard !clean.isEmpty else { return nil }
        // Нумерация — по времени, как у движка; в файле порядок тот же, но не полагаемся на это.
        let order = raw.indices.sorted { ((raw[$0]["at"] as? NSNumber)?.doubleValue ?? 0) < ((raw[$1]["at"] as? NSNumber)?.doubleValue ?? 0) }
        guard order.indices.contains(index) else { return nil }
        var marks = raw
        marks[order[index]]["text"] = clean
        root["marks"] = marks
        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Та же правка в `transcript.md`: строка `> 📌 ММ:СС — текст`.
    public static func replacingMark(inMarkdown markdown: String, old: String, new: String) -> String {
        let clean = normalized(new)
        var replaced = false
        let lines = markdown.components(separatedBy: "\n").map { line -> String in
            guard !replaced, line.hasPrefix("> 📌"), let dash = line.range(of: " — ") else { return line }
            guard normalized(String(line[dash.upperBound...])) == normalized(old) else { return line }
            replaced = true
            return String(line[..<dash.upperBound]) + clean
        }
        return lines.joined(separator: "\n")
    }
}

/// Можно ли отдать расшифровку бэкенду (M5–M7). Бэкенд — тот же, что у причёсывания;
/// согласие — своё: для облака это чужие голоса. Облаку нужно ещё и отдельное облачное
/// согласие (`MeetingCloudPolicy`), а «чувствительная» встреча в облако не уходит никогда.
public enum MeetingAIPolicy {
    public enum Gate: Equatable, Sendable {
        case ready(PolishBackend)
        case needsConsent(PolishBackend)
        case noBackend
        /// Встреча помечена «никуда, кроме этого Mac», а выбран облачный бэкенд.
        case sensitiveCloud
    }

    /// `localModel` — локальная LLM скачана: встреча «Только на этом Mac» при облачном выборе
    /// уходит на неё, а не остаётся без сводки и названия. Расшифровка не покидает Mac,
    /// поэтому отдельного согласия не нужно.
    public static func gate(_ settings: MostikSettings, sensitive: Bool = false, localModel: Bool = false) -> Gate {
        // Как у причёсывания: `claude` без облачного согласия на причёсывание считается выключенным.
        let backend = settings.meetingEffectiveBackend
        guard backend != .off else { return .noBackend }
        if backend.isCloud {
            if sensitive { return localModel ? .ready(.mlx) : .sensitiveCloud }
            return MeetingCloudPolicy.cloudAllowed(settings) ? .ready(backend) : .needsConsent(backend)
        }
        return settings.meetingAIConsent ? .ready(backend) : .needsConsent(backend)
    }

    /// Запускать ли сразу после расшифровки: только с согласием и бэкендом.
    public static func autoRun(_ settings: MostikSettings, sensitive: Bool = false, localModel: Bool = false) -> Bool {
        if case .ready = gate(settings, sensitive: sensitive, localModel: localModel) { return true }
        return false
    }
}

// MARK: - Шаблоны и рецепты (M16, W7, W22)

/// Шаблон сводки или рецепт из ответа движка `meeting_templates`.
public struct MeetingTemplateInfo: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var nameEn: String
    /// Шаблон: `topics | people | protocol`; рецепт: `doc | email` (в `output`).
    public var layout: String
    public var output: String
    /// `builtin` или `user` — свой файл из папки пользователя.
    public var source: String

    public init(id: String, name: String, nameEn: String = "", layout: String = "topics", output: String = "doc",
                source: String = "builtin") {
        self.id = id; self.name = name; self.nameEn = nameEn; self.layout = layout; self.output = output
        self.source = source
    }

    public func title(russian: Bool) -> String { !russian && !nameEn.isEmpty ? nameEn : name }

    public static func list(_ value: JSONValue?) -> [MeetingTemplateInfo] {
        guard case let .array(items)? = value else { return [] }
        return items.compactMap { item in
            guard case let .object(fields) = item, let id = fields["id"]?.stringValue, !id.isEmpty else { return nil }
            return MeetingTemplateInfo(id: id, name: fields["name"]?.stringValue ?? id,
                                       nameEn: fields["name_en"]?.stringValue ?? "",
                                       layout: fields["layout"]?.stringValue ?? "topics",
                                       output: fields["output"]?.stringValue ?? "doc",
                                       source: fields["source"]?.stringValue ?? "builtin")
        }
    }

    /// Виды сводки, которые предлагаются как дополнительные (W22): всё, кроме обычных типов встреч.
    public static let extraViews = ["protocol", "exec", "decisions"]
}

/// Ключ своей сводки, описанной словами (W22) — как у движка: `custom-` + 8 знаков sha1.
public enum MeetingAIVariant {
    public static let main = "main"
    public static func isCustom(_ key: String) -> Bool { key.hasPrefix("custom-") }
}

/// Настройки сводки встреч (M16, W23).
public struct MeetingNotesSettings: Codable, Equatable, Sendable {
    /// Галочка «использовать мои пометки»: свои записи из `notes.md` и вставленные картинки — вход сводки.
    public var useMyNotes: Bool = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        useMyNotes = try c.decodeIfPresent(Bool.self, forKey: .useMyNotes) ?? true
    }
}
