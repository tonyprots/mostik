import Foundation

/// Снимок процесса для поиска агента в дереве переднего приложения.
public struct ProcessEntry: Equatable, Sendable {
    public var pid: Int32
    public var ppid: Int32
    /// Короткое имя процесса (`p_comm`).
    public var name: String
    /// Путь к бинарнику; может быть пустым.
    public var path: String
    /// Время запуска, секунды с 1970.
    public var startTime: Double
    /// argv — только для интерпретаторов (node, bun), иначе пусто.
    public var args: [String]

    public init(pid: Int32, ppid: Int32, name: String, path: String = "", startTime: Double = 0, args: [String] = []) {
        self.pid = pid; self.ppid = ppid; self.name = name; self.path = path
        self.startTime = startTime; self.args = args
    }
}

/// Автопроект: агент (`claude`, `codex`) в дереве процессов переднего приложения →
/// его рабочая папка → корень git. Чистая логика; процессы и файлы подставляет MostikKit.
public enum ProjectResolver {
    /// Интерпретаторы, под которыми агент запускается npm-скриптом: имя агента — в argv[1].
    public static let interpreters: Set<String> = ["node", "bun", "deno"]

    public static func isInterpreter(_ p: ProcessEntry) -> Bool {
        interpreters.contains(p.name.lowercased()) || interpreters.contains(lastComponent(p.path))
    }

    public static func isAgent(_ p: ProcessEntry, names: Set<String>) -> Bool {
        agentName(p, names: names) != nil
    }

    /// Пакеты npm, чей скрипт запускает агента: `node …/node_modules/@openai/codex/bin/codex.js`.
    public static let agentPackages: [(package: String, agent: String)] = [
        ("@anthropic-ai/claude-code", "claude"), ("@openai/codex", "codex"),
        ("@google/gemini-cli", "gemini"), ("opencode-ai", "opencode"),
    ]

    /// Флаги node, за которыми идёт значение, а не скрипт.
    static let interpreterValueFlags: Set<String> = ["-r", "--require", "--import", "--loader",
                                                     "--experimental-loader", "--title", "--env-file"]

    /// Имя агента из `names`, которым процесс является: по имени бинарника, по пути,
    /// а у интерпретатора (node, bun, deno) — по argv: `process.title` (argv[0]),
    /// скрипту (`…/bin/gemini`, `cli.js` внутри пакета агента). nil — не агент.
    public static func agentName(_ p: ProcessEntry, names: Set<String>) -> String? {
        let wanted = Set(names.map { $0.lowercased() })
        for candidate in [p.name.lowercased(), lastComponent(p.path)] where wanted.contains(candidate) {
            return candidate
        }
        guard isInterpreter(p), !p.args.isEmpty else { return nil }
        // Агент мог переписать argv[0] через `process.title`.
        let title = scriptName(p.args[0])
        if wanted.contains(title) { return title }
        var skipValue = false
        for arg in p.args.dropFirst() {
            if skipValue { skipValue = false; continue }
            if arg.hasPrefix("-") {
                if interpreterValueFlags.contains(arg) { skipValue = true }
                continue
            }
            // `bun run x`, `deno run x`, `bun x x` — подкоманда, скрипт дальше.
            if ["run", "x", "exec"].contains(arg.lowercased()) { continue }
            let lower = arg.lowercased()
            for (package, agent) in agentPackages where wanted.contains(agent) {
                if lower.contains("/node_modules/" + package + "/") { return agent }
            }
            let script = scriptName(arg)
            return wanted.contains(script) ? script : nil
        }
        return nil
    }

    /// Последний компонент пути без `.js`/`.mjs`/`.cjs`, в нижнем регистре.
    static func scriptName(_ arg: String) -> String {
        var script = lastComponent(arg)
        for ext in [".js", ".mjs", ".cjs"] where script.hasSuffix(ext) { script.removeLast(ext.count) }
        return script
    }

    /// Агенты-потомки приложения `appPID`, новые первыми. Потомком считается и процесс,
    /// чья цепочка предков проходит через бинарник внутри бандла приложения: у iTerm2
    /// оболочки живут под `iTermServer`, родитель которого — launchd, а не сам iTerm2.
    public static func agentProcesses(appPID: Int32, appBundlePath: String?, in processes: [ProcessEntry],
                                      names: Set<String>) -> [ProcessEntry] {
        var byPID: [Int32: ProcessEntry] = [:]
        for p in processes { byPID[p.pid] = p }
        let bundlePrefix = appBundlePath.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        func belongs(_ p: ProcessEntry) -> Bool {
            var current = p
            var steps = 0
            while steps < 64 {
                steps += 1
                guard current.ppid > 1, current.ppid != current.pid, let parent = byPID[current.ppid] else { return false }
                if parent.pid == appPID { return true }
                if let bundlePrefix, parent.path.hasPrefix(bundlePrefix) { return true }
                current = parent
            }
            return false
        }
        return processes
            .filter { $0.pid != appPID && isAgent($0, names: names) && belongs($0) }
            .sorted { $0.startTime != $1.startTime ? $0.startTime > $1.startTime : $0.pid > $1.pid }
    }

    /// Корень git: первая папка вверх от `path`, где есть `.git` (папка или файл worktree).
    public static func gitRoot(of path: String, hasGitMarker: (String) -> Bool) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var current = (path as NSString).standardizingPath
        while true {
            if hasGitMarker(current) { return current }
            if current == "/" || current.isEmpty { return nil }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { return nil }
            current = parent
        }
    }

    public static func gitRoot(of path: String) -> String? {
        gitRoot(of: path) { dir in
            FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(".git"))
        }
    }

    /// Корень проекта для словаря: корень git, иначе сама рабочая папка агента —
    /// общие рабочие папки вроде `~/Work` не репозитории, но словарь в них есть.
    /// Домашняя папка и корень диска проектом не считаются: там нечего сканировать прицельно.
    public static func projectRoot(of cwd: String, home: String, hasGitMarker: (String) -> Bool) -> String? {
        if let root = gitRoot(of: cwd, hasGitMarker: hasGitMarker) {
            let normalizedHome = (home as NSString).standardizingPath
            if root != "/" && root != normalizedHome { return root }
        }
        guard cwd.hasPrefix("/") else { return nil }
        let path = (cwd as NSString).standardizingPath
        if path == "/" || path == (home as NSString).standardizingPath { return nil }
        return path
    }

    public static func projectRoot(of cwd: String) -> String? {
        projectRoot(of: cwd, home: NSHomeDirectory()) { dir in
            FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(".git"))
        }
    }

    /// Из нескольких агентов выбираем того, чья папка видна в заголовке окна (терминалы
    /// пишут туда каталог); иначе — самого свежего. `candidates` уже отсортированы.
    public static func chooseRoot(_ roots: [String], windowTitle: String) -> String? {
        if !windowTitle.isEmpty {
            for root in roots {
                let name = (root as NSString).lastPathComponent
                if !name.isEmpty, windowTitle.localizedCaseInsensitiveContains(name) { return root }
            }
        }
        return roots.first
    }

    /// Итоговый проект для `start.project`: автоопределённый, иначе ручной.
    public static func effectiveProject(detected: String?, autoEnabled: Bool, manual: String?) -> (path: String?, auto: Bool) {
        if autoEnabled, let detected, !detected.isEmpty { return (detected, true) }
        if let manual, !manual.isEmpty { return (manual, false) }
        return (nil, false)
    }

    /// argv из буфера `KERN_PROCARGS2`: int32 argc, путь exec, нули-выравнивание, argv.
    public static func parseProcArgs(_ bytes: [UInt8]) -> [String] {
        guard bytes.count > 4 else { return [] }
        let argc = Int(Int32(littleEndian: bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }))
        guard argc > 0 else { return [] }
        var i = 4
        while i < bytes.count, bytes[i] != 0 { i += 1 }       // путь exec
        while i < bytes.count, bytes[i] == 0 { i += 1 }       // выравнивание
        var args: [String] = []
        while i < bytes.count, args.count < argc {
            let start = i
            while i < bytes.count, bytes[i] != 0 { i += 1 }
            args.append(String(decoding: bytes[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    static func lastComponent(_ path: String) -> String {
        path.isEmpty ? "" : (path as NSString).lastPathComponent.lowercased()
    }
}
