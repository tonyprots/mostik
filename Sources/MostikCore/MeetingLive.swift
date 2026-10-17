import Foundation

// Встреча по ходу записи и после неё (П6-Б): живая расшифровка (W10), «только текст» (W15),
// продолжение в той же встрече (W16), ремонт говорящих (W17), согласие и предупреждение
// участникам (W19, W20), хоткей (W24), шумо- и эхоподавление (V6), выбор
// системного голоса озвучки (A1). Здесь только решения; платформа — в MostikKit и приложении.

/// Настройки порции. Одно поле в `MostikSettings`, чтобы не толкаться с соседними фичами.
public struct MeetingLiveSettings: Codable, Equatable, Sendable {
    /// W10: расшифровывать встречу кусками по ходу записи (локально, без проверки).
    public var liveTranscript: Bool = true
    /// W15: новая встреча сразу в режиме «только текст» — аудио убирается после расшифровки.
    public var textOnlyDefault: Bool = false
    /// W24: ⌃⌘M — начать или остановить запись встречи из любого приложения.
    public var hotkey: Bool = true
    /// V6: шумо- и эхоподавление Apple на микрофоне встречи: `off` | `speakers` | `always`.
    public var meetingVoiceProcessing: String = VoiceProcessingPolicy.off
    /// V6: шумоподавление Apple при диктовке.
    public var dictationVoiceProcessing: Bool = false
    /// W19: свой текст предупреждения участникам; nil — стандартный.
    public var warningText: String? = nil

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = MeetingLiveSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        liveTranscript = try c.decodeIfPresent(Bool.self, forKey: .liveTranscript) ?? d.liveTranscript
        textOnlyDefault = try c.decodeIfPresent(Bool.self, forKey: .textOnlyDefault) ?? d.textOnlyDefault
        // Автостарт записи звонка убран (решение автора): сохранённый `autoStart` не читается
        // и при следующем сохранении из файла пропадает. Остаются предложение «Записать?» и ⌃⌘M.
        hotkey = try c.decodeIfPresent(Bool.self, forKey: .hotkey) ?? d.hotkey
        let mode = try c.decodeIfPresent(String.self, forKey: .meetingVoiceProcessing) ?? d.meetingVoiceProcessing
        meetingVoiceProcessing = VoiceProcessingPolicy.modes.contains(mode) ? mode : d.meetingVoiceProcessing
        dictationVoiceProcessing = try c.decodeIfPresent(Bool.self, forKey: .dictationVoiceProcessing) ?? d.dictationVoiceProcessing
        warningText = try c.decodeIfPresent(String.self, forKey: .warningText)
    }
}

// MARK: - V6: шумо- и эхоподавление

/// Apple voice processing на входе (`AVAudioInputNode.setVoiceProcessingEnabled`) — это эхо-,
/// шумоподавление и АРУ разом, по отдельности их не включить. Эхоподавление нужно, только
/// когда звонок звучит из динамиков Mac: в наушниках эха нет, а обработка портит голос
/// и приглушает чужой звук (совет quill).
public enum VoiceProcessingPolicy {
    public static let off = "off"
    public static let speakers = "speakers"
    public static let always = "always"
    public static let modes = [off, speakers, always]

    /// Включать ли обработку на микрофоне встречи сейчас.
    public static func meeting(mode: String, outputIsSpeakers: Bool) -> Bool {
        switch mode {
        case always: return true
        case speakers: return outputIsSpeakers
        default: return false
        }
    }
}

// MARK: - W15: «только текст»

/// Отрезки записи (секунды записи без пауз), когда был включён режим «только текст».
/// После расшифровки звук этих отрезков затирается тишиной, а если режим шёл всю встречу —
/// аудио удаляется насовсем, без Корзины (`TextOnlyAudio`, П10 С7).
public struct TextOnlyRanges: Equatable, Sendable {
    public struct Span: Equatable, Sendable {
        public var start: Double
        public var end: Double
        public init(start: Double, end: Double) { self.start = start; self.end = max(start, end) }
    }

    public private(set) var spans: [Span] = []
    public private(set) var openSince: Double?

    public init(spans: [Span] = [], openSince: Double? = nil) {
        self.spans = spans
        self.openSince = openSince
    }

    public var isOn: Bool { openSince != nil }

    /// Включить или выключить режим в секунду записи `t`.
    public mutating func set(_ on: Bool, at t: Double) {
        if on {
            guard openSince == nil else { return }
            openSince = max(0, t)
        } else {
            guard let since = openSince else { return }
            openSince = nil
            if t > since { spans.append(Span(start: since, end: t)) }
        }
    }

    /// Отрезки к концу записи `end`: открытый закрывается, соседние и перекрытые сливаются.
    public func closed(at end: Double) -> [Span] {
        var all = spans
        if let since = openSince, end > since { all.append(Span(start: since, end: end)) }
        return Self.normalized(all)
    }

    public static func normalized(_ spans: [Span]) -> [Span] {
        var result: [Span] = []
        for span in spans.sorted(by: { $0.start < $1.start }) where span.end > span.start {
            if let last = result.last, span.start <= last.end + 0.05 {
                result[result.count - 1].end = max(last.end, span.end)
            } else {
                result.append(span)
            }
        }
        return result
    }

    /// Режим шёл всю встречу (допуск — секунда с краёв): аудио не нужно вовсе.
    public static func coversWhole(_ spans: [Span], duration: Double, slack: Double = 1) -> Bool {
        let merged = normalized(spans)
        guard duration > 0 else { return !merged.isEmpty }
        guard merged.count == 1, let only = merged.first else { return false }
        return only.start <= slack && only.end >= duration - slack
    }

    /// Байтовые отрезки данных PCM16 моно в сегменте, который начинается в секунду `offset`
    /// записи и длится `seconds`: что затереть нулями. Границы кратны двум байтам.
    public static func byteRanges(_ spans: [Span], segmentOffset offset: Double, segmentSeconds seconds: Double,
                                  sampleRate: Int = 16_000) -> [Range<Int>] {
        normalized(spans).compactMap { span in
            let from = max(0, span.start - offset)
            let to = min(seconds, span.end - offset)
            guard to > from else { return nil }
            let a = Int((from * Double(sampleRate)).rounded(.down)) * 2
            let b = Int((to * Double(sampleRate)).rounded(.up)) * 2
            return b > a ? a..<b : nil
        }
    }

    /// Поле манифеста `text_only`.
    public static func manifestValue(_ spans: [Span], whole: Bool) -> [String: Any] {
        ["whole": whole, "spans": normalized(spans).map { [($0.start * 10).rounded() / 10, ($0.end * 10).rounded() / 10] }]
    }

    public static func fromManifest(_ manifest: [String: Any]?) -> (spans: [Span], whole: Bool)? {
        guard let block = manifest?["text_only"] as? [String: Any] else { return nil }
        let raw = block["spans"] as? [[Any]] ?? []
        func number(_ v: Any) -> Double? { (v as? Double) ?? (v as? NSNumber)?.doubleValue }
        let spans = raw.compactMap { pair -> Span? in
            guard pair.count == 2, let a = number(pair[0]), let b = number(pair[1]) else { return nil }
            return Span(start: a, end: b)
        }
        return (spans, block["whole"] as? Bool ?? false)
    }
}

// MARK: - W10: живая расшифровка

/// Где резать звук дорожки на куски для живой расшифровки: по тихому месту, чтобы не рвать слово.
public enum LiveWindow {
    /// Шаг уровней — 100 мс.
    public static let frame: Double = 0.1
    /// Кусок не короче 12 с: короче Whisper теряет контекст.
    public static let minSeconds: Double = 12
    /// И не длиннее 25 с: дальше текст отстаёт от разговора.
    public static let maxSeconds: Double = 25
    /// Тише этого уровня (0…1, −50…0 dBFS) — пауза, можно резать не дожидаясь предела.
    public static let quietLevel: Float = 0.3

    /// Сколько кадров (по 100 мс) отдать в расшифровку из накопленных `levels`; nil — ждать.
    /// `final` — запись остановлена: забрать всё, что есть.
    public static func cut(levels: [Float], final: Bool = false) -> Int? {
        if final { return levels.isEmpty ? nil : levels.count }
        let minFrames = Int(minSeconds / frame)
        let maxFrames = Int(maxSeconds / frame)
        guard levels.count >= minFrames else { return nil }
        let upper = min(levels.count, maxFrames)
        // Самое тихое окно в 300 мс между минимумом и пределом; режем в его середине.
        var best: (index: Int, level: Float)?
        let run = 3
        var i = minFrames
        while i + run <= upper {
            let level = levels[i..<(i + run)].reduce(0, +) / Float(run)
            if best == nil || level < best!.level { best = (i + run / 2, level) }
            i += 1
        }
        if let best, best.level <= quietLevel { return best.index }
        // Тишины нет, а предел достигнут — режем по самому тихому, что нашлось.
        if levels.count >= maxFrames { return best?.index ?? maxFrames }
        return nil
    }
}

/// Строки живой расшифровки: кусок дорожки → строка с говорящим и временем начала.
public struct LiveTranscript: Equatable, Sendable {
    public struct Line: Equatable, Sendable, Identifiable {
        public var id: Int
        /// `mic` → «Я», `system` → «Собеседники»: без диаризации по ходу встречи.
        public var track: String
        public var start: Double
        public var text: String
        public init(id: Int, track: String, start: Double, text: String) {
            self.id = id; self.track = track; self.start = start; self.text = text
        }
    }

    public private(set) var lines: [Line] = []
    private var nextID = 0

    public init() {}

    /// Добавить расшифрованный кусок. Пустой и повтор предыдущего куска той же дорожки — не добавляются.
    @discardableResult
    public mutating func add(track: String, start: Double, text: String) -> Bool {
        let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !clean.isEmpty else { return false }
        if let last = lines.last(where: { $0.track == track }), last.text == clean { return false }
        let line = Line(id: nextID, track: track, start: start, text: clean)
        nextID += 1
        let index = lines.firstIndex { $0.start > start } ?? lines.count
        lines.insert(line, at: index)
        return true
    }

    public static func speaker(_ track: String, russian: Bool) -> String {
        track == "mic" ? (russian ? "Я" : "Me") : (russian ? "Собеседники" : "Others")
    }

    /// Текст для буфера обмена: `[мм:сс] Я: …` построчно.
    public func plainText(russian: Bool) -> String {
        lines.map { "[\(Self.clock($0.start))] \(Self.speaker($0.track, russian: russian)): \($0.text)" }
            .joined(separator: "\n")
    }

    public static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let (h, rest) = total.quotientAndRemainder(dividingBy: 3600)
        let (m, s) = rest.quotientAndRemainder(dividingBy: 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

// MARK: - W16: продолжить запись

public enum MeetingContinuation {
    /// С какой секунды встречи пойдёт продолжение: конец самого длинного сегмента
    /// (смещение + длительность файла) или длительность из манифеста — что больше.
    public static func baseOffset(segments: [MeetingSegment], seconds: (String) -> Double?, manifestDuration: Double?) -> Double {
        let ends = segments.map { $0.offset + (seconds($0.file) ?? 0) }
        return max(ends.max() ?? 0, manifestDuration ?? 0)
    }

    /// Сегменты, с которых начнётся продолжение: следующий номер у каждой дорожки, общее смещение.
    public static func nextSegments(after existing: [MeetingSegment], offset: Double) -> [MeetingSegment] {
        MeetingWatchdog.Track.allCases.map { track in
            let used = existing.filter { $0.track == track }.count
            return MeetingSegment(track: track, file: MeetingSegment.fileName(track, index: max(1, used) + 1), offset: offset)
        }
    }

    /// Сколько после конца встречи предлагать «Продолжить запись»: дольше — это уже другой разговор.
    public static let window: TimeInterval = 15 * 60

    /// Продолжать можно встречу, которая не пишется и у которой аудио на месте.
    /// `latest` и `endedAt` — только последняя встреча и только вскоре после конца
    /// (плашка висела на трёх старых встречах, хотя человек уже на другой).
    public static func allowed(recording: Bool, audioKept: Bool, hasAudio: Bool,
                               latest: Bool = true, endedAt: Date? = nil, now: Date = Date()) -> Bool {
        guard !recording, audioKept, hasAudio, latest else { return false }
        guard let endedAt else { return true }
        return now.timeIntervalSince(endedAt) < window
    }
}

// MARK: - W19, W20: предупреждение участникам

public enum ConsentWarning {
    public static func standard(russian: Bool) -> String {
        russian
            ? "Коллеги, я записываю эту встречу, чтобы ничего не упустить. Запись и расшифровка остаются у меня на компьютере и никуда не отправляются. Если вы против — скажите, я остановлю запись."
            : "Heads-up: I’m recording this meeting so nothing gets lost. The recording and transcript stay on my computer and aren’t sent anywhere. If you’d rather not, say so and I’ll stop."
    }

    public static func text(custom: String?, russian: Bool) -> String {
        let trimmed = custom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? standard(russian: russian) : trimmed
    }

    /// Черновик письма участникам события: `mailto:` открывает новое письмо и ничего не отправляет.
    /// Адреса — только похожие на почту; тема и текст в процентной кодировке (пробел — `%20`, не `+`).
    public static func mailto(emails: [String], title: String, start: Date, warning: String, russian: Bool,
                              timeZone: TimeZone = .current) -> URL? {
        let valid = emails.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.range(of: #"^[^@\s,;?&]+@[^@\s,;?&]+\.[^@\s,;?&]+$"#, options: .regularExpression) != nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: russian ? "ru_RU" : "en_US")
        f.timeZone = timeZone
        f.dateFormat = russian ? "d MMMM, HH:mm" : "MMM d, HH:mm"
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = russian ? "Запись встречи «\(name.isEmpty ? "встреча" : name)»" : "Recording: \(name.isEmpty ? "our meeting" : name)"
        let body = (russian ? "Встреча \(f.string(from: start)).\n\n" : "Meeting on \(f.string(from: start)).\n\n") + warning + "\n"
        // Только ASCII без кодирования: `alphanumerics` пропустил бы кириллицу.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        let to = valid.map(encode).joined(separator: ",")
        return URL(string: "mailto:\(to)?subject=\(encode(subject))&body=\(encode(body))")
    }
}

// MARK: - W17: реплики для ремонта говорящих

/// Реплика `transcript.json` с исходной меткой и дорожкой — для фильтра, прослушивания и переназначения.
public struct TurnRef: Equatable, Sendable, Identifiable {
    public var id: Int
    /// Исходная метка диаризации («Собеседник 2»); у «Я» — «Я».
    public var label: String
    /// Видимое имя.
    public var speaker: String
    /// `mic` | `system`.
    public var source: String
    public var start: Double
    public var end: Double
    public var text: String

    public init(id: Int, label: String, speaker: String, source: String, start: Double, end: Double, text: String) {
        self.id = id; self.label = label; self.speaker = speaker; self.source = source
        self.start = start; self.end = max(start, end); self.text = text
    }

    /// Переназначать можно только реплику системной дорожки с одной меткой.
    public var isReassignable: Bool { source == "system" && !label.contains(" + ") }

    public static func parse(_ data: Data) -> [TurnRef] {
        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = dict["turns"] as? [[String: Any]] else { return [] }
        func number(_ v: Any?) -> Double { (v as? Double) ?? (v as? NSNumber)?.doubleValue ?? 0 }
        return raw.enumerated().compactMap { index, item in
            guard let text = item["text"] as? String else { return nil }
            let speaker = item["speaker"] as? String ?? ""
            let id = (item["id"] as? Int) ?? (item["id"] as? NSNumber)?.intValue ?? index
            let start = number(item["start"])
            return TurnRef(id: id, label: item["label"] as? String ?? speaker, speaker: speaker,
                           source: item["source"] as? String ?? "system", start: start,
                           end: item["end"] == nil ? start : number(item["end"]), text: text)
        }
    }

    /// Метки системной дорожки в порядке появления с видимыми именами — цели переназначения.
    public static func labels(_ turns: [TurnRef]) -> [(label: String, name: String)] {
        var seen: [(String, String)] = []
        for turn in turns where turn.isReassignable && !seen.contains(where: { $0.0 == turn.label }) {
            seen.append((turn.label, turn.speaker))
        }
        return seen
    }

    /// Реплика по времени начала и видимому имени — так строка окна встречи находит свой `id`.
    public static func find(_ turns: [TurnRef], start: Double, speaker: String) -> TurnRef? {
        turns.first { abs($0.start - start) < 0.05 && $0.speaker == speaker }
            ?? turns.first { abs($0.start - start) < 0.05 }
    }
}

// MARK: - A1: выбор системного голоса

/// Установленный голос macOS: качество 1 — обычный, 2 — улучшенный, 3 — Premium.
public struct SystemVoiceInfo: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var language: String
    public var quality: Int
    public init(id: String, name: String, language: String, quality: Int) {
        self.id = id; self.name = name; self.language = language; self.quality = quality
    }
}

public enum SystemVoicePick {
    /// Голоса языка (`ru`, `en`): сначала Premium, потом улучшенные, внутри — по имени.
    public static func options(_ voices: [SystemVoiceInfo], language: String) -> [SystemVoiceInfo] {
        voices.filter { $0.language.lowercased().hasPrefix(language.lowercased()) }
            .sorted { ($0.quality, $1.name) > ($1.quality, $0.name) }
    }

    /// Выбранный пользователем голос, если он ещё установлен; иначе лучший из установленных.
    public static func best(_ voices: [SystemVoiceInfo], language: String, chosen: String?) -> SystemVoiceInfo? {
        let options = options(voices, language: language)
        if let chosen, let voice = options.first(where: { $0.id == chosen }) { return voice }
        return options.first
    }
}

// MARK: - PCM: уровни для живой расшифровки, смесь дорожек для прослушивания

/// PCM int16 LE 16 кГц моно — как пишет `MeetingRecorder`.
public enum LivePCM {
    public static let sampleRate = 16_000
    /// Байт в кадре уровней (100 мс).
    public static let frameBytes = sampleRate * 2 / 10

    /// Уровни по 100 мс: RMS в dBFS, −50…0 → 0…1 (та же шкала, что у волны в пилюле).
    /// Неполный хвост не считается — он уйдёт в следующий опрос.
    public static func levels(_ pcm: Data) -> [Float] {
        let samples = pcm.count / 2
        let perFrame = frameBytes / 2
        guard samples >= perFrame else { return [] }
        return pcm.withUnsafeBytes { raw -> [Float] in
            let values = raw.bindMemory(to: Int16.self)
            return stride(from: 0, to: samples - perFrame + 1, by: perFrame).map { start in
                var sum: Double = 0
                for i in start..<(start + perFrame) {
                    let v = Double(Int16(littleEndian: values[i])) / 32768
                    sum += v * v
                }
                let rms = (sum / Double(perFrame)).squareRoot()
                let db = 20 * log10(max(rms, 1e-6))
                return Float(min(1, max(0, (db + 50) / 50)))
            }
        }
    }

    /// Сложить дорожки сэмпл к сэмплу с насыщением; длина — по самой длинной.
    public static func mix(_ tracks: [Data]) -> Data {
        let count = (tracks.map(\.count).max() ?? 0) / 2
        var out = [Int16](repeating: 0, count: count)
        for track in tracks {
            track.withUnsafeBytes { raw in
                let values = raw.bindMemory(to: Int16.self)
                for i in 0..<min(count, values.count) {
                    let sum = Int(out[i]) + Int(Int16(littleEndian: values[i]))
                    out[i] = Int16(clamping: sum)
                }
            }
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Канонический 44-байтный WAV вокруг PCM — для временного файла и проигрывателя.
    public static func wav(_ pcm: Data, sampleRate: Int = sampleRate) -> Data {
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + pcm.count)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(pcm.count)
        return d + pcm
    }
}
