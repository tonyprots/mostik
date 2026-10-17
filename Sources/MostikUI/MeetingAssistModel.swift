import SwiftUI
import MostikCore

/// П7: вопросы по ходу встречи (M19), подсказки (M9), кадры окна звонка (W26).
/// Своя модель, чтобы не толкаться в `AppModel` с соседними фичами.
@MainActor
public final class MeetingAssistModel: ObservableObject {
    /// Что сейчас с кадрами идущей встречи — для строки в окне встречи и в пилюле.
    public enum FramesState: Equatable {
        /// Согласия на эту встречу нет (по умолчанию).
        case off
        /// Согласие есть, кадр снимается только при заметной смене.
        case watching
        case blocked(FrameDecision)
        /// Окна приложения звонка на экране не нашлось.
        case noWindow
    }

    // MARK: M19 — вопросы

    /// Вопросы идущей записи.
    @Published public var questions: [MeetingQuestion] = []
    /// Журналы готовых встреч из `questions.json` — по `MeetingItem.id`.
    @Published public var journals: [String: [MeetingQuestion]] = [:]
    /// Подпись про судью: «модель не загружена — решают правила» и т. п.
    @Published public var judgeNote: String?

    // MARK: M9 — подсказка

    @Published public var hint: MeetingHint?

    // MARK: W26 — кадры

    /// Согласие на кадры ЭТОЙ встречи. Сбрасывается в начале и в конце каждой записи.
    @Published public var framesConsent = false
    @Published public var framesState: FramesState = .off
    @Published public var framesCount = 0

    public init() {}

    // MARK: Намерения

    public var onToggleFrames: () -> Void = {}
    public var onDismissHint: () -> Void = {}
    public var onOpenHint: (MeetingHint) -> Void = { _ in }
    /// Панель «Запись экрана» в Системных настройках — разрешение выдаёт пользователь.
    public var onOpenScreenSettings: () -> Void = {}
    /// Слайды включили в Настройках: нет разрешения «Запись экрана» — внести Mostik в список и открыть его.
    public var onEnableSlides: () -> Void = {}
    /// «Проверка» в Настройках Mostik.
    public var onOpenCheckup: () -> Void = {}
    public var onLoadJournal: (String) -> Void = { _ in }
    public var onOpenFrames: () -> Void = {}

    // MARK: Помощники видов

    public var counts: (answered: Int, unanswered: Int, pending: Int) { Self.counts(questions) }

    public static func counts(_ items: [MeetingQuestion]) -> (answered: Int, unanswered: Int, pending: Int) {
        (items.filter { $0.status == .answered }.count, items.filter { $0.status == .unanswered }.count,
         items.filter { $0.status == .pending }.count)
    }

    /// Строка состояния кадров; nil — показывать нечего.
    public var framesLine: String? {
        switch framesState {
        case .off:
            return nil
        case .watching:
            return framesCount == 0
                ? L("Слайды звонка: ждём смены слайда.", "Call slides: waiting for a slide change.")
                : L("Слайды звонка: снято \(framesCount).", "Call slides: \(framesCount) captured.")
        case .noWindow:
            return L("Окно звонка не видно на экране — слайды не снимаются.", "The call window isn’t on screen, so no slides are captured.")
        case .blocked(let reason):
            switch reason {
            case .textOnly: return L("Звук не хранится — слайды тоже не сохраняются.", "Audio isn’t kept, so slides aren’t either.")
            case .noPermission:
                return L("Нужно разрешение «Запись экрана»: включите Mostik в Системных настройках и перезапустите его.",
                         "Screen Recording permission is needed: turn Mostik on in System Settings and relaunch it.")
            case .noConsent, .capture: return nil
            }
        }
    }
}
