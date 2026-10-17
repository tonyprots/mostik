import Foundation
import MostikCore

/// iCalendar для CalDAV (Яндекс Календарь и другие): строки, даты, участники, повторы. Только синтетика.
func runCalendarICSTests() {
    let utc = TimeZone(identifier: "UTC")!
    let msk = TimeZone(identifier: "Europe/Moscow")!
    let iso = ISO8601DateFormatter()
    func d(_ s: String) -> Date { iso.date(from: s)! }
    func local(_ date: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd EEE HH:mm"
        return f.string(from: date)
    }
    func wrap(_ body: String) -> String {
        "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//test//EN\r\n" + body + "END:VCALENDAR\r\n"
    }

    // MARK: строки и свойства
    do {
        equal(ICS.unfold("SUMMARY:Пла\r\n нёрка\r\nUID:1\r\n\tx\r\n"), ["SUMMARY:Планёрка", "UID:1x"], "перенос строки склеивается")
        let p = ICS.property(#"ATTENDEE;CN="Иванова, Анна: PM";PARTSTAT=ACCEPTED:mailto:anna@example.com"#)
        equal(p?.name, "ATTENDEE")
        equal(p?.params["CN"], "Иванова, Анна: PM", "двоеточие и точка с запятой в кавычках — часть имени")
        equal(p?.params["PARTSTAT"], "ACCEPTED")
        equal(p?.value, "mailto:anna@example.com")
        equal(ICS.property("dtstart;tzid=Europe/Moscow:20261016T100000")?.name, "DTSTART", "имя без учёта регистра")
        equal(ICS.unescape(#"Повестка\nпункт 1\, пункт 2\; итог\\"#), "Повестка\nпункт 1, пункт 2; итог\\")
        equal(ICS.property("без двоеточия"), nil)
    }

    // MARK: даты
    do {
        func dv(_ line: String) -> ICS.DateValue? { ICS.property(line).flatMap { ICS.date($0, fallback: utc) } }
        equal(dv("DTSTART:20261016T070000Z")?.date, d("2026-10-16T07:00:00Z"), "UTC")
        equal(dv("DTSTART;TZID=Europe/Moscow:20261016T100000")?.date, d("2026-10-16T07:00:00Z"), "TZID")
        equal(dv("DTSTART;TZID=/mozilla.org/20070129_1/Europe/Moscow:20261016T100000")?.date, d("2026-10-16T07:00:00Z"),
              "TZID с префиксом Thunderbird")
        equal(dv("DTSTART;TZID=Russian Standard Time:20261016T100000")?.date, d("2026-10-16T07:00:00Z"), "Windows-имя")
        equal(dv("DTSTART;TZID=Нет/Такого:20261016T100000")?.date, d("2026-10-16T10:00:00Z"), "неизвестный пояс — запасной")
        equal(dv("DTSTART:20261016T100000")?.date, d("2026-10-16T10:00:00Z"), "плавающее время — запасной пояс")
        check(dv("DTSTART;VALUE=DATE:20261016")?.allDay == true, "целый день")
        equal(dv("DTSTART:2026"), nil, "мусор")
        equal(ICS.duration("PT1H30M"), 5400)
        equal(ICS.duration("P1D"), 86_400)
        equal(ICS.duration("P1W"), 604_800)
        equal(ICS.duration("-PT15M"), -900)
        equal(ICS.duration("1H"), nil)
    }

    // MARK: одно событие
    do {
        let text = wrap("""
        BEGIN:VEVENT\r
        UID:one\r
        DTSTART;TZID=Europe/Moscow:20261016T100000\r
        DTEND;TZID=Europe/Moscow:20261016T103000\r
        SUMMARY:Планёрка\\, неделя 42\r
        ORGANIZER;CN=Пётр:mailto:petr@example.com\r
        ATTENDEE;CN=Пётр:mailto:petr@example.com\r
        ATTENDEE;CN=Я:mailto:Me@Example.com\r
        ATTENDEE;CN="Анна":mailto:anna%40example.com\r
        ATTENDEE;CN=Переговорка 5;CUTYPE=ROOM:mailto:room5@example.com\r
        ATTENDEE;CN=Отказался;PARTSTAT=DECLINED:mailto:no@example.com\r
        LOCATION:https://telemost.yandex.ru/j/123\r
        DESCRIPTION:Повестка\\nДокумент https://docs.example.com/x\r
        BEGIN:VALARM\r
        TRIGGER:-PT10M\r
        END:VALARM\r
        END:VEVENT\r
        BEGIN:VEVENT\r
        UID:cancelled\r
        STATUS:CANCELLED\r
        DTSTART:20261016T120000Z\r
        DTEND:20261016T130000Z\r
        END:VEVENT\r
        BEGIN:VEVENT\r
        UID:allday\r
        DTSTART;VALUE=DATE:20261016\r
        DTEND;VALUE=DATE:20261017\r
        END:VEVENT\r
        BEGIN:VEVENT\r
        UID:outside\r
        DTSTART:20261201T120000Z\r
        DURATION:PT1H\r
        END:VEVENT\r

        """)
        let events = ICS.events(text, from: d("2026-10-15T00:00:00Z"), to: d("2026-10-20T00:00:00Z"),
                                owner: "me@example.com", idPrefix: "yandex:", fallback: utc)
        equal(events.count, 1, "отменённое, целодневное и вне окна пропущены")
        let e = events.first
        equal(e?.title, "Планёрка, неделя 42")
        equal(e?.start, d("2026-10-16T07:00:00Z"))
        equal(e?.end, d("2026-10-16T07:30:00Z"))
        equal(e?.id, "yandex:one@" + String(Int(d("2026-10-16T07:00:00Z").timeIntervalSince1970)))
        equal(e?.attendees, ["Пётр", "Я", "Анна"], "организатор один раз, без переговорки и отказавшегося")
        equal(e?.others, ["Пётр", "Анна"], "владелец календаря — не собеседник (почта без учёта регистра)")
        equal(e?.emails, ["petr@example.com", "anna@example.com"], "почта раскодирована")
        equal(e?.link, "https://telemost.yandex.ru/j/123", "ссылка на звонок из места")
        equal(e?.notes, "Повестка\nДокумент https://docs.example.com/x")
    }

    // MARK: повторы
    do {
        // Пн и ср в 10:00 по Берлину, 6 раз, одна среда исключена, один понедельник перенесён.
        let text = wrap("""
        BEGIN:VEVENT\r
        UID:standup\r
        DTSTART;TZID=Europe/Berlin:20261019T100000\r
        DTEND;TZID=Europe/Berlin:20261019T101500\r
        RRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=6\r
        EXDATE;TZID=Europe/Berlin:20261021T100000\r
        SUMMARY:Стендап\r
        ATTENDEE:mailto:a@example.com\r
        ATTENDEE:mailto:b@example.com\r
        END:VEVENT\r
        BEGIN:VEVENT\r
        UID:standup\r
        RECURRENCE-ID;TZID=Europe/Berlin:20261026T100000\r
        DTSTART;TZID=Europe/Berlin:20261026T120000\r
        DTEND;TZID=Europe/Berlin:20261026T121500\r
        SUMMARY:Стендап (перенесён)\r
        ATTENDEE:mailto:a@example.com\r
        ATTENDEE:mailto:b@example.com\r
        END:VEVENT\r

        """)
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        let events = ICS.events(text, from: d("2026-10-01T00:00:00Z"), to: d("2026-12-01T00:00:00Z"), fallback: utc)
        equal(events.map { local($0.start, berlin) },
              ["2026-10-19 Mon 10:00", "2026-10-26 Mon 12:00", "2026-10-28 Wed 10:00", "2026-11-02 Mon 10:00", "2026-11-04 Wed 10:00"],
              "COUNT=6 минус EXDATE; перенос на 12:00; после перевода часов 25.10 — по-прежнему 10:00")
        equal(events[1].title, "Стендап (перенесён)")
        equal(events[0].end.timeIntervalSince(events[0].start), 900, "длительность серии")
    }
    do {
        let start = ICS.DateValue(date: d("2026-01-13T07:00:00Z"), allDay: false, timeZone: msk)  // вт 13 января, 10:00 МСК
        func run(_ rule: String, until: String = "2026-12-31T00:00:00Z") -> [String] {
            (RRule(rule, fallback: utc)?.occurrences(start: start, until: d(until)) ?? []).map { local($0, msk) }
        }
        equal(Array(run("FREQ=MONTHLY;BYDAY=2TU").prefix(3)), ["2026-01-13 Tue 10:00", "2026-02-10 Tue 10:00", "2026-03-10 Tue 10:00"],
              "второй вторник")
        equal(Array(run("FREQ=MONTHLY;BYDAY=-1FR").prefix(2)), ["2026-01-30 Fri 10:00", "2026-02-27 Fri 10:00"], "последняя пятница")
        equal(Array(run("FREQ=MONTHLY;BYMONTHDAY=31").prefix(3)), ["2026-01-31 Sat 10:00", "2026-03-31 Tue 10:00", "2026-05-31 Sun 10:00"],
              "31-е в коротком месяце пропускается")
        equal(run("FREQ=DAILY;INTERVAL=2;UNTIL=20260119T070000Z"),
              ["2026-01-13 Tue 10:00", "2026-01-15 Thu 10:00", "2026-01-17 Sat 10:00", "2026-01-19 Mon 10:00"], "через день до UNTIL включительно")
        equal(run("FREQ=WEEKLY;INTERVAL=2;COUNT=3"), ["2026-01-13 Tue 10:00", "2026-01-27 Tue 10:00", "2026-02-10 Tue 10:00"],
              "раз в две недели, день DTSTART")
        equal(run("FREQ=YEARLY;COUNT=2", until: "2030-01-01T00:00:00Z"), ["2026-01-13 Tue 10:00", "2027-01-13 Wed 10:00"])
        equal(run("FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR;COUNT=4"),
              ["2026-01-13 Tue 10:00", "2026-01-14 Wed 10:00", "2026-01-15 Thu 10:00", "2026-01-16 Fri 10:00"], "будни")
        check(RRule("FREQ=SECONDLY") == nil && RRule("BYDAY=MO") == nil, "неизвестная частота — не правило")
    }
    do {
        // Ежедневная серия с 2018 года без конца: в окне октября 2026 она есть, потолок не съеден прошлым.
        let text = wrap("BEGIN:VEVENT\r\nUID:old\r\nDTSTART:20180101T090000Z\r\nDTEND:20180101T091500Z\r\nRRULE:FREQ=DAILY\r\nSUMMARY:Старая\r\nATTENDEE:mailto:a@x\r\nATTENDEE:mailto:b@x\r\nEND:VEVENT\r\n")
        let events = ICS.events(text, from: d("2026-10-16T00:00:00Z"), to: d("2026-10-18T00:00:00Z"), fallback: utc)
        equal(events.map(\.start), [d("2026-10-16T09:00:00Z"), d("2026-10-17T09:00:00Z")], "серия 2018 года видна в 2026")
        let endless = wrap("BEGIN:VEVENT\r\nUID:e\r\nDTSTART:20261016T090000Z\r\nDTEND:20261016T091500Z\r\nRRULE:FREQ=DAILY\r\nEND:VEVENT\r\n")
        equal(ICS.events(endless, from: d("2026-10-16T00:00:00Z"), to: d("2126-10-16T00:00:00Z"), fallback: utc).count, 3000,
              "бесконечная серия на век вперёд упирается в потолок")
        // Только перенесённый экземпляр без серии в ответе.
        let lone = wrap("BEGIN:VEVENT\r\nUID:x\r\nRECURRENCE-ID:20261016T090000Z\r\nDTSTART:20261016T110000Z\r\nDTEND:20261016T113000Z\r\nSUMMARY:Перенос\r\nEND:VEVENT\r\n")
        equal(ICS.events(lone, from: d("2026-10-16T00:00:00Z"), to: d("2026-10-17T00:00:00Z"), fallback: utc).map(\.title), ["Перенос"])
    }
}
