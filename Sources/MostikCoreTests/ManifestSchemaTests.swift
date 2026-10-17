import Foundation
import MostikCore

/// Манифест, который пишет приложение, против `docs/schemas/meeting-manifest.schema.json`.
/// Python проверяет свою половину в `engine/tests/test_meeting_folder.py`; здесь — заплатки Swift.
func runManifestSchemaTests() {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let url = root.appendingPathComponent("docs/schemas/meeting-manifest.schema.json")
    guard let data = try? Data(contentsOf: url),
          let schema = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        check(false, "схема манифеста не читается: \(url.path)")
        return
    }

    // Валидатор понимает то, что есть в схеме, — и падает на всём остальном.
    do {
        equal(SchemaCheck.errors(["n": 1], ["properties": ["n": ["type": "integer", "minimum": 0]]]), [])
        equal(SchemaCheck.errors(["n": -1], ["properties": ["n": ["type": "integer", "minimum": 0]]]).count, 1, "minimum")
        equal(SchemaCheck.errors(["n": ["mic": 1]], ["properties": ["n": ["type": "integer"]]]).count, 1, "объект вместо целого")
        equal(SchemaCheck.errors(["n": true], ["properties": ["n": ["type": "integer"]]]).count, 1, "bool — не число")
        equal(SchemaCheck.errors(["n": 1.5], ["properties": ["n": ["type": "integer"]]]).count, 1, "дробное — не целое")
        equal(SchemaCheck.errors([:], ["required": ["a"]]).count, 1, "required")
        equal(SchemaCheck.errors("x", ["enum": ["a", "b"]]).count, 1, "enum")
        equal(SchemaCheck.errors(NSNull(), ["type": ["string", "null"]]), [], "null из списка типов")
        equal(SchemaCheck.errors(["x"], ["items": ["enum": ["mic"]]]).count, 1, "items")
        equal(SchemaCheck.errors("x", ["pattern": "x"]).count, 1, "незнакомое слово схемы — ошибка, не тишина")
    }

    // Все заплатки, которыми приложение правит манифест, в одной папке — и после каждой файл по схеме.
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("mostik-schema-\(UUID().uuidString)/2026-10-11-153000")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
    for name in ["mic.wav", "system.wav", "mic.2.wav"] {
        FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data([0]))
    }
    let now = Date(timeIntervalSince1970: 1_760_185_800)
    let segments = [MeetingSegment(track: .mic, file: "mic.wav", offset: 0),
                    MeetingSegment(track: .system, file: "system.wav", offset: 0),
                    MeetingSegment(track: .mic, file: "mic.2.wav", offset: 12.345)]

    var watchdog = MeetingWatchdog(startedAt: 0)
    for t in stride(from: 0.5, through: 2.5, by: 0.5) { watchdog.buffer(.system, at: t) }
    watchdog.buffer(.system, at: 5)
    equal(watchdog.tick(at: 5.5), [.restart(.mic, attempt: 1)])
    var restarted = watchdog.manifestRestarts
    restarted["segments"] = segments.map(\.manifestValue)
    equal(restarted["restarts"] as? Int, 1, "restarts — целое")
    equal(restarted["restarts_by_track"] as? [String: Int], ["mic": 1])

    let patches: [(String, [String: Any])] = [
        ("начало записи", [
            "started": MeetingFolder.iso(now), "app": "Телемост", "sensitive": true,
            "title": "Синк", "title_source": "calendar",
            "calendar": ["event_id": "e1", "title": "Синк", "start": MeetingFolder.iso(now),
                         "end": MeetingFolder.iso(now), "link": "https://telemost.yandex.ru/j/1"],
            "attendees": [["name": "Анна", "self": false]],
            "agenda": ["Бюджет"],
            "recording": ["status": "recording", "started_at": MeetingFolder.iso(now),
                          "segments": segments.prefix(2).map(\.manifestValue)],
        ]),
        ("продолжение", ["started": NSNull(), "recording": ["started_at": NSNull(), "continued_at": MeetingFolder.iso(now)]]),
        ("перезапуск дорожки", ["recording": restarted]),
        ("сторож сдался", ["recording": ["gave_up": ["mic"]]]),
        ("тишина", ["recording": ["warnings": ["system_silent"]]]),
        ("конец записи", ["recording": ["status": watchdog.status, "ended_at": MeetingFolder.iso(now),
                                        "segments": segments.map(\.manifestValue)],
                          "ended": MeetingFolder.iso(now), "duration_seconds": 1930.4,
                          "transcript": ["status": "pending"]]),
        ("восстановление", ["recording": ["status": "incomplete"],
                            "transcript": ["status": "failed", "error": "Не удалось дорасшифровать после сбоя"]]),
        ("хук", MeetingHook.manifestPatch(date: now, exitCode: 0, timedOut: false, skipped: nil)),
        ("хук пропущен", MeetingHook.manifestPatch(date: now, exitCode: nil, timedOut: false, skipped: "sensitive")),
        ("только текст", ["text_only": TextOnlyRanges.manifestValue([.init(start: 1, end: 2.25)], whole: false)]),
        ("аудио в Корзину", ["audio": ["kept": false, "trashed_at": MeetingFolder.iso(now), "trashed": ["mic.wav"]]]),
    ]
    for (name, patch) in patches {
        MeetingFolder.update(folder, patch, now: now)
        let manifest = MeetingFolder.readManifest(folder) ?? [:]
        equal(SchemaCheck.errors(manifest, schema), [], "манифест после «\(name)»")
    }

    // «Только текст» целиком: звук стирается, манифест по-прежнему по схеме.
    MeetingFolder.update(folder, ["text_only": TextOnlyRanges.manifestValue([.init(start: 0, end: 10)], whole: true)], now: now)
    _ = TextOnlyAudio.purge(folder, now: now)
    equal(SchemaCheck.errors(MeetingFolder.readManifest(folder) ?? [:], schema), [], "манифест после стирания звука")
}

/// Подмножество JSON Schema, которым написаны `docs/schemas/*.json`.
enum SchemaCheck {
    static let known: Set<String> = [
        "$schema", "$id", "title", "description", "type", "required", "properties", "items",
        "enum", "const", "minimum", "additionalProperties",
    ]

    static func errors(_ value: Any, _ schema: [String: Any], path: String = "$") -> [String] {
        var out: [String] = []
        for key in schema.keys where !known.contains(key) { out.append("\(path): слово схемы «\(key)» не поддержано") }
        if let c = schema["const"], !same(value, c) { out.append("\(path): ожидалось \(c)") }
        if let options = schema["enum"] as? [Any], !options.contains(where: { same(value, $0) }) {
            out.append("\(path): \(value) не из \(options)")
        }
        if let type = schema["type"] {
            let kinds = (type as? [String]) ?? [type as? String ?? ""]
            if !kinds.contains(where: { matches(value, $0) }) {
                return out + ["\(path): \(value) — не \(kinds)"]
            }
        }
        if let minimum = number(schema["minimum"]), let n = number(value), n < minimum {
            out.append("\(path): \(n) < \(minimum)")
        }
        if let object = value as? [String: Any] {
            for key in schema["required"] as? [String] ?? [] where object[key] == nil { out.append("\(path): нет \(key)") }
            let properties = schema["properties"] as? [String: Any] ?? [:]
            for (key, sub) in properties {
                if let v = object[key], let sub = sub as? [String: Any] { out += errors(v, sub, path: "\(path).\(key)") }
            }
            if (schema["additionalProperties"] as? Bool) == false {
                for key in object.keys where properties[key] == nil { out.append("\(path): лишний ключ \(key)") }
            }
        }
        if let array = value as? [Any], let items = schema["items"] as? [String: Any] {
            for (i, item) in array.enumerated() { out += errors(item, items, path: "\(path)[\(i)]") }
        }
        return out
    }

    static func isBool(_ v: Any) -> Bool {
        if v is Bool, !(v is NSNumber) { return true }
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    static func number(_ v: Any?) -> Double? {
        guard let v, !isBool(v) else { return nil }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }

    static func matches(_ v: Any, _ kind: String) -> Bool {
        switch kind {
        case "null": return v is NSNull
        case "boolean": return isBool(v)
        case "string": return v is String
        case "object": return v is [String: Any]
        case "array": return v is [Any]
        case "number": return number(v) != nil
        case "integer": return number(v).map { $0 == $0.rounded() } ?? false
        default: return false
        }
    }

    static func same(_ a: Any, _ b: Any) -> Bool {
        if let x = a as? String, let y = b as? String { return x == y }
        if isBool(a) || isBool(b) { return isBool(a) && isBool(b) && (a as? Bool) == (b as? Bool) }
        if let x = number(a), let y = number(b) { return x == y }
        return a is NSNull && b is NSNull
    }
}
