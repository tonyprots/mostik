import Foundation

/// Клавиши удержания: запись и голосовая правка (решение автора).
/// Запись — клавиша из Настроек (`MostikSettings.holdKey`). Голосовая правка — правый ⌘,
/// а если правый ⌘ уже держит запись, правка переходит на правый ⌥. Так две функции
/// никогда не делят одну клавишу и предупреждение о конфликте не нужно.
public enum HoldKeys {
    public static let rightOption = "rightOption"
    public static let rightCommand = "rightCommand"
    public static let fn = "fn"

    /// Клавиша голосовой правки при данной клавише записи.
    public static func voiceEditKey(holdKey: String) -> String {
        holdKey == rightCommand ? rightOption : rightCommand
    }

    /// Название клавиши для текста интерфейса: «правый ⌥», «правый ⌘», «fn».
    public static func name(_ key: String) -> String {
        switch key {
        case rightCommand: return UIText.pick("правый ⌘", "right ⌘")
        case fn: return "fn"
        default: return UIText.pick("правый ⌥", "right ⌥")
        }
    }

    /// То же с заглавной буквы — для начала фразы: «Правый ⌥».
    public static func capitalizedName(_ key: String) -> String {
        let n = name(key)
        return n.prefix(1).uppercased() + n.dropFirst()
    }
}

extension MostikSettings {
    /// Клавиша голосовой правки при текущей клавише записи.
    public var voiceEditKey: String { HoldKeys.voiceEditKey(holdKey: holdKey) }
}
