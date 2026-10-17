import Foundation

// Надёжная доставка текста (R1–R5, H2, H3, A7): чистые правила.
// Платформа (AX-чтение поля, ⌘V, ⌘Z) — `MostikKit/FocusedField.swift` и `Paster`.

/// Выделение или каретка в поле — в UTF-16, как в AX (`kAXSelectedTextRangeAttribute`).
public struct CaretRange: Equatable, Sendable {
    public var location: Int
    public var length: Int
    public init(location: Int, length: Int) { self.location = location; self.length = length }
}

/// Чем приложение рисует текст. Electron и Gecko получают только ⌘V, без AX-записи (R3),
/// и их элементы в фокусе AX пересоздаёт — сравнивать их по identity нельзя.
public enum AppTextEngine: String, Equatable, Sendable {
    case native, electron, gecko
}

/// Значение поля и каретка. Сравниваются при проверке вставки (R2) и перед откатом (R4).
public struct FieldState: Equatable, Sendable {
    public var value: String
    public var selection: CaretRange
    public init(value: String, selection: CaretRange) { self.value = value; self.selection = selection }
}

public enum Editability: Equatable, Sendable { case yes, no, unknown }

/// Снимок поля в фокусе (R1). Всё, что AX не отдал, — nil: это «неизвестно», а не «нет».
public struct FieldSnapshot: Equatable, Sendable {
    public var bundleID: String
    /// Идентичность элемента (CFHash AXUIElement); nil — элемента нет или не прочитан.
    public var elementToken: Int?
    public var role: String?
    public var subrole: String?
    /// Можно ли записать `AXValue`: признак редактируемого поля. Сами мы туда не пишем.
    public var valueSettable: Bool?
    public var value: String?
    public var selection: CaretRange?
    public var engine: AppTextEngine

    public init(bundleID: String, elementToken: Int? = nil, role: String? = nil, subrole: String? = nil,
                valueSettable: Bool? = nil, value: String? = nil, selection: CaretRange? = nil,
                engine: AppTextEngine = .native) {
        self.bundleID = bundleID; self.elementToken = elementToken; self.role = role; self.subrole = subrole
        self.valueSettable = valueSettable; self.value = value; self.selection = selection; self.engine = engine
    }

    public var isSecure: Bool { subrole == "AXSecureTextField" || role == "AXSecureTextField" }

    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    static let nonTextRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXMenuItem", "AXMenuButton", "AXPopUpButton", "AXSlider",
        "AXList", "AXOutline", "AXTable", "AXRow", "AXCell", "AXImage", "AXLink", "AXTabGroup", "AXToolbar",
        "AXDisclosureTriangle", "AXIncrementor", "AXColorWell", "AXBrowser",
    ]

    /// «Нет» — только когда AX уверенно назвал не-текстовую роль: Electron и терминалы часто
    /// отдают пустой или странный фокус, и там вставка должна идти как раньше.
    public var editable: Editability {
        guard let role else { return .unknown }
        if Self.textRoles.contains(role) || valueSettable == true { return .yes }
        if Self.nonTextRoles.contains(role) { return .no }
        return .unknown
    }

    public var state: FieldState? {
        guard let value, let selection else { return nil }
        return FieldState(value: value, selection: selection)
    }

    /// Символ слева от каретки; nil — каретка в начале поля или поле не прочитано.
    public var characterBeforeCaret: Character? {
        guard let value, let selection, selection.location > 0, selection.location <= value.utf16.count else { return nil }
        let index = String.Index(utf16Offset: selection.location, in: value)
        return value[..<index].last
    }
}

// MARK: R1 — решение о доставке

/// Почему текст оставлен в буфере, а не вставлен. `rawValue` — в `PasteOutcome.clipboard(reason:)`.
public enum DeliveryReason: String, Equatable, Sendable {
    case focusChanged = "focus_changed"
    case notEditable = "not_editable"
    case noAccessibility = "no_accessibility"
    case notInserted = "not_inserted"
}

public enum DeliveryDecision: Equatable, Sendable {
    /// Вставить ⌘V; `text` — уже с пробелом на стыке.
    case paste(text: String)
    case clipboard(DeliveryReason)
    /// Поле пароля или Secure Input: не вставляем и буфер не трогаем.
    case secureField
}

public enum DeliveryPlanner {
    /// - Parameters:
    ///   - start: снимок поля в начале записи; `now` — перед вставкой.
    ///   - expectedBundleID: приложение, которое было впереди в начале записи; nil — не сверяем (H3).
    ///   - canPost: есть Accessibility и право слать нажатия.
    public static func decide(text: String, start: FieldSnapshot?, now: FieldSnapshot?, expectedBundleID: String?,
                              frontBundleID: String?, secureInput: Bool, canPost: Bool) -> DeliveryDecision {
        if secureInput || now?.isSecure == true { return .secureField }
        if let expected = expectedBundleID, !expected.isEmpty, frontBundleID != expected { return .clipboard(.focusChanged) }
        guard canPost else { return .clipboard(.noAccessibility) }
        if let start, let now, start.bundleID == now.bundleID, start.engine == .native,
           let a = start.elementToken, let b = now.elementToken, a != b {
            return .clipboard(.focusChanged)
        }
        if now?.editable == .no { return .clipboard(.notEditable) }
        return .paste(text: Joint.join(text, after: now?.characterBeforeCaret))
    }
}

/// Пробел на стыке с текстом слева от каретки.
public enum Joint {
    /// После них пробел не нужен: пробелы, открывающие скобки и кавычки, слэш, дефис.
    static let openers: Set<Character> = ["(", "[", "{", "«", "„", "“", "‘", "\"", "'", "/", "\\", "-", "@", "#", "\u{00A0}"]
    /// С них текст прилипает к предыдущему: знаки препинания и закрывающие скобки.
    static let closers: Set<Character> = [".", ",", ";", ":", "!", "?", "…", ")", "]", "}", "»", "”", "’", "%"]

    public static func needsSpace(after previous: Character?, text: String) -> Bool {
        guard let previous, !previous.isWhitespace, !openers.contains(previous) else { return false }
        guard let first = text.first, !first.isWhitespace, !closers.contains(first) else { return false }
        return true
    }

    public static func join(_ text: String, after previous: Character?) -> String {
        needsSpace(after: previous, text: text) ? " " + text : text
    }
}

// MARK: R2 — проверка вставки

/// «Дошло / не дошло / неизвестно». `rawValue` — поле `pasteCheck` в истории.
public enum PasteCheck: String, Equatable, Sendable {
    case confirmed
    case notInserted = "not_inserted"
    case unknown
}

public enum PasteVerifier {
    /// Одно перечитывание поля после ⌘V.
    /// «Не дошло» — только если значение и каретка не изменились вовсе: всё прочее
    /// (поле не прочитать, приложение переформатировало текст) — «неизвестно».
    public static func judge(before: FieldState?, after: FieldState?, text: String) -> PasteCheck {
        guard let before, let after else { return .unknown }
        if before == after { return .notInserted }
        let probe = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        if !probe.isEmpty, after.value.contains(probe), !before.value.contains(probe) || after.value.count > before.value.count {
            return .confirmed
        }
        let grown = after.value.utf16.count - before.value.utf16.count
        if grown > 0, grown == text.utf16.count - before.selection.length { return .confirmed }
        return .unknown
    }

    /// Два перечитывания: вставка в Electron и вебе доходит не сразу.
    public static func combine(_ first: PasteCheck, _ second: PasteCheck) -> PasteCheck {
        if first == .confirmed || second == .confirmed { return .confirmed }
        if first == .notInserted, second == .notInserted { return .notInserted }
        return .unknown
    }
}

// MARK: R4, A7 — откат

/// Что вставили последним и каким было поле до и после — для отката (R4) и Esc (A7).
public struct InsertionRecord: Equatable, Sendable {
    public var entryID: String
    public var bundleID: String
    public var elementToken: Int?
    public var engine: AppTextEngine
    public var before: FieldState?
    public var after: FieldState?
    public var insertedText: String
    /// Исходник: сырая расшифровка, а без неё — вставленный текст.
    public var rawText: String
    public var at: Date
    public var check: PasteCheck

    public init(entryID: String, bundleID: String, elementToken: Int? = nil, engine: AppTextEngine = .native,
                before: FieldState? = nil, after: FieldState? = nil, insertedText: String, rawText: String,
                at: Date = Date(), check: PasteCheck = .unknown) {
        self.entryID = entryID; self.bundleID = bundleID; self.elementToken = elementToken; self.engine = engine
        self.before = before; self.after = after; self.insertedText = insertedText; self.rawText = rawText
        self.at = at; self.check = check
    }
}

/// Почему откат не сделан и исходник ушёл в буфер.
public enum RevertRefusal: String, Equatable, Sendable {
    case expired, focusChanged = "focus_changed", fieldChanged = "field_changed", unreadable
}

public enum RevertPlan: Equatable, Sendable {
    /// Откатывать нечего: вставки не было или она не дошла.
    case nothing
    /// Поле ровно такое, каким его оставила вставка: ⌘Z приложения.
    case undo
    /// Поле трогали — откат испортил бы чужое: исходник в буфер.
    case clipboard(text: String, reason: RevertRefusal)
}

public enum RevertPlanner {
    /// Сколько живёт возможность отката сочетанием.
    public static let window: TimeInterval = 120
    /// Сколько после вставки Esc означает «верни как было» (A7).
    public static let escapeWindow: TimeInterval = 3

    public static func plan(_ record: InsertionRecord?, current: FieldSnapshot?, frontBundleID: String?,
                            now: Date = Date()) -> RevertPlan {
        guard let record, record.check != .notInserted else { return .nothing }
        let source = record.rawText.isEmpty ? record.insertedText : record.rawText
        if now.timeIntervalSince(record.at) > window { return .clipboard(text: source, reason: .expired) }
        if frontBundleID != record.bundleID { return .clipboard(text: source, reason: .focusChanged) }
        if record.engine == .native, let a = record.elementToken, let b = current?.elementToken, a != b {
            return .clipboard(text: source, reason: .focusChanged)
        }
        guard let after = record.after, let state = current?.state else {
            return .clipboard(text: source, reason: .unreadable)
        }
        return state == after ? .undo : .clipboard(text: source, reason: .fieldChanged)
    }

    /// Esc после вставки откатывает её, только пока свежо и вставка не провалилась.
    public static func escapeReverts(_ record: InsertionRecord?, now: Date = Date()) -> Bool {
        guard let record, record.check != .notInserted else { return false }
        let age = now.timeIntervalSince(record.at)
        return age >= 0 && age <= escapeWindow
    }

    /// ⌘Z сработал, если значение вернулось к тому, что было до вставки.
    public static func undoWorked(before: FieldState?, now: FieldState?) -> Bool {
        guard let before, let now else { return false }
        return before.value == now.value
    }
}

// MARK: R5 — восстановление

public enum RecentDictations {
    /// Последние диктовки, которые есть чем восстановить: текст или аудио; новые первыми.
    public static func recoverable(_ entries: [HistoryEntry], now: Date = Date(), limit: Int = 3,
                                   window: TimeInterval = 86_400) -> [HistoryEntry] {
        let fresh = entries.filter { entry in
            let age = now.timeIntervalSince(entry.createdAt)
            return age <= window && (!entry.text.isEmpty || entry.audioPath != nil)
        }
        return Array(fresh.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    /// Пункт блока «За сутки» в меню: диктовка или записанная встреча.
    public enum Item<Meeting> {
        case dictation(HistoryEntry)
        case meeting(Meeting)
    }

    /// Диктовки и встречи за сутки вперемешку, новые первыми (решение автора).
    /// Встречу задаёт её начало; `include` отсекает лишние — например, идущую запись.
    public static func withMeetings<Meeting>(_ entries: [HistoryEntry], meetings: [Meeting],
                                             startedAt: (Meeting) -> Date,
                                             include: (Meeting) -> Bool = { _ in true },
                                             now: Date = Date(), limit: Int = 4,
                                             window: TimeInterval = 86_400) -> [Item<Meeting>] {
        let dictations = recoverable(entries, now: now, limit: limit, window: window)
            .map { (date: $0.createdAt, item: Item<Meeting>.dictation($0)) }
        let fresh = meetings.filter { meeting in
            let age = now.timeIntervalSince(startedAt(meeting))
            return age >= 0 && age <= window && include(meeting)
        }.map { (date: startedAt($0), item: Item<Meeting>.meeting($0)) }
        return (dictations + fresh).sorted { $0.date > $1.date }.prefix(limit).map(\.item)
    }

    /// Что вставлять повторно (H3): последняя диктовка с текстом. Отклонённую вставку в поле пароля —
    /// никогда, даже если запись старая и с текстом (П10 р5 Р5-1л).
    public static func lastWithText(_ entries: [HistoryEntry]) -> HistoryEntry? {
        entries.sorted(by: { $0.createdAt > $1.createdAt })
            .first(where: { !$0.text.isEmpty && $0.outcome != SecureDictation.outcome })
    }
}
