import Foundation
import MostikCore

/// Запись встречи в строке меню (решение автора): окошка внизу экрана нет,
/// значок показывает запись и время, меню — раздел со всеми действиями и «Завершить».
func runMeetingMenuTests() {
    let wasRussian = UIText.isRussian
    defer { UIText.isRussian = wasRussian }
    UIText.isRussian = true

    // Состояние.
    equal(MeetingMenu.state(recording: false, paused: false), .off)
    equal(MeetingMenu.state(recording: false, paused: true), .off, "пауза без записи — записи нет")
    equal(MeetingMenu.state(recording: true, paused: false), .recording)
    equal(MeetingMenu.state(recording: true, paused: true), .paused)

    // Заголовок раздела и формат времени.
    equal(MeetingMenu.title(.off, elapsed: 754), nil, "без записи раздела нет")
    equal(MeetingMenu.title(.recording, elapsed: 754.9), "Запись встречи · 12:34", "секунды вниз")
    equal(MeetingMenu.title(.recording, elapsed: 0), "Запись встречи · 0:00")
    equal(MeetingMenu.title(.recording, elapsed: 3723), "Запись встречи · 1:02:03", "больше часа — с часами")
    equal(MeetingMenu.title(.paused, elapsed: 61), "Встреча на паузе · 1:01")
    equal(MeetingMenu.title(.recording, elapsed: -5), "Запись встречи · 0:00", "отрицательное время — ноль")

    // Кнопки: пауза или продолжить, затем «Завершить» — последней.
    equal(MeetingMenu.actions(.off), [])
    equal(MeetingMenu.actions(.recording), [.pause, .finish])
    equal(MeetingMenu.actions(.paused), [.resume, .finish])
    equal(MeetingMenu.label(.finish), "Завершить")
    equal(MeetingMenu.label(.pause), "Пауза")
    equal(MeetingMenu.label(.resume), "Продолжить")
    check(MeetingMenu.help(.finish).contains("сохранить"), "«Завершить» — сохранение, не отмена")

    // Пометки: последние три.
    equal(MeetingMenu.recentMarks([1, 2, 3, 4, 5]), [3, 4, 5])
    equal(MeetingMenu.recentMarks([Int]()), [])

    // Слайды звонка (W26): переключатель «Слайды» у кнопки записи; «Только текст» из меню убран.
    equal(MeetingMenu.framesTitle(on: true, count: 3), "Снимать слайды звонка — снято 3")
    equal(MeetingMenu.framesTitle(on: false, count: 0), "Снимать слайды звонка — только эта встреча")

    // Значок строки меню.
    let idle = MenuBarStatus.look(dictation: .idle, meeting: .off, meetingElapsed: 0, reduceMotion: false)
    equal(idle.symbol, "waveform")
    equal(idle.timer, nil, "без встречи времени нет")
    equal(idle.spoken, "Mostik")
    let rec = MenuBarStatus.look(dictation: .idle, meeting: .recording, meetingElapsed: 754, reduceMotion: false)
    equal(rec.symbol, "record.circle.fill", "идёт запись встречи — значок записи")
    equal(rec.timer, "12:34", "время рядом со значком")
    check(!rec.breathes, "значок встречи не дышит — меняется только время")
    equal(rec.spoken, "Mostik, идёт запись встречи, 12:34")
    let paused = MenuBarStatus.look(dictation: .idle, meeting: .paused, meetingElapsed: 754, reduceMotion: false)
    equal(paused.symbol, "pause.circle")
    equal(paused.timer, "12:34", "на паузе время стоит")
    // «Уменьшить движение» — статично: значок записи без бегущего времени.
    let still = MenuBarStatus.look(dictation: .idle, meeting: .recording, meetingElapsed: 754, reduceMotion: true)
    equal(still.symbol, "record.circle.fill")
    equal(still.timer, nil, "без бегущего времени")
    equal(still.spoken, "Mostik, идёт запись встречи, 12:34", "VoiceOver время слышит всё равно")
    // Диктовка во время встречи: значок диктовки, время встречи остаётся.
    let dictating = MenuBarStatus.look(dictation: .recording, meeting: .recording, meetingElapsed: 60, reduceMotion: false)
    equal(dictating.symbol, "waveform.circle.fill")
    check(dictating.breathes)
    equal(dictating.timer, "1:00")
    check(!MenuBarStatus.look(dictation: .recording, meeting: .off, meetingElapsed: 0, reduceMotion: true).breathes,
          "«Уменьшить движение» — диктовка тоже не дышит")
    equal(MenuBarStatus.look(dictation: .transcribing, meeting: .off, meetingElapsed: 0, reduceMotion: false).symbol,
          "waveform.circle")

    // Английские подписи.
    UIText.isRussian = false
    equal(MeetingMenu.title(.recording, elapsed: 754), "Meeting recording · 12:34")
    equal(MeetingMenu.title(.paused, elapsed: 754), "Meeting paused · 12:34")
    equal(MeetingMenu.label(.finish), "Finish")
    equal(MenuBarStatus.look(dictation: .idle, meeting: .recording, meetingElapsed: 754, reduceMotion: false).spoken,
          "Mostik, meeting recording, 12:34")
    UIText.isRussian = true

    // Страж по исходникам: окошка записи встречи внизу экрана больше нет, «Завершить» ведёт
    // по штатному пути остановки, а отсчёт автоостановки умеет завершить сразу.
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    func source(_ path: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
    }
    let app = source("Mostik/MostikApp.swift")
    check(!app.isEmpty, "MostikApp.swift найден")
    check(!app.contains("MeetingPillView") && !app.contains("PillPanel"), "панели записи встречи внизу экрана нет")
    let menu = source("MostikUI/MenuBarContentView.swift")
    check(menu.contains("MenuMeetingSection(model: model)"), "раздел записи встречи в меню строки меню")
    let views = source("MostikUI/MeetingViews.swift")
    check(views.contains("case .finish:\n            MenuWindow.close()\n            model.onStopMeeting()"),
          "«Завершить» в меню — штатная остановка записи")
    let extras = source("MostikUI/MeetingExtrasViews.swift")
    check(extras.contains("extras.onFinishNow()"), "в отсчёте автоостановки есть «Завершить сейчас»")
    let folder = source("Mostik/MeetingFolderController.swift")
    check(folder.contains("extras.onFinishNow = { [weak self] in\n            self?.extras.prompt = nil\n            self?.stopMeeting()"),
          "«Завершить сейчас» — тот же stopMeeting, что автоостановка")
}
