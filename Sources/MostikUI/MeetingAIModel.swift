import Foundation
import SwiftUI
import MostikCore

/// Разделы окна готовой встречи (П9-B): сводка сразу под заголовком, задачи, расшифровка.
public enum MeetingSection: String, Hashable, Sendable, CaseIterable {
    case summary, tasks, transcript
}

/// Заметки, сводка и задачи встреч (M5–M7). Наполняет `MeetingAIController`, рисуют `MeetingAIViews`.
@MainActor
public final class MeetingAIModel: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case idle
        case queued
        case running(String)
        case failed(String)
    }

    /// Запрос прокрутки к реплике: `nonce` различает два нажатия на одну ссылку.
    public struct ScrollRequest: Equatable, Sendable {
        public var meeting: String
        public var turn: Int
        public var nonce: Int
    }

    /// Разобранный `notes.json` по `MeetingItem.id`.
    @Published public var files: [String: MeetingAIFile] = [:]
    /// Пометки из `transcript.json` сейчас — по ним видно разорванную связь.
    @Published public var marks: [String: [MeetingAIMark]] = [:]
    @Published public var phases: [String: Phase] = [:]
    /// Выбранный режим по встрече; без выбора — последний обработанный.
    @Published public var modes: [String: MeetingAIMode] = [:]
    /// Встреча, для которой показан лист согласия.
    @Published public var consentFor: String? = nil
    /// `consentFor` из Настроек: лист согласия без встречи — только согласие, без запуска.
    public static let settingsConsent = ""
    /// В «Тексте» только что включили Claude: под выбором вопрос «включить и для встреч?».
    @Published public var offerAfterPolish = false
    @Published public var scrollRequest: ScrollRequest? = nil
    /// Раздел окна готовой встречи (П9-B) по `MeetingItem.id`; без выбора — сводка.
    @Published public var section: [String: MeetingSection] = [:]
    /// Подсвеченная строка расшифровки после перехода по ссылке (`turn` здесь — id строки в интерфейсе).
    @Published public var highlighted: ScrollRequest? = nil

    // Шаблоны (M16), виды сводки (W22), рецепты (W7), следующие шаги (W25), свои записи (W23).
    /// Шаблоны сводки и рецепты из движка: встроенные и свои.
    @Published public var templates: [MeetingTemplateInfo] = []
    @Published public var recipes: [MeetingTemplateInfo] = []
    /// Шаблон, который выбрался бы сам по событию календаря, — по встрече.
    @Published public var detected: [String: String] = [:]
    /// Выбранный пользователем шаблон основной сводки; нет — «Сам по событию».
    @Published public var chosenTemplate: [String: String] = [:]
    /// Показанный вид сводки: `main` или ключ вида (`protocol`, `exec`, `custom-…`).
    @Published public var view: [String: String] = [:]
    /// Ход дополнительных сводок: ключ — «встреча|вид».
    @Published public var variantPhases: [String: Phase] = [:]
    /// Поле «Опишите сводку словами» открыто у встречи.
    @Published public var customFor: String? = nil
    /// Свои записи и картинки встречи (W23): знаков в `notes.md` и картинок.
    @Published public var inputs: [String: MeetingInputsInfo] = [:]
    /// Рецепт в работе и готовый черновик рецепта для просмотра.
    @Published public var recipeRunning: [String: String] = [:]
    @Published public var recipePreview: RecipePreview? = nil
    /// Лист «Следующие шаги» (W25).
    @Published public var nextSteps: NextStepsSheet? = nil
    /// Короткое сообщение после действия («Сохранено в …»).
    @Published public var toast: String? = nil

    public struct MeetingInputsInfo: Equatable, Sendable {
        public var notesChars: Int
        public var images: [String]
        public init(notesChars: Int, images: [String]) { self.notesChars = notesChars; self.images = images }
    }

    public struct RecipePreview: Equatable, Sendable {
        public var meeting: String
        public var recipe: String
        public var name: String
        public var text: String
        public var path: String?
        public var email: Bool
        public init(meeting: String, recipe: String, name: String, text: String, path: String?, email: Bool) {
            self.meeting = meeting; self.recipe = recipe; self.name = name; self.text = text; self.path = path; self.email = email
        }
    }

    public struct NextStepsSheet: Equatable, Sendable {
        public enum Tab: String, Sendable { case email, tasks, event }
        public var meeting: String
        public var steps: MeetingNextSteps
        public var tab: Tab = .email
        /// Куда сохранили `.ics` — «Добавить в Календарь» доступно только после сохранения.
        public var savedICS: String? = nil
        public init(meeting: String, steps: MeetingNextSteps) { self.meeting = meeting; self.steps = steps }
    }

    // Намерения — их подключает контроллер.
    public var onRun: (String, MeetingAIMode) -> Void = { _, _ in }
    public var onGrantConsent: (String) -> Void = { _ in }
    public var onEditMark: (String, Int, String) -> Void = { _, _, _ in }
    /// Задача в окне встречи: (встреча, где в `notes.json`, номер, правка).
    public var onEditTask: (String, MeetingAITaskPlace, Int, MeetingAITaskEdit) -> Void = { _, _, _, _ in }
    /// Сделать дополнительную сводку: (встреча, вид или `custom`, описание словами).
    public var onRunVariant: (String, String, String?) -> Void = { _, _, _ in }
    public var onChooseTemplate: (String, String?) -> Void = { _, _ in }
    public var onRunRecipe: (String, String) -> Void = { _, _ in }
    public var onOpenNextSteps: (String) -> Void = { _ in }
    public var onOpenMailDraft: (MeetingEmailDraft) -> Void = { _ in }
    public var onCopy: (String) -> Void = { _ in }
    public var onSaveTasks: (String, String) -> Void = { _, _ in }
    public var onSaveICS: (String, MeetingEventDraft) -> Void = { _, _ in }
    public var onAddICSToCalendar: (String) -> Void = { _ in }
    public var onReveal: (String) -> Void = { _ in }
    public var onAddImages: (String) -> Void = { _ in }
    public var onOpenNotes: (String) -> Void = { _ in }
    public var onOpenTemplatesFolder: () -> Void = {}
    public var onUseNotes: (Bool) -> Void = { _ in }

    private var nonce = 0

    public init() {}

    public func mode(for meeting: String) -> MeetingAIMode {
        modes[meeting] ?? files[meeting]?.lastMode ?? .detailed
    }

    public func result(for meeting: String) -> MeetingAIResult? {
        files[meeting]?.results[mode(for: meeting)]
    }

    public func phase(for meeting: String) -> Phase { phases[meeting] ?? .idle }

    public func variantPhase(_ meeting: String, _ variant: String) -> Phase { variantPhases[meeting + "|" + variant] ?? .idle }

    /// Показанный вид; вид пропал из файла — основная сводка.
    public func shownView(for meeting: String) -> String {
        guard let key = view[meeting], key != MeetingAIVariant.main else { return MeetingAIVariant.main }
        if files[meeting]?.variants[key] != nil || variantPhase(meeting, key) != .idle { return key }
        return MeetingAIVariant.main
    }

    public func templateName(_ id: String?) -> String? {
        guard let id else { return nil }
        return templates.first { $0.id == id }?.title(russian: L10n.isRussian)
    }

    public var isBusy: Bool {
        phases.values.contains { if case .running = $0 { return true }; return $0 == .queued }
    }

    public func scroll(to turn: Int, in meeting: String) {
        // Реплики живут в разделе «Расшифровка»: ссылка из сводки или задачи открывает его.
        section[meeting] = .transcript
        nonce += 1
        let request = ScrollRequest(meeting: meeting, turn: turn, nonce: nonce)
        scrollRequest = request
    }

    /// Подсветить строку, к которой прокрутили; гаснет сама.
    public func highlight(line: Int, in meeting: String) {
        nonce += 1
        let current = nonce
        highlighted = ScrollRequest(meeting: meeting, turn: line, nonce: current)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self, self.highlighted?.nonce == current else { return }
            withAnimation(Motion.quick) { self.highlighted = nil }
        }
    }
}
