import Foundation

public struct MostikSettings: Codable, Equatable, Sendable {
    /// Версия схемы `settings.json`. Файл без поля — 0, до версий. Миграции только вперёд
    /// (`SettingsMigration`); старое поле не удаляется в той же версии, где появилось новое. Файл новее этой
    /// сборки (откат на старую версию) читается как есть, его версия и незнакомые поля сохраняются (`save`).
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int = MostikSettings.currentSchemaVersion
    /// "ru" | "en". По умолчанию — из языков Mac: раньше всегда "ru", и англоязычный
    /// человек на первом запуске качал русскую модель и диктовал в неё.
    public var language: String = MostikSettings.defaultLanguage()
    /// Автоопределение языка (L5): выбор только из `autoLanguages`, а без него — из языков Mac,
    /// пересечённых с ru и en. Выключено: смешанную речь детектор может принять не за тот язык.
    public var autoLanguage: Bool = false
    /// Свой список для автоопределения; nil — языки Mac (`Locale.preferredLanguages`).
    public var autoLanguages: [String]? = nil
    /// Обучение на правках (L1): 60 с после вставки поле перечитывается (только чтение),
    /// повторённая правка предлагается в словарь — запоминается только после «Запомнить».
    public var learnFromEdits: Bool = true
    /// "rightOption" | "rightCommand" | "fn"
    public var holdKey: String = "rightOption"
    public var toggleShortcutEnabled: Bool = true
    /// Выключен по умолчанию: открытый микрофон держит оранжевый индикатор macOS.
    public var warmMicrophone: Bool = false
    /// Микрофон для записи Mostik по UID устройства (R3b, `MicChoice`); пусто — «Как в системе».
    /// Вход по умолчанию в macOS Mostik не меняет.
    public var micDeviceUID: String = ""
    /// Имя выбранного микрофона — чтобы сказать, какой не подключён.
    public var micDeviceName: String = ""
    /// Ваши имя и фамилия, как в звонках (Настройки → Общие). По ним Mostik находит
    /// свою плитку в Zoom и отличает вас от собеседника; пусто — подставится узнанное на встрече.
    public var myName: String = ""
    public var verify: Bool = true
    public var retentionDays: Int = 7
    public var keepAudio: Bool = true
    /// Сколько дней хранится звук диктовок при `keepAudio` (решение автора, П10: 1 день вместо 7).
    /// Запись истории живёт `retentionDays`, звук у неё снимается раньше.
    public static let dictationAudioDays = 1
    public var projectPath: String? = nil
    /// Python движка, выбранный вручную; пусто — искать самим (`EnginePaths`): встроенный в .app,
    /// `MOSTIK_PYTHON`, в dev-сборке — `vendor/python` репозитория.
    public var enginePython: String = ""
    public var meetingSuggest: Bool = true
    public var agentPolicy: AgentAppPolicy = .standard
    public var onboarded: Bool = false
    /// Запускаться при входе в macOS (`LaunchAtLogin`). Включено по умолчанию; в файле до этого поля
    /// его нет — значит, тоже включено. Действует с конца онбординга, где есть та же галочка.
    public var launchAtLogin: Bool = true
    /// Проект берётся из папки агента в активном окне (cwd процесса claude/codex → корень git).
    /// `projectPath` — ручная замена, когда автоопределение не сработало.
    public var autoProject: Bool = true
    /// Термины из кода (режим разработчика): словарь из проекта — найденного по окну агента или
    /// `projectPath`. По умолчанию выключено и у старых файлов настроек тоже: тысячи идентификаторов
    /// из репозитория перетягивали русскую речь в короткие английские слова. Без него словарь —
    /// только папки документов, календарь и личный словарь.
    public var codeTerms: Bool = false
    /// Запасная папка проекта, если термины из кода включены; иначе nil.
    public var codeProjectPath: String? { codeTerms ? projectPath : nil }
    /// Искать проект по окну агента — только при включённых терминах из кода.
    public var codeAutoProject: Bool { codeTerms && autoProject }
    /// Дополнительные источники словаря: папки документов, Markdown, Obsidian (S2).
    public var extraSources: [String] = []
    /// Календарь через EventKit как источник терминов и имён (S1). Включает пользователь.
    public var calendarEnabled: Bool = false
    /// Внешний календарь — путь к команде, которая печатает события JSON (docs/external-calendar.md).
    /// Запускается, только если путь выбран или подтверждён в Mostik (`CalendarCommandTrust`).
    public var calendarCommand: String? = nil
    /// Google, Яндекс и Календарь macOS: что подключено и какие календари отмечены. По умолчанию — ничего.
    public var calendarAccounts = CalendarAccounts()
    /// Пользователь видел предупреждение о согласии участников записи (M4).
    public var consentAcknowledged: Bool = false
    /// Двойное нажатие клавиши диктовки — запись без удержания (D1).
    public var handsFreeDoubleTap: Bool = true
    /// Причёсывание текста (D3, D4, G7): бэкенд, стиль, согласие на облако, политика по приложениям.
    public var polish: PolishSettings = PolishSettings()
    /// Голосовая правка выделенного (D5): зажать правый ⌘ и сказать команду. Нужен бэкенд LLM.
    public var voiceEdit: Bool = false
    /// Согласие отдавать расшифровки встреч и источники бэкенду LLM (M5–M8). Для облачного
    /// бэкенда это чужие голоса и документы, поэтому отдельно от согласия на причёсывание.
    public var meetingAIConsent: Bool = false
    /// Модель для встреч (сводки, названия, подсказки), если она не та же, что у диктовки.
    /// nil — как у диктовки (`polish.backend`). Выбирается в онбординге и Настройках.
    public var meetingBackend: PolishBackend? = nil
    /// Отдельное согласие отдавать расшифровки встреч в облако (Claude): дано на экране
    /// «расшифровка уйдёт в Anthropic» и сбрасывается при любой смене бэкенда (`MeetingCloudPolicy`).
    public var meetingAICloudConsent: Bool = false {
        didSet { meetingAICloudConsentFor = CloudConsentLabel.stamp(meetingAICloudConsent) }
    }
    /// Метка облачного согласия встреч (П10), см. `CloudConsentLabel`.
    public private(set) var meetingAICloudConsentFor: String?
    /// Защёлка (H4): во время удержания нажали другой модификатор — запись идёт без рук.
    public var holdLatch: Bool = true
    /// Боковая кнопка мыши как клавиша удержания (H5): "off" | "back" | "forward".
    public var mouseTrigger: String = "off"
    /// Кнопка гарнитуры ▶︎⏸ как переключатель записи (H5). Перехватывает и медиаклавишу клавиатуры.
    public var headsetTrigger: Bool = false
    /// Приглушать системный звук на время диктовки (H6).
    public var muteWhileRecording: Bool = false
    /// Хук после встречи (M11): своя команда с путём папки. Выключен по умолчанию.
    public var meetingHook: MeetingHookSettings = MeetingHookSettings()
    /// Автоостановка записи, когда событие кончилось или звонок закрылся, с отменяемым отсчётом (M13).
    public var meetingAutoStop: Bool = false
    /// Напоминание за минуту до встречи из календаря со ссылкой на звонок (M13). Нужен включённый календарь.
    public var meetingReminder: Bool = true
    /// Аудио встречи — в Корзину macOS после готовой сводки (W13). Выключено по умолчанию.
    public var trashAudioAfterSummary: Bool = false
    /// Сводка встреч (M16, W23): учитывать ли свои записи и вставленные картинки.
    public var meetingNotes: MeetingNotesSettings = MeetingNotesSettings()
    /// Голос и агенты (G5, G6, A1, A3, A5): tmux, голосовая отправка, озвучка, автотег.
    public var agentVoice: AgentVoiceSettings = AgentVoiceSettings()
    /// Хук SessionStart для агентов (G4): встреча в ближайший час и словарь проекта, в рабочие часы.
    public var agentContext: AgentContextSettings = AgentContextSettings()
    /// Голосовая память собеседников (M14): векторы голосов, не аудио. Выключена по умолчанию,
    /// включается только через экран согласия (`voiceMemoryConsent`).
    public var voiceMemory: Bool = false
    /// Пользователь прочитал экран согласия голосовой памяти и согласился.
    public var voiceMemoryConsent: Bool = false
    /// Встреча по ходу записи (П6-Б): живая расшифровка, «только текст», автостарт, хоткей,
    /// шумо- и эхоподавление, текст предупреждения (W10, W15, W19, W24, V6).
    public var meetingLive: MeetingLiveSettings = MeetingLiveSettings()
    /// Архив встреч (П6-Г): бриф до встречи, недельная сводка, слова-триггеры (W1, W6, W12).
    public var archive: ArchiveSettings = ArchiveSettings()
    /// П7: вопросы по ходу встречи (M19), подсказки (M9), шаг кадров окна звонка (W26).
    /// Согласия на кадры здесь нет — только на каждую встречу.
    public var meetingAssist: MeetingAssistSettings = MeetingAssistSettings()
    /// Голосовые команды-намерения (D6): ⌃⌘K — следующая диктовка становится черновиком события,
    /// напоминания или письма. Выключены по умолчанию.
    public var voiceIntents: VoiceIntentSettings = VoiceIntentSettings()
    /// Термины, скрытые во вкладке «Словарь»: найдены в источниках, но не идут в подсказку распознаванию.
    public var hiddenTerms: [String] = []

    public init() {}

    /// Первый из ru/en в списке языков Mac; ни того ни другого — en.
    public static func defaultLanguage(_ preferred: [String] = Locale.preferredLanguages) -> String {
        for tag in preferred {
            let code = tag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
            if code == "ru" || code == "en" { return code }
        }
        return "en"
    }

    public init(from decoder: Decoder) throws {
        let d = MostikSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fileVersion = (try? c.decodeIfPresent(Int.self, forKey: .schemaVersion)) ?? 0
        schemaVersion = max(fileVersion, Self.currentSchemaVersion)
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
        autoLanguage = try c.decodeIfPresent(Bool.self, forKey: .autoLanguage) ?? d.autoLanguage
        autoLanguages = try c.decodeIfPresent([String].self, forKey: .autoLanguages)
        learnFromEdits = try c.decodeIfPresent(Bool.self, forKey: .learnFromEdits) ?? d.learnFromEdits
        holdKey = try c.decodeIfPresent(String.self, forKey: .holdKey) ?? d.holdKey
        toggleShortcutEnabled = try c.decodeIfPresent(Bool.self, forKey: .toggleShortcutEnabled) ?? d.toggleShortcutEnabled
        warmMicrophone = try c.decodeIfPresent(Bool.self, forKey: .warmMicrophone) ?? d.warmMicrophone
        micDeviceUID = try c.decodeIfPresent(String.self, forKey: .micDeviceUID) ?? d.micDeviceUID
        micDeviceName = try c.decodeIfPresent(String.self, forKey: .micDeviceName) ?? d.micDeviceName
        myName = try c.decodeIfPresent(String.self, forKey: .myName) ?? d.myName
        verify = try c.decodeIfPresent(Bool.self, forKey: .verify) ?? d.verify
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? d.retentionDays
        keepAudio = try c.decodeIfPresent(Bool.self, forKey: .keepAudio) ?? d.keepAudio
        projectPath = try c.decodeIfPresent(String.self, forKey: .projectPath)
        enginePython = try c.decodeIfPresent(String.self, forKey: .enginePython) ?? d.enginePython
        meetingSuggest = try c.decodeIfPresent(Bool.self, forKey: .meetingSuggest) ?? d.meetingSuggest
        agentPolicy = try c.decodeIfPresent(AgentAppPolicy.self, forKey: .agentPolicy) ?? d.agentPolicy
        onboarded = try c.decodeIfPresent(Bool.self, forKey: .onboarded) ?? d.onboarded
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        autoProject = try c.decodeIfPresent(Bool.self, forKey: .autoProject) ?? d.autoProject
        codeTerms = try c.decodeIfPresent(Bool.self, forKey: .codeTerms) ?? d.codeTerms
        extraSources = try c.decodeIfPresent([String].self, forKey: .extraSources) ?? d.extraSources
        calendarEnabled = try c.decodeIfPresent(Bool.self, forKey: .calendarEnabled) ?? d.calendarEnabled
        calendarCommand = try c.decodeIfPresent(String.self, forKey: .calendarCommand) ?? d.calendarCommand
        calendarAccounts = (try? c.decodeIfPresent(CalendarAccounts.self, forKey: .calendarAccounts)) ?? d.calendarAccounts
        consentAcknowledged = try c.decodeIfPresent(Bool.self, forKey: .consentAcknowledged) ?? d.consentAcknowledged
        handsFreeDoubleTap = try c.decodeIfPresent(Bool.self, forKey: .handsFreeDoubleTap) ?? d.handsFreeDoubleTap
        polish = (try? c.decodeIfPresent(PolishSettings.self, forKey: .polish)) ?? d.polish
        voiceEdit = try c.decodeIfPresent(Bool.self, forKey: .voiceEdit) ?? d.voiceEdit
        meetingAIConsent = try c.decodeIfPresent(Bool.self, forKey: .meetingAIConsent) ?? d.meetingAIConsent
        meetingBackend = try? c.decodeIfPresent(PolishBackend.self, forKey: .meetingBackend)
        meetingAICloudConsent = CloudConsentLabel.accepts(
            try c.decodeIfPresent(Bool.self, forKey: .meetingAICloudConsent) ?? d.meetingAICloudConsent,
            label: try? c.decodeIfPresent(String.self, forKey: .meetingAICloudConsentFor))
        meetingAICloudConsentFor = CloudConsentLabel.stamp(meetingAICloudConsent)
        holdLatch = try c.decodeIfPresent(Bool.self, forKey: .holdLatch) ?? d.holdLatch
        mouseTrigger = try c.decodeIfPresent(String.self, forKey: .mouseTrigger) ?? d.mouseTrigger
        headsetTrigger = try c.decodeIfPresent(Bool.self, forKey: .headsetTrigger) ?? d.headsetTrigger
        muteWhileRecording = try c.decodeIfPresent(Bool.self, forKey: .muteWhileRecording) ?? d.muteWhileRecording
        meetingHook = (try? c.decodeIfPresent(MeetingHookSettings.self, forKey: .meetingHook)) ?? d.meetingHook
        meetingAutoStop = try c.decodeIfPresent(Bool.self, forKey: .meetingAutoStop) ?? d.meetingAutoStop
        meetingReminder = try c.decodeIfPresent(Bool.self, forKey: .meetingReminder) ?? d.meetingReminder
        trashAudioAfterSummary = try c.decodeIfPresent(Bool.self, forKey: .trashAudioAfterSummary) ?? d.trashAudioAfterSummary
        meetingNotes = (try? c.decodeIfPresent(MeetingNotesSettings.self, forKey: .meetingNotes)) ?? d.meetingNotes
        agentVoice = (try? c.decodeIfPresent(AgentVoiceSettings.self, forKey: .agentVoice)) ?? d.agentVoice
        agentContext = (try? c.decodeIfPresent(AgentContextSettings.self, forKey: .agentContext)) ?? d.agentContext
        voiceMemoryConsent = try c.decodeIfPresent(Bool.self, forKey: .voiceMemoryConsent) ?? d.voiceMemoryConsent
        // Без согласия память не включается, даже если файл настроек правили руками.
        voiceMemory = (try c.decodeIfPresent(Bool.self, forKey: .voiceMemory) ?? d.voiceMemory) && voiceMemoryConsent
        meetingLive = (try? c.decodeIfPresent(MeetingLiveSettings.self, forKey: .meetingLive)) ?? d.meetingLive
        archive = (try? c.decodeIfPresent(ArchiveSettings.self, forKey: .archive)) ?? d.archive
        meetingAssist = (try? c.decodeIfPresent(MeetingAssistSettings.self, forKey: .meetingAssist)) ?? d.meetingAssist
        voiceIntents = (try? c.decodeIfPresent(VoiceIntentSettings.self, forKey: .voiceIntents)) ?? d.voiceIntents
        hiddenTerms = (try? c.decodeIfPresent([String].self, forKey: .hiddenTerms)) ?? d.hiddenTerms
    }

    public static func load(from url: URL) -> MostikSettings {
        guard let data = try? Data(contentsOf: url) else { return MostikSettings() }
        return decode(data) ?? MostikSettings()
    }

    /// Разбор с миграциями вперёд: сначала JSON доводится до текущей схемы, потом декодируется.
    public static func decode(_ data: Data) -> MostikSettings? {
        var input = data
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let migrated = SettingsMigration.forward(object)
            input = (try? JSONSerialization.data(withJSONObject: migrated)) ?? data
        }
        return try? JSONDecoder().decode(MostikSettings.self, from: input)
    }

    /// Имена всех полей модели — те же, что ключи JSON (синтезированные `CodingKeys`).
    public static let knownKeys: Set<String> = Set(Mirror(reflecting: MostikSettings()).children.compactMap(\.label))

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(self)
        // Поля, которых эта сборка не знает (записала версия новее), переносятся как есть: откат на старую
        // версию и обратно не теряет настроек. Свои поля — только из модели, даже если в файле их нет.
        if let old = try? Data(contentsOf: url),
           let previous = try? JSONSerialization.jsonObject(with: old) as? [String: Any] {
            let foreign = previous.filter { !Self.knownKeys.contains($0.key) }
            if !foreign.isEmpty, var mine = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (key, value) in foreign { mine[key] = value }
                data = try JSONSerialization.data(withJSONObject: mine,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            }
        }
        try data.write(to: url, options: .atomic)
    }
}

/// Миграции `settings.json` только вперёд: шаг N → N+1 получает JSON версии N и возвращает JSON версии N+1.
/// Шаг не удаляет поле, которое читают предыдущие версии, — его убирают на версию позже.
public enum SettingsMigration {
    /// Шаг n → n+1; nil — шага нет. 0 → 1: файл до версий, поля те же — только отметка версии.
    static func step(from version: Int, _ object: [String: Any]) -> [String: Any]? {
        switch version {
        case 0: return object
        default: return nil
        }
    }

    public static func forward(_ object: [String: Any]) -> [String: Any] {
        var version = (object["schemaVersion"] as? Int) ?? 0
        guard version < MostikSettings.currentSchemaVersion else { return object }  // новее нас — как есть
        var result = object
        while version < MostikSettings.currentSchemaVersion, let next = step(from: version, result) {
            result = next
            version += 1
            result["schemaVersion"] = version
        }
        return result
    }
}

/// Пути приложения. Все функции принимают корень, чтобы тесты работали в /tmp.
public struct MostikPaths: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    public static var standard: MostikPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = base.appendingPathComponent("Mostik", isDirectory: true)
        return MostikPaths(root: root)
    }

    public var settings: URL { root.appendingPathComponent("settings.json") }
    public var history: URL { root.appendingPathComponent("history.jsonl") }
    public var recordings: URL { root.appendingPathComponent("recordings", isDirectory: true) }
    public var meetings: URL { root.appendingPathComponent("meetings", isDirectory: true) }
    public var glossary: URL { root.appendingPathComponent("glossary.yaml") }
    /// Старое место журналов (`engine.log` в `--simulate`, `meeting-hooks.log` до П10 р5). Mostik туда больше
    /// не пишет: журналы — в `MostikLogPaths` (`~/Library/Logs/Mostik/`); отсюда только переносится журнал хука.
    public var legacyLogs: URL { root.appendingPathComponent("logs", isDirectory: true) }
}
