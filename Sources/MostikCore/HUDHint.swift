import Foundation

/// Подсказка управления в плашке записи (П9-B, R3b): через 2 с записи справа появляется
/// «Отпустите правый ⌥ · Отмена esc» (без рук — «Стоп ⌥ · Отмена esc»), клавиши — капсулами. Клавиша стопа — та, что выбрана в Настройках
/// (`MostikSettings.holdKey`), Esc отменяет запись всегда (`HoldGesture.escape`).
/// Отмена пишется словом «esc», а не глифом ⎋: мелкий ⎋ читается как ↺ «повторить».
/// Чистая логика — покрыта тестами.
public enum HUDHint {
    /// Через сколько секунд записи появляется подсказка: короткая диктовка обходится без неё.
    public static let delay: TimeInterval = 2

    /// Пункт подсказки: действие словом и клавиша, которую плашка рисует капсулой.
    public struct Control: Equatable, Sendable {
        public let action: String
        public let key: String
        /// Как клавишу произносит VoiceOver: «правый Option», а не «⌥».
        public let spokenKey: String
    }

    /// Знак клавиши диктовки: правый ⌥, правый ⌘ или fn.
    public static func keySymbol(_ holdKey: String) -> String {
        switch holdKey {
        case "rightCommand": return "⌘"
        case "fn": return "fn"
        default: return "⌥"
        }
    }

    /// Название клавиши диктовки для VoiceOver.
    public static func spokenKey(_ holdKey: String) -> String {
        switch holdKey {
        case "rightCommand": return UIText.pick("правый Command", "right Command")
        case "fn": return "fn"
        default: return UIText.pick("правый Option", "right Option")
        }
    }

    /// Действие стопа словами. Удержание — «Отпустите правый ⌥»: так говорят о клавише, которую держат;
    /// у fn стороны нет. Без рук (двойное нажатие, защёлка) клавишу уже отпустили — тогда «Стоп ⌥».
    static func stopAction(holdKey: String, handsFree: Bool) -> String {
        if handsFree { return UIText.pick("Стоп", "Stop") }
        if holdKey == "fn" { return UIText.pick("Отпустите", "Release") }
        return UIText.pick("Отпустите правый", "Release right")
    }

    /// Пункты подсказки или nil, пока запись короче `delay`: сначала стоп, потом отмена.
    public static func items(holdKey: String, elapsed: TimeInterval, handsFree: Bool = false) -> [Control]? {
        guard elapsed >= delay else { return nil }
        return [
            Control(action: stopAction(holdKey: holdKey, handsFree: handsFree), key: keySymbol(holdKey), spokenKey: spokenKey(holdKey)),
            Control(action: UIText.pick("Отмена", "Cancel"), key: "esc", spokenKey: "Esc"),
        ]
    }

    /// Подсказка одной строкой: «Отпустите правый ⌥ · Отмена esc».
    public static func controls(holdKey: String, elapsed: TimeInterval, handsFree: Bool = false) -> String? {
        items(holdKey: holdKey, elapsed: elapsed, handsFree: handsFree)?.map { "\($0.action) \($0.key)" }.joined(separator: " · ")
    }

    /// Фраза для VoiceOver: «Отпустите правый Option, чтобы закончить; отмена — Esc».
    public static func spoken(holdKey: String, handsFree: Bool = false) -> String {
        let key = spokenKey(holdKey)
        if handsFree {
            return UIText.pick("Стоп — \(key), отмена — Esc", "Stop: \(key), cancel: Esc")
        }
        return UIText.pick("Отпустите \(key), чтобы закончить; отмена — Esc", "Release \(key) to finish, Esc to cancel")
    }
}
