import Foundation

// Следующие шаги после встречи (W25): письмо-итог, задачи для трекера, событие — только черновиком.
// Ничего не отправляется и не создаётся во внешних системах: письмо открывается неотправленным
// черновиком через `mailto:`, задачи — текстом, событие — файлом `.ics`. Чувствительные встречи
// (`MeetingFolder.isSensitive`) сюда не попадают — как и в рецепты (W7).

/// Черновик письма-итога.
public struct MeetingEmailDraft: Equatable, Sendable {
    public var to: String
    public var subject: String
    public var body: String
    public init(to: String = "", subject: String, body: String) { self.to = to; self.subject = subject; self.body = body }

    /// `mailto:` — почта откроет неотправленный черновик. Адресатов пользователь вписывает сам.
    public var mailtoURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = to.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
            .map(String.init).filter { $0.contains("@") }.joined(separator: ",")
        // `+` в URLQueryItem не кодируется, а почтовые клиенты читают его как пробел.
        components.percentEncodedQueryItems = [
            URLQueryItem(name: "subject", value: Self.encode(subject)),
            URLQueryItem(name: "body", value: Self.encode(body.replacingOccurrences(of: "\n", with: "\r\n"))),
        ]
        return components.url
    }

    static func encode(_ text: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

/// Черновик задачи для трекера: название, описание, исполнитель и срок как прозвучали.
public struct MeetingTaskDraft: Equatable, Sendable, Identifiable {
    public var id: Int
    public var title: String
    public var assignee: String?
    public var due: String?
    public var details: String
    public var include: Bool = true

    public init(id: Int, title: String, assignee: String?, due: String?, details: String) {
        self.id = id; self.title = title; self.assignee = assignee; self.due = due; self.details = details
    }
}

/// Черновик события: продолжение встречи. Сохраняется файлом `.ics`.
public struct MeetingEventDraft: Equatable, Sendable {
    public var title: String
    public var start: Date
    public var minutes: Int
    public var notes: String
    public var uid: String

    public init(title: String, start: Date, minutes: Int = 30, notes: String, uid: String) {
        self.title = title; self.start = start; self.minutes = minutes; self.notes = notes; self.uid = uid
    }
}

public struct MeetingNextSteps: Equatable, Sendable {
    public var email: MeetingEmailDraft
    public var tasks: [MeetingTaskDraft]
    public var event: MeetingEventDraft

    public init(email: MeetingEmailDraft, tasks: [MeetingTaskDraft], event: MeetingEventDraft) {
        self.email = email; self.tasks = tasks; self.event = event
    }

    /// Можно ли готовить шаги: чувствительная встреча — нет.
    public static func allowed(sensitive: Bool) -> Bool { !sensitive }

    /// Черновики из сводки. `recipeEmail` — текст рецепта «письмо от меня» (W7), если он уже есть:
    /// тогда письмо берётся из него, иначе собирается из сводки без модели.
    public static func build(result: MeetingAIResult, title: String, started: Date, meetingID: String,
                             russian: Bool, recipeEmail: (subject: String, body: String)? = nil,
                             calendar: Calendar = .current) -> MeetingNextSteps {
        let email: MeetingEmailDraft
        if let recipeEmail, !recipeEmail.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            email = MeetingEmailDraft(subject: recipeEmail.subject.isEmpty ? subject(title, russian) : recipeEmail.subject,
                                      body: recipeEmail.body)
        } else {
            email = MeetingEmailDraft(subject: subject(title, russian), body: emailBody(result, russian: russian))
        }
        let tasks = result.tasks.enumerated().map { index, task in
            var draft = MeetingTaskDraft(id: index, title: task.text, assignee: person(task, russian: russian), due: task.due,
                                         details: taskDetails(task, title: title, started: started, russian: russian))
            draft.include = !task.done  // сделанные в трекер по умолчанию не идут
            return draft
        }
        let event = MeetingEventDraft(
            title: (russian ? "Продолжение: " : "Follow-up: ") + title,
            start: followUpStart(after: started, calendar: calendar), minutes: 30,
            notes: eventNotes(result, russian: russian), uid: "\(meetingID)-follow-up@mostik")
        return MeetingNextSteps(email: email, tasks: tasks, event: event)
    }

    static func subject(_ title: String, _ russian: Bool) -> String { (russian ? "Итоги: " : "Recap: ") + title }

    static func person(_ task: MeetingAITask, russian: Bool) -> String? {
        switch task.assignee {
        case let .speaker(name): return name == "Я" ? (russian ? "я" : "me") : name
        case .group: return russian ? "все" : "everyone"
        case .none: return nil
        }
    }

    static func emailBody(_ result: MeetingAIResult, russian: Bool) -> String {
        var lines: [String] = [russian ? "Коллеги, добрый день!" : "Hi all,", ""]
        let overview = result.overview.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(overview.isEmpty ? (russian ? "Коротко об итогах встречи." : "A short recap of the meeting.") : overview)
        let decisions = result.decisions.isEmpty ? result.agenda.flatMap(\.decided) : result.decisions
        if !decisions.isEmpty {
            lines += ["", russian ? "Решили:" : "Decided:"]
            lines += decisions.map { "- " + $0.text }
        }
        if !result.tasks.isEmpty {
            lines += ["", russian ? "Кто что делает:" : "Who does what:"]
            for task in result.tasks {
                var line = "- " + task.text + " — " + (person(task, russian: russian) ?? (russian ? "не назначен" : "unassigned"))
                if let due = task.due { line += ", " + due }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    static func taskDetails(_ task: MeetingAITask, title: String, started: Date, russian: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: russian ? "ru_RU" : "en_US")
        formatter.dateFormat = russian ? "d MMMM yyyy" : "MMMM d, yyyy"
        var lines = [(russian ? "Со встречи «" : "From the meeting “") + title + (russian ? "», " : "”, ") + formatter.string(from: started) + "."]
        if let owner = task.owner { lines.append((russian ? "Поставил: " : "Set by: ") + owner) }
        if let due = task.due { lines.append((russian ? "Срок: " : "Due: ") + due) }
        return lines.joined(separator: "\n")
    }

    static func eventNotes(_ result: MeetingAIResult, russian: Bool) -> String {
        var lines = [russian ? "Открытые поручения:" : "Open tasks:"]
        let open = result.tasks.filter { !$0.done }
        lines += open.map { "- " + $0.text }
        if open.isEmpty { lines.append(russian ? "- нет" : "- none") }
        return lines.joined(separator: "\n")
    }

    /// Та же время через неделю; если выпало на выходные — ближайший понедельник.
    static func followUpStart(after started: Date, calendar: Calendar) -> Date {
        var date = calendar.date(byAdding: .day, value: 7, to: started) ?? started
        while calendar.isDateInWeekend(date) {
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        }
        return date
    }

    /// Задачи текстом для трекера: Markdown со списком, по одной задаче на раздел.
    public static func tasksMarkdown(_ tasks: [MeetingTaskDraft], russian: Bool) -> String {
        tasks.filter(\.include).map { task in
            var lines = ["## " + task.title]
            if let assignee = task.assignee { lines.append((russian ? "Исполнитель: " : "Assignee: ") + assignee) }
            if let due = task.due { lines.append((russian ? "Срок: " : "Due: ") + due) }
            lines += ["", task.details]
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n") + "\n"
    }
}

/// Событие в формате iCalendar (RFC 5545): CRLF, экранирование, перенос строк длиннее 75 байт.
public enum ICSWriter {
    public static func render(_ event: MeetingEventDraft, now: Date = Date()) -> String {
        let end = event.start.addingTimeInterval(TimeInterval(max(5, event.minutes) * 60))
        let lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Mostik//Meeting follow-up//RU",
            "CALSCALE:GREGORIAN",
            "BEGIN:VEVENT",
            "UID:" + escape(event.uid),
            "DTSTAMP:" + stamp(now),
            "DTSTART:" + stamp(event.start),
            "DTEND:" + stamp(end),
            "SUMMARY:" + escape(event.title),
            "DESCRIPTION:" + escape(event.notes),
            "END:VEVENT",
            "END:VCALENDAR",
        ]
        return lines.flatMap(fold).joined(separator: "\r\n") + "\r\n"
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    /// Текст свойства: переводы строк — `\n` (и одиночный `\r` тоже, иначе календарь начнёт с него
    /// новое свойство), прочие управляющие символы вырезаются (П10, низкие).
    static func escape(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
        return String(String.UnicodeScalarView(escaped.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
    }

    /// Строка длиннее 75 байт UTF-8 переносится: продолжение начинается с пробела. Символ не режется.
    static func fold(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var bytes = 0
        for character in line {
            let size = String(character).utf8.count
            let limit = result.isEmpty ? 75 : 74
            if bytes + size > limit {
                result.append(current)
                current = ""
                bytes = 0
            }
            current.append(character)
            bytes += size
        }
        result.append(current)
        return result.enumerated().map { $0.offset == 0 ? $0.element : " " + $0.element }
    }
}
