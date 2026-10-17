import Foundation
import ServiceManagement
import MostikCore

/// Объект входа Mostik через `SMAppService.mainApp` (macOS 13+). Решения — в `MostikCore.LaunchAtLogin`.
public enum LoginItem {
    /// Только у собранного `.app`: у бинарника `swift run` нет бандла, который macOS могла бы запустить.
    public static var state: LaunchAtLogin.State {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    /// Привести объект входа к желанию. Ошибка `SMAppService` возвращается текстом — её показывает «Проверка».
    public static func sync(wanted: Bool) -> LoginItemFacts {
        let before = state
        var failure: String?
        do {
            switch LaunchAtLogin.action(wanted: wanted, state: before) {
            case .register?: try SMAppService.mainApp.register()
            case .unregister?: try SMAppService.mainApp.unregister()
            case nil: break
            }
        } catch {
            failure = error.localizedDescription
        }
        return LoginItemFacts(wanted: wanted, state: state, error: failure)
    }

    public static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
