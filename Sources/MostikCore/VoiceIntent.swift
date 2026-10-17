import Foundation

// Голосовые команды-намерения (D6): «создай встречу завтра в три», «черновик письма Пете», «напомни…».
// Только черновики: событие и напоминание — файлом `.ics`, его открывает Календарь, и пользователь
// сам подтверждает добавление; письмо — `mailto:`, Почта открывает неотправленный черновик.
// Ничего не создаём и не отправляем сами, EventKit не трогаем, Контакты не читаем.
//
// Режим явный: ⌃⌘K — «следующая диктовка — команда», а не угадывание в каждой диктовке.
// Разбор — движок (`engine/mostik_engine/intents.py`, команда `intent`); здесь — решение по
// порогу, черновики и тексты карточки. Договор — `docs/polish-contract.md`, «Голосовые команды».

/// Настройки команд-намерений. Выключены по умолчанию.
public struct VoiceIntentSettings: Codable, Equatable, Sendable {
    public var enabled: Bool = false
    /// Ниже порога — обычная вставка текста. 0,6: правила «глагол + предмет» дают 0,85–0,95,
    /// один предмет без глагола — 0,5, расхождение правил и модели — меньше 0,5.
    public var threshold: Double = 0.6

    public static let thresholdRange: ClosedRange<Double> = 0.3...0.95

    public init(enabled: Bool = false, threshold: Double = 0.6) {
        self.enabled = enabled
        self.threshold = threshold
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        let raw = (try? c.decodeIfPresent(Double.self, forKey: .threshold)) ?? 0.6
        threshold = min(Self.thresholdRange.upperBound, max(Self.thresholdRange.lowerBound, raw))
    }
}

/// Что разобрал движок: ответ команды `intent`.
public struct VoiceIntentReply: Equatable, Sendable {
    /// `event` | `reminder` | `mail` | `none`.
    public var kind: String
    public var confidence: Double
    /// `rules` | `llm` | `rules+llm`.
    public var source: String
    public var title: String
    /// Местное время без пояса: `2026-10-12T15:00`.
    public var start: String?
    public var allDay: Bool
    public var minutes: Int
    public var when: String
    public var whenMissing: Bool
    public var to: String
    public var subject: String
    public var body: String
    /// `done` | `none` | `empty` | `too_long`.
    public var status: String
    public var llmStatus: String
    public var heard: String

    public init(kind: String, confidence: Double, source: String = "rules", title: String = "", start: String? = nil,
                allDay: Bool = false, minutes: Int = 30, when: String = "", whenMissing: Bool = false, to: String = "",
                subject: String = "", body: String = "", status: String = "done", llmStatus: String = "off",
                heard: String = "") {
        self.kind = kind; self.confidence = confidence; self.source = source; self.title = title; self.start = start
        self.allDay = allDay; self.minutes = minutes; self.when = when; self.whenMissing = whenMissing; self.to = to
        self.subject = subject; self.body = body; self.status = status; self.llmStatus = llmStatus; self.heard = heard
    }

    public init(payload: [String: JSONValue]) {
        var intent: [String: JSONValue] = [:]
        if case .object(let object)? = payload["intent"] { intent = object }
        var llm: [String: JSONValue] = [:]
        if case .object(let object)? = payload["llm"] { llm = object }
        self.init(kind: intent["kind"]?.stringValue ?? "none",
                  confidence: intent["confidence"]?.doubleValue ?? 0,
                  source: intent["source"]?.stringValue ?? "rules",
                  title: intent["title"]?.stringValue ?? "",
                  start: intent["start"]?.stringValue,
                  allDay: intent["all_day"]?.boolValue ?? false,
                  minutes: Int(intent["minutes"]?.doubleValue ?? 30),
                  when: intent["when"]?.stringValue ?? "",
                  whenMissing: intent["when_missing"]?.boolValue ?? false,
                  to: intent["to"]?.stringValue ?? "",
                  subject: intent["subject"]?.stringValue ?? "",
                  body: intent["body"]?.stringValue ?? "",
                  status: payload["status"]?.stringValue ?? "none",
                  llmStatus: llm["status"]?.stringValue ?? "off",
                  heard: payload["heard"]?.stringValue ?? "")
    }
}

/// Черновик события или напоминания. Сохраняется файлом `.ics`.
public struct VoiceIntentEvent: Equatable, Sendable {
    public var title: String
    public var start: Date
    public var allDay: Bool
    public var minutes: Int
    /// Напоминание: событие с сигналом в момент начала.
    public var reminder: Bool
    /// Время не названо — подставлен ближайший час; карточка об этом говорит.
    public var timeGuessed: Bool
    public var notes: String
    public var uid: String

    public init(title: String, start: Date, allDay: Bool = false, minutes: Int = 30, reminder: Bool = false,
                timeGuessed: Bool = false, notes: String = "", uid: String) {
        self.title = title; self.start = start; self.allDay = allDay; self.minutes = minutes; self.reminder = reminder
        self.timeGuessed = timeGuessed; self.notes = notes; self.uid = uid
    }
}

/// Черновик письма: имя адресата как сказано («Пете») — в карточке; адрес пользователь вписывает сам.
public struct VoiceIntentMail: Equatable, Sendable {
    public var recipient: String
    public var draft: MeetingEmailDraft

    public init(recipient: String, draft: MeetingEmailDraft) {
        self.recipient = recipient
        self.draft = draft
    }
}

public enum VoiceIntentDraft: Equatable, Sendable {
    case event(VoiceIntentEvent)
    case mail(VoiceIntentMail)
}

public enum VoiceIntentDecision: Equatable, Sendable {
    /// Показать карточку и ждать «Открыть» или «Отмена».
    case preview(VoiceIntentDraft)
    /// Команды нет или уверенность ниже порога — вставить текст как обычную диктовку.
    case insertText
}

public enum VoiceIntentPlan {
    /// Решение по ответу движка и порогу.
    public static func decide(_ reply: VoiceIntentReply, threshold: Double, now: Date = Date(),
                              calendar: Calendar = .current, uid: String = UUID().uuidString.lowercased()) -> VoiceIntentDecision {
        guard reply.status == "done", reply.confidence >= threshold else { return .insertText }
        switch reply.kind {
        case "event", "reminder":
            let title = reply.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return .insertText }
            var start = reply.start.flatMap { parseLocal($0, calendar: calendar) }
            var guessed = false
            if start == nil || reply.whenMissing {
                start = nextHour(after: now, calendar: calendar)
                guessed = true
            }
            guard let start else { return .insertText }
            let notes = reply.heard.isEmpty ? "" : "«" + reply.heard + "»"
            return .preview(.event(VoiceIntentEvent(
                title: title, start: start, allDay: reply.allDay && !guessed, minutes: max(5, min(reply.minutes, 24 * 60)),
                reminder: reply.kind == "reminder", timeGuessed: guessed, notes: notes, uid: "\(uid)@mostik-intent")))
        case "mail":
            let subject = reply.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = reply.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !(subject.isEmpty && body.isEmpty) else { return .insertText }
            // Поле «Кому» пустое: имя — не адрес, Контакты не читаем.
            return .preview(.mail(VoiceIntentMail(recipient: reply.to.trimmingCharacters(in: .whitespacesAndNewlines),
                                                  draft: MeetingEmailDraft(to: "", subject: subject, body: body))))
        default:
            return .insertText
        }
    }

    /// `2026-10-12T15:00` в часовом поясе календаря.
    public static func parseLocal(_ text: String, calendar: Calendar = .current) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter.date(from: text)
    }

    /// `now` для движка: местное время без пояса.
    public static func localStamp(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter.string(from: date)
    }

    /// Ближайший целый час, не раньше чем через 15 минут.
    public static func nextHour(after now: Date, calendar: Calendar = .current) -> Date {
        let soon = now.addingTimeInterval(15 * 60)
        var components = calendar.dateComponents([.year, .month, .day, .hour], from: soon)
        components.minute = 0
        let floor = calendar.date(from: components) ?? soon
        return floor < soon ? (calendar.date(byAdding: .hour, value: 1, to: floor) ?? soon) : floor
    }
}

// MARK: - Карточка

/// Тексты карточки над HUD. Событие: заголовок — название, подпись — «Событие · завтра 15:00 · 1 час»
/// (так название не обрезается рядом с кнопками). Письмо: «Письмо Пете: тема» и первая строка текста.
public enum VoiceIntentCardText {
    public static func headline(_ draft: VoiceIntentDraft, russian: Bool) -> String {
        switch draft {
        case .event(let event):
            return event.title
        case .mail(let mail):
            let who = mail.recipient.isEmpty ? "" : " " + mail.recipient
            let label = russian ? "Письмо" + who : (mail.recipient.isEmpty ? "Email" : "Email to " + mail.recipient)
            let topic = mail.draft.subject.isEmpty ? mail.draft.body : mail.draft.subject
            return label + ": " + firstLine(topic)
        }
    }

    public static func detail(_ draft: VoiceIntentDraft, now: Date = Date(), calendar: Calendar = .current,
                              russian: Bool) -> String {
        switch draft {
        case .event(let event):
            let label = event.reminder ? (russian ? "Напоминание" : "Reminder") : (russian ? "Событие" : "Event")
            var parts = [label, when(event, now: now, calendar: calendar, russian: russian)]
            if !event.allDay, !event.reminder { parts.append(duration(event.minutes, russian: russian)) }
            if event.timeGuessed { parts.append(russian ? "время не названо" : "no time said") }
            return parts.joined(separator: " · ")
        case .mail(let mail):
            let body = firstLine(mail.draft.body)
            let base = russian ? "черновик, адрес впишете сами" : "draft, add the address yourself"
            return body.isEmpty || body == firstLine(mail.draft.subject) ? base : body
        }
    }

    public static func openTitle(_ draft: VoiceIntentDraft, russian: Bool) -> String {
        switch draft {
        case .event: return russian ? "Открыть в Календаре" : "Open in Calendar"
        case .mail: return russian ? "Открыть в Почте" : "Open in Mail"
        }
    }

    /// «завтра 15:00», «сегодня 18:20», «пт, 16 окт., 10:00», «пт, 16 окт., весь день».
    public static func when(_ event: VoiceIntentEvent, now: Date, calendar: Calendar, russian: Bool) -> String {
        let locale = Locale(identifier: russian ? "ru_RU" : "en_US")
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: event.start)).day ?? 99
        let day: String
        switch days {
        case 0: day = russian ? "сегодня" : "today"
        case 1: day = russian ? "завтра" : "tomorrow"
        case 2 where russian: day = "послезавтра"
        default:
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate(days > 0 && days < 300 ? "EEdMMM" : "EEdMMMy")
            day = formatter.string(from: event.start)
        }
        if event.allDay { return day + (russian ? ", весь день" : ", all day") }
        let time = DateFormatter()
        time.locale = locale
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.dateFormat = russian ? "HH:mm" : "h:mm a"
        return day + " " + time.string(from: event.start)
    }

    static func duration(_ minutes: Int, russian: Bool) -> String {
        if minutes % 60 == 0 {
            let hours = minutes / 60
            return russian ? (hours == 1 ? "1 час" : "\(hours) ч") : (hours == 1 ? "1 hour" : "\(hours) hours")
        }
        if minutes > 60 {
            let h = minutes / 60, m = minutes % 60
            return russian ? "\(h) ч \(m) мин" : "\(h) h \(m) min"
        }
        return russian ? "\(minutes) мин" : "\(minutes) min"
    }

    static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    }
}

// MARK: - .ics

/// Событие команды в iCalendar: весь день — `VALUE=DATE`, напоминание — сигнал в момент начала.
/// Экранирование и перенос строк — общие с черновиком события после встречи (`ICSWriter`).
public enum VoiceIntentICS {
    /// Папка черновика события во временной папке (П10 р5 Р5-4л): своя на каждый черновик, с префиксом
    /// из `StorageHygiene.tempPrefixes` — старше 10 минут её убирает следующий черновик и следующий запуск.
    public static let draftPrefix = "mostik-commands-"
    public static func draftFolder(in temp: URL) -> URL {
        temp.appendingPathComponent(draftPrefix + UUID().uuidString, isDirectory: true)
    }

    public static func render(_ event: VoiceIntentEvent, now: Date = Date(), calendar: Calendar = .current) -> String {
        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Mostik//Voice command//RU",
            "CALSCALE:GREGORIAN",
            "BEGIN:VEVENT",
            "UID:" + ICSWriter.escape(event.uid),
            "DTSTAMP:" + ICSWriter.stamp(now),
        ]
        if event.allDay {
            let next = calendar.date(byAdding: .day, value: 1, to: event.start) ?? event.start
            lines += ["DTSTART;VALUE=DATE:" + day(event.start, calendar), "DTEND;VALUE=DATE:" + day(next, calendar)]
        } else {
            let end = event.start.addingTimeInterval(TimeInterval(max(5, event.minutes) * 60))
            lines += ["DTSTART:" + ICSWriter.stamp(event.start), "DTEND:" + ICSWriter.stamp(end)]
        }
        lines.append("SUMMARY:" + ICSWriter.escape(event.title))
        if !event.notes.isEmpty { lines.append("DESCRIPTION:" + ICSWriter.escape(event.notes)) }
        if event.reminder {
            lines += ["BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:" + ICSWriter.escape(event.title),
                      "TRIGGER:-PT0M", "END:VALARM"]
        }
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return lines.flatMap(ICSWriter.fold).joined(separator: "\r\n") + "\r\n"
    }

    static func day(_ date: Date, _ calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    /// Имя файла черновика: латиница и цифры, без пути из названия.
    public static func fileName(_ event: VoiceIntentEvent) -> String {
        let stem = event.uid.prefix(while: { $0 != "@" }).filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return "mostik-" + (stem.isEmpty ? "event" : String(stem.prefix(40))) + ".ics"
    }
}
