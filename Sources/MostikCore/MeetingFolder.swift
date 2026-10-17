import Foundation

/// Папка встречи как контракт (M10): приложение читает и дописывает `manifest.json` тем же правилом,
/// что и движок (`engine/mostik_engine/meeting_folder.py`): прочитать, слить свои ключи, записать атомарно.
/// Описание формата — `docs/meeting-folder.md`.
public enum MeetingFolder {
    public static let manifestName = "manifest.json"
    public static let meetingName = "meeting.md"
    public static let notesName = "notes.md"
    public static let transcriptName = "transcript.json"
    public static let schema = "mostik.meeting"
    public static let version = 1

    public static func manifestURL(_ folder: URL) -> URL { folder.appendingPathComponent(manifestName) }

    /// Манифест как словарь; нет файла или он битый — nil.
    public static func readManifest(_ folder: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: manifestURL(folder)),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return value
    }

    /// Словари сливаются по ключам, остальное заменяется целиком (как `deep_merge` движка).
    public static func merge(_ base: [String: Any], _ patch: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in patch {
            if let sub = value as? [String: Any], let old = result[key] as? [String: Any] {
                result[key] = merge(old, sub)
            } else {
                result[key] = value
            }
        }
        return result
    }

    /// Прочитать (или создать), слить `patch`, записать атомарно. NSNull в patch — `null` в JSON.
    @discardableResult
    public static func update(_ folder: URL, _ patch: [String: Any], now: Date = Date()) -> [String: Any] {
        let current = readManifest(folder) ?? base(folder, now: now)
        var merged = merge(current, patch)
        merged["schema"] = schema
        merged["version"] = max(version, (merged["version"] as? Int) ?? version)
        merged["id"] = folder.lastPathComponent
        merged["updated_at"] = iso(now)
        var audio = merged["audio"] as? [String: Any] ?? [:]
        audio["files"] = audioFiles(folder)
        merged["audio"] = audio
        merged["files"] = presentFiles(folder)
        if let data = try? JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys]) {
            let tmp = folder.appendingPathComponent(".\(manifestName).app.tmp")
            if (try? data.write(to: tmp)) != nil {
                _ = try? FileManager.default.replaceItemAt(manifestURL(folder), withItemAt: tmp)
                if FileManager.default.fileExists(atPath: tmp.path) {
                    // Первой записи заменять нечего.
                    try? FileManager.default.moveItem(at: tmp, to: manifestURL(folder))
                }
            }
        }
        return merged
    }

    public static func base(_ folder: URL, now: Date = Date()) -> [String: Any] {
        [
            "schema": schema, "version": version, "id": folder.lastPathComponent,
            "title": NSNull(), "title_source": "default",
            "started": folderDate(folder.lastPathComponent).map(iso) ?? NSNull(),
            "ended": NSNull(), "duration_seconds": NSNull(), "language": NSNull(),
            "attendees": [Any](), "calendar": NSNull(), "sensitive": false,
            "recording": ["status": "complete", "restarts": 0, "segments": [Any](), "warnings": [Any]()],
            "transcript": ["status": "pending", "attempts": 0, "error": NSNull()],
            "summary": ["status": "none", "mode": NSNull()],
            "audio": ["kept": true, "trashed_at": NSNull(), "files": [Any]()],
            "files": [String: Any](), "created_by": "mostik", "created_at": iso(now),
        ]
    }

    static let fileKeys: [(String, String)] = [
        ("meeting_md", meetingName), ("notes_md", notesName), ("transcript_json", transcriptName),
        ("transcript_md", "transcript.md"), ("summary_md", "summary.md"), ("notes_json", "notes.json"),
    ]

    public static func presentFiles(_ folder: URL) -> [String: String] {
        var result: [String: String] = [:]
        for (key, name) in fileKeys where FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            result[key] = name
        }
        return result
    }

    /// `mic.wav`, `system.wav` и сегменты `mic.2.wav`… (M12).
    public static func audioFiles(_ folder: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter(isAudioName).sorted()
    }

    public static func isAudioName(_ name: String) -> Bool {
        name.range(of: #"^(mic|system)(\.\d+)?\.wav$"#, options: .regularExpression) != nil
    }

    /// Время начала из имени папки `yyyy-MM-dd-HHmmss` (старое — `yyyy-MM-dd-HHmm`, бывает суффикс `-2`).
    public static func folderDate(_ name: String) -> Date? {
        guard let match = name.range(of: #"^\d{4}-\d{2}-\d{2}-(\d{6}|\d{4})"#, options: .regularExpression) else { return nil }
        let stem = String(name[match])
        let rest = name[match.upperBound...]
        guard rest.isEmpty || rest.range(of: #"^-\d+$"#, options: .regularExpression) != nil else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = stem.count == 17 ? "yyyy-MM-dd-HHmmss" : "yyyy-MM-dd-HHmm"
        return f.date(from: stem)
    }

    public static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: date)
    }

    // MARK: чувствительность (W13)

    /// Флаг манифеста ИЛИ `sensitive: true` в шапке `meeting.md` — то же правило, что у движка и MCP.
    public static func isSensitive(_ folder: URL) -> Bool {
        if (readManifest(folder)?["sensitive"] as? Bool) == true { return true }
        guard let text = try? String(contentsOf: folder.appendingPathComponent(meetingName), encoding: .utf8) else {
            return false
        }
        return frontMatterSensitive(text) == true
    }

    /// Значение `sensitive:` в YAML-шапке; нет шапки или ключа — nil.
    public static func frontMatterSensitive(_ text: String) -> Bool? {
        guard let block = frontMatterBlock(text) else { return nil }
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("sensitive:") else { continue }
            let value = trimmed.dropFirst("sensitive:".count).trimmingCharacters(in: .whitespaces).lowercased()
            if ["true", "yes", "on"].contains(value) { return true }
            if ["false", "no", "off"].contains(value) { return false }
        }
        return nil
    }

    static func frontMatterBlock(_ text: String) -> Substring? {
        guard text.hasPrefix("---\n") else { return nil }
        let body = text.dropFirst(4)
        guard let end = body.range(of: "\n---") else { return nil }
        return body[..<end.lowerBound]
    }

    /// Поставить флаг: манифест + строка шапки `meeting.md` (движок такую правку человеческой не считает).
    public static func setSensitive(_ folder: URL, _ value: Bool) {
        update(folder, ["sensitive": value])
        let url = folder.appendingPathComponent(meetingName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let patched = patchFrontMatterSensitive(text, value)
        if patched != text { try? patched.write(to: url, atomically: true, encoding: .utf8) }
    }

    public static func patchFrontMatterSensitive(_ text: String, _ value: Bool) -> String {
        guard let block = frontMatterBlock(text) else { return text }
        var lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let i = lines.firstIndex(where: { $0.hasPrefix("sensitive:") }) {
            lines[i] = "sensitive: \(value)"
        } else {
            lines.append("sensitive: \(value)")
        }
        let rest = text[block.endIndex...]
        return "---\n" + lines.joined(separator: "\n") + rest
    }

    // MARK: чтение для списка встреч

    /// Что приложению нужно из манифеста для списка и карточки.
    public struct Summary: Equatable, Sendable {
        public var title: String?
        public var sensitive: Bool
        public var recording: String?
        public var transcript: String?
        public var transcriptAttempts: Int
        public var audioKept: Bool
        public var link: String?
        public var app: String?
        /// Код сбоя расшифровки (`transcript.code`): `diarization_memory` — можно повторить без голосов (R3a).
        public var transcriptCode: String? = nil
        /// Длительность записи из манифеста: звук могли убрать в Корзину после сводки.
        public var durationSeconds: Double? = nil
        /// Расшифрована, но без разделения по голосам: нет `fluidaudiocli`, все собеседники — «Собеседник 1».
        public var diarizationUnavailable: Bool {
            transcript == "done" && transcriptCode == EngineErrorText.diarizationUnavailable
        }
        /// Расшифрована, но модель голосов упала на этой записи — тоже одним собеседником.
        public var diarizationFailed: Bool {
            transcript == "done" && transcriptCode == EngineErrorText.diarizationFailed
        }

        public init(title: String? = nil, sensitive: Bool = false, recording: String? = nil, transcript: String? = nil,
                    transcriptAttempts: Int = 0, audioKept: Bool = true, link: String? = nil, app: String? = nil) {
            self.title = title; self.sensitive = sensitive; self.recording = recording; self.transcript = transcript
            self.transcriptAttempts = transcriptAttempts; self.audioKept = audioKept; self.link = link; self.app = app
        }

        public init(manifest: [String: Any], sensitiveOverride: Bool = false) {
            let title = (manifest["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let recording = manifest["recording"] as? [String: Any]
            let transcript = manifest["transcript"] as? [String: Any]
            let audio = manifest["audio"] as? [String: Any]
            let calendar = manifest["calendar"] as? [String: Any]
            self.init(title: title?.isEmpty == false ? title : nil,
                      sensitive: (manifest["sensitive"] as? Bool) == true || sensitiveOverride,
                      recording: recording?["status"] as? String, transcript: transcript?["status"] as? String,
                      transcriptAttempts: transcript?["attempts"] as? Int ?? 0,
                      audioKept: audio?["kept"] as? Bool ?? true,
                      link: calendar?["link"] as? String, app: manifest["app"] as? String)
            transcriptCode = transcript?["code"] as? String
            durationSeconds = (manifest["duration_seconds"] as? NSNumber)?.doubleValue
        }
    }

    public static func summary(_ folder: URL) -> Summary? {
        guard let manifest = readManifest(folder) else { return nil }
        var result = Summary(manifest: manifest)
        if !result.sensitive { result.sensitive = isSensitive(folder) }
        return result
    }
}
