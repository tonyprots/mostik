import Foundation
import MostikCore

/// ИИ встреч (M5–M7): разбор `notes.json`, разорванная связь пометок, номера реплик, политика согласия.
func runMeetingAITests() {
    // notes.json: два режима, задачи с метками говорящих и «группой».
    do {
        let json = #"""
        {"version": 1, "last_mode": "brief", "modes": {
          "detailed": {"status": "done", "overview": "Итог.", "backend": "claude", "model": "sonnet", "seconds": 14.2,
            "calls": 1, "chunks": 1, "coverage": 1.0,
            "points": [{"text": "Решили сдвинуть релиз", "refs": [3, 4]}, {"text": "  ", "refs": []}],
            "notes": [{"mark_index": 0, "at": 26.0, "mark": "паракит", "text": "Собеседник 1: «паракит» в каждой третьей записи.",
                       "refs": [1, 2], "kept": false, "fallback": false}],
            "tasks": [
              {"text": "Добавить термины", "owner": "Я", "assignee": "Собеседник 1", "assignee_kind": "speaker", "due": "до среды", "refs": [7]},
              {"text": "Провести ретро", "owner": "Я", "assignee": null, "assignee_kind": "group", "due": null, "refs": [38]},
              {"text": "Посчитать бюджет", "owner": null, "assignee": null, "assignee_kind": "none", "refs": []}
            ]},
          "brief": {"status": "failed", "error": "нет связи", "overview": "", "points": [], "notes": [], "tasks": []}
        }}
        """#
        guard let file = MeetingAIFile.parse(Data(json.utf8)) else { check(false, "notes.json не разобран"); return }
        equal(file.lastMode, .brief)
        let detailed = file.results[.detailed]
        equal(detailed?.status, .done)
        equal(detailed?.points.count, 1, "пустой пункт выброшен")
        equal(detailed?.points.first?.refs, [3, 4])
        equal(detailed?.notes.first?.refs, [1, 2])
        equal(detailed?.tasks.map(\.assignee), [.speaker("Собеседник 1"), .group, .none])
        equal(detailed?.tasks.first?.due, "до среды")
        equal(detailed?.tasks.last?.owner, nil)
        equal(detailed?.model, "sonnet")
        check(detailed?.usable == true)
        equal(file.results[.brief]?.status, .failed)
        equal(file.results[.brief]?.error, "нет связи")
        check(file.results[.brief]?.usable == false, "провал не показывается как сводка")
        check(MeetingAIFile.parse(Data("{}".utf8)) == nil, "без modes — нет файла")
        check(MeetingAIFile.parse(Data("мусор".utf8)) == nil)
    }

    // Связь заметки с пометкой: правка пометки после обработки рвёт связь (M5).
    do {
        let note = MeetingAINote(markIndex: 1, at: 190, mark: "Мониторы — до пятницы", text: "…", refs: [16])
        let same = [MeetingAIMark(at: 26, text: "паракит"), MeetingAIMark(at: 190, text: "Мониторы  —  до пятницы")]
        check(!MeetingAILink.isStale(note, marks: same), "пробелы не рвут связь")
        let edited = [MeetingAIMark(at: 26, text: "паракит"), MeetingAIMark(at: 190, text: "Мониторы — до четверга")]
        check(MeetingAILink.isStale(note, marks: edited), "правка рвёт связь")
        check(MeetingAILink.isStale(note, marks: [same[0]]), "пометку убрали — связь разорвана")
    }

    // Номер реплики → строка интерфейса: пометки в нумерации реплик не участвуют.
    do {
        let isMark = [false, true, false, false, true, false]
        equal(MeetingAILink.line(forTurn: 0, isMark: isMark), 0)
        equal(MeetingAILink.line(forTurn: 1, isMark: isMark), 2)
        equal(MeetingAILink.line(forTurn: 3, isMark: isMark), 5)
        equal(MeetingAILink.line(forTurn: 4, isMark: isMark), nil, "за концом")
        equal(MeetingAILink.line(forTurn: -1, isMark: isMark), nil)
    }

    // Правка пометки в transcript.json и transcript.md: нумерация по времени, как у движка.
    do {
        let transcript = #"{"marks": [{"at": 190.0, "text": "Мониторы"}, {"at": 26.0, "text": "паракит"}], "turns": []}"#
        let data = Data(transcript.utf8)
        equal(MeetingAILink.marks(transcriptJSON: data).map(\.text), ["паракит", "Мониторы"])
        guard let updated = MeetingAILink.replacingMark(in: data, index: 1, text: "  Мониторы —  до четверга ") else {
            check(false, "пометка не заменена"); return
        }
        equal(MeetingAILink.marks(transcriptJSON: updated).map(\.text), ["паракит", "Мониторы — до четверга"])
        check(MeetingAILink.replacingMark(in: data, index: 5, text: "x") == nil, "нет такой пометки")
        check(MeetingAILink.replacingMark(in: data, index: 0, text: "  ") == nil, "пустой текст")
        let md = "# Встреча\n\n> 📌 00:26 — паракит\n\n**Я** [00:30] текст\n\n> 📌 03:10 — Мониторы\n"
        let patched = MeetingAILink.replacingMark(inMarkdown: md, old: "Мониторы", new: "Мониторы — до четверга")
        check(patched.contains("> 📌 03:10 — Мониторы — до четверга"), "строка пометки в md")
        check(patched.contains("> 📌 00:26 — паракит"), "соседняя пометка не тронута")
        equal(MeetingAILink.replacingMark(inMarkdown: md, old: "нет такой", new: "x"), md)
    }

    // Политика: бэкенд как у причёсывания, согласие своё; по умолчанию выключено.
    do {
        var s = MostikSettings()
        check(!s.meetingAIConsent, "согласие по умолчанию выключено")
        equal(MeetingAIPolicy.gate(s), .noBackend)
        s.polish.backend = .claude
        equal(MeetingAIPolicy.gate(s), .noBackend, "claude без облачного согласия — как выключено")
        s.polish.cloudConsent = true
        equal(MeetingAIPolicy.gate(s), .needsConsent(.claude), "согласие на причёсывание не заменяет согласие встреч")
        check(!MeetingAIPolicy.autoRun(s), "без согласия сам не запускается")
        s.meetingAIConsent = true
        equal(MeetingAIPolicy.gate(s), .needsConsent(.claude), "облаку нужно своё облачное согласие")
        s.grantMeetingAI()
        equal(MeetingAIPolicy.gate(s), .ready(.claude))
        check(MeetingAIPolicy.autoRun(s))
        s.polish.backend = .mlx
        equal(MeetingAIPolicy.gate(s), .ready(.mlx))
        s.polish.backend = .off
        check(!MeetingAIPolicy.autoRun(s), "без бэкенда не запускается")
    }

    // Протокол: meeting_ai_done — ответ на команду с тем же id.
    do {
        let line = #"{"event": "meeting_ai_done", "ok": true, "id": 41, "status": "done", "mode": "brief", "notes": 1}"#
        if case let .reply(id, ok, payload)? = EngineCodec.decode(line: line) {
            equal(id, 41); check(ok); equal(payload["status"]?.stringValue, "done")
        } else { check(false, "meeting_ai_done не разобран как ответ") }
        check(EngineCodec.decode(line: #"{"event": "meeting_ai_done", "status": "done"}"#) == nil, "без id — не ответ")
        if case let .progress(task, stage, _, _, _)? = EngineCodec.decode(line: #"{"event": "progress", "task": "meeting_ai", "stage": "Сводка: часть 2 из 4", "done": 1, "total": 5}"#) {
            equal(task, "meeting_ai"); equal(stage, "Сводка: часть 2 из 4")
        } else { check(false, "progress ИИ встречи") }
    }

    // Шаблоны, виды сводки и следующие шаги (M16, M17, W8, W22, W23, W25) — MeetingSummaryTests.swift.
    runMeetingSummaryTests()
    runMeetingTaskEditTests()
}

/// Задачи в окне встречи: сделано, правка, удаление пишутся в `notes.json`, номера — как в разборе.
func runMeetingTaskEditTests() {
    let json = """
    {"last_mode": "detailed", "modes": {"detailed": {"status": "ok", "overview": "о", "points": [],
     "tasks": [{"text": "  "}, {"text": "Купить муку", "due": "завтра"}, {"text": "Испечь пирог"}]}},
     "variants": {"exec": {"status": "ok", "mode": "brief", "tasks": [{"text": "Позвонить"}]}}}
    """
    let data = Data(json.utf8)
    let main = MeetingAITaskPlace.mode(.detailed)
    equal(MeetingAIFile.parse(data)?.results[.detailed]?.tasks.map(\.text) ?? [], ["Купить муку", "Испечь пирог"],
          "задачи: пустая выброшена при разборе")

    let done = MeetingAITaskEdit.done(true).applied(to: data, place: main, index: 1)
    let doneTasks = done.flatMap(MeetingAIFile.parse)?.results[.detailed]?.tasks ?? []
    equal(doneTasks.map(\.done), [false, true], "задачи: отметка ложится на задачу по номеру из разбора")

    let renamed = MeetingAITaskEdit.text(" Купить две пачки муки ").applied(to: data, place: main, index: 0)
    let renamedTasks = renamed.flatMap(MeetingAIFile.parse)?.results[.detailed]?.tasks ?? []
    equal(renamedTasks.first?.text, "Купить две пачки муки", "задачи: новый текст без пробелов по краям")
    equal(renamedTasks.first?.due, "завтра", "задачи: срок при правке текста остаётся")
    check(MeetingAITaskEdit.text("   ").applied(to: data, place: main, index: 0) == nil, "задачи: пустой текст не пишется")

    let deleted = MeetingAITaskEdit.delete.applied(to: data, place: main, index: 0)
    equal(deleted.flatMap(MeetingAIFile.parse)?.results[.detailed]?.tasks.map(\.text) ?? [], ["Испечь пирог"],
          "задачи: удалена именно выбранная")

    let variant = MeetingAITaskEdit.done(true).applied(to: data, place: .variant("exec"), index: 0)
    let parsed = variant.flatMap(MeetingAIFile.parse)
    equal(parsed?.variants["exec"]?.tasks.first?.done, true, "задачи: правка вида сводки — в его задачах")
    equal(parsed?.results[.detailed]?.tasks.map(\.done) ?? [], [false, false], "задачи: основная сводка не тронута")
    check(MeetingAITaskEdit.delete.applied(to: data, place: main, index: 5) == nil, "задачи: чужой номер — без записи")

    // Сделанные в «Следующих шагах» не идут в трекер и не попадают в «Открытые поручения».
    let result = done.flatMap(MeetingAIFile.parse)!.results[.detailed]!
    let steps = MeetingNextSteps.build(result: result, title: "Пирог", started: Date(timeIntervalSince1970: 0),
                                       meetingID: "m", russian: true)
    equal(steps.tasks.map(\.include), [true, false], "задачи: сделанная снята в черновике для трекера")
    check(!steps.event.notes.contains("Испечь пирог"), "задачи: сделанной нет в открытых поручениях")
}
