import Foundation
import MostikCore

// Голосовые команды-намерения (D6): порог, черновики, карточка, .ics, настройки. Только синтетика.
func runVoiceIntentTests() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
    let now = VoiceIntentPlan.parseLocal("2026-10-11T17:20", calendar: calendar)!  // воскресенье

    // MARK: настройки
    do {
        let d = MostikSettings()
        check(!d.voiceIntents.enabled, "выключено по умолчанию")
        equal(d.voiceIntents.threshold, 0.6, "порог по умолчанию")
        let old = try? JSONDecoder().decode(MostikSettings.self, from: Data(#"{"language":"ru"}"#.utf8))
        equal(old?.voiceIntents, VoiceIntentSettings(), "старый файл настроек — умолчания")
        let wild = try? JSONDecoder().decode(VoiceIntentSettings.self, from: Data(#"{"enabled":true,"threshold":5}"#.utf8))
        equal(wild?.threshold, 0.95, "порог зажат в пределы")
        equal(wild?.enabled, true)
        var s = MostikSettings()
        s.voiceIntents = VoiceIntentSettings(enabled: true, threshold: 0.7)
        let round = try? JSONDecoder().decode(MostikSettings.self, from: JSONEncoder().encode(s))
        equal(round?.voiceIntents, s.voiceIntents, "сохраняется и читается")
    }

    // MARK: ответ движка
    let payload: [String: JSONValue] = [
        "ok": .bool(true), "status": .string("done"), "heard": .string("создай встречу с Петей завтра в три"),
        "intent": .object(["kind": .string("event"), "confidence": .number(0.95), "source": .string("rules+llm"),
                           "title": .string("Встреча с Петей"), "start": .string("2026-10-12T15:00"),
                           "all_day": .bool(false), "minutes": .number(60), "when": .string("завтра в три"),
                           "when_missing": .bool(false)]),
        "llm": .object(["status": .string("done"), "ms": .number(800)]),
    ]
    let reply = VoiceIntentReply(payload: payload)
    equal(reply.kind, "event"); equal(reply.minutes, 60); equal(reply.llmStatus, "done"); equal(reply.source, "rules+llm")
    equal(VoiceIntentReply(payload: [:]).kind, "none", "пустой ответ — не команда")

    // MARK: решение по порогу
    do {
        guard case .preview(.event(let event)) = VoiceIntentPlan.decide(reply, threshold: 0.6, now: now, calendar: calendar,
                                                                        uid: "u1") else {
            check(false, "событие выше порога — карточка"); return
        }
        equal(event.title, "Встреча с Петей")
        equal(VoiceIntentPlan.localStamp(event.start, calendar: calendar), "2026-10-12T15:00")
        equal(event.minutes, 60); check(!event.reminder && !event.timeGuessed && !event.allDay)
        equal(event.uid, "u1@mostik-intent")
        equal(VoiceIntentPlan.decide(reply, threshold: 0.96, now: now, calendar: calendar), .insertText, "ниже порога — текст")
        var none = reply; none.kind = "none"
        equal(VoiceIntentPlan.decide(none, threshold: 0.3, now: now, calendar: calendar), .insertText, "не команда — текст")
        var failed = reply; failed.status = "too_long"
        equal(VoiceIntentPlan.decide(failed, threshold: 0.3, now: now, calendar: calendar), .insertText)
        var untitled = reply; untitled.title = "  "
        equal(VoiceIntentPlan.decide(untitled, threshold: 0.3, now: now, calendar: calendar), .insertText, "без названия — текст")
    }
    do {
        // Время не названо — ближайший целый час не раньше чем через 15 минут; помечено.
        let r = VoiceIntentReply(kind: "event", confidence: 0.85, title: "Созвон", start: nil, whenMissing: true)
        guard case .preview(.event(let event)) = VoiceIntentPlan.decide(r, threshold: 0.6, now: now, calendar: calendar) else {
            check(false, "событие без времени — карточка"); return
        }
        equal(VoiceIntentPlan.localStamp(event.start, calendar: calendar), "2026-10-11T18:00")
        check(event.timeGuessed && !event.allDay, "время подставлено")
        let late = VoiceIntentPlan.parseLocal("2026-10-11T17:50", calendar: calendar)!
        equal(VoiceIntentPlan.localStamp(VoiceIntentPlan.nextHour(after: late, calendar: calendar), calendar: calendar),
              "2026-10-11T19:00", "до часа меньше 15 минут — следующий")
        let reminder = VoiceIntentReply(kind: "reminder", confidence: 0.95, title: "Позвонить в банк",
                                        start: "2026-10-12T09:00", heard: "напомни мне завтра в 9 позвонить в банк")
        guard case .preview(.event(let r2)) = VoiceIntentPlan.decide(reminder, threshold: 0.6, now: now, calendar: calendar) else {
            check(false, "напоминание — карточка"); return
        }
        check(r2.reminder, "напоминание с сигналом")
        equal(r2.notes, "«напомни мне завтра в 9 позвонить в банк»", "сказанное — в заметке события")
    }
    do {
        let mail = VoiceIntentReply(kind: "mail", confidence: 0.9, to: "Пете", subject: "О переносе релиза",
                                    body: "Релиз переносим на пятницу.")
        guard case .preview(.mail(let draft)) = VoiceIntentPlan.decide(mail, threshold: 0.6, now: now, calendar: calendar) else {
            check(false, "письмо — карточка"); return
        }
        equal(draft.recipient, "Пете"); equal(draft.draft.to, "", "адрес не выдумываем")
        let url = draft.draft.mailtoURL?.absoluteString ?? ""
        check(url.hasPrefix("mailto:?subject=") && url.contains("body="), "mailto без адресата: \(url)")
        var empty = mail; empty.subject = ""; empty.body = ""
        equal(VoiceIntentPlan.decide(empty, threshold: 0.6, now: now, calendar: calendar), .insertText, "пустое письмо — текст")
    }

    // MARK: карточка
    do {
        let event = VoiceIntentEvent(title: "Встреча с Петей", start: VoiceIntentPlan.parseLocal("2026-10-12T15:00", calendar: calendar)!,
                                     minutes: 60, uid: "u")
        equal(VoiceIntentCardText.headline(.event(event), russian: true), "Встреча с Петей")
        equal(VoiceIntentCardText.detail(.event(event), now: now, calendar: calendar, russian: true), "Событие · завтра 15:00 · 1 час")
        equal(VoiceIntentCardText.detail(.event(event), now: now, calendar: calendar, russian: false), "Event · tomorrow 3:00 PM · 1 hour")
        equal(VoiceIntentCardText.openTitle(.event(event), russian: true), "Открыть в Календаре")
        var today = event; today.start = VoiceIntentPlan.parseLocal("2026-10-11T18:20", calendar: calendar)!; today.minutes = 30
        today.reminder = true
        equal(VoiceIntentCardText.headline(.event(today), russian: true), "Встреча с Петей")
        equal(VoiceIntentCardText.detail(.event(today), now: now, calendar: calendar, russian: true), "Напоминание · сегодня 18:20")
        var friday = event; friday.start = VoiceIntentPlan.parseLocal("2026-10-16T00:00", calendar: calendar)!; friday.allDay = true
        let fri = VoiceIntentCardText.detail(.event(friday), now: now, calendar: calendar, russian: true)
        check(fri.contains("16") && fri.hasSuffix("весь день"), "день недели и «весь день»: \(fri)")
        var guessed = event; guessed.timeGuessed = true; guessed.minutes = 90
        equal(VoiceIntentCardText.detail(.event(guessed), now: now, calendar: calendar, russian: true),
              "Событие · завтра 15:00 · 1 ч 30 мин · время не названо")
        let mail = VoiceIntentMail(recipient: "Пете", draft: MeetingEmailDraft(subject: "О переносе релиза",
                                                                               body: "Релиз переносим на пятницу.\nДетали позже."))
        equal(VoiceIntentCardText.headline(.mail(mail), russian: true), "Письмо Пете: О переносе релиза")
        equal(VoiceIntentCardText.detail(.mail(mail), russian: true), "Релиз переносим на пятницу.")
        equal(VoiceIntentCardText.openTitle(.mail(mail), russian: true), "Открыть в Почте")
        let anon = VoiceIntentMail(recipient: "", draft: MeetingEmailDraft(subject: "Report", body: "Report"))
        equal(VoiceIntentCardText.headline(.mail(anon), russian: false), "Email: Report")
        equal(VoiceIntentCardText.detail(.mail(anon), russian: false), "draft, add the address yourself")
    }

    // MARK: .ics
    do {
        let start = VoiceIntentPlan.parseLocal("2026-10-12T15:00", calendar: calendar)!
        let event = VoiceIntentEvent(title: "Встреча; бюджет, Q4", start: start, minutes: 60, notes: "«создай встречу»",
                                     uid: "abc-1@mostik-intent")
        let ics = VoiceIntentICS.render(event, now: now, calendar: calendar)
        check(ics.contains("DTSTART:20261012T120000Z\r\n") && ics.contains("DTEND:20261012T130000Z\r\n"), "время в UTC")
        check(ics.contains("SUMMARY:Встреча\\; бюджет\\, Q4"), "экранирование")
        check(!ics.contains("VALARM"), "у события сигнала нет")
        check(ics.hasSuffix("END:VCALENDAR\r\n"))
        var reminder = event; reminder.reminder = true
        check(VoiceIntentICS.render(reminder, now: now, calendar: calendar).contains("BEGIN:VALARM\r\nACTION:DISPLAY"), "сигнал")
        var allDay = event; allDay.allDay = true
        allDay.start = VoiceIntentPlan.parseLocal("2026-10-16T00:00", calendar: calendar)!
        let day = VoiceIntentICS.render(allDay, now: now, calendar: calendar)
        check(day.contains("DTSTART;VALUE=DATE:20261016\r\n") && day.contains("DTEND;VALUE=DATE:20261017\r\n"), "весь день")
        equal(VoiceIntentICS.fileName(event), "mostik-abc-1.ics")
        var evil = event; evil.uid = "../../etc/x@y"
        equal(VoiceIntentICS.fileName(evil), "mostik-etcx.ics", "путь из uid не уходит в имя файла")
    }

    // MARK: команда движку
    let command = EngineCodec.command("intent", id: 4, fields: ["text": .string("создай встречу"),
                                                                 "now": .string(VoiceIntentPlan.localStamp(now, calendar: calendar)),
                                                                 "backend": .string("mlx")])
    check(command.contains(#""cmd":"intent""#) && command.contains("2026-10-11T17:20"), "команда intent")
}
