import Foundation
import MostikCore

/// Говорящие встречи (M14, M15) — `docs/voice-memory.md`, раздел «Протокол движка».
extension EngineClient {
    /// Голосовая память вкл/выкл. `true` — только после экрана согласия.
    @discardableResult
    public func voicesConfig(enabled: Bool) async throws -> [String: JSONValue] {
        try await request("voices_config", fields: ["enabled": .bool(enabled)], timeout: 10)
    }

    /// Есть ли модель голоса и кого помним (без векторов).
    public func voicesStatus() async throws -> [String: JSONValue] {
        try await request("voices_status", timeout: 20)
    }

    /// Переименовать человека; имя другого — слияние образцов.
    public func voicesRename(person: String, name: String) async throws -> [String: JSONValue] {
        try await request("voices_rename", fields: ["person_id": .string(person), "name": .string(name)], timeout: 10)
    }

    /// «Забыть этого» (`person`) или «забыть всех» (`person == nil`).
    public func voicesForget(person: String?) async throws -> [String: JSONValue] {
        let fields: [String: JSONValue] = person.map { ["person_id": .string($0)] } ?? ["all": .bool(true)]
        return try await request("voices_forget", fields: fields, timeout: 30)
    }

    /// «Стереть отпечатки» при выключении памяти (П10 С8). Движок без `voices_wipe` — «Забыть всех».
    @discardableResult
    public func voicesWipe() async throws -> [String: JSONValue] {
        do {
            return try await request(VoiceMemoryWipe.command, timeout: 30)
        } catch EngineError.engine(let code, let message) where VoiceMemoryWipe.needsFallback(code: code, message: message) {
            return try await voicesForget(person: nil)
        }
    }

    /// Назвать говорящего встречи (все реплики метки).
    @discardableResult
    public func speakerRename(folder: URL, label: String, name: String) async throws -> [String: JSONValue] {
        try await request("speaker_rename", fields: ["folder": .string(folder.path), "label": .string(label),
                                                     "name": .string(name)], timeout: 30)
    }

    /// «Убрать имя» (E1): метка снова «Собеседник N», образец голоса этой встречи снимается с человека.
    @discardableResult
    public func speakerUnname(folder: URL, label: String) async throws -> [String: JSONValue] {
        try await request("speaker_unname", fields: ["folder": .string(folder.path), "label": .string(label)], timeout: 30)
    }

    /// «Это он» — имя из подсказки голосовой памяти.
    @discardableResult
    public func speakerConfirm(folder: URL, label: String) async throws -> [String: JSONValue] {
        try await request("speaker_confirm", fields: ["folder": .string(folder.path), "label": .string(label)], timeout: 30)
    }

    /// «Не он» — подсказка убирается.
    @discardableResult
    public func speakerReject(folder: URL, label: String) async throws -> [String: JSONValue] {
        try await request("speaker_reject", fields: ["folder": .string(folder.path), "label": .string(label)], timeout: 30)
    }

    /// Реплика на проверке: другому говорящему (`label`) или «верно» (`label == nil`).
    @discardableResult
    /// `label` — другая метка, `name` — человек по имени (есть на встрече — к нему, нет — новый говорящий),
    /// оба пустые — «верно».
    public func speakerTurn(folder: URL, turn: Int, label: String?, name: String? = nil) async throws -> [String: JSONValue] {
        try await request("speaker_turn", fields: ["folder": .string(folder.path), "turn": .number(Double(turn)),
                                                   "label": .string(label ?? ""), "name": .string(name ?? "")], timeout: 30)
    }
}
