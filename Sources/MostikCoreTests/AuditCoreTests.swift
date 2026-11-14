import Foundation
import MostikCore

/// Ревью 2026-11-14 (ядро и безопасность): по тесту на каждую исправленную находку. Номера — из отчёта.
func runAuditCoreTests() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("mostik-audit-\(UUID().uuidString)", isDirectory: true)
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let utc = TimeZone(identifier: "UTC")!
    let msk = TimeZone(identifier: "Europe/Moscow")!
    let iso = ISO8601DateFormatter()
    func d(_ s: String) -> Date { iso.date(from: s)! }
    func days(_ dates: [Date], _ tz: TimeZone) -> [String] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "MM-dd HH:mm"
        return dates.map(f.string(from:))
    }
    func wrap(_ body: String) -> String {
        "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n" + body + "END:VCALENDAR\r\n"
    }

    // MARK: 1 — одно поле неверного типа не обнуляет настройки
    do {
        func decode(_ json: String) -> MostikSettings? { MostikSettings.decode(Data(json.utf8)) }
        let a = decode(#"{"onboarded": true, "retentionDays": "7", "language": "en"}"#)
        equal(a?.onboarded, true, "строка вместо числа — остальное читается")
        equal(a?.retentionDays, 7, "а поле — умолчание")
        equal(a?.language, "en")
        equal(decode(#"{"onboarded": true, "retentionDays": 7.5}"#)?.onboarded, true, "дробное число")
        let b = decode(#"{"onboarded": true, "launchAtLogin": "yes", "meetingAIConsent": true}"#)
        equal(b?.onboarded, true, "строка вместо Bool")
        equal(b?.launchAtLogin, true, "умолчание поля")
        equal(b?.meetingAIConsent, true, "согласие не потеряно")
        // agentPolicy без одного ключа: список из standard, свои правки на месте.
        let c = decode(#"{"onboarded": true, "agentPolicy": {"terminals": ["x.term"], "forcedOff": ["a.b"]}}"#)
        equal(c?.onboarded, true, "неполный agentPolicy не роняет файл")
        equal(c?.agentPolicy.terminals, ["x.term"])
        equal(c?.agentPolicy.forcedOff, ["a.b"])
        equal(c?.agentPolicy.browserTitleMarkers, AgentAppPolicy.standard.browserTitleMarkers, "нет ключа — standard")
        // Блок agentVoice: одно поле не того типа не сбрасывает соседние.
        let v = decode(#"{"agentVoice": {"tmuxPaste": true, "tmuxTarget": 3, "voiceSend": true}}"#)
        equal(v?.agentVoice.tmuxPaste, true, "tmuxPaste остался")
        equal(v?.agentVoice.voiceSend, true)
        equal(v?.agentVoice.tmuxTarget, TmuxTargeting.auto, "tmuxTarget — умолчание")
        // Без согласия память по-прежнему не включается.
        equal(decode(#"{"voiceMemory": true, "voiceMemoryConsent": "да"}"#)?.voiceMemory, false)

        // Файл не разобрался вовсе: копия рядом, запись умолчаний её не стирает.
        let url = root.appendingPathComponent("settings.json")
        let broken = Data(#"{"onboarded": true, "meetingAIConsent": tr"#.utf8)
        try? broken.write(to: url)
        let loaded = MostikSettings.load(from: url)
        equal(loaded, MostikSettings(), "неразобранный файл — умолчания в памяти")
        let bad = MostikSettings.badCopyURL(url)
        equal(bad.lastPathComponent, "settings.json.bad")
        equal(try? Data(contentsOf: bad), broken, "копия при чтении")
        try? fm.removeItem(at: bad)
        try? loaded.save(to: url)
        equal(try? Data(contentsOf: bad), broken, "запись поверх битого файла — тоже с копией")
        check(MostikSettings.decode((try? Data(contentsOf: url)) ?? Data()) != nil, "новый файл читается")
        // Целый файл копию не плодит.
        try? fm.removeItem(at: bad)
        try? loaded.save(to: url)
        _ = MostikSettings.load(from: url)
        check(!fm.fileExists(atPath: bad.path), "у целого файла копии нет")
    }

    // MARK: 2 — выключенные сводки действуют и на встречи «Только на этом Mac»
    do {
        var s = MostikSettings()
        s.polish = PolishSettings(backend: .claude, cloudConsent: true)
        check(!s.meetingAIConsent)
        equal(MeetingAIPolicy.gate(s, sensitive: true, localModel: true), .needsConsent(.mlx), "без согласия — спросить")
        check(!MeetingAIPolicy.autoRun(s, sensitive: true, localModel: true), "автосводка не уходит")
        equal(MeetingAIPolicy.gate(s, sensitive: true, localModel: false), .sensitiveCloud, "без модели — как было")
        s.grantMeetingAI()
        equal(MeetingAIPolicy.gate(s, sensitive: true, localModel: true), .ready(.mlx), "с согласием — локальная модель")
        s.revokeMeetingAI()
        equal(MeetingAIPolicy.gate(s, sensitive: true, localModel: true), .needsConsent(.mlx), "после отзыва — снова спросить")
    }

    // MARK: 3 — сбой во время «Продолжить запись»: новая часть расшифровывается
    do {
        typealias S = MeetingFolder.Summary
        equal(MeetingRecovery.decide(summary: S(recording: "recording", transcript: "done", transcriptAttempts: 1),
                                     hasAudio: true, hasTranscript: true, isRecordingNow: false),
              .transcribe(markIncomplete: true), "дозаписанное — в очередь")
        equal(MeetingRecovery.decide(summary: S(recording: "recording", transcript: "done", audioKept: false),
                                     hasAudio: true, hasTranscript: true, isRecordingNow: false),
              .giveUp(markIncomplete: true), "звук убран — только пометка")
        equal(MeetingRecovery.decide(summary: S(recording: "recording", transcript: "done", transcriptAttempts: 2),
                                     hasAudio: true, hasTranscript: true, isRecordingNow: false),
              .giveUp(markIncomplete: true), "попытки кончились — без зацикливания")
        equal(MeetingRecovery.decide(summary: S(recording: "recording", transcript: "done"),
                                     hasAudio: true, hasTranscript: true, isRecordingNow: true), .none, "пишем сейчас")
        equal(MeetingRecovery.decide(summary: S(recording: "complete", transcript: "done"),
                                     hasAudio: true, hasTranscript: true, isRecordingNow: false), .none, "целая встреча не гоняется")
    }

    // MARK: 4 — «звук стёрт» не пишется, если стереть не удалось
    do {
        func wav(seconds: Double) -> Data {
            Data(count: 44) + Data(repeating: 0x11, count: Int(seconds * Double(LivePCM.sampleRate)) * 2)
        }
        func meeting(_ name: String, whole: Bool) -> URL {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try? wav(seconds: 4).write(to: folder.appendingPathComponent("mic.wav"))
            MeetingFolder.update(folder, ["text_only": TextOnlyRanges.manifestValue([.init(start: 1, end: 2)], whole: whole),
                                          "transcript": ["status": "done"]])
            return folder
        }
        // Часть встречи, файл только для чтения.
        let part = meeting("2026-11-14-100000", whole: false)
        let mic = part.appendingPathComponent("mic.wav")
        try? fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: mic.path)
        equal(TextOnlyAudio.purge(part), .incomplete, "файл не открылся на запись")
        check(TextOnlyAudio.needsPurge(MeetingFolder.readManifest(part)), "повтор остаётся нужным")
        check((MeetingFolder.readManifest(part)?["text_only"] as? [String: Any])?["silenced_at"] == nil, "silenced_at не записан")
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: mic.path)
        equal(TextOnlyAudio.purge(part), .silenced, "права вернули — стёрто")
        check(!TextOnlyAudio.needsPurge(MeetingFolder.readManifest(part)))
        // Вся встреча, файл не удаляется: манифест пишется (сама папка открыта), а запись удалить нельзя.
        let whole = meeting("2026-11-14-110000", whole: true)
        let locked = whole.appendingPathComponent("mic.wav")
        // Флаг «неизменяемый» запрещает удаление, не мешая писать соседние файлы.
        if (try? fm.setAttributes([.immutable: true], ofItemAtPath: locked.path)) != nil {
            equal(TextOnlyAudio.purge(whole), .incomplete, "файл не удалился")
            let manifest = MeetingFolder.readManifest(whole)
            check((manifest?["audio"] as? [String: Any])?["kept"] as? Bool != false, "kept=false не записан")
            check(TextOnlyAudio.needsPurge(manifest), "повтор нужен")
            try? fm.setAttributes([.immutable: false], ofItemAtPath: locked.path)
            equal(TextOnlyAudio.purge(whole), .removed(["mic.wav"]))
            check(!TextOnlyAudio.needsPurge(MeetingFolder.readManifest(whole)))
        } else {
            check(false, "не удалось поставить флаг immutable — ветка whole не проверена")
        }
    }

    // MARK: 12 — нечитаемый манифест не заменяется базовым
    do {
        let folder = root.appendingPathComponent("2026-11-14-120000", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        MeetingFolder.update(folder, ["title": "Планёрка", "sensitive": true, "transcript": ["status": "done"]])
        let url = MeetingFolder.manifestURL(folder)
        let full = (try? Data(contentsOf: url)) ?? Data()
        let cut = full.dropLast(5)
        try? Data(cut).write(to: url)
        check(MeetingFolder.readManifest(folder) == nil, "обрезанный манифест не читается")
        let result = MeetingFolder.update(folder, ["summary": ["status": "done"]])
        check(result.isEmpty, "запись не выполнена")
        equal(try? Data(contentsOf: url), Data(cut), "файл не тронут")
        equal(try? Data(contentsOf: folder.appendingPathComponent("manifest.json.bad")), Data(cut), "копия .bad")
        // Починили файл руками — пометка и название на месте.
        try? full.write(to: url)
        MeetingFolder.update(folder, ["summary": ["status": "done"]])
        equal(MeetingFolder.summary(folder)?.sensitive, true, "«Только на этом Mac» не потеряно")
        equal(MeetingFolder.summary(folder)?.title, "Планёрка")
        // Пустой файл (оборванное создание) — как отсутствующий.
        let empty = root.appendingPathComponent("2026-11-14-130000", isDirectory: true)
        try? fm.createDirectory(at: empty, withIntermediateDirectories: true)
        try? Data().write(to: MeetingFolder.manifestURL(empty))
        check(!MeetingFolder.update(empty, ["title": "Новая"]).isEmpty)
        equal(MeetingFolder.summary(empty)?.title, "Новая")
    }

    // MARK: 10 — NaN в буфере не ломает индикатор уровня
    do {
        var meter = LevelMeter(sampleRate: 16_000)
        var quiet = [Float](repeating: 0.0001, count: 1600)
        for _ in 0..<5 { _ = meter.level(quiet, count: quiet.count, sampleRate: 16_000) }
        quiet[800] = .nan
        quiet[801] = .infinity
        let poisoned = meter.level(quiet, count: quiet.count, sampleRate: 16_000)
        check(poisoned.isFinite && poisoned < 1, "буфер с NaN — не полная шкала: \(poisoned)")
        quiet[800] = 0.0001; quiet[801] = 0.0001
        var after: Float = 1
        for _ in 0..<30 { after = meter.level(quiet, count: quiet.count, sampleRate: 16_000) }
        check(after.isFinite && after < 0.5, "тишина после NaN — снова тишина: \(after)")
        check(meter.floor?.isFinite == true, "шумовой пол конечен")
        check(meter.filteredDB(quiet, count: quiet.count).isFinite, "фильтр жив")
        equal(meter.level(db: .nan, dt: 0.1), 0, "нефинитный замер — ноль")
        check(meter.floor?.isFinite == true && meter.ceiling.isFinite, "и состояние не тронуто")
    }

    // MARK: 11 — «send/отправь» не команда
    do {
        let question = "Какую кнопку нажать — Send?"
        equal(VoiceSend.detect(question), VoiceSendResult(text: question, submit: false), "вопрос — не команда")
        equal(VoiceSend.detect("Это точно отправь?").submit, false)
        equal(VoiceSend.detect("Только не — отправь").submit, false, "тире не снимает проверку блокера")
        equal(VoiceSend.detect("Попроси его не: отправь").submit, false, "двоеточие тоже")
        // Прежнее поведение на месте.
        equal(VoiceSend.detect("Поправь тест, отправь."), VoiceSendResult(text: "Поправь тест.", submit: true))
        equal(VoiceSend.detect("Поправь тест — отправь"), VoiceSendResult(text: "Поправь тест", submit: true), "тире перед командой снимается")
        equal(VoiceSend.detect("Напиши письмо и, отправь").submit, true, "запятая — граница фразы")
    }

    // MARK: 13 — число вне Int не роняет разбор
    do {
        equal(SafeInt.clamp(1e20), Int.max)
        equal(SafeInt.clamp(-1e20), Int.min)
        equal(SafeInt.clamp(.nan), 0)
        equal(SafeInt.clamp(.infinity), 0)
        equal(SafeInt.clamp(41.9), 41, "как Int(_): без дробной части")
        equal(SafeInt.clamp(-2.5), -2)
        equal(JSONValue.number(1e300).intValue, Int.max)
        equal(JSONValue.string("7").intValue, nil)
        let event = EngineCodec.decode(line: #"{"event": "progress", "task": "t", "stage": "s", "done": 1e20, "total": -1e30}"#)
        equal(event, .progress(task: "t", stage: "s", done: Int.max, total: Int.min, detail: ""), "progress с огромными числами")
        check(EngineCodec.decode(line: #"{"id": 1e25, "event": "progress", "done": 1, "total": 2}"#) != nil, "огромный id")
        equal(FrameDelta.fileName(at: 1e30).hasSuffix(".jpg"), true, "имя кадра на нелепых секундах")
        equal(FrameDelta.fileName(at: 755), "001235.jpg")
    }

    // MARK: 14 — дозапись после оборванной строки
    do {
        let dir = root.appendingPathComponent("history", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("history.jsonl")
        let store = HistoryStore(fileURL: url)
        try? store.append(HistoryEntry(id: "a", text: "первая"))
        // Прошлый процесс упал посреди записи: обрывок без перевода строки.
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(#"{"id":"обрыв","te"#.utf8))
            try? handle.close()
        }
        try? store.append(HistoryEntry(id: "b", text: "вторая"))
        try? store.append(HistoryEntry(id: "c", text: "третья"))
        equal(store.load().map(\.id), ["c", "b", "a"], "запись после обрывка не потеряна")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        check(!text.contains("\n\n"), "лишних пустых строк нет")
    }

    // MARK: 19 — неполное сомнение не теряет итог диктовки
    do {
        let json = #"{"session": "s", "text": "текст", "doubts": [{"heard": "a", "suggestion": "b"}], "corrections": [{"from": "x"}]}"#
        let result = try? JSONDecoder().decode(DictationResult.self, from: Data(json.utf8))
        equal(result?.text, "текст", "итог разобран")
        equal(result?.doubts, [Doubt(heard: "a", suggestion: "b", context: "", kind: "term")], "умолчания как в init")
        equal(result?.corrections, [Correction(from: "x", to: "")])
        let full = Doubt(heard: "h", suggestion: "s", context: "c", kind: "name")
        equal(try? JSONDecoder().decode(Doubt.self, from: JSONEncoder().encode(full)), full, "полная запись — без потерь")
    }

    // MARK: С1 — INTERVAL без границы не роняет разбор
    do {
        let rule = RRule("FREQ=DAILY;INTERVAL=4611686018427387904")
        equal(rule?.interval, 1000, "потолок интервала")
        let start = ICS.DateValue(date: d("2026-11-01T10:00:00Z"), allDay: false, timeZone: utc)
        equal(rule?.occurrences(start: start, until: d("2026-12-01T00:00:00Z")).count, 1, "только первый экземпляр")
        let text = wrap("BEGIN:VEVENT\r\nUID:big\r\nDTSTART:20261101T100000Z\r\nDTEND:20261101T110000Z\r\n"
            + "RRULE:FREQ=WEEKLY;INTERVAL=4611686018427387904;BYDAY=MO,TU\r\nSUMMARY:x\r\nEND:VEVENT\r\n")
        check(ICS.events(text, from: d("2026-11-01T00:00:00Z"), to: d("2027-11-01T00:00:00Z"), fallback: utc).count <= 3,
              "серия с огромным интервалом разобрана")
        equal(RRule("FREQ=YEARLY;INTERVAL=9223372036854775807")?.occurrences(start: start, until: d("2100-01-01T00:00:00Z")).count,
              1, "годовая: 20 000 шагов × 1000 без переполнения")
        // Длинные списки режутся.
        let many = Array(repeating: "MO", count: 500).joined(separator: ",")
        equal(RRule("FREQ=WEEKLY;BYDAY=" + many)?.byDay.count, 64, "BYDAY не длиннее 64")
        var crowd = "BEGIN:VEVENT\r\nUID:crowd\r\nDTSTART:20261101T100000Z\r\nDTEND:20261101T110000Z\r\nSUMMARY:x\r\n"
        for i in 0..<800 { crowd += "ATTENDEE;CN=P\(i):mailto:p\(i)@x.ru\r\n" }
        crowd += "END:VEVENT\r\n"
        equal(ICS.events(wrap(crowd), from: d("2026-11-01T00:00:00Z"), to: d("2026-11-02T00:00:00Z"), fallback: utc).first?.attendees.count,
              500, "участников не больше 500")
    }

    // MARK: 5 — BYSETPOS
    do {
        let start = ICS.DateValue(date: d("2026-10-30T07:00:00Z"), allDay: false, timeZone: msk)  // пт 30.10, 10:00 мск
        let last = RRule("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1")
        equal(days(last?.occurrences(start: start, from: d("2026-11-01T00:00:00Z"), until: d("2026-12-01T00:00:00Z")) ?? [], msk),
              ["11-30 10:00"], "последний рабочий день ноября — один, а не 21")
        let firstTwo = RRule("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=1,2;COUNT=4")
        let from = ICS.DateValue(date: d("2026-11-02T07:00:00Z"), allDay: false, timeZone: msk)
        equal(days(firstTwo?.occurrences(start: from, until: d("2027-01-01T00:00:00Z")) ?? [], msk),
              ["11-02 10:00", "11-03 10:00", "12-01 10:00", "12-02 10:00"], "первые два рабочих дня")
        // Без BYSETPOS — как раньше.
        equal(RRule("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR")?
            .occurrences(start: from, from: d("2026-11-01T00:00:00Z"), until: d("2026-12-01T00:00:00Z")).count, 21)
    }

    // MARK: 7 — UNTIL датой включает последний день
    do {
        let start = ICS.DateValue(date: d("2026-11-01T07:00:00Z"), allDay: false, timeZone: msk)
        let rule = RRule("FREQ=DAILY;UNTIL=20261105", fallback: utc)
        equal(days(rule?.occurrences(start: start, until: d("2026-12-01T00:00:00Z")) ?? [], msk),
              ["11-01 10:00", "11-02 10:00", "11-03 10:00", "11-04 10:00", "11-05 10:00"], "5.11 входит")
        // UNTIL со временем — как раньше, точным моментом.
        let exact = RRule("FREQ=DAILY;UNTIL=20261103T070000Z")
        equal(exact?.occurrences(start: start, until: d("2026-12-01T00:00:00Z")).count, 3)
        equal(RRule("FREQ=DAILY;UNTIL=20261103T065959Z")?.occurrences(start: start, until: d("2026-12-01T00:00:00Z")).count, 2)
    }

    // MARK: 8, 9 — EXDATE датой, RDATE, WKST
    do {
        let window = (d("2026-11-01T00:00:00Z"), d("2026-11-30T00:00:00Z"))
        func starts(_ body: String) -> [String] {
            days(ICS.events(wrap(body), from: window.0, to: window.1, fallback: msk).map(\.start), msk)
        }
        let head = "BEGIN:VEVENT\r\nUID:s\r\nSUMMARY:x\r\nDTSTART;TZID=Europe/Moscow:20261101T100000\r\nDTEND;TZID=Europe/Moscow:20261101T110000\r\n"
        equal(starts(head + "RRULE:FREQ=DAILY;COUNT=4\r\nEXDATE;VALUE=DATE:20261102\r\nEND:VEVENT\r\n"),
              ["11-01 10:00", "11-03 10:00", "11-04 10:00"], "EXDATE датой снимает день")
        equal(starts(head + "RRULE:FREQ=DAILY;COUNT=4\r\nEXDATE;TZID=Europe/Moscow:20261103T100000\r\nEND:VEVENT\r\n"),
              ["11-01 10:00", "11-02 10:00", "11-04 10:00"], "EXDATE со временем — как раньше")
        equal(starts(head + "RDATE;TZID=Europe/Moscow:20261110T150000\r\nEND:VEVENT\r\n"),
              ["11-01 10:00", "11-10 15:00"], "RDATE без RRULE")
        equal(starts(head + "RRULE:FREQ=DAILY;COUNT=2\r\nRDATE;TZID=Europe/Moscow:20261102T100000,20261110T150000\r\nEND:VEVENT\r\n"),
              ["11-01 10:00", "11-02 10:00", "11-10 15:00"], "RDATE, совпавший с правилом, не двоит встречу")
        // WKST=SU: воскресенье и понедельник — одна неделя.
        let sunday = ICS.DateValue(date: d("2026-11-01T07:00:00Z"), allDay: false, timeZone: msk)
        let until = d("2027-01-01T00:00:00Z")
        equal(days(RRule("FREQ=WEEKLY;INTERVAL=2;WKST=SU;BYDAY=SU,MO;COUNT=4")?.occurrences(start: sunday, until: until) ?? [], msk),
              ["11-01 10:00", "11-02 10:00", "11-15 10:00", "11-16 10:00"], "WKST=SU")
        equal(days(RRule("FREQ=WEEKLY;INTERVAL=2;BYDAY=SU,MO;COUNT=4")?.occurrences(start: sunday, until: until) ?? [], msk),
              ["11-01 10:00", "11-09 10:00", "11-15 10:00", "11-23 10:00"], "по умолчанию неделя с понедельника — как раньше")
    }

    // MARK: 6 — TZID
    do {
        func zone(_ tzid: String) -> String? {
            ICS.property("DTSTART;TZID=\"\(tzid)\":20261116T100000").flatMap { ICS.date($0, fallback: msk) }?.timeZone.identifier
        }
        equal(zone("/mozilla.org/20050126_1/America/Argentina/Buenos_Aires"), "America/Argentina/Buenos_Aires", "хвост из трёх частей")
        equal(zone("/mozilla.org/20050126_1/Europe/Berlin"), "Europe/Berlin", "хвост из двух — как раньше")
        equal(zone("FLE Standard Time"), "Europe/Kiev", "Windows-имя")
        equal(zone("Tokyo Standard Time"), "Asia/Tokyo")
        equal(zone("Russian Standard Time"), "Europe/Moscow")
        let offset = ICS.property("DTSTART;TZID=\"(UTC-05:00) Eastern Time (US & Canada)\":20261116T100000")
            .flatMap { ICS.date($0, fallback: msk) }
        equal(offset?.timeZone.secondsFromGMT(), -5 * 3600, "смещение из имени")
        equal(offset?.date, d("2026-11-16T15:00:00Z"))
        equal(zone("Неизвестный пояс"), "Europe/Moscow", "совсем незнакомое — пояс Mac")
    }

    // MARK: 15 — автоостановка не стартует в первую секунду
    do {
        var late = MeetingAutoStop()
        equal(late.update(now: 105, eventEnd: 100, callActive: false), .none, "запись начата после конца события")
        equal(late.update(now: 200, eventEnd: 100, callActive: false), .none, "и дальше по событию не останавливаем")
        equal(late.deadline, nil)
        _ = late.update(now: 210, eventEnd: 100, callActive: true)
        equal(late.update(now: 220, eventEnd: 100, callActive: false), .stop, "закрытый звонок останавливает по-прежнему")
        var normal = MeetingAutoStop()
        equal(normal.update(now: 10, eventEnd: 100, callActive: false), .none)
        equal(normal.update(now: 101, eventEnd: 100, callActive: false), .started(deadline: 161), "обычная запись — отсчёт")
    }

    // MARK: 18 — контекст не режет суррогатную пару
    do {
        let settings = PolishContextSettings()
        let value = String(repeating: "😀", count: 400)  // 800 единиц UTF-16
        func ctx(_ location: Int, _ length: Int = 0) -> [String: String] {
            PolishContext.make(ContextSource(bundleID: "com.tinyspeck.slackmacgap", value: value,
                                             selection: CaretRange(location: location, length: length)),
                               settings: settings, backend: .mlx) ?? [:]
        }
        for (location, length) in [(599, 0), (601, 3), (1, 0), (799, 0), (300, 1)] {
            let c = ctx(location, length)
            check(!c.values.contains { $0.unicodeScalars.contains("\u{FFFD}") }, "нет U+FFFD при курсоре \(location)+\(length)")
        }
        let c = ctx(599)
        check(c["before"]?.allSatisfy { $0 == "😀" } == true && c["after"]?.allSatisfy { $0 == "😀" } == true, "целые эмодзи")
        // Обычный текст — без изменений.
        let plain = PolishContext.make(ContextSource(bundleID: "com.tinyspeck.slackmacgap", value: "привет, мир",
                                                     selection: CaretRange(location: 7, length: 0)),
                                       settings: settings, backend: .mlx)
        equal(plain?["before"], "привет,")
        equal(plain?["after"], " мир")
    }

    // MARK: 17 — возраст временной папки — по свежему содержимому
    do {
        let tmp = root.appendingPathComponent("tmp", isDirectory: true)
        let now = Date()
        let old = now.addingTimeInterval(-3600)
        for name in ["mostik-tracks-busy", "mostik-tracks-dead"] {
            let dir = tmp.appendingPathComponent(name, isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("mix.wav")
            try? Data([1, 2, 3]).write(to: file)
            if name.hasSuffix("dead") { try? fm.setAttributes([.modificationDate: old], ofItemAtPath: file.path) }
            try? fm.setAttributes([.modificationDate: old], ofItemAtPath: dir.path)
        }
        equal(StorageHygiene.cleanStaleTemp(in: tmp, now: now), ["mostik-tracks-dead"], "папку со свежим файлом не трогаем")
        check(fm.fileExists(atPath: tmp.appendingPathComponent("mostik-tracks-busy/mix.wav").path))
    }

    // MARK: 16 — один срок на команду календаря
    do {
        let dir = root.appendingPathComponent("cal", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        func script(_ name: String, _ body: String) -> String {
            let url = dir.appendingPathComponent(name)
            fm.createFile(atPath: url.path, contents: Data(("#!/bin/sh\n" + body + "\n").utf8), attributes: [.posixPermissions: 0o755])
            return url.path
        }
        let now = Date()
        let events = #"[{"title":"t","start":"2026-11-14T10:00:00Z","end":"2026-11-14T11:00:00Z","attendees":["A","B"]}]"#
        // Закрыла stdout и не выходит: раньше ожидание было без срока.
        var t0 = Date()
        let hung = ExternalCalendar.run(path: script("hung", "echo '\(events)'\nexec 1>&-\nexec sleep 30"), now: now, timeout: 0.5)
        if case .failure(let e) = hung { equal(e.message, "не ответила за 0 с") } else { check(false, "висящая команда — не успех") }
        check(Date().timeIntervalSince(t0) < 4, "вернулись по сроку: \(Date().timeIntervalSince(t0)) с")
        // Команда вышла с ответом, а внук держит канал: ответ принят, не «не ответила».
        t0 = Date()
        let orphan = ExternalCalendar.run(path: script("orphan", "sleep 4 &\necho '\(events)'"), now: now, timeout: 3)
        if case .success(let list) = orphan { equal(list.map(\.title), ["t"]) } else { check(false, "ответ при живом внуке не принят") }
        check(Date().timeIntervalSince(t0) < 2.5, "не ждали срока: \(Date().timeIntervalSince(t0)) с")
    }

    // MARK: Н4, Н5 — редирект на чужой хост и потолок ответа
    do {
        let base = URL(string: "https://caldav.yandex.ru/calendars/a/")
        check(RedirectPolicy.allows(from: base, to: URL(string: "https://caldav.yandex.ru/other/")), "тот же хост по https")
        check(RedirectPolicy.allows(from: base, to: URL(string: "https://CALDAV.yandex.ru/x")), "регистр хоста не важен")
        check(!RedirectPolicy.allows(from: base, to: URL(string: "https://evil.example/calendars/a/")), "чужой хост")
        check(!RedirectPolicy.allows(from: base, to: URL(string: "http://caldav.yandex.ru/other/")), "смена схемы")
        check(!RedirectPolicy.allows(from: base, to: URL(string: "https://caldav.yandex.ru.evil.example/")), "похожий хост")
        check(!RedirectPolicy.allows(from: nil, to: base), "неизвестно откуда")
        check(!RedirectPolicy.allows(from: base, to: nil))

        // Тот же транспорт, что в приложении, с подделкой сети.
        let transport = URLSessionTransport(timeout: 5, maxBytes: 1000, protocolClasses: [AuditStubProtocol.self])
        func get(_ path: String) -> Result<(Data, HTTPURLResponse), Error> {
            blocking { try await transport.send(URLRequest(url: URL(string: "https://audit.test" + path)!)) }
        }
        AuditStubProtocol.reset()
        if case .success(let (data, response)) = get("/small") {
            equal(response.statusCode, 200)
            equal(String(decoding: data, as: UTF8.self), "ok", "обычный ответ читается")
        } else { check(false, "обычный ответ не прочитан") }
        if case .success(let (data, response)) = get("/redirect-same") {
            equal(response.statusCode, 200, "редирект на тот же хост выполняется")
            equal(String(decoding: data, as: UTF8.self), "ok")
        } else { check(false, "редирект на тот же хост не выполнен") }
        switch get("/redirect-foreign") {
        case .success(let (_, response)):
            equal(response.statusCode, 302, "редирект на чужой хост не выполняется — возвращается сам 302")
        case .failure(let error):
            check(false, "ответ 302 не получен: \(error)")
        }
        check(!AuditStubProtocol.requested().contains { $0.contains("evil.test") }, "на чужой хост запрос не ушёл")
        if case .failure(let error) = get("/big") {
            equal(error as? CalendarAccountError, .badResponse, "больше потолка — обрыв")
        } else { check(false, "большой ответ принят") }
        // Объявлено 5 МБ, тело в подделке — 10 байт: отказ именно по заголовку, а не по счёту байт.
        if case .failure(let error) = get("/big-declared") {
            equal(error as? CalendarAccountError, .badResponse, "Content-Length больше потолка — отказ по заголовку")
        } else { check(false, "большой объявленный ответ принят") }
    }
}

/// Подделка сети для `URLSessionTransport`: маленький ответ, редиректы, большой ответ кусками.
final class AuditStubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var urls: [String] = []
    nonisolated(unsafe) private static var sent: [String: Int] = [:]
    private var stopped = false

    static func reset() { lock.withLock { urls = []; sent = [:] } }
    static func requested() -> [String] { lock.withLock { urls } }
    static func sentBytes(for path: String) -> Int { lock.withLock { sent[path] ?? 0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        Self.lock.withLock { Self.urls.append(url.absoluteString) }
        func respond(_ code: Int, headers: [String: String] = [:]) {
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        func redirect(to target: String) {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target])!
            client.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: target)!), redirectResponse: response)
            // Редирект отклонён — ответом становится сам 302: отдать его и закончить.
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocolDidFinishLoading(self)
        }
        switch url.path {
        case "/redirect-same":
            redirect(to: "https://audit.test/small")
        case "/redirect-foreign":
            redirect(to: "https://evil.test/steal")
        case "/big":
            respond(200)
            let chunk = Data(repeating: 0x41, count: 500)
            for _ in 0..<40 {
                if Self.lock.withLock({ stopped }) { break }
                client.urlProtocol(self, didLoad: chunk)
                Self.lock.withLock { Self.sent[url.path, default: 0] += chunk.count }
            }
            client.urlProtocolDidFinishLoading(self)
        case "/big-declared":
            respond(200, headers: ["Content-Length": "5000000"])
            client.urlProtocol(self, didLoad: Data(repeating: 0x41, count: 10))
            client.urlProtocolDidFinishLoading(self)
        default:
            respond(200)
            client.urlProtocol(self, didLoad: Data("ok".utf8))
            client.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() { Self.lock.withLock { stopped = true } }
}
