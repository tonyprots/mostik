import Foundation

/// Событие календаря для движка (S1). Без EventKit: его заполняет MostikKit.
public struct CalendarEvent: Equatable, Sendable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    /// Все участники, включая владельца календаря.
    public var attendees: [String]
    /// Участники без владельца календаря — для `meeting.attendees`: по договору имя
    /// подставляется, только если такой участник один.
    public var others: [String]
    public var notes: String
    /// Ссылка на звонок из события (M13): поле URL, место или описание — `MeetingLinks.find`.
    public var link: String?
    /// Почта участников без владельца календаря — для черновика предупреждения (W20).
    public var emails: [String] = []

    public init(id: String, title: String, start: Date, end: Date, attendees: [String] = [],
                others: [String]? = nil, notes: String = "", link: String? = nil, emails: [String] = []) {
        self.id = id; self.title = title; self.start = start; self.end = end
        self.attendees = attendees; self.others = others ?? attendees; self.notes = notes; self.link = link
        self.emails = emails
    }
}

public enum CalendarLogic {
    /// Окно выборки событий: ±7 дней.
    public static let windowDays = 7
    /// «Идёт сейчас» с запасом ±10 минут.
    public static let currentSlack: TimeInterval = 600

    /// Встречи, а не напоминания: два участника и больше (фильтр Foresight).
    public static func meetings(_ events: [CalendarEvent]) -> [CalendarEvent] {
        events.filter { Set($0.attendees).count >= 2 }
    }

    /// Событие, которое идёт сейчас (с запасом). Начатое раньше и ещё идущее — приоритетнее
    /// того, что вот-вот начнётся; среди равных — с ближайшим началом.
    public static func current(in events: [CalendarEvent], at now: Date, slack: TimeInterval = currentSlack) -> CalendarEvent? {
        let near = events.filter { $0.start.addingTimeInterval(-slack) <= now && now <= $0.end.addingTimeInterval(slack) }
        func inProgress(_ e: CalendarEvent) -> Bool { e.start <= now && now <= e.end }
        return near.min { a, b in
            if inProgress(a) != inProgress(b) { return inProgress(a) }
            return abs(a.start.timeIntervalSince(now)) < abs(b.start.timeIntervalSince(now))
        }
    }

    /// Поля команды `calendar`: `events: [{id, title, start, end, attendees, notes}]`, ISO 8601.
    public static func commandFields(_ events: [CalendarEvent]) -> [String: JSONValue] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let items: [JSONValue] = events.map { e in
            .object([
                "id": .string(e.id), "title": .string(e.title),
                "start": .string(iso.string(from: e.start)), "end": .string(iso.string(from: e.end)),
                "attendees": .array(e.attendees.map { .string($0) }), "notes": .string(e.notes),
            ])
        }
        return ["events": .array(items)]
    }

    /// Имя участника: отображаемое имя, иначе адрес без `mailto:`.
    public static func participantName(name: String?, url: String?) -> String? {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        guard var address = url?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty else { return nil }
        if address.lowercased().hasPrefix("mailto:") { address.removeFirst("mailto:".count) }
        return address.removingPercentEncoding ?? address
    }
}

/// Часы записи встречи с паузой (M4): пока пауза, время стоит, сэмплы не пишутся,
/// поэтому метки в секундах «от начала записи» совпадают со временем в звуке.
public struct MeetingClock: Equatable, Sendable {
    public private(set) var startedAt: Double
    public private(set) var pausedTotal: Double = 0
    public private(set) var pausedAt: Double? = nil

    public init(startedAt: Double) { self.startedAt = startedAt }

    public var isPaused: Bool { pausedAt != nil }

    public mutating func pause(at t: Double) {
        guard pausedAt == nil else { return }
        pausedAt = t
    }

    public mutating func resume(at t: Double) {
        guard let p = pausedAt else { return }
        pausedTotal += max(0, t - p)
        pausedAt = nil
    }

    /// Записанные секунды к моменту `t`.
    public func elapsed(at t: Double) -> Double {
        let now = pausedAt ?? t
        return max(0, now - startedAt - pausedTotal)
    }
}

/// Пометка встречи для команды `meeting` (M1).
public struct MeetingMarkPayload: Equatable, Sendable {
    public var at: Double
    public var text: String
    public init(at: Double, text: String) { self.at = at; self.text = text }

    public static func fields(_ marks: [MeetingMarkPayload]) -> JSONValue {
        .array(marks.sorted { $0.at < $1.at }.map {
            .object(["at": .number(($0.at * 10).rounded() / 10), "text": .string($0.text)])
        })
    }
}
