import AppKit
import Foundation
import MostikCore
import MostikKit
import MostikUI

/// Всё вокруг диктовки, что не сама диктовка: триггеры мыши и гарнитуры (H5),
/// приглушение звука (H6), прогрев модели (R6), «Проверка» и правила повторов (R7).
/// `AppController` зовёт отсюда несколько методов в нужных местах.
@MainActor
final class UpkeepController {
    private let model: AppModel
    private let paths: MostikPaths
    private let engine: () -> EngineClient
    /// Идёт диктовка, правка или расшифровка встречи — прогрев не нужен.
    private let isBusy: () -> Bool
    private let restartEngine: () -> Void
    private let relaunch: () -> Void
    private let requestPermission: (AppModel.PermissionKind) -> Void

    private var triggers: ExtraTriggerMonitor!
    private let muter = OutputMuter()
    private var wake: WakeMonitor!
    private var warm = WarmupPolicy()
    private var warmTask: Task<Void, Never>?
    private var engineRetryTask: Task<Void, Never>?
    /// Отказ в микрофоне и временные сбои (R7).
    var gate = FailureGate()
    /// Чего нет в кэше моделей по `hello`; nil — движок ещё не ответил.
    var missingModels: [String]?
    /// Разделит ли движок встречу по голосам (`hello.diarization`); nil — движок ещё не ответил.
    var diarizationAvailable: Bool?
    /// Падений движка за сеанс — считает `AppController`, показывает «Проверка».
    var engineCrashes = 0
    /// Журнал и отчёты о сбоях (П8, пункт 6).
    var logPaths = MostikLogPaths.standard
    /// Автозапуск при входе после последней синхронизации; ошибку регистрации показывает «Проверка».
    private var loginItem: LoginItemFacts?

    init(model: AppModel, paths: MostikPaths, engine: @escaping () -> EngineClient, isBusy: @escaping () -> Bool,
         hotkey: @escaping (HotkeyMonitor.Event) -> Void, restartEngine: @escaping () -> Void,
         relaunch: @escaping () -> Void, requestPermission: @escaping (AppModel.PermissionKind) -> Void) {
        self.model = model
        self.paths = paths
        self.engine = engine
        self.isBusy = isBusy
        self.restartEngine = restartEngine
        self.relaunch = relaunch
        self.requestPermission = requestPermission
        triggers = ExtraTriggerMonitor { event in
            switch event {
            case .holdBegan: hotkey(.holdBegan)
            case .holdEnded: hotkey(.holdEnded)
            case .togglePressed: hotkey(.togglePressed)
            }
        }
        wake = WakeMonitor { [weak self] reason in self?.woke(reason) }
        model.doctor.onRun = { [weak self] in self?.runDoctor() }
        model.doctor.onFix = { [weak self] fix in self?.fix(fix) }
        model.doctor.onRevealLogs = {
            NSWorkspace.shared.activateFileViewerSelecting([MostikLogPaths.standard.root])
        }
    }

    func start() {
        // Прошлый запуск упал посреди диктовки с приглушённым звуком — возвращаем.
        muter.restoreLeftover()
        settingsChanged()
        wake.start()
    }

    func stop() {
        triggers.stop()
        wake.stop()
        warmTask?.cancel()
        engineRetryTask?.cancel()
        muter.restore()
    }

    func settingsChanged() {
        let s = model.settings
        triggers.configure(mouse: s.mouseTrigger, headset: s.headsetTrigger)
        if !s.muteWhileRecording { muter.restore() }
        syncLoginItem()
    }

    /// Объект входа — по настройке; зовётся при запуске и при каждой правке настроек, без изменений ничего не делает.
    private func syncLoginItem() {
        let wanted = LaunchAtLogin.wanted(model.settings)
        let facts = LoginItem.sync(wanted: wanted)
        if loginItem != facts, let error = facts.error { NSLog("Mostik login item: \(error)") }
        loginItem = facts
    }

    /// Доступ выдали на ходу — перехват мыши и гарнитуры ставим заново.
    func accessibilityGranted() {
        triggers.stop()
        settingsChanged()
    }

    // MARK: H6 — приглушение

    func recordingStarted() {
        if model.settings.muteWhileRecording { muter.mute() }
    }

    func recordingStopped() { muter.restore() }

    // MARK: R6 — прогрев

    /// Рукопожатие с движком прогрело модель.
    func warmed() {
        warm.warmed(at: ProcessInfo.processInfo.systemUptime)
        engineRetryTask?.cancel()
        gate.succeeded("engine")
    }

    private func woke(_ reason: WakeMonitor.Reason) {
        scheduleWarmup(afterSleep: reason == .wake)
    }

    private func scheduleWarmup(afterSleep: Bool) {
        warmTask?.cancel()
        let delay = warm.delay(afterSleep: afterSleep)
        warmTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            guard self.model.engineStatus == .ready,
                  self.warm.shouldWarm(at: ProcessInfo.processInfo.systemUptime, busy: self.isBusy(),
                                       afterSleep: afterSleep) else { return }
            _ = try? await self.engine().warmup(language: self.model.settings.language,
                                                 polishBackend: WarmupPolicy.polishBackendToWarm(self.model.settings))
        }
    }

    // MARK: R7 — повторы

    /// Микрофон запрещён: сообщаем один раз (и напоминаем не чаще раза в 10 минут).
    func shouldReportMicrophoneDenied() -> Bool {
        gate.permanent("microphone", at: ProcessInfo.processInfo.systemUptime) == .report
    }

    func microphoneGranted() { gate.succeeded("microphone") }

    /// Движок упал окончательно: перезапуск с паузами 2, 5, 15 с, потом — красная строка в «Проверке».
    /// Пока ждём повтора, строка статуса говорит, через сколько и какая попытка.
    func engineFailed() {
        guard engineRetryTask == nil else { return }
        var engineGate = gate
        engineGate.delays = EngineRecovery.retryDelays
        let decision = engineGate.transient("engine")
        gate = engineGate
        let why: String
        if case .failed(let message) = model.engineStatus { why = message } else { why = "" }
        guard case .retry(let after) = decision else {
            if decision == .giveUp {
                AppLog.shared.error("engine", "gave up after \(EngineRecovery.retryDelays.count) retries")
                model.engineStatus = .failed(EngineRecovery.gaveUp(why, crashes: engineCrashes,
                                                                   logPath: logPaths.engine.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                                                                   russian: L10n.isRussian))
            }
            return
        }
        let attempt = (EngineRecovery.retryDelays.firstIndex(of: after) ?? 0) + 1
        AppLog.shared.event("engine", "retry \(attempt) in \(after)s")
        model.engineStatus = .failed(EngineRecovery.retrying(why, after: after, attempt: attempt, russian: L10n.isRussian))
        engineRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.engineRetryTask = nil
            if case .failed = self.model.engineStatus { self.restartEngine() }
        }
    }

    // MARK: R7 — «Проверка»

    func runDoctor() {
        let doctor = model.doctor
        doctor.running = true
        var facts = DoctorProbe.facts(holdKey: model.settings.holdKey, dataDir: paths.root)
        switch model.engineStatus {
        case .starting: facts.engine = .starting
        case .loading: facts.engine = .loading
        case .ready: facts.engine = .ready
        case .failed(let why): facts.engine = .failed(why)
        }
        // Обязательное для языка диктовки — из того же списка, что «Нужны модели»; рукопожатие считает
        // и необязательные (Parakeet), и строка горела красным у всех, кто их не качал.
        facts.missingModels = model.models.known ? model.models.missing.map(\.label) : missingModels
        facts.diarizationAvailable = diarizationAvailable
        if let row = model.models.rows.first(where: { $0.purpose == "diarization" }), !row.installed {
            facts.diarizationDownloadBytes = max(row.missingBytes, 0)
        }
        let backend = model.settings.polish.effectiveBackend
        facts.llmBackend = backend.rawValue
        facts.llmAvailable = model.polishAvailable[backend.rawValue]
        facts.engineCrashes = engineCrashes
        let reports = (try? FileManager.default.contentsOfDirectory(atPath: logPaths.crashes.path)) ?? []
        facts.crashReports = CrashReportPolicy.recent(reports, since: Date().addingTimeInterval(-7 * 86_400)).count
        // Состояние читается заново: человек мог выключить Mostik в Объектах входа; ошибка — последней синхронизации.
        let wanted = LaunchAtLogin.wanted(model.settings)
        facts.loginItem = LoginItemFacts(wanted: wanted, state: LoginItem.state,
                                         error: loginItem?.wanted == wanted ? loginItem?.error : nil)
        doctor.checks = Doctor.evaluate(facts, russian: L10n.isRussian)
        doctor.checkedAt = Date()
        doctor.running = false
    }

    private func fix(_ fix: DoctorCheck.Fix) {
        switch fix {
        case .requestMicrophone, .openMicrophone: requestPermission(.microphone)
        case .requestAccessibility: requestPermission(.accessibility)
        case .openSystemAudio: requestPermission(.screenRecording)
        case .relaunch: relaunch()
        case .openKeyboard: DoctorProbe.openKeyboardSettings()
        case .openStorage: DoctorProbe.openStorageSettings()
        case .openLoginItems: LoginItem.openSettings()
        case .restartEngine:
            gate.succeeded("engine")
            restartEngine()
        case .openPolish:
            model.openSettings(.chooseModel)
        case .downloadModels:
            model.models.start(model.models.missing.map(\.key))
        case .downloadDiarization:
            model.models.start(model.models.rows.filter { $0.purpose == "diarization" && !$0.installed }.map(\.key))
        case .showLogs:
            // Есть отчёты о сбое — открываем их папку, иначе папку журнала.
            let fm = FileManager.default
            try? fm.createDirectory(at: logPaths.crashes, withIntermediateDirectories: true)
            let reports = ((try? fm.contentsOfDirectory(atPath: logPaths.crashes.path)) ?? []).filter { $0.hasSuffix(".txt") }.sorted()
            if let last = reports.last {
                NSWorkspace.shared.activateFileViewerSelecting([logPaths.crashes.appendingPathComponent(last)])
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([fm.fileExists(atPath: logPaths.app.path) ? logPaths.app : logPaths.root])
            }
            return
        }
        // Результат «Исправить» виден не сразу (диалог, перезапуск) — перепроверяем с запасом.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.runDoctor()
        }
    }
}
