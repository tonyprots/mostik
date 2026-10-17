import AppKit
import Foundation
import MostikCore
import MostikKit
import MostikUI

/// Связывает платформенный слой с `AppModel`: диктовка, история, словарь,
/// встречи, разрешения, движок. Интерфейс видит только `AppModel`.
@MainActor
final class AppController {
    let model = AppModel()
    let paths: MostikPaths
    let windows: WindowManager

    private var machine = DictationMachine()
    private let recorder = Recorder()
    private var engine: EngineClient
    private let paster = Paster()
    /// Отпечаток команды хука встречи в связке ключей (П10 С3).
    private let hookStore: HookDigestStore = KeychainHookDigestStore()
    /// Команда хука, изменённая вне Mostik: спросить после запуска.
    private var pendingHookQuestion: String?
    private var hotkeys: HotkeyMonitor!
    private let history: HistoryStore
    private let inspector = FrontAppInspector()
    private var power: PowerMonitor?
    private var meetingDetector: MeetingDetector?
    private var meetingRecorder: MeetingRecorder?
    private let projectDetector = ProjectDetector()
    private let calendar = CalendarSource.shared
    /// Внешний календарь — команда (docs/external-calendar.md).
    private lazy var externalCalendar = ExternalCalendarController(model: model)
    /// Google, Яндекс, Календарь macOS — по умолчанию ни один (CalendarAccountsController.swift).
    private lazy var calendarAccounts = CalendarAccountsController(model: model)
    /// Автообновление (Sparkle 2, П8-3): создаётся в `start()`, когда приложение уже запущено.
    private var updater: SparkleUpdater?
    private var calendarTimer: Timer?
    /// Проект в `model.currentProject` определён по активному окну, а не взят из настроек.
    private var currentProjectIsAuto = false
    /// Ответы `sources` приходят не по порядку — берём только последний запрос.
    private var sourcesGeneration = 0
    private var meetingClock: MeetingClock?
    /// Имена говорящих из окна Zoom по времени (прототип): лента в папке встречи.
    private var speakerObserver: CallSpeakerObserver?
    /// Событие календаря, которое шло при начале записи встречи.
    private var meetingEvent: CalendarEvent?

    /// Текущая диктовка.
    private struct Session {
        let id: String
        let frontBundleID: String
        let agentAtStart: Bool
        let wav: URL
        /// Проект и источники, с которыми начата сессия, — для повтора по файлу.
        let project: String?
        let sources: [String]
        /// Полировка, решённая на старте по приложению впереди (D3); nil — без неё.
        let polish: PolishRequest?
        var file: RecordingFile?
        var stoppedAt: Date?
        var result: DictationResult?
        /// Поле в фокусе в начале записи (R1).
        var startField: FieldSnapshot? = nil
        /// План П6-А: язык и Enter из сценария, сомнения (polishExtras).
        var polishPlan: DictationPlan? = nil
        /// В полировщик ушёл контекст из приложения (поле, буфер, адрес) — П10, `AutoEnterGuard`.
        var polishContextSent = false
        /// ⌃⌘K: диктовка — голосовая команда-намерение (D6), не текст для поля.
        var command = false
        /// Запись начата пунктом «Записать голос»: куда вставлять (`MenuVoice.target`); nil — с клавиши.
        var menuTarget: MenuPasteTarget? = nil
        /// `start` ушёл в движок (шаг 1, п. 1: план решается после старта записи).
        var started = false
    }
    private var session: Session?
    /// Замер текущей диктовки (шаг 0): signpost и строка отрезков в `app.log`.
    private var perf: DictationPerf?
    /// Отложенное сохранение Настроек (шаг 2, п. 10).
    private var settingsSave = Coalescer<MostikSettings>(delay: 0.4)
    private var settingsSaveTask: Task<Void, Never>?
    private var pendingHookOld: MeetingHookSettings?
    private let settingsIO = DispatchQueue(label: "mostik.settings.io", qos: .utility)
    private var lingeringPerf: DictationPerf?
    /// Звук до `start` движку и план текущей записи (шаг 1, п. 1).
    private var startGate: StartGate<Data>?
    /// Вставки, у которых ⌘V уже ушёл, а проверка поля и возврат буфера ещё идут (шаг 1, п. 3).
    private var deliveringIDs: Set<String> = []
    private var planTask: Task<Void, Never>?
    private var droppedAtStart = 0
    private var engineBreakdown = ""
    /// Последнее приложение впереди, кроме Mostik: меню строки меню забирает активность себе.
    private var frontMemory = FrontAppMemory(ownPID: ProcessInfo.processInfo.processIdentifier)
    /// Цель вставки из меню — до того, как `beginRecording` заведёт сессию.
    private var pendingMenuTarget: MenuPasteTarget?
    /// Самопроверка `MOSTIK_SELFTEST=menu-voice`: фокус возвращается, а запись не начинается.
    var menuVoiceDryRun: ((MenuPasteTarget) -> Void)?
    /// Вставка с проверкой, откат, повтор, Esc (R1–R4, H2, H3, A7) — `DeliveryController.swift`.
    private var delivery: DeliveryController!
    /// Расшифровки, брошенные по Esc (H2): их текст уходит в историю как «отменено».
    private var abandonedSessions: Set<String> = []
    /// Вставки, отменённые по Esc посреди вставки (A7).
    private var abortedInserts: Set<String> = []

    private var elapsedTimer: Timer?
    private var recordingStartedAt = Date()
    /// Время диктовки без пауз (пауза — точкой в плашке).
    private var dictationClock: MeetingClock?
    private var hudHideTask: Task<Void, Never>?
    private var accessibilityTimer: Timer?
    private var permissionsChecked = false
    private var relaunching = false
    private var permissionTimer: Timer?
    private var pruneTimer: Timer?
    private var meetingTimer: Timer?
    private var meetingStartedAt = Date()
    /// «Локально» нажато до первого согласия (M4): запись начнёт `acknowledgeConsent` — с тем же флагом.
    private var pendingMeetingSensitive = false
    /// Встреча, отправленная движку. Параметры храним, чтобы повторить после перезапуска движка.
    private struct MeetingJob {
        var command: Int
        let meeting: String
        let mic: URL
        let system: URL
        let outDir: URL
        let language: String
        let marks: [MeetingMarkPayload]
        let title: String?
        let attendees: [String]
        var attempts = 1
        /// false — повтор после нехватки памяти: без модели голосов (R3a).
        var diarize = true
    }
    /// Упавшие встречи этой сессии: задание целиком (с пометками) — для повтора.
    private var failedJobs: [String: MeetingJob] = [:]
    /// Запись, в которой вход так и не дал звука (`SilentInputWatch.warn`).
    private var silentSession: String?
    /// В этой записи пришлось выключить шумоподавление: с ним вход отдавал нули.
    private var droppedVoiceProcessing = false
    /// Встречи, ждущие расшифровки, по порядку отправки.
    private var meetingQueue: [MeetingJob] = []
    private var dismissedMeetingApp: String?
    private var lastAccessibility = false
    /// Голосовая правка выделенного (D5) — `VoiceEditController.swift`.
    private var voiceEdit: VoiceEditController!
    /// Архив встреч (П6-Г) — `ArchiveController.swift`.
    private var archiveController: ArchiveController!
    /// ИИ встреч (M5–M7) — `MeetingAIController.swift`.
    private var meetingAI: MeetingAIController!
    /// Мышь и гарнитура, приглушение, прогрев, «Проверка» (H5, H6, R6, R7) — `UpkeepController.swift`.
    private var upkeep: UpkeepController!
    /// Голос и агенты: tmux, «отправь», @файлы, обращение по имени, озвучка (G5, G6, A1, A3, A5) — `AgentVoiceController.swift`.
    private var agentVoice: AgentVoiceController!
    /// П6-А: сценарии, правила речи, контекст, стили, потоковая вставка, очередь агенту — `PolishExtrasController.swift`.
    private var polishExtras: PolishExtrasController!
    /// CLI, MCP, скилл и хук для агентов (G1, G2, G4) — `AgentToolsController.swift`.
    private var agentTools: AgentToolsController!
    /// Папка встречи и вокруг неё (M10–M13, W2, W9, W11, W13, W14) — `MeetingFolderController.swift`.
    private var meetingFolders: MeetingFolderController!
    /// Говорящие встреч и голосовая память (M14, M15) — `SpeakersController.swift`.
    private var speakersController: SpeakersController!
    /// Личный словарь вокруг вставки: правки, «Запомнить написание», импорт (L1, L2, L6) — `GlossaryLearningController.swift`.
    private var glossaryLearning: GlossaryLearningController!
    /// Встреча по ходу записи и ремонт после (W10, W15–W20, W24, V6, A1) — `MeetingLiveController.swift`.
    private var meetingLive: MeetingLiveController!
    /// Вопросы, подсказки и кадры окна звонка по ходу встречи (M19, M9, W26) — `MeetingAssistController.swift`.
    private var meetingAssist: MeetingAssistController!
    /// Голосовые команды-намерения: ⌃⌘K, карточка, черновики (D6) — `VoiceIntentController.swift`.
    private var voiceIntents: VoiceIntentController!
    /// Перезапуски движка по одному; события старого поколения не трогают новое (П8).
    /// Модели по кнопке: статус, загрузка, «Нужны модели» (П8, пункт 5) — `ModelsController.swift`.
    private var modelsController: ModelsController!
    private var engineGate = EngineRestartGate()
    /// Падений движка за сеанс — в строку статуса и в «Проверку» (П8, пункт 6).
    private var engineCrashes = 0

    init(paths: MostikPaths = .standard) {
        self.paths = paths
        self.windows = WindowManager()
        self.history = HistoryStore(fileURL: paths.history, audioRoot: paths.recordings)
        var settings = MostikSettings.load(from: paths.settings)
        // П10 С3: команда хука, которую не подтверждали в Mostik, выключается до первого запуска.
        let hookCheck = MeetingHookTrust.reconcileOnLoad(settings.meetingHook, store: hookStore)
        if let command = hookCheck.ask {
            settings.meetingHook = hookCheck.settings
            try? settings.save(to: paths.settings)
            pendingHookQuestion = command
        }
        // «Ваше имя» пустое, а себя уже узнавали на звонках — вписываем узнанное.
        if settings.myName.trimmingCharacters(in: .whitespaces).isEmpty,
           let known = ZoomSelfNames.load().first ?? ZoomSelfNames.fromMeetings(paths.meetings) {
            settings.myName = known
            try? settings.save(to: paths.settings)
        }
        EngineClient.ownerName = settings.myName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.engine = EngineClient(config: Self.engineConfig(settings: settings, paths: paths))
        model.settings = settings
        EngineClient.cloudGrants = CloudGrants(settings: settings)  // приватность: поле consent облачных команд
        model.currentProject = settings.codeProjectPath
        machine.doubleTapEnabled = settings.handsFreeDoubleTap
        windows.model = model
        windows.onHUDShown = { [weak self] phase in
            if phase == .recording { self?.perf?.mark(.hudShown) }
        }
        recorder.onFirstBuffer = { [weak self] in
            let at = Perf.now
            DispatchQueue.main.async { self?.perf?.mark(.firstBuffer, at: at) }
        }
        recorder.onSilentInput = { [weak self] action in
            DispatchQueue.main.async { self?.silentInput(action) }
        }
        hotkeys = HotkeyMonitor { [weak self] event in self?.hotkey(event) }
        voiceEdit = VoiceEditController(
            model: model, recorder: recorder, paster: paster, inspector: inspector,
            recordings: paths.recordings, engine: { [unowned self] in self.engine },
            isDictationBusy: { [unowned self] in self.machine.currentSession != nil })
        archiveController = ArchiveController(model: model, engine: { [unowned self] in self.engine })
        meetingAI = MeetingAIController(model: model, engine: { [unowned self] in self.engine })
        modelsController = ModelsController(model: model, engine: { [unowned self] in self.engine })
        modelsController.onInstalled = { [weak self] in
            guard let self else { return }
            Task { await self.handshake() }
        }
        // Модели голосов встали — «Проверка» и встречи должны узнать это без перезапуска движка.
        modelsController.onDiarizationInstalled = { [weak self] in
            guard let self else { return }
            Task {
                guard let hello = try? await self.engine.hello(),
                      case .object(let diarization)? = hello["diarization"] else { return }
                self.upkeep.diarizationAvailable = diarization["available"]?.boolValue
            }
        }
        upkeep = UpkeepController(
            model: model, paths: paths, engine: { [unowned self] in self.engine },
            isBusy: { [unowned self] in self.machine.currentSession != nil || self.voiceEdit.isActive || !self.meetingQueue.isEmpty },
            hotkey: { [weak self] event in self?.hotkey(event) },
            restartEngine: { [weak self] in self?.restartEngine() },
            relaunch: { [weak self] in self?.relaunch() },
            requestPermission: { [weak self] kind in self?.model.onRequestPermission(kind) })
        delivery = DeliveryController(model: model, paster: paster)
        agentVoice = AgentVoiceController(model: model, paths: paths)
        polishExtras = PolishExtrasController(model: model, paths: paths, paster: paster, engine: { [unowned self] in self.engine })
        polishExtras.notice = { [weak self] title, detail in self?.delivery.notice(title, detail) }
        delivery.onPolishHotkey = { [weak self] event in self?.polishExtras.hotkey(event) }
        agentTools = AgentToolsController(model: model)
        agentVoice.isBusy = { [unowned self] in self.machine.currentSession != nil || self.voiceEdit.isActive }
        meetingFolders = MeetingFolderController(model: model, paths: paths, engine: { [unowned self] in self.engine },
                                                 hookStore: hookStore)
        meetingFolders.reloadMeetings = { [weak self] in self?.loadMeetings() }
        meetingFolders.flushSettings = { [weak self] in self?.flushSettingsSave() }
        meetingFolders.permissionsChanged = { [weak self] in self?.refreshPermissions() }
        meetingFolders.startMeeting = { [weak self] sensitive in self?.startMeeting(sensitive: sensitive) }
        meetingFolders.stopMeeting = { [weak self] in self?.stopMeeting() }
        meetingFolders.addMark = { [weak self] text in self?.addMeetingMark(text) }
        meetingFolders.recordingClock = { [weak self] in
            guard let clock = self?.meetingClock else { return (0, false) }
            return (clock.elapsed(at: Date().timeIntervalSince1970), clock.isPaused)
        }
        meetingFolders.enqueue = { [weak self] folder, title in self?.enqueueMeeting(folder: folder, title: title) }
        meetingAI.finished = { [weak self] id in self?.meetingFolders.summaryDone(meeting: id) }
        speakersController = SpeakersController(model: model, engine: { [unowned self] in self.engine })
        glossaryLearning = GlossaryLearningController(model: model, engine: { [unowned self] in self.engine })
        delivery.onInserted = { [weak self] record in self?.glossaryLearning.inserted(record) }
        meetingLive = MeetingLiveController(model: model, engine: { [unowned self] in self.engine })
        meetingLive.startMeeting = { [weak self] in self?.startMeeting() }
        meetingLive.stopMeeting = { [weak self] in self?.stopMeeting() }
        meetingLive.continueMeeting = { [weak self] item in self?.startMeeting(continuing: item) }
        meetingLive.isRecording = { [weak self] in self?.meetingRecorder != nil }
        meetingLive.recordingClock = { [weak self] in self?.meetingClock?.elapsed(at: Date().timeIntervalSince1970) ?? 0 }
        meetingLive.showMainWindow = { [weak self] in self?.windows.showMain() }
        meetingAssist = MeetingAssistController(model: model, engine: { [unowned self] in self.engine })
        recorder.voiceProcessing = settings.meetingLive.dictationVoiceProcessing
        recorder.setMicDevice(settings.micDeviceUID)
        voiceIntents = VoiceIntentController(model: model, engine: { [unowned self] in self.engine })
        voiceIntents.notice = { [weak self] title, detail in self?.delivery.notice(title, detail) }
        delivery.onIntentHotkey = { [weak self] in self?.voiceIntents.hotkey() }
        wireDelivery()
        wireIntents()
        trackFrontApp()
    }

    /// Конфигурация движка: журнал движка и отчёты о сбоях — в `~/Library/Logs/Mostik/` (П8, пункт 6).
    private static func engineConfig(settings: MostikSettings, paths: MostikPaths) -> EngineClient.Config {
        var config = EngineLocator.config(settings: settings, paths: paths)
        let logs = MostikLogPaths.standard
        config.logFile = logs.engine
        config.crashDir = logs.crashes
        return config
    }

    // MARK: запуск

    func start() {
        // П10: данные и журналы — только владельцу (0700); склейки встреч после SIGKILL — прочь.
        StorageHygiene.secure([paths.root, MostikLogPaths.standard.root, MostikLogPaths.standard.crashes])
        StorageHygiene.cleanStaleTemp(in: FileManager.default.temporaryDirectory)
        CrashReporter.install()
        AppLog.shared.event("app", "start \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        // Запуск из .dmg или транслоцированной копии — предложить перенос в «Программы».
        Task { @MainActor in AppMover.offerIfNeeded() }
        // Проверка обновлений всегда включена (решение автора); перезапуск после установки ждёт конца записи.
        updater = SparkleUpdater(isBusy: { [weak self] in
            guard let self else { return false }
            return self.meetingRecorder != nil || self.hotkeys.isRecording
        })
        model.updatesConfigurable = UpdatePolicy.showsUpdateLedgerLine(updater?.availability ?? .frameworkMissing)
        model.updatesCheckable = updater?.showsCheckItem ?? false
        try? FileManager.default.createDirectory(at: paths.recordings, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: paths.meetings, withIntermediateDirectories: true)
        loadHistoryInBackground()
        loadMeetings()
        refreshPermissions()

        hotkeys.holdKey = model.settings.holdKey
        hotkeys.toggleEnabled = model.settings.toggleShortcutEnabled
        hotkeys.latchEnabled = model.settings.holdLatch
        hotkeys.start()
        upkeep.start()
        voiceEdit.start()
        delivery.start()
        agentVoice.start()
        agentTools.start()
        polishExtras.start()
        meetingLive.start()
        meetingAssist.start()

        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.pushLevel(level) }
        }

        power = PowerMonitor { [weak self] state in
            DispatchQueue.main.async { self?.powerChanged(state) }
        }
        power?.start()
        updateWarm()

        meetingDetector = MeetingDetector { [weak self] app in
            DispatchQueue.main.async { self?.meetingAppChanged(app) }
        }
        meetingDetector?.start()

        startEngine()

        pruneTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.prune() }
        }
        // Календарь движку — раз в час (S1); на старте он уходит после рукопожатия.
        calendarTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.settings.calendarEnabled else { return }
                Task { await self.sendCalendar(); self.refreshSources(rescan: false) }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }

        // Приложение из строки меню почти не становится активным, поэтому выдачу
        // доступа в Настройках ловим опросом, пока доступа нет.
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.lastAccessibility || !Permissions.microphoneAuthorized else { return }
                self.refreshPermissions()
            }
        }

        if !model.settings.onboarded { showOnboarding() }
        externalCalendar.start { [weak self] in
            guard let self, self.model.settings.calendarEnabled else { return }
            Task { await self.sendCalendar(); self.refreshSources(rescan: false) }
        }
        calendarAccounts.start { [weak self] in
            guard let self, self.model.settings.calendarEnabled else { return }
            Task { await self.sendCalendar(); self.refreshSources(rescan: false) }
        }
        if let command = pendingHookQuestion {
            pendingHookQuestion = nil
            DispatchQueue.main.async { [weak self] in self?.meetingFolders.confirmHook(command: command) }
        }
    }

    func shutdown() {
        AppLog.shared.event("app", "quit")
        flushSettingsSave()
        settingsIO.sync {}
        hotkeys.stop()
        upkeep.stop()
        voiceEdit.stop()
        delivery.stop()
        agentVoice.stop()
        meetingLive.stop()
        meetingAssist.stop()
        meetingDetector?.stop()
        power?.stop()
        if meetingRecorder != nil { stopMeeting() }
        recorder.setWarm(false)
        recorder.discard()
        engine.shutdownAndWait()
    }

    // MARK: движок

    private func startEngine() {
        model.engineStatus = .starting
        let generation = engineGate.generation
        engine.onStatus = { [weak self] status in
            DispatchQueue.main.async {
                guard let self, self.engineGate.isCurrent(generation) else { return }
                self.engineStatusChanged(status)
            }
        }
        engine.onEvent = { [weak self] event in
            DispatchQueue.main.async {
                guard let self, self.engineGate.isCurrent(generation) else { return }
                self.engineEvent(event)
            }
        }
        do { try engine.start() } catch {
            model.engineStatus = .failed(error.localizedDescription)
        }
    }

    /// Перезапуск по одному: старый процесс сначала останавливается, и только потом
    /// поднимается новый — два Python с моделями одновременно не живут. Запрос во время
    /// перезапуска вливается в него; конфигурация берётся на момент старта нового.
    private func restartEngine() {
        guard engineGate.begin() else { return }
        let old = engine
        old.onStatus = nil
        old.onEvent = nil
        model.engineStatus = .loading(L10n.isRussian ? "Перезапуск распознавания…" : "Restarting recognition…")
        AppLog.shared.event("engine", "restart requested")
        Task { [weak self] in
            await Task.detached { old.shutdownAndWait(timeout: 3) }.value
            guard let self else { return }
            self.engineGate.finish()
            self.engine = EngineClient(config: Self.engineConfig(settings: self.model.settings, paths: self.paths))
            self.startEngine()
        }
    }

    private func engineStatusChanged(_ status: EngineClient.Status) {
        switch status {
        case .starting:
            model.engineStatus = .starting
        case .running:
            resendMeetings()
            Task { await handshake() }
        case .restarting(let attempt, let delay):
            engineCrashes += 1
            upkeep.engineCrashes = engineCrashes
            AppLog.shared.event("engine", "crashed, restart \(attempt) in \(delay)s, crashes this session \(engineCrashes)")
            model.engineStatus = .loading(EngineRecovery.restarting(attempt: attempt, delay: delay, crashes: engineCrashes,
                                                                    russian: L10n.isRussian))
        case .stopped:
            break
        case .failed(let message):
            AppLog.shared.event("engine", "failed: \(message)")
            model.engineStatus = .failed(message)
            failMeetings(message)
            upkeep.engineFailed()
        }
    }

    /// hello → warmup → power → словари.
    private func handshake() async {
        let ru = L10n.isRussian
        var missing: [String] = []
        // Рукопожатие старого поколения после перезапуска замолкает, а не правит новый статус.
        let generation = engineGate.generation
        do {
            let hello = try await engine.hello()
            guard engineGate.isCurrent(generation) else { return }
            if case .object(let models)? = hello["models"] {
                missing = models.filter { $0.value.boolValue == false }.map(\.key).sorted()
                upkeep.missingModels = missing
            }
            if case .object(let diarization)? = hello["diarization"] {
                upkeep.diarizationAvailable = diarization["available"]?.boolValue
            }
            if case .object(let backends)? = hello["polish"] {
                var available: [String: Bool] = [:]
                for (name, value) in backends {
                    if case .object(let status) = value { available[name] = status["available"]?.boolValue ?? false }
                }
                model.polishAvailable = available
            }
        } catch {
            guard engineGate.isCurrent(generation) else { return }
            model.engineStatus = .failed(error.localizedDescription)
            return
        }
        // Первый запуск без моделей (и без сети) — не ошибка движка, а экран «Нужны модели» (П8, пункт 5).
        let needed = await modelsController.refresh(language: model.settings.language)
        guard engineGate.isCurrent(generation) else { return }
        if !needed.isEmpty {
            model.engineStatus = .failed(modelsController.blockedText(needed))
            return
        }
        model.engineStatus = .loading(ru ? "Загрузка моделей" : "Loading models")
        do {
            _ = try await engine.warmup(language: model.settings.language,
                                        polishBackend: WarmupPolicy.polishBackendToWarm(model.settings))
            guard engineGate.isCurrent(generation) else { return }
            model.engineStatus = .ready
            AppLog.shared.event("engine", "ready")
            upkeep.warmed()
            refreshFallbackProject()
        } catch {
            guard engineGate.isCurrent(generation) else { return }
            let tail = missing.isEmpty ? "" : (ru ? " · нет моделей: " : " · missing models: ") + missing.joined(separator: ", ")
            model.engineStatus = .failed(error.localizedDescription + tail)
        }
        guard engineGate.isCurrent(generation) else { return }
        if let state = power?.current { _ = try? await engine.power(state) }
        await reloadGlossary()
        await glossaryLearning.engineReady()
        await loadProjectTerms()
        await sendCalendar()
        await sendHiddenTerms()
        refreshSources(rescan: false)
        await meetingFolders.migrate()
        await speakersController.engineReady()
        await polishExtras.engineReady()
    }

    private func engineEvent(_ event: EngineEvent) {
        switch event {
        case .partial(let sid, let text):
            if voiceEdit.partial(session: sid, text: text) { return }
            if polishExtras.partial(session: sid, text: text) { return }
            guard sid == session?.id, !text.isEmpty else { return }
            // Окно может прийти целиком заново или только новым куском.
            if text.hasPrefix(model.partialText) || model.partialText.isEmpty {
                model.partialText = text
            } else {
                model.partialText += " " + text
            }
        case .progress(let task, let stage, let done, let total, let detail):
            if modelsController.progress(task: task, done: done, total: total) { return }
            // ИИ встречи идёт своей очередью и не трогает состояние расшифровки.
            if task == "meeting_ai" { meetingAI.progress(stage: stage, done: done, total: total); return }
            // Длинная диктовка ждёт вторую модель: полоса в плашке и «Вставить сразу».
            if task == "dictation" {
                if model.hud == .transcribing, total > 0 { model.verifyProgress = min(Double(done) / Double(total), 1) }
                return
            }
            guard let first = meetingQueue.first else { return }
            // Фаза и короткое имя модели — без дорожек, полных имён моделей и счётчиков окон.
            let share = task == "meeting" && total > 0 ? min(max(Double(done) / Double(total), 0), 1) : nil
            updateMeeting(first.meeting) {
                $0.state = .processing(MeetingProgressText.label(phase: stage, model: detail))
                $0.progress = share
            }
        case .meetingDone(let done):
            guard !meetingQueue.isEmpty else { return }
            let item = meetingQueue.removeFirst()
            let transcript = URL(fileURLWithPath: done.transcriptMd)
            let summary = MeetingFolder.summary(item.outDir)
            let unsplit = summary?.diarizationUnavailable == true
            let voicesFailed = summary?.diarizationFailed == true
            updateMeeting(item.meeting) {
                $0.state = .done
                $0.transcriptPath = transcript
                $0.speakers = done.speakers
                $0.diarizationUnavailable = unsplit
                $0.diarizationFailed = voicesFailed
            }
            // Расшифровка часовой встречи — мегабайты JSON: разбор с фона (шаг 2, п. 10).
            let json = URL(fileURLWithPath: done.transcriptJson)
            Task.detached(priority: .userInitiated) {
                let lines = Self.parseTranscript(json: json)
                await MainActor.run { self.model.meetingTranscripts[item.meeting] = lines }
            }
            meetingFolders.transcriptDone(meeting: item.meeting, folder: item.outDir)
            meetingLive.transcriptDone(meeting: item.meeting, folder: item.outDir)
        case .error(let id, _, let code, let message):
            if let id, let index = meetingQueue.firstIndex(where: { $0.command == id }) {
                let item = meetingQueue.remove(at: index)
                // Пометки и название упавшего задания нужны повтору («Повторить расшифровку», «без голосов»).
                failedJobs[item.meeting] = item
                updateMeeting(item.meeting) {
                    $0.state = .failed(EngineErrorText.short(code: code, message: message))
                    $0.failureCode = code
                }
            } else {
                NSLog("Mostik engine error \(code): \(message)")
            }
        case .final, .reply:
            break
        }
    }

    // MARK: хоткеи и машина состояний

    private func hotkey(_ event: HotkeyMonitor.Event) {
        // Идёт голосовая правка (D5): Recorder занят, новая диктовка не начинается.
        if voiceEdit.isActive, event == .holdBegan || event == .togglePressed { return }
        let now = ProcessInfo.processInfo.systemUptime
        let input: DictationInput
        switch event {
        case .holdBegan: input = .holdBegan(at: now)
        case .holdEnded: input = .holdEnded(at: now)
        case .togglePressed: input = .togglePressed(at: now)
        case .cancel: input = .cancel
        case .latch: input = .latch
        }
        let before = machine.state
        let effects = machine.handle(input)
        // Диагностика: клавиши диктовки и что с ними сделала машина. Без текста диктовки.
        AppLog.shared.event("keys", "\(event) state=\(before) effects=\(effects) meeting=\(meetingRecorder != nil)")
        apply(effects)
    }

    private func apply(_ effects: [DictationEffect]) {
        for effect in effects {
            switch effect {
            case .startRecording(let id): beginRecording(id)
            case .stopRecording(let id): endRecording(id)
            case .discardRecording(let id): discardRecording(id)
            case .insertResult(let id): Task { await insert(id) }
            case .showError(let message): showError(message)
            case .abandonTranscription(let id): abandonTranscription(id)
            case .abortInsertion(let id): abortedInserts.insert(id)
            }
        }
        let menuPhase = MenuVoice.phase(machine.state)
        if model.menuVoicePhase != menuPhase { model.menuVoicePhase = menuPhase }
        // Подсказка в плашке: держат клавишу или уже без рук. Только отображение.
        if case let .recording(_, _, toggled) = machine.state, model.recordingHandsFree != toggled {
            model.recordingHandsFree = toggled
        }
        // Esc ловится вне записи, пока идёт расшифровка или вставка (H2).
        rearmEscape()
    }

    private func beginRecording(_ id: String) {
        let ru = L10n.isRussian
        guard Permissions.microphoneAuthorized else {
            // Отказ сообщаем один раз, а не на каждое нажатие; подробности — в «Диагностике» (R7).
            if upkeep.shouldReportMicrophoneDenied() {
                apply(machine.handle(.failure(ru ? "Нет доступа к микрофону. Настройки → Приватность и данные → Доступ"
                                                 : "No microphone access. Settings → Privacy & Data → Access")))
            } else {
                apply(machine.handle(.reset))
            }
            return
        }
        // П10 р4 Р4-4л: в поле пароля не записываем вовсе — ни причёсывания, ни истории, ни агентов.
        if let refusal = SecureDictation.refusal(secureInput: SecureInput.enabled, field: nil) {
            apply(machine.handle(.failure(refusal))); return
        }
        let settings = model.settings
        if perf?.session != id {
            // Прошлая диктовка ещё проверяет вставку (машина свободна после ⌘V) — её строку допишем позже.
            if let old = perf, old.session != id { lingeringPerf = old }
            perf = DictationPerf(session: id)
            droppedAtStart = machine.droppedPresses
        }
        let wav = paths.recordings.appendingPathComponent("\(id).wav")
        let frontApp = NSWorkspace.shared.frontmostApplication
        let bundleID = frontApp?.bundleIdentifier ?? ""

        // Шаг 1, п. 1–2: сначала запись и плашка. Микрофон стартует на своей очереди (холодный
        // `AVAudioEngine` — до секунды на Bluetooth), звук копится в шлюзе до `start` движку.
        let gate = StartGate<Data>()
        startGate = gate
        recorder.onPCM = { pcm in gate.push(pcm) }
        session = Session(id: id, frontBundleID: bundleID, agentAtStart: false, wav: wav, project: nil,
                          sources: settings.extraSources, polish: nil)
        session?.menuTarget = pendingMenuTarget
        pendingMenuTarget = nil
        perf?.begin("recorder.start")
        recorder.beginAsync(to: wav) { [weak self] error in
            DispatchQueue.main.async { self?.recorderStarted(id, error: error) }
        }
        delivery.recordingBegan()
        hotkeys.isRecording = true
        upkeep.recordingStarted()
        hudHideTask?.cancel()
        model.partialText = ""
        model.micTrouble = nil
        silentSession = nil
        droppedVoiceProcessing = false
        model.levels = Array(repeating: 0, count: model.levels.count)
        model.elapsed = 0
        model.hud = .recording
        recordingStartedAt = Date()
        dictationClock = MeetingClock(startedAt: recordingStartedAt.timeIntervalSince1970)
        model.dictationPaused = false
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let clock = self.dictationClock else { return }
                LiveFeed.tickElapsed(clock.elapsed(at: Date().timeIntervalSince1970), model: self.model)
            }
        }

        // Потом план: заголовок окна, агенты, проект и домен страницы — вне главного потока.
        let name = frontApp?.localizedName ?? ""
        let pid = frontApp?.processIdentifier ?? 0
        let bundlePath = frontApp?.bundleURL?.path
        let ownApp = pid == ProcessInfo.processInfo.processIdentifier
        let agentCLIs = settings.agentPolicy.agentCLIs
        let autoProject = settings.codeAutoProject && frontApp != nil && !ownApp
        let inspector = self.inspector
        let detector = self.projectDetector
        perf?.begin("plan")
        planTask = Task { [weak self] in
            let scan = await Task.detached(priority: .userInitiated) {
                let front = inspector.describe(bundleID: bundleID, name: name, pid: pid, agentCLIs: agentCLIs)
                let detected = autoProject ? detector.detect(pid: pid, bundlePath: bundlePath,
                                                             windowTitle: front.windowTitle, agentNames: agentCLIs) : nil
                let host = pid > 0 ? PolishContextReader.host(bundleID: bundleID, pid: pid) : nil
                return StartScan(front: front, detected: detected, host: host)
            }.value
            self?.planRecording(id, scan: scan, gate: gate)
        }
    }

    /// Что выяснили о приложении впереди вне главного потока (шаг 1, п. 1).
    private struct StartScan: Sendable {
        let front: FrontApp
        let detected: String?
        let host: String?
    }

    /// План диктовки по приложению впереди и `start` движку; копившийся звук уходит следом.
    private func planRecording(_ id: String, scan: StartScan, gate: StartGate<Data>) {
        perf?.end("plan")
        // Запись успели отменить (Esc, короткое нажатие) — движок о ней не узнаёт.
        guard var current = session, current.id == id, startGate === gate else { gate.close(); return }
        let settings = model.settings
        let front = scan.front
        let agent = settings.agentPolicy.isAgent(front)
        let project = resolveProject(detected: scan.detected)
        // В агентных приложениях полировка по умолчанию выключена — независимо от блока сомнений (§6 решений).
        // Сценарий по приложению и сайту, разовый режим ⌃⌘E/⌃⌘J (П6-А, polishExtras).
        var polishPlan = polishExtras.plan(front: front, isAgent: settings.agentPolicy.isAgent(front), host: scan.host)
        // ⌃⌘K (D6): команду разбирает движок по тексту как сказано — без причёсывания.
        let command = voiceIntents.consumeArmed()
        if command { polishPlan.polish = nil }
        let polish = polishPlan.polish
        // Снимок поля — после старта записи (R1), но до `start` движку: звук ждёт в шлюзе.
        let startField = FocusedField.snapshot()
        // П10 р4 Р4-4л: AX-роль поля — до контекста поля и причёсывания (поле пароля без защищённого ввода).
        // Движок о такой записи не узнаёт вовсе.
        if let refusal = SecureDictation.refusal(secureInput: SecureInput.enabled, field: startField) {
            discardRecording(id); apply(machine.handle(.failure(refusal))); return
        }

        // Движок слушает stdin по порядку: `start` уходит раньше первого `audio` — шлюз открываем после.
        let engine = self.engine
        engine.startSession(id, language: polishPlan.language ?? settings.language, project: project,
                            verify: settings.verify, agent: agent, sources: settings.extraSources, polish: polish,
                            languages: polishPlan.language != nil ? [] : LanguageChoice.request(settings: settings, preferred: Locale.preferredLanguages),
                            extra: polishExtras.startFields())
        gate.open { pcm in engine.sendAudio(session: id, pcm: pcm) }
        current = Session(id: id, frontBundleID: front.bundleID, agentAtStart: agent, wav: current.wav,
                          project: project, sources: current.sources, polish: polish,
                          file: current.file, stoppedAt: current.stoppedAt, menuTarget: current.menuTarget)
        current.started = true
        current.startField = startField
        current.polishPlan = polishPlan
        current.command = command
        session = current
        let contextSent = polishExtras.recordingStarted(session: id, plan: polishPlan, field: current.startField,
                                                        bundleID: front.bundleID)
        session?.polishContextSent = contextSent
        agentVoice.recordingBegan(project: project)
    }

    /// Микрофон запустился (или нет) на своей очереди.
    private func recorderStarted(_ id: String, error: Error?) {
        perf?.end("recorder.start")
        AppLog.shared.event("keys", "recorder started error=\(error.map { String(describing: $0) } ?? "nil")")
        guard let error else {
            upkeep.gate.succeeded("recorder")
            // Микрофон «запустился», но звука нет — так выглядит залипший после смены устройств вход.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.session?.id == id, self.perf?.session == id, self.perf?.hasFirstBuffer == false else { return }
                AppLog.shared.event("keys", "no audio buffers 2 s after start")
            }
            return
        }
        guard session?.id == id else { return }
        startGate?.close()
        startGate = nil
        planTask?.cancel()
        if session?.started == true { engine.cancel(session: id) }
        session = nil
        stopRecordingUI()
        // Микрофон занят или ещё не проснулся — повтор с паузой, пока клавиша держится (R7).
        if case .retry(let after) = upkeep.gate.transient("recorder") {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
                guard let self, self.machine.currentSession == id, self.session == nil else { return }
                self.beginRecording(id)
            }
            return
        }
        upkeep.gate.succeeded("recorder")
        apply(machine.handle(.failure(error.localizedDescription)))
    }

    /// Залипший микрофон (`SilentInputWatch`): запись идёт, Recorder переподключает вход — говорим, что происходит.
    private func silentInput(_ action: SilentInputWatch.Action) {
        AppLog.shared.event("mic", "silent input: \(action)")
        let ru = L10n.isRussian
        switch action {
        case .none:
            return
        case .dropVoiceProcessing:
            model.micTrouble = ru ? "Без шумоподавления…" : "Turning off noise suppression…"
            // С обработкой голоса вход отдавал нули — выключаем её и в Настройках, иначе следующая запись повторит.
            var settings = model.settings
            settings.meetingLive.dictationVoiceProcessing = false
            applySettings(settings)
            droppedVoiceProcessing = true
        case .reconnect:
            model.micTrouble = ru ? "Переподключаю микрофон…" : "Reconnecting the mic…"
        case .warn:
            model.micTrouble = ru ? "Микрофон молчит" : "The mic is silent"
            silentSession = session?.id
        case .recovered:
            // Шумоподавление уже выключено и в Настройках; помнить об этом всю запись незачем — только в журнале.
            model.micTrouble = nil
        }
    }

    /// Удаление диктовки из карточки: запись и звук уходят из истории, в памяти — то же, что в файле.
    private func deleteEntry(_ entry: HistoryEntry) {
        do {
            try history.remove(id: entry.id)
            model.history.removeAll { $0.id == entry.id }
            AppLog.shared.event("history", "deleted entry")
        } catch {
            AppLog.shared.event("history", "delete failed: \(error.localizedDescription)")
        }
    }

    /// Пауза диктовки из плашки: звук не идёт движку, таймер стоит.
    private func toggleDictationPause() {
        guard model.hud == .recording, var clock = dictationClock else { return }
        let now = Date().timeIntervalSince1970
        if clock.isPaused { clock.resume(at: now) } else { clock.pause(at: now) }
        dictationClock = clock
        recorder.isPaused = clock.isPaused
        model.dictationPaused = clock.isPaused
        AppLog.shared.event("dictation", clock.isPaused ? "paused" : "resumed")
    }

    private func stopRecordingUI() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        dictationClock = nil
        model.dictationPaused = false
        hotkeys.isRecording = false
        upkeep.recordingStopped()
    }

    private func endRecording(_ id: String) {
        perf?.mark(.release)
        stopRecordingUI()
        guard var current = session, current.id == id, let file = recorder.end() else {
            apply(machine.handle(.failure(L10n.isRussian ? "Запись не сохранилась" : "Recording was not saved")))
            return
        }
        // П10 р5: поле пароля появилось посреди записи — не расшифровываем, звук удаляем.
        if let refusal = SecureDictation.stopRefusal(secureInput: SecureInput.enabled, field: FocusedField.snapshot()) {
            dropSecureRecording(id, file: file, refusal: refusal); return
        }
        current.file = file
        current.stoppedAt = Date()
        session = current
        model.hud = .transcribing
        let settings = model.settings
        let engine = self.engine
        let plan = planTask
        let perf = self.perf
        perf?.begin("engine.final")
        Task {
            // План решается после старта записи; короткая фраза может закончиться раньше него.
            await plan?.value
            guard let planned = self.session, planned.id == id else { return }
            guard planned.started else {
                self.apply(self.machine.handle(.failure(L10n.isRussian ? "Запись не сохранилась" : "Recording was not saved")))
                return
            }
            current = planned
            let wait = current.agentAtStart ? 5000 : 0
            // Потоковый черновик — последний запасной текст, если не удастся ни stop, ни повтор по файлу (D2).
            let partial = self.model.partialText
            var result: DictationResult
            do {
                result = try await engine.stop(session: id, waitVerifierMs: wait, audioSeconds: file.seconds,
                                               polishing: current.polish != nil)
                perf?.mark(.engineFinal)
                perf?.end("engine.final", result.timings.breakdown)
                self.engineBreakdown = result.timings.breakdown
            } catch is CancellationError {
                return
            } catch {
                // Движок упал или не ответил — WAV на диске, распознаём его целиком (§6).
                do {
                    result = try await self.retryFile(file.url, settings: settings, project: current.project,
                                                      sources: current.sources, polish: current.polish)
                } catch {
                    guard let fallback = DictationResult.rawFallback(session: id, partial: partial,
                                                                     language: settings.language) else {
                        // Брошенная по Esc уже в истории с аудио — ошибку не показываем.
                        if self.abandonedSessions.remove(id) != nil { return }
                        self.recordFailure(id: id, file: file, message: error.localizedDescription)
                        return
                    }
                    result = fallback
                }
            }
            if self.abandonedSessions.remove(id) != nil { self.keepCancelled(id: id, result: result); return }
            guard self.machine.currentSession == id else { return }
            self.session?.result = result
            self.apply(self.machine.handle(.resultReady))
        }
    }

    /// Повтор по файлу; если движок перезапускается — ждём его до 20 с.
    private func retryFile(_ url: URL, settings: MostikSettings, project: String?, sources: [String],
                           polish: PolishRequest?) async throws -> DictationResult {
        // Движок окончательно не запустился — ждать нечего, сразу ошибка вместо 20 с «расшифровки».
        if case .failed = model.engineStatus, !engine.isRunning { throw EngineError.notRunning }
        for _ in 0..<40 where !engine.isRunning { try await Task.sleep(nanoseconds: 500_000_000) }
        return try await engine.transcribeFile(path: url.path, language: settings.language, project: project,
                                               sources: sources, polish: polish,
                                               languages: LanguageChoice.request(settings: settings,
                                                                                 preferred: Locale.preferredLanguages))
    }

    /// П10 р5: запись в поле пароля — без звука, расшифровки и истории; причина в плашке.
    private func dropSecureRecording(_ id: String, file: RecordingFile, refusal: String) {
        try? FileManager.default.removeItem(at: file.url)
        startGate?.close()
        startGate = nil
        planTask?.cancel()
        // План ещё не отправил `start` — движку отменять нечего, а `planRecording` увидит пустую сессию.
        if session?.id != id || session?.started == true { engine.cancel(session: id) }
        polishExtras.cancelStream(session: id)
        if session?.id == id { session = nil }
        model.partialText = ""
        apply(machine.handle(.failure(refusal)))
    }

    private func discardRecording(_ id: String) {
        stopRecordingUI()
        recorder.discard()
        startGate?.close()
        startGate = nil
        planTask?.cancel()
        // `start` ещё не ушёл — движку отменять нечего.
        if session?.id != id || session?.started == true { engine.cancel(session: id) }
        polishExtras.cancelStream(session: id)
        if session?.id == id { session = nil }
        model.partialText = ""
        model.hud = .hidden
    }

    /// Esc во время расшифровки (H2): машина уже свободна, движок досчитывает. Сразу пишем
    /// в историю «отменено» с аудио и черновиком, готовый текст допишет `keepCancelled`.
    private func abandonTranscription(_ id: String) {
        guard let current = session, current.id == id else { return }
        abandonedSessions.insert(id)
        let entry = HistoryEntry(id: id, text: model.partialText, language: model.settings.language,
                                 audioSeconds: current.file?.seconds ?? 0, audioPath: current.file?.url.path,
                                 outcome: "cancelled", verifier: "off")
        model.history.insert(history.record(entry), at: 0)  // Р5-1л: в памяти — то, что в файле
        session = nil
        model.partialText = ""
        delivery.notice(L10n.isRussian ? "Отменено" : "Cancelled",
                        L10n.isRussian ? "Текст сохранён в истории" : "Text kept in history")
    }

    private func keepCancelled(id: String, result: DictationResult) {
        guard var entry = model.history.first(where: { $0.id == id }) else { return }
        let text = result.insertable.text
        if !text.isEmpty { entry.text = text }
        entry.rawText = result.rawTextForHistory
        entry.doubts = result.doubts
        entry.corrections = result.corrections
        entry.language = result.language
        entry.verifier = result.verifier
        replaceEntry(entry)
    }

    private func insert(_ id: String) async {
        guard let current = session, current.id == id, let result = current.result, let file = current.file else {
            apply(machine.handle(.reset))
            return
        }
        let ru = L10n.isRussian
        let settings = model.settings
        // Обработка не дала текста, а сырой есть — вставляем сырой, а не ничего (D2).
        var text = result.insertable.text
        if text.isEmpty {
            try? FileManager.default.removeItem(at: file.url)
            if silentSession == id {
                // Вход так и не дал звука — дело не в речи: говорим, что проверить.
                model.hud = .error(ru ? "Микрофон не дал звука. Проверьте вход в Настройках → Основное"
                                      : "The microphone gave no sound. Check the input in Settings → General")
                finishSession(id)
                scheduleHUDHide(after: 4)
                return
            }
            model.hud = .done(summary: ru ? "Речи не слышно" : "No speech heard", doubts: 0, agent: false)
            finishSession(id)
            return
        }
        // П10 р5 Р5-1л: поле пароля в момент вставки — ни очереди агенту, ни tmux, ни потоковой вставки.
        // Хвост р5 Ф-4: и флаг защищённого ввода, и роль AXSecureTextField; до голосовой команды — иначе пароль,
        // похожий на команду, лёг бы в историю с исходом `command`.
        if SecureDictation.stopRefusal(secureInput: SecureInput.enabled, field: FocusedField.snapshot()) != nil {
            polishExtras.cancelStream(session: id)
            let refused = HistoryEntry(id: id, text: text, language: result.language, audioSeconds: file.seconds,
                                       audioPath: file.url.path, outcome: SecureDictation.outcome)
            model.history.insert(history.record(refused), at: 0)
            model.hud = .error(ru ? "Поле пароля — текст не сохранён" : "Password field — text not saved")
            finishSession(id)
            return
        }
        // Голосовая команда (D6): выше порога — карточка с черновиком вместо вставки; ниже — вставка как обычно.
        if current.command, await voiceIntents.handle(text: text, language: result.language) {
            let keep = settings.keepAudio
            if !keep { try? FileManager.default.removeItem(at: file.url) }
            let entry = HistoryEntry(id: id, text: text, doubts: result.doubts, corrections: result.corrections,
                                     language: result.language, audioSeconds: file.seconds,
                                     audioPath: keep ? file.url.path : nil, outcome: "command",
                                     verifier: result.verifier, rawText: result.rawTextForHistory)
            model.history.insert(history.record(entry), at: 0)  // Р5-1л: в памяти — то, что в файле
            model.hud = .done(summary: ru ? "Черновик готов — проверьте" : "Draft ready — check it", doubts: 0, agent: false)
            finishSession(id)
            return
        }
        // Агентность решаем в момент вставки (§3, шаг 6).
        let front = inspector.current(agentCLIs: settings.agentPolicy.agentCLIs)
        // Обращение к сессии, «отправь», @файлы; панель tmux вместо ⌘V (G5, G6, A3, A5).
        // П10 р3 Н-7: «отправь» и адрес — по сказанному до модели, а не по её ответу.
        let route = await agentVoice.route(text: text, front: front, project: current.project,
                                           spoken: SpokenCommands.spoken(result))
        text = route.text
        if text.isEmpty, route.submit {
            // Сказали только «отправь»: вставлять нечего, жмём Enter.
            try? FileManager.default.removeItem(at: file.url)
            await agentVoice.submit(route, bundleID: front.bundleID)
            model.hud = .done(summary: ru ? "Отправлено" : "Sent", doubts: 0, agent: false)
            finishSession(id)
            return
        }
        let agent = settings.agentPolicy.isAgent(front) || route.pane != nil
        // Слова под вопросом в текст не дописываем и агенту тоже (C4): они решаются в истории и на плашке.
        let composed = text
        let raw = result.rawTextForHistory ?? text
        // Esc пришёл до вставки — не вставляем вовсе, текст в историю как «отменено» (H2).
        if abortedInserts.remove(id) != nil {
            let entry = HistoryEntry(id: id, text: text, insertedText: composed, doubts: result.doubts,
                                     corrections: result.corrections, language: result.language,
                                     audioSeconds: file.seconds, appName: front.name, agent: agent,
                                     audioPath: file.url.path, outcome: "cancelled", verifier: result.verifier,
                                     rawText: result.rawTextForHistory)
            model.history.insert(history.record(entry), at: 0)  // Р5-1л: в памяти — то, что в файле
            delivery.notice(ru ? "Отменено" : "Cancelled", ru ? "Текст сохранён в истории" : "Text kept in history")
            finishSession(id)
            return
        }
        // Запись из меню: приложение, где стоял курсор, закрыли — текст в буфер, а не в случайное окно.
        let menuReason = route.pane == nil ? MenuVoice.delivery(current.menuTarget, isRunning: FocusReturn.isRunning) : nil
        if menuReason != nil { paster.write(composed) }
        // Агент занят — в очередь (A6); куски уже вставлены по ходу — дописать или заменить (P6). polishExtras
        let queuedForAgent = route.pane == nil && menuReason == nil
            && AgentQueue.allowsEnqueue(contextSent: current.polishContextSent, polished: result.polished)  // Р4-4и
            && polishExtras.enqueueForAgent(composed, front: front, project: current.project)
        let streamed = route.pane == nil && menuReason == nil && !queuedForAgent
            ? await polishExtras.finishStream(session: id, text: composed) : nil
        polishExtras.cancelStream(session: id)
        let report = if let menuReason {
            DeliveryReport(outcome: .clipboard(reason: menuReason.rawValue), sent: composed)
        } else if queuedForAgent {
            DeliveryReport(outcome: .inserted, check: nil, before: nil, after: nil, sent: composed)
        } else if let streamed {
            streamed
        } else if let pane = route.pane {
            await agentVoice.deliver(composed, to: pane, id: id)
        } else {
            await deliverMeasured(text: composed, raw: raw, id: id, current: current)
        }
        let outcome = report.outcome
        // Esc посреди вставки (A7): вставка уже ушла — откатываем её, поле не трогали — нет.
        let aborted = abortedInserts.remove(id) != nil

        let latency = current.stoppedAt.map { Date().timeIntervalSince($0) * 1000 } ?? result.timings.totalMs
        // Аудио остаётся при любом сбое: не вставлено, в буфере, отменено (R5).
        let keepFile = settings.keepAudio || outcome != .inserted || aborted
        if !keepFile { try? FileManager.default.removeItem(at: file.url) }
        var entry = HistoryEntry(id: id, text: text, insertedText: outcome == .inserted ? report.sent : composed,
                                 doubts: result.doubts,
                                 corrections: result.corrections, language: result.language,
                                 audioSeconds: file.seconds, latencyMs: latency, appName: front.name, agent: agent,
                                 audioPath: keepFile ? file.url.path : nil, outcome: outcome.historyValue,
                                 verifier: result.verifier, rawText: result.rawTextForHistory)
        entry.pasteCheck = report.check?.rawValue
        if aborted, outcome != .inserted { entry.outcome = "cancelled" }
        model.history.insert(history.record(entry), at: 0)  // Р5-1л: в памяти — то, что в файле

        if aborted {
            finishSession(id)
            // В панель tmux откатить нечем: запись отката — от прошлой вставки ⌘V.
            if outcome == .inserted, route.pane == nil { await delivery.revert(.cancel) } else {
                delivery.notice(ru ? "Отменено" : "Cancelled", ru ? "Текст сохранён в истории" : "Text kept in history")
            }
            return
        }

        let shownDoubts = result.doubts.count
        // Голосовая отправка (G6): Enter только за дошедшей вставкой.
        // П10: Enter сценария — не после контекста из агента или терминала (`AutoEnterGuard`).
        let scenarioEnter = AutoEnterGuard.allows(planned: current.polishPlan?.autoEnter == true,
                                                  contextSent: current.polishContextSent,
                                                  front: front, policy: settings.agentPolicy)
            && !(current.polishContextSent && route.pane != nil)
        if current.polishPlan?.autoEnter == true, !scenarioEnter {
            AppLog.shared.event("polish", "auto-enter skipped: context from agent or terminal")
        }
        if route.submit || scenarioEnter, !queuedForAgent, outcome == .inserted, report.check != .notInserted {  // polishExtras: Enter из сценария
            await agentVoice.submit(route, bundleID: front.bundleID)
        }
        switch outcome {
        case .inserted:
            let summary = agentVoice.summary(for: route) ?? (route.submit ? (ru ? "Отправлено" : "Sent") : (ru ? "Вставлено" : "Inserted"))
            if ownsHUD(id) { model.hud = .done(summary: summary, doubts: shownDoubts, agent: agent) }
        case .clipboard(let reason) where reason == DeliveryReason.notInserted.rawValue:
            // R2: поле не изменилось — карточка, текст в буфере и в истории.
            delivery.notice(ru ? "Текст не вставлен" : "Text not inserted",
                            ru ? "Текст в буфере — вставьте его ⌘V" : "Text on clipboard — paste it with ⌘V")
        case .clipboard(let reason) where reason == DeliveryReason.notEditable.rawValue:
            delivery.notice(ru ? "Курсор не в текстовом поле" : "Cursor isn't in a text field",
                            ru ? "Текст в буфере · ⌘V" : "Text on clipboard · ⌘V")
        case .clipboard(let reason) where MenuVoice.clipboardSummary(reason) != nil:
            if ownsHUD(id) { model.hud = .done(summary: MenuVoice.clipboardSummary(reason) ?? "", doubts: shownDoubts, agent: agent) }
        case .clipboard(let reason):
            let summary = reason == "focus_changed"
                ? (ru ? "В буфере — окно сменилось" : "On clipboard — window changed")
                : (ru ? "Текст в буфере. Включите Mostik в Универсальном доступе" : "Text on clipboard. Turn Mostik on in Accessibility")
            if ownsHUD(id) { model.hud = .done(summary: summary, doubts: shownDoubts, agent: agent) }
        case .secureInput:
            if ownsHUD(id) { model.hud = .error(ru ? "Поле пароля — текст не сохранён" : "Password field — text not saved") }  // Р4-4л
        case .failed(let message):
            if ownsHUD(id) { model.hud = .error((ru ? "Вставка не удалась: " : "Paste failed: ") + message) }
        }
        if queuedForAgent, ownsHUD(id) { model.hud = .done(summary: ru ? "Агенту — в очередь" : "Queued for the agent", doubts: shownDoubts, agent: agent) }  // polishExtras, A6
        finishSession(id)
    }

    /// Вставка ⌘V с замером `deliver` и отметкой `paste.posted` (шаг 0).
    private func deliverMeasured(text: String, raw: String, id: String, current: Session) async -> DeliveryReport {
        let perf = self.perf?.session == id ? self.perf : nil
        perf?.begin("deliver")
        deliveringIDs.insert(id)
        let report = await delivery.deliver(text: text, raw: raw, entryID: id, expectedBundleID: current.frontBundleID,
                                            start: current.startField, onPosted: { [weak self] in
            perf?.mark(.pastePosted)
            MainActor.assumeIsolated { self?.pastePosted(id) }
        })
        deliveringIDs.remove(id)
        rearmEscape()
        perf?.end("deliver")
        return report
    }

    /// Шаг 1, п. 3: ⌘V ушёл — машина свободна, следующее нажатие пишет сразу.
    /// Проверка вставки и возврат буфера идут дальше в фоне; Esc в это время всё ещё откатывает.
    private func pastePosted(_ id: String) {
        guard case .inserting(let active) = machine.state, active == id else { return }
        apply(machine.handle(.pastePosted))
        if perf?.session == id { perf?.mark(.idle) }
    }

    /// Esc взведён, пока машина занята или ещё идёт проверка вставки (её можно отменить).
    private func rearmEscape() {
        switch machine.state {
        case .transcribing, .inserting: delivery.escapeArmed = true
        case .idle: delivery.escapeArmed = !deliveringIDs.isEmpty
        default: delivery.escapeArmed = false
        }
    }

    /// Строка отрезков диктовки в `app.log` (шаг 0) — один раз, когда машина свободна.
    private func logPerf(_ id: String) {
        let perf = self.perf?.session == id ? self.perf : lingeringPerf?.session == id ? lingeringPerf : nil
        guard let perf else { return }
        if lingeringPerf === perf { lingeringPerf = nil }
        perf.mark(.idle)
        if let line = perf.finish(engine: engineBreakdown, dropped: machine.droppedPresses - droppedAtStart) {
            AppLog.shared.event("perf", line)
        }
        engineBreakdown = ""
    }

    /// Плашка ещё за этой диктовкой: после ⌘V машина свободна, и плашку могла занять новая запись.
    private func ownsHUD(_ id: String) -> Bool { session == nil || session?.id == id }

    /// `id` — чья вставка закончилась: после Esc уже могла начаться новая запись, её не трогаем.
    private func finishSession(_ id: String? = nil) {
        if let id { logPerf(id) }
        if let id, let active = session?.id, active != id { return }
        session = nil
        model.partialText = ""
        apply(machine.handle(.inserted))
        // Итог с сомнениями — ссылка в историю (П9-B): держим его дольше, чтобы успеть нажать.
        if case let .done(_, doubts, _) = model.hud, doubts > 0 {
            scheduleHUDHide(after: 4)
        } else {
            scheduleHUDHide(after: 1.2)
        }
    }

    private func recordFailure(id: String, file: RecordingFile, message: String) {
        AppLog.shared.error("dictation", "transcription failed after \(String(format: "%.1f", file.seconds)) s audio: \(message)")
        let entry = HistoryEntry(id: id, text: "", language: model.settings.language, audioSeconds: file.seconds,
                                 audioPath: file.url.path, outcome: "failed", verifier: "off")
        model.history.insert(history.record(entry), at: 0)  // Р5-1л: в памяти — то, что в файле
        session = nil
        apply(machine.handle(.failure(message)))
    }

    private func showError(_ message: String) {
        AppLog.shared.error("dictation", message)
        stopRecordingUI()
        model.hud = .error(message)
        scheduleHUDHide(after: 2.5)
    }

    private func scheduleHUDHide(after seconds: Double) {
        hudHideTask?.cancel()
        hudHideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            switch self.model.hud {
            case .done, .error:
                self.model.hud = .hidden
                if case .failed = self.machine.state { self.apply(self.machine.handle(.reset)) }
            default: break
            }
        }
    }

    private func pushMeetingLevel(_ level: Float) {
        guard meetingRecorder != nil, model.hud == .hidden, !model.meetingPaused else { return }
        LiveFeed.pushLevel(level, into: model)
    }

    private func pushLevel(_ level: Float) {
        guard case .recording = model.hud else { return }
        LiveFeed.pushLevel(level, into: model)
        // Значок строки меню «дышит» голосом (решение автора); «Уменьшить движение» — статичен.
        model.menuIcon.level(level, at: ProcessInfo.processInfo.systemUptime,
                             reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    // MARK: настройки, тёплый микрофон, питание

    private func applySettings(_ proposed: MostikSettings) {
        let old = model.settings
        // Приватность: смена бэкенда сбрасывает облачное согласие встреч; снимок согласий — в EngineClient.
        var new = MeetingCloudPolicy.reconcile(old: old, new: proposed)
        if MeetingHookTrust.isCommandEdit(old: old.meetingHook, new: new.meetingHook) {
            // Шаг 2, п. 10: ввод команды включённого хука — отпечаток в связку ключей один раз после паузы,
            // а не на каждую клавишу (`flushSettingsSave`). Итог тот же: запись отпечатка последней команды.
            if pendingHookOld == nil { pendingHookOld = old.meetingHook }
        } else {
            flushSettingsSave()
            // П10 С3: команда хука, введённая здесь, — подтверждена пользователем; только включённая — спросить (Р4-3).
            let hook = MeetingHookTrust.applyChange(old: old.meetingHook, new: new.meetingHook, store: hookStore)
            new.meetingHook = hook.settings
            if let command = hook.ask {
                DispatchQueue.main.async { [weak self] in self?.meetingFolders.confirmHook(command: command) }
            }
        }
        EngineClient.cloudGrants = CloudGrants(settings: new)
        EngineClient.ownerName = new.myName.trimmingCharacters(in: .whitespacesAndNewlines)
        model.settings = new
        // Шаг 2, п. 10: JSON — один раз после паузы в 400 мс, а не на каждую клавишу.
        scheduleSettingsSave(new)
        hotkeys.holdKey = new.holdKey
        hotkeys.toggleEnabled = new.toggleShortcutEnabled
        machine.doubleTapEnabled = new.handsFreeDoubleTap
        hotkeys.latchEnabled = new.holdLatch
        voiceEdit.settingsChanged()
        upkeep.settingsChanged()
        agentVoice.settingsChanged()
        polishExtras.settingsChanged()
        voiceIntents.settingsChanged()
        meetingLive.settingsChanged()
        if new.meetingLive.dictationVoiceProcessing != old.meetingLive.dictationVoiceProcessing {
            // Обработка голоса включается только на остановленном движке: тёплый микрофон перезапускаем.
            recorder.voiceProcessing = new.meetingLive.dictationVoiceProcessing
            recorder.setWarm(false)
        }
        if new.micDeviceUID != old.micDeviceUID { recorder.setMicDevice(new.micDeviceUID) }
        updateWarm()
        model.models.language = new.language  // от языка зависит, какие модели обязательны (П8, пункт 5)
        if new.enginePython != old.enginePython {
            restartEngine()
        } else if new.language != old.language, model.engineStatus == .ready {
            Task { _ = try? await engine.warmup(language: new.language, polishBackend: WarmupPolicy.polishBackendToWarm(new)) }
        } else if let backend = WarmupPolicy.polishBackendToWarm(new), WarmupPolicy.polishBackendToWarm(old) == nil,
                  model.engineStatus == .ready {
            // Причёсывание переключили на MLX — модель грузится сейчас, а не на первой диктовке (шаг 1, п. 7).
            Task { _ = try? await engine.warmup(language: new.language, polishBackend: backend) }
        }
        if new.projectPath != old.projectPath { refreshFallbackProject() }
        if new.codeProjectPath != old.codeProjectPath || new.codeAutoProject != old.codeAutoProject {
            // Ручной проект, выключенный автопоиск или термины из кода меняют проект сразу, не дожидаясь диктовки.
            if !(currentProjectIsAuto && new.codeAutoProject) {
                setCurrentProject(new.codeProjectPath, auto: false)
            }
        }
        if new.extraSources != old.extraSources { refreshSources(rescan: false) }
        if new.hiddenTerms != old.hiddenTerms { Task { await sendHiddenTerms() } }
        externalCalendar.settingsChanged(old: old, new: new)
        calendarAccounts.settingsChanged(old: old, new: new)
        if new.calendarEnabled != old.calendarEnabled { Task { await sendCalendar(clearIfOff: true); refreshSources(rescan: false) } }
        if new.retentionDays != old.retentionDays { prune(); model.history = history.load() }
        if new.onboarded, !old.onboarded { closeOnboarding() }
        if !new.meetingSuggest { model.meetingSuggestion = nil }
    }

    private func updateWarm() {
        let lowBattery = power?.current.batteryLow ?? false
        recorder.setWarm(model.settings.warmMicrophone && !lowBattery && Permissions.microphoneAuthorized)
    }

    private func scheduleSettingsSave(_ new: MostikSettings) {
        settingsSave.submit(new, at: ProcessInfo.processInfo.systemUptime)
        settingsSaveTask?.cancel()
        let delay = settingsSave.delay
        settingsSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.flushSettingsSave()
        }
    }

    /// Записать отложенное: отпечаток команды хука — здесь, JSON — на фоновой очереди по порядку.
    private func flushSettingsSave() {
        settingsSaveTask?.cancel()
        settingsSaveTask = nil
        guard let value = settingsSave.flush() else { return }
        if let hookOld = pendingHookOld {
            // Только правка команды включённого хука: запись отпечатка, без вопроса (см. applySettings).
            MeetingHookTrust.applyChange(old: hookOld, new: value.meetingHook, store: hookStore)
        }
        pendingHookOld = nil
        let path = paths.settings
        settingsIO.async { try? value.save(to: path) }
    }

    private func powerChanged(_ state: PowerState) {
        updateWarm()
        Task { _ = try? await engine.power(state) }
    }

    /// История при старте — с фона (шаг 2, п. 10): чистка по сроку хранения и чтение файла
    /// не держат главный поток. Записи, появившиеся за это время, не теряются.
    private func loadHistoryInBackground() {
        let history = self.history
        let days = max(1, model.settings.retentionDays)
        Task.detached(priority: .utility) {
            _ = try? history.prune(retention: TimeInterval(days) * 86_400,
                                   audioRetention: TimeInterval(MostikSettings.dictationAudioDays) * 86_400)
            let loaded = history.load()
            await MainActor.run {
                let known = Set(loaded.map(\.id))
                self.model.history = self.model.history.filter { !known.contains($0.id) } + loaded
            }
        }
    }

    private func prune() {
        let days = max(1, model.settings.retentionDays)
        let before = model.history.filter { $0.audioPath != nil }.count
        _ = try? history.prune(retention: TimeInterval(days) * 86_400,
                               audioRetention: TimeInterval(MostikSettings.dictationAudioDays) * 86_400)
        // Звук старше суток снят (П10) — список в окне без устаревших путей.
        let loaded = history.load()
        if loaded.filter({ $0.audioPath != nil }).count != before || loaded.count != model.history.count { model.history = loaded }
    }

    // MARK: разрешения и онбординг

    /// Список входов и текущий вход для строки «Микрофон» в Настройках (R3b).
    private func refreshInputDevices() {
        model.inputDevices = AudioInputs.list().map { InputDevice(id: $0.id, uid: $0.uid, name: $0.name) }
        model.inputDeviceID = AudioInputs.systemDefaultID()
    }

    private func refreshPermissions() {
        let accessibility = Permissions.accessibilityTrusted
        model.permissions = AppModel.Permissions(microphone: Permissions.microphoneAuthorized,
                                                 accessibility: accessibility,
                                                 screenRecording: Permissions.systemAudioGranted,
                                                 postEvents: Permissions.postEventsGranted,
                                                 screenCapture: Permissions.screenCaptureGranted)
        // Глобальные мониторы, поставленные до выдачи доступа, могут молчать — переставляем.
        if accessibility, !lastAccessibility { hotkeys.stop(); hotkeys.start(); voiceEdit.stop(); voiceEdit.start(); upkeep.accessibilityGranted() }
        if accessibility, !lastAccessibility { delivery.restart() }
        if Permissions.microphoneAuthorized { upkeep.microphoneGranted() }
        // Право слать нажатия (вставка) процесс получает только при запуске:
        // доступ выдан на ходу — перезапускаемся сами, иначе вставка молча не работает.
        if accessibility, !CGPreflightPostEventAccess(), permissionsChecked, !relaunching {
            relaunching = true
            relaunch()
        }
        permissionsChecked = true
        lastAccessibility = accessibility
    }

    private func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: Relaunch.shell)
        // Ждём своего выхода, потом открываем заново: два экземпляра делили бы хоткей. П10 р4 Р4-2: окружение и пути.
        task.arguments = Relaunch.arguments(pid: ProcessInfo.processInfo.processIdentifier, bundlePath: path)
        task.environment = Relaunch.environment(ProcessInfo.processInfo.environment)
        try? task.run()
        NSApp.terminate(nil)
    }

    private func showOnboarding() {
        windows.showOnboarding()
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshPermissions()
                if !self.windows.isOnboardingVisible { self.permissionTimer?.invalidate(); self.permissionTimer = nil }
            }
        }
    }

    private func closeOnboarding() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        windows.closeOnboarding()
    }

    // MARK: словари

    private func reloadGlossary() async {
        guard let items = try? await engine.glossaryList() else { return }
        model.glossary = items.map { AppModel.GlossaryItem(canonical: $0.canonical, aliases: $0.aliases, source: $0.source) }
    }

    private func loadProjectTerms() async {
        guard let path = model.currentProject else { model.projectTerms = []; return }
        model.projectTerms = (try? await engine.projectGlossary(path: path)) ?? []
    }

    private func chooseProject(_ url: URL?) {
        var settings = model.settings
        if let url {
            settings.projectPath = url.path
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = L10n.isRussian ? "Выбрать" : "Choose"
            if let path = settings.projectPath { panel.directoryURL = URL(fileURLWithPath: path) }
            MenuBarPanel.activateApp()
            guard panel.runModal() == .OK, let picked = panel.url else { return }
            settings.projectPath = picked.path
        }
        settings.codeTerms = true  // папку проекта выбрали руками — значит, термины из кода нужны
        applySettings(settings)
    }

    private func chooseEnginePython() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = URL(fileURLWithPath: EngineLocator.python(settings: model.settings)).deletingLastPathComponent()
        MenuBarPanel.activateApp()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var settings = model.settings
        settings.enginePython = url.path
        applySettings(settings)
    }

    // MARK: автопроект и источники (S1, S5)

    /// Проект для диктовки: агент в дереве процессов переднего приложения → корень git;
    /// не нашли — ручной `projectPath`. Обновляет `model.currentProject` и источники.
    /// `detected` — найденный вне главного потока на старте записи (шаг 1, п. 1).
    private func resolveProject(detected: String?) -> String? {
        let settings = model.settings
        let effective = ProjectResolver.effectiveProject(detected: detected, autoEnabled: settings.codeAutoProject,
                                                         manual: settings.codeProjectPath)
        setCurrentProject(effective.path, auto: effective.auto)
        return effective.path
    }

    /// Запасная папка проекта: нет её — `.missing`, нет терминов — `.empty` (предупреждение в Настройках).
    private func refreshFallbackProject() {
        guard let path = model.settings.projectPath, !path.isEmpty else { model.fallbackProjectStatus = .unknown; return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            model.fallbackProjectStatus = .missing
            return
        }
        let engine = self.engine
        Task {
            guard let reply = try? await engine.sources(project: path, sources: [], rescan: false),
                  path == self.model.settings.projectPath else { return }
            let total = reply.sources.first { $0.kind == "repo" }?.total ?? 0
            self.model.fallbackProjectStatus = total > 0 ? .terms(total) : .empty
        }
    }

    private func setCurrentProject(_ path: String?, auto: Bool) {
        let pathChanged = model.currentProject != path
        let autoChanged = currentProjectIsAuto != auto
        currentProjectIsAuto = auto
        guard pathChanged || autoChanged else { return }
        model.currentProject = path
        if pathChanged { Task { await loadProjectTerms() } }
        refreshSources(rescan: false)
    }

    /// `sources` или `rescan` → `model.sources`/`model.terms`. Ошибка оставляет прошлый список.
    private func refreshSources(rescan: Bool) {
        sourcesGeneration += 1
        let generation = sourcesGeneration
        let project = model.currentProject
        let auto = currentProjectIsAuto
        let extra = model.settings.extraSources
        let engine = self.engine
        model.sourcesScanning = true
        Task {
            defer { if generation == self.sourcesGeneration { self.model.sourcesScanning = false } }
            let reply: SourcesReply
            do { reply = try await engine.sources(project: project, sources: extra, rescan: rescan) } catch {
                NSLog("Mostik sources: \(error.localizedDescription)")
                return
            }
            guard generation == self.sourcesGeneration else { return }
            let projectKey = project.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            self.model.sources = reply.sources.map { s in
                let key = s.path.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
                return AppModel.SourceItem(kind: s.kind, label: s.label, path: s.path, scannedAt: s.scannedAt,
                                           counts: s.counts, total: s.total,
                                           auto: auto && s.kind == "repo" && key != nil && key == projectKey)
            }
            self.model.terms = reply.terms.map { AppModel.TermItem(term: $0.term, kind: $0.kind, origins: $0.origins) }
        }
    }

    private func addSource(_ url: URL?) {
        var picked: [URL] = []
        if let url { picked = [url] } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = true
            panel.prompt = L10n.isRussian ? "Добавить" : "Add"
            panel.message = L10n.isRussian ? "Папка с документами, заметками Markdown или Obsidian"
                                           : "A folder with documents, Markdown or Obsidian notes"
            MenuBarPanel.activateApp()
            guard panel.runModal() == .OK else { return }
            picked = panel.urls
        }
        var settings = model.settings
        let known = Set(settings.extraSources.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        for url in picked {
            let path = url.standardizedFileURL.path
            if !known.contains(path), path != model.currentProject { settings.extraSources.append(path) }
        }
        guard settings != model.settings else { return }
        applySettings(settings)
    }

    private func removeSource(_ item: AppModel.SourceItem) {
        var settings = model.settings
        let key = item.path.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        switch item.kind {
        case "docs":
            settings.extraSources.removeAll { URL(fileURLWithPath: $0).standardizedFileURL.path == key }
        case "repo":
            // Автопроект не убирается — он следует за окном агента. Убираем ручную замену.
            guard let key, let manual = settings.projectPath,
                  URL(fileURLWithPath: manual).standardizedFileURL.path == key else { return }
            settings.projectPath = nil
        case "calendar":
            settings.calendarEnabled = false
        default:
            return
        }
        applySettings(settings)
    }

    /// Общий выключатель календаря. Доступ к Календарю macOS здесь не просим: источник выбирается
    /// ниже (Google, Яндекс, macOS), и доступ EventKit — только по «Календарь macOS → Выбрать…».
    private func setCalendarEnabled(_ enabled: Bool) {
        var settings = model.settings
        settings.calendarEnabled = enabled
        applySettings(settings)
    }

    /// Команда `calendar`: встречи на ±7 дней. Выключенный календарь — пустой список, чтобы движок забыл прошлый набор.
    /// «Скрыть термин» (вкладка «Словарь»): движок убирает эти термины из подсказки распознаванию.
    private func sendHiddenTerms() async {
        let terms = model.settings.hiddenTerms
        do { _ = try await engine.request("hidden_terms", fields: ["terms": .array(terms.map { .string($0) })]) } catch {
            NSLog("Mostik hidden terms: \(error.localizedDescription)")
        }
    }

    private func sendCalendar(clearIfOff: Bool = false) async {
        guard model.settings.calendarEnabled else {
            if clearIfOff { _ = try? await engine.calendar([]) }
            return
        }
        guard calendar.isReady else { return }
        let events = calendar.meetings()
        do { try await engine.calendar(events) } catch {
            NSLog("Mostik calendar: \(error.localizedDescription)")
        }
    }

    // MARK: пометки, пауза, согласие (M1, M4)

    private func addMeetingMark(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, meetingRecorder != nil, let clock = meetingClock else { return }
        model.meetingMarks.append(AppModel.MeetingMark(at: clock.elapsed(at: Date().timeIntervalSince1970), text: text))
    }

    private func toggleMeetingPause() {
        guard let rec = meetingRecorder, var clock = meetingClock else { return }
        let now = Date().timeIntervalSince1970
        if clock.isPaused { clock.resume(at: now) } else { clock.pause(at: now) }
        rec.isPaused = clock.isPaused
        meetingClock = clock
        model.meetingPaused = clock.isPaused
        model.meetingElapsed = clock.elapsed(at: now)
    }

    private func acknowledgeConsent() {
        var settings = model.settings
        settings.consentAcknowledged = true
        applySettings(settings)
        model.meetingConsentPending = false
        startMeeting(sensitive: pendingMeetingSensitive)
    }

    // MARK: история

    private func retranscribe(_ entry: HistoryEntry) {
        guard let path = entry.audioPath, FileManager.default.fileExists(atPath: path) else { return }
        let settings = model.settings
        Task {
            guard let result = try? await engine.transcribeFile(path: path, language: entry.language,
                                                                  project: self.model.currentProject,
                                                                  sources: settings.extraSources) else { return }
            var updated = entry
            updated.text = result.insertable.text
            updated.rawText = result.rawTextForHistory
            updated.doubts = result.doubts
            updated.corrections = result.corrections
            updated.verifier = result.verifier
            if updated.outcome == "failed", !updated.text.isEmpty { updated.outcome = "clipboard"; paster.write(updated.text) }
            replaceEntry(updated)
        }
    }

    private func replaceEntry(_ entry: HistoryEntry) {
        let stored = history.record(entry)  // Р5-1л
        if let i = model.history.firstIndex(where: { $0.id == entry.id }) { model.history[i] = stored }
    }

    // MARK: встречи

    private func meetingAppChanged(_ app: String?) {
        // W14: предложение — только если звонок держит микрофон 10 с; «Нет» — до конца звонка.
        meetingFolders.callAppChanged(app)
    }

    /// `continuing` — продолжить остановленную встречу в той же папке (W16);
    /// `sensitive` — «Локально» из карточки: встреча сразу «Только на этом Mac».
    private func startMeeting(continuing previous: AppModel.MeetingItem? = nil, sensitive: Bool = false) {
        guard meetingRecorder == nil else { return }
        // Перед первой записью — предупреждение о согласии участников (M4); запись начнёт onAcknowledgeConsent.
        guard model.settings.consentAcknowledged else {
            pendingMeetingSensitive = sensitive
            model.meetingConsentPending = true
            return
        }
        pendingMeetingSensitive = false
        model.meetingConsentPending = false
        let started = Date()
        let formatter = DateFormatter()
        // Имя папки — машинное: без POSIX-локали 12-часовой формат системы портит «HH».
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let folder = previous?.folder
            ?? paths.meetings.appendingPathComponent(formatter.string(from: started), isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let rec = MeetingRecorder(folder: folder)
        rec.voiceProcessing = meetingLive.voiceProcessingForMeeting()
        rec.micDeviceUID = model.settings.micDeviceUID
        let continuation = previous.map { _ in MeetingLiveController.continuation(folder) }
        let offset = continuation?.offset ?? 0
        // Волна записи встречи в меню строки меню; пока идёт диктовка, волну ведёт она.
        rec.onLevels = { [weak self] mic, system in
            MainActor.assumeIsolated { self?.pushMeetingLevel(max(mic, system)) }
        }
        do { try rec.start(continuing: continuation?.segments ?? [], offset: offset) } catch {
            model.hud = .error((L10n.isRussian ? "Встреча не записывается: " : "Meeting recording failed: ")
                               + error.localizedDescription)
            scheduleHUDHide(after: 3)
            return
        }
        // Разрешение на звук системы подтверждается первым звуком системной дорожки, а не стартом записи:
        // при отказе tap стартует и пишет тишину (`MeetingFolderController.tick`).
        meetingRecorder = rec
        meetingStartedAt = previous?.startedAt ?? started
        // Продолжение: часы встречи идут с конца прежней записи.
        meetingClock = MeetingClock(startedAt: started.timeIntervalSince1970 - offset)
        meetingEvent = previous == nil && model.settings.calendarEnabled ? calendar.current(at: started) : nil
        model.meetingMarks = []
        model.meetingPaused = false
        model.meetingSuggestion = nil
        meetingFolders.recordingStarted(folder: folder, recorder: rec, event: meetingEvent, started: started,
                                        sensitive: sensitive)
        if let continuation {
            // Начало встречи — прежнее; когда продолжили — отдельным полем.
            MeetingFolder.update(folder, ["started": continuation.started ?? NSNull(),
                                          "recording": ["started_at": continuation.started ?? NSNull(),
                                                        "continued_at": MeetingFolder.iso(started)]])
        }
        meetingLive.recordingStarted(folder: folder, recorder: rec, offset: offset)
        let observer = CallSpeakerObserver(folder: folder, myName: model.settings.myName) { [weak self] in
            guard let clock = self?.meetingClock, !clock.isPaused else { return nil }
            return clock.elapsed(at: Date().timeIntervalSince1970)
        }
        // Узнали себя на звонке, а поле «Ваше имя» пустое — вписываем; заполненное не трогаем.
        observer.onLearnedName = { [weak self] name in
            guard let self, self.model.settings.myName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            var settings = self.model.settings
            settings.myName = name
            self.applySettings(settings)
        }
        observer.start()
        speakerObserver = observer
        let eventTitle = meetingEvent?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let item = AppModel.MeetingItem(id: folder.lastPathComponent,
                                        title: eventTitle.isEmpty ? Self.meetingTitle(started) : eventTitle,
                                        startedAt: started, duration: 0, state: .recording, folder: folder)
        if let previous {
            updateMeeting(previous.id) { $0.state = .recording }
        } else {
            model.meetings.insert(item, at: 0)
        }
        model.meetingElapsed = offset
        meetingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let clock = self.meetingClock else { return }
                self.model.meetingElapsed = clock.elapsed(at: Date().timeIntervalSince1970)
            }
        }
    }

    private func stopMeeting() {
        guard let rec = meetingRecorder else { return }
        meetingRecorder = nil
        meetingTimer?.invalidate()
        meetingTimer = nil
        let tracks = rec.stop()
        let now = Date()
        let duration = meetingClock?.elapsed(at: now.timeIntervalSince1970) ?? now.timeIntervalSince(meetingStartedAt)
        let marks = model.meetingMarks.map { MeetingMarkPayload(at: $0.at, text: $0.text) }
        // До сброса часов: последний отрезок ленты закрывается концом записи.
        speakerObserver?.stop()
        speakerObserver = nil
        // Встречу начали заранее — событие могло начаться уже по ходу записи.
        let event = meetingEvent ?? (model.settings.calendarEnabled ? calendar.current(at: now) : nil)
        meetingClock = nil
        meetingEvent = nil
        model.meetingMarks = []
        model.meetingPaused = false
        guard let item = model.meetings.first(where: { $0.state == .recording }) else { return }
        meetingLive.recordingStopped(folder: item.folder, duration: duration)
        meetingFolders.recordingStopped(folder: item.folder, ended: now, duration: duration)
        updateMeeting(item.id) {
            $0.duration = duration
            $0.state = .processing(L10n.isRussian ? "В очереди" : "Queued")
            $0.progress = nil
        }
        let language = model.settings.language
        // Участники без владельца календаря: движок подставит имя, только если такой участник один (M2).
        let title = event?.title.isEmpty == false ? event?.title : nil
        let attendees = event?.others ?? []
        let command = engine.meeting(mic: tracks.mic, system: tracks.system, outDir: item.folder,
                                     language: language, speakers: nil, marks: marks, title: title, attendees: attendees)
        meetingQueue.append(MeetingJob(command: command, meeting: item.id, mic: tracks.mic, system: tracks.system,
                                       outDir: item.folder, language: language, marks: marks, title: title,
                                       attendees: attendees))
        // Движок окончательно не запустился — команда никуда не ушла, не держим «В очереди» вечно.
        if case .failed(let message) = model.engineStatus, !engine.isRunning { failMeetings(message) }
    }

    /// Движок упал посреди расшифровки: процесс новый, его очередь встреч пуста — шлём заново.
    /// Один повтор: встреча, которая сама роняет движок, не должна гонять его по кругу.
    private func resendMeetings() {
        guard !meetingQueue.isEmpty else { return }
        var kept: [MeetingJob] = []
        for var job in meetingQueue {
            guard job.attempts < 2 else {
                updateMeeting(job.meeting) { $0.state = .failed(L10n.isRussian ? "Расшифровка прервалась из-за сбоя" : "Transcription stopped after a crash") }
                continue
            }
            job.attempts += 1
            job.command = engine.meeting(mic: job.mic, system: job.system, outDir: job.outDir,
                                         language: job.language, speakers: nil, marks: job.marks,
                                         title: job.title, attendees: job.attendees, diarize: job.diarize)
            kept.append(job)
        }
        meetingQueue = kept
    }

    /// Брошенная встреча (M12): приложение упало посреди записи или до конца расшифровки — в очередь заново.
    private func enqueueMeeting(folder: URL, title: String?) {
        let id = folder.lastPathComponent
        guard !meetingQueue.contains(where: { $0.meeting == id }), meetingRecorder == nil || model.meetings.first(where: { $0.state == .recording })?.id != id else { return }
        let mic = folder.appendingPathComponent("mic.wav")
        let system = folder.appendingPathComponent("system.wav")
        let language = model.settings.language
        let command = engine.meeting(mic: mic, system: system, outDir: folder, language: language, speakers: nil,
                                     marks: [], title: title, attendees: [])
        meetingQueue.append(MeetingJob(command: command, meeting: id, mic: mic, system: system, outDir: folder,
                                       language: language, marks: [], title: title, attendees: []))
        updateMeeting(id) { $0.state = .processing(L10n.isRussian ? "Дорасшифровка" : "Resuming"); $0.progress = nil }
    }

    /// Повтор после нехватки памяти на модели голосов (R3a): та же встреча, собеседники одним голосом.
    /// Пометки и название — из упавшего задания этой сессии; после перезапуска — без них, как при дорасшифровке.
    private func retryMeetingWithoutVoices(_ id: String) { retryMeeting(id, diarize: false) }

    /// Повтор упавшей расшифровки (кнопка «Повторить расшифровку») или без голосов после нехватки памяти.
    private func retryMeeting(_ id: String, diarize: Bool) {
        guard !meetingQueue.contains(where: { $0.meeting == id }),
              let item = model.meetings.first(where: { $0.id == id }) else { return }
        let failed = failedJobs.removeValue(forKey: id)
        let mic = failed?.mic ?? item.folder.appendingPathComponent("mic.wav")
        let system = failed?.system ?? item.folder.appendingPathComponent("system.wav")
        let language = failed?.language ?? model.settings.language
        let marks = failed?.marks ?? []
        let title = failed?.title ?? item.title
        let attendees = failed?.attendees ?? []
        let command = engine.meeting(mic: mic, system: system, outDir: item.folder, language: language, speakers: nil,
                                     marks: marks, title: title, attendees: attendees, diarize: diarize)
        var job = MeetingJob(command: command, meeting: id, mic: mic, system: system, outDir: item.folder,
                             language: language, marks: marks, title: title, attendees: attendees)
        job.diarize = diarize
        meetingQueue.append(job)
        updateMeeting(id) {
            $0.state = .processing(diarize ? (L10n.isRussian ? "В очереди" : "Queued")
                                           : (L10n.isRussian ? "В очереди, без разделения по голосам" : "Queued, without splitting by voice"))
            $0.failureCode = nil
            $0.progress = nil
        }
        if case .failed(let message) = model.engineStatus, !engine.isRunning { failMeetings(message) }
    }

    private func failMeetings(_ message: String) {
        for job in meetingQueue { updateMeeting(job.meeting) { $0.state = .failed(message) } }
        meetingQueue.removeAll()
    }

    private func updateMeeting(_ id: String, _ change: (inout AppModel.MeetingItem) -> Void) {
        guard let i = model.meetings.firstIndex(where: { $0.id == id }) else { return }
        change(&model.meetings[i])
    }

    /// Удаление встречи: папка целиком в Корзину — вернуть можно оттуда; идущую запись не трогаем.
    private func deleteMeeting(_ meeting: AppModel.MeetingItem) {
        guard meeting.state != .recording else { return }
        do {
            try FileManager.default.trashItem(at: meeting.folder, resultingItemURL: nil)
            model.meetings.removeAll { $0.id == meeting.id }
            model.meetingTranscripts[meeting.id] = nil
            AppLog.shared.event("meeting", "moved to Trash")
        } catch {
            AppLog.shared.event("meeting", "delete failed: \(error.localizedDescription)")
        }
    }

    /// Список встреч с диска: папка = встреча, `transcript.md` = готово.
    /// Читается в фоне: у долгих встреч `transcript.json` весит мегабайты.
    private func loadMeetings() {
        let root = paths.meetings
        Task.detached(priority: .utility) {
            let (items, transcripts) = Self.scanMeetings(root: root)
            await MainActor.run {
                for (id, lines) in transcripts { self.model.meetingTranscripts[id] = lines }
                // Встречи, начатые за время чтения, не теряем.
                let known = Set(items.map(\.id))
                let live = self.model.meetings.filter { !known.contains($0.id) }
                self.model.meetings = (items + live).sorted { $0.startedAt > $1.startedAt }
            }
        }
    }

    nonisolated private static func scanMeetings(root: URL) -> ([AppModel.MeetingItem], [String: [AppModel.TranscriptLine]]) {
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey],
                                                         options: .skipsHiddenFiles) else { return ([], [:]) }
        var items: [AppModel.MeetingItem] = []
        var transcripts: [String: [AppModel.TranscriptLine]] = [:]
        for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let started = formatter.date(from: folder.lastPathComponent)
                ?? (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
            let mic = folder.appendingPathComponent("mic.wav")
            let transcript = folder.appendingPathComponent("transcript.md")
            let done = fm.fileExists(atPath: transcript.path)
            let lines = done ? parseTranscript(json: folder.appendingPathComponent("transcript.json")) : []
            let speakers = MeetingSpeakers.peopleCount(lines.map(\.speaker))  // перекрытия и пометки — не люди
            // Название из манифеста (M10): событие календаря или правка пользователя.
            let manifest = MeetingFolder.summary(folder)
            // Звук мог уйти в Корзину после сводки — тогда длительность из манифеста, а не «1 мин».
            let duration = WAVInfo.duration(of: mic) ?? manifest?.durationSeconds ?? 0
            // Сбой на модели голосов (R3a) переживает перезапуск: код лежит в манифесте.
            let memory = !done && manifest?.transcript == "failed" && manifest?.transcriptCode == EngineErrorText.diarizationMemory
            var item = AppModel.MeetingItem(
                id: folder.lastPathComponent, title: manifest?.title ?? meetingTitle(started), startedAt: started, duration: duration,
                state: done ? .done : .failed(memory ? EngineErrorText.short(code: EngineErrorText.diarizationMemory, message: "")
                                                     : (L10n.isRussian ? "Не расшифрована" : "Not transcribed")),
                folder: folder, transcriptPath: done ? transcript : nil, speakers: speakers)
            if memory { item.failureCode = EngineErrorText.diarizationMemory }
            item.diarizationUnavailable = done && manifest?.diarizationUnavailable == true
            item.diarizationFailed = done && manifest?.diarizationFailed == true
            items.append(item)
            if done { transcripts[folder.lastPathComponent] = lines }
        }
        return (items, transcripts)
    }

    nonisolated private static func meetingTitle(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.dateFormat = L10n.isRussian ? "d MMMM, HH:mm" : "MMM d, HH:mm"
        return (L10n.isRussian ? "Встреча · " : "Meeting · ") + f.string(from: date)
    }

    /// `transcript.json` движка: `{segments: [...]}` или массив; поля speaker/start/text.
    nonisolated static func parseTranscript(json url: URL) -> [AppModel.TranscriptLine] {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let segments: [[String: Any]]
        var rawMarks: [[String: Any]] = []
        if let dict = value as? [String: Any] {
            // Движок пишет реплики в `turns` (meeting.py); `segments`/`lines` — старые варианты.
            segments = (dict["turns"] as? [[String: Any]]) ?? (dict["segments"] as? [[String: Any]])
                ?? (dict["lines"] as? [[String: Any]]) ?? []
            rawMarks = dict["marks"] as? [[String: Any]] ?? []
        } else {
            segments = value as? [[String: Any]] ?? []
        }
        func seconds(_ value: Any?) -> Double { (value as? Double) ?? (value as? NSNumber)?.doubleValue ?? 0 }
        var lines: [(speaker: String, start: Double, text: String)] = segments.compactMap { seg in
            guard let text = seg["text"] as? String else { return nil }
            return (seg["speaker"] as? String ?? "", seconds(seg["start"]), text)
        }
        // Пометки (M1) — строкой «📌» перед первой репликой, которая начинается не раньше пометки.
        let marks = rawMarks.compactMap { m -> (Double, String)? in
            guard let text = m["text"] as? String, !text.isEmpty else { return nil }
            return (seconds(m["at"]), text)
        }.sorted { $0.0 < $1.0 }
        for (at, text) in marks {
            let index = lines.firstIndex { $0.speaker != "📌" && $0.start >= at } ?? lines.count
            lines.insert(("📌", at, text), at: index)
        }
        return lines.enumerated().map { index, line in
            AppModel.TranscriptLine(id: index, speaker: line.speaker, start: line.start, text: line.text)
        }
    }

    // MARK: доставка (R1–R5, H2, H3, A7)

    private func wireDelivery() {
        delivery.escapeToMachine = { [unowned self] in
            switch self.machine.state {
            case .transcribing, .inserting:
                self.apply(self.machine.handle(.abort))
                return true
            case .failed:
                self.apply(self.machine.handle(.abort))
                if case .error = self.model.hud { self.model.hud = .hidden }
                return true
            case .idle where !self.deliveringIDs.isEmpty:
                // ⌘V ушёл, проверка ещё идёт (шаг 1, п. 3): Esc откатит вставку, как раньше.
                self.abortedInserts.formUnion(self.deliveringIDs)
                return true
            default:
                return false
            }
        }
        delivery.isBusy = { [unowned self] in self.machine.currentSession != nil || self.voiceEdit.isActive }
        delivery.replaceEntry = { [unowned self] entry in self.replaceEntry(entry) }
    }

    // MARK: «Записать голос» из меню строки меню

    /// Кто впереди, кроме нас: меню `.window` делает Mostik активным, поэтому запоминаем заранее.
    private func trackFrontApp() {
        frontMemory.activated(FocusReturn.frontmost())
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.frontMemory.activated(app.map(FocusReturn.ref)) }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { if let pid { self?.frontMemory.terminated(pid: pid) } }
        }
    }

    /// Пункт «Записать голос» / «Остановить запись»: закрыть меню, вернуть фокус приложению, где стоял
    /// курсор, и только потом нажать «переключатель» — как второе нажатие двойного (D1).
    private func menuVoice() {
        MenuBarPanel.dismiss()
        if voiceEdit.isActive { return }
        let inputs = MenuVoice.inputs(machine.state, at: ProcessInfo.processInfo.systemUptime)
        guard !inputs.isEmpty || menuVoiceDryRun != nil else { return }
        let starting = MenuVoice.phase(machine.state) == .idle
        // Стоп: вставлять туда же, куда собирались при старте; запись с клавиши — в последнее приложение.
        let target = (!starting ? session?.menuTarget : nil)
            ?? MenuVoice.target(remembered: frontMemory.last, isRunning: FocusReturn.isRunning)
        let element: AXUIElement? = if case .app(let app) = target { FocusReturn.focusedElement(pid: app.pid) } else { nil }
        // В журнал — без имени приложения (П10: в app.log нет того, что пользователь делал и где).
        AppLog.shared.event("menu", "voice \(starting ? "start" : "stop"), target: \(target == .clipboard(.noApp) ? "none" : "previous app")")
        Task { [weak self] in
            if case .app(let app) = target { await FocusReturn.activate(app, element: element) }
            guard let self else { return }
            if let dry = self.menuVoiceDryRun { dry(target); return }
            // Пока возвращали фокус, состояние могло смениться (клавиша, Esc): решаем заново.
            let now = MenuVoice.inputs(self.machine.state, at: ProcessInfo.processInfo.systemUptime)
            guard MenuVoice.phase(self.machine.state) == (starting ? .idle : .recording), !now.isEmpty else { return }
            if starting { self.pendingMenuTarget = target }
            for input in now { self.apply(self.machine.handle(input)) }
            // Микрофон не дал записать — цель не пригодится; повтор `beginRecording` (R7) её ещё заберёт.
            if starting, MenuVoice.phase(self.machine.state) != .recording { self.pendingMenuTarget = nil }
        }
    }

    // MARK: намерения интерфейса

    private func wireIntents() {
        model.onStartMeeting = { [weak self] in
            MenuBarPanel.dismiss()
            self?.startMeeting()
        }
        model.onStopMeeting = { [weak self] in MenuBarPanel.dismiss(); self?.stopMeeting() }
        model.onRetranscribe = { [weak self] entry in MenuBarPanel.dismiss(); self?.retranscribe(entry) }
        model.onDeleteEntry = { [weak self] entry in self?.deleteEntry(entry) }
        model.onCopy = { [weak self] text in self?.paster.write(text) }
        model.onInsertFast = { [weak self] in
            guard let self, let id = self.session?.id, self.model.hud == .transcribing else { return }
            self.engine.skipVerifier(session: id)
        }
        // Слово под вопросом (C3–C5): принятая подсказка правит текст записи и идёт в словарь,
        // отказ снимает отметку и больше не предлагается.
        model.onAcceptDoubt = { [weak self] entryID, heard, canonical in
            guard let self, let entry = self.model.history.first(where: { $0.id == entryID }) else { return }
            self.replaceEntry(DoubtResolution.accept(entry, heard: heard, canonical: canonical))
            let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
            let canonical = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !canonical.isEmpty else { return }
            Task {
                try? await self.engine.remember(heard: heard, canonical: canonical,
                                                language: entry.language)
                await self.reloadGlossary()
            }
        }
        model.onRejectDoubt = { [weak self] entryID, doubt in
            guard let self, let entry = self.model.history.first(where: { $0.id == entryID }) else { return }
            self.replaceEntry(DoubtResolution.reject(entry, doubt: doubt))
            Task { try? await self.engine.rejectDoubt(heard: doubt.heard, suggestion: doubt.suggestion) }
        }
        model.onRemember = { [weak self] heard, canonical in
            guard let self else { return }
            Task {
                try? await self.engine.remember(heard: heard, canonical: canonical)
                await self.reloadGlossary()
            }
        }
        model.onForget = { [weak self] item in
            guard let self else { return }
            Task {
                try? await self.engine.forget(canonical: item.canonical)
                await self.reloadGlossary()
            }
        }
        model.onChooseProject = { [weak self] url in self?.chooseProject(url) }
        model.onUpdateSettings = { [weak self] settings in self?.applySettings(settings) }
        model.onRequestPermission = { [weak self] kind in
            switch kind {
            case .microphone:
                Permissions.requestMicrophone { _ in
                    DispatchQueue.main.async { self?.refreshPermissions(); self?.updateWarm() }
                }
            case .accessibility:
                Permissions.requestAccessibility()
            case .screenRecording:
                Permissions.requestSystemAudio()
            case .screenCapture:
                Permissions.openScreenCapture()
            }
        }
        model.onOpenTranscript = { item in
            NSWorkspace.shared.open(item.transcriptPath ?? item.folder)
        }
        model.onRevealInFinder = { url in NSWorkspace.shared.activateFileViewerSelecting([url]) }
        model.onDeleteMeeting = { [weak self] meeting in self?.deleteMeeting(meeting) }
        model.onQuit = { NSApp.terminate(nil) }
        model.onCheckForUpdates = { [weak self] in self?.updater?.checkForUpdates() }
        model.onOpenMainWindow = { [weak self] in
            self?.refreshPermissions()
            self?.windows.showMain()
        }
        // Настройки — вкладка главного окна (B1): `openSettings` уже выбрал её, осталось показать окно.
        model.onOpenSettings = { [weak self] in
            self?.refreshPermissions()
            self?.refreshInputDevices()
            self?.windows.showMain()
        }
        model.onSettingsShown = { [weak self] in
            self?.refreshPermissions()
            self?.refreshInputDevices()
        }
        model.onRetryMeetingWithoutVoices = { [weak self] id in self?.retryMeetingWithoutVoices(id) }
        model.onRetryMeeting = { [weak self] id in self?.retryMeeting(id, diarize: true) }
        model.onDismissMeetingSuggestion = { [weak self] in
            self?.dismissedMeetingApp = self?.model.meetingSuggestion
            self?.model.meetingSuggestion = nil
            self?.meetingFolders.dismissCall()
        }
        model.onChooseEnginePython = { [weak self] in self?.chooseEnginePython() }
        model.onChooseCalendarCommand = { [weak self] in self?.externalCalendar.choose() }
        model.onClearCalendarCommand = { [weak self] in self?.externalCalendar.clear() }
        model.onRefreshCalendarCommand = { [weak self] in self?.externalCalendar.refresh() }
        model.onRescanSources = { [weak self] in self?.refreshSources(rescan: true) }
        model.onAddSource = { [weak self] url in self?.addSource(url) }
        model.onRemoveSource = { [weak self] item in self?.removeSource(item) }
        model.onSetCalendarEnabled = { [weak self] enabled in self?.setCalendarEnabled(enabled) }
        model.onAddMeetingMark = { [weak self] text in self?.addMeetingMark(text) }
        model.onToggleMeetingPause = { [weak self] in self?.toggleMeetingPause() }
        model.onToggleDictationPause = { [weak self] in self?.toggleDictationPause() }
        model.onAcknowledgeConsent = { [weak self] in MenuBarPanel.dismiss(); self?.acknowledgeConsent() }
        model.onMenuVoice = { [weak self] in self?.menuVoice() }
    }
}
