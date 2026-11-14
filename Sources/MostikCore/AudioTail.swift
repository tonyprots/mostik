import Foundation

/// Хвост диктовки: клавишу отпустили, а последний буфер тапа ещё не пришёл — без ожидания
/// конец слова терялся. Ждём буфер, который накрывает момент отпускания.
public struct TailDrain: Equatable, Sendable {
    /// Дольше не ждём: буфер тапа ~100 мс, остальное — запас на планировщик.
    public static let timeout: TimeInterval = 0.25
    /// Столько буферов хватает, когда тап не даёт времени захвата.
    public static let buffersWithoutClock = 2

    /// Момент запроса по часам звукового тракта, секунды.
    public let requestedAt: Double
    public private(set) var buffers = 0

    public init(requestedAt: Double) { self.requestedAt = requestedAt }

    /// Пришёл буфер; `end` — время конца его звука по тем же часам, nil — тап времени не дал.
    /// true — хвост получен, запись можно закрывать.
    public mutating func feed(end: Double?) -> Bool {
        buffers += 1
        if let end, end >= requestedAt { return true }
        // Часы тапа отстали или молчат — не держим пользователя до таймаута.
        return buffers >= (end == nil ? Self.buffersWithoutClock : Self.buffersWithoutClock + 1)
    }
}

/// Дорожка встречи после перенастройки входа: пока устройство менялось, звук не шёл, и всё
/// записанное позже съезжало раньше относительно второй дорожки. Разрыв заполняем тишиной.
public struct TrackGap: Equatable, Sendable {
    /// Короче — обычный разброс прихода буферов, не разрыв.
    public static let minimum: TimeInterval = 0.05

    public private(set) var pending = false
    /// Откуда считаем разрыв по монотонным часам; nil — запись на паузе.
    private var from: Double?
    /// Разрыв, накопленный до паузы: на паузе стоят обе дорожки, её в тишину не считаем.
    private var banked: Double = 0

    public init() {}

    /// Вход перенастраивается; `lastAudioEnd` — когда кончился последний записанный буфер.
    public mutating func open(lastAudioEnd: Double, paused: Bool) {
        guard !pending else { return }
        pending = true
        from = paused ? nil : lastAudioEnd
    }

    public mutating func pause(at now: Double) {
        guard pending, let start = from else { return }
        banked += max(0, now - start)
        from = nil
    }

    public mutating func resume(at now: Double) {
        if pending, from == nil { from = now }
    }

    /// Первый записываемый буфер после разрыва начался в `bufferStart`: сколько секунд тишины дописать перед ним.
    public mutating func close(bufferStart: Double) -> Double {
        guard pending else { return 0 }
        let gap = banked + (from.map { max(0, bufferStart - $0) } ?? 0)
        pending = false; from = nil; banked = 0
        return gap >= Self.minimum ? gap : 0
    }
}

/// К чему привязана запись звука системы: устройство вывода, дающее агрегату часы, и частота, с
/// которой приходят буферы (под неё собран пересчёт в 16 кГц).
public struct SystemTapBinding: Equatable, Sendable {
    public var outputUID: String?
    public var rate: Double

    public init(outputUID: String?, rate: Double) {
        self.outputUID = outputUID
        self.rate = rate
    }
}

/// Запись звука системы идёт за устройством вывода. Агрегат создаётся один раз и берёт часы и частоту
/// у вывода, который был по умолчанию на старте. Подключили посреди встречи наушники — агрегат остаётся
/// на прежнем устройстве: в лучшем случае звук пересчитывается лишний раз относительно чужих часов, в
/// худшем (прежнее устройство отключилось или сменило частоту) буферы идут с другой частотой, чем та, на
/// которую собран пересчёт, и дорожка собеседников уезжает от микрофона. Поэтому на смену вывода или
/// частоты агрегат пересобирается, а разрыв на время пересборки заполняется тишиной (`TrackGap`).
public struct SystemTapFollow: Equatable, Sendable {
    /// Смена устройства приходит пачкой уведомлений (устройство появилось, стало выводом, выбрало
    /// частоту): пересобираем один раз, когда они стихли.
    public static let settle: TimeInterval = 0.4
    /// Пересборка не удалась (новое устройство ещё не готово) — повтор через столько секунд.
    public static let retryAfter: TimeInterval = 1
    public static let maxRetries = 3
    /// Чаще пересобирать нельзя: устройство, которое ещё выбирает частоту, гоняло бы тап по кругу.
    public static let minSpacing: TimeInterval = 2
    /// Частоты ближе этого — одна и та же.
    public static let rateTolerance = 0.5

    public enum Decision: Equatable, Sendable {
        case keep
        case rebuild
    }

    public private(set) var bound: SystemTapBinding
    public private(set) var failures = 0

    public init(bound: SystemTapBinding) { self.bound = bound }

    /// `current` — вывод по умолчанию сейчас и частота, с которой сейчас работает агрегат.
    public func decide(current: SystemTapBinding) -> Decision {
        // Вывода нет совсем — привязываться не к чему; замолчавшую дорожку поднимет сторож встречи.
        guard let wanted = current.outputUID else { return .keep }
        if wanted != bound.outputUID { return .rebuild }
        if current.rate > 0, abs(current.rate - bound.rate) > Self.rateTolerance { return .rebuild }
        return .keep
    }

    public mutating func rebuilt(_ binding: SystemTapBinding) {
        bound = binding
        failures = 0
    }

    /// Пересборка не удалась: через сколько секунд повторить; nil — хватит, дальше дорожку ведёт сторож.
    public mutating func failed() -> TimeInterval? {
        failures += 1
        return failures <= Self.maxRetries ? Self.retryAfter : nil
    }
}
