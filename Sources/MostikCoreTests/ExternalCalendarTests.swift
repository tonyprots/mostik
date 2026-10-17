import Foundation
import MostikCore

/// Внешний календарь — команда (docs/external-calendar.md): формат вывода, слияние с календарём macOS,
/// проверка файла и подтверждение пути. Только синтетика.
func runExternalCalendarTests() {
    let now = ISO8601DateFormatter().date(from: "2026-10-16T09:00:00Z")!

    // MARK: аргументы и окружение
    do {
        equal(ExternalCalendar.arguments(around: now, days: 7),
              ["--from", "2026-10-09T09:00:00Z", "--to", "2026-10-23T09:00:00Z"], "окно ±7 дней в UTC")
        let env = ExternalCalendar.environment(from: ["HOME": "/Users/u", "ANTHROPIC_API_KEY": "k", "HTTPS_PROXY": "p",
                                                       "PATH": "/opt/evil:/usr/bin", "LANG": "ru_RU.UTF-8"])
        equal(env["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin", "PATH системный, не родительский")
        equal(env["HOME"], "/Users/u")
        equal(env["LANG"], "ru_RU.UTF-8")
        equal(env["MOSTIK_CALENDAR_FORMAT"], "1")
        check(env["ANTHROPIC_API_KEY"] == nil && env["HTTPS_PROXY"] == nil, "ключи и прокси Mostik команде не достаются")
    }

    // MARK: разбор
    do {
        let json = """
        {"events": [
          {"id": "a1", "title": " Планёрка ", "start": "2026-10-16T10:00:00+03:00", "end": "2026-10-16T10:30:00+03:00",
           "attendees": ["Анна Иванова", "Я", "Анна Иванова", ""], "others": ["Анна Иванова"],
           "link": "https://zoom.us/j/123", "notes": "повестка", "emails": ["anna@example.com", "не почта"]},
          {"title": "Без id", "start": "2026-10-16T12:00:00.500Z", "end": "2026-10-16T13:00:00Z", "attendees": ["A", "B"]},
          {"title": "Весь день", "start": "2026-10-16T00:00:00Z", "end": "2026-10-17T00:00:00Z", "all_day": true},
          {"title": "Конец раньше начала", "start": "2026-10-16T12:00:00Z", "end": "2026-10-16T11:00:00Z"},
          {"title": "Нет даты", "end": "2026-10-16T11:00:00Z"},
          "строка вместо события"
        ]}
        """
        let events = try ExternalCalendar.parse(Data(json.utf8))
        equal(events.count, 2, "битые и целодневные события пропущены")
        let first = events[0]
        equal(first.id, "ext:a1", "id с префиксом — не пересекается с EventKit")
        equal(first.title, "Планёрка", "пробелы по краям сняты")
        equal(first.attendees, ["Анна Иванова", "Я"], "повторы и пустые имена убраны")
        equal(first.others, ["Анна Иванова"])
        equal(first.link, "https://zoom.us/j/123")
        equal(first.emails, ["anna@example.com"], "только похожее на почту")
        equal(first.notes, "повестка")
        equal(events[1].id, "ext:Без id@" + String(Int(ISO8601DateFormatter().date(from: "2026-10-16T12:00:00Z")!.timeIntervalSince1970) ),
              "id по названию и началу; дробные секунды читаются")
        equal(events[1].others, ["A", "B"], "без others — все участники")

        let bare = try ExternalCalendar.parse(Data(#"[{"title": "x", "start": "2026-10-16T10:00:00Z", "end": "2026-10-16T11:00:00Z"}]"#.utf8))
        equal(bare.count, 1, "голый массив тоже формат")
        let long = String(repeating: "я", count: 5000)
        let capped = try ExternalCalendar.parse(Data(#"[{"title": "\#(long)", "notes": "\#(long)", "start": "2026-10-16T10:00:00Z", "end": "2026-10-16T11:00:00Z"}]"#.utf8))
        equal(capped[0].title.count, 200, "название обрезано")
        equal(capped[0].notes.count, 2000, "описание обрезано")
    } catch {
        check(false, "разбор упал: \(error)")
    }
    do {
        func fails(_ text: String, _ expected: ExternalCalendar.ParseError, _ message: String) {
            do { _ = try ExternalCalendar.parse(Data(text.utf8)); check(false, message) } catch {
                equal(error as? ExternalCalendar.ParseError, expected, message)
            }
        }
        fails("not json", .notJSON, "мусор — ошибка, прежние события остаются")
        fails(#"{"items": []}"#, .noEvents, "нет ключа events")
        let many = "[" + Array(repeating: "{}", count: ExternalCalendar.maxEvents + 1).joined(separator: ",") + "]"
        fails(many, .tooMany(ExternalCalendar.maxEvents + 1), "потолок числа событий")
    }

    // MARK: слияние и окно
    do {
        let t = now
        let mac = CalendarEvent(id: "ek1", title: "Планёрка", start: t, end: t.addingTimeInterval(1800), attendees: ["A", "B"])
        let dup = CalendarEvent(id: "ext:1", title: " планёрка ", start: t.addingTimeInterval(20), end: t.addingTimeInterval(1800), attendees: ["A", "B", "C"])
        let other = CalendarEvent(id: "ext:2", title: "Ретро", start: t.addingTimeInterval(-3600), end: t, attendees: ["A", "B"])
        let merged = ExternalCalendar.merge([mac], [dup, other])
        equal(merged.map(\.id), ["ext:2", "ek1"], "дубль по названию и минуте остаётся в версии macOS, порядок по началу")

        let solo = CalendarEvent(id: "ext:3", title: "Напоминание", start: t, end: t.addingTimeInterval(60), attendees: ["Я"])
        let far = CalendarEvent(id: "ext:4", title: "Далеко", start: t.addingTimeInterval(10 * 86_400), end: t.addingTimeInterval(10 * 86_400 + 60), attendees: ["A", "B"])
        equal(ExternalCalendar.window([other, solo, far], around: t, days: 7).map(\.id), ["ext:2"],
              "в окне только встречи (≥2 участника) в пределах ±дней")
    }

    // MARK: файл команды
    do {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("mostik-extcal-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let script = dir.appendingPathComponent("cal")
        fm.createFile(atPath: script.path, contents: Data("#!/bin/sh\necho '[]'\n".utf8))

        equal(ExternalCalendar.check(path: "cal"), .notAbsolute, "относительный путь")
        equal(ExternalCalendar.check(path: dir.appendingPathComponent("нет").path), .missing)
        equal(ExternalCalendar.check(path: dir.path), .notFile, "папка — не файл")
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: script.path)
        equal(ExternalCalendar.check(path: script.path), .notExecutable)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        equal(ExternalCalendar.check(path: script.path), nil, "свой исполняемый файл — годится")
        equal(ExternalCalendar.check(path: script.path, uid: getuid() &+ 4242), .foreignOwner, "чужой владелец")
        try? fm.setAttributes([.posixPermissions: 0o777], ofItemAtPath: script.path)
        equal(ExternalCalendar.check(path: script.path), .writableByOthers, "файл пишут все")
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try? fm.setAttributes([.posixPermissions: 0o777], ofItemAtPath: dir.path)
        equal(ExternalCalendar.check(path: script.path), .writableByOthers, "папку пишут все — файл можно подменить")
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let link = dir.appendingPathComponent("link")
        try? fm.createSymbolicLink(at: link, withDestinationURL: script)
        equal(ExternalCalendar.check(path: link.path), nil, "ссылка раскрывается до настоящего файла")
        check(!ExternalCalendar.describe(.notExecutable).isEmpty)
    }

    // MARK: запуск настоящей команды
    do {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("mostik-extcal-run-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        defer { try? fm.removeItem(at: dir) }
        func script(_ name: String, _ body: String) -> String {
            let url = dir.appendingPathComponent(name)
            fm.createFile(atPath: url.path, contents: Data(("#!/bin/sh\n" + body + "\n").utf8),
                          attributes: [.posixPermissions: 0o755])
            return url.path
        }
        func message(_ r: Result<[CalendarEvent], ExternalCalendar.RunError>) -> String {
            if case .failure(let e) = r { return e.message }
            return "успех"
        }
        setenv("ANTHROPIC_API_KEY", "секрет", 1)
        defer { unsetenv("ANTHROPIC_API_KEY") }
        let ok = script("ok", #"printf '[{"title":"%s|%s|%s|%s","start":"2026-10-16T10:00:00Z","end":"2026-10-16T11:00:00Z","attendees":["A","B"]}]' "$1" "$2" "${ANTHROPIC_API_KEY:-нет}" "$PATH""#)
        if case .success(let events) = ExternalCalendar.run(path: ok, now: now) {
            equal(events.map(\.title), ["--from|2026-10-09T09:00:00Z|нет|/usr/bin:/bin:/usr/sbin:/sbin"],
                  "аргументы окна дошли, ключ Mostik — нет, PATH системный")
        } else {
            check(false, "рабочая команда не прочиталась")
        }
        equal(message(ExternalCalendar.run(path: script("exit", "exit 3"), now: now)), "код выхода 3")
        equal(message(ExternalCalendar.run(path: script("junk", "echo привет"), now: now)), "вывод не в формате событий")
        equal(message(ExternalCalendar.run(path: script("big", "yes | head -c 5000"), now: now, maxOutput: 1000)),
              "вывод больше 0 МБ", "потолок вывода")
        var t0 = Date()
        equal(message(ExternalCalendar.run(path: script("slow", "sleep 5; echo []"), now: now, timeout: 0.5)),
              "не ответила за 0 с", "таймаут")
        check(Date().timeIntervalSince(t0) < 3, "внук-sleep не держит чтение: \(Date().timeIntervalSince(t0)) с")
        t0 = Date()
        equal(message(ExternalCalendar.run(path: script("stubborn", "trap '' TERM; while :; do sleep 0.1; done"), now: now, timeout: 0.5)),
              "не ответила за 0 с", "SIGTERM заглушён")
        check(Date().timeIntervalSince(t0) < 4, "SIGKILL добивает: \(Date().timeIntervalSince(t0)) с")
        equal(message(ExternalCalendar.run(path: dir.appendingPathComponent("нет").path, now: now)), "файла нет",
              "проверка файла перед запуском")
    }

    // MARK: подтверждение пути (как хук встречи, П10 С3)
    do {
        let store = FakeHookDigestStore()
        let path = "/Users/u/bin/calendar-events"
        equal(CalendarCommandTrust.keychainAccount, "calendar-command", "своя запись, не запись хука")
        check(CalendarCommandTrust.digest(path) != MeetingHookTrust.digest(path), "отпечатки хука и календаря не взаимозаменяемы")
        let unknown = CalendarCommandTrust.reconcile(path, store: store)
        check(unknown.active == nil && unknown.ask == path, "вписанный снаружи путь не запускается, а спрашивается")
        check(CalendarCommandTrust.approve(path, store: store))
        let trusted = CalendarCommandTrust.reconcile(path, store: store)
        check(trusted.active == path && trusted.ask == nil, "подтверждённый — в работу")
        let swapped = CalendarCommandTrust.reconcile(path + "2", store: store)
        check(swapped.active == nil && swapped.ask == path + "2", "подменённый путь снова спрашивается")
        check(CalendarCommandTrust.reconcile(nil, store: store) == (nil, nil), "нет пути — нечего спрашивать")
        check(CalendarCommandTrust.reconcile("", store: store) == (nil, nil))
        store.failWrites = true
        check(!CalendarCommandTrust.approve("/x", store: store), "не записали в связку ключей — не одобрено")
    }

    // MARK: настройка
    do {
        let decoded = try? JSONDecoder().decode(MostikSettings.self, from: Data(#"{"calendarCommand": "/Users/u/bin/cal"}"#.utf8))
        equal(decoded?.calendarCommand, "/Users/u/bin/cal")
        equal(MostikSettings().calendarCommand, nil, "по умолчанию внешнего календаря нет")
        let roundTrip = try? JSONDecoder().decode(MostikSettings.self, from: JSONEncoder().encode(decoded ?? MostikSettings()))
        equal(roundTrip?.calendarCommand, "/Users/u/bin/cal", "сохраняется в settings.json")
    }
}
