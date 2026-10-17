import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreAudio
import Foundation
import MostikCore

// MARK: - V6: шумо- и эхоподавление Apple

/// Голосовая обработка Apple (шумоподавление + эхоподавление) на входе `AVAudioEngine`.
/// Включать только до `engine.start()`; приглушение чужого звука — минимальное,
/// иначе собеседники в наушниках становятся тише на время записи.
public enum VoiceProcessing {
    public static func set(_ input: AVAudioInputNode, enabled: Bool) {
        guard input.isVoiceProcessingEnabled != enabled else { return }
        do {
            try input.setVoiceProcessingEnabled(enabled)
        } catch {
            NSLog("Mostik: голосовая обработка не переключилась: \(error)")
            return
        }
        if enabled, #available(macOS 14.0, *) {
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        }
    }
}

/// Куда сейчас идёт звук: эхоподавление нужно, только когда собеседники звучат из колонок.
public enum AudioRoute {
    /// Встроенные динамики, HDMI/DisplayPort, AirPlay — да; наушники, Bluetooth, USB-гарнитура — нет.
    /// Неизвестное считаем наушниками: лишняя обработка портит голос, а эха без колонок нет.
    public static func outputIsSpeakers() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown,
              let transport = CoreAudioQuery.uint32(device, kAudioDevicePropertyTransportType) else { return false }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            // Встроенный выход: источник 'ispk' — динамики, 'hdpn' — наушники в разъёме.
            var source: UInt32 = 0
            size = UInt32(MemoryLayout<UInt32>.size)
            address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &source) == noErr else { return true }
            return source != 0x6864_706E  // 'hdpn'
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeAirPlay:
            return true
        default:
            return false
        }
    }
}

// MARK: - W24: ⌃⌘M — начать или остановить запись встречи

/// Сочетание для встречи. Своя подпись 'MOSM': чужие сочетания (⌥Space, ⌃⌘V/Z/R) уходят дальше по цепочке.
@MainActor
public final class MeetingHotkey {
    static let signature = OSType(0x4D4F_534D)
    private let handler: () -> Void
    private var hotKey: EventHotKeyRef?
    private var carbonHandler: EventHandlerRef?

    public init(handler: @escaping () -> Void) { self.handler = handler }

    public var isActive: Bool { hotKey != nil }

    public func start() {
        guard hotKey == nil else { return }
        if carbonHandler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let context = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                               nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard status == noErr, id.signature == MeetingHotkey.signature else { return OSStatus(eventNotHandledErr) }
                let monitor = Unmanaged<MeetingHotkey>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { monitor.handler() }
                return noErr
            }, 1, &spec, context, &carbonHandler)
        }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        if RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(controlKey | cmdKey), id, GetApplicationEventTarget(), 0, &ref) == noErr {
            hotKey = ref
        }
    }

    public func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        if let carbonHandler { RemoveEventHandler(carbonHandler) }
        carbonHandler = nil
    }
}

// MARK: - Файлы дорожек: чтение кусков, обнуление, фрагменты

/// PCM дорожек встречи: 44-байтный заголовок, int16 моно 16 кГц (`MeetingWAVStream`).
public enum MeetingAudioFiles {
    static let header = 44
    static let bytesPerSecond = Double(LivePCM.sampleRate * 2)

    /// Сколько байт данных сейчас в файле (растущий файл — по размеру, не по заголовку).
    public static func dataBytes(_ url: URL) -> Int {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return max(0, size - header) & ~1
    }

    /// Кусок данных `[from, from + count)` в байтах после заголовка.
    public static func read(_ url: URL, from: Int, count: Int) -> Data {
        guard count > 0, let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(header + max(0, from)))) != nil else { return Data() }
        return (try? handle.read(upToCount: count)) ?? Data()
    }

    /// «Только текст» (W15): обнулить диапазоны данных на месте. Размер и заголовок не меняются —
    /// расшифровка и время реплик остаются верными, звук в этих местах — тишина.
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

    /// PCM отрезка встречи `[start, end)` в секундах по дорожкам; дорожки смешиваются.
    public static func snippet(folder: URL, segments: [MeetingSegment], tracks: [MeetingWatchdog.Track],
                               start: Double, end: Double) -> Data {
        var mixed: [Data] = []
        for track in tracks {
            let own = segments.filter { $0.track == track }
            var lengths: [String: Double] = [:]
            for segment in own {
                lengths[segment.file] = Double(dataBytes(folder.appendingPathComponent(segment.file))) / bytesPerSecond
            }
            let total = Int(((end - start) * bytesPerSecond).rounded()) & ~1
            var pcm = Data(count: max(0, total))
            for piece in MeetingClipPlan.pieces(segments: own, lengths: lengths, start: start, end: end) {
                let from = Int((piece.fileOffset * bytesPerSecond).rounded()) & ~1
                let count = Int((piece.length * bytesPerSecond).rounded()) & ~1
                let chunk = read(folder.appendingPathComponent(piece.file), from: from, count: count)
                let at = Int((piece.clipOffset * bytesPerSecond).rounded()) & ~1
                guard at < pcm.count else { continue }
                let n = min(chunk.count, pcm.count - at)
                pcm.replaceSubrange(at..<(at + n), with: chunk.prefix(n))
            }
            mixed.append(pcm)
        }
        return LivePCM.mix(mixed)
    }
}

// MARK: - Прослушать фрагмент (W17, W18)

/// Проигрыватель фрагмента встречи из памяти: без временных файлов, один фрагмент за раз.
@MainActor
public final class MeetingSnippetPlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    /// Вызывается на главной очереди, когда фрагмент доиграл или остановлен.
    public var onFinish: (() -> Void)?

    public override init() { super.init() }

    public var isPlaying: Bool { player?.isPlaying ?? false }

    @discardableResult
    public func play(pcm: Data) -> Bool {
        stop()
        guard !pcm.isEmpty, let player = try? AVAudioPlayer(data: LivePCM.wav(pcm)) else { return false }
        player.delegate = self
        self.player = player
        return player.play()
    }

    public func stop() {
        guard let player else { return }
        player.stop()
        self.player = nil
        onFinish?()
    }

    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            self.player = nil
            self.onFinish?()
        }
    }
}

// MARK: - W10: хвост растущей дорожки

/// Читает новые байты текущего сегмента дорожки и копит уровни; `take` отдаёт готовый кусок.
public final class LiveTrackTail {
    public let track: MeetingWatchdog.Track
    private var file: String?
    private var offset: Double = 0
    /// Сколько байт сегмента уже прочитано.
    private var read = 0
    /// Прочитанное, но ещё не отданное в расшифровку.
    private var pending = Data()
    private var levels: [Float] = []
    /// Секунда встречи, с которой начинается `pending`.
    private var pendingStart: Double = 0

    public init(track: MeetingWatchdog.Track) { self.track = track }

    /// Подтянуть новое из последнего сегмента дорожки. Сменился сегмент (сторож перезапустил дорожку) —
    /// недоданный хвост прежнего пропадает из живой строки (в итоговой расшифровке он есть), новый читается с нуля.
    public func poll(folder: URL, segments: [MeetingSegment]) {
        guard let current = segments.last(where: { $0.track == track }) else { return }
        if current.file != file {
            file = current.file
            offset = current.offset
            read = 0
            pending.removeAll()
            levels.removeAll()
        }
        let url = folder.appendingPathComponent(current.file)
        let available = MeetingAudioFiles.dataBytes(url)
        guard available > read else { return }
        // Только целые кадры по 100 мс: уровни считаются по кадрам.
        let count = (available - read) / LivePCM.frameBytes * LivePCM.frameBytes
        guard count > 0 else { return }
        let chunk = MeetingAudioFiles.read(url, from: read, count: count)
        if pending.isEmpty { pendingStart = offset + Double(read) / MeetingAudioFiles.bytesPerSecond }
        read += chunk.count
        pending.append(chunk)
        levels.append(contentsOf: LivePCM.levels(chunk))
    }

    /// Готовый кусок: (секунда начала, PCM). Тишину целиком не отдаём — Whisper на ней сочиняет.
    public func take(final: Bool = false) -> (start: Double, pcm: Data)? {
        guard let frames = LiveWindow.cut(levels: levels, final: final) else { return nil }
        let bytes = min(pending.count, frames * LivePCM.frameBytes)
        let start = pendingStart
        let pcm = pending.prefix(bytes)
        let loud = levels.prefix(frames).contains { $0 > LiveWindow.quietLevel }
        pending.removeFirst(bytes)
        levels.removeFirst(min(levels.count, frames))
        pendingStart = start + Double(bytes) / MeetingAudioFiles.bytesPerSecond
        return loud ? (start, Data(pcm)) : nil
    }
}

// MARK: - A1: установленные голоса macOS

public enum SystemVoices {
    /// Все установленные голоса — для выбора в настройках; скачанные Enhanced/Premium тоже здесь.
    public static func installed() -> [SystemVoiceInfo] {
        AVSpeechSynthesisVoice.speechVoices().map { voice in
            let quality: Int
            switch voice.quality {
            case .premium: quality = 3
            case .enhanced: quality = 2
            default: quality = 1
            }
            return SystemVoiceInfo(id: voice.identifier, name: voice.name, language: voice.language, quality: quality)
        }
    }
}

// MARK: - W17: вся метка — другому говорящему

extension EngineClient {
    @discardableResult
    public func speakerMerge(folder: URL, source: String, target: String) async throws -> [String: JSONValue] {
        try await request("speaker_merge", fields: ["folder": .string(folder.path), "source": .string(source),
                                                    "target": .string(target)], timeout: 30)
    }
}
