import Foundation

/// Хук после встречи (M11): своя команда пользователя с путём папки встречи. Выключен по умолчанию.
public struct MeetingHookSettings: Codable, Equatable, Sendable {
    public var enabled: Bool = false
    public var command: String = ""
    public var timeoutSeconds: Int = 60
    /// Звать хук ещё раз, когда готова сводка ИИ (событие `summary`).
    public var afterSummary: Bool = true

    public init(enabled: Bool = false, command: String = "", timeoutSeconds: Int = 60, afterSummary: Bool = true) {
        self.enabled = enabled; self.command = command; self.timeoutSeconds = timeoutSeconds; self.afterSummary = afterSummary
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 60
        afterSummary = try c.decodeIfPresent(Bool.self, forKey: .afterSummary) ?? true
    }
}

public enum MeetingHook {
    public enum Event: String, Sendable { case transcript, summary }

    public enum Decision: Equatable, Sendable {
        case run
        case skip(String)
    }

    public static let minTimeout = 5
    public static let maxTimeout = 3600
    /// Сколько вывода хука кладём в лог.
    public static let outputLimit = 16_000

    /// `trusted` — отпечаток команды совпал с записанным в связке ключей (`MeetingHookTrust`, П10 С3).
    public static func decide(_ settings: MeetingHookSettings, event: Event, sensitive: Bool, trusted: Bool) -> Decision {
        guard settings.enabled else { return .skip("disabled") }
        guard !settings.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .skip("empty") }
        if event == .summary && !settings.afterSummary { return .skip("summary_off") }
        // W13: чувствительную встречу хуки не получают.
        if sensitive { return .skip("sensitive") }
        // П10 С3: команду, которую пользователь не подтверждал в Mostik, не запускаем.
        guard trusted else { return .skip("untrusted") }
        return .run
    }

    public static func timeout(_ settings: MeetingHookSettings) -> TimeInterval {
        TimeInterval(min(maxTimeout, max(minTimeout, settings.timeoutSeconds)))
    }

    /// `/bin/zsh -fc <команда> mostik-hook <папка>`: внутри команды папка — `$1`. `-f` и без `-l` (П10, низкий):
    /// `~/.zshenv`, `~/.zprofile` и `~/.zshrc` не читаются, исполняется ровно подтверждённая команда.
    /// `PATH` — всегда системный (`ToolEnvironment`, П10 р3 С-2): программы вне `/usr/bin`, `/bin`,
    /// `/usr/sbin` и `/sbin` — по полному пути.
    public static let shell = "/bin/zsh"

    public static func arguments(command: String, folder: URL) -> [String] {
        ["-fc", command, "mostik-hook", folder.path]
    }

    public static func environment(folder: URL, event: Event, base: [String: String]) -> [String: String] {
        // П10: команде пользователя — только обычные переменные (HOME, язык) и системный PATH,
        // без секретов, `DYLD_*` и `PATH` родителя.
        var env = ToolEnvironment.minimal(base)
        env["MOSTIK_MEETING_DIR"] = folder.path
        env["MOSTIK_MEETING_ID"] = folder.lastPathComponent
        env["MOSTIK_MEETING_EVENT"] = event.rawValue
        return env
    }

    /// Запись в `~/Library/Logs/Mostik/meeting-hooks.log` (`MeetingHookLog`).
    public static func logEntry(date: Date, folder: URL, event: Event, exitCode: Int32?, timedOut: Bool,
                                seconds: Double, output: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        let code = timedOut ? "timeout" : exitCode.map { "exit \($0)" } ?? "not started"
        var text = "[\(f.string(from: date))] \(folder.lastPathComponent) \(event.rawValue) — \(code), "
            + String(format: "%.1f s", seconds) + "\n"
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let body = trimmed.count > outputLimit ? String(trimmed.prefix(outputLimit)) + "\n…" : trimmed
            text += body.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(separator: "\n") + "\n"
        }
        return text
    }

    /// Поле `hook` манифеста.
    public static func manifestPatch(date: Date, exitCode: Int32?, timedOut: Bool, skipped: String?) -> [String: Any] {
        ["hook": ["ran_at": MeetingFolder.iso(date), "exit_code": exitCode.map { Int($0) } as Any? ?? NSNull(),
                  "timed_out": timedOut, "skipped": skipped as Any? ?? NSNull()]]
    }
}

/// Аудио после готовой сводки (W13): в Корзину, если пользователь так решил. Выключено по умолчанию.
public enum AudioRetention {
    public static func shouldTrash(enabled: Bool, summaryStatus: String?, hasTranscript: Bool, audioKept: Bool) -> Bool {
        enabled && audioKept && hasTranscript && summaryStatus == "done"
    }
}
