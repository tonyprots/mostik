import Foundation
import MostikCore

/// Архив встреч (П6-Г): разбор ответов движка, расписание брифа и недельной сводки.
func runArchiveTests() {
    // W1: ответ archive_brief.
    let line = #"{"id":9,"ok":true,"brief":{"event":{"id":"ABC@3","title":"Синк","start":"2026-10-21T10:00:00+03:00","attendees":["Иван"]},"series":"cal:ABC","points":[{"kind":"last","text":"В прошлый раз: смета"},{"kind":"promises","text":"Иван обещал — сделано?"}],"followups":[{"meeting_id":"2026-10-14-100000","key":"abc123","task":"смета","assignee":"Иван","due_date":"2026-10-17","overdue":true,"status":"open","open":true,"meeting_title":"Синк"}],"text":"Бриф: Синк"},"path":"/h/briefs/x.md"}"#
    if case .reply(_, let ok, let payload)? = EngineCodec.decode(line: line), let brief = ArchiveBrief(payload: payload) {
        check(ok)
        equal(brief.eventID, "ABC@3")
        equal(brief.points.count, 2)
        equal(brief.followups.first?.id, "2026-10-14-100000/abc123")
        check(brief.followups.first?.overdue == true && brief.followups.first?.isOpen == true, "просрочено и открыто")
        equal(brief.notificationBody, "В прошлый раз: смета\nИван обещал — сделано?")
        equal(brief.path, "/h/briefs/x.md")
    } else {
        check(false, "archive_brief не разобран")
    }
    check(ArchiveBrief(payload: ["brief": .null]) == nil, "без брифа — nil")

    // W3, W6: списки.
    let people = ArchivePerson.list(payload: ["items": .array([.object([
        "name": .string("Иван Петров"), "meetings": .number(2), "open": .number(1), "voice": .bool(true),
        "last": .object(["title": .string("Синк"), "date": .string("2026-10-14T10:00")]),
    ])])])
    equal(people.first?.name, "Иван Петров"); equal(people.first?.meetings, 2); check(people.first?.voice == true)
    equal(people.first?.lastTitle, "Синк")
    let digest = ArchiveDigest(payload: ["digest": .object(["key": .string("week-2026-W42"), "title": .string("Неделя"),
                                                            "text": .string("# Неделя\n"), "meetings": .array([.object([:])])])])
    equal(digest?.meetings, 1); equal(digest?.key, "week-2026-W42")

    // Настройки: умолчания, разбор старого файла и мусора.
    let decoded = try? JSONDecoder().decode(ArchiveSettings.self, from: Data(#"{"digestHour":99,"topics":["цена"]}"#.utf8))
    equal(decoded?.digestHour, 23, "час прижат к диапазону, старое поле topics не мешает")
    check(decoded?.brief == true && decoded?.weeklyDigest == true, "умолчания")
    let settings = try? JSONDecoder().decode(MostikSettings.self, from: Data(#"{"archive":{"brief":false}}"#.utf8))
    check(settings?.archive.brief == false, "поле archive в настройках")
    check((try? JSONDecoder().decode(MostikSettings.self, from: Data(#"{"archive":7}"#.utf8)))?.archive == ArchiveSettings(),
          "битое поле — умолчание, а не сброс настроек")

    // Расписание брифа (W1): за 10 минут, один раз, самое раннее.
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let a = CalendarEvent(id: "a", title: "A", start: now.addingTimeInterval(540), end: now.addingTimeInterval(3600))
    let b = CalendarEvent(id: "b", title: "B", start: now.addingTimeInterval(300), end: now.addingTimeInterval(3600))
    let late = CalendarEvent(id: "c", title: "C", start: now.addingTimeInterval(900), end: now.addingTimeInterval(3600))
    let started = CalendarEvent(id: "d", title: "D", start: now.addingTimeInterval(-60), end: now.addingTimeInterval(3600))
    equal(ArchiveSchedule.briefDue(events: [a, b, late, started], now: now, shown: [])?.id, "b")
    equal(ArchiveSchedule.briefDue(events: [a, b, late], now: now, shown: ["b"])?.id, "a")
    check(ArchiveSchedule.briefDue(events: [late, started], now: now, shown: []) == nil, "рано или уже идёт")

    // Недельная сводка (W6): ключ ISO-недели и момент «пятница 17:00».
    let utc = TimeZone(identifier: "UTC")!
    let iso = ISO8601DateFormatter()
    let friday = iso.date(from: "2026-10-16T16:59:00Z")!   // пятница, неделя 42
    equal(ArchiveSchedule.weekKey(friday, timeZone: utc), "week-2026-W42")
    equal(ArchiveSchedule.weekKey(iso.date(from: "2027-01-01T12:00:00Z")!, timeZone: utc), "week-2026-W53", "год ISO-недели")
    check(ArchiveSchedule.digestDue(now: friday, weekday: 6, hour: 17, lastKey: nil, timeZone: utc) == nil, "ещё рано")
    let fridayLate = friday.addingTimeInterval(120)
    equal(ArchiveSchedule.digestDue(now: fridayLate, weekday: 6, hour: 17, lastKey: nil, timeZone: utc), "week-2026-W42")
    check(ArchiveSchedule.digestDue(now: fridayLate, weekday: 6, hour: 17, lastKey: "week-2026-W42", timeZone: utc) == nil,
          "за неделю один раз")
    let saturday = iso.date(from: "2026-10-17T09:00:00Z")!
    equal(ArchiveSchedule.digestDue(now: saturday, weekday: 6, hour: 17, lastKey: "week-2026-W41", timeZone: utc),
          "week-2026-W42", "пропущенная пятница — в субботу")
    let sundayEvening = iso.date(from: "2026-10-18T20:00:00Z")!
    equal(ArchiveSchedule.digestDue(now: sundayEvening, weekday: 1, hour: 19, lastKey: nil, timeZone: utc),
          "week-2026-W42", "воскресенье — последний день ISO-недели")
    check(ArchiveSchedule.digestDue(now: saturday, weekday: 1, hour: 19, lastKey: nil, timeZone: utc) == nil)
}
