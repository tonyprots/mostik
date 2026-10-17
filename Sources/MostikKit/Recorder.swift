import AVFoundation
import CoreAudio
import MostikCore
import Foundation

public struct RecordingFile: Equatable, Sendable {
    public let url: URL
    public let seconds: Double
}

public enum RecorderError: Error, LocalizedError {
    case noInput
    case notAuthorized
    case converter

    public var errorDescription: String? {
        switch self {
        case .noInput: return L("Нет устройства ввода", "No input device")
        case .notAuthorized: return L("Нет доступа к микрофону", "No microphone access")
        case .converter: return L("Не удалось настроить конвертер звука", "Couldn’t set up the audio converter")
        }
    }
}

/// Микрофон (§12.6): тап в формате железа → AVAudioConverter → 16 кГц моно int16.
/// PCM уходит кусками по 100 мс в `onPCM` и параллельно пишется в WAV с первого кадра.
/// Тёплый микрофон держит кольцевой преролл 500 мс — только на встроенном или проводном входе.
public final class Recorder: @unchecked Sendable {
    public static let sampleRate: Double = 16_000
    static let chunkBytes = 3_200       // 100 мс int16
    static let preRollBytes = 16_000    // 500 мс int16

    /// Уровень 0…1, вызывается из фоновой очереди.
    public var onLevel: ((Float) -> Void)?
    /// PCM int16 LE 16 кГц моно, куски по 100 мс; вызывается из фоновой очереди.
    public var onPCM: ((Data) -> Void)?
    /// Шумо- и эхоподавление Apple для диктовки (V6); применяется при следующем запуске движка.
    public var voiceProcessing = false
    /// Первый звук записи дошёл (замер «нажатие → первый буфер», шаг 0); вызывается из очереди записи.
    public var onFirstBuffer: (() -> Void)?
    /// Вход отдаёт цифровые нули: шаг восстановления уже сделан (`SilentInputWatch`); из очереди записи.
    public var onSilentInput: ((SilentInputWatch.Action) -> Void)?

    /// Пересоздаётся при смене входа: `inputNode` остаётся привязан к устройству,
    /// которое было по умолчанию, когда движок создавали (`WarmMicPolicy`). Выбранный в Настройках
    /// микрофон привязывается к `inputNode` этого движка — системный вход не меняется (`MicChoice`).
    private var engine = AVAudioEngine()
    /// Устройство, под которое собран `engine`; nil — ещё не запускался.
    private var boundDevice: AudioDeviceID?
    private var inputListener: AudioObjectPropertyListenerBlock?
    private var devicesListener: AudioObjectPropertyListenerBlock?
    /// UID микрофона из Настроек; пусто — системный вход.
    private var micUID = ""
    private let queue = DispatchQueue(label: "mostik.recorder")
    private let converterLock = NSLock()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Recorder.sampleRate,
                                       channels: 1, interleaved: false)!
    private var tapInstalled = false
    private var engineRunning = false
    private var warmWanted = false
    private var recording = false
    /// Пауза диктовки: звук не уходит ни движку, ни в файл, вход остаётся открытым.
    private var paused = false
    private var ring = Data()
    private var chunk = Data()
    private var writer: WAVWriter?
    private var configObserver: NSObjectProtocol?
    private var firstBufferPending = false
    private var silence = SilentInputWatch()

    public init() {
        observe(engine)
        // Смена входа по умолчанию (сняли AirPods): остановленному движку
        // `AVAudioEngineConfigurationChange` не приходит — слушаем Core Audio.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.queue.async { self?.reconfigure() }
        }
        var address = Self.defaultInputAddress
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener) == noErr {
            inputListener = listener
        }
        // Выбранный микрофон подключили или вынули: захват переходит на него или на системный вход.
        let devices: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.queue.async { self?.reconfigure() }
        }
        var list = Self.devicesAddress
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &list, queue, devices) == noErr {
            devicesListener = devices
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        if let inputListener {
            var address = Self.defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, inputListener)
        }
        if let devicesListener {
            var address = Self.devicesAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, devicesListener)
        }
    }

    private static var devicesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private func observe(_ engine: AVAudioEngine) {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.queue.async { self?.reconfigure(formatChanged: true) }
        }
    }

    // MARK: публичный интерфейс

    /// Включить или выключить тёплый микрофон. Учитывает тип входа и разрешение.
    public func setWarm(_ on: Bool) {
        queue.async {
            self.warmWanted = on
            self.applyWarm()
        }
    }

    public var isWarm: Bool { queue.sync { warmActive } }

    /// Пауза идущей диктовки; с началом и концом записи снимается сама.
    public var isPaused: Bool {
        get { queue.sync { paused } }
        set { queue.async { self.paused = newValue && self.recording } }
    }

    /// Микрофон из Настроек (`MostikSettings.micDeviceUID`); пусто — системный вход.
    /// Меняет только захват Mostik: идущая запись или тёплый микрофон переезжают на новый вход.
    public func setMicDevice(_ uid: String) {
        queue.async {
            guard self.micUID != uid else { return }
            self.micUID = uid
            self.reconfigure()
        }
    }

    /// Начать запись в `url`. Преролл (если есть) пишется первым.
    public func begin(to url: URL) throws {
        try queue.sync { try beginOnQueue(url) }
    }

    /// То же без ожидания (шаг 1, п. 2): холодный старт `AVAudioEngine` идёт на очереди записи,
    /// главный поток сразу показывает плашку. `done` — с очереди записи; nil — запись идёт.
    /// `end()`/`discard()` встают в ту же очередь и не обгонят старт.
    public func beginAsync(to url: URL, done: @escaping @Sendable (Error?) -> Void) {
        queue.async {
            do { try self.beginOnQueue(url); done(nil) } catch { done(error) }
        }
    }

    private func beginOnQueue(_ url: URL) throws {
        do {
            guard Permissions.microphoneAuthorized else { throw RecorderError.notAuthorized }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            writer = try WAVWriter(url: url, sampleRate: Int(Recorder.sampleRate))
            chunk.removeAll(keepingCapacity: true)
            firstBufferPending = true
            silence = SilentInputWatch()
            recording = true; paused = false
            if warmActive, !ring.isEmpty {
                consume(ring)
                ring.removeAll(keepingCapacity: true)
            }
            if !engineRunning {
                let current = currentInput()?.device
                // Обработку голоса движок не снимает с уже созданного входа: выключили в Настройках —
                // без перезапуска приложения вход так и отдавал нули. Собираем заново.
                let staleProcessing = boundDevice != nil && engine.inputNode.isVoiceProcessingEnabled != voiceProcessing
                if staleProcessing || (current != nil && boundDevice != nil && boundDevice != current) { rebuildEngine() }
                do { try startEngine() } catch {
                    recording = false; paused = false
                    writer?.close(); writer = nil
                    try? FileManager.default.removeItem(at: url)
                    throw error
                }
            }
        }
    }

    /// Закончить запись: дописать хвост, закрыть WAV.
    @discardableResult
    public func end() -> RecordingFile? {
        queue.sync {
            guard recording, let writer else { return nil }
            recording = false; paused = false
            if !chunk.isEmpty { onPCM?(Data(chunk)); chunk.removeAll(keepingCapacity: true) }
            writer.close()
            self.writer = nil
            if !warmActive { stopEngine() }
            return RecordingFile(url: writer.url, seconds: Double(writer.dataBytes) / 2 / Recorder.sampleRate)
        }
    }

    /// Отменить запись и удалить файл.
    public func discard() {
        if let file = end() { try? FileManager.default.removeItem(at: file.url) }
    }

    /// Вход по умолчанию и тип его подключения; nil — входа нет.
    public static func defaultInput() -> (device: AudioDeviceID, transport: WarmMicPolicy.Transport)? {
        guard let device = AudioInputs.systemDefaultID() else { return nil }
        return (device, AudioInputs.transport(of: device))
    }

    /// Вход захвата Mostik: выбранный в Настройках, а если его нет — системный (`MicChoice`).
    private func currentInput() -> (device: AudioDeviceID, transport: WarmMicPolicy.Transport, pinned: Bool)? {
        let choice = AudioInputs.resolve(uid: micUID)
        guard let device = choice.device else { return nil }
        return (device, AudioInputs.transport(of: device), choice.pinned)
    }

    // MARK: внутреннее — всё на `queue`

    /// Кэш проверок входа: тап зовёт `warmActive` 20 раз в секунду.
    private var inputSuitsWarm = false
    private var warmActive: Bool { warmWanted && inputSuitsWarm }

    private func applyWarm() { reconfigure() }

    /// Новый `AVAudioEngine` под текущий вход по умолчанию.
    private func rebuildEngine() {
        stopEngine()
        engine = AVAudioEngine()
        observe(engine)
    }

    private func startEngine() throws {
        let input = engine.inputNode
        // Выбранный микрофон — только этому движку, до формата и тапа; системный вход не трогаем.
        let chosen = currentInput()
        if let chosen, chosen.pinned { AudioInputs.bind(input, to: chosen.device) }
        VoiceProcessing.set(input, enabled: voiceProcessing)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInput }
        guard let conv = AVAudioConverter(from: format, to: target) else { throw RecorderError.converter }
        conv.downmix = true
        converterLock.lock(); converter = conv; converterLock.unlock()
        if tapInstalled { input.removeTap(onBus: 0) }
        // ~50 мс на буфер: волна в HUD живая, нагрузки мало.
        let frames = AVAudioFrameCount(max(256, format.sampleRate / 20))
        input.installTap(onBus: 0, bufferSize: frames, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        engineRunning = true
        boundDevice = chosen?.device
    }

    private func stopEngine() {
        guard engineRunning || tapInstalled else { return }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine.stop()
        engineRunning = false
        converterLock.lock(); converter = nil; converterLock.unlock()
    }

    /// Смена входа, формата, настройки или разрешения: решение — в `WarmMicPolicy`.
    /// Формат мог смениться и на том же устройстве, поэтому запущенный движок
    /// после уведомления всё равно пересобирает тап и конвертер.
    private func reconfigure(formatChanged: Bool = false) {
        // Выбранный микрофон закреплён: смена системного входа его не переключает (`MicChoice`).
        let input = currentInput()
        let authorized = Permissions.microphoneAuthorized
        inputSuitsWarm = authorized && WarmMicPolicy.suitsWarm(input?.transport)
        let state = WarmMicPolicy.State(warmWanted: warmWanted, authorized: authorized, recording: recording,
                                        running: engineRunning, boundDevice: boundDevice,
                                        currentDevice: input?.device, currentTransport: input?.transport)
        var action = WarmMicPolicy.decide(state)
        if action == .none, engineRunning, formatChanged { action = .restart }  // тот же вход, другой формат
        do {
            switch action {
            case .none: break
            case .stop: stopEngine()
            case .start(let rebuild):
                if rebuild { rebuildEngine() }
                try startEngine()
            case .restart:
                if input?.device != boundDevice { rebuildEngine() } else { stopEngine() }
                try startEngine()
            }
        } catch {
            NSLog("Mostik recorder: reconfigure failed: \(error)")
        }
        if !warmActive { ring.removeAll() }
    }

    /// Поток тапа: конвертация и уровень, дальше — на `queue`.
    private func process(_ buffer: AVAudioPCMBuffer) {
        converterLock.lock()
        guard let converter else { converterLock.unlock(); return }
        let ratio = Recorder.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            converterLock.unlock(); return
        }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        converterLock.unlock()
        guard error == nil, let samples = out.floatChannelData?[0] else { return }
        let count = Int(out.frameLength)
        guard count > 0 else { return }

        var sum: Float = 0
        var pcm = Data(count: count * 2)
        pcm.withUnsafeMutableBytes { raw in
            let dst = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                let s = max(-1, min(1, samples[i]))
                sum += s * s
                dst[i] = Int16(s * 32_767).littleEndian
            }
        }
        let rms = (sum / Float(count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        let level = max(0, min(1, (db + 55) / 50))

        queue.async {
            if self.recording, self.paused {
                self.onLevel?(0)
            } else if self.recording {
                self.onLevel?(level)
                self.consume(pcm)
            } else if self.warmActive {
                self.ring.append(pcm)
                if self.ring.count > Recorder.preRollBytes {
                    self.ring.removeFirst(self.ring.count - Recorder.preRollBytes)
                }
            }
        }
    }

    private func consume(_ pcm: Data) {
        if firstBufferPending, !pcm.isEmpty {
            firstBufferPending = false
            onFirstBuffer?()
        }
        watchSilence(pcm)
        writer?.append(pcm)
        chunk.append(pcm)
        while chunk.count >= Recorder.chunkBytes {
            onPCM?(Data(chunk.prefix(Recorder.chunkBytes)))
            chunk.removeFirst(Recorder.chunkBytes)
        }
    }
}

extension Recorder {
    /// Цифровые нули с начала записи — переподключаем вход по шагам `SilentInputWatch`. На `queue`.
    fileprivate func watchSilence(_ pcm: Data) {
        guard recording, !silence.heard else { return }
        let silent = pcm.allSatisfy { $0 == 0 }
        let seconds = Double(pcm.count) / 2 / Recorder.sampleRate
        let action = silence.feed(seconds: seconds, silent: silent, voiceProcessing: engine.inputNode.isVoiceProcessingEnabled)
        switch action {
        case .none:
            return
        case .dropVoiceProcessing:
            voiceProcessing = false
            restartForSilence()
        case .reconnect:
            restartForSilence()
        case .warn, .recovered:
            break
        }
        onSilentInput?(action)
    }

    /// Новый движок на том же входе; запись и WAV продолжаются.
    private func restartForSilence() {
        rebuildEngine()
        do { try startEngine() } catch { NSLog("Mostik recorder: restart after silence failed: \(error)") }
    }
}

/// Потоковая запись WAV (PCM16 моно): заголовок сразу, размеры — при закрытии.
final class WAVWriter {
    let url: URL
    private let handle: FileHandle
    private(set) var dataBytes = 0
    private let sampleRate: Int

    init(url: URL, sampleRate: Int) throws {
        self.url = url
        self.sampleRate = sampleRate
        FileManager.default.createFile(atPath: url.path, contents: WAVWriter.header(sampleRate: sampleRate, dataBytes: 0))
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        try? handle.write(contentsOf: data)
        dataBytes += data.count
    }

    func close() {
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: WAVWriter.header(sampleRate: sampleRate, dataBytes: dataBytes))
        try? handle.close()
    }

    static func header(sampleRate: Int, dataBytes: Int) -> Data {
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return d
    }

    /// Длительность WAV по заголовку (любой PCM); nil — не WAV.
    static func duration(of url: URL) -> Double? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096), head.count >= 44,
              head.prefix(4) == Data("RIFF".utf8) else { return nil }
        func u32(_ o: Int) -> Int { head[o..<o + 4].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) } }
        func u16(_ o: Int) -> Int { Int(head[o]) | Int(head[o + 1]) << 8 }
        var offset = 12
        var byteRate = 0
        while offset + 8 <= head.count {
            let id = String(decoding: head[offset..<offset + 4], as: UTF8.self)
            let size = u32(offset + 4)
            if id == "fmt " { byteRate = u32(offset + 16) }
            if id == "data" {
                guard byteRate > 0 else { return nil }
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                let bytes = size > 0 && size < Int(UInt32.max) ? size : fileSize - offset - 8
                return Double(min(bytes, max(0, fileSize - offset - 8))) / Double(byteRate)
            }
            offset += 8 + size + (size & 1)
        }
        return nil
    }
}

public enum WAVInfo {
    /// Длительность WAV-файла в секундах; nil — не WAV.
    public static func duration(of url: URL) -> Double? { WAVWriter.duration(of: url) }
}
