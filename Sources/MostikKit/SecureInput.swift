import Carbon.HIToolbox

/// Защищённый ввод (поле пароля Cocoa или браузера, «Защищённый ввод с клавиатуры» терминала): П10 р4 Р4-4л.
public enum SecureInput {
    public static var enabled: Bool { IsSecureEventInputEnabled() }
}
