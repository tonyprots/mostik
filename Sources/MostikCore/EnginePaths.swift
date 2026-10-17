import Foundation

/// Где искать движок и Python к нему — чистая логика без обращения к диску (П8, пункт 1).
///
/// Порядок одинаков для обоих путей:
/// 1. встроенное в `.app` (`Contents/Resources/engine`, `Contents/Resources/python/bin/python3`);
/// 2. переменные окружения для разработки: `MOSTIK_ENGINE_DIR`, `MOSTIK_PYTHON`;
/// 3. только в dev-сборке (`swift run`) — репозиторий рядом с исполняемым файлом:
///    `engine/` и `vendor/python/bin/python3`.
///
/// Явный выбор Python в Настройках главнее всех трёх — только в debug-сборке (П10 С3): в выпуске
/// `enginePython` из `settings.json`, `MOSTIK_PYTHON` и `MOSTIK_ENGINE_DIR` не действуют, иначе правка
/// файла настроек или `launchctl setenv` запускала бы чужую программу с разрешениями Mostik.
/// Абсолютных путей к чьей-то машине здесь нет: продовая сборка находит всё внутри бандла.
public enum EnginePaths {
    /// Относительно `Contents/Resources` бандла.
    public static let bundledEngine = "engine"
    public static let bundledPython = "python/bin/python3"
    /// Относительно корня репозитория.
    public static let repoEngine = "engine"
    public static let repoPython = "vendor/python/bin/python3"

    /// Каталог с пакетом `mostik_engine`; nil — не нашли нигде.
    public static func engineDir(
        resources: URL?,
        environment: [String: String],
        devRepoRoot: URL?,
        hasEngine: (URL) -> Bool,
        debug: Bool = DebugOverrides.isDebugBuild
    ) -> URL? {
        if let res = resources?.appendingPathComponent(bundledEngine, isDirectory: true), hasEngine(res) {
            return res
        }
        if debug, let env = environment["MOSTIK_ENGINE_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: NSString(string: env).expandingTildeInPath, isDirectory: true)
        }
        if let repo = devRepoRoot?.appendingPathComponent(repoEngine, isDirectory: true), hasEngine(repo) {
            return repo
        }
        return nil
    }

    /// Интерпретатор движка; nil — не нашли нигде.
    public static func python(
        explicit: String,
        resources: URL?,
        environment: [String: String],
        devRepoRoot: URL?,
        isExecutable: (String) -> Bool,
        debug: Bool = DebugOverrides.isDebugBuild
    ) -> String? {
        let chosen = NSString(string: explicit).expandingTildeInPath
        if honorsExplicitPython(debug: debug), !chosen.isEmpty {
            return chosen
        }
        if let bundled = resources?.appendingPathComponent(bundledPython).path, isExecutable(bundled) {
            return bundled
        }
        guard debug else { return nil }
        if let env = environment["MOSTIK_PYTHON"], !env.isEmpty {
            return NSString(string: env).expandingTildeInPath
        }
        if let repo = devRepoRoot?.appendingPathComponent(repoPython).path, isExecutable(repo) {
            return repo
        }
        return nil
    }

    /// Действует ли выбор Python из Настроек: только в debug-сборке (П10 С3).
    public static func honorsExplicitPython(debug: Bool = DebugOverrides.isDebugBuild) -> Bool { debug }

    /// Корень репозитория для dev-сборки: вверх от исполняемого файла
    /// (`.build/debug/Mostik`) до каталога с `Package.swift` и `engine/mostik_engine`.
    public static func repoRoot(executable: URL, isRepo: (URL) -> Bool, maxDepth: Int = 6) -> URL? {
        var dir = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<maxDepth {
            if isRepo(dir) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }
}
