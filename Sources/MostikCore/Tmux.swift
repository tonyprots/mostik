import Foundation

// G5 и A5: адресная вставка в панель tmux. Чистая часть — разбор `list-panes`, поиск агентов
// в дереве процессов панели, выбор цели и сами команды tmux. Запуск tmux — `MostikKit/TmuxClient`.

/// Панель tmux из `list-panes -a`.
public struct TmuxPane: Equatable, Sendable {
    public var id: String
    public var session: String
    public var windowIndex: Int
    public var windowName: String
    public var paneIndex: Int
    /// PID процесса панели — обычно оболочка.
    public var pid: Int32
    public var command: String
    public var path: String
    public var active: Bool
    public var windowActive: Bool
    /// Сколько клиентов подключено к сессии.
    public var attached: Int

    public init(id: String, session: String, windowIndex: Int = 0, windowName: String = "", paneIndex: Int = 0,
                pid: Int32 = 0, command: String = "", path: String = "", active: Bool = false,
                windowActive: Bool = false, attached: Int = 0) {
        self.id = id; self.session = session; self.windowIndex = windowIndex; self.windowName = windowName
        self.paneIndex = paneIndex; self.pid = pid; self.command = command; self.path = path
        self.active = active; self.windowActive = windowActive; self.attached = attached
    }

    /// `сессия:окно.панель` — как tmux называет цель.
    public var label: String { "\(session):\(windowIndex).\(paneIndex)" }
    /// Панель, которую сейчас видно в подключённом клиенте.
    public var visible: Bool { active && windowActive && attached > 0 }
}

/// Панель, в которой работает агент.
public struct TmuxAgentPane: Equatable, Sendable {
    public var pane: TmuxPane
    /// Имя агента: `claude`, `codex`…
    public var agent: String
    public var agentPID: Int32
    /// Корень проекта агента (cwd → git), если известен.
    public var project: String?

    public init(pane: TmuxPane, agent: String, agentPID: Int32, project: String? = nil) {
        self.pane = pane; self.agent = agent; self.agentPID = agentPID; self.project = project
    }

    /// Имена для обращения голосом (A5): сессия, окно, папка проекта.
    public var names: [String] {
        var out = [pane.session, pane.windowName]
        if let project { out.append((project as NSString).lastPathComponent) }
        return out.filter { !$0.isEmpty }
    }

    /// Подпись в настройках и HUD: «frontend · claude · mostik».
    public var title: String {
        var parts = [pane.session]
        if !pane.windowName.isEmpty, pane.windowName != pane.session, !SessionAddress.automaticNames.contains(pane.windowName.lowercased()) {
            parts.append(pane.windowName)
        }
        parts.append(agent)
        if let project { parts.append((project as NSString).lastPathComponent) }
        var seen: [String] = []
        for p in parts where !seen.contains(p) { seen.append(p) }
        return seen.joined(separator: " · ")
    }
}

public enum Tmux {
    /// Где искать tmux: Homebrew на Apple Silicon и Intel, MacPorts, Nix.
    public static let candidatePaths = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/opt/local/bin/tmux",
                                        "/run/current-system/sw/bin/tmux", "/usr/bin/tmux"]

    static let fields = ["pane_id", "session_name", "window_index", "pane_index", "pane_pid", "pane_active",
                         "window_active", "session_attached", "pane_current_command", "window_name", "pane_current_path"]
    /// Формат `list-panes`: путь последним — в нём может оказаться что угодно.
    public static let listFormat = fields.map { "#{\($0)}" }.joined(separator: "\t")

    public static func listArgs() -> [String] { ["list-panes", "-a", "-F", listFormat] }

    /// Окружение tmux (П10): урезанное (`ToolEnvironment`).
    /// Mostik могли запустить из tmux: без `TMUX` и `TMUX_PANE` команды не уйдут в «текущую» сессию мимо `-t`.
    /// П10 р5 Р5-1: без `TMUX_TMPDIR` — он выбирает сокет сервера, а поддельный сервер (`launchctl setenv
    /// TMUX_TMPDIR …`) может велеть клиенту запустить программу. Сокет — только по умолчанию, `/tmp/tmux-<uid>/`;
    /// сервер со своим `TMUX_TMPDIR` Mostik не увидит, вставка уйдёт обычным ⌘V.
    public static func environment(parent: [String: String]) -> [String: String] {
        var env = ToolEnvironment.minimal(parent)
        env.removeValue(forKey: "TMUX")
        env.removeValue(forKey: "TMUX_PANE")
        return env
    }

    public static func parsePanes(_ output: String) -> [TmuxPane] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: "\t", maxSplits: fields.count - 1, omittingEmptySubsequences: false).map(String.init)
            guard f.count == fields.count, f[0].hasPrefix("%"), let pid = Int32(f[4]) else { return nil }
            return TmuxPane(id: f[0], session: f[1], windowIndex: Int(f[2]) ?? 0, windowName: f[9],
                            paneIndex: Int(f[3]) ?? 0, pid: pid, command: f[8], path: f[10],
                            active: f[5] == "1", windowActive: f[6] == "1", attached: Int(f[7]) ?? 0)
        }
    }

    /// Панели, в дереве процессов которых работает агент. В панели может быть несколько агентов
    /// (субагент, вложенный запуск) — берётся самый ранний: это тот, с кем говорит человек.
    public static func agentPanes(_ panes: [TmuxPane], processes: [ProcessEntry], names: Set<String>) -> [TmuxAgentPane] {
        var byPID: [Int32: ProcessEntry] = [:]
        for p in processes { byPID[p.pid] = p }
        let agents = processes.filter { ProjectResolver.isAgent($0, names: names) }
        var result: [TmuxAgentPane] = []
        for pane in panes {
            var found: [ProcessEntry] = []
            for agent in agents {
                var current = agent
                var steps = 0
                while steps < 64 {
                    steps += 1
                    if current.pid == pane.pid { found.append(agent); break }
                    guard current.ppid > 1, current.ppid != current.pid, let parent = byPID[current.ppid] else { break }
                    current = parent
                }
            }
            guard let first = found.min(by: { $0.startTime != $1.startTime ? $0.startTime < $1.startTime : $0.pid < $1.pid })
            else { continue }
            result.append(TmuxAgentPane(pane: pane, agent: agentName(first, names: names), agentPID: first.pid))
        }
        return result
    }

    static func agentName(_ p: ProcessEntry, names: Set<String>) -> String {
        ProjectResolver.agentName(p, names: names) ?? p.name
    }

    /// Имя буфера tmux на одну вставку: свой, чтобы не затереть буфер пользователя.
    public static func bufferName(_ id: String) -> String {
        "mostik-" + String(id.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(40))
    }

    /// Вставка: текст в именованный буфер со stdin, потом bracketed paste (`-p`) в панель
    /// с удалением буфера (`-d`). Перевод строки внутри bracketed paste агент не примет за Enter.
    public static func pasteCommands(pane: String, buffer: String) -> [[String]] {
        [["load-buffer", "-b", buffer, "-"],
         ["paste-buffer", "-p", "-d", "-b", buffer, "-t", pane]]
    }

    public static func enterCommand(pane: String) -> [String] { ["send-keys", "-t", pane, "Enter"] }
}

/// Подключённый клиент tmux: процесс `tmux` в окне терминала и сессия, которую он показывает.
public struct TmuxClientInfo: Equatable, Sendable {
    public var pid: Int32
    /// Время последнего ввода, секунды с 1970.
    public var activity: Int
    public var session: String
    public init(pid: Int32, activity: Int, session: String) { self.pid = pid; self.activity = activity; self.session = session }
}

extension Tmux {
    public static func clientsArgs() -> [String] { ["list-clients", "-F", "#{client_pid}\t#{client_activity}\t#{client_session}"] }

    public static func parseClients(_ output: String) -> [TmuxClientInfo] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 3, let pid = Int32(f[0]) else { return nil }
            return TmuxClientInfo(pid: pid, activity: Int(f[1]) ?? 0, session: f[2])
        }
    }
}

/// Какую панель считать целью вставки.
public enum TmuxTargeting {
    public static let auto = "auto"

    /// Сессия, которую показывает терминал впереди: из его клиентов tmux — с последним вводом.
    public static func focusedSession(_ clients: [TmuxClientInfo], frontClientPIDs: Set<Int32>) -> String? {
        clients.filter { frontClientPIDs.contains($0.pid) }.max { $0.activity < $1.activity }?.session
    }

    /// Закреплённая панель — если она ещё жива. `auto` — активная панель сессии, которую показывает
    /// терминал впереди, если в ней агент. Сессию узнать не удалось — единственная панель с агентом
    /// или единственная видимая. Неоднозначно — nil, вставка идёт как обычно.
    public static func choose(_ panes: [TmuxAgentPane], preference: String, focusedSession: String? = nil) -> TmuxAgentPane? {
        if preference != auto, !preference.isEmpty {
            return panes.first { $0.pane.id == preference }
        }
        if let focusedSession {
            return panes.first { $0.pane.session == focusedSession && $0.pane.active && $0.pane.windowActive }
        }
        if panes.count == 1 { return panes[0] }
        let visible = panes.filter { $0.pane.visible }
        return visible.count == 1 ? visible[0] : nil
    }

    /// Кандидаты для обращения по имени (A5).
    public static func candidates(_ panes: [TmuxAgentPane]) -> [AddressCandidate] {
        panes.map { AddressCandidate(id: $0.pane.id, names: $0.names) }
    }
}
