import Foundation

/// Разбор iCalendar (RFC 5545) — то, что отдают CalDAV-серверы (Яндекс Календарь и другие).
/// Только чтение и только то, что нужно встречам: время, название, участники, место, ссылка, описание.
/// Повторы (RRULE) разворачиваются здесь же: сервер обычно отдаёт серию одной записью.
public enum ICS {
    public struct Property: Equatable, Sendable {
        public var name: String
        public var params: [String: String]
        public var value: String
    }

    public struct Component: Equatable, Sendable {
        public var name: String
        public var properties: [Property] = []
        public var children: [Component] = []

        public func first(_ name: String) -> Property? { properties.first { $0.name == name } }
        public func all(_ name: String) -> [Property] { properties.filter { $0.name == name } }
    }

    /// Предел разворота одной серии: защита от правила без конца и от злого сервера.
    static let maxOccurrences = 3000
    static let maxIterations = 20_000

    // MARK: строки и свойства

    /// Склейка перенесённых строк: продолжение начинается с пробела или табуляции.
    public static func unfold(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = raw.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else if !raw.isEmpty {
                lines.append(String(raw))
            }
        }
        return lines
    }

    /// `ATTENDEE;CN="Иванова, Анна";ROLE=REQ:mailto:a@x` → имя, параметры, значение. Двоеточие в кавычках — не граница.
    public static func property(_ line: String) -> Property? {
        var inQuotes = false
        var colon: String.Index?
        for i in line.indices {
            let c = line[i]
            if c == "\"" { inQuotes.toggle() } else if c == ":" && !inQuotes { colon = i; break }
        }
        guard let colon else { return nil }
        let head = String(line[..<colon])
        let value = String(line[line.index(after: colon)...])
        var parts: [String] = []
        var current = ""
        inQuotes = false
        for c in head {
            if c == "\"" { inQuotes.toggle(); continue }
            if c == ";" && !inQuotes { parts.append(current); current = ""; continue }
            current.append(c)
        }
        parts.append(current)
        guard let name = parts.first?.uppercased(), !name.isEmpty else { return nil }
        var params: [String: String] = [:]
        for p in parts.dropFirst() {
            guard let eq = p.firstIndex(of: "=") else { continue }
            params[String(p[..<eq]).uppercased()] = String(p[p.index(after: eq)...])
        }
        return Property(name: name, params: params, value: value)
    }

    /// Дерево компонентов (`VCALENDAR` → `VEVENT`, `VTIMEZONE`, `VALARM`).
    public static func parse(_ text: String) -> [Component] {
        var stack: [Component] = []
        var roots: [Component] = []
        for line in unfold(text) {
            guard let p = property(line) else { continue }
            if p.name == "BEGIN" {
                stack.append(Component(name: p.value.uppercased()))
            } else if p.name == "END" {
                guard let done = stack.popLast() else { continue }
                if stack.isEmpty { roots.append(done) } else { stack[stack.count - 1].children.append(done) }
            } else if !stack.isEmpty {
                stack[stack.count - 1].properties.append(p)
            }
        }
        return roots
    }

    /// `\n`, `\,`, `\;`, `\\` в тексте.
    public static func unescape(_ s: String) -> String {
        var out = ""
        var escape = false
        for c in s {
            if escape {
                switch c {
                case "n", "N": out.append("\n")
                default: out.append(c)
                }
                escape = false
            } else if c == "\\" {
                escape = true
            } else {
                out.append(c)
            }
        }
        return out
    }

    // MARK: даты

    public struct DateValue: Equatable, Sendable {
        public var date: Date
        public var allDay: Bool
        public var timeZone: TimeZone

        public init(date: Date, allDay: Bool, timeZone: TimeZone) {
            self.date = date; self.allDay = allDay; self.timeZone = timeZone
        }
    }

    /// `20261016T100000Z`, `TZID=Europe/Moscow:20261016T100000`, `VALUE=DATE:20261016`.
    /// Неизвестный TZID (Windows-имена) и «плавающее» время — часовой пояс этого Mac.
    public static func date(_ p: Property, fallback: TimeZone = .current) -> DateValue? {
        date(p.value, tzid: p.params["TZID"], isDate: p.params["VALUE"]?.uppercased() == "DATE", fallback: fallback)
    }

    static func date(_ raw: String, tzid: String?, isDate: Bool, fallback: TimeZone) -> DateValue? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let utc = s.hasSuffix("Z")
        let digits = utc ? String(s.dropLast()) : s
        let zone = utc ? TimeZone(identifier: "UTC")! : (tzid.flatMap(timeZone) ?? fallback)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        func n(_ from: Int, _ len: Int) -> Int? {
            let chars = Array(digits)
            guard chars.count >= from + len else { return nil }
            return Int(String(chars[from..<(from + len)]))
        }
        guard let y = n(0, 4), let mo = n(4, 2), let d = n(6, 2) else { return nil }
        if isDate || digits.count == 8 {
            guard let day = cal.date(from: DateComponents(year: y, month: mo, day: d)) else { return nil }
            return DateValue(date: day, allDay: true, timeZone: zone)
        }
        guard digits.count >= 15, Array(digits)[8] == "T", let h = n(9, 2), let mi = n(11, 2), let sec = n(13, 2),
              let value = cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: sec))
        else { return nil }
        return DateValue(date: value, allDay: false, timeZone: zone)
    }

    /// Olson-имя как есть; `/mozilla.org/.../Europe/Moscow` — по хвосту; пара частых Windows-имён.
    static func timeZone(_ tzid: String) -> TimeZone? {
        let id = tzid.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        if let tz = TimeZone(identifier: id) { return tz }
        let parts = id.split(separator: "/")
        if parts.count >= 2, let tz = TimeZone(identifier: parts.suffix(2).joined(separator: "/")) { return tz }
        let windows = ["Russian Standard Time": "Europe/Moscow", "UTC": "UTC", "GMT Standard Time": "Europe/London",
                       "W. Europe Standard Time": "Europe/Berlin", "Pacific Standard Time": "America/Los_Angeles",
                       "Eastern Standard Time": "America/New_York", "Central European Standard Time": "Europe/Warsaw"]
        return windows[id].flatMap(TimeZone.init(identifier:))
    }

    /// `PT1H30M`, `P1D`, `-PT15M` → секунды.
    public static func duration(_ s: String) -> TimeInterval? {
        var text = s.trimmingCharacters(in: .whitespaces).uppercased()
        var sign: Double = 1
        if text.hasPrefix("-") { sign = -1; text.removeFirst() } else if text.hasPrefix("+") { text.removeFirst() }
        guard text.hasPrefix("P") else { return nil }
        text.removeFirst()
        var total: Double = 0
        var number = ""
        var inTime = false
        for c in text {
            if c == "T" { inTime = true; continue }
            if c.isNumber { number.append(c); continue }
            guard let v = Double(number) else { return nil }
            number = ""
            switch (c, inTime) {
            case ("W", _): total += v * 7 * 86_400
            case ("D", _): total += v * 86_400
            case ("H", true): total += v * 3600
            case ("M", true): total += v * 60
            case ("S", true): total += v
            default: return nil
            }
        }
        return number.isEmpty ? sign * total : nil
    }

    // MARK: события

    /// Встречи из iCalendar в окне [`from`, `to`]: серии развёрнуты, отменённые и целодневные пропущены.
    /// `owner` — почта владельца календаря: его нет в `others` и `emails`.
    /// `idPrefix` — чтобы id не пересекались с другими источниками.
    public static func events(_ text: String, from: Date, to: Date, owner: String? = nil,
                              idPrefix: String = "ics:", fallback: TimeZone = .current) -> [CalendarEvent] {
        let vevents = parse(text).flatMap { root in root.name == "VEVENT" ? [root] : root.children.filter { $0.name == "VEVENT" } }
        // Перенесённые экземпляры серии: UID → (исходное начало → компонент).
        var overrides: [String: [Date: Component]] = [:]
        var masters: [Component] = []
        for e in vevents {
            if let rid = e.first("RECURRENCE-ID"), let uid = e.first("UID")?.value, let original = date(rid, fallback: fallback) {
                overrides[uid, default: [:]][original.date] = e
            } else {
                masters.append(e)
            }
        }
        var out: [CalendarEvent] = []
        var usedOverrides: Set<String> = []
        for master in masters {
            guard let start = master.first("DTSTART").flatMap({ date($0, fallback: fallback) }), !start.allDay else { continue }
            let length = eventLength(master, start: start, fallback: fallback)
            let uid = master.first("UID")?.value ?? UUID().uuidString
            let starts: [Date]
            if let rule = master.first("RRULE").flatMap({ RRule($0.value, fallback: fallback) }) {
                let excluded = Set(master.all("EXDATE").flatMap { p in
                    p.value.split(separator: ",").compactMap {
                        date(String($0), tzid: p.params["TZID"], isDate: p.params["VALUE"]?.uppercased() == "DATE", fallback: fallback)?.date
                    }
                })
                let extra = master.all("RDATE").flatMap { p in
                    p.value.split(separator: ",").compactMap { date(String($0), tzid: p.params["TZID"], isDate: false, fallback: fallback)?.date }
                }
                starts = (rule.occurrences(start: start, from: from.addingTimeInterval(-length), until: to) + extra)
                    .filter { !excluded.contains($0) }
            } else {
                starts = [start.date]
            }
            for s in starts {
                if let o = overrides[uid]?[s] {
                    usedOverrides.insert(uid + "|" + String(s.timeIntervalSince1970))
                    if let e = event(o, uid: uid, owner: owner, idPrefix: idPrefix, fallback: fallback), e.end >= from, e.start <= to {
                        out.append(e)
                    }
                    continue
                }
                let end = s.addingTimeInterval(length)
                guard end >= from, s <= to else { continue }
                if let e = event(master, uid: uid, owner: owner, idPrefix: idPrefix, fallback: fallback, start: s, end: end) {
                    out.append(e)
                }
            }
        }
        // Перенос без серии в этом ответе (сервер отдал только экземпляр).
        for (uid, list) in overrides {
            for (original, o) in list where !usedOverrides.contains(uid + "|" + String(original.timeIntervalSince1970)) {
                if let e = event(o, uid: uid, owner: owner, idPrefix: idPrefix, fallback: fallback), e.end >= from, e.start <= to {
                    out.append(e)
                }
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    static func eventLength(_ e: Component, start: DateValue, fallback: TimeZone) -> TimeInterval {
        if let end = e.first("DTEND").flatMap({ date($0, fallback: fallback) }) { return max(0, end.date.timeIntervalSince(start.date)) }
        if let d = e.first("DURATION").flatMap({ duration($0.value) }) { return max(0, d) }
        return 0
    }

    static func event(_ e: Component, uid: String, owner: String?, idPrefix: String, fallback: TimeZone,
                      start: Date? = nil, end: Date? = nil) -> CalendarEvent? {
        if e.first("STATUS")?.value.uppercased() == "CANCELLED" { return nil }
        guard let dtstart = e.first("DTSTART").flatMap({ date($0, fallback: fallback) }), !dtstart.allDay else { return nil }
        let s = start ?? dtstart.date
        let finish = end ?? s.addingTimeInterval(eventLength(e, start: dtstart, fallback: fallback))
        let ownerLower = owner?.lowercased()
        var all: [String] = []
        var others: [String] = []
        var emails: [String] = []
        var people = e.all("ATTENDEE")
        if let org = e.first("ORGANIZER"), !people.contains(where: { $0.value.lowercased() == org.value.lowercased() }) {
            people.insert(org, at: 0)
        }
        for p in people {
            let type = p.params["CUTYPE"]?.uppercased()
            if type == "ROOM" || type == "RESOURCE" { continue }
            if p.params["PARTSTAT"]?.uppercased() == "DECLINED", p.name == "ATTENDEE" { continue }
            guard let name = CalendarLogic.participantName(name: p.params["CN"].map(unescape), url: p.value),
                  !all.contains(name) else { continue }
            all.append(name)
            var address = p.value
            if address.lowercased().hasPrefix("mailto:") { address.removeFirst("mailto:".count) }
            address = address.removingPercentEncoding ?? address
            let isOwner = ownerLower != nil && address.lowercased() == ownerLower
            if !isOwner {
                others.append(name)
                if address.contains("@"), !emails.contains(address) { emails.append(address) }
            }
        }
        let notes = e.first("DESCRIPTION").map { unescape($0.value) } ?? ""
        let link = MeetingLinks.find(url: e.first("URL")?.value, location: e.first("LOCATION").map { unescape($0.value) },
                                     notes: notes)
        return CalendarEvent(id: idPrefix + uid + "@" + String(Int(s.timeIntervalSince1970)),
                             title: e.first("SUMMARY").map { unescape($0.value) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                             start: s, end: max(finish, s), attendees: all, others: others,
                             notes: String(notes.prefix(2000)), link: link, emails: emails)
    }
}

/// Правило повтора RFC 5545 — то, что встречается в рабочих календарях: DAILY, WEEKLY с BYDAY,
/// MONTHLY по числу или «второй вторник», YEARLY; INTERVAL, COUNT, UNTIL, BYMONTH, BYSETPOS не поддержан.
public struct RRule: Equatable, Sendable {
    public enum Freq: String, Sendable { case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY" }

    public var freq: Freq
    public var interval = 1
    public var count: Int?
    public var until: Date?
    /// День недели (1 = вс … 7 = сб, как в `Calendar`) и порядковый номер в месяце (`2TU` → 2, `-1FR` → -1).
    public var byDay: [(weekday: Int, ordinal: Int?)] = []
    public var byMonthDay: [Int] = []
    public var byMonth: [Int] = []

    public static func == (a: RRule, b: RRule) -> Bool {
        a.freq == b.freq && a.interval == b.interval && a.count == b.count && a.until == b.until
            && a.byDay.map { "\($0.weekday)/\($0.ordinal ?? 0)" } == b.byDay.map { "\($0.weekday)/\($0.ordinal ?? 0)" }
            && a.byMonthDay == b.byMonthDay && a.byMonth == b.byMonth
    }

    static let weekdays = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]

    public init?(_ text: String, fallback: TimeZone = .current) {
        var fields: [String: String] = [:]
        for part in text.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { fields[kv[0].uppercased()] = kv[1] }
        }
        guard let f = fields["FREQ"].flatMap({ Freq(rawValue: $0.uppercased()) }) else { return nil }
        freq = f
        interval = max(1, Int(fields["INTERVAL"] ?? "") ?? 1)
        count = fields["COUNT"].flatMap(Int.init)
        if let u = fields["UNTIL"] { until = ICS.date(u, tzid: nil, isDate: false, fallback: fallback)?.date }
        for d in (fields["BYDAY"] ?? "").split(separator: ",") {
            let s = String(d).uppercased()
            guard s.count >= 2, let wd = Self.weekdays[String(s.suffix(2))] else { continue }
            byDay.append((wd, Int(s.dropLast(2))))
        }
        byMonthDay = (fields["BYMONTHDAY"] ?? "").split(separator: ",").compactMap { Int($0) }
        byMonth = (fields["BYMONTH"] ?? "").split(separator: ",").compactMap { Int($0) }
    }

    /// Начала экземпляров от DTSTART до `until` (включительно), в часовом поясе DTSTART: перевод часов
    /// не сдвигает встречу «в 10:00». COUNT считается с самого начала серии.
    /// Экземпляры раньше `from` не сохраняются (только считаются для COUNT): серия с 2018 года не упирается в потолок.
    public func occurrences(start: ICS.DateValue, from: Date = .distantPast, until limit: Date) -> [Date] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = start.timeZone
        let end = min(limit, until ?? limit)
        let time = cal.dateComponents([.hour, .minute, .second], from: start.date)
        func at(_ day: Date) -> Date? {
            cal.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: day)
        }
        var out: [Date] = []
        var produced = 0
        func take(_ candidates: [Date]) -> Bool {
            for c in candidates.sorted() where c >= start.date {
                if c > end { return false }
                produced += 1
                if c >= from { out.append(c) }
                if let count, produced >= count { return false }
                if out.count >= ICS.maxOccurrences { return false }
            }
            return true
        }
        let startDay = cal.startOfDay(for: start.date)
        var step = 0
        while step < ICS.maxIterations {
            defer { step += 1 }
            let n = step * interval
            var candidates: [Date] = []
            switch freq {
            case .daily:
                guard let day = cal.date(byAdding: .day, value: n, to: startDay) else { return out }
                if byMonth.isEmpty || byMonth.contains(cal.component(.month, from: day)),
                   byDay.isEmpty || byDay.contains(where: { $0.weekday == cal.component(.weekday, from: day) }) {
                    candidates = [at(day)].compactMap { $0 }
                }
            case .weekly:
                // Неделя с понедельника (WKST=MO по умолчанию у календарей; RFC — тоже MO).
                guard let weekStart = cal.date(byAdding: .weekOfYear, value: n, to: mondayOf(startDay, cal)) else { return out }
                let days = byDay.isEmpty ? [cal.component(.weekday, from: start.date)] : byDay.map(\.weekday)
                candidates = days.compactMap { wd in
                    cal.date(byAdding: .day, value: (wd + 5) % 7, to: weekStart).flatMap(at)
                }
            case .monthly:
                guard let month = cal.date(byAdding: .month, value: n, to: firstOfMonth(startDay, cal)) else { return out }
                candidates = daysIn(month: month, cal: cal, defaultDay: cal.component(.day, from: start.date)).compactMap(at)
            case .yearly:
                guard let year = cal.date(byAdding: .year, value: n, to: firstOfMonth(startDay, cal)) else { return out }
                let months = byMonth.isEmpty ? [cal.component(.month, from: start.date)] : byMonth
                for m in months {
                    var comps = cal.dateComponents([.year], from: year)
                    comps.month = m
                    comps.day = 1
                    guard let first = cal.date(from: comps) else { continue }
                    candidates += daysIn(month: first, cal: cal, defaultDay: cal.component(.day, from: start.date)).compactMap(at)
                }
            }
            if !take(candidates) { return out }
            // Период целиком за пределом окна — дальше только позже.
            if let last = candidates.max(), last > end { return out }
            if candidates.isEmpty, let probe = cal.date(byAdding: periodUnit, value: n, to: startDay), probe > end { return out }
        }
        return out
    }

    private var periodUnit: Calendar.Component {
        switch freq { case .daily: .day; case .weekly: .weekOfYear; case .monthly: .month; case .yearly: .year }
    }

    private func mondayOf(_ day: Date, _ cal: Calendar) -> Date {
        let wd = cal.component(.weekday, from: day)  // 1 = вс
        return cal.date(byAdding: .day, value: -((wd + 5) % 7), to: day) ?? day
    }

    private func firstOfMonth(_ day: Date, _ cal: Calendar) -> Date {
        cal.date(from: cal.dateComponents([.year, .month], from: day)) ?? day
    }

    /// Дни месяца по BYMONTHDAY / BYDAY (с номером или без) / числу DTSTART.
    private func daysIn(month first: Date, cal: Calendar, defaultDay: Int) -> [Date] {
        guard let range = cal.range(of: .day, in: .month, for: first) else { return [] }
        let count = range.count
        func day(_ d: Int) -> Date? { cal.date(byAdding: .day, value: d - 1, to: first) }
        if !byMonthDay.isEmpty {
            return byMonthDay.compactMap { d in
                let real = d > 0 ? d : count + d + 1
                return (1...count).contains(real) ? day(real) : nil
            }
        }
        if !byDay.isEmpty {
            var out: [Date] = []
            for rule in byDay {
                let matching = (1...count).filter { cal.component(.weekday, from: day($0)!) == rule.weekday }
                if let ord = rule.ordinal {
                    let idx = ord > 0 ? ord - 1 : matching.count + ord
                    if matching.indices.contains(idx) { out.append(day(matching[idx])!) }
                } else {
                    out += matching.compactMap(day)
                }
            }
            return out
        }
        // 31-е в коротком месяце пропускается, как в RFC.
        return defaultDay <= count ? [day(defaultDay)].compactMap { $0 } : []
    }
}
