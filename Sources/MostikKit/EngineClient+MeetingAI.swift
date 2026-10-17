import Foundation
import MostikCore

/// ИИ встреч (M5–M7): `meeting_ai` → события `progress` (task `meeting_ai`) и `meeting_ai_done` с тем же id.
extension EngineClient {
    /// Встреча ждёт в очереди движка конца расшифровки других встреч и диктовки — таймаут с большим запасом.
    public static let meetingAITimeout: TimeInterval = 3 * 3600

    @discardableResult
    public func meetingAI(folder: URL, mode: MeetingAIMode, language: String,
                          backend: PolishBackend) async throws -> [String: JSONValue] {
        try await meetingAI(folder: folder, mode: mode, language: language, backend: backend, options: .init())
    }

    /// Как сделать сводку: шаблон (M16), вид (W22) или своё описание словами, свои записи (W23).
    public struct MeetingAIOptions: Sendable {
        /// `nil` или `auto` — по событию календаря.
        public var template: String?
        /// Дополнительная сводка: id шаблона (`protocol`, `exec`, `decisions`) или `custom`.
        public var variant: String?
        public var instruction: String?
        public var useNotes: Bool
        public init(template: String? = nil, variant: String? = nil, instruction: String? = nil, useNotes: Bool = true) {
            self.template = template; self.variant = variant; self.instruction = instruction; self.useNotes = useNotes
        }
    }

    @discardableResult
    public func meetingAI(folder: URL, mode: MeetingAIMode, language: String, backend: PolishBackend,
                          options: MeetingAIOptions) async throws -> [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "folder": .string(folder.path),
            "mode": .string(mode.rawValue),
            "language": .string(language),
            "backend": .string(backend.rawValue),
            "use_notes": .bool(options.useNotes),
        ]
        if let template = options.template { fields["template"] = .string(template) }
        if let variant = options.variant { fields["variant"] = .string(variant) }
        if let instruction = options.instruction { fields["instruction"] = .string(instruction) }
        return try await request("meeting_ai", fields: fields, timeout: Self.meetingAITimeout)
    }

    /// Рецепт после встречи (W7): та же очередь движка; ответ `{status, path, text, subject, body}`.
    @discardableResult
    public func meetingRecipe(folder: URL, recipe: String, language: String, backend: PolishBackend,
                              useNotes: Bool) async throws -> [String: JSONValue] {
        try await request("meeting_recipe", fields: [
            "folder": .string(folder.path),
            "recipe": .string(recipe),
            "language": .string(language),
            "backend": .string(backend.rawValue),
            "use_notes": .bool(useNotes),
        ], timeout: Self.meetingAITimeout)
    }

    /// Шаблоны и рецепты (встроенные и свои); `folder` — какой шаблон выбрался бы сам; `ensure` — создать свои папки.
    public func meetingTemplates(folder: URL? = nil, ensure: Bool = false) async throws -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["ensure": .bool(ensure)]
        if let folder { fields["folder"] = .string(folder.path) }
        return try await request("meeting_templates", fields: fields, timeout: 30)
    }
}
