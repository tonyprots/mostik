import Foundation

/// Запуск процесса движка (П10 С1): изолированный Python и чистое окружение.
///
/// `-I` отключает пользовательский site (`~/.local/lib/python3.x/site-packages` и его `.pth`),
/// переменные `PYTHON*` и папку скрипта в `sys.path`. Путь к движку при `-I` через `PYTHONPATH`
/// не передать, поэтому он идёт аргументом в короткий загрузчик: тот кладёт каталог в `sys.path`
/// и запускает модуль через `runpy`, как `-m`. Одинаково для `swift run` и для `.app`.
public enum EngineLaunch {
    /// Загрузчик: `sys.argv[1]` — каталог движка, `sys.argv[2]` — модуль. Пути в код не подставляются.
    public static let bootstrap =
        "import sys, runpy; d, m = sys.argv[1], sys.argv[2]; del sys.argv[1:3]; "
        + "sys.path.insert(0, d); runpy.run_module(m, run_name='__main__', alter_sys=True)"

    public static func arguments(engineDir: URL, module: String = "mostik_engine") -> [String] {
        ["-I", "-u", "-c", bootstrap, engineDir.path, module]
    }

    /// Окружение движка: белый список (П10 р4 Р4-1, `EngineEnvironment.allowlisted`), из него вычищаем то,
    /// чем подменяется код (`EngineEnvironment.apply`), ставим дом и папку отчётов.
    public static func environment(base: [String: String], home: URL, crashDir: URL?,
                                   debug: Bool = DebugOverrides.isDebugBuild) -> [String: String] {
        var env = EngineEnvironment.allowlisted(base)
        EngineEnvironment.apply(to: &env, debug: debug)
        env["MOSTIK_HOME"] = home.path
        if let crashDir { env["MOSTIK_CRASH_DIR"] = crashDir.path } else { env.removeValue(forKey: "MOSTIK_CRASH_DIR") }
        return env
    }
}

/// Окружение внешних утилит (git, tmux, хук встречи): белый список вместо полного наследования.
/// Если Mostik запущен из терминала, токены и `DYLD_*` пользователя до утилит не доходят.
///
/// П10 р3 С-2: `PATH` — всегда системный, родительский не наследуется. Отпечаток хука закрепляет
/// текст команды, но не то, какой `cp` она найдёт: после `launchctl setenv PATH /evil:…` подтверждённая
/// команда запустила бы чужую программу с разрешениями Mostik. Homebrew и свои программы — полным путём.
public enum ToolEnvironment {
    public static let defaultPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    public static let allowed: Set<String> = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "TERM", "__CF_USER_TEXT_ENCODING"]

    public static func minimal(_ base: [String: String]) -> [String: String] {
        var env = base.filter { allowed.contains($0.key) || $0.key.hasPrefix("LC_") }
        env["PATH"] = defaultPath
        return env
    }
}

/// П10: `git` в репозитории проекта, который может быть чужим. Его `.git/config` не должен ничего
/// запускать: `core.fsmonitor` выполняется уже на `ls-files`, хуки — тоже мимо. Окружение — урезанное,
/// без `GIT_*` (`GIT_DIR`, `GIT_CONFIG_GLOBAL` и т. п. подменили бы репозиторий или настройки).
/// Повторяет `SAFE_GIT` движка (`project_glossary.py`).
public enum SafeGit {
    public static let hardening = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
                                   "-c", "core.untrackedCache=false", "-c", "core.sshCommand=false",
                                   "-c", "protocol.allow=never"]

    public static func arguments(root: String, _ command: [String]) -> [String] {
        hardening + ["-C", root] + command
    }

    /// П10 р5 Р5-2: `/usr/bin/git` — шим xcode-select: он спрашивает путь у xcrun, а xcrun берёт его из своего
    /// кэша `xcrun_db` (в `DARWIN_USER_TEMP_DIR` или по переменной `xcrun_db`) без проверки. Проба: подложенный
    /// кэш уводит шим в любую программу. Поэтому git — напрямую из папки разработчика (`xcode-select -p`),
    /// и только из системных мест: Command Line Tools или `/Applications/<имя>.app/Contents/Developer`.
    ///
    /// П10 хвост р5 Ф-1: форма пути — не доверие. `/Applications` (root:admin 775) открыт на запись админу,
    /// Xcode из `.xip` или Xcodes принадлежит пользователю. Поэтому вся цепочка от `<имя>.app` (или от CLT)
    /// до самого файла git — root, без записи группе и прочим, без ссылок (`status`, по умолчанию `lstat`).
    /// nil — путь чужой или git нет: список файлов проекта строится обходом папки.
    public static func executable(developerDir: String?, isExecutable: (String) -> Bool,
                                  status: (String) -> PathStatus? = lstatus) -> String? {
        guard var dir = developerDir?.trimmingCharacters(in: .whitespacesAndNewlines), dir.hasPrefix("/") else { return nil }
        while dir.count > 1, dir.hasSuffix("/") { dir.removeLast() }
        let resolved = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
        guard isSystemDeveloperDir(dir), isSystemDeveloperDir(resolved) else { return nil }
        let git = resolved + "/usr/bin/git"
        guard isExecutable(git) else { return nil }
        return trustChain(developerDir: resolved).allSatisfy({ status($0)?.isRootOnly == true }) ? git : nil
    }

    /// Звенья, которые должны принадлежать root: от CLT или `<имя>.app` до `usr/bin/git`. Сам `/Applications`
    /// в цепочку не входит: он root:admin 775 по замыслу системы, подмену `.app` в нём ловит владелец `.app`.
    static func trustChain(developerDir: String) -> [String] {
        let top = developerDir == commandLineTools
            ? commandLineTools
            : "/Applications/" + String(developerDir.split(separator: "/")[1])
        var chain = [top]
        let rest = developerDir.dropFirst(top.count).split(separator: "/").map(String.init) + ["usr", "bin", "git"]
        for part in rest { chain.append(chain[chain.count - 1] + "/" + part) }
        return chain
    }

    public static let xcodeSelect = "/usr/bin/xcode-select"
    public static let xcodeSelectTimeout: TimeInterval = 5

    /// Вывод `xcode-select -p` с окружением без `DEVELOPER_DIR`. П10 хвост р5 Ф-5: с таймаутом — завис, упал
    /// или не запустился: nil, как при отказе (git нет, список файлов — обходом папки).
    public static func developerDir(tool: String = xcodeSelect, timeout: TimeInterval = xcodeSelectTimeout,
                                    environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-p"]
        process.environment = ToolEnvironment.minimal(environment)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        // Путь в несколько десятков байт: в буфер канала влезает, читаем после выхода.
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// Владелец и права звена пути, без перехода по ссылке.
    public struct PathStatus: Equatable, Sendable {
        public var uid: UInt32
        public var mode: UInt16
        public var isSymlink: Bool

        public init(uid: UInt32, mode: UInt16, isSymlink: Bool) {
            self.uid = uid
            self.mode = mode
            self.isSymlink = isSymlink
        }

        /// root, не ссылка, не открыт на запись группе и прочим.
        public var isRootOnly: Bool { uid == 0 && !isSymlink && mode & 0o022 == 0 }
    }

    public static func lstatus(_ path: String) -> PathStatus? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return PathStatus(uid: info.st_uid, mode: UInt16(info.st_mode), isSymlink: info.st_mode & S_IFMT == S_IFLNK)
    }

    public static let commandLineTools = "/Library/Developer/CommandLineTools"

    static func isSystemDeveloperDir(_ dir: String) -> Bool {
        if dir == commandLineTools { return true }
        let parts = dir.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return parts.count == 5 && parts[0].isEmpty && parts[1] == "Applications" && parts[2].hasSuffix(".app")
            && parts[2].count > 4 && !parts[2].hasPrefix(".") && parts[3] == "Contents" && parts[4] == "Developer"
    }

    public static func environment(_ base: [String: String]) -> [String: String] {
        var env = ToolEnvironment.minimal(base)
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        return env
    }
}

/// П10 р4 Р4-2: самоперезапуск. Раньше — `/bin/sh -c "…sleep…open…"` с окружением родителя: `/bin/sh` читает
/// `BASH_ENV`/`ENV`, а `sleep` и `open` искал по `PATH` из `launchctl setenv`. Теперь утилиты — полным путём,
/// окружение — `ToolEnvironment.minimal`, путь бандла и pid — аргументами (`$0`, `$1`), не в тексте скрипта.
public enum Relaunch {
    public static let shell = "/bin/sh"
    public static let script = "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\""

    public static func arguments(pid: Int32, bundlePath: String) -> [String] {
        ["-c", script, bundlePath, String(pid)]
    }

    public static func environment(_ base: [String: String]) -> [String: String] {
        ToolEnvironment.minimal(base)
    }
}
