import AppKit
import Combine
import Foundation
import MostikCore
import MostikKit
import MostikUI

/// Встреча по ходу записи и ремонт после (П6-Б): живая расшифровка (W10), «только текст» (W15),
/// продолжение (W16), ремонт говорящих (W17), прослушивание (W17, W18), черновик письма (W20),
/// ⌃⌘M (W24), шумоподавление (V6), голоса озвучки (A1).
/// Решения — в MostikCore (`MeetingLive.swift`), платформа — в MostikKit (`MeetingLiveKit.swift`), здесь связка.
@MainActor
final class MeetingLiveController {
    private let model: AppModel
    private let engine: () -> EngineClient
    private var live: MeetingLiveModel { model.meetingLive }
    private var cancellables: Set<AnyCancellable> = []
    private var seen: [String: Int] = [:]

    // Связка с `AppController`.
    var startMeeting: () -> Void = {}
    var stopMeeting: () -> Void = {}
    var continueMeeting: (AppModel.MeetingItem) -> Void = { _ in }
    var isRecording: () -> Bool = { false }
    /// Секунды записи без пауз — по часам встречи.
    var recordingClock: () -> Double = { 0 }
    var showMainWindow: () -> Void = {}

    // Идущая запись.
    private weak var recorder: MeetingRecorder?
    private var folder: URL?
    private var textOnly = TextOnlyRanges()
    /// «Только текст» прежних частей встречи (W16): продолжение их не теряет.
    private var previousSpans: [TextOnlyRanges.Span] = []
    private var tails: [LiveTrackTail] = []
    private var liveTimer: Timer?
    private var pending: [(track: String, start: Double, pcm: Data)] = []
    private var inFlight = false

    private lazy var hotkey = MeetingHotkey { [weak self] in self?.hotkeyPressed() }
    private let player = MeetingSnippetPlayer()
    private let announcer = AgentAnnouncer()

    init(model: AppModel, engine: @escaping () -> EngineClient) {
        self.model = model
        self.engine = engine
        live.textOnly = model.settings.meetingLive.textOnlyDefault
        player.onFinish = { [weak self] in self?.live.playing = nil }
        wireIntents()
        // Реплики с id и меткой — для меню ремонта; читаются, когда расшифровка появилась или поменялась.
        model.$meetingTranscripts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transcripts in self?.transcriptsChanged(transcripts) }
            .store(in: &cancellables)
        model.$meetings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] meetings in self?.refreshContinuable(meetings) }
            .store(in: &cancellables)
    }

    func start() { settingsChanged() }

    func stop() {
        hotkey.stop()
        player.stop()
    }

    func settingsChanged() {
        if model.settings.meetingLive.hotkey { hotkey.start() } else { hotkey.stop() }
        live.hotkeyActive = hotkey.isActive
        if !isRecording() && folder == nil { live.textOnly = model.settings.meetingLive.textOnlyDefault }
    }

    /// Шумо- и эхоподавление встречи (V6): решается в момент старта по тому, куда идёт звук.
    func voiceProcessingForMeeting() -> Bool {
        VoiceProcessingPolicy.meeting(mode: model.settings.meetingLive.meetingVoiceProcessing,
                                      outputIsSpeakers: AudioRoute.outputIsSpeakers())
    }

    private func wireIntents() {
        live.onToggleTextOnly = { [weak self] in self?.toggleTextOnly() }
        live.onContinue = { [weak self] id in
            guard let self, let item = self.model.meetings.first(where: { $0.id == id }) else { return }
            self.continueMeeting(item)
        }
        live.onPlay = { [weak self] meeting, start, end, track in self?.play(meeting, start: start, end: end, track: track) }
        live.onStopPlaying = { [weak self] in self?.player.stop() }
        live.onReassignTurn = { [weak self] meeting, turn, label in
            self?.edit(meeting) { engine, folder in
                let reply = try await engine.speakerTurn(folder: folder, turn: turn, label: label)
                let who = reply["speaker"]?.stringValue ?? label
                return L10n.isRussian ? "Реплика перенесена: \(who)." : "Turn moved to \(who)."
            }
        }
        live.onMergeLabel = { [weak self] meeting, source, target in
            self?.edit(meeting) { engine, folder in
                let reply = try await engine.speakerMerge(folder: folder, source: source, target: target)
                let moved = Int(reply["moved"]?.doubleValue ?? 0)
                let who = reply["speaker"]?.stringValue ?? target
                return L10n.isRussian ? "«\(source)» → \(who): перенесено реплик — \(moved)." : "“\(source)” → \(who): \(moved) turns moved."
            }
        }
        live.onWarnParticipants = { [weak self] meeting in self?.draftWarning(meeting) }
        live.onRefreshVoices = { [weak self] in self?.live.voices = SystemVoices.installed() }
        live.onPreviewVoice = { [weak self] voice, sample in self?.announcer.preview(sample, voice: voice) }
    }

    // MARK: W24 — ⌃⌘M и автостарт

    private func hotkeyPressed() {
        if isRecording() { stopMeeting(); return }
        // Без принятого предупреждения о согласии — показать его в окне, запись начнёт «Понятно».
        if !model.settings.consentAcknowledged { showMainWindow(); model.selectedTab = .meetings }
        startMeeting()
    }

    // MARK: запись

    /// Запись началась (в том числе продолжение): хвосты дорожек, «только текст», цикл живой расшифровки.
    func recordingStarted(folder: URL, recorder: MeetingRecorder, offset: Double) {
        self.recorder = recorder
        self.folder = folder
        previousSpans = offset > 0 ? (TextOnlyRanges.fromManifest(MeetingFolder.readManifest(folder))?.spans ?? []) : []
        textOnly = TextOnlyRanges()
        if live.textOnly { textOnly.set(true, at: offset) }
        live.transcript = LiveTranscript()
        live.liveNote = nil
        tails = MeetingWatchdog.Track.allCases.map(LiveTrackTail.init(track:))
        pending = []
        liveTimer?.invalidate()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.liveTick(final: false) }
        }
    }

    /// Запись остановлена — до команды движку: отрезки «только текст» в манифест.
    func recordingStopped(folder: URL, duration: Double) {
        liveTimer?.invalidate()
        liveTimer = nil
        // Хвост по ходу не дорасшифровываем: движку сейчас важнее полная расшифровка встречи.
        pending = []
        tails = []
        let spans = TextOnlyRanges.normalized(previousSpans + textOnly.closed(at: duration))
        if !spans.isEmpty {
            let whole = TextOnlyRanges.coversWhole(spans, duration: duration)
            MeetingFolder.update(folder, ["text_only": TextOnlyRanges.manifestValue(spans, whole: whole)])
        }
        recorder = nil
        self.folder = nil
        textOnly = TextOnlyRanges()
        previousSpans = []
        live.textOnly = model.settings.meetingLive.textOnlyDefault
    }

    private func toggleTextOnly() {
        guard folder != nil else {
            live.textOnly.toggle()
            return
        }
        let on = !live.textOnly
        textOnly.set(on, at: recordingClock())
        live.textOnly = on
    }

    // MARK: W10 — живая расшифровка

    private func liveTick(final: Bool) {
        guard model.settings.meetingLive.liveTranscript, let recorder, let folder else { return }
        let segments = recorder.segments
        for tail in tails {
            tail.poll(folder: folder, segments: segments)
            while let chunk = tail.take(final: final) {
                pending.append((tail.track.rawValue, chunk.start, chunk.pcm))
                if final { break }
            }
        }
        // Движок не успевает: старые куски выбрасываем, строка по ходу встречи важнее полноты.
        if pending.count > 4 {
            pending.removeFirst(pending.count - 4)
            live.liveNote = L10n.isRussian ? "Расшифровка по ходу отстаёт — часть кусков пропущена. Полная будет после остановки."
                                           : "The live draft is lagging — some pieces were skipped. The full transcript comes after you stop."
        }
        pump()
    }

    private func pump() {
        guard !inFlight, !pending.isEmpty, model.engineStatus == .ready else { return }
        let item = pending.removeFirst()
        inFlight = true
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mostik-live-\(UUID().uuidString).wav")
        let settings = model.settings
        Task {
            defer { try? FileManager.default.removeItem(at: url) }
            var text: String?
            if (try? LivePCM.wav(item.pcm).write(to: url)) != nil {
                let result = try? await engine().transcribeLive(path: url.path, language: settings.language,
                                                                 languages: LanguageChoice.request(settings: settings,
                                                                                                   preferred: Locale.preferredLanguages))
                text = result?.rawText.isEmpty == false ? result?.rawText : result?.text
            }
            if let text { live.transcript.add(track: item.track, start: item.start, text: text) }
            inFlight = false
            pump()
        }
    }

    // MARK: W15 — после расшифровки

    /// Расшифровка готова: звук отрезков «только текст» — тишина; вся встреча такая — аудио
    /// удаляется насовсем, без Корзины (П10 С7, `TextOnlyAudio`).
    func transcriptDone(meeting id: String, folder: URL) {
        guard let block = TextOnlyRanges.fromManifest(MeetingFolder.readManifest(folder)), !block.spans.isEmpty else { return }
        Task.detached(priority: .utility) {
            TextOnlyAudio.purge(folder)
            await MainActor.run { self.refreshContinuable(self.model.meetings) }
        }
    }

    // MARK: W16 — продолжить запись

    /// Прежние сегменты встречи и секунда, с которой пойдёт продолжение.
    nonisolated static func continuation(_ folder: URL) -> (segments: [MeetingSegment], offset: Double, started: Any?) {
        let manifest = MeetingFolder.readManifest(folder)
        var segments = MeetingSegment.fromManifest(manifest)
        if segments.isEmpty {
            segments = MeetingWatchdog.Track.allCases
                .map { MeetingSegment(track: $0, file: "\($0.rawValue).wav", offset: 0) }
                .filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.file).path) }
        }
        let duration = (manifest?["duration_seconds"] as? Double) ?? (manifest?["duration_seconds"] as? NSNumber)?.doubleValue
        let offset = MeetingContinuation.baseOffset(segments: segments, seconds: { file in
            WAVInfo.duration(of: folder.appendingPathComponent(file))
        }, manifestDuration: duration)
        return (segments, offset, manifest?["started"])
    }

    // MARK: W16 — что можно продолжить

    private func refreshContinuable(_ meetings: [AppModel.MeetingItem]) {
        let recording = isRecording()
        let latest = meetings.max(by: { $0.startedAt < $1.startedAt })?.id
        var result: Set<String> = []
        var expires: Date?
        for meeting in meetings where meeting.state == .done && meeting.id == latest {
            let kept = !model.meetingExtras.audioTrashed.contains(meeting.id)
            let hasAudio = !MeetingFolder.audioFiles(meeting.folder).isEmpty
            let ended = meeting.startedAt.addingTimeInterval(meeting.duration)
            if MeetingContinuation.allowed(recording: recording, audioKept: kept, hasAudio: hasAudio,
                                           latest: true, endedAt: ended) {
                result.insert(meeting.id)
                expires = ended.addingTimeInterval(MeetingContinuation.window)
            }
        }
        if live.continuable != result { live.continuable = result }
        // Окно закрывается само, даже если список встреч больше не меняется.
        if let expires {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(1, expires.timeIntervalSinceNow) + 1) { [weak self] in
                guard let self else { return }
                self.refreshContinuable(self.model.meetings)
            }
        }
    }

    // MARK: W17 — реплики и ремонт

    private func transcriptsChanged(_ transcripts: [String: [AppModel.TranscriptLine]]) {
        let folders = Dictionary(model.meetings.map { ($0.id, $0.folder) }, uniquingKeysWith: { a, _ in a })
        for (id, lines) in transcripts where seen[id] != lines.hashValueForChange {
            seen[id] = lines.hashValueForChange
            guard let folder = folders[id] else { continue }
            let url = folder.appendingPathComponent("transcript.json")
            Task.detached(priority: .utility) {
                let turns = (try? Data(contentsOf: url)).map(TurnRef.parse) ?? []
                await MainActor.run { self.live.turns[id] = turns }
            }
        }
    }

    private func edit(_ meeting: String, _ action: @escaping (EngineClient, URL) async throws -> String) {
        guard let folder = model.meetings.first(where: { $0.id == meeting })?.folder else { return }
        live.repairNote[meeting] = nil
        Task {
            do {
                live.repairNote[meeting] = try await action(engine(), folder)
            } catch {
                live.repairNote[meeting] = error.localizedDescription
            }
            model.meetingTranscripts[meeting] = AppController.parseTranscript(json: folder.appendingPathComponent("transcript.json"))
        }
    }

    // MARK: W17, W18 — прослушать

    private func play(_ meeting: String, start: Double, end: Double, track: String?) {
        guard let folder = model.meetings.first(where: { $0.id == meeting })?.folder else { return }
        let tracks: [MeetingWatchdog.Track] = track.flatMap(MeetingWatchdog.Track.init(rawValue:)).map { [$0] }
            ?? MeetingWatchdog.Track.allCases
        let from = max(0, start - 0.3)
        Task.detached(priority: .userInitiated) {
            var segments = MeetingSegment.fromManifest(MeetingFolder.readManifest(folder))
            if segments.isEmpty {
                segments = MeetingWatchdog.Track.allCases.map { MeetingSegment(track: $0, file: "\($0.rawValue).wav", offset: 0) }
            }
            let pcm = MeetingAudioFiles.snippet(folder: folder, segments: segments, tracks: tracks, start: from, end: end)
            await MainActor.run {
                if self.player.play(pcm: pcm) {
                    self.live.playing = MeetingLiveModel.Playing(meeting: meeting, start: from, end: end)
                } else {
                    self.live.repairNote[meeting] = L10n.isRussian ? "Звука этого места нет — аудио удалено или в Корзине."
                                                                   : "No audio for this moment — it was deleted or moved to the Trash."
                }
            }
        }
    }

    // MARK: W20 — черновик письма

    /// Черновик в почтовом клиенте по умолчанию через `mailto:` — письмо открывается, но не отправляется.
    private func draftWarning(_ meeting: UpcomingMeeting) {
        let warning = ConsentWarning.text(custom: model.settings.meetingLive.warningText, russian: L10n.isRussian)
        guard let url = ConsentWarning.mailto(emails: meeting.emails, title: meeting.title, start: meeting.start,
                                              warning: warning, russian: L10n.isRussian) else { return }
        NSWorkspace.shared.open(url)
    }
}

private extension Array where Element == AppModel.TranscriptLine {
    /// Отпечаток для «поменялась ли расшифровка»: число строк и их тексты с говорящими.
    var hashValueForChange: Int {
        var hasher = Hasher()
        hasher.combine(count)
        for line in self { hasher.combine(line.id); hasher.combine(line.speaker); hasher.combine(line.start) }
        return hasher.finalize()
    }
}
