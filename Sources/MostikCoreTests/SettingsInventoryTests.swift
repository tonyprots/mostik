import Foundation
import MostikCore

/// Опись Настроек (П9-А; 5 разделов): каждая прежняя настройка либо в своём новом разделе,
/// либо явно в списке «умолчание без контрола». Тест читает исходники, как страж локализации:
/// токен настройки (путь ключа, строка, вызов) должен стоять в файле,
/// а секция с ним — в разделе `// MARK: pane <раздел>` файла SettingsTab.swift.
struct SettingsInventoryEntry {
    var title: String
    var pane: String
    var file: String
    var token: String
    /// Секция, через которую настройка попадает в раздел; nil — настройка прямо в SettingsTab.swift.
    var section: String?
}

/// Настройка, у которой больше нет контрола (решение автора): значение остаётся
/// в модели с умолчанием, а токен контрола не должен встречаться в файле, где он был.
struct SettingsDefaultEntry {
    var title: String
    /// Файл MostikUI, где был контрол.
    var file: String
    /// Чего в файле быть не должно.
    var token: String
}

enum SettingsInventory {
    static let panes = ["general", "text", "meetings", "agents", "privacy"]

    static func e(_ title: String, _ pane: String, _ token: String,
                  _ file: String = "SettingsTab.swift", via section: String? = nil) -> SettingsInventoryEntry {
        SettingsInventoryEntry(title: title, pane: pane, file: file, token: token, section: section)
    }

    /// Всё, что было в прежних 9 разделах, кроме перечисленного в `defaults`, — в своём новом разделе.
    static let entries: [SettingsInventoryEntry] = [
        // Основное
        e("Клавиша записи", "general", "\\.holdKey"),
        e("Запись двойным нажатием", "general", "\\.handsFreeDoubleTap"),
        e("Вход микрофона", "general", "MicrophoneRow"),
        e("Шумоподавление диктовки", "general", "\\.meetingLive.dictationVoiceProcessing"),
        e("Приглушать звук", "general", "\\.muteWhileRecording"),
        e("Язык диктовки", "general", "\\.language"),
        e("Запускать при входе", "general", "\\.launchAtLogin"),
        e("Русский и английский вперемешку", "general", "$0.autoLanguage =", "GlossaryLearningViews.swift", via: "LanguageAutoRows"),
        e("Языки автоопределения", "general", "$0.autoLanguages =", "GlossaryLearningViews.swift", via: "LanguageAutoRows"),
        e("⌥Space", "general", "\\.toggleShortcutEnabled"),
        e("Боковая кнопка мыши", "general", "\\.mouseTrigger"),
        e("Кнопка гарнитуры", "general", "\\.headsetTrigger"),
        // Текст: причёсывание, правила речи, сценарии
        e("Модель причёсывания", "text", "choosePolishBackend"),
        e("Отозвать согласие", "text", "cloudConsent = false"),
        e("Скачать модель на этом Mac", "text", "models.start("),
        e("Стиль", "text", "s.polish.style = value"),
        e("Не причёсывать или всегда", "text", "polish.setOverride"),
        e("Голосовая правка", "text", ".voiceEdit = value", "VoiceEditModel.swift", via: "VoiceEditSettingsRow"),
        e("Действия голосом ⌃⌘K", "text", "\\.voiceIntents.enabled", "VoiceIntentViews.swift", via: "VoiceIntentSettingsSection"),
        e("Текст вокруг курсора", "text", "\\.enabled", "PolishExtrasSettings.swift", via: "PolishExtrasSection(model: model, parts: [.context])"),
        e("Контекст в облако", "text", "\\.toCloud", "PolishExtrasSettings.swift", via: "PolishExtrasSection(model: model, parts: [.context])"),
        e("Списки", "text", "\\.lists", "PolishExtrasSettings.swift", via: "PolishExtrasSection(model: model, parts: [.rules])"),
        e("Числа", "text", "\\.numbers", "PolishExtrasSettings.swift", via: "PolishExtrasSection(model: model, parts: [.rules])"),
        e("Сценарии по приложениям", "text", "addScenario", "PolishExtrasSettings.swift", via: "PolishExtrasSection(model: model, parts: [.scenarios])"),
        e("Превью тона", "text", "TonePreview", "PolishExtrasSettings.swift", via: ".tone"),
        e("Стили из папки", "text", "$0.pack =", "PolishExtrasSettings.swift", via: ".styleFiles"),
        e("Перевод ⌃⌘E", "text", "$0.translateTone =", "PolishExtrasSettings.swift", via: ".modes"),
        e("Задача ⌃⌘J", "text", "pendingMode", "PolishExtrasSettings.swift", via: ".modes"),
        // Встречи
        e("Подсказывать о звонках", "meetings", "$0.meetingSuggest = on", "MeetingSettingsSection.swift", via: "MeetingSettingsSection"),
        e("Напоминать о встрече (вместе с подсказкой)", "meetings", "$0.meetingReminder = on", "MeetingSettingsSection.swift", via: "MeetingSettingsSection"),
        e("Календарь", "meetings", "onSetCalendarEnabled", "MeetingSettingsSection.swift", via: "MeetingSettingsSection"),
        e("Слайды звонка", "meetings", "meetingAssist.slides = on", "MeetingSettingsSection.swift", via: "MeetingSettingsSection"),
        e("Останавливать после встречи", "meetings", "\\.meetingAutoStop", "MeetingSettingsSection.swift", via: "MeetingSettingsSection"),
        e("Заметки и сводка", "meetings", "MeetingCloudPolicy.toggle", via: "MeetingNotesChoice"),
        e("Согласие на облако встреч", "meetings", "MeetingAIModel.settingsConsent", via: "MeetingNotesChoice"),
        e("Голосовая память", "meetings", "voiceMemoryConsent", "MeetingSpeakersViews.swift", via: "VoiceMemorySettingsSection"),
        e("Люди", "meetings", "personRow", "MeetingSpeakersViews.swift", via: "VoiceMemorySettingsSection"),
        e("Забыть всех", "meetings", "forgetAllRow", "MeetingSpeakersViews.swift", via: "VoiceMemorySettingsSection"),
        e("Справка перед встречей", "meetings", "\\.archive.brief", "ArchiveSettingsSection.swift", via: "ArchiveSettingsSection"),
        e("Итоги недели", "meetings", "\\.archive.weeklyDigest", "ArchiveSettingsSection.swift", via: "ArchiveSettingsSection"),
        e("Подсказки во время встречи", "meetings", "\\.meetingAssist.hints", "MeetingAssistViews.swift", via: "MeetingAssistSettingsSection"),
        e("⌃⌘M", "meetings", "\\.meetingLive.hotkey", "MeetingLiveViews.swift", via: "MeetingLiveSettingsSection(model: model, part: .more)"),
        e("Шумоподавление встреч", "meetings", "\\.meetingLive.meetingVoiceProcessing", "MeetingLiveViews.swift", via: "MeetingLiveSettingsSection(model: model, part: .more)"),
        e("Своя команда", "meetings", "\\.meetingHook.enabled", "MeetingSettingsSection.swift", via: "MeetingHookRows"),
        e("Команда", "meetings", "\\.meetingHook.command", "MeetingSettingsSection.swift", via: "MeetingHookRows"),
        // Агенты
        e("Claude Code", "agents", ".claudeCode", "AgentToolsModel.swift", via: "AgentToolsSection(model: model, part: .connect)"),
        e("Codex", "agents", ".codex", "AgentToolsModel.swift", via: "AgentToolsSection(model: model, part: .connect)"),
        e("Отправка голосом", "agents", "\\.voiceSend", "AgentVoiceModel.swift", via: "AgentVoiceSection(model: model, part: .main)"),
        e("Упоминания файлов", "agents", "\\.fileMentions", "AgentVoiceModel.swift", via: "AgentVoiceSection(model: model, part: .main)"),
        e("Озвучка", "agents", "\\.announce", "AgentVoiceModel.swift", via: "AgentVoiceSection(model: model, part: .main)"),
        e("Подключение озвучки", "agents", "hooksRow", "AgentVoiceModel.swift", via: "AgentVoiceSection(model: model, part: .main)"),
        e("Голоса", "agents", "AgentVoicePickerRows", "AgentVoiceModel.swift", via: "AgentVoiceSection(model: model, part: .main)"),
        e("Первая фраза вслух", "agents", "\\.announceSummary", "AgentVoiceModel.swift", via: "AgentVoiceSection(model: model, part: .main)"),
        e("Диктовать, пока агент занят", "agents", ".midTurn = v", "PolishExtrasSettings.swift", via: "PolishExtrasSection(model: model, parts: [.midTurn])"),
        e("Подключение очереди", "agents", "queueHooksRow", "PolishExtrasSettings.swift", via: "PolishExtrasSection(model: model, parts: [.midTurn])"),
        e("tmux", "agents", "\\.tmuxPaste", "AgentVoiceModel.swift", via: "AgentVoiceSection(model: model, part: .tmux)"),
        e("Приложения агентов", "agents", "agentPolicy"),
        e("Подсказка агенту", "agents", "agentContext.hookEnabled = on", "AgentToolsModel.swift", via: "AgentToolsSection(model: model, part: .more)"),
        e("Явное включение подсказки", "agents", "agentContext.hookExplicit = true", "AgentToolsModel.swift", via: "AgentToolsSection(model: model, part: .more)"),
        e("Рабочие часы с", "agents", "\\.workStart", "AgentToolsModel.swift", via: "AgentToolsSection(model: model, part: .more)"),
        e("Рабочие часы до", "agents", "\\.workEnd", "AgentToolsModel.swift", via: "AgentToolsSection(model: model, part: .more)"),
        e("Выходные", "agents", "\\.weekends", "AgentToolsModel.swift", via: "AgentToolsSection(model: model, part: .more)"),
        e("Участники встречи", "agents", "\\.includeAttendees", "AgentToolsModel.swift", via: "AgentToolsSection(model: model, part: .more)"),
        e("Команда mostik", "agents", "cliRow", "AgentToolsModel.swift", via: "AgentToolsSection(model: model, part: .more)"),
        // Приватность и данные
        e("Что уходит с этого Mac", "privacy", "PrivacyLedger"),
        e("Хранить историю", "privacy", "retentionDays"),
        e("Хранить звук диктовок", "privacy", "keepAudio"),
        e("Звук встреч: в Корзину", "privacy", "s.trashAudioAfterSummary =", "MeetingSettingsSection.swift", via: "MeetingAudioRow"),
        e("Звук встреч: только текст", "privacy", "s.meetingLive.textOnlyDefault =", "MeetingSettingsSection.swift", via: "MeetingAudioRow"),
        e("Микрофон", "privacy", "permissions.microphone"),
        e("Универсальный доступ", "privacy", "permissions.accessibility"),
        e("Звук собеседников", "privacy", "permissions.screenRecording"),
        e("Запись экрана", "privacy", "permissions.screenCapture"),
        // Приватность и данные → Дополнительно
        e("Перепроверка", "privacy", "\\.verify"),
        e("Микрофон наготове", "privacy", "\\.warmMicrophone"),
        e("Учиться на правках", "privacy", "\\.learnFromEdits"),
        e("Термины из кода", "privacy", "\\.codeTerms"),
        e("Проект сам", "privacy", "\\.autoProject"),
        e("Папка проекта", "privacy", "onChooseProject"),
        e("Буфер обмена", "privacy", "\\.clipboard", "PolishExtrasSettings.swift", via: "PolishExtrasSection(model: model, parts: [.advanced])"),
        e("Вставка по ходу", "privacy", "$0.streamInsert =", "PolishExtrasSettings.swift", via: "PolishExtrasSection(model: model, parts: [.advanced])"),
        e("Модели", "privacy", "models.start(", "ModelsViews.swift", via: "ModelsSection"),
        e("Состояние движка", "privacy", "engineStatus"),
        e("Python движка", "privacy", "onChooseEnginePython"),
        e("Диагностика", "privacy", "DoctorSection"),
    ]

    /// Узкие переключатели, ставшие умолчанием без контрола (redundancy.md, решение автора).
    /// Значение живёт в модели; что именно стоит по умолчанию, сверяет `runSettingsInventoryTests`.
    static let defaults: [SettingsDefaultEntry] = [
        SettingsDefaultEntry(title: "⇧-защёлка", file: "SettingsTab.swift", token: "\\.holdLatch"),
        SettingsDefaultEntry(title: "Абзац и строка голосом", file: "PolishExtrasSettings.swift", token: "\\.commands"),
        SettingsDefaultEntry(title: "«Зачеркни»", file: "PolishExtrasSettings.swift", token: "\\.scratch"),
        SettingsDefaultEntry(title: "Выбор языков чипами", file: "GlossaryLearningViews.swift", token: "ForEach(LanguageChoice.supported"),
        SettingsDefaultEntry(title: "Порог действий голосом", file: "VoiceIntentViews.swift", token: "voiceIntents.threshold ="),
        SettingsDefaultEntry(title: "Расшифровка по ходу встречи", file: "MeetingLiveViews.swift", token: "\\.meetingLive.liveTranscript"),
        SettingsDefaultEntry(title: "Журнал вопросов встречи", file: "MeetingAssistViews.swift", token: "\\.meetingAssist.questions"),
        SettingsDefaultEntry(title: "Кадры окна звонка: частота", file: "MeetingAssistViews.swift", token: "meetingAssist.frameInterval ="),
        SettingsDefaultEntry(title: "День итогов недели", file: "ArchiveSettingsSection.swift", token: "\\.archive.digestWeekday"),
        SettingsDefaultEntry(title: "Час итогов недели", file: "ArchiveSettingsSection.swift", token: "\\.archive.digestHour"),
        SettingsDefaultEntry(title: "Лимит своей команды", file: "MeetingSettingsSection.swift", token: "\\.meetingHook.timeoutSeconds"),
        SettingsDefaultEntry(title: "Своя команда после сводки", file: "MeetingSettingsSection.swift", token: "\\.meetingHook.afterSummary"),
        SettingsDefaultEntry(title: "Панель tmux", file: "AgentVoiceModel.swift", token: "$0.tmuxTarget ="),
        SettingsDefaultEntry(title: "Обращение к сессии по имени", file: "AgentVoiceModel.swift", token: "\\.addressing"),
    ]

    /// Настройки, которых больше нет вовсе (решение автора, C4): блок слов под вопросом
    /// в текст агенту не вставляется, сомнения решаются в истории. Токена нет ни в интерфейсе, ни в модели.
    static let removed: [(title: String, token: String)] = [
        ("Слова под вопросом", "doubtsToAgents"),
        ("Лимит слов под вопросом", "doubtLimit"),
        // проверка обновлений всегда включена — ни вопроса при первом запуске, ни переключателя.
        ("Проверять обновления", "updateChecks"),
    ]

    /// Кусок SettingsTab.swift от `// MARK: pane <раздел>` до следующего такого же.
    static func chunk(_ text: String, pane: String) -> String? {
        guard let start = text.range(of: "// MARK: pane \(pane)\n") else { return nil }
        let rest = text[start.upperBound...]
        let end = rest.range(of: "// MARK: pane ")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }
}

func runSettingsInventoryTests() {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let ui = root.appendingPathComponent("Sources/MostikUI")
    func read(_ name: String) -> String { (try? String(contentsOf: ui.appendingPathComponent(name), encoding: .utf8)) ?? "" }
    let tab = read("SettingsTab.swift")
    check(!tab.isEmpty, "опись: SettingsTab.swift прочитан")

    for pane in SettingsInventory.panes {
        check(SettingsInventory.chunk(tab, pane: pane) != nil, "опись: в SettingsTab.swift есть раздел \(pane)")
    }
    var covered = Set<String>()
    for entry in SettingsInventory.entries {
        guard let chunk = SettingsInventory.chunk(tab, pane: entry.pane) else { continue }
        if let section = entry.section {
            check(read(entry.file).contains(entry.token), "опись: «\(entry.title)» — \(entry.token) в \(entry.file)")
            check(chunk.contains(section), "опись: «\(entry.title)» — \(section) в разделе \(entry.pane)")
        } else {
            check(chunk.contains(entry.token), "опись: «\(entry.title)» — \(entry.token) в разделе \(entry.pane)")
        }
        covered.insert(entry.pane)
    }
    check(covered == Set(SettingsInventory.panes), "опись: у каждого раздела есть настройки")

    // Поиск по настройкам знает все разделы и прячет жаргон в ключевых словах.
    let index = read("SettingsIndex.swift")
    for pane in SettingsInventory.panes {
        check(index.contains("pane: .\(pane)") || index.contains("(.\(pane),"), "опись: поиск знает раздел \(pane)")
    }
    for jargon in ["hooks", "mcp", "tmux", "bundle"] {
        check(index.lowercased().contains(jargon), "опись: поиск находит по слову \(jargon)")
    }
    // Умолчания без контрола: контрола нет, значение в модели — прежнее умолчание.
    for entry in SettingsInventory.defaults {
        check(!read(entry.file).isEmpty, "опись: \(entry.file) прочитан")
        check(!read(entry.file).contains(entry.token), "опись: «\(entry.title)» — умолчание без контрола, \(entry.token) нет в \(entry.file)")
    }
    let core = (try? String(contentsOf: root.appendingPathComponent("Sources/MostikCore/Settings.swift"), encoding: .utf8)) ?? ""
    check(!core.isEmpty, "опись: Settings.swift прочитан")
    for entry in SettingsInventory.removed {
        check(!tab.contains(entry.token) && !read("SettingsIndex.swift").contains(entry.token) && !core.contains(entry.token),
              "опись: «\(entry.title)» убрана — \(entry.token) нет ни в Настройках, ни в модели")
    }
    let d = MostikSettings()
    check(d.holdLatch, "умолчание: ⇧-защёлка включена")
    check(d.polish.rules.commands && d.polish.rules.scratch, "умолчание: «новый абзац» и «зачеркни» работают")
    check(d.meetingLive.liveTranscript, "умолчание: расшифровка по ходу встречи")
    check(d.meetingAssist.questions, "умолчание: журнал вопросов встречи")
    equal(d.meetingAssist.frameInterval, MeetingAssistSettings.defaultFrameInterval, "умолчание: частота кадров")
    equal(d.archive.digestWeekday, 6, "умолчание: итоги недели по пятницам")
    equal(d.archive.digestHour, 17, "умолчание: итоги недели в 17:00")
    equal(d.meetingHook.timeoutSeconds, 60, "умолчание: своя команда — до 60 с")
    check(d.meetingHook.afterSummary, "умолчание: своя команда ещё раз после сводки")
    equal(d.voiceIntents.threshold, 0.6, "умолчание: порог действий голосом")
    equal(d.agentVoice.tmuxTarget, TmuxTargeting.auto, "умолчание: активная панель tmux")
    check(d.agentVoice.addressing, "умолчание: обращение к сессии по имени")
    check(!d.agentContext.hookEnabled, "умолчание: подсказка агенту на старте выключена")

    // Названия в описи не повторяются, и всего прежних настроек не меньше 90.
    let titles = SettingsInventory.entries.map(\.title) + SettingsInventory.defaults.map(\.title)
        + SettingsInventory.removed.map(\.title)
    equal(Set(titles).count, titles.count, "опись: названия не повторяются")
    let total = SettingsInventory.entries.count + SettingsInventory.defaults.count + SettingsInventory.removed.count
    check(total >= 90, "опись: не меньше 90 настроек вместе с умолчаниями (\(total))")
}
