import Foundation
import MostikCore

/// Голосовые команды-намерения (D6): разбор готового текста диктовки в черновик.
extension EngineClient {
    /// `intent {text, language, now, backend}`. `backend` — тот же, что у причёсывания:
    /// `off` — только правила, `claude` или `mlx` — правила и модель.
    public func voiceIntent(text: String, language: String, now: Date = Date(),
                            backend: PolishBackend) async throws -> VoiceIntentReply {
        let fields: [String: JSONValue] = [
            "text": .string(text), "language": .string(language),
            "now": .string(VoiceIntentPlan.localStamp(now)), "backend": .string(backend.rawValue),
        ]
        // Таймаут модели в движке — 20 с; сверху запас на запуск процесса локальной модели.
        let reply = try await request("intent", fields: fields, timeout: 30)
        return VoiceIntentReply(payload: reply)
    }
}
