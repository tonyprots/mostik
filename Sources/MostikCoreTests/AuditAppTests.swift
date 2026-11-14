import Foundation
import MostikCore

/// Аудит 2026-11-14: пометки встречи переживают падение и выход (`MeetingMarksFile`).
func runAuditAppTests() {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mostik-marks-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    equal(MeetingMarksFile.load(from: folder), [], "нет файла — пусто")
    MeetingMarksFile.save([], in: folder)
    check(!FileManager.default.fileExists(atPath: MeetingMarksFile.url(in: folder).path), "пустой набор файл не создаёт")

    let marks = [MeetingMarkPayload(at: 12.34, text: "решили про бюджет"), MeetingMarkPayload(at: 61, text: "«кавычки» и\nперенос")]
    MeetingMarksFile.save(marks, in: folder)
    let loaded = MeetingMarksFile.load(from: folder)
    equal(loaded.count, 2)
    equal(loaded.first?.at, 12.3, "время — до десятых, как в команде движку")
    equal(loaded.last?.text, "«кавычки» и\nперенос")

    try? Data("{\"marks\": [{\"at\": \"x\", \"text\": \"a\"}, {\"at\": 5, \"text\": \"\"}, {\"at\": 7, \"text\": \"ок\"}]}".utf8)
        .write(to: MeetingMarksFile.url(in: folder))
    equal(MeetingMarksFile.load(from: folder), [MeetingMarkPayload(at: 7, text: "ок")], "битые записи пропускаются")
    try? Data("не json".utf8).write(to: MeetingMarksFile.url(in: folder))
    equal(MeetingMarksFile.load(from: folder), [], "нечитаемый файл — пусто")
}
