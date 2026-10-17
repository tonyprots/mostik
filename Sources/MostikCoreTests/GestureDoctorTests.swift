import Foundation
import MostikCore

/// Жесты клавиши (H1, H4), защёлка в машине, «Проверка» и правила повторов (R7), прогрев (R6).
func runGestureDoctorTests() {
    // H1: удержание при уже зажатом модификаторе — не диктовка.
    var g = HoldGesture()
    equal(g.handle(.holdDown(otherModifiers: true)), [], "⌘ + правый ⌥ — чужое сочетание")
    equal(g.handle(.modifierDown), [], "в чужом сочетании защёлки нет")
    equal(g.handle(.holdUp), [], "отпускание чужого сочетания ничего не значит")
    equal(g.phase, .up)

    // H1: ⌥+буква отменяет запись, начатую удержанием; отпускание потом молчит.
    equal(g.handle(.holdDown(otherModifiers: false)), [.begin])
    g.recordingStarted(true)
    equal(g.handle(.keyDown(space: false)), [.cancel], "⌥+буква")
    equal(g.handle(.keyDown(space: false)), [], "вторая буква — уже ничего")
    equal(g.handle(.holdUp), [])

    // Удержание пришлось на идущую запись (остановка без рук) — буквы её не отменяют.
    equal(g.handle(.holdDown(otherModifiers: false)), [.begin])
    g.recordingStarted(false)
    equal(g.handle(.keyDown(space: false)), [], "чужую запись буква не трогает")
    equal(g.handle(.modifierDown), [], "и защёлки на чужой записи нет")
    equal(g.handle(.holdUp), [.end])

    // H4: модификатор во время удержания — защёлка; отпускание не останавливает.
    g.handle(.holdDown(otherModifiers: false)); g.recordingStarted(true)
    equal(g.handle(.modifierDown), [.latch], "правый ⌥ + ⇧")
    equal(g.phase, .latched)
    equal(g.handle(.modifierDown), [], "второй модификатор — без повтора")
    equal(g.handle(.holdUp), [], "отпущено после защёлки")
    equal(g.phase, .up)

    // ⌥⇧+буква: защёлка была, но это набор символа — отмена.
    g.handle(.holdDown(otherModifiers: false)); g.recordingStarted(true)
    g.handle(.modifierDown)
    equal(g.handle(.keyDown(space: false)), [.cancel], "⌥⇧+буква")
    g.handle(.holdUp)

    // Защёлка выключена — модификатор ничего не делает, отпускание останавливает.
    var off = HoldGesture(latchEnabled: false)
    off.handle(.holdDown(otherModifiers: false)); off.recordingStarted(true)
    equal(off.handle(.modifierDown), [])
    equal(off.handle(.holdUp), [.end])

    // ⌥Space во время удержания: своё удержание отменяется, переключатель решает сам.
    g.handle(.holdDown(otherModifiers: false)); g.recordingStarted(true)
    equal(g.handle(.toggle), [.cancel])
    equal(g.handle(.holdUp), [])
    // Пробел без переключателя — обычная буква.
    g.handle(.holdDown(otherModifiers: false)); g.recordingStarted(true)
    equal(g.handle(.keyDown(space: true)), [], "пробел ловит Carbon")
    equal(g.handle(.escape(recording: true)), [.cancel], "Esc")
    equal(g.handle(.holdUp), [], "после Esc отпускание молчит")
    equal(g.handle(.escape(recording: false)), [], "Esc без записи")

    // Машина: защёлка переводит запись в режим без рук, следующее нажатие останавливает.
    var m = DictationMachine(makeSessionID: { "L" })
    equal(m.minimumHold, 0.3, "H1: порог 0,3 с")
    m.handle(.holdBegan(at: 0))
    equal(m.handle(.latch), [])
    check(m.isHandsFree, "после защёлки — без рук")
    equal(m.handle(.holdEnded(at: 0.8)), [], "отпускание после защёлки")
    equal(m.state, .recording(session: "L", startedAt: 0, toggled: true))
    equal(m.handle(.holdBegan(at: 5)), [.stopRecording(session: "L")], "следующее нажатие останавливает")
    equal(m.handle(.latch), [], "защёлка вне записи ничего не делает")

    // Защёлка на втором нажатии двойного (D1) не ломает его: остаётся без рук.
    var d = DictationMachine(makeSessionID: { "D" })
    d.handle(.holdBegan(at: 0)); d.handle(.holdEnded(at: 0.1))
    d.handle(.holdBegan(at: 0.3))
    d.handle(.latch)
    equal(d.handle(.holdEnded(at: 2)), [], "второе нажатие с защёлкой")
    check(d.isHandsFree)
    equal(d.handle(.holdBegan(at: 4)), [.stopRecording(session: "D")])
    // Без двойного нажатия тап 0,28 с теперь отбрасывается (раньше порог был 0,25).
    var plain = DictationMachine(makeSessionID: { "P" })
    plain.doubleTapEnabled = false
    plain.handle(.holdBegan(at: 0))
    equal(plain.handle(.holdEnded(at: 0.28)), [.discardRecording(session: "P")], "тап короче 0,3 с")

    // R7: «Проверка».
    var f = DoctorFacts()
    f.microphone = .denied
    f.accessibility = true
    f.postEvents = false
    f.holdKey = "fn"
    f.fnUsage = 1
    f.engine = .failed("python не найден")
    f.missingModels = ["GigaAM v3"]
    f.freeBytes = 1_500_000_000
    f.llmBackend = "claude"
    f.llmAvailable = false
    f.loginItem = .init(wanted: true, state: .requiresApproval)
    let checks = Doctor.evaluate(f, russian: true)
    func check_(_ kind: DoctorCheck.Kind) -> DoctorCheck? { checks.first { $0.kind == kind } }
    equal(checks.count, DoctorCheck.Kind.allCases.count, "строка на каждую проверку")
    equal(check_(.microphone)?.fix, .openMicrophone, "отказ — в Настройки")
    equal(check_(.postEvents)?.fix, .relaunch, "доступ выдан на ходу — перезапуск")
    equal(check_(.hotkey)?.status, .warning, "fn переключает раскладку")
    equal(check_(.hotkey)?.fix, .openKeyboard)
    equal(check_(.engine)?.fix, .restartEngine)
    check(check_(.models)?.detail.contains("GigaAM v3") == true, "какой модели нет")
    equal(check_(.models)?.fix, .downloadModels, "кнопка «Скачать»")
    check(check_(.models)?.detail.contains("transcriber") == false, "без внутренних имён")
    equal(check_(.disk)?.status, .failed, "1,5 ГБ — мало")
    check(check_(.disk)?.detail.contains("1,5\u{00A0}ГБ") == true, "размер по-русски")
    equal(check_(.llm)?.status, .warning)
    equal(Doctor.worst(checks), .failed)

    var good = DoctorFacts()
    good.microphone = .authorized; good.accessibility = true; good.postEvents = true; good.systemAudio = true
    good.engine = .ready; good.missingModels = []; good.diarizationAvailable = true; good.freeBytes = 50_000_000_000
    good.fnUsage = 1  // fn занята, но клавиша записи — правый ⌥
    let fine = Doctor.evaluate(good, russian: false)
    equal(Doctor.worst(fine), .ok, "всё в порядке")
    good.keyGrabbers = ["Punto Switcher"]
    good.freeBytes = 8_000_000_000
    let warned = Doctor.evaluate(good, russian: true)
    equal(Doctor.worst(warned), .warning, "Punto и 8 ГБ — предупреждения")
    good.microphone = .undetermined
    equal(Doctor.evaluate(good, russian: true).first { $0.kind == .microphone }?.fix, .requestMicrophone)

    // Разделение встреч по голосам (fluidaudiocli): строка в «Проверке» — есть или нет на этом Mac.
    var voices = DoctorFacts()
    func split(_ facts: DoctorFacts, _ ru: Bool = true) -> DoctorCheck? { Doctor.evaluate(facts, russian: ru).first { $0.kind == .diarization } }
    equal(split(voices)?.status, .unknown, "движок ещё не ответил")
    voices.diarizationAvailable = true
    equal(split(voices)?.status, .ok)
    voices.diarizationAvailable = false
    equal(split(voices)?.status, .warning, "встречи расшифровываются, но без голосов — не ошибка")
    check(split(voices)?.detail.contains("Собеседник 1") == true, "что будет со встречей")
    check(split(voices, false)?.detail.contains("one speaker") == true,
          "по-английски")
    equal(split(voices)?.fix, nil, "причина не в моделях — качать нечего")
    voices.diarizationDownloadBytes = 34_000_000
    equal(split(voices)?.fix, .downloadDiarization, "модели голосов — по кнопке")
    check(split(voices)?.detail.contains("34\u{00A0}МБ") == true, "размер в мегабайтах")

    // отказ в звуке системы виден в «Проверке».
    var silent = DoctorFacts()
    silent.systemAudioSilent = true
    let audio = Doctor.evaluate(silent, russian: true).first { $0.kind == .systemAudio }
    equal(audio?.status, .warning, "тишина системной дорожки при живом микрофоне — предупреждение")
    equal(audio?.fix, .openSystemAudio)
    check(MeetingAudioText.pane(russian: true, macOS15: true).contains("Запись экрана и системного звука"), "Sequoia: общая панель")
    check(MeetingAudioText.pane(russian: true, macOS15: false).contains("Запись звука системы"), "Sonoma: своя панель")
    check(MeetingAudioText.systemSilent(russian: false).contains("system audio"))

    // R7: отказ в микрофоне — один раз, напоминание через 10 минут, сброс после выдачи.
    var gate = FailureGate()
    equal(gate.permanent("mic", at: 0), .report)
    equal(gate.permanent("mic", at: 5), .silent)
    equal(gate.permanent("mic", at: 599), .silent)
    equal(gate.permanent("mic", at: 601), .report, "напоминание")
    gate.succeeded("mic")
    equal(gate.permanent("mic", at: 602), .report, "после выдачи — снова сообщаем")
    // Временные сбои — повтор с паузой, потом сдаёмся.
    equal(gate.transient("rec"), .retry(after: 0.3))
    equal(gate.transient("rec"), .retry(after: 1.0))
    equal(gate.transient("rec"), .giveUp)
    gate.succeeded("rec")
    equal(gate.transient("rec"), .retry(after: 0.3), "после успеха счётчик заново")

    // R6: прогрев не чаще раза в 2 минуты, не во время работы; после сна — всегда.
    var warm = WarmupPolicy()
    warm.warmed(at: 100)
    check(!warm.shouldWarm(at: 150, busy: false), "только что прогрели")
    check(warm.shouldWarm(at: 150, busy: false, afterSleep: true), "после сна")
    check(!warm.shouldWarm(at: 400, busy: true), "идёт диктовка")
    check(warm.shouldWarm(at: 400, busy: false), "прошло больше 2 минут")
}
