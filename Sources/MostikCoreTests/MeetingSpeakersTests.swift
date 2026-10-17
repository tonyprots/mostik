import Foundation
import MostikCore

/// Говорящие встречи (M14, M15): разбор `transcript.json` и ответов движка. Данные синтетические.
func runMeetingSpeakersTests() {
    let json = """
    {"speaker_names": {"Собеседник 1": "Иван"},
     "turns": [
      {"id": 0, "speaker": "Я", "source": "mic", "start": 0, "end": 3, "text": "Начнём."},
      {"id": 1, "speaker": "Иван", "label": "Собеседник 1", "source": "system", "start": 4, "end": 10,
       "text": "Про сроки.", "speaker_confidence": 1.0},
      {"id": 2, "speaker": "Собеседник 2", "label": "Собеседник 2", "source": "system", "start": 12, "end": 18,
       "text": "Про бюджет.", "speaker_confidence": 0.31, "review": true,
       "speaker_alternatives": [{"label": "Собеседник 1", "share": 0.4}, {"label": "Собеседник 2", "share": 0.5}]},
      {"id": 3, "speaker": "Иван + Собеседник 2", "label": "Собеседник 1 + Собеседник 2", "source": "system",
       "start": 19, "end": 20, "text": "Да.", "speaker_confidence": 0.2, "review": true, "reviewed": true},
      {"id": 4, "speaker": "Собеседник 3", "label": "Собеседник 3", "source": "system", "start": 21, "end": 22,
       "text": "Угу.", "speaker_confidence": 0.5}
     ],
     "voices": {"enabled": true, "suggestions": [
       {"label": "Собеседник 2", "person_id": "p1", "name": "Мария", "score": 0.74},
       {"label": "Собеседник 9", "person_id": "p2", "name": "Призрак", "score": 0.9}]}}
    """
    let parsed = MeetingSpeakers.parse(Data(json.utf8))
    equal(parsed.speakers.map(\.label), ["Собеседник 1", "Собеседник 2", "Собеседник 3"], "«Я» не говорящий системы")
    equal(parsed.speakers.first?.name, "Иван", "имя из speaker_names")
    check(parsed.speakers.first?.isNamed == true && parsed.speakers[1].isNamed == false, "названа ли метка")
    equal(parsed.speakers.first?.seconds, 7, "перекрытие считается каждой части")
    equal(parsed.reviews.map(\.turn), [2, 4], "проверенная реплика снята; без review — по порогу 0,6")
    equal(parsed.reviews.first?.alternatives.map(\.name), ["Иван"], "альтернатива с именем, своя метка выброшена")
    equal(parsed.review(start: 12, speaker: "Собеседник 2")?.turn, 2, "поиск строки окна")
    check(parsed.review(start: 12, speaker: "Иван") == nil, "другое имя — не та строка")
    equal(parsed.suggestions.map(\.name), ["Мария"], "подсказка к несуществующей метке отброшена")
    check(parsed.memoryUsed && parsed.memoryAvailable, "память участвовала")
    equal(parsed.suggestion(for: "Собеседник 2")?.personID, "p1")

    let old = MeetingSpeakers.parse(Data(#"{"turns": [{"speaker": "Собеседник 1", "start": 0, "end": 1, "text": "x"}]}"#.utf8))
    equal(old.speakers.map(\.label), ["Собеседник 1"], "старая расшифровка без label и source")
    check(old.reviews.isEmpty && !old.memoryUsed, "без уверенности — без проверки")
    equal(MeetingSpeakers.parse(Data("мусор".utf8)), MeetingSpeakers(), "битый файл")

    let missing = MeetingSpeakers.parse(Data(#"{"turns": [], "voices": {"enabled": true, "available": false}}"#.utf8))
    check(missing.memoryUsed && !missing.memoryAvailable, "нет модели голоса")

    // Ответ движка voices_status.
    let reply: [String: JSONValue] = [
        "available": .bool(true), "detail": .string("/bin/fluid"), "model": .string("fluidaudio-wespeaker-v2-256"),
        "people": .array([.object(["id": .string("p1"), "name": .string("Мария"), "samples": .number(3), "seconds": .number(42)]),
                          .object(["name": .string("без id")])]),
    ]
    let status = VoiceMemoryStatus.parse(reply)
    check(status.available, "модель есть")
    equal(status.people, [VoicePerson(id: "p1", name: "Мария", samples: 3, seconds: 42)])
    let after = VoiceMemoryStatus.parse(["people": .array([])], previous: status)
    check(after.available && after.people.isEmpty, "частичный ответ не сбрасывает доступность")
}

/// Имена говорящих (E1–E3): одно имя у двух меток — один человек, поиск по имени строки, счётчик людей.
func runSpeakerNamesTests() {
    // Старая расшифровка: модель голосов разрезала Катю на две метки, обеим дали имя.
    let json = """
    {"speaker_names": {"Собеседник 1": "Катя", "Собеседник 3": "катя"},
     "turns": [
      {"id": 0, "speaker": "Я", "source": "mic", "start": 0, "end": 2, "text": "Начнём."},
      {"id": 1, "speaker": "Катя", "label": "Собеседник 1", "source": "system", "start": 2, "end": 6, "text": "a"},
      {"id": 2, "speaker": "Собеседник 2", "label": "Собеседник 2", "source": "system", "start": 6, "end": 9, "text": "b",
       "speaker_confidence": 0.3, "review": true,
       "speaker_alternatives": [{"label": "Собеседник 1", "share": 0.4}, {"label": "Собеседник 3", "share": 0.3}]},
      {"id": 3, "speaker": "катя", "label": "Собеседник 3", "source": "system", "start": 9, "end": 12, "text": "c",
       "speaker_confidence": 0.3, "review": true, "speaker_alternatives": [{"label": "Собеседник 1", "share": 0.4}]},
      {"id": 4, "speaker": "Катя + Собеседник 2", "label": "Собеседник 1 + Собеседник 2", "source": "system",
       "start": 12, "end": 13, "text": "d"}
     ]}
    """
    let parsed = MeetingSpeakers.parse(Data(json.utf8))
    equal(parsed.speakers.map(\.name), ["Катя", "Собеседник 2"], "одно имя — одна строка в списке говорящих")
    equal(parsed.speakers.first?.labels, ["Собеседник 1", "Собеседник 3"], "все метки человека")
    equal(parsed.speakers.first?.turns, 3, "реплики обеих меток")
    equal(parsed.speakers.first?.seconds, 8, "секунды обеих меток")
    equal(parsed.reviews.first { $0.turn == 2 }?.alternatives.map(\.name), ["Катя", "катя"],
          "у чужой реплики альтернативы остаются")
    check(parsed.reviews.first { $0.turn == 3 }?.alternatives.isEmpty == true,
          "альтернатива под тем же именем — тот же человек, не предлагаем")
    equal(parsed.speaker(named: "КАТЯ")?.label, "Собеседник 1", "строка расшифровки → говорящий, регистр не важен")
    check(parsed.speaker(named: "Я") == nil && parsed.speaker(named: "Катя + Собеседник 2") == nil,
          "«Я» и перекрытие не переименовываются щелчком")
    equal(parsed.speaker(named: "Собеседник 2")?.isNamed, false)
    equal(parsed.mergeTargets(for: parsed.speakers[1]).map(\.name), ["Катя"], "объединить — с остальными")

    equal(MeetingSpeakers.peopleCount(["Я", "Катя", "катя", "Собеседник 2", "Катя + Собеседник 2", "📌", ""]), 3,
          "счётчик: перекрытие и регистр не добавляют людей, пометки не считаются")
    equal(MeetingSpeakers.peopleCount([String]()), 0)
}

/// Настройки голосовой памяти: выключена по умолчанию и не включается без согласия.
func runVoiceMemorySettingsTests() {
    check(!MostikSettings().voiceMemory && !MostikSettings().voiceMemoryConsent, "по умолчанию выключено")
    let forced = try? JSONDecoder().decode(MostikSettings.self, from: Data(#"{"voiceMemory": true}"#.utf8))
    equal(forced?.voiceMemory, false, "без согласия не включается")
    let agreed = try? JSONDecoder().decode(MostikSettings.self, from: Data(#"{"voiceMemory": true, "voiceMemoryConsent": true}"#.utf8))
    equal(agreed?.voiceMemory, true, "с согласием")
}
