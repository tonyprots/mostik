import Foundation

/// Встреча из календаря вокруг записи (M13, W2): ссылка на звонок, напоминание, повестка, автоостановка.
public struct UpcomingMeeting: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var link: String?
    public var agenda: [String]
    /// Почта участников (W20): черновик предупреждения о записи.
    public var emails: [String] = []

    public init(id: String, title: String, start: Date, end: Date, link: String? = nil, agenda: [String] = [],
                emails: [String] = []) {
        self.id = id; self.title = title; self.start = start; self.end = end; self.link = link; self.agenda = agenda
        self.emails = emails
    }

    public init(event: CalendarEvent) {
        self.init(id: event.id, title: event.title, start: event.start, end: event.end,
                  link: event.link, agenda: Agenda.parse(event.notes), emails: event.emails)
    }
}

public enum MeetingLinks {
    /// Хосты ВКС: ссылка на них в событии — это ссылка на звонок.
    public static let hosts = [
        "telemost.yandex.ru", "telemost.360.yandex.ru", "zoom.us", "zoom.com", "meet.google.com",
        "teams.microsoft.com", "teams.live.com", "webex.com", "salutejazz.ru", "jazz.sber.ru", "ktalk.ru",
        "meet.jit.si", "whereby.com", "facetime.apple.com", "chime.aws", "bluejeans.com", "gotomeeting.com",
        "around.co", "discord.gg", "vk.com/call", "mts-link.ru", "dion.vc",
    ]

    /// Ссылка на звонок: сначала поле URL события, потом место, потом описание. Без известного хоста —
    /// любая https-ссылка из места (там её кладут Google и Яндекс), но не из описания: там бывают документы.
    public static func find(url: String?, location: String?, notes: String?) -> String? {
        for text in [url, location, notes] {
            if let link = urls(in: text).first(where: isCallLink) { return link }
        }
        if let url, let link = urls(in: url).first { return link }
        return urls(in: location).first
    }

    public static func isCallLink(_ link: String) -> Bool {
        let lower = link.lowercased()
        guard let host = URL(string: lower)?.host else { return false }
        return hosts.contains { pattern in
            let parts = pattern.split(separator: "/", maxSplits: 1).map(String.init)
            let hostMatch = host == parts[0] || host.hasSuffix("." + parts[0])
            return hostMatch && (parts.count == 1 || lower.contains(pattern))
        }
    }

    static func urls(in text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        let pattern = #"https?://[^\s<>"'\)\]]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;")) }
        }
    }
}

/// Повестка из описания события (W2): пункты списка или строки после «Повестка» / «Agenda».
public enum Agenda {
    public static let maxItems = 12
    public static let maxLength = 140

    public static func parse(_ notes: String) -> [String] {
        let lines = notes.replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var items: [String] = []
        var underHeading = false
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { if underHeading && !items.isEmpty { underHeading = false }; continue }
            let lower = line.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":# "))
            if ["повестка", "повестка встречи", "agenda", "план", "вопросы", "topics"].contains(lower) {
                underHeading = true
                continue
            }
            if let item = listItem(line) {
                append(item, to: &items)
            } else if underHeading {
                append(line, to: &items)
            }
            if items.count >= maxItems { break }
        }
        return items
    }

    static func listItem(_ line: String) -> String? {
        let pattern = #"^(?:[-*•–—]|\d{1,2}[.)])\s+(?:\[[ xX]?\]\s+)?(.+)$|^\[[ xX]?\]\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        for group in 1...2 {
            if let range = Range(match.range(at: group), in: line) { return String(line[range]) }
        }
        return nil
    }

    static func append(_ text: String, to items: inout [String]) {
        var item = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Ссылки и «подключиться по ссылке» — не пункты повестки.
        guard !item.isEmpty, MeetingLinks.urls(in: item).first.map({ $0.count < item.count - 3 }) ?? true else { return }
        if item.count > maxLength { item = String(item.prefix(maxLength - 1)) + "…" }
        if !items.contains(item) { items.append(item) }
    }
}

/// Напоминание о встрече (M13): за `lead` секунд до начала, один раз на событие.
public enum MeetingReminder {
    public static let defaultLead: TimeInterval = 60

    public static func due(_ events: [CalendarEvent], now: Date, lead: TimeInterval = defaultLead,
                           shown: Set<String>) -> CalendarEvent? {
        events.filter { !shown.contains($0.id) && $0.start > now.addingTimeInterval(-60) && $0.start <= now.addingTimeInterval(lead) }
            .min { $0.start < $1.start }
    }

    /// Ближайшая встреча для карточки «Скоро» (W2): идущая сейчас или начинающаяся в пределах `within`.
    public static func upcoming(_ events: [CalendarEvent], now: Date, within: TimeInterval = 15 * 60) -> CalendarEvent? {
        let candidates = events.filter { $0.end > now && $0.start <= now.addingTimeInterval(within) }
        return candidates.min { a, b in
            let aStarted = a.start <= now, bStarted = b.start <= now
            if aStarted != bStarted { return !aStarted }  // будущая важнее идущей: к ней готовятся
            return a.start < b.start
        }
    }
}

/// Автоостановка записи (M13): звонок закрылся — стоп сразу; кончилось событие календаря — отсчёт, который можно отменить.
/// Выключена по умолчанию. Отменённый отсчёт до конца этой записи не возвращается.
public struct MeetingAutoStop: Equatable, Sendable {
    public static let countdown: TimeInterval = 60

    public private(set) var deadline: Double?
    public private(set) var cancelled = false
    private var sawCall = false

    public init() {}

    public enum Action: Equatable, Sendable { case none, started(deadline: Double), stop }

    /// - Parameters:
    ///   - eventEnd: конец события календаря, по которому идёт запись (секунды с 1970), nil — без события.
    ///   - callActive: приложение звонка держит микрофон.
    public mutating func update(now: Double, eventEnd: Double?, callActive: Bool) -> Action {
        if callActive { sawCall = true }
        guard !cancelled else { return .none }
        if let deadline {
            return now >= deadline ? .stop : .none
        }
        let eventOver = eventEnd.map { now >= $0 } ?? false
        let callOver = sawCall && !callActive
        // Звонок закрылся — встреча кончилась: останавливаем сразу, без минуты ожидания (решение автора).
        if callOver { return .stop }
        // Кончилось только время в календаре, а звонок идёт или его не было — встречи часто
        // затягиваются, поэтому отсчёт с «Завершить сейчас» и «Не останавливать».
        guard eventOver else { return .none }
        let deadline = now + Self.countdown
        self.deadline = deadline
        return .started(deadline: deadline)
    }

    public mutating func cancel() {
        cancelled = true
        deadline = nil
    }

    public func remaining(now: Double) -> TimeInterval? {
        deadline.map { max(0, $0 - now) }
    }
}

/// Предложение записать (W14): только если звонок держит микрофон 10 секунд подряд — короткие
/// голосовые и проверка микрофона не дёргают. «Нет» действует, пока это приложение держит микрофон.
public struct CallSuggestion: Equatable, Sendable {
    public static let delay: TimeInterval = 10

    public private(set) var app: String?
    public private(set) var since: Double?
    public private(set) var dismissed: String?

    public init() {}

    public mutating func appChanged(_ app: String?, at t: Double) {
        guard app != self.app else { return }
        self.app = app
        since = app == nil ? nil : t
        if app == nil || app != dismissed { dismissed = nil }
    }

    public mutating func dismiss() { dismissed = app }

    public func suggestion(at t: Double, recording: Bool, enabled: Bool) -> String? {
        guard enabled, !recording, let app, let since, app != dismissed, t - since >= Self.delay else { return nil }
        return app
    }
}

/// Заметка до встречи (W2) — тот же вид, что пишет движок (`meeting_folder.render_notes_md`).
public enum MeetingNotes {
    public static func render(title: String, agenda: [String], prep: String, language: String = "ru") -> String {
        let en = language == "en"
        var lines = ["# \(en ? "Notes" : "Заметки"): \(title)", ""]
        if !agenda.isEmpty {
            lines += ["## \(en ? "Agenda" : "Повестка")", ""] + agenda.map { "- [ ] \($0)" } + [""]
        }
        let prep = prep.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prep.isEmpty { lines += ["## \(en ? "Prep" : "Подготовка")", "", prep, ""] }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n") + "\n"
    }
}
