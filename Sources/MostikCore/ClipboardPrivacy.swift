import Foundation

/// Буфер обмена и пароли (П10, низкие): записи менеджеров паролей помечены типами
/// nspasteboard.org. Такой снимок Mostik не восстанавливает (иначе ломается автоочистка
/// 1Password и Bitwarden, сверяющая changeCount) и в контекст причёсывания не берёт.
public enum ClipboardPrivacy {
    public static let concealed = "org.nspasteboard.ConcealedType"
    public static let transient = "org.nspasteboard.TransientType"
    /// Маркеры 1Password (старый и новый).
    public static let passwordManagers = ["com.agilebits.onepassword", "com.agilebits.onepassword.ConcealedType"]

    /// Типы одной записи буфера говорят «пароль или временная запись».
    public static func isSensitive(_ types: [String]) -> Bool {
        types.contains { $0 == concealed || $0 == transient || passwordManagers.contains($0) }
    }

    /// Можно ли вернуть снимок буфера после вставки: ни одной чувствительной записи.
    public static func restorable(_ items: [[String]]) -> Bool {
        !items.contains(where: isSensitive)
    }

    /// Чем помечать запасную запись диктовки в буфер (текст для ⌘V руками): менеджеры буфера
    /// её не сохраняют, а Concealed не ставим — иначе вставить её было бы неоткуда видно.
    public static let fallbackMarkers = [transient]
}
