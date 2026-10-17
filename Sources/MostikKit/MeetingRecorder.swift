import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import MostikCore

/// Запись встречи двумя дорожками в одну папку (архитектура §4, §12.7).
///
/// - `mic.wav` — микрофон через собственный `AVAudioEngine` («Я»);
/// - `system.wav` — звук всех приложений через Core Audio process tap
///   (macOS 14.2+), собственный процесс исключён.
///
/// Обе дорожки — 16 кГц, моно, int16, пишутся потоково. Заголовок WAV
/// пишется с заглушками и обновляется раз в секунду записанного звука, так что
/// после падения файл остаётся валидным (теряется не больше секунды хвоста);
/// на `stop()` размеры выставляются точно.
///
/// Первый `start()` вызывает системный запрос разрешения на запись звука
/// (`NSAudioCaptureUsageDescription`) и микрофона — запускать только из
/// приложения по действию пользователя.
public final class MeetingRecorder: @unchecked Sendable {
    public enum Failure: LocalizedError {
        case alreadyRunning
        case unsupportedOS
        case noInput
        case coreAudio(String, OSStatus)

        public var errorDescription: String? {
            switch self {
            case .alreadyRunning: return L("Запись встречи уже идёт", "A meeting is already being recorded")
            case .unsupportedOS: return L("Запись звука системы требует macOS 14.2 или новее", "Recording system audio needs macOS 14.2 or later")
            case .noInput: return L("Нет устройства ввода", "No input device")
            case let .coreAudio(step, status): return L("Core Audio: \(step) — код \(status)", "Core Audio: \(step) — code \(status)")
            }
        }
    }

    /// Уровни (0…1) микрофона и системы; вызывается на главной очереди ~10 раз в секунду.
    public var onLevels: ((Float, Float) -> Void)?

    public let folder: URL
    public var micURL: URL { folder.appendingPathComponent("mic.wav") }
    public var systemURL: URL { folder.appendingPathComponent("system.wav") }

    /// Сегменты дорожек (M12): первый — `mic.wav`/`system.wav` со смещением 0, после перезапуска — `mic.2.wav`…
    public var segments: [MeetingSegment] { lock.withLock { segmentList } }
    private var segmentList: [MeetingSegment] = []
    /// Когда от дорожки последний раз пришёл буфер (секунды с 1970) — для сторожа; пауза не мешает.
    private var lastBufferAt: [MeetingWatchdog.Track: Double] = [:]
    /// Пик уровня с прошлого опроса — сторож по нему понимает, есть ли звук вообще.
    private var peaks: [MeetingWatchdog.Track: Float] = [:]

    static let sampleRate: Double = 16_000
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
    )!

    private let lock = NSLock()
    /// Разводит перенастройку микрофона и разбор: иначе смена устройства в момент
    /// остановки снова запускает уже остановленный движок и микрофон остаётся открытым.
    /// Рекурсивный: `engine.stop()` может прислать уведомление о смене конфигурации в том же потоке.
    private let controlLock = NSRecursiveLock()
    private var running = false
    private var paused = false
    private var micWriter: MeetingWAVStream?
    private var systemWriter: MeetingWAVStream?
    private var micLevel: Float = 0
    private var systemLevel: Float = 0
    private var lastLevelsReport = Date.distantPast

    // Микрофон.
    private var engine: AVAudioEngine?
    private var micConverter: AVAudioConverter?
    private var configObserver: NSObjectProtocol?

    // Звук системы.
    private var systemTap: AnyObject?  // SystemAudioTap, macOS 14.2+

    /// Микрофон из Настроек (`MostikSettings.micDeviceUID`); пусто — системный вход (R3b, `MicChoice`).
    public var micDeviceUID = ""

    public init(folder: URL) {
        self.folder = folder
    }

    deinit {
        teardown()
    }

    /// Шумо- и эхоподавление Apple (V6) для микрофона встречи; задаётся до `start()`.
    public var voiceProcessing = false

    public func start() throws {
        try start(continuing: [], offset: 0)
    }

    /// Продолжить запись той же встречи (W16): прежние сегменты сохраняются, новые пишутся
    /// в следующие файлы (`mic.2.wav`…) со смещением `offset` — секунды уже записанного.
    public func start(continuing previous: [MeetingSegment], offset: Double) throws {
        lock.lock()
        guard !running else {
            lock.unlock()
            throw Failure.alreadyRunning
        }
        running = true
        lock.unlock()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let fresh = previous.isEmpty
                ? [MeetingSegment(track: .mic, file: micURL.lastPathComponent, offset: 0),
                   MeetingSegment(track: .system, file: systemURL.lastPathComponent, offset: 0)]
                : MeetingContinuation.nextSegments(after: previous, offset: offset)
            func url(_ track: MeetingWatchdog.Track) -> URL {
                folder.appendingPathComponent(fresh.first { $0.track == track }?.file ?? "\(track.rawValue).wav")
            }
            let mic = try MeetingWAVStream(url: url(.mic), sampleRate: Int(Self.sampleRate))
            let system = try MeetingWAVStream(url: url(.system), sampleRate: Int(Self.sampleRate))
            lock.lock()
            micWriter = mic
            systemWriter = system
            segmentList = previous + fresh
            lock.unlock()
            try startMic()
            try startSystem()
        } catch {
            teardown()
            throw error
        }
    }

    /// Пауза (M4): устройства не закрываем, чтобы продолжить без нового запроса доступа
    /// и без щелчка, но сэмплы не пишем. Обе дорожки стоят одинаково — синхронность сохраняется.
    public var isPaused: Bool {
        get { lock.withLock { paused } }
        set {
            lock.withLock { paused = newValue }
            if newValue { report(mic: 0, system: 0) }
        }
    }

    /// Сторож (M12): когда дорожки последний раз присылали буферы и пики уровня с прошлого опроса.
    public func poll() -> (lastBuffer: [MeetingWatchdog.Track: Double], peaks: [MeetingWatchdog.Track: Float]) {
        lock.withLock {
            let result = (lastBufferAt, peaks)
            peaks = [:]
            return result
        }
    }

    /// Перезапустить вставшую дорожку новым сегментом (M12). `offset` — секунды записи к этому моменту.
    public func restart(_ track: MeetingWatchdog.Track, offset: Double) throws {
        controlLock.lock()
        defer { controlLock.unlock() }
        guard lock.withLock({ running }) else { return }
        let index = lock.withLock { segmentList.filter { $0.track == track }.count } + 1
        let name = MeetingSegment.fileName(track, index: index)
        let writer = try MeetingWAVStream(url: folder.appendingPathComponent(name), sampleRate: Int(Self.sampleRate))
        switch track {
        case .mic:
            lock.lock()
            let engine = self.engine
            let observer = configObserver
            let old = micWriter
            self.engine = nil
            configObserver = nil
            micConverter = nil
            micWriter = writer
            segmentList.append(MeetingSegment(track: .mic, file: name, offset: offset))
            lock.unlock()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            if let engine {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
            old?.close()
            try startMic()
        case .system:
            lock.lock()
            let tap = systemTap
            let old = systemWriter
            systemTap = nil
            systemWriter = writer
            segmentList.append(MeetingSegment(track: .system, file: name, offset: offset))
            lock.unlock()
            if #available(macOS 14.2, *), let tap = tap as? SystemAudioTap { tap.stop() }
            old?.close()
            try startSystem()
        }
    }

    @discardableResult
    public func stop() -> (mic: URL, system: URL) {
        teardown()
        return (micURL, systemURL)
    }

    // MARK: - Разбор

    /// Ссылки забираем под замком, а останавливаем без него: `engine.stop()` и
    /// `AudioDeviceStop` ждут колбэк, который сам берёт замок.
    private func teardown() {
        controlLock.lock()
        defer { controlLock.unlock() }
        lock.lock()
        let observer = configObserver
        let engine = self.engine
        let tap = systemTap
        let writers = [micWriter, systemWriter]
        configObserver = nil
        self.engine = nil
        micConverter = nil
        systemTap = nil
        micWriter = nil
        systemWriter = nil
        running = false
        paused = false
        lastBufferAt = [:]
        peaks = [:]
        lock.unlock()

        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        if #available(macOS 14.2, *), let tap = tap as? SystemAudioTap {
            tap.stop()
        }
        writers.forEach { $0?.close() }
    }

    // MARK: - Микрофон

    private func startMic() throws {
        let engine = AVAudioEngine()
        lock.lock()
        self.engine = engine
        lock.unlock()
        try installMicTap(on: engine)
        // Смена устройства (наушники, AirPods) останавливает движок и меняет
        // формат: пересоздаём конвертер и тап, запись продолжается в тот же файл.
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.reconfigureMic()
        }
        lock.lock()
        configObserver = observer
        lock.unlock()
        engine.prepare()
        try engine.start()
    }

    private func installMicTap(on engine: AVAudioEngine) throws {
        let input = engine.inputNode
        // Выбранный микрофон — только движку встречи; системный вход не меняется.
        let choice = AudioInputs.resolve(uid: micDeviceUID)
        if choice.pinned, let device = choice.device { AudioInputs.bind(input, to: device) }
        VoiceProcessing.set(input, enabled: voiceProcessing)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noInput }
        guard let converter = AVAudioConverter(from: format, to: Self.targetFormat) else {
            throw Failure.noInput
        }
        converter.downmix = true
        lock.lock()
        micConverter = converter
        lock.unlock()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handleMic(buffer)
        }
    }

    private func reconfigureMic() {
        controlLock.lock()
        defer { controlLock.unlock() }
        lock.lock()
        let engine = self.engine
        let isRunning = running
        lock.unlock()
        guard let engine, isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try installMicTap(on: engine)
            engine.prepare()
            try engine.start()
        } catch {
            // Микрофон пропал совсем: дорожка системы продолжает писаться,
            // mic.wav остаётся валидным до текущего места.
            NSLog("Mostik: микрофон встречи не перезапустился: \(error)")
        }
    }

    private func handleMic(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let converter = micConverter
        let writer = micWriter
        let skip = paused
        lastBufferAt[.mic] = Date().timeIntervalSince1970
        lock.unlock()
        guard let converter, let writer else { return }
        // Конвертер гоняем и на паузе: у ресемплера своё состояние, без входа он «щёлкнет» на продолжении.
        guard let pcm = MeetingAudio.convert(buffer, with: converter), !skip else { return }
        writer.append(pcm.int16)
        lock.withLock { peaks[.mic] = max(peaks[.mic] ?? 0, pcm.level) }
        report(mic: pcm.level)
    }

    // MARK: - Система

    private func startSystem() throws {
        guard #available(macOS 14.2, *) else { throw Failure.unsupportedOS }
        let tap = SystemAudioTap { [weak self] buffer in
            self?.handleSystem(buffer)
        }
        try tap.start()
        lock.lock()
        systemTap = tap
        lock.unlock()
    }

    private func handleSystem(_ pcm: MeetingAudio.Converted) {
        lock.lock()
        let writer = systemWriter
        let skip = paused
        lastBufferAt[.system] = Date().timeIntervalSince1970
        if !skip { peaks[.system] = max(peaks[.system] ?? 0, pcm.level) }
        lock.unlock()
        guard !skip else { return }
        writer?.append(pcm.int16)
        report(system: pcm.level)
    }

    // MARK: - Уровни

    private func report(mic: Float? = nil, system: Float? = nil) {
        lock.lock()
        if let mic { micLevel = mic }
        if let system { systemLevel = system }
        let now = Date()
        let due = now.timeIntervalSince(lastLevelsReport) >= 0.1
        if due { lastLevelsReport = now }
        let levels = (micLevel, systemLevel)
        let callback = onLevels
        lock.unlock()
        guard due, let callback else { return }
        DispatchQueue.main.async { callback(levels.0, levels.1) }
    }
}

// MARK: - Конвертация

enum MeetingAudio {
    struct Converted {
        let int16: Data
        let level: Float
    }

    /// Любой формат → 16 кГц моно → int16 LE. Конвертер хранит состояние
    /// ресемплера между вызовами, поэтому на один поток — один конвертер.
    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> Converted? {
        let ratio = MeetingRecorder.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: MeetingRecorder.targetFormat, frameCapacity: capacity) else {
            return nil
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let samples = output.floatChannelData?[0] else { return nil }
        return pack(samples, count: Int(output.frameLength))
    }

    static func pack(_ samples: UnsafePointer<Float>, count: Int) -> Converted {
        guard count > 0 else { return Converted(int16: Data(), level: 0) }
        var data = Data(count: count * 2)
        var sumSquares: Float = 0
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                let value = max(-1, min(1, samples[i]))
                sumSquares += value * value
                out[i] = Int16(value * 32767).littleEndian
            }
        }
        let rms = (sumSquares / Float(count)).squareRoot()
        // Уровень для индикатора: -50…0 dBFS → 0…1.
        let db = 20 * log10(max(rms, 1e-6))
        return Converted(int16: data, level: max(0, min(1, (db + 50) / 50)))
    }
}

// MARK: - Потоковый WAV

/// WAV 16 бит моно, который валиден в любой момент записи.
///
/// Заголовок сразу пишется с заглушкой 0xFFFFFFFF («длина неизвестна» —
/// так пишут потоковые рекордеры, ffmpeg читает до конца файла), затем
/// размеры обновляются каждую секунду звука и точно — на `close()`.
/// Запись идёт на своей последовательной очереди: колбэки звука не ждут диска.
final class MeetingWAVStream: @unchecked Sendable {
    static let headerSize = 44

    let url: URL
    private let sampleRate: Int
    private let handle: FileHandle
    private let queue: DispatchQueue
    private var dataBytes = 0
    private var bytesSincePatch = 0
    private var closed = false

    init(url: URL, sampleRate: Int) throws {
        self.url = url
        self.sampleRate = sampleRate
        self.queue = DispatchQueue(label: "mostik.meeting.wav.\(url.lastPathComponent)", qos: .utility)
        FileManager.default.createFile(atPath: url.path, contents: Self.header(sampleRate: sampleRate, dataBytes: nil))
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [self] in
            guard !closed else { return }
            do {
                try handle.write(contentsOf: data)
            } catch {
                NSLog("Mostik: запись \(url.lastPathComponent) не удалась: \(error)")
                return
            }
            dataBytes += data.count
            bytesSincePatch += data.count
            if bytesSincePatch >= sampleRate * 2 {
                bytesSincePatch = 0
                patchHeader()
            }
        }
    }

    func close() {
        queue.sync {
            guard !closed else { return }
            closed = true
            patchHeader()
            try? handle.synchronize()
            try? handle.close()
        }
    }

    private func patchHeader() {
        do {
            let end = try handle.offset()
            try handle.seek(toOffset: 4)
            try handle.write(contentsOf: Self.u32(36 + dataBytes))
            try handle.seek(toOffset: 40)
            try handle.write(contentsOf: Self.u32(dataBytes))
            try handle.seek(toOffset: end)
        } catch {
            NSLog("Mostik: заголовок \(url.lastPathComponent) не обновился: \(error)")
        }
    }

    static func u32(_ value: Int) -> Data {
        var little = UInt32(truncatingIfNeeded: value).littleEndian
        return Data(bytes: &little, count: 4)
    }

    /// `dataBytes == nil` — заглушка «длина неизвестна».
    static func header(sampleRate: Int, dataBytes: Int?) -> Data {
        func u16(_ value: Int) -> Data {
            var little = UInt16(value).littleEndian
            return Data(bytes: &little, count: 2)
        }
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(dataBytes.map { u32(36 + $0) } ?? u32(0xFFFF_FFFF))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        data.append(u32(16))
        data.append(u16(1))  // PCM
        data.append(u16(1))  // моно
        data.append(u32(sampleRate))
        data.append(u32(sampleRate * 2))
        data.append(u16(2))
        data.append(u16(16))
        data.append(contentsOf: Array("data".utf8))
        data.append(dataBytes.map { u32($0) } ?? u32(0xFFFF_FFFF - 36))
        return data
    }
}

// MARK: - Core Audio process tap

/// Глобальный тап на весь вывод системы, кроме собственного процесса,
/// в приватном aggregate-устройстве. Порядок разбора обратный созданию:
/// IOProc → aggregate → tap.
@available(macOS 14.2, *)
final class SystemAudioTap: @unchecked Sendable {
    typealias Sink = (MeetingAudio.Converted) -> Void

    private let sink: Sink
    private let queue = DispatchQueue(label: "mostik.meeting.system-tap", qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    init(sink: @escaping Sink) {
        self.sink = sink
    }

    deinit { stop() }

    func start() throws {
        do {
            try createTap()
            try createAggregate()
            try startIO()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown, let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        converter = nil
    }

    private var tapUUID = UUID()

    private func createTap() throws {
        var excluded: [AudioObjectID] = []
        if let own = CoreAudioQuery.processObject(pid: getpid()) {
            excluded.append(own)
        }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.uuid = tapUUID
        description.name = "Mostik meeting"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &id)
        guard status == noErr, id != kAudioObjectUnknown else {
            throw MeetingRecorder.Failure.coreAudio("AudioHardwareCreateProcessTap", status)
        }
        tapID = id

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let formatStatus = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard formatStatus == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw MeetingRecorder.Failure.coreAudio("kAudioTapPropertyFormat", formatStatus)
        }
        guard let converter = AVAudioConverter(from: format, to: MeetingRecorder.targetFormat) else {
            throw MeetingRecorder.Failure.coreAudio(L("AVAudioConverter для тапа", "AVAudioConverter for the tap"), -1)
        }
        converter.downmix = true
        sourceFormat = format
        self.converter = converter
    }

    private func createAggregate() throws {
        let outputUID = CoreAudioQuery.defaultOutputUID()
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mostik Meeting Tap",
            kAudioAggregateDeviceUIDKey: "mostik.meeting.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                ]
            ],
        ]
        // Устройство вывода как главное даёт часы; без него тап тоже работает.
        if let outputUID {
            description[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            description[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard status == noErr, id != kAudioObjectUnknown else {
            throw MeetingRecorder.Failure.coreAudio("AudioHardwareCreateAggregateDevice", status)
        }
        aggregateID = id
    }

    private func startIO() throws {
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) {
            [weak self] _, inputData, _, _, _ in
            self?.handle(inputData)
        }
        guard status == noErr, let proc else {
            throw MeetingRecorder.Failure.coreAudio("AudioDeviceCreateIOProcIDWithBlock", status)
        }
        procID = proc
        let startStatus = AudioDeviceStart(aggregateID, proc)
        guard startStatus == noErr else {
            throw MeetingRecorder.Failure.coreAudio("AudioDeviceStart", startStatus)
        }
    }

    private func handle(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let format = sourceFormat, let converter,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil),
              buffer.frameLength > 0
        else { return }
        guard let converted = MeetingAudio.convert(buffer, with: converter) else { return }
        sink(converted)
    }
}

// MARK: - Запросы к Core Audio

enum CoreAudioQuery {
    static func processObject(pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
        )
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown
        else { return nil }
        return string(device, kAudioDevicePropertyDeviceUID)
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &list) == noErr else { return [] }
        return Array(list.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }
}
