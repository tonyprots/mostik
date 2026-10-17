import Foundation
import MostikCore

/// Итог `polish_text`: превью тона (P2) и проверка пакета.
public struct PolishTextReply: Equatable, Sendable {
    public var text: String
    public var polished: Bool
    /// `ok`, `timeout`, `rejected`, `answered`, `error`…
    public var status: String
    public var ms: Double
}

/// П6-А: контекст (P1), пакеты стилей (P4), причёсывание готового текста.
extension EngineClient {
    /// Контекст из приложения к идущей записи: приходит, пока человек говорит (P1).
    public func sendContext(session: String, context: [String: String]) {
        var fields: [String: JSONValue] = ["session": .string(session)]
        for (key, value) in context { fields[key] = .string(value) }
        send("context", fields: fields)
    }

    /// Пакеты стилей и папка с ними; `example` — сначала положить пример «Письмо коллегам».
    public func stylePacks(example: Bool = false) async throws -> (packs: [StylePackInfo], folder: String) {
        let reply = try await request("styles", fields: example ? ["example": .bool(true)] : [:], timeout: 15)
        var packs: [StylePackInfo] = []
        if case .array(let items)? = reply["packs"] {
            for item in items {
                guard case .object(let o) = item, let id = o["id"]?.stringValue else { continue }
                packs.append(StylePackInfo(id: id, name: o["name"]?.stringValue ?? id,
                                           terms: Int(o["terms"]?.doubleValue ?? 0),
                                           replacements: Int(o["replacements"]?.doubleValue ?? 0),
                                           path: o["path"]?.stringValue ?? ""))
            }
        }
        return (packs, reply["folder"]?.stringValue ?? "")
    }

    /// Причесать готовый текст тем же конвейером, что и диктовку: правила речи, пакет, перевод.
    public func polishText(_ text: String, language: String, polish: PolishRequest,
                           rules: SpeechRuleSettings? = nil) async throws -> PolishTextReply {
        var fields: [String: JSONValue] = ["text": .string(text), "language": .string(language),
                                           "polish": Self.polishField(polish)]
        if let payload = rules?.payload { fields["rules"] = .object(payload.mapValues { .bool($0) }) }
        let reply = try await request("polish_text", fields: fields, timeout: Self.polishTimeoutReserve + 5)
        return PolishTextReply(text: reply["text"]?.stringValue ?? text, polished: reply["polished"]?.boolValue ?? false,
                               status: reply["status"]?.stringValue ?? "", ms: reply["ms"]?.doubleValue ?? 0)
    }

    /// Поля `start` для П6-А: правила речи (P3, V4). Контекст уходит отдельной командой `context`.
    public static func polishExtraFields(rules: SpeechRuleSettings) -> [String: JSONValue] {
        guard let payload = rules.payload else { return [:] }
        return ["rules": .object(payload.mapValues { .bool($0) })]
    }
}
