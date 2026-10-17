import Foundation

/// Автозапуск при входе в macOS: что хотим и что сделать с объектом входа. Сам вызов `SMAppService` —
/// в `MostikKit.LoginItem`; здесь только решения, чтобы их можно было проверить тестом.
public enum LaunchAtLogin {
    /// Состояние объекта входа по `SMAppService.mainApp.status`.
    public enum State: Equatable, Sendable {
        case enabled, notRegistered, requiresApproval, notFound
        /// Не собранный `.app` (`swift run`): регистрировать нечего.
        case unavailable
    }

    public enum Action: Equatable, Sendable { case register, unregister }

    /// Автозапуск нужен, когда онбординг пройден и галочка стоит. До конца онбординга объект входа
    /// не трогаем: человек ещё не видел выбора.
    public static func wanted(_ s: MostikSettings) -> Bool { s.onboarded && s.launchAtLogin }

    /// Что сделать, чтобы состояние совпало с желанием; nil — ничего.
    /// `requiresApproval` не перерегистрируем: это выбор человека в Системных настройках, «Проверка» о нём скажет.
    public static func action(wanted: Bool, state: State) -> Action? {
        switch (wanted, state) {
        case (_, .unavailable): return nil
        case (true, .notRegistered), (true, .notFound): return .register
        case (false, .enabled), (false, .requiresApproval): return .unregister
        default: return nil
        }
    }
}

/// Факты для строки «Проверки».
public struct LoginItemFacts: Equatable, Sendable {
    public var wanted: Bool
    public var state: LaunchAtLogin.State
    /// Текст ошибки последней регистрации или снятия; nil — ошибки не было.
    public var error: String?

    public init(wanted: Bool, state: LaunchAtLogin.State, error: String? = nil) {
        self.wanted = wanted; self.state = state; self.error = error
    }
}
