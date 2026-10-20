import Foundation

/// Тёплый микрофон (П8, находка ревью): что делать со звуковым движком, когда сменился вход
/// по умолчанию или пришло `AVAudioEngineConfigurationChange`.
///
/// Баг: после Bluetooth-гарнитуры вход вернулся на встроенный, а тёплый микрофон так и не
/// включился. Пока вход был Bluetooth, движок стоял, и уведомление о смене конфигурации
/// остановленному `AVAudioEngine` не приходит; а его `inputNode` остаётся привязан к устройству,
/// которое было по умолчанию при создании. Поэтому смену входа слушаем через Core Audio
/// (`kAudioHardwarePropertyDefaultInputDevice`), а на новом устройстве собираем движок заново.
public enum WarmMicPolicy {
    /// Тип подключения входа (`kAudioDevicePropertyTransportType`), без зависимости от Core Audio.
    public enum Transport: Equatable, Sendable {
        case builtIn, usb, pci, fireWire, thunderbolt, bluetooth, bluetoothLE, airPlay, aggregate, virtual, unknown
    }

    /// Тёплым держим только встроенный и проводной вход: Bluetooth-гарнитура от открытого
    /// микрофона уходит в режим HFP и портит звук, AirPlay и виртуальные входы — не микрофон.
    public static func suitsWarm(_ transport: Transport?) -> Bool {
        switch transport {
        case .builtIn?, .usb?, .pci?, .fireWire?, .thunderbolt?: return true
        default: return false
        }
    }

    public struct State: Equatable, Sendable {
        /// Пользователь хочет тёплый микрофон (настройка, не разряженная батарея).
        public var warmWanted: Bool
        public var authorized: Bool
        public var recording: Bool
        /// Звуковой движок сейчас запущен.
        public var running: Bool
        /// Устройство, к которому привязан текущий звуковой движок; nil — ещё не запускался.
        public var boundDevice: UInt32?
        /// Вход захвата сейчас: выбранный в Настройках, а без него — системный (`MicChoice`); nil — входа нет.
        /// Пока выбранный подключён, смена системного входа это значение не меняет — и движок не пересобирается.
        public var currentDevice: UInt32?
        public var currentTransport: Transport?

        public init(warmWanted: Bool, authorized: Bool, recording: Bool, running: Bool,
                    boundDevice: UInt32?, currentDevice: UInt32?, currentTransport: Transport?) {
            self.warmWanted = warmWanted; self.authorized = authorized; self.recording = recording
            self.running = running; self.boundDevice = boundDevice; self.currentDevice = currentDevice
            self.currentTransport = currentTransport
        }

        /// Тёплый микрофон сейчас уместен.
        public var warmActive: Bool { warmWanted && authorized && WarmMicPolicy.suitsWarm(currentTransport) }
    }

    public enum Action: Equatable, Sendable {
        case none
        /// Запустить; `rebuild` — сначала пересоздать `AVAudioEngine` (вход сменился).
        case start(rebuild: Bool)
        /// Остановить (тёплый больше не нужен или вход не годится).
        case stop
        /// Перезапустить на новом входе: остановить, пересоздать, запустить.
        case restart
    }

    /// Сколько ждать тишины от Core Audio, прежде чем трогать движок по внешнему сигналу.
    ///
    /// Сбой 2026-10-19: Bluetooth-вывод, запись старт → отмена → старт за 400 мс. HAL пересобирал
    /// агрегат входа, движок прислал `AVAudioEngineConfigurationChange`, и мы сразу остановили его,
    /// пока он ещё работал, — IO-поток CoreAudio упал по нулевому адресу (SIGSEGV в
    /// `HALC_ProxyIOContext::IOWorkLoop`). Сигналы приходят пачкой: ждём, пока устройство затихнет.
    public static let settleDelay: TimeInterval = 0.3

    /// Отложенная перенастройка: пачка сигналов → одна перенастройка после `settleDelay` тишины.
    /// Формат сменился хоть в одном сигнале — перезапуск нужен и после склейки.
    public struct Settle: Equatable, Sendable {
        /// Номер последнего сигнала: сработать должен только таймер последнего.
        public private(set) var generation = 0
        public private(set) var formatChanged = false
        public private(set) var pending = false

        public init() {}

        /// Пришёл сигнал; вернуть номер, с которым ставить таймер.
        public mutating func signal(formatChanged: Bool) -> Int {
            generation += 1
            self.formatChanged = self.formatChanged || formatChanged
            pending = true
            return generation
        }

        /// Таймер сработал. nil — после него были сигналы (сработает их таймер) или уже обработано;
        /// иначе — `formatChanged` всей пачки, и ожидание сброшено.
        public mutating func fire(_ generation: Int) -> Bool? {
            guard pending, generation == self.generation else { return nil }
            defer { pending = false; formatChanged = false }
            return formatChanged
        }
    }

    public static func decide(_ s: State) -> Action {
        let deviceChanged = s.boundDevice != nil && s.currentDevice != nil && s.boundDevice != s.currentDevice
        let needsAudio = s.recording || s.warmActive
        guard needsAudio, s.currentDevice != nil else { return s.running ? .stop : .none }
        if s.running { return deviceChanged ? .restart : .none }
        return .start(rebuild: deviceChanged)
    }
}
