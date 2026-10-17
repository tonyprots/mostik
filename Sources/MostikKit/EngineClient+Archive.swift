import Foundation
import MostikCore

/// Команды архива встреч (M18, W1, W3, W6) — обычный ответ с тем же id. Чувствительные встречи движок не отдаёт.
extension EngineClient {
    /// Бриф к событию календаря (W1); `write` — сохранить в `briefs/`.
    public func archiveBrief(event: CalendarEvent, write: Bool) async throws -> ArchiveBrief? {
        let iso = ISO8601DateFormatter()
        let reply = try await request("archive_brief", fields: [
            "event": .object([
                "id": .string(event.id),
                "title": .string(event.title),
                "start": .string(iso.string(from: event.start)),
                "end": .string(iso.string(from: event.end)),
                "attendees": .array(event.attendees.map { .string($0) }),
            ]),
            "write": .bool(write),
        ], timeout: 60)
        return ArchiveBrief(payload: reply)
    }

    public func archivePeople(write: Bool = false) async throws -> [ArchivePerson] {
        ArchivePerson.list(payload: try await request("archive_people", fields: ["write": .bool(write)], timeout: 60))
    }

    /// Сводка: `week` или `series` с ключом серии (W6).
    public func archiveDigest(kind: String, series: String? = nil, write: Bool) async throws -> ArchiveDigest? {
        var fields: [String: JSONValue] = ["kind": .string(kind), "write": .bool(write)]
        if let series { fields["series"] = .string(series) }
        return ArchiveDigest(payload: try await request("archive_digest", fields: fields, timeout: 60))
    }

    /// Пересобрать устаревшие карточки встреч (`card.md`, M18).
    public func archiveCards() async throws {
        _ = try await request("archive_cards", timeout: 120)
    }
}
