import Foundation
import MostikCore

/// Сводка по шаблонам (M16, M17, W8, W22, W23) и следующие шаги черновиком (W25).
func runMeetingSummaryTests() {
    // notes.json: разделы по темам, решения, протокол, виды сводки, шаблон основной.
    do {
        let json = #"""
        {"version": 1, "last_mode": "detailed", "template": {"id": "standup", "auto": true},
         "modes": {"detailed": {"status": "done", "overview": "Итог.", "topic": "Бюджет и релиз",
           "template": "standup", "template_name": "Стендап", "layout": "people",
           "points": [{"text": "  ", "refs": []}, {"text": "Купить мониторы", "refs": [1], "section": "Собеседник 1"},
                      {"text": "Из записи", "refs": [], "src": "notes", "section": "Общее"},
                      {"text": "Без раздела", "refs": [2]}],
           "sections": [{"title": "Собеседник 1", "points": [1]}, {"title": "Общее", "points": [2, 0]}],
           "decisions": [{"text": "Решили купить два монитора", "refs": [1]}],
           "inputs": {"used": true, "agenda": 2, "notes_chars": 120, "images": 1},
           "notes": [], "tasks": [{"text": "Смета", "assignee": "Я", "assignee_kind": "speaker", "refs": [],
                                   "needs_owner": false, "needs_due": true}]}},
         "variants": {
           "protocol": {"status": "done", "mode": "brief", "layout": "protocol", "title": "Протокол", "points": [],
             "agenda": [{"question": "О бюджете", "heard": [{"text": "Собеседник 1 — о перерасходе", "refs": [0]}],
                         "decided": [{"text": "Утвердить бюджет", "refs": [1], "form_ok": true},
                                     {"text": "Решили перенести", "refs": [1], "form_ok": false}]}],
             "tasks": []},
           "custom-1a2b3c4d": {"status": "done", "title": "Только риски", "instruction": "Только риски",
             "overview": "Риски.", "points": [{"text": "Сорвём сроки", "refs": [3]}]}
         }}
        """#
        guard let file = MeetingAIFile.parse(Data(json.utf8)) else { check(false, "notes.json с видами не разобран"); return }
        let main = file.results[.detailed]
        equal(file.template, "standup"); check(file.templateAuto)
        equal(main?.topic, "Бюджет и релиз"); equal(main?.layout, "people"); equal(main?.templateName, "Стендап")
        equal(main?.points.count, 3, "пустой пункт выброшен")
        // Номера разделов пересчитаны после выброса пустого пункта; пункт вне разделов — в конце.
        equal(main?.groupedPoints.map(\.title), ["Собеседник 1", "Общее", nil])
        equal(main?.groupedPoints.map { $0.points.map(\.text) }, [["Купить мониторы"], ["Из записи"], ["Без раздела"]])
        check(main?.points[1].fromNotes == true, "пункт из своих записей помечен")
        equal(main?.decisions.map(\.text), ["Решили купить два монитора"])
        equal(main?.inputs, MeetingAIInputs(used: true, agenda: 2, notesChars: 120, images: 1))
        equal(main?.tasks.first?.needsDue, true); equal(main?.tasks.first?.needsOwner, false)
        equal(file.variantKeys, ["custom-1a2b3c4d", "protocol"])
        let protocolView = file.variants["protocol"]
        check(protocolView?.isProtocol == true && protocolView?.usable == true, "протокол без points — всё равно сводка")
        equal(protocolView?.mode, .brief)
        equal(protocolView?.agenda.first?.decided.map(\.formOK), [true, false])
        equal(file.variants["custom-1a2b3c4d"]?.instruction, "Только риски")
        check(MeetingAIVariant.isCustom("custom-1a2b3c4d") && !MeetingAIVariant.isCustom("exec"))
        // Только виды, без основной сводки, — файл всё равно есть.
        let onlyVariants = #"{"variants": {"exec": {"status": "done", "overview": "x"}}}"#
        check(MeetingAIFile.parse(Data(onlyVariants.utf8))?.variants["exec"] != nil)
        // Старый notes.json без новых полей разбирается как раньше.
        let old = #"{"modes": {"brief": {"status": "done", "overview": "o", "points": [{"text": "p", "refs": [0]}]}}}"#
        let legacy = MeetingAIFile.parse(Data(old.utf8))?.results[.brief]
        equal(legacy?.layout, "topics"); equal(legacy?.groupedPoints.count, 1); equal(legacy?.groupedPoints.first?.title, nil)
    }

    // Список шаблонов из ответа движка.
    do {
        let value = JSONValue.array([
            .object(["id": .string("standup"), "name": .string("Стендап"), "name_en": .string("Standup"),
                     "layout": .string("people"), "source": .string("user")]),
            .object(["name": .string("без id")]),
        ])
        let list = MeetingTemplateInfo.list(value)
        equal(list.map(\.id), ["standup"]); equal(list.first?.title(russian: false), "Standup")
        equal(list.first?.source, "user")
        equal(MeetingTemplateInfo.list(nil), [])
    }

    // Настройки: галочка «использовать мои пометки» включена по умолчанию и переживает старый файл.
    do {
        let decoded = try? JSONDecoder().decode(MostikSettings.self, from: Data("{}".utf8))
        equal(decoded?.meetingNotes.useMyNotes, true)
        let off = try? JSONDecoder().decode(MostikSettings.self, from: Data(#"{"meetingNotes": {"useMyNotes": false}}"#.utf8))
        equal(off?.meetingNotes.useMyNotes, false)
    }

    // Следующие шаги (W25): письмо, задачи, событие — черновики.
    do {
        var result = MeetingAIResult(mode: .detailed, status: .done, overview: "Обсудили бюджет.",
                                     tasks: [MeetingAITask(text: "Подготовить смету", owner: "Я", assignee: .speaker("Собеседник 1"),
                                                           due: "до пятницы", refs: [1]),
                                             MeetingAITask(text: "Провести ретро", owner: nil, assignee: .group, due: nil, refs: []),
                                             MeetingAITask(text: "Посчитать мониторы", owner: nil, assignee: .none, due: nil, refs: [])])
        result.decisions = [MeetingAIPoint(text: "Купить два монитора", refs: [1])]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        // Пятница 10 октября 2025, 15:30 → через неделю пятница, будни.
        let started = calendar.date(from: DateComponents(year: 2025, month: 10, day: 10, hour: 15, minute: 30))!
        let steps = MeetingNextSteps.build(result: result, title: "Синк по бюджету", started: started,
                                           meetingID: "2025-10-10-153000", russian: true, calendar: calendar)
        equal(steps.email.subject, "Итоги: Синк по бюджету")
        check(steps.email.body.contains("Решили:\n- Купить два монитора"), "решения в письме")
        check(steps.email.body.contains("- Подготовить смету — Собеседник 1, до пятницы"), "поручение с исполнителем и сроком")
        check(steps.email.body.contains("- Провести ретро — все") && steps.email.body.contains("— не назначен"))
        equal(steps.tasks.map(\.assignee), ["Собеседник 1", "все", nil])
        check(steps.tasks[0].details.contains("Поставил: Я") && steps.tasks[0].details.contains("Срок: до пятницы"))
        equal(steps.event.title, "Продолжение: Синк по бюджету")
        equal(calendar.dateComponents([.day, .hour], from: steps.event.start), DateComponents(day: 17, hour: 15))
        // Через неделю после субботы — суббота → понедельник.
        let saturday = calendar.date(from: DateComponents(year: 2025, month: 10, day: 11, hour: 10))!
        let monday = MeetingNextSteps.build(result: result, title: "t", started: saturday, meetingID: "x", russian: true,
                                            calendar: calendar).event.start
        equal(calendar.component(.weekday, from: monday), 2)
        // Письмо рецепта «от меня» (W7) побеждает собранное из сводки.
        let recipe = MeetingNextSteps.build(result: result, title: "t", started: started, meetingID: "x", russian: true,
                                            recipeEmail: (subject: "Итоги синка", body: "Коллеги, привет!"))
        equal(recipe.email.subject, "Итоги синка"); equal(recipe.email.body, "Коллеги, привет!")
        // Чувствительная встреча — шагов нет.
        check(!MeetingNextSteps.allowed(sensitive: true) && MeetingNextSteps.allowed(sensitive: false))
        // Задачи для трекера — только отмеченные.
        var drafts = steps.tasks
        drafts[1].include = false
        let markdown = MeetingNextSteps.tasksMarkdown(drafts, russian: true)
        check(markdown.contains("## Подготовить смету") && !markdown.contains("Провести ретро"))
        check(markdown.contains("Исполнитель: Собеседник 1"))
    }

    // mailto: неотправленный черновик, `&`, `+`, `=` и переносы не ломают поля.
    do {
        let draft = MeetingEmailDraft(to: "a@b.ru; c@d.ru, не адрес", subject: "Итоги & план", body: "1+1=2\nвторая строка")
        guard let url = draft.mailtoURL, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            check(false, "mailto не собран"); return
        }
        equal(url.scheme, "mailto")
        equal(components.path, "a@b.ru,c@d.ru")
        equal(components.queryItems?.first { $0.name == "subject" }?.value, "Итоги & план")
        equal(components.queryItems?.first { $0.name == "body" }?.value, "1+1=2\r\nвторая строка")
        check(!url.absoluteString.contains("+1"), "плюс закодирован")
    }

    // .ics: экранирование, CRLF, перенос длинных строк по байтам без разрыва символа.
    do {
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        let event = MeetingEventDraft(title: "Продолжение: бюджет; сроки, QA",
                                      start: start, minutes: 45,
                                      notes: "Открытые поручения:\n- " + String(repeating: "смета ", count: 20), uid: "m1-follow-up@mostik")
        let ics = ICSWriter.render(event, now: start)
        check(ics.hasPrefix("BEGIN:VCALENDAR\r\n") && ics.hasSuffix("END:VCALENDAR\r\n"))
        check(ics.contains("SUMMARY:Продолжение: бюджет\\; сроки\\, QA"), "экранирование ; и ,")
        check(ics.contains("DTSTART:20251009T085320Z") && ics.contains("DTEND:20251009T093820Z"), "UTC и длительность")
        check(ics.contains("DESCRIPTION:Открытые поручения:\\n- смета"), "перенос строки в описании — \\n")
        for line in ics.components(separatedBy: "\r\n") {
            check(line.utf8.count <= 75, "строка ≤ 75 байт: \(line.utf8.count)")
        }
        let unfolded = ics.replacingOccurrences(of: "\r\n ", with: "")
        check(unfolded.contains(String(repeating: "смета ", count: 20).trimmingCharacters(in: .whitespaces)), "склейка возвращает текст")
    }
}
