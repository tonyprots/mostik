import Foundation
import SwiftUI
import MostikCore

/// Единственная точка, через которую интерфейс видит приложение.
/// Вид только читает состояние и вызывает намерения; что за ними стоит —
/// дело `AppController`. Так экраны собираются и проверяются без звука и движка.
@MainActor
public final class AppModel: ObservableObject {
    public enum EngineStatus: Equatable {
        case starting
        case loading(String)
        case ready
        case failed(String)
    }

    public enum HUDPhase: Equatable {
        case hidden
        case recording
        case transcribing
        case done(summary: String, doubts: Int, agent: Bool)
        case error(String)
        /// Карточка доставки (R2, R4, H2): «Текст не вставлен» + что с ним стало.
        case notice(title: String, detail: String)
    }

    public enum MeetingState: Equatable {
        case recording
        case processing(String)
        case done
        case failed(String)

        public var isProcessing: Bool { if case .processing = self { return true }; return false }
    }

    public struct MeetingItem: Identifiable, Equatable {
        public var id: String
        public var title: String
        public var startedAt: Date
        public var duration: TimeInterval
        public var state: MeetingState
        public var folder: URL
        public var transcriptPath: URL?
        public var speakers: Int
        /// Код сбоя движка (R3a): `EngineErrorText.diarizationMemory` даёт действие «Повторить без голосов».
        public var failureCode: String? = nil
        /// Расшифрована без разделения по голосам: на этом Mac нет `fluidaudiocli` (`transcript.code`).
        public var diarizationUnavailable = false
        /// Расшифрована без разделения по голосам: модель голосов упала на этой записи.
        public var diarizationFailed = false
        /// Доля расшифровки 0…1, пока она идёт; nil — доля неизвестна (в очереди, дорасшифровка).
        public var progress: Double? = nil

        public init(id: String, title: String, startedAt: Date, duration: TimeInterval, state: MeetingState,
                    folder: URL, transcriptPath: URL? = nil, speakers: Int = 0) {
            self.id = id; self.title = title; self.startedAt = startedAt; self.duration = duration
            self.state = state; self.folder = folder; self.transcriptPath = transcriptPath; self.speakers = speakers
        }
    }

    public struct GlossaryItem: Identifiable, Equatable, Hashable {
        public var id: String { canonical }
        public var canonical: String
        public var aliases: [String]
        /// "personal" | "learned"
        public var source: String

        public init(canonical: String, aliases: [String], source: String) {
            self.canonical = canonical; self.aliases = aliases; self.source = source
        }
    }

    public struct Permissions: Equatable {
        public var microphone = false
        public var accessibility = false
        /// «Звук системы» для встреч: публичной проверки нет — хоть раз записалась встреча.
        public var screenRecording = false
        /// Право слать нажатия (вставка ⌘V): `CGPreflightPostEventAccess`.
        public var postEvents = false
        /// «Запись экрана» — для кадров окна звонка (W26): `CGPreflightScreenCaptureAccess`.
        public var screenCapture = false
        public init(microphone: Bool = false, accessibility: Bool = false, screenRecording: Bool = false,
                    postEvents: Bool? = nil, screenCapture: Bool = false) {
            self.microphone = microphone; self.accessibility = accessibility; self.screenRecording = screenRecording
            self.postEvents = postEvents ?? accessibility; self.screenCapture = screenCapture
        }
    }

    /// `screenRecording` — панель «Запись звука системы»; `screenCapture` — «Запись экрана».
    public enum PermissionKind { case microphone, accessibility, screenRecording, screenCapture }

    /// Реплика расшифровки встречи: кто, когда (секунды от начала), что сказал.
    public struct TranscriptLine: Identifiable, Equatable {
        public var id: Int
        public var speaker: String
        public var start: TimeInterval
        public var text: String
        public init(id: Int, speaker: String, start: TimeInterval, text: String) {
            self.id = id; self.speaker = speaker; self.start = start; self.text = text
        }
    }

    // Состояние
    @Published public var engineStatus: EngineStatus = .starting
    @Published public var hud: HUDPhase = .hidden {
        didSet {
            switch hud {
            case .recording: menuIcon.set(.recording)
            case .transcribing: menuIcon.set(.transcribing)
            default: menuIcon.set(.idle)
            }
            if hud != .transcribing { verifyProgress = nil }
        }
    }
    /// Длинная диктовка ждёт вторую модель: доля проверенных пачек 0…1; nil — ожидания нет.
    @Published public var verifyProgress: Double? = nil
    /// «Вставить сразу»: не ждать вторую модель, вставить текст первой.
    public var onInsertFast: () -> Void = {}
    /// Живые данные записи — в своих объектах (шаг 2, п. 8): `AppModel` смотрят ~80 видов,
    /// и уровень 20 раз в секунду не должен перерисовывать их все.
    public let meter = LevelMeter()
    public let clock = LiveClock()
    public let menuIcon = MenuBarIcon()
    /// Последние уровни сигнала 0…1, новые в конце; для волны в HUD (`meter`).
    public var levels: [Float] {
        get { meter.levels }
        set { meter.levels = newValue }
    }
    public var elapsed: TimeInterval {
        get { clock.elapsed }
        set { clock.elapsed = newValue }
    }
    /// Запись идёт без рук (двойное нажатие или защёлка ⇧): подсказка в плашке — «Стоп ⌥», а не «Отпустите».
    @Published public var recordingHandsFree = false
    /// Диктовка на паузе (точка в плашке).
    @Published public var dictationPaused = false
    /// Микрофон отдаёт тишину: что Mostik делает или что проверить (`SilentInputWatch`); nil — всё в порядке.
    @Published public var micTrouble: String?
    /// Пункт «Записать голос» в меню строки меню: покой, запись, расшифровка (`MenuVoice.phase`).
    @Published public var menuVoicePhase: MenuVoice.Phase = .idle
    /// Потоковый черновик: запасной текст для истории, на экране не показывается — не публикуется.
    public var partialText: String = ""
    @Published public var history: [HistoryEntry] = []
    @Published public var meetings: [MeetingItem] = [] {
        didSet { syncMenuMeeting() }
    }
    public var meetingElapsed: TimeInterval {
        get { clock.meetingElapsed }
        set {
            clock.meetingElapsed = newValue
            syncMenuMeeting()
        }
    }
    /// Имя приложения ВКС, если микрофон занят им и мы не пишем.
    @Published public var meetingSuggestion: String? = nil
    @Published public var glossary: [GlossaryItem] = []
    @Published public var projectTerms: [String] = []
    @Published public var settings = MostikSettings()
    /// Внешний календарь-команда: «Событий: 12 · обновлено в 10:40» или ошибка; nil — не подключён.
    @Published public var externalCalendarStatus: String? = nil
    /// Источники календаря (Google, Яндекс, macOS): строка под источником — что отмечено, сколько событий, ошибка.
    @Published public var calendarSourceStatus: [CalendarAccounts.Kind: CalendarSourceStatus] = [:]
    /// Окно выбора календарей аккаунта.
    @Published public var calendarPicker: CalendarPickerState? = nil
    /// Окно входа в Яндекс Календарь (логин и пароль приложения).
    @Published public var yandexSignIn: YandexSignInState? = nil
    /// Идёт вход в Google: ждём ответа из браузера.
    @Published public var googleSigningIn = false
    /// В сборке есть OAuth-клиент Google (`MOSTIK_GOOGLE_CLIENT_ID`); без него Google недоступен.
    @Published public var googleCalendarAvailable = false
    /// У выпуска есть настоящая лента обновлений — показать переключатель «Проверять обновления» (п. 8).
    @Published public var updatesConfigurable = false
    /// Пункт «Проверить обновления…»: только с настоящим адресом ленты (`UpdatePolicy.showsCheckForUpdates`).
    @Published public var updatesCheckable = false
    /// Какие бэкенды полировщика движок считает доступными (`hello.polish`); пусто — ещё не знаем.
    @Published public var polishAvailable: [String: Bool] = [:]
    /// Выбран `claude`, но согласие на отправку в облако ещё не дано: показываем предупреждение.
    @Published public var polishConsentPending = false
    @Published public var permissions = Permissions()
    /// Входы звука для строки «Микрофон» в Настройках (R3b); пусто — список ещё не читали.
    @Published public var inputDevices: [InputDevice] = []
    /// Системный вход macOS (только чтение): с него пишем, когда в Настройках «Как в системе».
    @Published public var inputDeviceID: UInt32? = nil
    @Published public var selectedTab: Tab = .dictation
    /// Раздел Настроек (П9-А): боковая панель помнит выбор, ссылки из других экранов открывают нужный.
    /// Настройки — вкладка главного окна (отзыв автора, B1): открывать через `openSettings(_:)`.
    @Published public var settingsPane: SettingsPane = .general
    /// Свёрнутый блок раздела, который ссылка просит раскрыть сразу (`SettingsRoute.reveal`):
    /// «Нужны модели» и «Вся диагностика» ведут в «Дополнительно» внутри «Приватности и данных».
    @Published public var settingsReveal: String? = nil
    /// Встреча, которую открыть на нужной реплике (подсказка встречи, меню, архив).
    @Published public var meetingFocus: MeetingFocus? = nil
    /// Расшифровки встреч по `MeetingItem.id`; controller кладёт сюда разобранный транскрипт.
    @Published public var meetingTranscripts: [String: [TranscriptLine]] = [:]

    /// Вкладки главного окна; Настройки — последняя (отзыв автора, B1: не отдельным окном).
    public enum Tab: Hashable { case dictation, meetings, glossary, settings }

    /// Открыть главное окно на вкладке Настроек и разделе ссылки: так ведут «Изменить», «Нужны модели»,
    /// «Вся диагностика», строка меню и ⌘,. Без раздела — тот, где Настройки оставили.
    public func openSettings(_ link: SettingsRoute) {
        if let raw = link.pane, let pane = SettingsPane(rawValue: raw) { settingsPane = pane }
        if link.pane != nil { settingsReveal = link.reveal }
        // «Агенты» скрыты, пока агент не найден: на скрытом разделе не открываем.
        if !visibleSettingsPanes.contains(settingsPane) { settingsPane = .general }
        selectedTab = .settings
        onOpenSettings()
    }

    /// На Mac есть агент (Claude Code или Codex) — от этого зависит раздел «Агенты».
    public var agentFound: Bool {
        agentTools.agentFound || polishAvailable["claude"] == true || agentTools.installed.values.contains(true)
    }

    /// Разделы боковой панели Настроек (`SettingsRoute.visiblePanes`).
    public var visibleSettingsPanes: [SettingsPane] {
        SettingsRoute.visiblePanes(agentFound: agentFound).compactMap(SettingsPane.init(rawValue:))
    }

    // Этап B: у каждой фичи своя модель, чтобы параллельные правки не сталкивались здесь.
    public let voiceEdit = VoiceEditModel()
    public let meetingAI = MeetingAIModel()
    /// «Проверка» в Настройках (R7).
    public let doctor = DoctorModel()
    /// Модели по кнопке (П8, пункт 5).
    public let models = ModelsModel()
    /// Локальная LLM скачана: на неё уходят сводка и название встреч «Только на этом Mac» (`MeetingAIPolicy`).
    public var localLLMInstalled: Bool { models.rows.contains { $0.purpose == "llm" && $0.installed } }
    public let meetingExtras = MeetingExtrasModel()
    /// Голос и агенты (G5, G6, A1, A3, A5): tmux и хуки Claude Code.
    public let agentVoice = AgentVoiceModel()
    /// CLI, MCP, скилл и хук для агентов (G1, G2, G4).
    public let agentTools = AgentToolsModel()
    /// Говорящие встреч: имена, проверка меток, голосовая память (M14, M15).
    public let meetingSpeakers = MeetingSpeakersModel()
    /// Личный словарь вокруг вставки: правки, «Запомнить написание», импорт (L1, L2, L6).
    public let glossaryLearning = GlossaryLearningModel()
    /// П6-А: пакеты стилей, превью тона, хуки очереди агенту (P2, P4, A6).
    public let polishExtras = PolishExtrasModel()
    /// Встреча по ходу записи и ремонт после (W10, W15–W20, W24, A1).
    public let meetingLive = MeetingLiveModel()
    /// П7: вопросы по ходу встречи, подсказки, кадры окна звонка (M19, M9, W26).
    public let meetingAssist = MeetingAssistModel()
    /// Голосовые команды-намерения: ⌃⌘K и карточка над HUD (D6).
    public let voiceIntent = VoiceIntentModel()

    // MARK: этап A — источники словаря (S1–S5)

    /// Источник словаря: репозиторий, папка документов, календарь, личный словарь.
    public struct SourceItem: Identifiable, Equatable {
        /// "repo" | "docs" | "calendar" | "personal"
        public var kind: String
        public var label: String
        /// Путь к папке; у календаря и личного словаря — nil.
        public var path: String?
        public var scannedAt: Date?
        /// По видам термина: "person", "project", "tech", "acronym", "identifier".
        public var counts: [String: Int]
        public var total: Int
        /// true — проект определён автоматически по активному окну.
        public var auto: Bool
        public var id: String { kind + ":" + (path ?? label) }
        public init(kind: String, label: String, path: String? = nil, scannedAt: Date? = nil,
                    counts: [String: Int] = [:], total: Int = 0, auto: Bool = false) {
            self.kind = kind; self.label = label; self.path = path; self.scannedAt = scannedAt
            self.counts = counts; self.total = total; self.auto = auto
        }
    }

    /// Термин с происхождением: "Sources/App.swift:12", "календарь: Планёрка", "личный словарь".
    public struct TermItem: Identifiable, Equatable, Hashable {
        public var term: String
        public var kind: String
        public var origins: [String]
        public var id: String { term }
        public init(term: String, kind: String, origins: [String]) {
            self.term = term; self.kind = kind; self.origins = origins
        }
    }

    /// Пометка по ходу встречи (M1): секунды от начала записи.
    public struct MeetingMark: Identifiable, Equatable {
        public var id = UUID()
        public var at: TimeInterval
        public var text: String
        public init(at: TimeInterval, text: String) { self.at = at; self.text = text }
    }

    @Published public var sources: [SourceItem] = []
    @Published public var terms: [TermItem] = []
    @Published public var sourcesScanning = false
    /// Корень проекта, определённый по активному окну: его словарь помогает распознаванию.
    @Published public var currentProject: String? = nil
    /// Запасная папка проекта из настроек: есть ли она и есть ли в ней термины.
    public enum FallbackProjectStatus: Equatable { case unknown, missing, empty, terms(Int) }
    @Published public var fallbackProjectStatus: FallbackProjectStatus = .unknown

    /// Пометки текущей записи встречи (M1).
    @Published public var meetingMarks: [MeetingMark] = []
    @Published public var meetingPaused = false {
        didSet { syncMenuMeeting() }
    }
    /// Показать предупреждение о согласии перед первой записью встречи (M4).
    @Published public var meetingConsentPending = false

    public var isMeetingRecording: Bool { meetings.contains { $0.state == .recording } }
    /// Запись встречи для строки меню: значок и раздел меню (`MeetingMenu`).
    public var meetingMenuState: MeetingMenu.State { MeetingMenu.state(recording: isMeetingRecording, paused: meetingPaused) }

    /// Значок строки меню следит за записью встречи: пилюли внизу экрана больше нет (решение автора).
    private func syncMenuMeeting() {
        menuIcon.setMeeting(meetingMenuState, elapsed: clock.meetingElapsed)
    }

    public init() {}

    // Намерения — controller подставляет реализацию.
    /// Перетаскивание плашки диктовки: окно двигает и место запоминает WindowManager.
    public enum HUDDrag: Equatable, Sendable { case changed, ended }
    public var onHUDDrag: (HUDDrag) -> Void = { _ in }
    /// Вернуть плашку диктовки на место по умолчанию (Настройки → Основное).
    public var onResetHUDPosition: () -> Void = {}
    /// Плашку перетаскивали — у неё своё место; в Настройках доступно «Вернуть на место».
    @Published public var hudMoved = false
    public var onStartMeeting: () -> Void = {}
    public var onStopMeeting: () -> Void = {}
    public var onRetranscribe: (HistoryEntry) -> Void = { _ in }
    /// Удалить диктовку вместе со звуком (из «…» в карточке).
    public var onDeleteEntry: (HistoryEntry) -> Void = { _ in }
    public var onCopy: (String) -> Void = { _ in }
    public var onRemember: (_ heard: String, _ canonical: String) -> Void = { _, _ in }
    /// Слово под вопросом в записи: принять написание — текст записи правится, слово в словарь (C3, C4).
    public var onAcceptDoubt: (_ entryID: String, _ heard: String, _ canonical: String) -> Void = { _, _, _ in }
    /// Отклонить подсказку: отметка снимается, текст как был, пара больше не предлагается (C5).
    public var onRejectDoubt: (_ entryID: String, _ doubt: Doubt) -> Void = { _, _ in }
    public var onForget: (GlossaryItem) -> Void = { _ in }
    public var onChooseProject: (URL?) -> Void = { _ in }
    public var onUpdateSettings: (MostikSettings) -> Void = { _ in }
    public var onRequestPermission: (PermissionKind) -> Void = { _ in }
    public var onOpenTranscript: (MeetingItem) -> Void = { _ in }
    public var onRevealInFinder: (URL) -> Void = { _ in }
    /// Удалить встречу: папка уходит в Корзину (из «…» у встречи, с подтверждением).
    public var onDeleteMeeting: (MeetingItem) -> Void = { _ in }
    /// Повторить расшифровку встречи без разделения по голосам (R3a): после нехватки памяти.
    public var onRetryMeetingWithoutVoices: (String) -> Void = { _ in }
    /// Повторить расшифровку встречи после сбоя: готовая дорожка не пересчитывается.
    public var onRetryMeeting: (String) -> Void = { _ in }
    public var onQuit: () -> Void = {}
    public var onCheckForUpdates: () -> Void = {}
    /// «Записать голос» / «Остановить запись»: меню закрывает и фокус возвращает controller.
    public var onMenuVoice: () -> Void = {}
    public var onOpenMainWindow: () -> Void = {}
    /// Показать главное окно на вкладке Настроек (controller: `WindowManager.showMain`). Звать через `openSettings(_:)`.
    public var onOpenSettings: () -> Void = {}
    /// Вкладку Настроек показали (в том числе щелчком по вкладке): перечитать микрофоны и разрешения.
    public var onSettingsShown: () -> Void = {}
    public var onDismissMeetingSuggestion: () -> Void = {}
    /// Выбрать интерпретатор движка (NSOpenPanel на стороне controller).
    public var onChooseEnginePython: () -> Void = {}

    // Этап A.
    public var onRescanSources: () -> Void = {}
    /// nil — controller открывает NSOpenPanel для папки.
    public var onAddSource: (URL?) -> Void = { _ in }
    public var onRemoveSource: (SourceItem) -> Void = { _ in }
    public var onSetCalendarEnabled: (Bool) -> Void = { _ in }
    /// Внешний календарь (docs/external-calendar.md): выбрать файл команды, отключить, перечитать.
    public var onChooseCalendarCommand: () -> Void = {}
    public var onClearCalendarCommand: () -> Void = {}
    public var onRefreshCalendarCommand: () -> Void = {}
    /// Источники календаря: подключить (Google — браузер, Яндекс — окно входа, macOS — доступ и выбор), отключить,
    /// выбрать календари, сохранить выбор, войти в Яндекс, отменить вход.
    public var onConnectCalendar: (CalendarAccounts.Kind) -> Void = { _ in }
    public var onDisconnectCalendar: (CalendarAccounts.Kind) -> Void = { _ in }
    public var onPickCalendars: (CalendarAccounts.Kind) -> Void = { _ in }
    public var onSaveCalendars: (CalendarAccounts.Kind, [RemoteCalendar]) -> Void = { _, _ in }
    public var onSubmitYandex: (_ login: String, _ password: String) -> Void = { _, _ in }
    public var onCancelCalendarSignIn: () -> Void = {}
    public var onAddMeetingMark: (String) -> Void = { _ in }
    public var onToggleMeetingPause: () -> Void = {}
    public var onToggleDictationPause: () -> Void = {}
    /// Пользователь принял предупреждение о согласии (M4); запись встречи начинается после него.
    public var onAcknowledgeConsent: () -> Void = {}
}
