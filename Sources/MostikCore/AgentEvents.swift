import Foundation

// A1: озвучка конца хода и запроса разрешения. Хуки Claude Code (Stop, Notification) запускают
// `integrations/claude-code/hooks/mostik-notify.sh`; он кладёт файл события в папку
// `~/Library/Application Support/Mostik/agent-events`, приложение его читает и говорит.
// Здесь — разбор события, текст озвучки и правка `~/.claude/settings.json` для кнопки установки.

public enum AgentEventKind: String, Equatable, Sendable {
    /// Агент закончил ход.
    case done
    /// Агент ждёт разрешения.
    case permission
}

public struct AgentEvent: Equatable, Sendable {
    public var kind: AgentEventKind
    public var sessionID: String?
    public var cwd: String?
    public var transcriptPath: String?
    public var message: String?
    /// `$TMUX_PANE` процесса хука — по нему озвучка называет сессию (A5).
    public var tmuxPane: String?
    public var at: Date

    public init(kind: AgentEventKind, sessionID: String? = nil, cwd: String? = nil, transcriptPath: String? = nil,
                message: String? = nil, tmuxPane: String? = nil, at: Date = Date()) {
        self.kind = kind; self.sessionID = sessionID; self.cwd = cwd; self.transcriptPath = transcriptPath
        self.message = message; self.tmuxPane = tmuxPane; self.at = at
    }
}

public enum AgentEvents {
    /// Папка событий внутри данных приложения; маркер в ней — «Mostik слушает».
    public static let folderName = "agent-events"
    public static let listeningMarker = ".listening"
    /// События старше этого не озвучиваются: приложение было закрыто или занято.
    public static let maxAge: TimeInterval = 120

    /// Файл события: первая строка — заголовок от скрипта, дальше — JSON хука как есть.
    /// Уведомление «жду ввода» (idle) не озвучиваем: о конце хода уже сказал Stop.
    public static func parse(_ contents: String) -> AgentEvent? {
        let lines = contents.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let headerLine = lines.first,
              let header = try? JSONSerialization.jsonObject(with: Data(headerLine.utf8)) as? [String: Any],
              header["mostik"] != nil, let event = header["event"] as? String else { return nil }
        var payload: [String: Any] = [:]
        if lines.count > 1, let data = String(lines[1]).data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            payload = object
        }
        let message = payload["message"] as? String
        let kind: AgentEventKind
        switch event {
        case "stop":
            kind = .done
        case "notification":
            guard let k = notificationKind(type: payload["notification_type"] as? String, message: message) else { return nil }
            kind = k
        default:
            return nil
        }
        let pane = (header["tmux_pane"] as? String).flatMap { validPane($0) ? $0 : nil }
        let at = (header["at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            ?? (header["at"] as? Int).map { Date(timeIntervalSince1970: Double($0)) } ?? Date()
        return AgentEvent(kind: kind, sessionID: payload["session_id"] as? String, cwd: payload["cwd"] as? String,
                          transcriptPath: payload["transcript_path"] as? String, message: message,
                          tmuxPane: pane, at: at)
    }

    /// Новые версии Claude Code шлют `notification_type`; старые — только текст.
    static func notificationKind(type: String?, message: String?) -> AgentEventKind? {
        if let type {
            switch type {
            case "permission_prompt": return .permission
            case "idle_prompt": return nil
            default: break
            }
        }
        let text = (message ?? "").lowercased()
        if text.contains("permission") || text.contains("разрешени") || text.contains("approve") { return .permission }
        return nil
    }

    static func validPane(_ s: String) -> Bool {
        s.count >= 2 && s.first == "%" && s.dropFirst().allSatisfy(\.isNumber)
    }

    /// Последняя реплика агента из транскрипта Claude Code (JSONL): первая фраза, без разметки.
    public static func lastAssistantSentence(transcript: String, limit: Int = 160) -> String? {
        for line in transcript.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any] else { continue }
            var text = ""
            if let content = message["content"] as? [[String: Any]] {
                text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: " ")
            } else if let content = message["content"] as? String {
                text = content
            }
            let sentence = firstSentence(text, limit: limit)
            if !sentence.isEmpty { return sentence }
        }
        return nil
    }

    public static func firstSentence(_ text: String, limit: Int) -> String {
        // Без кода, ссылок и разметки: голосом их не прочесть.
        var clean = text
        while let open = clean.range(of: "```") {
            if let close = clean.range(of: "```", range: open.upperBound..<clean.endIndex) {
                clean.replaceSubrange(open.lowerBound..<close.upperBound, with: " ")
            } else {
                clean = String(clean[..<open.lowerBound])
            }
        }
        clean = clean.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        clean = clean.replacingOccurrences(of: #"[*_`#>|]"#, with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return "" }
        var sentence = clean
        if let end = clean.range(of: #"[.!?…](\s|$)"#, options: .regularExpression) {
            sentence = String(clean[..<end.upperBound]).trimmingCharacters(in: .whitespaces)
        }
        if sentence.count > limit {
            let cut = sentence.prefix(limit)
            let lastSpace = cut.lastIndex(of: " ") ?? cut.endIndex
            sentence = String(cut[..<lastSpace]) + "…"
        }
        return sentence
    }

    /// Что сказать. Имя проекта — всегда, если известно; сессия tmux — если она другая (A5).
    public static func announcement(_ event: AgentEvent, project: String?, session: String?, summary: String?,
                                    russian: Bool) -> String {
        let name = project.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
        let tmux = session.flatMap { $0.isEmpty || $0.lowercased() == name?.lowercased() ? nil : $0 }
        let ru = russian
        switch event.kind {
        case .permission:
            switch (name, tmux) {
            case let (n?, s?): return ru ? "Проекту \(n), сессия \(s), нужно разрешение." : "\(n), session \(s), needs your permission."
            case let (n?, nil): return ru ? "Проекту \(n) нужно разрешение." : "\(n) needs your permission."
            case let (nil, s?): return ru ? "Сессии \(s) нужно разрешение." : "Session \(s) needs your permission."
            case (nil, nil): return ru ? "Агенту нужно разрешение." : "The agent needs your permission."
            }
        case .done:
            let head: String
            switch (name, tmux) {
            case let (n?, s?): head = ru ? "\(n), сессия \(s): готово." : "\(n), session \(s): done."
            case let (n?, nil): head = ru ? "\(n): готово." : "\(n): done."
            case let (nil, s?): head = ru ? "Сессия \(s): готово." : "Session \(s): done."
            case (nil, nil): head = ru ? "Агент закончил." : "The agent is done."
            }
            guard let summary, !summary.isEmpty else { return head }
            return head + " " + summary
        }
    }

    /// Разные звуки: «закончил» мягкий, «нужно разрешение» заметный.
    public static func sound(_ kind: AgentEventKind) -> String {
        switch kind {
        case .done: "Glass"
        case .permission: "Sosumi"
        }
    }

    /// Одно и то же событие одной сессии в пределах окна не повторяем: Stop и Notification
    /// иногда приходят парой, а у субагентов — пачкой.
    public static func isDuplicate(_ event: AgentEvent, of previous: AgentEvent?, window: TimeInterval = 4) -> Bool {
        guard let previous, previous.kind == event.kind, previous.sessionID == event.sessionID,
              previous.cwd == event.cwd else { return false }
        return abs(event.at.timeIntervalSince(previous.at)) < window
    }
}

// MARK: Установка хуков Claude Code

/// Правка `~/.claude/settings.json`: добавить или убрать наши записи в `hooks.Stop` и
/// `hooks.Notification`, ничего больше не трогая. Пишет файл только кнопка в настройках.
public enum ClaudeHooks {
    public static let scriptName = "mostik-notify.sh"
    public static let events: [(hook: String, argument: String)] = [("Stop", "stop"), ("Notification", "notification")]

    /// Путь через `shellQuote`: `$`, обратная кавычка и кавычки в пути не разбираются shell (П10).
    public static func command(scriptPath: String, argument: String) -> String {
        AgentIntegration.shellQuote(scriptPath) + " " + argument
    }

    static func isOurs(_ entry: Any) -> Bool {
        guard let group = entry as? [String: Any], let hooks = group["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { ($0["command"] as? String)?.contains(scriptName) == true }
    }

    public static func isInstalled(_ settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            (hooks[event.hook] as? [Any])?.contains(where: isOurs) == true
        }
    }

    /// Наши записи — как они лягут в файл; это же показывается перед установкой.
    public static func entries(scriptPath: String) -> [String: Any] {
        var out: [String: Any] = [:]
        for event in events {
            out[event.hook] = [["hooks": [["type": "command", "command": command(scriptPath: scriptPath, argument: event.argument),
                                           "timeout": 5]]]]
        }
        return out
    }

    /// Добавить (заменив прежние наши записи). Чужие хуки и прочие ключи остаются.
    public static func install(into settings: [String: Any], scriptPath: String) -> [String: Any] {
        var result = uninstall(from: settings)
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        for (hook, value) in entries(scriptPath: scriptPath) {
            let existing = hooks[hook] as? [Any] ?? []
            hooks[hook] = existing + (value as? [Any] ?? [])
        }
        result["hooks"] = hooks
        return result
    }

    /// Убрать только наши записи; опустевшие списки и `hooks` — тоже.
    public static func uninstall(from settings: [String: Any]) -> [String: Any] {
        var result = settings
        guard var hooks = result["hooks"] as? [String: Any] else { return result }
        for event in events {
            guard let list = hooks[event.hook] as? [Any] else { continue }
            let kept = list.filter { !isOurs($0) }
            hooks[event.hook] = kept.isEmpty ? nil : kept
        }
        result["hooks"] = hooks.isEmpty ? nil : hooks
        return result
    }

    /// Разобрать файл настроек. Пустой или отсутствующий — пустой словарь; битый JSON — nil
    /// (такой файл не трогаем).
    public static func load(_ data: Data?) -> [String: Any]? {
        guard let data, !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public static func encode(_ settings: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Текст для окна подтверждения: что и куда запишется.
    public static func preview(scriptPath: String) -> String {
        let data = encode(["hooks": entries(scriptPath: scriptPath)]) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
