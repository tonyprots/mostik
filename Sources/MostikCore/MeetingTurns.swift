import Foundation

/// Реплика `transcript.json` с концом — для фрагментов (W9) и метрик говорения (W11).
public struct SpeechTurn: Equatable, Sendable {
    public var index: Int
    public var speaker: String
    public var start: Double
    public var end: Double
    public var text: String

    public init(index: Int, speaker: String, start: Double, end: Double, text: String) {
        self.index = index; self.speaker = speaker; self.start = start; self.end = max(start, end); self.text = text
    }

    public var seconds: Double { max(0, end - start) }

    /// Реплики из `transcript.json` (`turns`; у старых — `segments`/`lines` или массив).
    public static func parse(_ data: Data) -> [SpeechTurn] {
        guard let value = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let raw: [[String: Any]]
        if let dict = value as? [String: Any] {
            raw = (dict["turns"] as? [[String: Any]]) ?? (dict["segments"] as? [[String: Any]])
                ?? (dict["lines"] as? [[String: Any]]) ?? []
        } else {
            raw = value as? [[String: Any]] ?? []
        }
        func number(_ v: Any?) -> Double { (v as? Double) ?? (v as? NSNumber)?.doubleValue ?? 0 }
        return raw.enumerated().compactMap { index, item in
            guard let text = item["text"] as? String else { return nil }
            let start = number(item["start"])
            return SpeechTurn(index: index, speaker: item["speaker"] as? String ?? "", start: start,
                              end: item["end"] == nil ? start : number(item["end"]), text: text)
        }
    }
}

/// Метрики говорения только для себя (W11): моя доля, самый длинный монолог, сколько вопросов задал.
/// Других участников не оцениваем и не показываем.
public struct SpeakingMetrics: Equatable, Sendable {
    public static let me = "Я"

    /// Доля моей речи во всей речи встречи, 0…1.
    public var share: Double
    public var mySeconds: Double
    public var longestMonologue: Double
    /// Начало самого длинного монолога — чтобы к нему прыгнуть.
    public var longestAt: Double
    public var questions: Int

    public init(share: Double, mySeconds: Double, longestMonologue: Double, longestAt: Double, questions: Int) {
        self.share = share; self.mySeconds = mySeconds; self.longestMonologue = longestMonologue
        self.longestAt = longestAt; self.questions = questions
    }

    /// nil — меня в расшифровке нет (микрофон молчал) или речи нет совсем.
    public static func compute(_ turns: [SpeechTurn], me: String = me) -> SpeakingMetrics? {
        let speech = turns.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        let total = speech.reduce(0) { $0 + $1.seconds }
        let mine = speech.filter { $0.speaker == me }
        guard total > 0, !mine.isEmpty else { return nil }
        let mySeconds = mine.reduce(0) { $0 + $1.seconds }
        // Монолог — мои реплики подряд, пока никто другой не начал говорить.
        var longest = 0.0, longestAt = 0.0
        var runStart: Double?, runEnd = 0.0
        for turn in speech.sorted(by: { $0.start < $1.start }) {
            if turn.speaker == me {
                if runStart == nil { runStart = turn.start }
                runEnd = max(runEnd, turn.end)
            } else {
                close(&runStart, runEnd, &longest, &longestAt)
                runEnd = 0
            }
        }
        close(&runStart, runEnd, &longest, &longestAt)
        let questions = mine.reduce(0) { $0 + questionCount($1.text) }
        return SpeakingMetrics(share: min(1, mySeconds / total), mySeconds: mySeconds,
                               longestMonologue: longest, longestAt: longestAt, questions: questions)
    }

    private static func close(_ runStart: inout Double?, _ runEnd: Double, _ longest: inout Double, _ at: inout Double) {
        guard let start = runStart else { return }
        if runEnd - start > longest { longest = runEnd - start; at = start }
        runStart = nil
    }

    /// Вопросы — предложения со знаком «?»; «??» и «?!» — один вопрос.
    public static func questionCount(_ text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: #"\?+[!?]*"#) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }
}

/// Фрагмент для пересылки (W9): отрезок аудио + текст из выделенных реплик. Никуда не отправляется.
public struct MeetingClipPlan: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var stem: String
    public var markdown: String

    public static let padding: Double = 0.5

    /// - Parameters:
    ///   - selected: выделенные реплики (говорящий, начало, текст) в порядке расшифровки.
    ///   - turns: все реплики с концами — из них берём конец последней выделенной.
    public static func make(selected: [(speaker: String, start: Double, text: String)], turns: [SpeechTurn],
                            title: String, date: Date?, duration: Double, audioFile: String?,
                            language: String = "ru") -> MeetingClipPlan? {
        guard let first = selected.first, let last = selected.last else { return nil }
        let lastTurn = turns.first { $0.speaker == last.speaker && abs($0.start - last.start) < 0.01 }
            ?? turns.first { abs($0.start - last.start) < 0.01 }
        let rawEnd = lastTurn?.end ?? (turns.first { $0.start > last.start + 0.01 }?.start ?? last.start + 5)
        let start = max(0, first.start - padding)
        var end = rawEnd + padding
        if duration > 0 { end = min(end, duration) }
        guard end > start else { return nil }
        let stem = "\(fileClock(start))-\(fileClock(end))"
        let en = language == "en"
        var lines = ["# \(en ? "Clip" : "Фрагмент"): \(title)", ""]
        var meta = "- \(en ? "Meeting" : "Встреча"): "
        if let date {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH:mm"
            meta += f.string(from: date) + " · "
        }
        meta += "\(clock(start))–\(clock(end))"
        lines.append(meta)
        if let audioFile { lines.append("- \(en ? "Audio" : "Аудио"): [\(audioFile)](\(audioFile))") }
        lines.append("")
        for item in selected {
            lines.append("**\(item.speaker)** [\(clock(item.start))] \(item.text)")
            lines.append("")
        }
        return MeetingClipPlan(start: start, end: end, stem: stem,
                               markdown: lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n")
    }

    public static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// Для имени файла: двоеточие в Finder превращается в косую черту.
    static func fileClock(_ seconds: Double) -> String { clock(seconds).replacingOccurrences(of: ":", with: ".") }

    /// Какой кусок какого сегмента брать: (файл, секунда в файле, сколько секунд, куда в фрагменте).
    public struct Piece: Equatable, Sendable {
        public var file: String
        public var fileOffset: Double
        public var length: Double
        public var clipOffset: Double

        public init(file: String, fileOffset: Double, length: Double, clipOffset: Double) {
            self.file = file; self.fileOffset = fileOffset; self.length = length; self.clipOffset = clipOffset
        }
    }

    /// Сегменты дорожки (M12) → куски для отрезка [start, end). Длина сегмента — `lengths[file]` секунд.
    public static func pieces(segments: [MeetingSegment], lengths: [String: Double], start: Double, end: Double) -> [Piece] {
        let sorted = segments.sorted { $0.offset < $1.offset }
        var result: [Piece] = []
        for (i, segment) in sorted.enumerated() {
            let length = lengths[segment.file] ?? 0
            // Следующий сегмент начинается раньше конца этого — хвост этого не берём.
            let next = i + 1 < sorted.count ? sorted[i + 1].offset : .infinity
            let segEnd = min(segment.offset + length, next)
            let from = max(start, segment.offset), to = min(end, segEnd)
            guard to > from else { continue }
            result.append(Piece(file: segment.file, fileOffset: from - segment.offset, length: to - from,
                                clipOffset: from - start))
        }
        return result
    }
}
