import Foundation
import MostikCore

/// Настройки — вкладка главного окна (отзыв автора, B1), ⌘, и «Настройки…» открывают её.
/// Каждый переход «в Настройки» ведёт в главное окно, на эту вкладку и нужный раздел. Логика ссылок — в ядре,
/// а что экраны зовут именно её, сверяем по исходникам, как страж локализации.
func runSettingsRouteTests() {
    // Куда ведёт каждая ссылка.
    // 5 разделов (решение автора): модели и диагностика — в «Дополнительно» приватности.
    equal(SettingsRoute.panes, ["general", "text", "meetings", "agents", "privacy"], "пять разделов в порядке боковой панели")
    equal(SettingsRoute.modelsNeeded.pane, "privacy", "«Нужны модели» — в «Приватность и данные»")
    equal(SettingsRoute.modelsNeeded.reveal, SettingsRoute.advanced, "…и сразу раскрывает «Дополнительно» со списком моделей")
    equal(SettingsRoute.fullCheckup.pane, "privacy", "«Вся диагностика» — в «Приватность и данные»")
    equal(SettingsRoute.fullCheckup.reveal, SettingsRoute.advanced, "…и раскрывает «Дополнительно» с диагностикой")
    equal(SettingsRoute.hotkey.pane, "general", "«Настройки клавиши» — в «Основное»")
    equal(SettingsRoute.chooseModel.pane, "text", "«Выбрать модель» — в «Текст»")
    equal(SettingsRoute.menu.pane, nil, "строка меню и ⌘, — на разделе, где закрыли")
    for route in [SettingsRoute.hotkey, .chooseModel, .menu] {
        equal(route.reveal, nil, "\(route): ничего не раскрывает")
    }
    for pane in SettingsRoute.panes {
        equal(SettingsRoute.pane(pane).pane, pane, "«Изменить» ведёт в раздел \(pane)")
        equal(SettingsRoute.pane(pane).reveal, nil, "«Изменить» в \(pane) ничего не раскрывает")
    }
    // Старые имена разделов (их могли запомнить ссылки) ведут туда, где теперь их настройки.
    equal(SettingsRoute.pane("recognition").pane, "privacy", "«Распознавание» → «Приватность и данные»")
    equal(SettingsRoute.pane("recognition").reveal, SettingsRoute.advanced, "…в «Дополнительно»")
    equal(SettingsRoute.pane("advanced").pane, "privacy", "«Дополнительно» → «Приватность и данные»")
    equal(SettingsRoute.pane("advanced").reveal, SettingsRoute.advanced, "…раскрытое")
    for old in ["polish", "speechRules", "scenarios"] {
        equal(SettingsRoute.pane(old).pane, "text", "\(old) → «Текст»")
    }
    equal(SettingsRoute.pane("нет такого").pane, nil, "неизвестный раздел не сбрасывает выбор")
    // «Агенты» видны, только если на Mac найден агент.
    equal(SettingsRoute.visiblePanes(agentFound: true), SettingsRoute.panes, "агент найден — все пять разделов")
    equal(SettingsRoute.visiblePanes(agentFound: false), ["general", "text", "meetings", "privacy"], "агента нет — без «Агентов»")
    equal(SettingsRoute.panes, SettingsInventory.panes, "разделы ссылок совпадают с описью")

    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    func read(_ path: String) -> String { (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? "" }

    // Разделы ядра совпадают с `SettingsPane` по порядку и сырым значениям.
    let form = read("MostikUI/SettingsForm.swift")
    check(form.contains("case " + SettingsRoute.panes.joined(separator: ", ") + "\n"),
          "SettingsPane перечисляет те же разделы в том же порядке")

    // Настройки — последняя вкладка; переход на неё мимо openSettings не показал бы окно и не выбрал раздел.
    let app = read("MostikUI/AppModel.swift")
    check(app.contains("enum Tab: Hashable { case dictation, meetings, glossary, settings }"), "Настройки — вкладка главного окна")
    if let start = app.range(of: "public func openSettings(_ link: SettingsRoute)"),
       let end = app.range(of: "onOpenSettings()", range: start.upperBound..<app.endIndex) {
        check(app[start.upperBound..<end.lowerBound].contains("selectedTab = .settings"), "openSettings выбирает вкладку Настроек до показа окна")
    } else {
        check(false, "openSettings зовёт onOpenSettings()")
    }
    let main = read("MostikUI/MainWindowView.swift")
    check(main.contains("case .settings: SettingsWindowView(model: model)"), "главное окно показывает Настройки вкладкой")
    check(main.contains("(.settings, L(\"Настройки\", \"Settings\"))"), "вкладка «Настройки» в переключателе")
    for dir in ["MostikUI", "Mostik"] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(dir).path)) ?? []
        for file in files where file.hasSuffix(".swift") {
            let text = read(dir + "/" + file)
            // Снимки ставят вкладку для кадра сами.
            if file != "AppModel.swift" && !file.hasSuffix("Snapshots.swift") {
                check(!text.contains("selectedTab = .settings"), "\(file): переход в Настройки только через openSettings")
            }
            // Раздел меняют только ссылка и боковая панель самого окна; снимки задают его для кадра.
            if !file.hasSuffix("Snapshots.swift") && file != "AppModel.swift" && file != "SettingsTab.swift" {
                check(!text.contains("settingsPane = ."), "\(file): раздел Настроек выбирает openSettings, а не прямое присваивание")
            }
        }
    }

    // Каждый вход ведёт своей ссылкой.
    let sites: [(String, String, String)] = [
        ("MostikUI/MainWindowView.swift", "openSettings(.modelsNeeded)", "карточка «Нужны модели»"),
        ("MostikUI/MainWindowView.swift", "openSettings(.hotkey)", "пустая история"),
        ("MostikUI/MainWindowView.swift", "Button(\"\") { model.openSettings(.menu) }\n                .keyboardShortcut(\",\", modifiers: .command)", "⌘, в главном окне"),
        ("MostikUI/MenuBarContentView.swift", "openSettings(.menu)", "строка меню «Настройки…»"),
        ("MostikUI/MeetingAIViews.swift", "openSettings(.chooseModel)", "«Выбрать модель» у ИИ встречи"),
        ("Mostik/MeetingAssistController.swift", "openSettings(.fullCheckup)", "проверка из помощника встречи"),
        ("MostikUI/SettingsTab.swift", "Button(L(\"Открыть «\\(pane.title)»\", \"Open \\(pane.title)\")) { model.openSettings(.pane(pane.rawValue)) }",
         "«Открыть „раздел“» в сводке приватности"),
        ("Mostik/AppController.swift", "self?.refreshInputDevices()\n            self?.windows.showMain()", "контроллер открывает главное окно на Настройках"),
        ("MostikUI/SettingsTab.swift", ".onAppear { model.onSettingsShown() }", "вкладка Настроек перечитывает микрофоны при показе"),
        ("MostikUI/SettingsTab.swift", "ForEach(model.visibleSettingsPanes)", "боковая панель показывает только видимые разделы"),
        ("MostikUI/SettingsTab.swift", "open: model.settingsReveal == SettingsRoute.advanced", "«Дополнительно» раскрывается по ссылке"),
    ]
    for (file, token, what) in sites {
        check(read(file).contains(token), "\(what): \(token) в \(file)")
    }

    // Отдельного окна Настроек нет; главное окно закрывает меню строки меню (activateApp).
    let windows = read("Mostik/MostikApp.swift")
    check(!windows.contains("func showSettings()") && !windows.contains("settingsWindow"), "отдельного окна Настроек нет")
    if let start = windows.range(of: "func showMain()"),
       let end = windows.range(of: "func showOnboarding()", range: start.upperBound..<windows.endIndex) {
        let body = windows[start.upperBound..<end.lowerBound]
        check(body.contains("MenuBarPanel.activateApp()"), "showMain закрывает меню через MenuBarPanel.activateApp()")
        check(body.contains("MainWindowView(model: model)"), "showMain показывает MainWindowView")
        check(body.contains("makeKeyAndOrderFront"), "главное окно выходит вперёд")
        // B2: значок в Dock появляется до активации — окно встаёт в ⌘Tab сразу.
        if let dock = body.range(of: "setDockPresence(true)"), let activate = body.range(of: "MenuBarPanel.activateApp()") {
            check(dock.lowerBound < activate.lowerBound, "B2: значок в Dock — до активации")
        } else {
            check(false, "B2: showMain ставит значок в Dock")
        }
    } else {
        check(false, "в WindowManager есть showMain()")
    }
    // B2: Dock — только пока открыто главное окно. Политику больше никто не меняет, плашка — неактивирующая.
    check(windows.contains("NSApp.setActivationPolicy(.accessory)"), "B2: запуск — без значка в Dock")
    check(windows.contains("window === mainWindow {\n            mainWindow = nil\n            setDockPresence(false)"),
          "B2: закрыли главное окно — значок из Dock убран")
    check(windows.contains("applicationShouldHandleReopen"), "B2: щелчок по значку в Dock открывает главное окно")
    check(windows.contains("[.borderless, .nonactivatingPanel]"), "плашка диктовки — неактивирующая панель")
    for dir in ["MostikUI", "Mostik", "MostikKit"] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(dir).path)) ?? []
        for file in files where file.hasSuffix(".swift") && file != "MostikApp.swift" {
            check(!read(dir + "/" + file).contains("setActivationPolicy"), "\(file): политику Dock меняет только WindowManager")
        }
    }
}
