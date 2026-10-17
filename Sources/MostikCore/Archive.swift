import Foundation

// Архив встреч без векторов (M18, W1, W3, W4, W6): чистая логика на стороне приложения —
// разбор ответов `archive_*` движка и расписание брифа и недельной сводки.
// Сами карточки, бриф и сводки собирает движок (`engine/mostik_engine/archive.py`).

private func int(_ value: JSONValue?) -> Int { Int(value?.doubleValue ?? 0) }
private func items(_ value: JSONValue?) -> [JSONValue] {
    if case .array(let list)? = value { return list }
    return []
}
private func flag(_ value: JSONValue?) -> Bool {
    if case .bool(let b)? = value { return b }
    return false
}

/// Поручение из архива (W4): текст, исполнитель, срок, отметка «сделано».
public struct ArchiveTask: Equatable, Sendable, Identifiable {
    public var meetingID: String
    public var key: String
    public var text: String
    public var assignee: String?
    /// ISO-дата срока, если срок назван.
    public var dueDate: String?
    public var overdue: Bool
    /// open | done | dropped
    public var status: String
    public var meetingTitle: String

    public var id: String { "\(meetingID)/\(key)" }

    public init(meetingID: String, key: String, text: String, assignee: String? = nil, dueDate: String? = nil,
                overdue: Bool = false, status: String = "open", meetingTitle: String = "") {
        self.meetingID = meetingID; self.key = key; self.text = text; self.assignee = assignee
        self.dueDate = dueDate; self.overdue = overdue; self.status = status; self.meetingTitle = meetingTitle
    }

    public init?(json: JSONValue) {
        guard case .object(let o) = json, let meeting = o["meeting_id"]?.stringValue,
              let key = o["key"]?.stringValue else { return nil }
        meetingID = meeting; self.key = key
        text = o["task"]?.stringValue ?? o["text"]?.stringValue ?? ""
        assignee = o["assignee"]?.stringValue
        dueDate = o["due_date"]?.stringValue
        overdue = flag(o["overdue"])
        status = o["status"]?.stringValue ?? (flag(o["open"]) ? "open" : "done")
        meetingTitle = o["meeting_title"]?.stringValue ?? ""
    }

    public var isOpen: Bool { status == "open" }
}

/// Бриф к встрече (W1): до трёх пунктов и открытые обещания серии.
public struct ArchiveBrief: Equatable, Sendable {
    public var eventID: String
    public var title: String
    public var start: String?
    public var points: [String]
    public var followups: [ArchiveTask]
    public var text: String
    public var path: String?

    public init(eventID: String, title: String, start: String? = nil, points: [String], followups: [ArchiveTask] = [],
                text: String = "", path: String? = nil) {
        self.eventID = eventID; self.title = title; self.start = start; self.points = points
        self.followups = followups; self.text = text; self.path = path
    }

    /// Ответ `archive_brief`: `{brief: {...} | null, path}`. Без пунктов брифа нет.
    public init?(payload: [String: JSONValue]) {
        guard case .object(let b)? = payload["brief"] else { return nil }
        var event: [String: JSONValue] = [:]
        if case .object(let e)? = b["event"] { event = e }
        eventID = event["id"]?.stringValue ?? ""
        title = event["title"]?.stringValue ?? ""
        start = event["start"]?.stringValue
        points = items(b["points"]).compactMap { item in
            if case .object(let p) = item { return p["text"]?.stringValue }
            return nil
        }
        followups = items(b["followups"]).compactMap(ArchiveTask.init(json:))
        text = b["text"]?.stringValue ?? ""
        path = payload["path"]?.stringValue
        if points.isEmpty { return nil }
    }

    /// Текст уведомления: пункты через перевод строки, без заголовка.
    public var notificationBody: String { points.prefix(3).joined(separator: "\n") }
}

/// Собеседник из архива (W3).
public struct ArchivePerson: Equatable, Sendable, Identifiable {
    public var name: String
    public var meetings: Int
    public var open: Int
    public var voice: Bool
    public var lastTitle: String?
    public var lastDate: String?
    public var file: String?

    public var id: String { name }

    public init(name: String, meetings: Int, open: Int = 0, voice: Bool = false, lastTitle: String? = nil,
                lastDate: String? = nil, file: String? = nil) {
        self.name = name; self.meetings = meetings; self.open = open; self.voice = voice
        self.lastTitle = lastTitle; self.lastDate = lastDate; self.file = file
    }

    public init?(json: JSONValue) {
        guard case .object(let o) = json, let name = o["name"]?.stringValue else { return nil }
        self.name = name
        meetings = int(o["meetings"]); open = int(o["open"]); voice = flag(o["voice"])
        if case .object(let last)? = o["last"] {
            lastTitle = last["title"]?.stringValue; lastDate = last["date"]?.stringValue
        }
        file = o["file"]?.stringValue
    }

    public static func list(payload: [String: JSONValue]) -> [ArchivePerson] {
        items(payload["items"]).compactMap(ArchivePerson.init(json:))
    }
}

/// Сводка за неделю или по серии (W6).
public struct ArchiveDigest: Equatable, Sendable {
    public var key: String
    public var title: String
    public var text: String
    public var meetings: Int
    public var path: String?

    public init(key: String, title: String, text: String, meetings: Int, path: String? = nil) {
        self.key = key; self.title = title; self.text = text; self.meetings = meetings; self.path = path
    }

    public init?(payload: [String: JSONValue]) {
        guard case .object(let d)? = payload["digest"] else { return nil }
        key = d["key"]?.stringValue ?? ""
        title = d["title"]?.stringValue ?? ""
        text = d["text"]?.stringValue ?? ""
        meetings = items(d["meetings"]).count
        path = payload["path"]?.stringValue
    }
}

/// Настройки архива: бриф до встречи (W1), недельная сводка по расписанию (W6).
public struct ArchiveSettings: Codable, Equatable, Sendable {
    /// Бриф за `briefLeadMinutes` до встречи календаря — уведомлением и файлом в `briefs/`.
    public var brief: Bool = true
    public var briefLeadMinutes: Int = 10
    /// Недельная сводка в `digests/` — внутри приложения, без launchd.
    public var weeklyDigest: Bool = true
    /// День недели по `Calendar` (1 — воскресенье … 6 — пятница).
    public var digestWeekday: Int = 6
    public var digestHour: Int = 17

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case brief, briefLeadMinutes, weeklyDigest, digestWeekday, digestHour
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ArchiveSettings()
        brief = (try? c.decodeIfPresent(Bool.self, forKey: .brief)) ?? d.brief
        briefLeadMinutes = min(60, max(1, (try? c.decodeIfPresent(Int.self, forKey: .briefLeadMinutes)) ?? d.briefLeadMinutes))
        weeklyDigest = (try? c.decodeIfPresent(Bool.self, forKey: .weeklyDigest)) ?? d.weeklyDigest
        digestWeekday = min(7, max(1, (try? c.decodeIfPresent(Int.self, forKey: .digestWeekday)) ?? d.digestWeekday))
        digestHour = min(23, max(0, (try? c.decodeIfPresent(Int.self, forKey: .digestHour)) ?? d.digestHour))
    }
}

/// Расписание архива: что пора сделать сейчас. Чистые функции, время — параметром.
public enum ArchiveSchedule {
    /// Событие, к которому пора показать бриф: начинается в ближайшие `lead` секунд, ещё не началось,
    /// и бриф к нему не показывали. Самое раннее.
    public static func briefDue(events: [CalendarEvent], now: Date, lead: TimeInterval = 600,
                                shown: Set<String>) -> CalendarEvent? {
        events.filter { $0.start > now && $0.start.timeIntervalSince(now) <= lead && !shown.contains($0.id) }
            .min { $0.start < $1.start }
    }

    /// Ключ ISO-недели — тот же, что у движка: `week-2026-W41`.
    public static func weekKey(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "week-%04d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
    }

    /// Пора ли собрать недельную сводку: момент этой недели (день и час) уже прошёл, а сводки
    /// за эту неделю ещё не было. Приложение, закрытое в пятницу, соберёт сводку при запуске в субботу.
    /// Возвращает ключ недели или nil.
    public static func digestDue(now: Date, weekday: Int, hour: Int, lastKey: String?,
                                 timeZone: TimeZone = .current) -> String? {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        let key = weekKey(now, timeZone: timeZone)
        guard key != lastKey,
              let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return nil }
        // Неделя ISO начинается в понедельник; день `Calendar` 1 — воскресенье, он последний.
        let offset = (weekday + 5) % 7
        guard let day = calendar.date(byAdding: .day, value: offset, to: week.start),
              let moment = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) else { return nil }
        return now >= moment ? key : nil
    }
}
