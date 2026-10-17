import AppKit
import Combine
import Foundation
import MostikCore
import MostikKit
import MostikUI

/// П7: вопросы по ходу встречи (M19), подсказки (M9), кадры окна звонка (W26).
/// Решения — в MostikCore (`MeetingAssist.swift`), платформа — `MeetingFrameCapture`, движок —
/// `meeting_questions.py` и `meeting_hints.py`. Здесь связка: строки живой расшифровки → движок,
/// ответ → журнал и карточка; таймер кадров. В `AppController` встаёт тремя строками, запись
/// встречи узнаёт сам — по `model.meetings`.
@MainActor
final class MeetingAssistController {
    private let model: AppModel
    private let engine: () -> EngineClient
    private var assist: MeetingAssistModel { model.meetingAssist }
    private var cancellables: Set<AnyCancellable> = []

    // Идущая запись.
    private var meetingID: String?
    private var folder: URL?
    private var seenLines: Set<Int> = []
    private var throttle = HintThrottle()
    private var delta = FrameDelta()
    private var frameTimer: Timer?
    private var capturing = false
    /// Остановленные встречи, чей журнал пересчитать по готовой расшифровке.
    private var awaitingTranscript: Set<String> = []

    init(model: AppModel, engine: @escaping () -> EngineClient) {
        self.model = model
        self.engine = engine
        wireIntents()
        model.meetingLive.$transcript
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transcript in self?.transcriptChanged(transcript) }
            .store(in: &cancellables)
        model.$meetings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] meetings in self?.meetingsChanged(meetings) }
            .store(in: &cancellables)
    }

    func start() { meetingsChanged(model.meetings) }

    func stop() {
        frameTimer?.invalidate()
        frameTimer = nil
    }

    private func wireIntents() {
        assist.onToggleFrames = { [weak self] in self?.toggleFrames() }
        assist.onDismissHint = { [weak self] in self?.assist.hint = nil }
        assist.onOpenHint = { [weak self] hint in self?.open(hint) }
        assist.onOpenScreenSettings = { MeetingFrameCapture.openPermissionSettings() }
        assist.onEnableSlides = { if !MeetingFrameCapture.permissionGranted { Permissions.openScreenCapture() } }
        assist.onOpenCheckup = { [weak self] in self?.model.openSettings(.fullCheckup) }
        assist.onLoadJournal = { [weak self] id in self?.loadJournal(id) }
        assist.onOpenFrames = { [weak self] in
            guard let folder = self?.folder else { return }
            NSWorkspace.shared.open(folder.appendingPathComponent(FrameDelta.folderName, isDirectory: true))
        }
    }

    // MARK: начало и конец записи

    private func meetingsChanged(_ meetings: [AppModel.MeetingItem]) {
        let recording = meetings.first { $0.state == .recording }
        if recording?.id != meetingID {
            if let id = meetingID, let folder { recordingStopped(id, folder: folder) }
            if let recording { recordingStarted(recording) }
        }
        for meeting in meetings where meeting.state == .done && awaitingTranscript.contains(meeting.id) {
            awaitingTranscript.remove(meeting.id)
            finalize(meeting.id, folder: meeting.folder, closePending: false)
        }
    }

    private func recordingStarted(_ meeting: AppModel.MeetingItem) {
        meetingID = meeting.id
        folder = meeting.folder
        seenLines = []
        throttle = HintThrottle()
        delta = FrameDelta()
        assist.questions = []
        assist.hint = nil
        assist.judgeNote = nil
        assist.framesCount = 0
        // Слайды — из Настроек; выключенные посреди встречи снова включатся в следующей.
        assist.framesConsent = model.settings.meetingAssist.slides
        assist.framesState = assist.framesConsent ? .watching : .off
        frameTimer?.invalidate()
        let interval = TimeInterval(model.settings.meetingAssist.frameInterval)
        frameTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.frameTick() }
        }
    }

    private func recordingStopped(_ id: String, folder: URL) {
        frameTimer?.invalidate()
        frameTimer = nil
        meetingID = nil
        self.folder = nil
        assist.hint = nil
        // Выключение посреди встречи не запоминается: следующая начнётся по Настройкам.
        assist.framesConsent = false
        assist.framesState = .off
        if !assist.questions.isEmpty {
            assist.journals[id] = assist.questions
            awaitingTranscript.insert(id)
            finalize(id, folder: folder, closePending: true)
        }
    }

    // MARK: M19 — вопросы

    private func transcriptChanged(_ transcript: LiveTranscript) {
        guard let folder, model.settings.meetingAssist.questions else { return }
        for line in transcript.lines where !seenLines.contains(line.id) {
            seenLines.insert(line.id)
            let client = engine()
            Task { [weak self] in
                guard let reply = try? await client.meetingQuestion(folder: folder, track: line.track, at: line.start,
                                                                    text: line.text) else { return }
                self?.questionsArrived(reply, folder: folder)
            }
        }
    }

    private func questionsArrived(_ reply: EngineClient.QuestionReply, folder: URL) {
        guard folder == self.folder else { return }
        assist.questions = MeetingQuestion.merge(assist.questions, reply.added + reply.updated)
        assist.judgeNote = reply.judgeAvailable ? nil : judgeNote(reply.judgeReason)
        for question in reply.added
        where HintPolicy.wants(question, settings: model.settings.meetingAssist, recording: true) {
            requestHint(question, folder: folder)
        }
    }

    private func judgeNote(_ reason: String?) -> String? {
        switch reason {
        case "not_loaded": return L10n.isRussian ? "Вопросы ловят правила: локальная модель не загружена." : "Rules catch questions: the local model isn’t loaded."
        case "memory": return L10n.isRussian ? "Вопросы ловят правила: модели не хватает памяти в бюджете 6 ГБ." : "Rules catch questions: the 6 GB memory budget is used up."
        default: return nil
        }
    }

    private func finalize(_ id: String, folder: URL, closePending: Bool) {
        let client = engine()
        Task { [weak self] in
            guard let items = try? await client.meetingQuestionsFinalize(folder: folder, closePending: closePending) else { return }
            self?.assist.journals[id] = items
        }
    }

    private func loadJournal(_ id: String) {
        guard assist.journals[id] == nil, let folder = model.meetings.first(where: { $0.id == id })?.folder else { return }
        Task.detached(priority: .utility) {
            let items = MeetingQuestion.load(folder: folder)
            await MainActor.run { self.assist.journals[id] = items }
        }
    }

    // MARK: M9 — подсказки

    private func requestHint(_ question: MeetingQuestion, folder: URL) {
        guard throttle.allows(at: Date().timeIntervalSince1970) else { return }
        let settings = model.settings
        let client = engine()
        Task { [weak self] in
            guard let hint = try? await client.meetingHint(question: question, folder: folder,
                                                           sources: HintSources.roots(settings: settings),
                                                           project: self?.model.currentProject,
                                                           consent: settings.meetingAIConsent) else { return }
            self?.show(hint, folder: folder)
        }
    }

    private func show(_ hint: MeetingHint?, folder: URL) {
        let now = Date().timeIntervalSince1970
        // Пока искали, встреча могла кончиться, а подсказки — выключиться.
        guard let hint, folder == self.folder, model.settings.meetingAssist.hints, throttle.allows(at: now) else { return }
        throttle.shown(at: now)
        assist.hint = hint
    }

    private func open(_ hint: MeetingHint) {
        switch hint.kind {
        case .meeting:
            guard let meeting = hint.meeting else { return }
            model.meetingFocus = MeetingFocus(meeting: meeting, at: hint.at ?? 0, turn: hint.turn)
            model.selectedTab = .meetings
        case .source, .glossary:
            guard let path = hint.path, FileManager.default.fileExists(atPath: path) else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    // MARK: W26 — кадры окна звонка

    private func toggleFrames() {
        assist.framesConsent.toggle()
        // Включили без разрешения — сразу вносим Mostik в «Запись экрана», иначе счётчик молча стоит на нуле.
        if assist.framesConsent, !MeetingFrameCapture.permissionGranted { Permissions.openScreenCapture() }
        if meetingID != nil {
            assist.framesState = assist.framesConsent ? .watching : .off
            if assist.framesConsent { frameTick() }
        }
    }

    private func frameTick() {
        guard meetingID != nil, let folder, !model.meetingPaused else { return }
        let decision = FrameDecision.decide(consent: assist.framesConsent, textOnly: model.meetingLive.textOnly,
                                            permission: MeetingFrameCapture.permissionGranted)
        switch decision {
        case .noConsent:
            assist.framesState = .off
            return
        case .capture:
            break
        default:
            assist.framesState = .blocked(decision)
            return
        }
        guard !capturing else { return }
        capturing = true
        let at = model.meetingElapsed
        Task { [weak self] in
            defer { self?.capturing = false }
            guard let window = try? await MeetingFrameCapture.callWindow() else {
                self?.assist.framesState = .noWindow
                return
            }
            guard let image = try? await MeetingFrameCapture.capture(window) else { return }
            self?.frameCaptured(image, at: at, folder: folder)
        }
    }

    private func frameCaptured(_ image: CGImage, at: Double, folder: URL) {
        // Встреча кончилась или согласие сняли, пока шёл снимок, — кадр не пишем.
        guard folder == self.folder, assist.framesConsent, meetingID != nil else { return }
        assist.framesState = .watching
        guard delta.observe(MeetingFrameCapture.thumbnail(image)) else { return }
        assist.framesCount = delta.count
        let url = folder.appendingPathComponent(FrameDelta.folderName, isDirectory: true)
            .appendingPathComponent(FrameDelta.fileName(at: at))
        Task.detached(priority: .utility) {
            // Текст кадра — локально через Vision; в индекс и сводку идёт только он и путь.
            FrameStore.save(to: url, write: { MeetingFrameCapture.writeJPEG(image, to: $0) },
                            ocr: { ImageOCR.recognize($0) })
        }
    }
}
