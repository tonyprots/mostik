import Foundation

/// Жест клавиши удержания (H1, H4): что из сырых нажатий считать диктовкой.
/// Чистая логика — `HotkeyMonitor` переводит события AppKit в `Event` и исполняет `Action`.
///
/// - H1: удержание, начатое при уже зажатом другом модификаторе (⌘⌥…, ⇧⌥…), — не диктовка;
///   обычная клавиша во время удержания (⌥+буква) отменяет начатую им запись. Короткий тап
///   (< 0,3 с) отбрасывает `DictationMachine`, там же живёт двойное нажатие (D1).
/// - H4: «защёлка» — во время удержания добавили модификатор (правый ⌥ + ⇧): запись
///   продолжается без рук до следующего нажатия, как после двойного нажатия.
public struct HoldGesture: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        /// Клавиша удержания нажата; `otherModifiers` — уже зажат другой модификатор.
        case holdDown(otherModifiers: Bool)
        case holdUp
        /// Во время удержания добавился другой модификатор (⇧, ⌃, ⌘, левый ⌥).
        case modifierDown
        /// Обычная клавиша. `space` — пробел, который ловит переключатель ⌥Space.
        case keyDown(space: Bool)
        /// Esc; `recording` — идёт ли сейчас запись.
        case escape(recording: Bool)
        /// Сработал переключатель ⌥Space.
        case toggle
    }

    public enum Action: Equatable, Sendable { case begin, end, cancel, latch }

    public enum Phase: Equatable, Sendable {
        case up
        /// Клавиша зажата, но это не диктовка: её отпускание ничего не значит.
        case ignored
        /// Обычное удержание; `startedRecording` — оно само начало запись.
        case holding(startedRecording: Bool)
        /// Защёлкнуто (H4): запись идёт без рук, клавиша ещё зажата.
        case latched
    }

    public var latchEnabled: Bool
    public private(set) var phase: Phase = .up

    public init(latchEnabled: Bool = true) { self.latchEnabled = latchEnabled }

    /// Клавиша удержания физически зажата.
    public var isHeld: Bool { phase != .up }

    @discardableResult
    public mutating func handle(_ event: Event) -> [Action] {
        switch (phase, event) {
        case (.up, .holdDown(let other)):
            if other { phase = .ignored; return [] }
            phase = .holding(startedRecording: false)
            return [.begin]
        case (_, .holdDown):
            return []  // автоповтор флагов
        case (.holding, .holdUp):
            phase = .up
            return [.end]
        case (_, .holdUp):
            // Защёлка: отпускание не останавливает. Отменённое или чужое удержание — тоже.
            phase = .up
            return []
        case (.holding(true), .modifierDown) where latchEnabled:
            phase = .latched
            return [.latch]
        case (.holding(true), .keyDown(false)), (.latched, .keyDown(false)):
            // ⌥+буква или ⌥⇧+буква — набор символа, а не диктовка.
            phase = .ignored
            return [.cancel]
        case (_, .escape(let recording)):
            if phase != .up { phase = .ignored }
            return recording ? [.cancel] : []
        case (.holding(true), .toggle):
            // Правый ⌥ + Space: удержание превращается в переключатель.
            phase = .ignored
            return [.cancel]
        case (.holding, .toggle), (.latched, .toggle):
            phase = .ignored
            return []
        default:
            return []
        }
    }

    /// После `.begin`: началась ли запись на самом деле (могла не начаться — идёт
    /// расшифровка, нет микрофона, или нажатие остановило запись без рук).
    public mutating func recordingStarted(_ started: Bool) {
        if case .holding = phase { phase = .holding(startedRecording: started) }
    }

    /// Смена клавиши или перезапуск монитора.
    public mutating func reset() { phase = .up }
}
