import Foundation
import MostikCore

/// Решение автора (П10): звук диктовок хранится 1 день, `keepAudio` по умолчанию включён,
/// запись истории живёт свой срок (`retentionDays`), без звука.
func runDictationAudioRetentionTests() {
    let fm = FileManager.default
    equal(MostikSettings.dictationAudioDays, 1, "звук диктовок — 1 день")
    check(MostikSettings().keepAudio, "keepAudio остаётся включённым")
    equal(MostikSettings().retentionDays, 7, "срок истории не меняется")

    let dir = fm.temporaryDirectory.appendingPathComponent("mostik-audio-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: dir) }
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = HistoryStore(fileURL: dir.appendingPathComponent("history.jsonl"))
    let now = Date()
    func wav(_ name: String) -> String {
        let path = dir.appendingPathComponent(name).path
        fm.createFile(atPath: path, contents: Data([1])); return path
    }
    let fresh = wav("fresh.wav"), dayOld = wav("day.wav"), weekOld = wav("week.wav")
    try? store.append(HistoryEntry(id: "fresh", createdAt: now.addingTimeInterval(-3600), text: "a", audioPath: fresh))
    try? store.append(HistoryEntry(id: "day", createdAt: now.addingTimeInterval(-26 * 3600), text: "b", audioPath: dayOld))
    try? store.append(HistoryEntry(id: "week", createdAt: now.addingTimeInterval(-8 * 86_400), text: "c", audioPath: weekOld))

    let dropped = (try? store.prune(retention: 7 * 86_400, audioRetention: TimeInterval(MostikSettings.dictationAudioDays) * 86_400, now: now)) ?? -1
    equal(dropped, 1, "запись старше 7 дней удалена")
    check(fm.fileExists(atPath: fresh), "звук за последние сутки на месте")
    check(!fm.fileExists(atPath: dayOld), "звук старше суток удалён")
    check(!fm.fileExists(atPath: weekOld), "звук удалённой записи удалён")
    let left = Dictionary(uniqueKeysWithValues: store.load().map { ($0.id, $0) })
    equal(left.keys.sorted(), ["day", "fresh"])
    equal(left["day"]?.text, "b", "текст записи остаётся")
    check(left["day"]?.audioPath == nil, "у записи без звука нет пути")
    equal(left["fresh"]?.audioPath, fresh)
}

/// П10, инфо: `prune` удаляет звук только внутри своей папки записей — путь из подложенной истории не трогает.
func runHistoryPruneScopeTests() {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("mostik-prune-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: dir) }
    let recordings = dir.appendingPathComponent("recordings", isDirectory: true)
    let outside = dir.appendingPathComponent("elsewhere", isDirectory: true)
    try? fm.createDirectory(at: recordings, withIntermediateDirectories: true)
    try? fm.createDirectory(at: outside, withIntermediateDirectories: true)
    let own = recordings.appendingPathComponent("a.wav").path
    let foreign = outside.appendingPathComponent("important.doc").path
    let sneaky = recordings.appendingPathComponent("../elsewhere/sneaky.doc").path
    for path in [own, foreign, sneaky] { fm.createFile(atPath: path, contents: Data([1])) }
    let store = HistoryStore(fileURL: dir.appendingPathComponent("history.jsonl"), audioRoot: recordings)
    let old = Date().addingTimeInterval(-30 * 86_400)
    try? store.append(HistoryEntry(id: "own", createdAt: old, text: "a", audioPath: own))
    try? store.append(HistoryEntry(id: "foreign", createdAt: old, text: "b", audioPath: foreign))
    try? store.append(HistoryEntry(id: "sneaky", createdAt: old, text: "c", audioPath: sneaky))
    _ = try? store.prune(retention: 86_400)
    check(!fm.fileExists(atPath: own), "свой звук удалён")
    check(fm.fileExists(atPath: foreign), "файл вне recordings/ не тронут")
    check(fm.fileExists(atPath: outside.appendingPathComponent("sneaky.doc").path), "../ из recordings/ не выводит")
}
