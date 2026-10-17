import Foundation
import MostikCore

/// Папка встречи (M10): миграция старых встреч и перегенерация `meeting.md` — `docs/meeting-folder.md`.
extension EngineClient {
    /// Старым папкам — `manifest.json` и `meeting.md`; файлы не переписываются. Ответ: scanned, migrated, errors.
    @discardableResult
    public func meetingsMigrate(root: URL? = nil) async throws -> [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        if let root { fields["root"] = .string(root.path) }
        return try await request("meetings_migrate", fields: fields, timeout: 120)
    }
}
