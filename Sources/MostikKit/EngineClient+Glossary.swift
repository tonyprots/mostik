import Foundation
import MostikCore

/// Личный словарь: обучение на правках (L1), «Запомнить написание» (L2), импорт (L6).
extension EngineClient {
    /// Пара «вставлено → стало» после правки в поле; ответ — готовые предложения.
    public func learnEdit(inserted: String, edited: String, language: String?) async throws -> [GlossarySuggestion] {
        let reply = try await request("learn_edit", fields: [
            "inserted": .string(inserted), "edited": .string(edited),
            "language": language.map { .string($0) } ?? .null,
        ], timeout: 15)
        return GlossarySuggestion.parse(reply["suggestions"])
    }

    public func learnSuggestions() async throws -> [GlossarySuggestion] {
        GlossarySuggestion.parse(try await request("learn_suggestions", timeout: 15)["suggestions"])
    }

    /// Ответ на предложение: «Запомнить» кладёт пару в словарь, «Нет» — не предлагать 7 дней.
    public func learnDecide(_ suggestion: GlossarySuggestion, accept: Bool) async throws -> [GlossarySuggestion] {
        let reply = try await request("learn_decide", fields: [
            "heard": .string(suggestion.heard), "canonical": .string(suggestion.canonical),
            "language": suggestion.language.map { .string($0) } ?? .null, "accept": .bool(accept),
        ], timeout: 15)
        return GlossarySuggestion.parse(reply["suggestions"])
    }

    /// «Запомнить написание» с языком диктовки (L2): `remember` без языка пишет для всех языков.
    public func remember(heard: String, canonical: String, language: String?) async throws {
        _ = try await request("remember", fields: [
            "heard": .string(heard), "canonical": .string(canonical),
            "language": language.map { .string($0) } ?? .null,
        ], timeout: 15)
    }

    /// Отклонённая подсказка к слову под вопросом (C5): движок больше не предлагает эту пару
    /// и не копит её из правок.
    public func rejectDoubt(heard: String, suggestion: String) async throws {
        _ = try await request("doubt_reject", fields: [
            "heard": .string(heard), "suggestion": .string(suggestion),
        ], timeout: 15)
    }

    /// Какие приложения для импорта есть на диске — по метаданным, без чтения.
    public func glossaryImportDetect() async throws -> [String: Bool] {
        let reply = try await request("glossary_import", fields: ["source": .string("detect")], timeout: 15)
        guard case .object(let found)? = reply["detected"] else { return [:] }
        return found.compactMapValues(\.boolValue)
    }

    /// Просмотр (`apply: false`) или запись импорта.
    public func glossaryImport(source: String, path: String? = nil, text: String? = nil,
                               apply: Bool) async throws -> GlossaryImportPreview {
        var fields: [String: JSONValue] = ["source": .string(source), "apply": .bool(apply)]
        if let path { fields["path"] = .string(path) }
        if let text { fields["text"] = .string(text) }
        let reply = try await request("glossary_import", fields: fields, timeout: 60)
        return GlossaryImportPreview(payload: reply, path: path, text: text)
    }
}
