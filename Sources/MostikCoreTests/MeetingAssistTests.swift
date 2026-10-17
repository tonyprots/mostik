import Foundation
import MostikCore

/// П7: вопросы по ходу встречи (M19), подсказки (M9), кадры окна звонка (W26). Данные и картинки синтетические.
func runMeetingAssistTests() {
    // MARK: настройки — умолчания, старый файл, битый шаг
    do {
        let old = try? JSONDecoder().decode(MostikSettings.self, from: Data(#"{"language":"ru"}"#.utf8))
        equal(old?.meetingAssist, MeetingAssistSettings(), "без поля — умолчания")
        check(old?.meetingAssist.hints == false, "подсказки выключены по умолчанию")
        check(old?.meetingAssist.questions == true, "журнал вопросов включён: локально и без новой модели")
        let bad = try? JSONDecoder().decode(MeetingAssistSettings.self, from: Data(#"{"frameInterval":1}"#.utf8))
        equal(bad?.frameInterval, MeetingAssistSettings.defaultFrameInterval, "шаг вне списка — по умолчанию")
        var s = MostikSettings()
        s.meetingAssist.hints = true
        s.meetingAssist.frameInterval = 20
        let back = (try? JSONEncoder().encode(s)).flatMap { try? JSONDecoder().decode(MostikSettings.self, from: $0) }
        equal(back?.meetingAssist.hints, true)
        equal(back?.meetingAssist.frameInterval, 20)
        // Согласия на кадры в настройках нет вовсе — оно не может «запомниться» между встречами.
        let keys = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(MeetingAssistSettings()))) as? [String: Any]
        check(keys?.keys.contains { $0.lowercased().contains("consent") || $0.lowercased().contains("frames") } == false,
              "в настройках нет согласия на кадры")
    }

    // MARK: M19 — журнал из ответа движка и из файла
    do {
        let reply: JSONValue = .array([
            .object(["id": .string("q1"), "at": .number(12), "track": .string("system"),
                     "text": .string("Сколько стоит лицензия?"), "status": .string("pending"), "layer": .string("judge")]),
            .object(["id": .string("q2"), "at": .number(5), "track": .string("mic"), "text": .string("Кто возьмёт?"),
                     "status": .string("answered"), "answer": .string("Я возьму."), "answered_by": .string("Борис")]),
            .object(["text": .string("без id")]),
        ])
        let list = MeetingQuestion.list(reply)
        equal(list.map(\.id), ["q1", "q2"], "битый элемент пропущен")
        equal(list[0].layer, "judge")
        equal(list[1].status, .answered)
        let merged = MeetingQuestion.merge(list, [MeetingQuestion(id: "q1", at: 12, track: "system", text: "Сколько стоит лицензия?",
                                                                  status: .unanswered)])
        equal(merged.map(\.id), ["q2", "q1"], "по времени")
        equal(merged.last?.status, .unanswered, "обновление по id")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mostik-assist-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = #"{"schema":"mostik.questions","version":1,"items":[{"id":"q1","at":3,"track":"system","text":"Когда релиз?","status":"unanswered"}]}"#
        try? file.write(to: dir.appendingPathComponent(MeetingQuestion.fileName), atomically: true, encoding: .utf8)
        equal(MeetingQuestion.load(folder: dir).first?.status, .unanswered)
        equal(MeetingQuestion.load(folder: dir.appendingPathComponent("нет")), [], "нет файла — пусто")
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: M9 — подсказка: разбор ответа, подписи, частота, кому
    do {
        let payload: [String: JSONValue] = [
            "status": .string("found"), "question": .string("Сколько стоит лицензия?"),
            "snippet": .string("Одна лицензия стоит 2100 долларов в месяц."),
            "source": .object(["kind": .string("source"), "title": .string("notes/licenses.md · Бюджет"),
                               "path": .string("/tmp/notes/licenses.md"), "line": .number(3)]),
            "more": .array([.object(["title": .string("Синк по бюджету")])]),
            "glossary": .array([.object(["term": .string("A100"), "path": .string("/tmp/repo/README.md"), "line": .number(7)])]),
        ]
        let hint = MeetingHint(id: "q1", payload: payload)
        equal(hint?.kind, .source)
        equal(hint?.sourceLabel, "licenses.md:3")
        equal(hint?.more, ["Синк по бюджету", "A100 — README.md:7"])
        check(hint?.answer == nil, "без модели — только фрагмент")
        let meeting = MeetingHint(id: "q2", payload: ["status": .string("found"), "question": .string("?"),
                                                      "source": .object(["kind": .string("meeting"), "title": .string("Синк"),
                                                                         "meeting": .string("2026-10-01-100000"), "at": .number(754)])])
        equal(meeting?.sourceLabel, "Синк · 12:34")
        let glossary = MeetingHint(id: "q3", payload: ["status": .string("found"), "question": .string("?"),
                                                       "glossary": .array([.object(["term": .string("PaymentGateway"),
                                                                                    "path": .string("/r/README.md"), "line": .number(3)])])])
        equal(glossary?.kind, .glossary)
        equal(glossary?.sourceLabel, "README.md:3")
        check(MeetingHint(id: "q4", payload: ["status": .string("none")]) == nil, "ничего не нашлось — карточки нет")

        var throttle = HintThrottle()
        check(throttle.allows(at: 100))
        throttle.shown(at: 100)
        check(!throttle.allows(at: 119.9), "не чаще одной за 20 с")
        check(throttle.allows(at: 120))

        // Открытые вопросы — выше отвеченных, порядок внутри группы сохраняется.
        var asked = [MeetingQuestion(id: "a", at: 1, track: "system", text: "1"),
                     MeetingQuestion(id: "b", at: 2, track: "system", text: "2"),
                     MeetingQuestion(id: "c", at: 3, track: "system", text: "3"),
                     MeetingQuestion(id: "d", at: 4, track: "system", text: "4")]
        asked[0].status = .answered; asked[1].status = .unanswered; asked[2].status = .answered; asked[3].status = .pending
        equal(MeetingQuestion.openFirst(asked).map(\.id), ["b", "d", "a", "c"], "сначала открытые, потом отвеченные")

        var settings = MeetingAssistSettings()
        let theirs = MeetingQuestion(id: "q", at: 1, track: "system", text: "Когда?")
        let mine = MeetingQuestion(id: "m", at: 1, track: "mic", text: "Когда?")
        check(!HintPolicy.wants(theirs, settings: settings, recording: true), "выключено по умолчанию")
        settings.hints = true
        check(HintPolicy.wants(theirs, settings: settings, recording: true))
        check(!HintPolicy.wants(mine, settings: settings, recording: true), "на свой вопрос подсказка не нужна")
        check(!HintPolicy.wants(theirs, settings: settings, recording: false), "только во время записи встречи")
    }

    // MARK: W26 — когда снимать
    do {
        equal(FrameDecision.decide(consent: false, textOnly: false, permission: true), .noConsent, "без согласия — никогда")
        equal(FrameDecision.decide(consent: true, textOnly: true, permission: true), .textOnly)
        equal(FrameDecision.decide(consent: true, textOnly: false, permission: false), .noPermission)
        equal(FrameDecision.decide(consent: true, textOnly: false, permission: true), .capture)
        equal(FrameDelta.fileName(at: 754.9), "001234.jpg")
        equal(FrameDelta.fileName(at: 3725), "010205.jpg")
    }

    // MARK: W26 — дельта кадра на синтетических картинках 64×36
    do {
        let cells = 64 * 36
        // «Слайд»: светлый фон и тёмные строки текста; второй слайд — строки в других местах.
        func slide(_ seed: Int) -> [UInt8] {
            (0..<cells).map { i in
                let row = i / 64
                return (row + seed) % 6 == 0 && (i % 64) > 6 && (i % 64) < 50 ? 40 : 235
            }
        }
        var rng = SystemRandomNumberGenerator()
        func noisy(_ base: [UInt8], amount: Int) -> [UInt8] {
            base.map { UInt8(max(0, min(255, Int($0) + Int.random(in: -amount...amount, using: &rng)))) }
        }
        // Окошко видео в углу слайда (10 × 8 ячеек ≈ 3,5 % кадра) — каждый раз новое.
        func withVideo(_ base: [UInt8]) -> [UInt8] {
            var copy = base
            for row in 0..<8 { for col in 54..<64 { copy[row * 64 + col] = UInt8.random(in: 0...255, using: &rng) } }
            return copy
        }
        let a = slide(0), b = slide(3)
        check(FrameDelta.difference(a, a) == 0)
        check(FrameDelta.difference(a, b) >= FrameDelta.changed, "смена слайда — заметная")
        check(FrameDelta.difference(a, noisy(a, amount: 10)) <= FrameDelta.stable, "шум сжатия — не смена")
        check(FrameDelta.difference(a, [1, 2, 3]) == 1, "разный размер — всё другое")

        var delta = FrameDelta()
        check(!delta.observe(a), "первый взгляд — ещё неизвестно, устоялся ли кадр")
        check(delta.observe(withVideo(a)), "слайд стоит, рядом идёт видео — сохраняем")
        check(!delta.observe(withVideo(noisy(a, amount: 8))), "тот же слайд — не сохраняем снова")
        check(!delta.observe(b), "новый слайд только появился — ждём, что устоится")
        check(delta.observe(withVideo(b)), "новый слайд устоялся — сохраняем")
        equal(delta.count, 2)

        // Видео на весь кадр (лица): меняется на каждом взгляде — ни одного кадра.
        var video = FrameDelta()
        var saved = 0
        for _ in 0..<20 where video.observe((0..<cells).map { _ in UInt8.random(in: 0...255, using: &rng) }) { saved += 1 }
        equal(saved, 0, "видео лиц не снимается")

        var capped = FrameDelta()
        var total = 0
        for i in 0..<(FrameDelta.maxFrames * 2 + 10) {
            let frame = (i / 2) % 2 == 0 ? a : b  // слайды по очереди, каждый виден дважды подряд
            if capped.observe(frame) { total += 1 }
        }
        equal(total, FrameDelta.maxFrames, "не больше \(FrameDelta.maxFrames) кадров за встречу")
    }
}

/// П10, низкий: кадр, снятый до пометки «чувствительная», не появляется в папке после неё.
func runFrameRaceTests() {
    let fm = FileManager.default
    func meeting() -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("mostik-frame-race-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        MeetingFolder.update(dir, ["title": "Синк"])
        return dir
    }
    func frameURL(_ folder: URL) -> URL {
        folder.appendingPathComponent(FrameDelta.folderName, isDirectory: true).appendingPathComponent(FrameDelta.fileName(at: 90))
    }
    func jpeg(_ url: URL) -> Bool {
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return fm.createFile(atPath: url.path, contents: Data([0xFF, 0xD8]))
    }
    // Обычная встреча: кадр и текст на месте.
    do {
        let folder = meeting(); defer { try? fm.removeItem(at: folder) }
        let url = frameURL(folder)
        check(FrameStore.save(to: url, write: jpeg, ocr: { _ in "слайд" }))
        check(fm.fileExists(atPath: url.path)); check(fm.fileExists(atPath: ImageOCR_sidecar(url).path))
    }
    // «Только на этом Mac»: кадр тоже сохраняется — дальше Mac его не пускает движок.
    do {
        let folder = meeting(); defer { try? fm.removeItem(at: folder) }
        MeetingFolder.setSensitive(folder, true)
        let url = frameURL(folder)
        check(FrameStore.save(to: url, write: jpeg, ocr: { _ in "зарплаты" }), "кадр помеченной встречи пишется")
        check(fm.fileExists(atPath: ImageOCR_sidecar(url).path), "и текст кадра рядом")
        equal(FrameDecision.decide(consent: true, textOnly: false, permission: true), .capture,
              "пометка снимок не запрещает — только согласие, «только текст» и разрешение")
    }
    // Запись не удалась — текст не пишем.
    do {
        let folder = meeting(); defer { try? fm.removeItem(at: folder) }
        let url = frameURL(folder)
        check(!FrameStore.save(to: url, write: { _ in false }, ocr: { _ in "слайд" }))
        check(!fm.fileExists(atPath: ImageOCR_sidecar(url).path))
    }
}

private func ImageOCR_sidecar(_ url: URL) -> URL { FrameStore.sidecar(for: url) }
