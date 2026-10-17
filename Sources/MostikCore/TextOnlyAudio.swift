import Foundation

/// П10 С7: «только текст» (W15) обещает «звук записи не хранится». Поэтому после расшифровки —
/// и после сбоя, когда дорасшифровки уже не будет, — звук этих отрезков стирается насовсем:
/// вся встреча — файлы удаляются (`removeItem`, не Корзина), часть — на месте пишутся нули.
public enum TextOnlyAudio {
    public enum Result: Equatable, Sendable {
        case nothing
        /// Вся встреча шла «только текст»: удалённые файлы.
        case removed([String])
        /// Отрезки затёрты тишиной.
        case silenced
    }

    static let header = 44

    /// Есть ли что стирать: отрезки «только текст» есть, звук ещё не стирали и расшифровка
    /// уже не понадобится (готова или окончательно не удалась).
    public static func needsPurge(_ manifest: [String: Any]?) -> Bool {
        guard let manifest, let block = TextOnlyRanges.fromManifest(manifest), !block.spans.isEmpty else { return false }
        let raw = manifest["text_only"] as? [String: Any]
        if raw?["silenced_at"] != nil { return false }
        let audio = manifest["audio"] as? [String: Any]
        if audio?["kept"] as? Bool == false { return false }
        let transcript = (manifest["transcript"] as? [String: Any])?["status"] as? String
        return transcript == "done" || transcript == "failed"
    }

    /// Стереть звук отрезков «только текст» по манифесту папки.
    @discardableResult
    public static func purge(_ folder: URL, now: Date = Date()) -> Result {
        let manifest = MeetingFolder.readManifest(folder)
        guard let block = TextOnlyRanges.fromManifest(manifest), !block.spans.isEmpty else { return .nothing }
        let fm = FileManager.default
        if block.whole {
            var removed: [String] = []
            for name in MeetingFolder.audioFiles(folder) {
                if (try? fm.removeItem(at: folder.appendingPathComponent(name))) != nil { removed.append(name) }
            }
            MeetingFolder.update(folder, ["audio": ["kept": false, "removed_at": MeetingFolder.iso(now),
                                                    "removed": removed, "reason": "text_only"],
                                          "text_only": ["silenced_at": MeetingFolder.iso(now)]], now: now)
            return .removed(removed)
        }
        var segments = MeetingSegment.fromManifest(manifest)
        if segments.isEmpty {
            segments = MeetingWatchdog.Track.allCases.map { MeetingSegment(track: $0, file: "\($0.rawValue).wav", offset: 0) }
        }
        for segment in segments {
            let url = folder.appendingPathComponent(segment.file)
            let seconds = Double(dataBytes(url)) / Double(LivePCM.sampleRate * 2)
            let ranges = TextOnlyRanges.byteRanges(block.spans, segmentOffset: segment.offset, segmentSeconds: seconds)
            zero(url, ranges: ranges)
        }
        MeetingFolder.update(folder, ["text_only": ["silenced_at": MeetingFolder.iso(now)]], now: now)
        return .silenced
    }

    /// Байт данных PCM после 44-байтного заголовка (растущий файл — по размеру).
    public static func dataBytes(_ url: URL) -> Int {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return max(0, size - header) & ~1
    }

    /// Обнулить диапазоны данных на месте; размер и заголовок не меняются.
    @discardableResult
    public static func zero(_ url: URL, ranges: [Range<Int>]) -> Bool {
        guard !ranges.isEmpty else { return true }
        guard let handle = try? FileHandle(forWritingTo: url) else { return false }
        defer { try? handle.close() }
        let limit = dataBytes(url)
        let block = Data(count: 64 * 1024)
        for range in ranges {
            var at = max(0, range.lowerBound)
            let end = min(range.upperBound, limit)
            while at < end {
                let n = min(block.count, end - at)
                guard (try? handle.seek(toOffset: UInt64(header + at))) != nil,
                      (try? handle.write(contentsOf: block.prefix(n))) != nil else { return false }
                at += n
            }
        }
        return true
    }
}
