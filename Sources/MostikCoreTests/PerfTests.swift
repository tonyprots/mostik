import Foundation
import MostikCore

// Пакет «Плавность и быстродействие»: замеры, порядок старта записи,
// нажатия без потерь, сглаживание уровня, плашка, прогрев.
func runPerfTests() {
    // Шаг 0: отрезки диктовки в миллисекундах, первая отметка выигрывает.
    do {
        var t = DictationTimeline()
        t.mark(.hotkey, at: 10.000)
        t.mark(.hudShown, at: 10.012)
        t.mark(.hudShown, at: 10.500)  // вторая отметка не перетирает первую
        t.mark(.firstBuffer, at: 10.085)
        t.mark(.release, at: 13.0)
        t.mark(.pastePosted, at: 13.76)
        t.mark(.idle, at: 13.762)
        equal(t.ms(.hotkey, .hudShown), 12, "нажатие → плашка")
        equal(t.ms(.hotkey, .firstBuffer), 85, "нажатие → первый буфер")
        equal(t.ms(.release, .pastePosted), 760, "отпускание → ⌘V")
        equal(t.ms(.release, .engineFinal), nil, "нет отметки — нет отрезка")
        equal(t.summary, "hotkey→hud 12 ms · hotkey→buffer 85 ms · release→paste 760 ms · release→idle 762 ms",
              "строка журнала")
        equal(DictationTimeline().summary, "", "пусто — пустая строка")
    }

    // Шаг 0: раскладка хвоста из `final.timings` — в журнал числами.
    do {
        let json = #"{"audio_s": 3, "tail_ms": 412.4, "primary_ms": 1, "verifier_ms": 0, "total_ms": 2, "queued_ms": 120,"#
            + #" "remainder_ms": 230.6, "verifier_wait_ms": 0, "prepare_ms": 2700, "model_load_ms": 2650}"#
        let t = try? JSONDecoder().decode(Timings.self, from: Data(json.utf8))
        equal(t?.modelLoadMs, 2650, "загрузка модели")
        equal(t?.breakdown, "tail 412 ms · queued 120 ms · remainder 231 ms · verifier_wait 0 ms · prepare 2700 ms · model_load 2650 ms")
        let old = try? JSONDecoder().decode(Timings.self, from: Data(#"{"tail_ms": 5}"#.utf8))
        equal(old?.queuedMs, nil, "старый движок — без раскладки")
        equal(old?.breakdown, "tail 5 ms")
    }

    // Шаг 1, п. 1: звук до `start` движку копится и уходит после него, по порядку.
    do {
        let gate = StartGate<Int>()
        var sent: [Int] = []
        gate.push(1); gate.push(2)
        equal(sent, [], "до открытия ничего не уходит")
        gate.open { sent.append($0) }
        equal(sent, [1, 2], "накопленное — сразу и по порядку")
        gate.push(3)
        equal(sent, [1, 2, 3], "после открытия — напрямую")
        let dropped = StartGate<Int>()
        var none: [Int] = []
        dropped.push(1)
        dropped.close()
        dropped.push(2)
        dropped.open { none.append($0) }
        equal(none, [], "закрытый шлюз (отмена до старта) не отдаёт ничего")
        equal(dropped.pendingCount, 0, "и ничего не держит")
    }

    // Шаг 1, п. 1: обход AX-родителей ограничен по глубине и по времени.
    do {
        var budget = AXWalkBudget(maxDepth: 40, deadline: 0.1, startedAt: 5.0)
        check(budget.allowsStep(now: 5.0), "первый шаг")
        for _ in 0..<10 { _ = budget.allowsStep(now: 5.05) }
        check(!budget.allowsStep(now: 5.11), "100 мс прошло — стоп")
        var deep = AXWalkBudget(maxDepth: 3, deadline: 10, startedAt: 0)
        equal((0..<10).filter { _ in deep.allowsStep(now: 0) }.count, 3, "не глубже maxDepth")
        equal(AXWalkBudget.standardDeadline, 0.1, "общий срок обхода — 100 мс")
        check(AXWalkBudget.messagingTimeout(left: 0.03) <= 0.03, "таймаут AX-вызова не больше остатка срока")
        check(AXWalkBudget.messagingTimeout(left: 5) <= 0.2, "и не больше прежних 0,2 с")
    }

    // Шаг 1, п. 3: машина свободна сразу после ⌘V — нажатие во время проверки вставки не теряется.
    do {
        var m = DictationMachine(minimumHold: 0.25, makeSessionID: { "s" })
        m.handle(.holdBegan(at: 0))
        m.handle(.holdEnded(at: 2))
        equal(m.handle(.resultReady), [.insertResult(session: "s")])
        equal(m.handle(.holdBegan(at: 2.5)), [], "во время вставки до ⌘V нажатие ещё не принять")
        equal(m.droppedPresses, 1, "и оно посчитано как отброшенное")
        equal(m.handle(.pastePosted), [], "⌘V ушёл")
        equal(m.state, .idle, "машина свободна, проверка вставки идёт в фоне")
        equal(m.handle(.holdBegan(at: 2.7)), [.startRecording(session: "s")], "новое нажатие сразу пишет")
        equal(m.handle(.inserted), [], "поздний «вставлено» прошлой сессии не трогает новую запись")
        check(m.currentSession == "s", "запись идёт")
        equal(m.acceptedPresses, 2, "принятые нажатия")
        var t = DictationMachine(minimumHold: 0.25, makeSessionID: { "t" })
        t.handle(.holdBegan(at: 0)); t.handle(.holdEnded(at: 1))
        t.handle(.holdBegan(at: 1.5))
        equal(t.droppedPresses, 1, "нажатие во время расшифровки — отброшено (полный вариант не делали)")
        equal(t.handle(.pastePosted), [], "⌘V без вставки — ничего")
    }

    // Шаг 3, п. 12: уровень — атака мгновенная, спад ~120 мс (×0,75 за тик 50 мс).
    do {
        equal(LevelSmoothing.next(previous: 0.2, sample: 0.9), 0.9, "рост мгновенный")
        check(abs(LevelSmoothing.next(previous: 0.8, sample: 0.0) - 0.6) < 1e-6, "спад плавный")
        var v: Float = 1
        var ticks = 0
        while v > 0.1 { v = LevelSmoothing.next(previous: v, sample: 0); ticks += 1 }
        check(ticks >= 5 && ticks <= 10, "с 1 до 0,1 за 250–500 мс: \(ticks) тиков")
        var ring: [Float] = Array(repeating: 0, count: 4)
        LevelSmoothing.push(0.8, into: &ring)
        LevelSmoothing.push(0.0, into: &ring)
        check(ring.count == 4 && ring[2] == 0.8 && abs(ring[3] - 0.6) < 1e-6, "буфер едет лентой, новое в конце: \(ring)")
    }

    // Декоративное: иконка строки меню «дышит» голосом не чаще 10 раз в секунду.
    do {
        var meter = MenuBarMeter()
        equal(meter.update(level: 0.9, at: 0), 3, "первое значение сразу")
        equal(meter.update(level: 0.1, at: 0.05), nil, "чаще 10 Гц — нет")
        equal(meter.update(level: 0.1, at: 0.11), 0, "через 100 мс — новое")
        equal(meter.update(level: 0.12, at: 0.3), nil, "та же ступень — без перерисовки")
        var emitted = 0
        var m2 = MenuBarMeter()
        for i in 0..<200 { if m2.update(level: Float(i % 7) / 6, at: Double(i) * 0.05) != nil { emitted += 1 } }
        check(emitted <= 101, "за 10 с не больше 100 обновлений: \(emitted)")
        equal(MenuBarMeter.steps, 4, "четыре ступени")
        equal(MenuBarMeter.variableValue(step: 3), 1.0)
        equal(MenuBarMeter.variableValue(step: 0), 0.25, "тишина — не пусто: значок записи виден")
    }

    // Шаг 3, п. 13: экран плашки фиксируется на старте, смена фаз не переносит её.
    do {
        check(HUDPlacement.reposition(wasVisible: false, phaseVisible: true), "показ — к курсору")
        check(!HUDPlacement.reposition(wasVisible: true, phaseVisible: true), "смена фазы — на месте")
        check(!HUDPlacement.reposition(wasVisible: true, phaseVisible: false), "скрытие — на месте")
        equal(HUDPlacement.showDuration, 0.12)
        equal(HUDPlacement.hideDuration, 0.15)
    }

    // Шаг 1, п. 5: прогрев после сна — без задержки; после разблокировки — как было.
    do {
        let w = WarmupPolicy()
        equal(w.delay(afterSleep: true), 0, "после сна — сразу")
        equal(w.delay(afterSleep: false), 3, "разблокировка без сна — через 3 с")
    }

    // Шаг 1, п. 7: локальную LLM прогреваем, только если причёсывание на MLX включено.
    do {
        var s = MostikSettings()
        equal(WarmupPolicy.polishBackendToWarm(s), nil, "по умолчанию причёсывание выключено — LLM не греем")
        s.polish.backend = .mlx
        equal(WarmupPolicy.polishBackendToWarm(s), s.polish.effectiveBackend == .mlx ? "mlx" : nil, "MLX — греем")
        s.polish.backend = .claude
        equal(WarmupPolicy.polishBackendToWarm(s), nil, "claude — облако, греть нечего")
    }

    // Шаг 2, п. 10: частые правки (ввод в поле) сводятся в одну запись после паузы.
    do {
        var c = Coalescer<String>(delay: 0.4)
        c.submit("a", at: 0)
        c.submit("ab", at: 0.1)
        c.submit("abc", at: 0.2)
        equal(c.due(at: 0.5), nil, "пауза ещё не 400 мс от последней правки")
        equal(c.due(at: 0.61), "abc", "после паузы — последнее значение")
        equal(c.due(at: 1.0), nil, "один раз")
        c.submit("x", at: 2)
        equal(c.flush(), "x", "выход — записать сразу")
        equal(c.flush(), nil)
        equal(c.deadline, nil, "ничего не ждём")
    }

    // Мелочь: в пустой истории — клавиша записи из настроек, без чужих клавиш вокруг.
    do {
        equal(HoldKeys.emptyStateCaps("rightOption").count, 1, "одна клавиша")
        equal(HoldKeys.emptyStateCaps("rightCommand").first?.symbol, "⌘")
        equal(HoldKeys.emptyStateCaps("fn").first?.symbol, "fn")
        check(!HoldKeys.emptyStateCaps("rightOption").contains { $0.symbol == "⌘" }, "декоративного ⌘ нет")
    }
}

// Шаг 2, п. 10: ввод команды хука сводится в одну запись отпечатка с тем же итогом.
func runHookCoalesceTests() {
    final class Store: HookDigestStore {
        var stored: String?
        var writes = 0
        func read() -> HookDigestRead { stored.map { .value($0) } ?? .missing }
        func write(_ digest: String) -> Bool { stored = digest; writes += 1; return true }
    }
    var a = MeetingHookSettings(); a.enabled = true; a.command = "echo"
    var b = a; b.command = "echo 1"
    var off = a; off.enabled = false
    check(MeetingHookTrust.isCommandEdit(old: a, new: b), "ввод в поле включённого хука — копится")
    check(!MeetingHookTrust.isCommandEdit(old: off, new: a), "включение — сразу")
    check(!MeetingHookTrust.isCommandEdit(old: a, new: off), "выключение — сразу")
    let step = Store(), once = Store()
    var prev = a
    for text in ["echo 1", "echo 12", "echo 123"] {
        var next = prev; next.command = text
        MeetingHookTrust.applyChange(old: prev, new: next, store: step)
        prev = next
    }
    MeetingHookTrust.applyChange(old: a, new: prev, store: once)
    equal(once.stored, step.stored, "одна запись после паузы — тот же отпечаток")
    equal(once.writes, 1, "и одна запись в связку ключей вместо трёх")
}

// Шаг 3, пп. 11, 13, 14 и декоративное: числа движения и «Уменьшить движение».
func runMotionSpecTests() {
    equal(MotionSpec.phaseSpring, MotionSpec.Spring(response: 0.24, damping: 1.0), "пружина фаз плашки")
    equal(MotionSpec.tabIndicator, MotionSpec.Spring(response: 0.28, damping: 1.0), "подложка вкладок")
    equal(MotionSpec.transition(reduceMotion: true), .fade, "«Уменьшить движение» — только затухание")
    equal(MotionSpec.transition(reduceMotion: false), .shiftAndFade)
    check(!MotionSpec.scrollAnimated(reduceMotion: true), "прокрутка — сразу")
    check(!MotionSpec.recordingDotPulses(reduceMotion: true), "точка записи статична")
    check(MotionSpec.glyphAnimates(reduceMotion: false, alreadyPlayed: false), "знак оживает в первый раз")
    check(!MotionSpec.glyphAnimates(reduceMotion: false, alreadyPlayed: true), "и только один раз")
    check(!MotionSpec.glyphAnimates(reduceMotion: true, alreadyPlayed: false), "при «Уменьшить движение» — статичен")
}
