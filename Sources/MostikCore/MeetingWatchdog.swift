import Foundation

/// Живучесть записи встречи (M12). Сторож раз в секунду смотрит, когда от каждой дорожки
/// приходил последний буфер. Дорожка молчит дольше `stallAfter` — перезапустить её новым
/// сегментом (`mic.2.wav`…), не больше `maxRestarts` раз; потом сдаться и пометить запись неполной.
/// Тишина в звуке — не остановка: буферы с нулями идут, их сторож не трогает. Зато если за первые
/// `silenceWarnAfter` секунд не было ни одного громкого буфера ни на одной дорожке — одно предупреждение
/// «нет звука». Отдельно — отказ в «звуке системы»: macOS при отказе не ломает
/// process tap, а отдаёт тишину, и встреча молча писалась без собеседников. Если микрофон звучит, а
/// системная дорожка за `systemSilentWarnAfter` секунд не дала ни одного буфера выше −50 dBFS, —
/// одно предупреждение `warnSystemSilent`, но только когда звука системы ждём (`systemExpected`):
/// разрешение ещё ни разу не подтверждалось звуком или идёт звонок. Очная встреча без звонка с уже
/// подтверждённым разрешением — законная тишина, о ней не говорим.
public struct MeetingWatchdog: Equatable, Sendable {
    public enum Track: String, CaseIterable, Sendable { case mic, system }

    public enum Action: Equatable, Sendable {
        case restart(Track, attempt: Int)
        case giveUp(Track)
        case warnNoAudio
        case warnSystemSilent
    }

    public static let stallAfter: Double = 3
    public static let maxRestarts = 3
    public static let silenceWarnAfter: Double = 10
    /// Уровень 0…1 (−50…0 dBFS), выше которого считаем, что звук есть.
    public static let soundLevel: Float = 0.15
    /// Сколько секунд записи с живым микрофоном и тихой системной дорожкой — до предупреждения.
    public static let systemSilentWarnAfter: Double = 15

    public private(set) var startedAt: Double
    public private(set) var lastBuffer: [Track: Double]
    public private(set) var restarts: [Track: Int] = [:]
    public private(set) var gaveUp: Set<Track> = []
    public private(set) var heardSound = false
    public private(set) var warnedNoAudio = false
    /// Дорожки, от которых пришёл хоть один буфер громче −50 dBFS (уровень > 0).
    public private(set) var audible: Set<Track> = []
    public private(set) var micSounded = false
    public private(set) var warnedSystemSilent = false
    /// Секунды записи без пауз — для предупреждения о тишине.
    private var activeSeconds: Double = 0
    private var lastTick: Double

    public init(startedAt: Double, tracks: [Track] = Track.allCases) {
        self.startedAt = startedAt
        self.lastTick = startedAt
        // Старт считается буфером: у дорожки есть `stallAfter` секунд на первый звук.
        lastBuffer = Dictionary(uniqueKeysWithValues: tracks.map { ($0, startedAt) })
    }

    /// Пришёл буфер дорожки (`level` — 0…1).
    public mutating func buffer(_ track: Track, at t: Double, level: Float = 0) {
        lastBuffer[track] = max(lastBuffer[track] ?? t, t)
        if level >= Self.soundLevel { heardSound = true }
        if level > 0 { audible.insert(track) }
        if track == .mic, level >= Self.soundLevel { micSounded = true }
    }

    /// Дорожку перезапустили (удачно или нет): даём ей новый срок на первый буфер.
    public mutating func restarted(_ track: Track, at t: Double) {
        lastBuffer[track] = t
    }

    /// Системная дорожка хоть раз прозвучала — разрешение на звук системы точно выдано.
    public var systemHeard: Bool { audible.contains(.system) }

    public mutating func tick(at t: Double, paused: Bool = false, systemExpected: Bool = false) -> [Action] {
        if !paused { activeSeconds += max(0, t - lastTick) }
        lastTick = t
        var actions: [Action] = []
        for track in Track.allCases {
            guard let last = lastBuffer[track], !gaveUp.contains(track), t - last >= Self.stallAfter else { continue }
            let done = restarts[track, default: 0]
            if done < Self.maxRestarts {
                restarts[track] = done + 1
                lastBuffer[track] = t
                actions.append(.restart(track, attempt: done + 1))
            } else {
                gaveUp.insert(track)
                actions.append(.giveUp(track))
            }
        }
        if !heardSound, !warnedNoAudio, activeSeconds >= Self.silenceWarnAfter {
            warnedNoAudio = true
            actions.append(.warnNoAudio)
        }
        if systemExpected, micSounded, !systemHeard, !warnedSystemSilent, lastBuffer[.system] != nil,
           !gaveUp.contains(.system), activeSeconds >= Self.systemSilentWarnAfter {
            warnedSystemSilent = true
            actions.append(.warnSystemSilent)
        }
        return actions
    }

    /// Статус записи для манифеста: `complete` / `recovered` / `incomplete`.
    public var status: String {
        if !gaveUp.isEmpty { return "incomplete" }
        return restarts.values.contains { $0 > 0 } ? "recovered" : "complete"
    }

    public var totalRestarts: Int { restarts.values.reduce(0, +) }

    /// Ключи `recording` манифеста после перезапуска: `restarts` — целое по схеме,
    /// разбивка по дорожкам — отдельным полем.
    public var manifestRestarts: [String: Any] {
        ["restarts": totalRestarts,
         "restarts_by_track": Dictionary(uniqueKeysWithValues: restarts.map { ($0.key.rawValue, $0.value) })]
    }
}

/// Что делать со встречей при запуске приложения (M12): дорасшифровать брошенное, но без зацикливания.
public enum MeetingRecovery {
    public static let maxAttempts = 2

    public enum Decision: Equatable, Sendable {
        case none
        /// `markIncomplete` — приложение упало посреди записи: статус записи становится `incomplete`.
        case transcribe(markIncomplete: Bool)
        /// Попытки кончились или звука нет — встреча остаётся «не расшифрована», статус failed.
        case giveUp(markIncomplete: Bool)
    }

    /// - Parameters:
    ///   - summary: манифест; nil — старая папка без манифеста (её разбирает миграция, сами не гоняем).
    ///   - hasAudio: есть хотя бы одна дорожка больше заголовка.
    ///   - hasTranscript: `transcript.json` уже лежит.
    ///   - isRecordingNow: эту встречу пишем прямо сейчас.
    public static func decide(summary: MeetingFolder.Summary?, hasAudio: Bool, hasTranscript: Bool,
                              isRecordingNow: Bool) -> Decision {
        guard let summary, !isRecordingNow else { return .none }
        let crashed = summary.recording == "recording"
        let unfinished = ["pending", "processing"].contains(summary.transcript ?? "")
        if hasTranscript && summary.transcript == "done" { return crashed ? .giveUp(markIncomplete: true) : .none }
        guard crashed || unfinished else { return .none }
        guard hasAudio, summary.audioKept, summary.transcriptAttempts < maxAttempts else {
            return .giveUp(markIncomplete: crashed)
        }
        return .transcribe(markIncomplete: crashed)
    }
}

/// Сегмент дорожки (M12): файл и смещение его начала от начала записи (по часам записи, без пауз).
public struct MeetingSegment: Equatable, Sendable {
    public var track: MeetingWatchdog.Track
    public var file: String
    public var offset: Double

    public init(track: MeetingWatchdog.Track, file: String, offset: Double) {
        self.track = track; self.file = file; self.offset = offset
    }

    /// Имя файла сегмента: первый — `mic.wav`, дальше `mic.2.wav`, `mic.3.wav`…
    public static func fileName(_ track: MeetingWatchdog.Track, index: Int) -> String {
        index <= 1 ? "\(track.rawValue).wav" : "\(track.rawValue).\(index).wav"
    }

    public var manifestValue: [String: Any] {
        ["track": track.rawValue, "file": file, "offset_seconds": (offset * 100).rounded() / 100]
    }

    /// Поле `segments` команды `meeting`: `{mic: [{file, offset_seconds}], system: […]}`.
    public static func commandField(_ segments: [MeetingSegment]) -> JSONValue {
        var result: [String: JSONValue] = [:]
        for track in MeetingWatchdog.Track.allCases {
            let items = segments.filter { $0.track == track }
            guard !items.isEmpty else { continue }
            result[track.rawValue] = .array(items.map {
                .object(["file": .string($0.file), "offset_seconds": .number(($0.offset * 100).rounded() / 100)])
            })
        }
        return .object(result)
    }

    /// Сегменты из манифеста (`recording.segments`).
    public static func fromManifest(_ manifest: [String: Any]?) -> [MeetingSegment] {
        let raw = (manifest?["recording"] as? [String: Any])?["segments"] as? [[String: Any]] ?? []
        return raw.compactMap { item in
            guard let track = (item["track"] as? String).flatMap(MeetingWatchdog.Track.init(rawValue:)),
                  let file = item["file"] as? String else { return nil }
            let offset = (item["offset_seconds"] as? Double) ?? (item["offset_seconds"] as? NSNumber)?.doubleValue ?? 0
            return MeetingSegment(track: track, file: file, offset: offset)
        }
    }
}

/// Тексты про звук системы — одни для плашки встречи и «Проверки».
public enum MeetingAudioText {
    /// Где включать: на macOS 15+ — «Запись экрана и системного звука» (раздел «Только системный звук»),
    /// на 14.x — «Запись звука системы».
    public static func pane(russian: Bool, macOS15: Bool = ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))) -> String {
        if macOS15 {
            return russian ? "Конфиденциальность и безопасность → Запись экрана и системного звука"
                : "Privacy & Security → Screen & System Audio Recording"
        }
        return russian ? "Конфиденциальность и безопасность → Запись звука системы"
            : "Privacy & Security → System Audio Recording"
    }

    public static func systemSilent(russian: Bool) -> String {
        russian
            ? "Микрофон пишется, а звук звонка — тишина. Если вы на звонке, разрешите Mostik запись системного звука: "
                + pane(russian: true) + ". Запись идёт дальше; после разрешения начните встречу заново."
            : "The microphone is recording, but the call audio is silent. If you’re on a call, allow Mostik to record system audio: "
                + pane(russian: false) + ". Recording continues; start the meeting again after allowing it."
    }
}
