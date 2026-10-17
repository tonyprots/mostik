import Foundation

/// Состояния одной диктовки. Чистая логика: никакого звука и AppKit,
/// только переходы, по которым приложение решает, что делать.
public enum DictationState: Equatable, Sendable {
    case idle
    case recording(session: String, startedAt: Double, toggled: Bool)
    case transcribing(session: String, audioSeconds: Double)
    case inserting(session: String)
    case failed(message: String)
}

public enum DictationInput: Equatable, Sendable {
    case holdBegan(at: Double)
    case holdEnded(at: Double)
    case togglePressed(at: Double)
    /// Защёлка (H4): идущая по удержанию запись продолжается без рук.
    case latch
    /// Случайная отмена (⌥+буква во время удержания): действует только на запись.
    case cancel
    /// Esc (H2): явная отмена на любом этапе — запись, расшифровка, вставка.
    case abort
    case resultReady
    /// ⌘V ушёл в приложение (шаг 1, п. 3): машина свободна, проверка вставки и возврат буфера — в фоне.
    case pastePosted
    case inserted
    case failure(String)
    case reset
}

public enum DictationEffect: Equatable, Sendable {
    case startRecording(session: String)
    case stopRecording(session: String)
    case discardRecording(session: String)
    case insertResult(session: String)
    /// Расшифровку бросили по Esc: текст, когда придёт, уходит в историю как «отменено».
    case abandonTranscription(session: String)
    /// Esc во время вставки: не вставлять, а если уже вставлено — откатить (A7).
    case abortInsertion(session: String)
    case showError(String)
}

public struct DictationMachine: Sendable {
    /// Короче этого удержание считается случайным нажатием (H1: 0,3 с).
    public var minimumHold: Double = 0.3
    public var makeSessionID: @Sendable () -> String = { UUID().uuidString.lowercased() }
    public private(set) var state: DictationState = .idle

    /// Режим без рук (D1): два нажатия короче `tapMax` с паузой не больше `tapGap`
    /// начинают запись без удержания; следующее нажатие её останавливает.
    public var doubleTapEnabled = true
    public var tapMax: Double = 0.3
    public var tapGap: Double = 0.4
    /// Идёт запись без рук.
    public private(set) var isHandsFree = false
    /// Когда закончилось первое короткое нажатие — ждём второе.
    private var lastTapEndedAt: Double?
    /// Текущее удержание — второе нажатие двойного.
    private var secondTapPending = false
    /// Нажатия, начавшие запись, и нажатия, пришедшие в расшифровку или вставку и пропавшие (шаг 0).
    public private(set) var acceptedPresses = 0
    public private(set) var droppedPresses = 0

    public init(minimumHold: Double = 0.3, makeSessionID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }) {
        self.minimumHold = minimumHold
        self.makeSessionID = makeSessionID
    }

    @discardableResult
    public mutating func handle(_ input: DictationInput) -> [DictationEffect] {
        let effects = transition(input)
        if effects.contains(where: { if case .startRecording = $0 { return true } else { return false } }) {
            acceptedPresses += 1
        }
        switch (state, input) {
        case (.transcribing, .holdBegan), (.transcribing, .togglePressed),
             (.inserting, .holdBegan), (.inserting, .togglePressed):
            if effects.isEmpty { droppedPresses += 1 }
        default: break
        }
        return effects
    }

    private mutating func transition(_ input: DictationInput) -> [DictationEffect] {
        switch (state, input) {
        case (.idle, .holdBegan(let t)), (.failed, .holdBegan(let t)):
            secondTapPending = doubleTapEnabled && lastTapEndedAt.map { t - $0 <= tapGap && t >= $0 } == true
            lastTapEndedAt = nil
            let id = makeSessionID()
            state = .recording(session: id, startedAt: t, toggled: false)
            return [.startRecording(session: id)]
        case (.idle, .togglePressed(let t)), (.failed, .togglePressed(let t)):
            let id = makeSessionID()
            state = .recording(session: id, startedAt: t, toggled: true)
            return [.startRecording(session: id)]
        case (.recording(let id, let started, false), .holdEnded(let t)):
            let held = t - started
            if doubleTapEnabled, held < tapMax {
                if secondTapPending {
                    // Второе короткое нажатие: запись этого нажатия продолжается уже без рук.
                    secondTapPending = false
                    isHandsFree = true
                    state = .recording(session: id, startedAt: started, toggled: true)
                    return []
                }
                lastTapEndedAt = t
                state = .idle
                return [.discardRecording(session: id)]
            }
            secondTapPending = false
            if held < minimumHold {
                state = .idle
                return [.discardRecording(session: id)]
            }
            state = .transcribing(session: id, audioSeconds: held)
            return [.stopRecording(session: id)]
        case (.recording(let id, let started, false), .latch):
            // Дальше как после двойного нажатия: отпускание не останавливает, следующее нажатие — да.
            secondTapPending = false
            lastTapEndedAt = nil
            isHandsFree = true
            state = .recording(session: id, startedAt: started, toggled: true)
            return []
        case (.recording(let id, let started, true), .holdBegan(let t)) where isHandsFree:
            // Одиночное нажатие останавливает запись без рук; его отпускание придёт в расшифровку и не значит ничего.
            isHandsFree = false
            state = .transcribing(session: id, audioSeconds: t - started)
            return [.stopRecording(session: id)]
        case (.recording(let id, let started, true), .togglePressed(let t)):
            isHandsFree = false
            state = .transcribing(session: id, audioSeconds: t - started)
            return [.stopRecording(session: id)]
        case (.recording(let id, _, _), .cancel), (.recording(let id, _, _), .abort):
            clearTaps()
            state = .idle
            return [.discardRecording(session: id)]
        case (.transcribing(let id, _), .resultReady):
            state = .inserting(session: id)
            return [.insertResult(session: id)]
        case (.transcribing, .cancel):
            // Случайная отмена относится только к записи: начатую расшифровку не бросаем,
            // иначе готовый текст пропадёт без вставки и без записи в истории.
            return []
        case (.transcribing(let id, _), .abort):
            // Явный Esc: машина свободна сразу, а текст контроллер сохранит как «отменено».
            clearTaps()
            state = .idle
            return [.abandonTranscription(session: id)]
        case (.inserting(let id), .abort):
            clearTaps()
            state = .idle
            return [.abortInsertion(session: id)]
        case (.failed, .abort):
            state = .idle
            return []
        case (.inserting, .inserted), (.inserting, .pastePosted):
            state = .idle
            return []
        case (_, .failure(let message)):
            if case .idle = state { return [] }
            clearTaps()
            state = .failed(message: message)
            return [.showError(message)]
        case (_, .reset):
            clearTaps()
            state = .idle
            return []
        default:
            return []
        }
    }

    private mutating func clearTaps() {
        isHandsFree = false
        secondTapPending = false
        lastTapEndedAt = nil
    }

    public var currentSession: String? {
        switch state {
        case .recording(let id, _, _), .transcribing(let id, _), .inserting(let id): return id
        default: return nil
        }
    }
}
