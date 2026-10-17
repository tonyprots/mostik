import Foundation

/// Залипший микрофон: движок записи «запущен», буферы идут, но в них
/// цифровые нули. Живой микрофон ровного нуля не даёт даже в тишине — шум есть всегда, — поэтому
/// признак — ни одного ненулевого отсчёта за `window` секунд с начала записи.
///
/// Вход был встроенный, а включено «Шумоподавление» (обработка голоса Apple): его
/// выключение без перезапуска не помогало — обработка остаётся на уже созданном движке.
/// Поэтому первый шаг при включённой обработке — собрать движок без неё, затем — просто заново,
/// и только потом сказать человеку, что микрофон молчит.
public struct SilentInputWatch: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case none
        /// Собрать движок записи заново на том же входе.
        case reconnect
        /// Собрать движок без обработки голоса: с ней вход отдавал нули.
        case dropVoiceProcessing
        /// Шаги кончились — сказать, что микрофон молчит.
        case warn
        /// После шага пошёл звук.
        case recovered
    }

    /// Сколько секунд сплошных нулей ждём перед каждым шагом. Обработка голоса Apple на старте
    /// отдаёт нули до ~0,3 с — порог с запасом.
    public static let window: Double = 1.2

    public private(set) var zeroSeconds: Double = 0
    public private(set) var heard = false
    public private(set) var steps: [Action] = []

    public init() {}

    /// Кусок записи: `seconds` — длительность, `silent` — все отсчёты ровно 0,
    /// `voiceProcessing` — включена ли обработка голоса на движке сейчас.
    public mutating func feed(seconds: Double, silent: Bool, voiceProcessing: Bool) -> Action {
        guard !heard else { return .none }
        guard silent else {
            heard = true
            return steps.isEmpty ? .none : .recovered
        }
        guard steps.last != .warn else { return .none }
        zeroSeconds += seconds
        guard zeroSeconds >= Self.window else { return .none }
        zeroSeconds = 0
        let next: Action
        if voiceProcessing && !steps.contains(.dropVoiceProcessing) {
            next = .dropVoiceProcessing
        } else if !steps.contains(.reconnect) {
            next = .reconnect
        } else {
            next = .warn
        }
        steps.append(next)
        return next
    }

    /// Запись так и не дала звука, хотя шаги были.
    public var gaveUp: Bool { steps.last == .warn && !heard }
}
