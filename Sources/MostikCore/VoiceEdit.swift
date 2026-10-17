import Foundation

// Голосовая правка выделенного (D5): чистая логика без AppKit — решение «можно ли»,
// выбор пути чтения выделения, жест правого ⌘ и разбор ответа движка.
// Договор — docs/polish-contract.md, раздел «Голосовая правка выделенного».

/// Почему голосовая правка сейчас не работает.
public enum VoiceEditBlocker: String, Equatable, Sendable {
    /// Выключена в настройках.
    case disabled
    /// Бэкенд LLM не выбран: правке нужен тот же бэкенд, что и причёсыванию.
    case noBackend
    /// Выбран `claude`, но согласия на облако нет.
    case noConsent
}

public enum VoiceEditAvailability: Equatable, Sendable {
    case ready(PolishBackend)
    case blocked(VoiceEditBlocker)

    public var backend: PolishBackend? {
        if case .ready(let backend) = self { return backend }
        return nil
    }
}

extension MostikSettings {
    /// Можно ли слушать клавишу правки (`voiceEditKey`). Бэкенд и согласие берутся из причёсывания (`polish`).
    /// Конфликта с клавишей записи нет: при записи на правом ⌘ правка уходит на правый ⌥ (`HoldKeys`).
    public var voiceEditAvailability: VoiceEditAvailability {
        guard voiceEdit else { return .blocked(.disabled) }
        switch polish.backend {
        case .off: return .blocked(.noBackend)
        case .claude: return polish.cloudConsent ? .ready(.claude) : .blocked(.noConsent)
        case .mlx: return .ready(.mlx)
        }
    }
}

// MARK: - Выделение

/// Что ответил AX о выделении в элементе в фокусе.
public enum SelectionProbe: Equatable, Sendable {
    /// `kAXSelectedTextAttribute` вернул непустую строку.
    case text(String)
    /// Атрибут есть, но строка пустая. Chromium и Electron так отвечают и при живом выделении.
    case empty
    /// Нет элемента в фокусе или он не отдаёт атрибут.
    case unsupported
    /// У приложения нет доступа к Accessibility.
    case noAccess
}

/// Почему правка не состоялась. Тексты для HUD — в `VoiceEditModel`.
public enum VoiceEditFailure: String, Equatable, Sendable {
    case secureInput, noAccessibility, noSelection, tooLong, noMicrophone, busy
    case emptyCommand, refused, unchanged, timeout, unavailable, badOutput, engine
    case focusChanged, pasteFailed
    /// Менеджер паролей, связка ключей, банк или своё исключение (`PolishContext`): выделение не читаем.
    case excludedApp
}

/// Как читать выделение.
public enum SelectionPlan: Equatable, Sendable {
    case use(String)
    /// AX не дал текста — копируем ⌘C со снимком и восстановлением буфера.
    case copyFallback
    case refuse(VoiceEditFailure)
}

public enum VoiceEditSelection {
    /// Предел движка (`voice_edit.MAX_SELECTION`): длиннее — не правим, а говорим об этом сразу.
    public static let maxCharacters = 20_000

    /// Путь чтения выделения на нажатии правого ⌘. `probe` вычисляется лениво: в защищённом поле
    /// и в исключённом приложении выделение не читается вовсе — ни AX, ни запасным ⌘C.
    public static func plan(probe: @autoclosure () -> SelectionProbe, secureInput: Bool,
                            excludedApp: Bool = false) -> SelectionPlan {
        if secureInput { return .refuse(.secureInput) }
        if excludedApp { return .refuse(.excludedApp) }
        switch probe() {
        case .noAccess:
            // Без Accessibility не уйдёт и ⌘C: запасного пути нет.
            return .refuse(.noAccessibility)
        case .text(let text) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return text.count > maxCharacters ? .refuse(.tooLong) : .use(text)
        case .text, .empty, .unsupported:
            return .copyFallback
        }
    }

    /// Приложение из списка исключений контекста (встроенного или своего): правка голосом там не работает.
    public static func isExcluded(bundleID: String, settings: PolishContextSettings) -> Bool {
        PolishContext.excludedApps.contains(bundleID) || settings.excludedApps.contains(bundleID)
    }

    /// Итог запасного ⌘C: буфер не изменился — выделения не было (⌘C без выделения буфер не трогает).
    public static func copied(changeBefore: Int, changeAfter: Int, text: String?) -> SelectionPlan {
        guard changeAfter != changeBefore, let text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .refuse(.noSelection) }
        return text.count > maxCharacters ? .refuse(.tooLong) : .use(text)
    }
}

// MARK: - Жест правого ⌘

/// Удержание правого ⌘ как клавиши правки, не мешая обычным сочетаниям с ⌘.
///
/// Запись начинается сразу на нажатии, чтобы не терять первые слова. Любая другая клавиша
/// или щелчок мышью за время удержания — это сочетание (⌘C, ⌘-щелчок), а не правка: отмена,
/// и до отпускания ⌘ жест больше ничего не делает. Короткое нажатие — тоже не правка.
public struct VoiceEditGesture: Sendable {
    public enum Input: Equatable, Sendable {
        case commandDown(at: TimeInterval)
        case commandUp(at: TimeInterval)
        case otherInput
    }

    public enum Effect: Equatable, Sendable { case begin, finish, abort }

    public enum State: Equatable, Sendable { case idle, holding(since: TimeInterval), ignoring }

    public var minimumHold: TimeInterval
    public private(set) var state: State = .idle

    public init(minimumHold: TimeInterval = 0.3) { self.minimumHold = minimumHold }

    public mutating func handle(_ input: Input) -> Effect? {
        switch (state, input) {
        case (.idle, .commandDown(let at)):
            state = .holding(since: at)
            return .begin
        case (.holding, .otherInput):
            state = .ignoring
            return .abort
        case (.holding(let since), .commandUp(let at)):
            state = .idle
            return at - since >= minimumHold ? .finish : .abort
        case (.ignoring, .commandUp):
            state = .idle
            return nil
        default:
            return nil
        }
    }

    /// Сброс снаружи (настройка выключена, монитор остановлен).
    public mutating func reset() -> Effect? {
        defer { state = .idle }
        if case .holding = state { return .abort }
        return nil
    }
}

// MARK: - Ответ движка

/// Событие `edit_done`: что заменить и чем, либо почему не заменять.
public struct VoiceEditReply: Equatable, Sendable {
    public var status: String
    public var text: String
    /// Как модель поняла команду; если не успела — распознанная команда.
    public var command: String
    /// Распознанная команда как есть.
    public var heard: String
    public var detail: String
    public var ms: Double

    public init(status: String, text: String = "", command: String = "", heard: String = "", detail: String = "",
                ms: Double = 0) {
        self.status = status; self.text = text; self.command = command; self.heard = heard
        self.detail = detail; self.ms = ms
    }

    public init(payload: [String: JSONValue]) {
        self.init(status: payload["status"]?.stringValue ?? "failed",
                  text: payload["text"]?.stringValue ?? "",
                  command: payload["command"]?.stringValue ?? "",
                  heard: payload["heard"]?.stringValue ?? "",
                  detail: payload["detail"]?.stringValue ?? "",
                  ms: payload["ms"]?.doubleValue ?? 0)
    }

    /// Заменяем выделение только при `done` и непустом тексте; всё прочее выделение не трогает.
    public var replacement: String? {
        status == "done" && !text.isEmpty ? text : nil
    }

    public var failure: VoiceEditFailure? {
        switch status {
        case "done": return text.isEmpty ? .badOutput : nil
        case "unchanged": return .unchanged
        case "refused": return .refused
        case "empty_command": return .emptyCommand
        case "empty_selection": return .noSelection
        case "too_long": return .tooLong
        case "timeout": return .timeout
        case "unavailable": return .unavailable
        case "bad_output": return .badOutput
        default: return .engine
        }
    }
}
