import Foundation
import MostikCore

/// Встреча по ходу записи и после неё (П6-Б): V6, W10, W15–W17, W19, W20, W24, A1. Данные синтетические.
func runMeetingLiveTests() {
    // MARK: настройки — старый файл без поля, битый режим
    do {
        let old = try? JSONDecoder().decode(MostikSettings.self, from: Data(#"{"language":"ru"}"#.utf8))
        equal(old?.meetingLive, MeetingLiveSettings(), "без поля — умолчания")
        check(old?.meetingLive.textOnlyDefault == false, "«только текст» выключен")
        let bad = try? JSONDecoder().decode(MeetingLiveSettings.self, from: Data(#"{"meetingVoiceProcessing":"loud"}"#.utf8))
        equal(bad?.meetingVoiceProcessing, VoiceProcessingPolicy.off, "неизвестный режим — выключено")
        var s = MostikSettings()
        s.meetingLive.warningText = "Пишу встречу"
        s.agentVoice.voiceRU = "com.apple.voice.premium.ru-RU.Milena"
        let data = try? JSONEncoder().encode(s)
        let back = data.flatMap { try? JSONDecoder().decode(MostikSettings.self, from: $0) }
        equal(back?.meetingLive.warningText, "Пишу встречу")
        equal(back?.agentVoice.voiceRU, "com.apple.voice.premium.ru-RU.Milena")
    }

    // MARK: V6 — когда включать обработку голоса
    do {
        check(!VoiceProcessingPolicy.meeting(mode: "off", outputIsSpeakers: true))
        check(VoiceProcessingPolicy.meeting(mode: "speakers", outputIsSpeakers: true), "звук из динамиков")
        check(!VoiceProcessingPolicy.meeting(mode: "speakers", outputIsSpeakers: false), "в наушниках эха нет")
        check(VoiceProcessingPolicy.meeting(mode: "always", outputIsSpeakers: false))
    }

    // MARK: W15 — отрезки «только текст»
    do {
        var r = TextOnlyRanges()
        r.set(true, at: 10)
        r.set(true, at: 12)
        check(r.isOn)
        r.set(false, at: 30)
        r.set(false, at: 31)
        r.set(true, at: 50)
        let spans = r.closed(at: 80)
        equal(spans, [.init(start: 10, end: 30), .init(start: 50, end: 80)], "открытый отрезок закрыт концом записи")
        check(!TextOnlyRanges.coversWhole(spans, duration: 80))
        check(TextOnlyRanges.coversWhole([.init(start: 0.4, end: 79.5)], duration: 80), "вся встреча с допуском")
        check(TextOnlyRanges.coversWhole([.init(start: 0, end: 40), .init(start: 40, end: 80)], duration: 80), "стык сливается")
        check(!TextOnlyRanges.coversWhole([], duration: 80))
        // Сегмент 2 начинается на 60-й секунде и длится 30 с: затираются 0…20 с внутри него.
        equal(TextOnlyRanges.byteRanges(spans, segmentOffset: 60, segmentSeconds: 30), [0..<640_000])
        equal(TextOnlyRanges.byteRanges(spans, segmentOffset: 0, segmentSeconds: 40), [320_000..<960_000])
        equal(TextOnlyRanges.byteRanges([.init(start: 0.00003, end: 0.0001)], segmentOffset: 0, segmentSeconds: 1).first.map { $0.lowerBound % 2 }, 0, "границы кратны 2")
        let manifest: [String: Any] = ["text_only": TextOnlyRanges.manifestValue(spans, whole: false)]
        let parsed = TextOnlyRanges.fromManifest(manifest)
        equal(parsed?.spans, spans)
        equal(parsed?.whole, false)
        check(TextOnlyRanges.fromManifest([:]) == nil)
    }

    // MARK: W10 — где резать кусок
    do {
        let loud = [Float](repeating: 0.8, count: 100)
        equal(LiveWindow.cut(levels: loud), nil, "10 с — рано")
        var withPause = [Float](repeating: 0.8, count: 200)
        for i in 150..<154 { withPause[i] = 0.05 }
        let cut = LiveWindow.cut(levels: withPause)
        check(cut.map { (150...154).contains($0) } == true, "режем в паузе, получено \(String(describing: cut))")
        equal(LiveWindow.cut(levels: [Float](repeating: 0.8, count: 200)), nil, "громко и до предела далеко — ждём")
        let long = [Float](repeating: 0.8, count: 260)
        check(LiveWindow.cut(levels: long).map { $0 <= 250 && $0 >= 120 } == true, "предел — режем всё равно")
        equal(LiveWindow.cut(levels: [0.5, 0.5], final: true), 2, "остановка — всё")
        equal(LiveWindow.cut(levels: [], final: true), nil)
    }

    // MARK: W10 — строки живой расшифровки
    do {
        var live = LiveTranscript()
        check(live.add(track: "system", start: 14, text: "  Добрый   день "))
        check(live.add(track: "mic", start: 0, text: "Привет"))
        check(!live.add(track: "mic", start: 20, text: "   "), "пустое не добавляется")
        check(!live.add(track: "system", start: 30, text: "Добрый день"), "повтор куска — нет")
        equal(live.lines.map(\.start), [0, 14], "по времени")
        equal(live.plainText(russian: true), "[00:00] Я: Привет\n[00:14] Собеседники: Добрый день")
        equal(LiveTranscript.clock(3725), "1:02:05")
    }

    // MARK: W16 — продолжение
    do {
        let segments = [MeetingSegment(track: .mic, file: "mic.wav", offset: 0),
                        MeetingSegment(track: .system, file: "system.wav", offset: 0),
                        MeetingSegment(track: .mic, file: "mic.2.wav", offset: 100)]
        let seconds = ["mic.wav": 90.0, "system.wav": 160.0, "mic.2.wav": 61.0]
        equal(MeetingContinuation.baseOffset(segments: segments, seconds: { seconds[$0] }, manifestDuration: 150), 161)
        equal(MeetingContinuation.baseOffset(segments: [], seconds: { _ in nil }, manifestDuration: nil), 0)
        let next = MeetingContinuation.nextSegments(after: segments, offset: 161)
        equal(next.map(\.file), ["mic.3.wav", "system.2.wav"])
        equal(next.map(\.offset), [161, 161])
        equal(MeetingContinuation.nextSegments(after: [], offset: 0).map(\.file), ["mic.2.wav", "system.2.wav"],
              "без манифеста первый файл уже занят")
        check(MeetingContinuation.allowed(recording: false, audioKept: true, hasAudio: true))
        check(!MeetingContinuation.allowed(recording: true, audioKept: true, hasAudio: true), "идёт другая запись")
        check(!MeetingContinuation.allowed(recording: false, audioKept: false, hasAudio: true), "аудио в Корзине")
        let end = Date(timeIntervalSince1970: 1_000_000)
        check(MeetingContinuation.allowed(recording: false, audioKept: true, hasAudio: true, latest: true,
                                          endedAt: end, now: end.addingTimeInterval(5 * 60)), "только что закончилась")
        check(!MeetingContinuation.allowed(recording: false, audioKept: true, hasAudio: true, latest: true,
                                           endedAt: end, now: end.addingTimeInterval(20 * 60)), "прошло 20 минут")
        check(!MeetingContinuation.allowed(recording: false, audioKept: true, hasAudio: true, latest: false,
                                           endedAt: end, now: end), "после неё была другая встреча")
    }

    // MARK: W24 — автостарт убран (решение автора)
    do {
        // Сохранённый когда-то `autoStart: true` игнорируется и не переживает пересохранение.
        let saved = Data(#"{"meetingLive":{"autoStart":true,"liveTranscript":false}}"#.utf8)
        let s = try? JSONDecoder().decode(MostikSettings.self, from: saved)
        equal(s?.meetingLive.liveTranscript, false, "соседние поля читаются как раньше")
        let back = s.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        check(!back.contains("autoStart"), "автостарт не пишется обратно в settings.json")
        // Звонок только предлагают записать: ни кода автостарта, ни настройки.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Mostik/MeetingFolderController.swift", "MostikUI/MeetingLiveViews.swift", "MostikUI/SettingsIndex.swift"] {
            let text = (try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)) ?? ""
            check(!text.isEmpty && !text.contains("autoStart"), "\(file): автостарта записи звонка нет")
        }
    }

    // MARK: W19, W20 — предупреждение и черновик письма
    do {
        check(ConsentWarning.text(custom: "  ", russian: true).hasPrefix("Коллеги"), "пустой свой текст — стандартный")
        equal(ConsentWarning.text(custom: " Пишу. ", russian: true), "Пишу.")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let start = cal.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15, minute: 30))!
        let url = ConsentWarning.mailto(emails: ["anna@example.com", "не почта", "b@x.org?bcc=evil@x.org", "boris@example.org"],
                                        title: "Синк & план", start: start, warning: "Пишу встречу.", russian: true,
                                        timeZone: TimeZone(identifier: "Europe/Moscow")!)
        let text = url?.absoluteString ?? ""
        check(text.hasPrefix("mailto:anna%40example.com,boris%40example.org?subject="), "только адреса: \(text)")
        check(!text.contains("evil") && !text.contains("+"), "без подмешанных полей и плюсов")
        check(text.contains("%26"), "амперсанд в теме закодирован")
        let comps = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let body = comps?.queryItems?.first { $0.name == "body" }?.value ?? ""
        check(body.contains("12 октября, 15:30") && body.contains("Пишу встречу."), "тело: \(body)")
        equal(comps?.queryItems?.first { $0.name == "subject" }?.value, "Запись встречи «Синк & план»")
        check(ConsentWarning.mailto(emails: [], title: "", start: start, warning: "x", russian: false)?.absoluteString.hasPrefix("mailto:?subject=") == true,
              "без адресов — письмо без получателей")
    }

    // MARK: W17 — реплики с метками
    do {
        let json = #"""
        {"turns": [
          {"id": 0, "speaker": "Я", "source": "mic", "start": 0, "end": 3, "text": "Привет"},
          {"id": 1, "speaker": "Анна", "label": "Собеседник 1", "source": "system", "start": 4, "end": 9, "text": "Здравствуйте"},
          {"id": 2, "speaker": "Собеседник 2", "label": "Собеседник 2", "source": "system", "start": 10, "end": 12, "text": "Да"},
          {"id": 3, "speaker": "Анна + Собеседник 2", "label": "Собеседник 1 + Собеседник 2", "source": "system", "start": 12, "end": 13, "text": "Ага"},
          {"id": 4, "speaker": "Собеседник 3", "source": "system", "start": 20, "text": "Без метки и конца"}
        ]}
        """#
        let turns = TurnRef.parse(Data(json.utf8))
        equal(turns.count, 5)
        equal(turns[4].label, "Собеседник 3", "старая расшифровка: метка = имя")
        equal(turns[4].end, 20)
        check(!turns[0].isReassignable && !turns[3].isReassignable && turns[1].isReassignable, "«Я» и перекрытие — нет")
        equal(TurnRef.labels(turns).map(\.label), ["Собеседник 1", "Собеседник 2", "Собеседник 3"])
        equal(TurnRef.labels(turns).first?.name, "Анна")
        equal(TurnRef.find(turns, start: 10.01, speaker: "Собеседник 2")?.id, 2)
        check(TurnRef.parse(Data("[]".utf8)).isEmpty)
    }

    // MARK: A1 — голос
    do {
        let voices = [SystemVoiceInfo(id: "ru.milena", name: "Milena", language: "ru-RU", quality: 1),
                      SystemVoiceInfo(id: "ru.katya.premium", name: "Katya", language: "ru-RU", quality: 3),
                      SystemVoiceInfo(id: "ru.yuri.enhanced", name: "Yuri", language: "ru-RU", quality: 2),
                      SystemVoiceInfo(id: "en.ava", name: "Ava", language: "en-US", quality: 2)]
        equal(SystemVoicePick.options(voices, language: "ru").map(\.id), ["ru.katya.premium", "ru.yuri.enhanced", "ru.milena"])
        equal(SystemVoicePick.best(voices, language: "ru", chosen: nil)?.id, "ru.katya.premium", "лучший установленный")
        equal(SystemVoicePick.best(voices, language: "ru", chosen: "ru.milena")?.id, "ru.milena", "выбор пользователя")
        equal(SystemVoicePick.best(voices, language: "ru", chosen: "gone")?.id, "ru.katya.premium", "удалённый — лучший")
        equal(SystemVoicePick.best(voices, language: "de", chosen: nil), nil)
    }

    // MARK: PCM — уровни, смесь, WAV
    do {
        func pcm(_ values: [Int16]) -> Data { values.withUnsafeBufferPointer { Data(buffer: $0) } }
        let silence = pcm([Int16](repeating: 0, count: 1600))
        let loud = pcm([Int16](repeating: 16384, count: 1600))
        let levels = LivePCM.levels(silence + loud + pcm([1, 2, 3]))
        equal(levels.count, 2, "неполный хвост не считается")
        equal(levels.first, 0, "тишина — 0")
        check(levels[1] > 0.85, "−6 dBFS — почти верх шкалы")
        equal(LivePCM.levels(pcm([1, 2])), [], "меньше кадра — пусто")
        let mixed = LivePCM.mix([pcm([30000, 100, -30000]), pcm([10000, 5])])
        mixed.withUnsafeBytes { raw in
            let v = Array(raw.bindMemory(to: Int16.self))
            equal(v, [Int16.max, 105, -30000], "насыщение и длина по длинной")
        }
        let wav = LivePCM.wav(pcm([1, 2]))
        equal(wav.count, 48)
        equal(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        equal(Int(wav[40]), 4, "размер данных в заголовке")
    }
}
