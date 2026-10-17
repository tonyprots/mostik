import Foundation
import MostikCore

/// Пункт «Записать голос» в меню строки меню: старт и стоп как у двойного нажатия, подпись и таймер,
/// подсказка клавиши, выбор приложения, куда вернуть фокус и вставить текст.
func runMenuVoiceTests() {
    // MARK: переключение старт/стоп — через ту же машину, что двойное нажатие
    do {
        var m = DictationMachine(minimumHold: 0.25, makeSessionID: { "v1" })
        equal(MenuVoice.phase(m.state), .idle)
        var effects: [DictationEffect] = []
        for input in MenuVoice.inputs(m.state, at: 1) { effects += m.handle(input) }
        equal(effects, [.startRecording(session: "v1")], "первое нажатие пункта начинает запись")
        equal(m.state, .recording(session: "v1", startedAt: 1, toggled: true), "запись без удержания, как после двойного нажатия")
        equal(MenuVoice.phase(m.state), .recording)
        equal(m.handle(.holdEnded(at: 1.2)), [], "отпускание клавиши запись из меню не останавливает")

        effects = []
        for input in MenuVoice.inputs(m.state, at: 6) { effects += m.handle(input) }
        equal(effects, [.stopRecording(session: "v1")], "второе нажатие останавливает")
        equal(m.state, .transcribing(session: "v1", audioSeconds: 5))
        equal(MenuVoice.phase(m.state), .busy)
        equal(MenuVoice.inputs(m.state, at: 7), [], "во время расшифровки пункт ничего не делает")
        m.handle(.resultReady)
        equal(MenuVoice.phase(m.state), .busy, "вставка — тоже занято")
        m.handle(.inserted)
        equal(MenuVoice.phase(m.state), .idle)

        // Запись без рук от двойного нажатия останавливается пунктом меню.
        var d = DictationMachine(minimumHold: 0.25, makeSessionID: { "d" })
        d.handle(.holdBegan(at: 0)); d.handle(.holdEnded(at: 0.1)); d.handle(.holdBegan(at: 0.3)); d.handle(.holdEnded(at: 0.35))
        equal(MenuVoice.phase(d.state), .recording)
        effects = []
        for input in MenuVoice.inputs(d.state, at: 3) { effects += d.handle(input) }
        equal(effects, [.stopRecording(session: "d")], "двойное нажатие → стоп из меню")
        check(!d.isHandsFree, "режим без рук сброшен")

        // Держат клавишу и жмут пункт: запись останавливается, а не игнорируется.
        var h = DictationMachine(minimumHold: 0.25, makeSessionID: { "h" })
        h.handle(.holdBegan(at: 0))
        effects = []
        for input in MenuVoice.inputs(h.state, at: 2) { effects += h.handle(input) }
        equal(effects, [.stopRecording(session: "h")], "удержание → стоп из меню")

        // После ошибки пункт снова начинает запись.
        var f = DictationMachine(minimumHold: 0.25, makeSessionID: { "f" })
        f.handle(.togglePressed(at: 0)); f.handle(.failure("x"))
        equal(MenuVoice.phase(f.state), .idle, "ошибка — снова можно записать")
        equal(MenuVoice.inputs(f.state, at: 1), [.togglePressed(at: 1)])
    }

    // MARK: подпись и таймер
    do {
        let was = UIText.isRussian
        defer { UIText.isRussian = was }
        UIText.isRussian = true
        equal(MenuVoice.title(.idle), "Записать голос")
        equal(MenuVoice.title(.recording), "Остановить запись")
        equal(MenuVoice.title(.busy), "Расшифровка…")
        UIText.isRussian = false
        equal(MenuVoice.title(.idle), "Record voice")
        equal(MenuVoice.title(.recording), "Stop recording")
        equal(MenuVoice.title(.busy), "Transcribing…")

        equal(MenuVoice.timer(0), "0:00")
        equal(MenuVoice.timer(7.9), "0:07", "секунды вниз, без скачка вперёд")
        equal(MenuVoice.timer(65), "1:05")
        equal(MenuVoice.timer(3725), "1:02:05")
        equal(MenuVoice.timer(-3), "0:00")
        equal(MenuVoice.timer(.nan), "0:00")
        equal(MenuVoice.timer(.infinity), "0:00")
        // Таймер виден только во время записи.
        equal(MenuVoice.trailing(.recording, elapsed: 12), "0:12")
        equal(MenuVoice.trailing(.idle, elapsed: 12), nil)
        equal(MenuVoice.trailing(.busy, elapsed: 12), nil)
    }

    // MARK: подсказка клавиши — клавиша записи из настроек, нажатая дважды
    do {
        equal(MenuVoice.shortcut(holdKey: "rightOption", doubleTap: true, toggleShortcut: true), "⌥⌥")
        equal(MenuVoice.shortcut(holdKey: "rightCommand", doubleTap: true, toggleShortcut: true), "⌘⌘")
        equal(MenuVoice.shortcut(holdKey: "fn", doubleTap: true, toggleShortcut: false), "fn fn")
        equal(MenuVoice.shortcut(holdKey: "rightCommand", doubleTap: false, toggleShortcut: true), "⌥Space",
              "двойное нажатие выключено — переключатель ⌥Space")
        equal(MenuVoice.shortcut(holdKey: "rightOption", doubleTap: false, toggleShortcut: false), "", "сочетаний нет — без подсказки")
        var s = MostikSettings()
        s.holdKey = "rightCommand"
        equal(MenuVoice.shortcut(settings: s), "⌘⌘", "из настроек")
    }

    // MARK: какое приложение было впереди до меню
    do {
        let safari = AppRef(pid: 10, bundleID: "com.apple.Safari", name: "Safari")
        let notes = AppRef(pid: 11, bundleID: "com.apple.Notes", name: "Notes")
        let own = AppRef(pid: 99, bundleID: "app.mostik.mac", name: "Mostik")
        var memory = FrontAppMemory(ownPID: 99)
        equal(memory.last, nil)
        memory.activated(safari)
        memory.activated(own)
        equal(memory.last, safari, "сам Mostik (меню, окна) не считается")
        memory.activated(notes)
        memory.activated(nil)
        equal(memory.last, notes, "пустое уведомление не стирает прежнее")
        memory.activated(AppRef(pid: 99, bundleID: "", name: ""))
        equal(memory.last, notes, "свой процесс без bundle id (swift run) — тоже свой")
        memory.terminated(pid: 11)
        equal(memory.last, nil, "закрылось — забыли")
    }

    // MARK: цель вставки
    do {
        let safari = AppRef(pid: 10, bundleID: "com.apple.Safari", name: "Safari")
        equal(MenuVoice.target(remembered: safari, isRunning: { _ in true }), .app(safari))
        equal(MenuVoice.target(remembered: safari, isRunning: { _ in false }), .clipboard(.appClosed), "закрылось до нажатия")
        equal(MenuVoice.target(remembered: nil, isRunning: { _ in true }), .clipboard(.noApp), "впереди ничего не было")
        equal(MenuVoice.target(remembered: AppRef(pid: 0, bundleID: "", name: ""), isRunning: { _ in true }), .clipboard(.noApp))

        // К вставке: цель ещё жива — вставляем как обычно, закрыта — честно в буфер.
        equal(MenuVoice.delivery(.app(safari), isRunning: { _ in true }), nil, "обычная вставка")
        equal(MenuVoice.delivery(.app(safari), isRunning: { _ in false }), .appClosed, "закрыли во время записи")
        equal(MenuVoice.delivery(.clipboard(.noApp), isRunning: { _ in true }), .noApp)
        equal(MenuVoice.delivery(nil, isRunning: { _ in false }), nil, "диктовка с клавиши — без правил меню")

        // Вернуть фокус элементу, только если приложение переставило его на другой.
        check(!MenuVoice.needsRefocus(remembered: 5, current: 5))
        check(MenuVoice.needsRefocus(remembered: 5, current: 6))
        check(MenuVoice.needsRefocus(remembered: 5, current: nil))
        check(!MenuVoice.needsRefocus(remembered: nil, current: 6), "не знали элемент — не трогаем")

        // Подпись на плашке: честно, почему текст в буфере.
        let was = UIText.isRussian
        defer { UIText.isRussian = was }
        UIText.isRussian = true
        equal(MenuVoice.clipboardSummary(MenuClipboardReason.appClosed.rawValue), "В буфере — приложение закрыто")
        equal(MenuVoice.clipboardSummary(MenuClipboardReason.noApp.rawValue), "В буфере — некуда вставить")
        equal(MenuVoice.clipboardSummary("focus_changed"), nil, "чужие причины — не наши подписи")
        UIText.isRussian = false
        equal(MenuVoice.clipboardSummary("app_closed"), "On clipboard — the app was closed")
        equal(MenuVoice.clipboardSummary("no_target"), "On clipboard — nowhere to paste")
    }

    // MARK: страж по исходнику меню (отзыв автора, A1–A6)
    do {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let menu = (try? String(contentsOf: root.appendingPathComponent("Sources/MostikUI/MenuBarContentView.swift"),
                                encoding: .utf8)) ?? ""
        check(!menu.isEmpty, "MenuBarContentView.swift найден")
        check(!menu.contains("Project glossary"), "A1: строки словаря проекта в меню нет")
        check(menu.contains("StatusDot(color: engine.color)") && menu.contains("L(\"Готов\", \"Ready\")"),
              "A2: состояние движка — в шапке, «Готов»")
        check(menu.contains("Text(holdHint)"), "у «Записать голос» — клавиша удержания")
        check(!menu.contains("Paste last dictation"), "A3: «Вставить последнюю ещё раз» убран")
        check(!menu.contains("Undo last insertion"), "A4: «Отменить последнюю вставку» убран")
        check(!menu.contains("Replace with text as spoken"), "A5: «Заменить текстом как сказано» убран")
        check(!menu.contains("Dictation language"), "A6: переключателя языка в меню нет")
    }
}

/// «Проверить обновления…»: пока адрес ленты — заглушка, пункта нет нигде; с настоящим https-адресом он возвращается сам.
func runUpdateMenuItemTests() {
    let key = "vFN3VIE+RUf1wngsuwVO8xrecSq/7ZroB+K7rkHaScM="
    let stub = "https://example.invalid/mostik/appcast.xml"
    let real = "https://mostik.app/appcast.xml"
    check(!UpdatePolicy.showsCheckForUpdates(feedURL: stub), "заглушка .invalid — пункта нет")
    check(!UpdatePolicy.showsCheckForUpdates(feedURL: nil), "без SUFeedURL — пункта нет")
    check(!UpdatePolicy.showsCheckForUpdates(feedURL: "http://mostik.app/appcast.xml"), "не https — пункта нет")
    check(UpdatePolicy.showsCheckForUpdates(feedURL: real), "настоящая лента — пункт есть")
    // Лента настоящая, но сборка без модуля обновлений или без ключа — пункт остаётся и объясняет почему.
    check(UpdatePolicy.unavailableMessage(UpdatePolicy.availability(feedURL: real, publicKey: nil, frameworkPresent: true), russian: true) != nil)
    check(UpdatePolicy.unavailableMessage(UpdatePolicy.availability(feedURL: real, publicKey: key, frameworkPresent: false), russian: false) != nil)
    // swift run и сборка без Sparkle с заглушкой: Sparkle скажет «нет модуля», но пункт решает адрес ленты — его нет.
    equal(UpdatePolicy.availability(feedURL: stub, publicKey: key, frameworkPresent: false), .frameworkMissing)
    check(!UpdatePolicy.showsCheckForUpdates(feedURL: stub))
    // Фразу про незаданный адрес пользователь не видит ни на каком языке.
    for ru in [true, false] {
        equal(UpdatePolicy.unavailableMessage(.feedNotConfigured, russian: ru)?.title, nil, "заглушка — без окна, ru=\(ru)")
    }
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var sources = ""
    for folder in ["Sources/MostikCore", "Sources/MostikKit", "Sources/MostikUI", "Sources/Mostik"] {
        let dir = root.appendingPathComponent(folder)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".swift") {
            sources += (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }
    }
    check(!sources.contains("has not been set yet"), "английская фраза про незаданный адрес удалена")
    check(!sources.contains("откуда Mostik берёт обновления"), "русская фраза про незаданный адрес удалена")
    // Пункт меню строки меню виден только по `updatesCheckable`.
    let menu = (try? String(contentsOf: root.appendingPathComponent("Sources/MostikUI/MenuBarContentView.swift"), encoding: .utf8)) ?? ""
    check(menu.contains("if model.updatesCheckable"), "пункт меню завязан на UpdatePolicy")
    // Автопроверка — тоже только с настоящей лентой.
    check(!UpdatePolicy.checksAutomatically(.feedNotConfigured))
}
