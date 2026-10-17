import Foundation
import MostikCore

/// Папка встречи (M10) и всё, что решается вокруг неё (M11–M13, W2, W9, W11, W13, W14).
func runMeetingFolderTests() {
    // MARK: имя папки → время
    do {
        let cal = Calendar.current
        let date = MeetingFolder.folderDate("2026-10-11-153012")
        equal(date.map { cal.component(.second, from: $0) }, 12, "секунды из HHmmss")
        equal(MeetingFolder.folderDate("2026-10-10-1530").map { cal.component(.minute, from: $0) }, 30, "старое HHmm")
        check(MeetingFolder.folderDate("2026-10-11-153012-2") != nil, "суффикс -2")
        check(MeetingFolder.folderDate("clips") == nil, "не встреча")
        check(MeetingFolder.isAudioName("mic.2.wav") && MeetingFolder.isAudioName("system.wav"), "сегменты")
        check(!MeetingFolder.isAudioName("mic.wav.tmp"), "не аудио")
    }

    // MARK: шапка meeting.md
    do {
        let text = "---\ntitle: \"Синк\"\nsensitive: false\n---\n\n# Синк\nsensitive: false в теле\n"
        equal(MeetingFolder.frontMatterSensitive(text), false)
        let on = MeetingFolder.patchFrontMatterSensitive(text, true)
        equal(MeetingFolder.frontMatterSensitive(on), true)
        check(on.hasSuffix("# Синк\nsensitive: false в теле\n"), "тело не тронуто")
        let added = MeetingFolder.patchFrontMatterSensitive("---\ntitle: \"x\"\n---\nтело\n", true)
        equal(MeetingFolder.frontMatterSensitive(added), true, "ключ добавлен")
        equal(MeetingFolder.patchFrontMatterSensitive("без шапки", true), "без шапки")
    }

    // MARK: манифест: слияние и флаг
    do {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mostik-mf-\(UUID().uuidString)/2026-10-11-153000")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder.appendingPathComponent("mic.wav").path, contents: Data([0]))
        MeetingFolder.update(folder, ["title": "Синк", "recording": ["status": "recording"], "custom": ["a": 1]])
        MeetingFolder.update(folder, ["recording": ["restarts": 1], "custom": ["b": 2]])
        let m = MeetingFolder.readManifest(folder) ?? [:]
        equal(m["schema"] as? String, "mostik.meeting")
        equal((m["recording"] as? [String: Any])?["status"] as? String, "recording", "слияние сохраняет соседние ключи")
        equal((m["recording"] as? [String: Any])?["restarts"] as? Int, 1)
        equal((m["custom"] as? [String: Any])?.count, 2, "чужие ключи живут")
        equal((m["audio"] as? [String: Any])?["files"] as? [String], ["mic.wav"])
        check(!MeetingFolder.isSensitive(folder), "по умолчанию не чувствительная")
        try? "---\ntitle: \"Синк\"\nsensitive: false\n---\n".write(to: folder.appendingPathComponent("meeting.md"), atomically: true, encoding: .utf8)
        MeetingFolder.setSensitive(folder, true)
        check(MeetingFolder.isSensitive(folder), "флаг поставлен")
        let md = (try? String(contentsOf: folder.appendingPathComponent("meeting.md"), encoding: .utf8)) ?? ""
        equal(MeetingFolder.frontMatterSensitive(md), true, "строка шапки поправлена")
        MeetingFolder.setSensitive(folder, false)
        check(!MeetingFolder.isSensitive(folder), "флаг снят")
        equal(MeetingFolder.summary(folder)?.title, "Синк")
        try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
    }

    runSensitiveFramesTests()
    runMeetingWatchdogTests()
    runMeetingCalendarTests()
    runMeetingHookTests()
    runMeetingTurnsTests()
}

// MARK: - M12: сторож и восстановление

func runMeetingWatchdogTests() {
    do {
        var w = MeetingWatchdog(startedAt: 0)
        for t in stride(from: 0.5, through: 2.5, by: 0.5) { w.buffer(.mic, at: t, level: 0.5); w.buffer(.system, at: t) }
        equal(w.tick(at: 3), [], "буферы идут — тихо")
        w.buffer(.system, at: 5)
        // Микрофон молчит с 2.5 с: на 5.5 с — перезапуск.
        equal(w.tick(at: 5.5), [.restart(.mic, attempt: 1)])
        equal(w.tick(at: 6), [], "после перезапуска — новый срок")
        w.buffer(.system, at: 8.5)
        equal(w.tick(at: 8.5), [.restart(.mic, attempt: 2)])
        w.buffer(.system, at: 11.5)
        equal(w.tick(at: 11.5), [.restart(.mic, attempt: 3)])
        w.buffer(.system, at: 14.5)
        equal(w.tick(at: 14.5), [.giveUp(.mic)], "после трёх попыток — сдаёмся")
        w.buffer(.system, at: 20)
        equal(w.tick(at: 20), [], "сдавшаяся дорожка больше не дёргается")
        equal(w.status, "incomplete")
        equal(w.totalRestarts, 3)
    }
    do {
        var w = MeetingWatchdog(startedAt: 100)
        w.buffer(.mic, at: 101, level: 0.4); w.buffer(.system, at: 101)
        _ = w.tick(at: 104.5)
        w.buffer(.mic, at: 105, level: 0.4); w.buffer(.system, at: 105)
        w.restarted(.mic, at: 105)
        equal(w.status, "recovered", "перезапуск удался — запись восстановлена")
        var quiet = MeetingWatchdog(startedAt: 0)
        for t in 1...12 { quiet.buffer(.mic, at: Double(t), level: 0.01); quiet.buffer(.system, at: Double(t)) }
        var actions: [MeetingWatchdog.Action] = []
        for t in 1...12 { actions += quiet.tick(at: Double(t)) }
        equal(actions, [.warnNoAudio], "10 с тишины — одно предупреждение")
        equal(quiet.status, "complete")
        var paused = MeetingWatchdog(startedAt: 0)
        var pausedActions: [MeetingWatchdog.Action] = []
        for t in 1...30 { paused.buffer(.mic, at: Double(t)); paused.buffer(.system, at: Double(t)); pausedActions += paused.tick(at: Double(t), paused: true) }
        equal(pausedActions, [], "пауза не считается тишиной")
    }
    do {
        // отказ в «звуке системы» — системная дорожка в нулях при живом микрофоне.
        func run(_ expected: Bool, system: Float, seconds: Int = 20) -> (MeetingWatchdog, [MeetingWatchdog.Action]) {
            var w = MeetingWatchdog(startedAt: 0)
            var actions: [MeetingWatchdog.Action] = []
            for t in 1...seconds {
                w.buffer(.mic, at: Double(t), level: 0.5); w.buffer(.system, at: Double(t), level: system)
                actions += w.tick(at: Double(t), systemExpected: expected)
            }
            return (w, actions)
        }
        let (denied, deniedActions) = run(true, system: 0)
        equal(deniedActions, [.warnSystemSilent], "одно предупреждение, после 15 с")
        check(!denied.systemHeard, "разрешение не подтверждено")
        equal(run(true, system: 0, seconds: 14).1, [], "раньше 15 с — молчим")
        let (granted, grantedActions) = run(true, system: 0.02)
        equal(grantedActions, [], "собеседник тихий, но не цифровой ноль")
        check(granted.systemHeard, "звук системы был — разрешение выдано")
        equal(run(false, system: 0).1, [], "очная встреча с подтверждённым разрешением — законная тишина")
        var quietRoom = MeetingWatchdog(startedAt: 0)
        var quietActions: [MeetingWatchdog.Action] = []
        for t in 1...20 { quietRoom.buffer(.mic, at: Double(t), level: 0); quietRoom.buffer(.system, at: Double(t), level: 0)
                          quietActions += quietRoom.tick(at: Double(t), systemExpected: true) }
        equal(quietActions, [.warnNoAudio], "молчат обе — это «нет звука», не отказ")
    }
    do {
        typealias S = MeetingFolder.Summary
        equal(MeetingRecovery.decide(summary: S(recording: "recording", transcript: "pending"), hasAudio: true,
                                     hasTranscript: false, isRecordingNow: false), .transcribe(markIncomplete: true), "упали посреди записи")
        equal(MeetingRecovery.decide(summary: S(recording: "recording", transcript: "pending"), hasAudio: true,
                                     hasTranscript: false, isRecordingNow: true), .none, "пишем прямо сейчас")
        equal(MeetingRecovery.decide(summary: S(recording: "complete", transcript: "processing", transcriptAttempts: 1),
                                     hasAudio: true, hasTranscript: false, isRecordingNow: false), .transcribe(markIncomplete: false), "движок упал при расшифровке")
        equal(MeetingRecovery.decide(summary: S(recording: "complete", transcript: "processing", transcriptAttempts: 2),
                                     hasAudio: true, hasTranscript: false, isRecordingNow: false), .giveUp(markIncomplete: false), "без зацикливания")
        equal(MeetingRecovery.decide(summary: S(recording: "complete", transcript: "missing"), hasAudio: true,
                                     hasTranscript: false, isRecordingNow: false), .none, "старая встреча сама не гоняется")
        equal(MeetingRecovery.decide(summary: S(recording: "complete", transcript: "done"), hasAudio: true,
                                     hasTranscript: true, isRecordingNow: false), .none)
        equal(MeetingRecovery.decide(summary: nil, hasAudio: true, hasTranscript: false, isRecordingNow: false), .none)
        equal(MeetingRecovery.decide(summary: S(recording: "recording", transcript: "pending"), hasAudio: false,
                                     hasTranscript: false, isRecordingNow: false), .giveUp(markIncomplete: true), "звука нет")
        // R3a: код сбоя из манифеста — действие «Повторить без разделения по голосам» после перезапуска.
        equal(S(manifest: ["transcript": ["status": "failed", "code": "diarization_memory"]]).transcriptCode,
              EngineErrorText.diarizationMemory)
        equal(S(manifest: ["transcript": ["status": "failed", "code": NSNull()]]).transcriptCode, nil, "null — кода нет")
        // Нет fluidaudiocli: встреча расшифрована одним собеседником — спокойная строка, не сбой.
        check(S(manifest: ["transcript": ["status": "done", "code": "diarization_unavailable"]]).diarizationUnavailable,
              "готова без разделения по голосам")
        check(!S(manifest: ["transcript": ["status": "done", "code": NSNull()]]).diarizationUnavailable, "голоса разделены")
        check(!S(manifest: ["transcript": ["status": "failed", "code": "diarization_unavailable"]]).diarizationUnavailable,
              "сбой — не про голоса")
        equal(EngineErrorText.diarizationUnavailable, "diarization_unavailable")
        check(S(manifest: ["transcript": ["status": "done", "code": "diarization_failed"]]).diarizationFailed,
              "модель голосов упала — расшифровка есть, одним собеседником")
        check(!S(manifest: ["transcript": ["status": "done", "code": "diarization_failed"]]).diarizationUnavailable,
              "сбой модели — не «недоступно на этом Mac»")
        equal(S(manifest: ["duration_seconds": 1924.4]).durationSeconds, 1924.4,
              "длительность из манифеста — звук мог уйти в Корзину")
        equal(S(manifest: [:]).durationSeconds, nil, "нет в манифесте — нет")
    }
    do {
        equal(MeetingSegment.fileName(.mic, index: 1), "mic.wav")
        equal(MeetingSegment.fileName(.system, index: 3), "system.3.wav")
        let segs = [MeetingSegment(track: .mic, file: "mic.wav", offset: 0), MeetingSegment(track: .mic, file: "mic.2.wav", offset: 312.456)]
        let back = MeetingSegment.fromManifest(["recording": ["segments": segs.map(\.manifestValue)]])
        equal(back.map(\.file), ["mic.wav", "mic.2.wav"])
        equal(back.last?.offset, 312.46)
        check(EngineCodec.command("meeting", id: 1, fields: ["segments": MeetingSegment.commandField(segs)])
            .contains(#""mic":[{"#), "поле segments")
    }
}

// MARK: - M13, W2, W14: календарь, повестка, предложение записать

func runMeetingCalendarTests() {
    do {
        equal(MeetingLinks.find(url: nil, location: "Переговорка 5", notes: "Документ https://docs.google.com/d/1\nЗвонок: https://telemost.yandex.ru/j/1234567890"),
              "https://telemost.yandex.ru/j/1234567890", "ссылка на звонок важнее документа")
        equal(MeetingLinks.find(url: "https://us02web.zoom.us/j/885?pwd=x", location: nil, notes: nil), "https://us02web.zoom.us/j/885?pwd=x")
        equal(MeetingLinks.find(url: nil, location: "https://meet.example.org/room", notes: nil), "https://meet.example.org/room", "любая ссылка из места")
        equal(MeetingLinks.find(url: nil, location: nil, notes: "отчёт https://wiki.example.org/x."), nil, "из описания — только известные")
        check(MeetingLinks.isCallLink("https://meet.google.com/abc-defg-hij"))
        check(!MeetingLinks.isCallLink("https://vk.com/id1"), "vk.com без /call — не звонок")
    }
    do {
        let notes = "Подключиться: https://telemost.yandex.ru/j/1\n\nПовестка:\n1. Бюджет на Q4\n2) Найм\n- [ ] Сроки релиза\n\nКонец"
        equal(Agenda.parse(notes), ["Бюджет на Q4", "Найм", "Сроки релиза"])
        equal(Agenda.parse("Agenda\nRoadmap review\nHiring\n\nThanks"), ["Roadmap review", "Hiring"], "строки под заголовком")
        equal(Agenda.parse("Просто текст без списка"), [])
        equal(Agenda.parse(String(repeating: "- пункт\n", count: 3)), ["пункт"], "без повторов")
    }
    do {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let soon = CalendarEvent(id: "a", title: "Синк", start: now.addingTimeInterval(50), end: now.addingTimeInterval(1850))
        let later = CalendarEvent(id: "b", title: "Ретро", start: now.addingTimeInterval(600), end: now.addingTimeInterval(1200))
        equal(MeetingReminder.due([later, soon], now: now, shown: [])?.id, "a")
        equal(MeetingReminder.due([later, soon], now: now, shown: ["a"])?.id, nil, "одно напоминание на событие")
        equal(MeetingReminder.upcoming([later, soon], now: now)?.id, "a")
        let running = CalendarEvent(id: "c", title: "Идёт", start: now.addingTimeInterval(-300), end: now.addingTimeInterval(300))
        equal(MeetingReminder.upcoming([running], now: now)?.id, "c", "идущая — тоже «скоро»")
        equal(UpcomingMeeting(event: CalendarEvent(id: "x", title: "t", start: now, end: now, notes: "- один\n- два", link: "https://zoom.us/j/1")).agenda, ["один", "два"])
    }
    do {
        var a = MeetingAutoStop()
        equal(a.update(now: 10, eventEnd: 100, callActive: true), .none)
        equal(a.update(now: 100, eventEnd: 100, callActive: true), .started(deadline: 160), "событие кончилось")
        equal(a.update(now: 130, eventEnd: 100, callActive: true), .none)
        equal(a.remaining(now: 130), 30)
        equal(a.update(now: 160, eventEnd: 100, callActive: true), .stop)
        var b = MeetingAutoStop()
        _ = b.update(now: 0, eventEnd: nil, callActive: false)
        equal(b.update(now: 5, eventEnd: nil, callActive: false), .none, "звонка не было — не по чему останавливать")
        _ = b.update(now: 6, eventEnd: nil, callActive: true)
        equal(b.update(now: 20, eventEnd: nil, callActive: false), .stop, "звонок закрылся — стоп сразу, без минуты")
        var c = MeetingAutoStop()
        _ = c.update(now: 0, eventEnd: 50, callActive: true)
        equal(c.update(now: 60, eventEnd: 50, callActive: false), .stop, "звонок закрылся и после конца события — тоже сразу")
        var d = MeetingAutoStop()
        equal(d.update(now: 100, eventEnd: 100, callActive: true), .started(deadline: 160))
        d.cancel()
        equal(d.update(now: 170, eventEnd: 100, callActive: true), .none, "отменённый отсчёт не возвращается")
        equal(d.remaining(now: 170), nil)
    }
    do {
        var s = CallSuggestion()
        s.appChanged("Zoom", at: 0)
        equal(s.suggestion(at: 9, recording: false, enabled: true), nil, "раньше 10 с — молчим")
        equal(s.suggestion(at: 10, recording: false, enabled: true), "Zoom")
        equal(s.suggestion(at: 10, recording: true, enabled: true), nil, "уже пишем")
        equal(s.suggestion(at: 10, recording: false, enabled: false), nil, "выключено")
        s.dismiss()
        equal(s.suggestion(at: 30, recording: false, enabled: true), nil, "«Нет» держится, пока звонок идёт")
        s.appChanged(nil, at: 40)
        s.appChanged("Zoom", at: 50)
        equal(s.suggestion(at: 61, recording: false, enabled: true), "Zoom", "новый звонок — новое предложение")
        s.appChanged("Телемост", at: 62)
        equal(s.suggestion(at: 70, recording: false, enabled: true), nil, "другое приложение — снова ждём 10 с")
    }
    do {
        equal(MeetingNotes.render(title: "Синк", agenda: ["Бюджет"], prep: " спросить про сроки "),
              "# Заметки: Синк\n\n## Повестка\n\n- [ ] Бюджет\n\n## Подготовка\n\nспросить про сроки\n")
        equal(MeetingNotes.render(title: "Sync", agenda: [], prep: "", language: "en"), "# Notes: Sync\n")
    }
}

// MARK: - M11, W13: хук и удаление аудио

func runMeetingHookTests() {
    var settings = MeetingHookSettings()
    equal(MeetingHook.decide(settings, event: .transcript, sensitive: false, trusted: true), .skip("disabled"), "выключен по умолчанию")
    settings.enabled = true
    equal(MeetingHook.decide(settings, event: .transcript, sensitive: false, trusted: true), .skip("empty"))
    settings.command = "cp \"$1/meeting.md\" ~/Vault/"
    equal(MeetingHook.decide(settings, event: .transcript, sensitive: false, trusted: true), .run)
    equal(MeetingHook.decide(settings, event: .transcript, sensitive: true, trusted: true), .skip("sensitive"), "чувствительная — без хуков")
    settings.afterSummary = false
    equal(MeetingHook.decide(settings, event: .summary, sensitive: false, trusted: true), .skip("summary_off"))
    settings.timeoutSeconds = 1
    equal(MeetingHook.timeout(settings), 5, "нижняя граница таймаута")
    let folder = URL(fileURLWithPath: "/tmp/m/2026-10-11-153000")
    // П10, низкий: без login-оболочки — ~/.zprofile и ~/.zshrc не читаются, исполняется ровно подтверждённая команда.
    equal(MeetingHook.arguments(command: "echo $1", folder: folder), ["-fc", "echo $1", "mostik-hook", "/tmp/m/2026-10-11-153000"])
    let env = MeetingHook.environment(folder: folder, event: .summary, base: ["PATH": "/usr/bin"])
    equal(env["MOSTIK_MEETING_DIR"], folder.path); equal(env["MOSTIK_MEETING_EVENT"], "summary")
    equal(env["PATH"], ToolEnvironment.defaultPath, "П10 р3 С-2: PATH хука — системный, не родительский")
    let log = MeetingHook.logEntry(date: Date(), folder: folder, event: .transcript, exitCode: nil, timedOut: true,
                                   seconds: 60, output: "строка 1\nстрока 2")
    check(log.contains("2026-10-11-153000 transcript — timeout") && log.contains("  строка 2"), "лог хука")
    let decoded = try? JSONDecoder().decode(MostikSettings.self, from: Data("{\"meetingHook\":{\"enabled\":true}}".utf8))
    equal(decoded?.meetingHook.enabled, true); equal(decoded?.meetingHook.timeoutSeconds, 60)
    equal(decoded?.meetingAutoStop, false, "автоостановка выключена по умолчанию")
    equal(decoded?.trashAudioAfterSummary, false, "аудио по умолчанию не удаляем")

    check(!AudioRetention.shouldTrash(enabled: false, summaryStatus: "done", hasTranscript: true, audioKept: true), "выключено")
    check(AudioRetention.shouldTrash(enabled: true, summaryStatus: "done", hasTranscript: true, audioKept: true))
    check(!AudioRetention.shouldTrash(enabled: true, summaryStatus: "partial", hasTranscript: true, audioKept: true), "сводка неполная")
    check(!AudioRetention.shouldTrash(enabled: true, summaryStatus: "done", hasTranscript: false, audioKept: true), "без расшифровки")
    check(!AudioRetention.shouldTrash(enabled: true, summaryStatus: "done", hasTranscript: true, audioKept: false), "уже в Корзине")
}

// MARK: - W9, W11: фрагменты и метрики говорения

func runMeetingTurnsTests() {
    let json = """
    {"turns": [
      {"speaker": "Я", "start": 0, "end": 10, "text": "Привет. Начнём? Как дела??"},
      {"speaker": "Иван", "start": 11, "end": 20, "text": "Хорошо."},
      {"speaker": "Я", "start": 21, "end": 50, "text": "Длинный рассказ."},
      {"speaker": "Я", "start": 55, "end": 70, "text": "Продолжаю. Вопросы?!"},
      {"speaker": "Иван", "start": 71, "end": 100, "text": "Понял?"}
    ]}
    """
    let turns = SpeechTurn.parse(Data(json.utf8))
    equal(turns.count, 5)
    let metrics = SpeakingMetrics.compute(turns)
    equal(metrics?.mySeconds, 54)
    equal(metrics.map { ($0.share * 100).rounded() }, 59, "доля: 54 из 92 секунд")
    equal(metrics?.longestMonologue, 49, "монолог 21–70: пауза без чужой речи не рвёт")
    equal(metrics?.longestAt, 21)
    equal(metrics?.questions, 3, "только мои вопросы; «??» и «?!» — по одному")
    equal(SpeakingMetrics.compute([SpeechTurn(index: 0, speaker: "Собеседник 1", start: 0, end: 5, text: "Да")]), nil, "меня нет")
    equal(SpeechTurn.parse(Data(#"[{"speaker":"Я","start":1.5,"text":"без конца"}]"#.utf8)).first?.end, 1.5)

    let plan = MeetingClipPlan.make(selected: [("Иван", 11, "Хорошо."), ("Я", 21, "Длинный рассказ.")], turns: turns,
                                    title: "Синк", date: nil, duration: 100, audioFile: "00.10-00.50.m4a")
    equal(plan?.start, 10.5); equal(plan?.end, 50.5); equal(plan?.stem, "00.10-00.50")
    check(plan?.markdown.contains("**Иван** [00:11] Хорошо.") == true && plan?.markdown.contains("[00.10-00.50.m4a](00.10-00.50.m4a)") == true, "текст фрагмента")
    equal(MeetingClipPlan.make(selected: [("Иван", 71, "Понял?")], turns: turns, title: "Синк", date: nil, duration: 100, audioFile: nil)?.end, 100, "не дальше конца встречи")
    equal(MeetingClipPlan.make(selected: [], turns: turns, title: "x", date: nil, duration: 0, audioFile: nil), nil)
    equal(MeetingClipPlan.clock(3725), "1:02:05")

    let segs = [MeetingSegment(track: .mic, file: "mic.wav", offset: 0), MeetingSegment(track: .mic, file: "mic.2.wav", offset: 100)]
    let pieces = MeetingClipPlan.pieces(segments: segs, lengths: ["mic.wav": 90, "mic.2.wav": 50], start: 80, end: 120)
    equal(pieces, [.init(file: "mic.wav", fileOffset: 80, length: 10, clipOffset: 0),
                   .init(file: "mic.2.wav", fileOffset: 0, length: 20, clipOffset: 20)], "дыра между сегментами — тишина")
}


// MARK: - П10: кадры экрана при пометке «чувствительная»

/// Кадры (W26), снятые до пометки, уходят в Корзину вместе с `*.ocr.txt`. Корзина — подделка:
/// настоящую не трогаем.
func runSensitiveFramesTests() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("mostik-sensframes-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    let folder = root.appendingPathComponent("2026-10-11-153012", isDirectory: true)
    let frames = folder.appendingPathComponent("frames", isDirectory: true)
    try? fm.createDirectory(at: frames, withIntermediateDirectories: true)
    try? Data("jpg".utf8).write(to: frames.appendingPathComponent("000130.jpg"))
    try? Data("зарплаты".utf8).write(to: frames.appendingPathComponent("000130.ocr.txt"))
    try? Data("{}".utf8).write(to: folder.appendingPathComponent("manifest.json"))

    // Пометка «только на этом Mac» кадры не трогает: они остаются, как и расшифровка.
    MeetingFolder.setSensitive(folder, true)
    check(MeetingFolder.isSensitive(folder), "флаг стоит")
    check(fm.fileExists(atPath: frames.appendingPathComponent("000130.jpg").path), "кадр на месте")
    check(fm.fileExists(atPath: frames.appendingPathComponent("000130.ocr.txt").path), "текст кадра на месте")
    MeetingFolder.setSensitive(folder, false)
    check(!MeetingFolder.isSensitive(folder), "флаг снимается")
}
