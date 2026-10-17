import Foundation

// A6 — сообщение агенту посреди хода.
//
// Пока Claude Code работает, надиктованное в его окно не вставляется в поле ввода, а ложится
// в очередь `<MOSTIK_HOME>/agent-queue/queue/<session>/`. Хук `mostik-queue.sh` отдаёт его агенту:
// после очередного инструмента (PostToolUse → `additionalContext`), а если ход кончается —
// не даёт ему закончиться (Stop → `decision: block`), и агент читает сообщение сразу.
// Агент «занят» — файл `busy/<session>`: его ставит хук на UserPromptSubmit, обновляет на каждом
// инструменте и снимает на Stop. Хуки ставит только кнопка в Настройках, с показом что куда ляжет.

public struct BusySession: Equatable, Sendable {
    public var id: String
    /// Папка, где запущен агент.
    public var cwd: String?
    /// Когда хук последний раз отметился.
    public var touched: Date
    public init(id: String, cwd: String?, touched: Date) { self.id = id; self.cwd = cwd; self.touched = touched }
}

public enum AgentQueue {
    /// П10 р4 Р4-4и: очередь отдаёт текст агенту как волю пользователя, без Enter и без просмотра человеком.
    /// Текст, который прошёл модель после контекста из терминала или агента, туда не идёт — он вставляется
    /// в поле, и Enter остаётся за человеком (как `AutoEnterGuard`, Н-7).
    public static func allowsEnqueue(contextSent: Bool, polished: Bool) -> Bool {
        !(contextSent && polished)
    }

    public static let folderName = "agent-queue"
    /// Маркер «очередь включена»: без него хук ничего не делает.
    public static let enabledMarker = ".enabled"
    /// Без отметки хука дольше — сессию считаем свободной (агента прервали Esc, и Stop не пришёл).
    public static let staleAfter: TimeInterval = 15 * 60
    /// Предел одного сообщения: агенту — реплика, не документ.
    public static let messageLimit = 4000

    /// Session id Claude Code — UUID; всё прочее отбрасываем, чтобы имя не стало путём.
    public static func isValidSessionID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Разбор `busy/<session>`: первая строка — cwd агента.
    public static func parseBusy(name: String, content: String?, modified: Date) -> BusySession? {
        guard isValidSessionID(name) else { return nil }
        let cwd = content?.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        return BusySession(id: name, cwd: (cwd?.isEmpty ?? true) ? nil : cwd, touched: modified)
    }

    /// Куда класть сообщение. Свежие занятые сессии; при проекте — та, чья папка с ним совпала;
    /// без совпадения — только если занятая сессия одна. Иначе nil: вставляем как обычно.
    public static func target(_ sessions: [BusySession], project: String?, now: Date) -> BusySession? {
        let fresh = sessions.filter { now.timeIntervalSince($0.touched) < staleAfter }
        guard !fresh.isEmpty else { return nil }
        if let project, !project.isEmpty {
            let root = normalized(project)
            let matching = fresh.filter { session in
                guard let cwd = session.cwd.map(normalized) else { return false }
                return cwd == root || cwd.hasPrefix(root + "/") || root.hasPrefix(cwd + "/")
            }
            if matching.count == 1 { return matching[0] }
            if matching.count > 1 { return matching.max { $0.touched < $1.touched } }
        }
        return fresh.count == 1 ? fresh[0] : nil
    }

    static func normalized(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Текст сообщения в файл очереди: уже экранированный для строки JSON, без кавычек вокруг —
    /// хук на POSIX sh только склеивает файлы и вставляет в свой JSON как есть.
    public static func encodeMessage(_ text: String) -> String {
        jsonEscape(String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(messageLimit)))
    }

    public static func jsonEscape(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "%": out += "\\u0025"  // printf в хуке: процент не должен стать форматом
            default:
                if scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    /// Имя файла сообщения: время в миллисекундах — порядок, хвост — чтобы не столкнуться.
    public static func messageFileName(now: Date, suffix: String) -> String {
        let ms = Int64((now.timeIntervalSince1970 * 1000).rounded())
        let clean = suffix.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(8)
        return "\(ms)-\(clean).msg"
    }
}

// MARK: Установка хуков очереди — только по кнопке

/// Правка `~/.claude/settings.json`: наши записи в `UserPromptSubmit`, `PostToolUse`, `Stop`.
/// Чужие хуки и записи озвучки (`mostik-notify.sh`) не трогаются.
public enum QueueHooks {
    public static let scriptName = "mostik-queue.sh"
    public static let events: [(hook: String, argument: String)] = [
        ("UserPromptSubmit", "prompt"), ("PostToolUse", "tool"), ("Stop", "stop"),
    ]

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
        return events.allSatisfy { event in (hooks[event.hook] as? [Any])?.contains(where: isOurs) == true }
    }

    public static func entries(scriptPath: String) -> [String: Any] {
        var out: [String: Any] = [:]
        for event in events {
            out[event.hook] = [["hooks": [["type": "command", "command": command(scriptPath: scriptPath, argument: event.argument),
                                           "timeout": 5]]]]
        }
        return out
    }

    public static func install(into settings: [String: Any], scriptPath: String) -> [String: Any] {
        var result = uninstall(from: settings)
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        for (hook, value) in entries(scriptPath: scriptPath) {
            hooks[hook] = (hooks[hook] as? [Any] ?? []) + (value as? [Any] ?? [])
        }
        result["hooks"] = hooks
        return result
    }

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

    /// Текст окна подтверждения: что и куда запишется.
    public static func preview(scriptPath: String) -> String {
        let data = ClaudeHooks.encode(["hooks": entries(scriptPath: scriptPath)]) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
