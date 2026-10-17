import Foundation
import MostikCore

/// Модели по кнопке (П8, пункт 5): манифест, загрузка с докачкой, остановка.
extension EngineClient {
    /// Что из манифеста стоит в кэше; в сеть движок не ходит.
    public func models() async throws -> [ModelRow] {
        ModelCatalog.rows(from: try await request("models", timeout: 30))
    }

    /// Качает `keys` (пусто — обязательные недостающие). Ход — событиями `.progress(task: "models:<key>")`,
    /// ответ — когда всё скачано и проверено. Гигабайты на медленной сети — часы, отсюда таймаут.
    public func downloadModels(keys: [String]) async throws -> [ModelRow] {
        var fields: [String: JSONValue] = ["keys": .array(keys.map { .string($0) })]
        // Зеркало моделей из окружения — только в debug-сборке; движок сам окружение не читает.
        if let base = DebugOverrides.modelsBaseURL(environment: ProcessInfo.processInfo.environment) {
            fields["base_url"] = .string(base)
        }
        let reply = try await request("models_download", fields: fields, timeout: 24 * 3600)
        return ModelCatalog.rows(from: reply)
    }

    public func cancelModelDownload() async {
        _ = try? await request("models_cancel", timeout: 10)
    }
}
