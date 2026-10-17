import Foundation
import MostikCore

/// П10 С7: «только текст» — звук удаляется насовсем, а не в Корзину; обнуляется и при сбое
/// расшифровки (ветка giveUp), и при старте по манифесту.
func runTextOnlyAudioTests() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("mostik-textonly-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }

    func wav(seconds: Double, fill: UInt8 = 0x11) -> Data {
        Data(count: 44) + Data(repeating: fill, count: Int(seconds * Double(LivePCM.sampleRate)) * 2)
    }
    func makeMeeting(_ name: String, spans: [TextOnlyRanges.Span], whole: Bool, transcript: String?) -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try? wav(seconds: 4).write(to: folder.appendingPathComponent("mic.wav"))
        try? wav(seconds: 4).write(to: folder.appendingPathComponent("system.wav"))
        var patch: [String: Any] = ["text_only": TextOnlyRanges.manifestValue(spans, whole: whole)]
        if let transcript { patch["transcript"] = ["status": transcript] }
        MeetingFolder.update(folder, patch)
        return folder
    }

    // Вся встреча «только текст»: файлы стёрты насовсем — их нет ни в папке, ни в Корзине.
    do {
        let folder = makeMeeting("2026-10-11-100000", spans: [.init(start: 0, end: 4)], whole: true, transcript: "done")
        check(TextOnlyAudio.needsPurge(MeetingFolder.readManifest(folder)), "до обнуления — нужно")
        let trashBefore = (try? fm.contentsOfDirectory(atPath: NSHomeDirectory() + "/.Trash"))?.filter { $0.hasPrefix("mic") }.count
        let result = TextOnlyAudio.purge(folder)
        equal(result, .removed(["mic.wav", "system.wav"]))
        equal(MeetingFolder.audioFiles(folder), [], "звука в папке нет")
        let trashAfter = (try? fm.contentsOfDirectory(atPath: NSHomeDirectory() + "/.Trash"))?.filter { $0.hasPrefix("mic") }.count
        equal(trashAfter, trashBefore, "в Корзину ничего не ушло")
        let manifest = MeetingFolder.readManifest(folder)
        let audio = manifest?["audio"] as? [String: Any]
        equal(audio?["kept"] as? Bool, false)
        equal(audio?["reason"] as? String, "text_only")
        check(audio?["removed_at"] != nil, "отметка об удалении")
        check(audio?["trashed_at"] == nil || audio?["trashed_at"] is NSNull, "не «в Корзине»")
        check(!TextOnlyAudio.needsPurge(manifest), "повторно не нужно")
    }

    // Часть встречи: в этих секундах — нули, остальное на месте.
    do {
        let folder = makeMeeting("2026-10-11-110000", spans: [.init(start: 1, end: 2)], whole: false, transcript: "failed")
        check(TextOnlyAudio.needsPurge(MeetingFolder.readManifest(folder)), "сбой расшифровки — тоже обнуляем")
        equal(TextOnlyAudio.purge(folder), .silenced)
        let data = (try? Data(contentsOf: folder.appendingPathComponent("mic.wav"))) ?? Data()
        let second = LivePCM.sampleRate * 2
        check(data[44 + second..<44 + 2 * second].allSatisfy { $0 == 0 }, "секунда 1–2 — тишина")
        check(data[44..<44 + second].allSatisfy { $0 == 0x11 }, "до неё звук на месте")
        check(data[44 + 2 * second..<data.count].allSatisfy { $0 == 0x11 }, "после — тоже")
        check(!TextOnlyAudio.needsPurge(MeetingFolder.readManifest(folder)), "silenced_at записан")
    }

    // Расшифровка ещё впереди (в очереди или идёт) — звук нужен, не трогаем.
    do {
        for status in ["pending", "processing"] {
            let folder = makeMeeting("2026-10-11-12000\(status.count)", spans: [.init(start: 0, end: 4)], whole: true,
                                     transcript: status)
            check(!TextOnlyAudio.needsPurge(MeetingFolder.readManifest(folder)), status)
        }
        // Без «только текст» — не наше дело.
        check(!TextOnlyAudio.needsPurge(["transcript": ["status": "done"]]))
        check(!TextOnlyAudio.needsPurge(nil))
    }
}
