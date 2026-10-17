import AppKit
import Combine
import Darwin
import Foundation
import MostikCore
import MostikKit
import MostikUI
import SwiftUI

/// Папка встречи и всё, что вокруг неё (M10–M13, W2, W9, W11, W13, W14). Решения — в MostikCore
/// (`MeetingFolder`, `MeetingWatchdog`, `MeetingHook`, …), здесь только платформа: файлы, процессы, таймеры.
@MainActor
final class MeetingFolderController {
    private let model: AppModel
    private let paths: MostikPaths
    private let engine: () -> EngineClient
    private var extras: MeetingExtrasModel { model.meetingExtras }

    /// Перечитать список встреч с диска (`AppController.loadMeetings`).
    var reloadMeetings: () -> Void = {}
    /// Начать и остановить запись (`AppController.startMeeting` / `stopMeeting`).
    var startMeeting: (_ sensitive: Bool) -> Void = { _ in }
    var stopMeeting: () -> Void = {}
    /// Пометка M1 в текущую секунду записи.
    var addMark: (String) -> Void = { _ in }
    /// Секунды записи без пауз и пауза сейчас — часы встречи живут в `AppController`.
    var recordingClock: () -> (elapsed: Double, paused: Bool) = { (0, false) }
    /// Поставить брошенную встречу в очередь расшифровки (M12).
    var enqueue: (_ folder: URL, _ title: String?) -> Void = { _, _ in }

    // Запись.
    private var recorder: MeetingRecorder?
    private var folder: URL?
    private var watchdog: MeetingWatchdog?
    private var autoStop = MeetingAutoStop()
    private var eventEnd: Date?
    private var tickTimer: Timer?
    // Предложение записать (W14).
    private var call = CallSuggestion()
    private var callTimer: Timer?
    // Календарь (M13, W2).
    private let calendar = CalendarSource.shared
    private var calendarTimer: Timer?
    private var remindersShown: Set<String> = []
    // Встречи, по которым уже прочитаны манифест и метрики.
    private var known: [String: AppModel.MeetingState] = [:]
    private var recovered = false
    private var panel: NSPanel?
    private var cancellables: Set<AnyCancellable> = []

    /// Отпечаток команды хука (П10 С3): связка ключей, служба `app.mostik.mac.hooks`.
    let hookStore: HookDigestStore
    /// Дописать отложенное сохранение Настроек и отпечаток команды хука до проверки доверия.
    var flushSettings: () -> Void = {}
    /// Узнали что-то о разрешении на звук системы — обновить «Доступ» и «Проверку».
    var permissionsChanged: () -> Void = {}

    init(model: AppModel, paths: MostikPaths, engine: @escaping () -> EngineClient, hookStore: HookDigestStore) {
        self.model = model
        self.paths = paths
        self.engine = engine
        self.hookStore = hookStore
        extras.prep = Self.loadPrep(prepURL)
        wireIntents()
        model.$meetings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] meetings in self?.meetingsChanged(meetings) }
            .store(in: &cancellables)
        extras.$prompt
            .receive(on: DispatchQueue.main)
            .sink { [weak self] prompt in self?.showPanel(prompt != nil) }
            .store(in: &cancellables)
        calendarTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.calendarTick() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated { self?.calendarTick() }
        }
    }

    private var prepURL: URL { paths.root.appendingPathComponent("meeting-prep.json") }
    /// П10 р5 Р5-3л: журнал хука — в `~/Library/Logs/Mostik/` с ротацией (`MeetingHookLog`).
    private var hookLog: URL { MostikLogPaths.standard.meetingHooks }

    private func appendHookLog(_ entry: String) {
        MeetingHookLog.append(entry, to: hookLog, legacy: paths.legacyLogs.appendingPathComponent("meeting-hooks.log"))
    }
    private var language: String { L10n.isRussian ? "ru" : "en" }

    private func wireIntents() {
        extras.onRecordNow = { [weak self] in
            self?.extras.prompt = nil
            self?.startMeeting(false)
        }
        extras.onRecordLocal = { [weak self] in
            self?.extras.prompt = nil
            self?.startMeeting(true)
        }
        extras.onDismissPrompt = { [weak self] in self?.dismissPrompt() }
        extras.onOpenSystemAudio = { Permissions.requestSystemAudio() }
        extras.onCancelAutoStop = { [weak self] in
            self?.autoStop.cancel()
            self?.extras.prompt = nil
        }
        // Тот же путь, что автоостановка по истечении отсчёта и «Завершить» в меню: `AppController.stopMeeting`.
        extras.onFinishNow = { [weak self] in
            self?.extras.prompt = nil
            self?.stopMeeting()
        }
        extras.onJoin = { link in
            guard let url = URL(string: link), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
            NSWorkspace.shared.open(url)
        }
        extras.onUseAgendaItem = { [weak self] item in
            self?.addMark(item)
            self?.extras.agendaUsed.insert(item)
        }
        extras.onSetPrep = { [weak self] id, text in self?.setPrep(id, text) }
        extras.onSetSensitive = { [weak self] id, value in self?.setSensitive(id, value) }
        extras.onExportClip = { [weak self] id, lines in self?.exportClip(id, lines) }
        extras.onRevealClip = { url in NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    // MARK: M10 — миграция старых встреч, M12 — восстановление

    /// На каждом запуске движка: старые папки получают манифест и `meeting.md`, затем список перечитывается.
    /// Первый раз за запуск приложения — ещё и дорасшифровка брошенных встреч (M12).
    func migrate() async {
        do {
            let reply = try await engine().meetingsMigrate(root: paths.meetings)
            if (reply["migrated"]?.doubleValue ?? 0) > 0 { reloadMeetings() }
        } catch {
            NSLog("Mostik meetings_migrate: \(error.localizedDescription)")
        }
        if !recovered {
            recovered = true
            await recover()
        }
    }

    /// Встречи, которые приложение бросило (упало посреди записи или до конца расшифровки), — в очередь.
    private func recover() async {
        let root = paths.meetings
        let current = folder?.lastPathComponent
        let plans = await Task.detached(priority: .utility) { () -> [(URL, MeetingRecovery.Decision, String?)] in
            let fm = FileManager.default
            let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            return folders.compactMap { folder in
                let summary = MeetingFolder.summary(folder)
                let hasAudio = MeetingFolder.audioFiles(folder).contains { name in
                    let size = (try? fm.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.size] as? Int) ?? 0
                    return size > 44
                }
                let hasTranscript = fm.fileExists(atPath: folder.appendingPathComponent("transcript.json").path)
                let decision = MeetingRecovery.decide(summary: summary, hasAudio: hasAudio, hasTranscript: hasTranscript,
                                                      isRecordingNow: folder.lastPathComponent == current)
                return decision == .none ? nil : (folder, decision, summary?.title)
            }
        }.value
        for (folder, decision, title) in plans {
            switch decision {
            case .none:
                break
            case let .transcribe(markIncomplete):
                if markIncomplete { MeetingFolder.update(folder, ["recording": ["status": "incomplete"]]) }
                extras.recordingStatus[folder.lastPathComponent] = markIncomplete ? "incomplete" : nil
                enqueue(folder, title)
            case let .giveUp(markIncomplete):
                var patch: [String: Any] = [:]
                if markIncomplete { patch["recording"] = ["status": "incomplete"] }
                let transcript = MeetingFolder.summary(folder)?.transcript
                if transcript != "done" {
                    patch["transcript"] = ["status": "failed", "error": L("Не удалось дорасшифровать после сбоя",
                                                                         "Could not finish transcribing after a crash")]
                }
                if !patch.isEmpty { MeetingFolder.update(folder, patch) }
                if markIncomplete { extras.recordingStatus[folder.lastPathComponent] = "incomplete" }
            }
        }
        // П10 С7: «только текст» — звук стирается и после окончательного сбоя расшифровки (giveUp),
        // и у встреч, где до этого не дошло (упали между расшифровкой и обнулением). Те, что
        // поставлены в очередь, обнулятся после расшифровки — звук ей ещё нужен.
        let queued = Set(plans.compactMap { plan -> String? in
            if case .transcribe = plan.1 { return plan.0.lastPathComponent } else { return nil }
        })
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            for folder in folders where folder.lastPathComponent != current && !queued.contains(folder.lastPathComponent) {
                if TextOnlyAudio.needsPurge(MeetingFolder.readManifest(folder)) { TextOnlyAudio.purge(folder) }
            }
        }.value
    }

    // MARK: запись (M12, M13, W2)

    /// `sensitive` — запись начата кнопкой «Локально»: флаг уходит в манифест первой же записью,
    /// до кадров, хуков и расшифровки. Ложь флаг не снимает (продолжение помеченной встречи).
    func recordingStarted(folder: URL, recorder: MeetingRecorder, event: CalendarEvent?, started: Date,
                          sensitive: Bool = false) {
        self.recorder = recorder
        self.folder = folder
        watchdog = MeetingWatchdog(startedAt: started.timeIntervalSince1970)
        autoStop = MeetingAutoStop()
        eventEnd = event?.end
        let upcoming = event.map(UpcomingMeeting.init(event:))
        extras.agenda = upcoming?.agenda ?? []
        extras.agendaUsed = []
        if case .autoStop? = extras.prompt {} else { extras.prompt = nil }
        model.meetingSuggestion = nil
        if let event { remindersShown.insert(event.id) }

        var patch: [String: Any] = [
            "started": MeetingFolder.iso(started),
            "recording": ["status": "recording", "started_at": MeetingFolder.iso(started),
                          "segments": recorder.segments.map(\.manifestValue)],
        ]
        if let app = call.app { patch["app"] = app }
        if sensitive {
            patch["sensitive"] = true
            extras.sensitive.insert(folder.lastPathComponent)
        }
        if let event {
            if !event.title.isEmpty { patch["title"] = event.title; patch["title_source"] = "calendar" }
            var calendar: [String: Any] = ["event_id": event.id, "title": event.title,
                                           "start": MeetingFolder.iso(event.start), "end": MeetingFolder.iso(event.end)]
            if let link = event.link { calendar["link"] = link }
            patch["calendar"] = calendar
            if !event.others.isEmpty { patch["attendees"] = event.others.map { ["name": $0, "self": false] } }
            if let upcoming, !upcoming.agenda.isEmpty { patch["agenda"] = upcoming.agenda }
            extras.links[folder.lastPathComponent] = event.link
        }
        MeetingFolder.update(folder, patch)
        // W2: заметка до встречи и повестка — в `notes.md` до первого слова.
        let prep = event.flatMap { extras.prep[$0.id] } ?? ""
        let title = event?.title.isEmpty == false ? event!.title : L("Встреча", "Meeting")
        Self.writeNotesIfEmpty(folder.appendingPathComponent("notes.md"),
                               MeetingNotes.render(title: title, agenda: upcoming?.agenda ?? [], prep: prep, language: language))
        if let event, extras.prep[event.id] != nil { setPrep(event.id, "") }

        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Раз в секунду: сторож дорожек и автоостановка.
    private func tick() {
        guard let recorder, let folder, var watchdog else { return }
        let now = Date().timeIntervalSince1970
        let polled = recorder.poll()
        let heardBefore = watchdog.systemHeard
        for (track, at) in polled.lastBuffer { watchdog.buffer(track, at: at, level: polled.peaks[track] ?? 0) }
        if watchdog.systemHeard, !heardBefore {
            // Собеседников слышно — разрешение на звук системы точно есть.
            Permissions.systemAudioGranted = true
            Permissions.systemAudioSilent = false
            if case .systemAudioMissing? = extras.prompt { extras.prompt = nil }
            permissionsChanged()
        }
        let clock = recordingClock()
        // Звука системы ждём, пока он ни разу не подтверждался, и на любом звонке.
        let actions = watchdog.tick(at: now, paused: clock.paused,
                                    systemExpected: !Permissions.systemAudioGranted || call.app != nil)
        for action in actions {
            switch action {
            case let .restart(track, attempt):
                do {
                    try recorder.restart(track, offset: clock.elapsed)
                    NSLog("Mostik meeting: \(track.rawValue) restarted (\(attempt))")
                } catch {
                    NSLog("Mostik meeting: \(track.rawValue) restart failed: \(error.localizedDescription)")
                }
                watchdog.restarted(track, at: now)
                var recording = watchdog.manifestRestarts
                recording["segments"] = recorder.segments.map(\.manifestValue)
                MeetingFolder.update(folder, ["recording": recording])
            case let .giveUp(track):
                MeetingFolder.update(folder, ["recording": ["gave_up": watchdog.gaveUp.map(\.rawValue).sorted()]])
                warn(L("Дорожка «\(Self.trackName(track))» не пишется", "The \(Self.trackName(track)) track is not recording"),
                     L("Mostik перезапускал её трижды — не помогло. Остальное записывается; встреча будет помечена неполной.",
                       "Restarted it three times without luck. The rest keeps recording; the meeting will be marked incomplete."))
            case .warnSystemSilent:
                MeetingFolder.update(folder, ["recording": ["warnings": ["system_silent"]]])
                Permissions.systemAudioSilent = true
                permissionsChanged()
                if case .autoStop? = extras.prompt { break }
                extras.prompt = .systemAudioMissing
            case .warnNoAudio:
                MeetingFolder.update(folder, ["recording": ["warnings": ["no_audio"]]])
                warn(L("Не слышно звука", "No sound"),
                     L("За 10 секунд ни микрофон, ни звук звонка ничего не уловили. Проверьте устройство ввода и громкость.",
                       "Neither the microphone nor the call audio picked anything up in 10 seconds. Check the input device and volume."))
            }
        }
        self.watchdog = watchdog
        guard model.settings.meetingAutoStop else { return }
        switch autoStop.update(now: now, eventEnd: eventEnd?.timeIntervalSince1970, callActive: call.app != nil) {
        case .none: break
        case let .started(deadline): extras.prompt = .autoStop(deadline: Date(timeIntervalSince1970: deadline))
        case .stop:
            extras.prompt = nil
            stopMeeting()
        }
    }

    private func warn(_ title: String, _ detail: String) {
        if case .autoStop? = extras.prompt { return }
        extras.prompt = .warning(title: title, detail: detail)
    }

    private static func trackName(_ track: MeetingWatchdog.Track) -> String {
        switch track {
        case .mic: return L("микрофон", "microphone")
        case .system: return L("звук звонка", "call audio")
        }
    }

    /// Запись остановлена: итог сторожа, конец и длительность — в манифест до команды движку.
    func recordingStopped(folder: URL, ended: Date, duration: Double) {
        tickTimer?.invalidate()
        tickTimer = nil
        let status = watchdog?.status ?? "complete"
        var recording: [String: Any] = ["status": status, "ended_at": MeetingFolder.iso(ended)]
        if let recorder { recording["segments"] = recorder.segments.map(\.manifestValue) }
        MeetingFolder.update(folder, ["recording": recording, "ended": MeetingFolder.iso(ended),
                                      "duration_seconds": (duration * 10).rounded() / 10,
                                      "transcript": ["status": "pending"]])
        if status != "complete" { extras.recordingStatus[folder.lastPathComponent] = status }
        recorder = nil
        self.folder = nil
        watchdog = nil
        eventEnd = nil
        extras.agenda = []
        extras.agendaUsed = []
        switch extras.prompt {
        case .autoStop?, .warning?: extras.prompt = nil
        default: break
        }
    }

    // MARK: W14 — предложение записать

    /// Детектор звонка: приложение начало или перестало держать микрофон.
    func callAppChanged(_ app: String?) {
        call.appChanged(app, at: Date().timeIntervalSince1970)
        callTimer?.invalidate()
        callTimer = nil
        if app == nil || model.meetingSuggestion != app {
            model.meetingSuggestion = nil
            if case .callSuggestion? = extras.prompt { extras.prompt = nil }
        }
        guard app != nil else { return }
        callTimer = Timer.scheduledTimer(withTimeInterval: CallSuggestion.delay + 0.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluateCall() }
        }
    }

    private func evaluateCall() {
        // Автостарта нет (решение автора): звонок только предлагают записать, начинает человек.
        guard let app = call.suggestion(at: Date().timeIntervalSince1970, recording: recorder != nil,
                                        enabled: model.settings.meetingSuggest) else { return }
        model.meetingSuggestion = app
        if extras.prompt == nil { extras.prompt = .callSuggestion(app: app) }
    }

    /// «Нет» / «Не сейчас» — до конца этого звонка.
    func dismissCall() {
        call.dismiss()
        model.meetingSuggestion = nil
        if case .callSuggestion? = extras.prompt { extras.prompt = nil }
    }

    private func dismissPrompt() {
        switch extras.prompt {
        case .callSuggestion?: dismissCall()
        default: extras.prompt = nil
        }
    }

    // MARK: M13, W2 — календарь

    private func calendarTick() {
        guard model.settings.calendarEnabled, calendar.isReady else {
            extras.upcoming = nil
            return
        }
        let now = Date()
        let events = calendar.meetings(around: now, days: 1)
        extras.upcoming = MeetingReminder.upcoming(events, now: now).map(UpcomingMeeting.init(event:))
        guard model.settings.meetingReminder, recorder == nil, extras.prompt == nil,
              let due = MeetingReminder.due(events, now: now, shown: remindersShown) else { return }
        remindersShown.insert(due.id)
        extras.prompt = .reminder(UpcomingMeeting(event: due))
    }

    private func setPrep(_ id: String, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { extras.prep.removeValue(forKey: id) } else { extras.prep[id] = text }
        let data = try? JSONSerialization.data(withJSONObject: extras.prep, options: [.prettyPrinted, .sortedKeys])
        try? data?.write(to: prepURL, options: .atomic)
    }

    private static func loadPrep(_ url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: String]) ?? [:]
    }

    /// `notes.md` создаётся под тем же flock, что и заметки MCP-агента (`meeting_store.append_note`);
    /// уже начатый файл не трогаем.
    nonisolated static func writeNotesIfEmpty(_ url: URL, _ text: String) {
        let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return }
        defer { flock(fd, LOCK_UN) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size == 0 else { return }
        let data = Data(text.utf8)
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    // MARK: после расшифровки и сводки (M11, W11, W13)

    /// Движок прислал `meeting_done`.
    func transcriptDone(meeting id: String, folder: URL) {
        known[id] = .done
        load(id, folder: folder)
        runHook(folder, event: .transcript)
    }

    /// Сводка ИИ записана (`MeetingAIController`): хук `summary`, потом — если включено — аудио в Корзину.
    func summaryDone(meeting id: String) {
        guard let meeting = model.meetings.first(where: { $0.id == id }) else { return }
        let folder = meeting.folder
        let summaryStatus = (MeetingFolder.readManifest(folder)?["summary"] as? [String: Any])?["status"] as? String
        guard summaryStatus == "done" else { return }
        Task {
            await self.runHookNow(folder, event: .summary)
            self.trashAudioIfAsked(id, folder: folder, summaryStatus: summaryStatus)
        }
    }

    private func runHook(_ folder: URL, event: MeetingHook.Event) {
        Task { await self.runHookNow(folder, event: event) }
    }

    private func runHookNow(_ folder: URL, event: MeetingHook.Event) async {
        flushSettings()  // отпечаток команды из Настроек пишется с задержкой (шаг 2, п. 10) — сначала дописать
        let settings = model.settings.meetingHook
        let sensitive = MeetingFolder.isSensitive(folder)
        let trusted = MeetingHookTrust.isTrusted(settings, store: hookStore)
        switch MeetingHook.decide(settings, event: event, sensitive: sensitive, trusted: trusted) {
        case .skip("untrusted"):
            // П10 С3: команду меняли не в Mostik — хук выключаем и спрашиваем, не запуская.
            var s = model.settings
            s.meetingHook.enabled = false
            model.onUpdateSettings(s)
            appendHookLog("[\(MeetingFolder.iso(Date()))] \(folder.lastPathComponent) \(event.rawValue) — skipped: untrusted\n")
            confirmHook(command: settings.command)
        case .skip(let reason):
            // Выключенный хук молчит; пропуск чувствительной встречи — виден в манифесте и логе.
            guard reason == "sensitive" else { return }
            MeetingFolder.update(folder, MeetingHook.manifestPatch(date: Date(), exitCode: nil, timedOut: false, skipped: reason))
            appendHookLog("[\(MeetingFolder.iso(Date()))] \(folder.lastPathComponent) \(event.rawValue) — skipped: sensitive\n")
        case .run:
            let started = Date()
            let result = await MeetingHookRunner.run(command: settings.command, folder: folder, event: event,
                                                     timeout: MeetingHook.timeout(settings))
            appendHookLog(MeetingHook.logEntry(date: started, folder: folder, event: event, exitCode: result.exitCode,
                                               timedOut: result.timedOut, seconds: result.seconds, output: result.output))
            MeetingFolder.update(folder, MeetingHook.manifestPatch(date: started, exitCode: result.exitCode,
                                                                   timedOut: result.timedOut, skipped: nil))
        }
    }

    /// Команда хука изменилась вне Mostik (П10 С3): показать её и спросить. По умолчанию — «Не запускать».
    func confirmHook(command: String) {
        let ru = L10n.isRussian
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = ru ? "Команда после встречи изменилась не в Mostik" : "The after-meeting command was changed outside Mostik"
        // Команда — в поле с прокруткой моноширинным шрифтом, невидимые знаки показаны: хвост не спрятать (П10, низкий).
        let notes = MeetingHookPrompt.notes(command)
        alert.informativeText = (ru ? "Mostik выключил её и не запускал. Запускать эту команду после встреч?"
                                    : "Mostik turned it off and didn’t run it. Run this command after meetings?")
            + (notes.isEmpty ? "" : "\n\n" + notes.joined(separator: "\n"))
        alert.accessoryView = Self.commandView(MeetingHookPrompt.visible(command))
        alert.addButton(withTitle: ru ? "Не запускать" : "Don’t run")
        alert.addButton(withTitle: ru ? "Разрешить" : "Allow")
        MenuBarPanel.activateApp()
        let allow = alert.runModal() == .alertSecondButtonReturn
        var s = model.settings
        s.meetingHook.command = command
        flushSettings()  // отложенный отпечаток не должен перезаписать ответ (шаг 2, п. 10)
        s.meetingHook = MeetingHookTrust.answer(allow, settings: s.meetingHook, store: hookStore)
        model.onUpdateSettings(s)
    }

    /// Команда целиком: только чтение, выделяется, перенос по словам, прокрутка.
    private static func commandView(_ text: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 140))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let view = NSTextView(frame: scroll.contentView.bounds)
        view.isEditable = false
        view.isSelectable = true
        view.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        view.string = text
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        return scroll
    }

    private func trashAudioIfAsked(_ id: String, folder: URL, summaryStatus: String?) {
        let summary = MeetingFolder.summary(folder)
        let hasTranscript = FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript.json").path)
        guard AudioRetention.shouldTrash(enabled: model.settings.trashAudioAfterSummary, summaryStatus: summaryStatus,
                                         hasTranscript: hasTranscript, audioKept: summary?.audioKept ?? true) else { return }
        var trashed: [String] = []
        for name in MeetingFolder.audioFiles(folder) {
            do {
                try FileManager.default.trashItem(at: folder.appendingPathComponent(name), resultingItemURL: nil)
                trashed.append(name)
            } catch {
                NSLog("Mostik trash \(name): \(error.localizedDescription)")
            }
        }
        guard !trashed.isEmpty else { return }
        MeetingFolder.update(folder, ["audio": ["kept": false, "trashed_at": MeetingFolder.iso(Date()), "trashed": trashed]])
        extras.audioTrashed.insert(id)
    }

    // MARK: сведения о встречах (M12, M13, W11, W13)

    private func meetingsChanged(_ meetings: [AppModel.MeetingItem]) {
        for meeting in meetings where known[meeting.id] != meeting.state {
            let previous = known[meeting.id]
            known[meeting.id] = meeting.state
            if meeting.state == .done || previous == nil { load(meeting.id, folder: meeting.folder) }
        }
    }

    /// Манифест и метрики говорения — в фоне: `transcript.json` долгой встречи весит мегабайты.
    private func load(_ id: String, folder: URL) {
        Task.detached(priority: .utility) {
            let summary = MeetingFolder.summary(folder)
            let textOnlyRemoved = ((MeetingFolder.readManifest(folder)?["audio"] as? [String: Any])?["reason"] as? String) == "text_only"
            let turns = (try? Data(contentsOf: folder.appendingPathComponent("transcript.json"))).map(SpeechTurn.parse) ?? []
            let metrics = SpeakingMetrics.compute(turns)
            await MainActor.run {
                let extras = self.extras
                if summary?.sensitive == true { extras.sensitive.insert(id) } else { extras.sensitive.remove(id) }
                if let status = summary?.recording, ["recovered", "incomplete"].contains(status) {
                    extras.recordingStatus[id] = status
                }
                if let link = summary?.link { extras.links[id] = link }
                // «Только текст» удаляет звук насовсем — это не «аудио в Корзине».
                if summary?.audioKept == false, !textOnlyRemoved { extras.audioTrashed.insert(id) }
                if let metrics { extras.metrics[id] = metrics } else { extras.metrics.removeValue(forKey: id) }
            }
        }
    }

    private func setSensitive(_ id: String, _ value: Bool) {
        guard let meeting = model.meetings.first(where: { $0.id == id }) else { return }
        // Кадры остаются: облаку и агентам их текст не отдаёт движок, как и расшифровку.
        MeetingFolder.setSensitive(meeting.folder, value)
        if value { extras.sensitive.insert(id) } else { extras.sensitive.remove(id) }
    }

    // MARK: W9 — фрагмент

    private func exportClip(_ id: String, _ lines: [AppModel.TranscriptLine]) {
        guard let meeting = model.meetings.first(where: { $0.id == id }), !lines.isEmpty else { return }
        let folder = meeting.folder
        let title = meeting.title
        let duration = meeting.duration
        let language = language
        let selected = lines.sorted { $0.start < $1.start }.map { (speaker: $0.speaker, start: $0.start, text: $0.text) }
        Task.detached(priority: .userInitiated) {
            let turns = (try? Data(contentsOf: folder.appendingPathComponent("transcript.json"))).map(SpeechTurn.parse) ?? []
            var segments = MeetingSegment.fromManifest(MeetingFolder.readManifest(folder))
            if segments.isEmpty {
                segments = MeetingWatchdog.Track.allCases.map { MeetingSegment(track: $0, file: "\($0.rawValue).wav", offset: 0) }
            }
            let result: MeetingExtrasModel.ClipResult
            if let draft = MeetingClipPlan.make(selected: selected, turns: turns, title: title,
                                                date: MeetingFolder.folderDate(folder.lastPathComponent),
                                                duration: duration, audioFile: nil, language: language),
               let plan = MeetingClipPlan.make(selected: selected, turns: turns, title: title,
                                               date: MeetingFolder.folderDate(folder.lastPathComponent),
                                               duration: duration, audioFile: draft.stem + ".m4a", language: language) {
                do {
                    let saved = try MeetingClipExporter.export(folder: folder, plan: plan, segments: segments)
                    let name = saved.audio == nil ? saved.text.lastPathComponent
                        : saved.text.deletingPathExtension().lastPathComponent + ".m4a + .md"
                    result = .init(meeting: id, folder: saved.audio ?? saved.text,
                                   message: (saved.audio == nil ? L("Аудио нет — сохранён текст: ", "No audio — saved text: ")
                                                                : L("Отрывок сохранён: ", "Clip saved: ")) + name, ok: true)
                } catch {
                    result = .init(meeting: id, folder: nil, message: error.localizedDescription, ok: false)
                }
            } else {
                result = .init(meeting: id, folder: nil, message: L("Не удалось сохранить отрывок", "Could not save the clip"), ok: false)
            }
            await MainActor.run { self.extras.clipResult = result }
        }
    }

    // MARK: плавающая карточка

    private func showPanel(_ visible: Bool) {
        guard visible else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard let hosting = panel.contentView, let screen = NSScreen.main else { return }
        let size = hosting.fittingSize
        let frame = screen.visibleFrame
        panel.setFrame(NSRect(x: frame.maxX - size.width - 8, y: frame.maxY - size.height - 8,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        // Высота карточки меняется вместе с видом подсказки — подогнать после раскладки.
        DispatchQueue.main.async { [weak panel] in
            guard let panel, let hosting = panel.contentView else { return }
            let fitted = hosting.fittingSize
            panel.setFrame(NSRect(x: frame.maxX - fitted.width - 8, y: frame.maxY - fitted.height - 8,
                                  width: fitted.width, height: fitted.height), display: true)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 140),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: MeetingPromptView(extras: extras).tint(Palette.accent))
        return panel
    }
}

private func L(_ ru: String, _ en: String) -> String { L10n.isRussian ? ru : en }
