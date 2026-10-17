import Foundation
import MostikCore

/// Где лежит движок и каким Python его запускать. Логика порядка — `EnginePaths` (MostikCore).
public enum EngineLocator {
    /// Корень репозитория — только в dev-сборке (`swift run`, debug). В релизе его нет:
    /// продовое приложение не должно знать путей к машине, на которой его собрали.
    public static func devRepoRoot(executable: URL? = Bundle.main.executableURL) -> URL? {
        #if DEBUG
        guard let executable else { return nil }
        let fm = FileManager.default
        return EnginePaths.repoRoot(executable: executable) { dir in
            fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path)
                && fm.fileExists(atPath: dir.appendingPathComponent("engine/mostik_engine").path)
        }
        #else
        return nil
        #endif
    }

    private static func hasEngine(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("mostik_engine").path)
    }

    /// Порядок: ресурсы бандла → MOSTIK_ENGINE_DIR → репозиторий (только dev).
    /// Не нашли — путь в бандле: `EngineClient` скажет «Движок не найден: …».
    public static func engineDir(bundle: Bundle = .main,
                                 environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let resources = bundle.resourceURL
        return EnginePaths.engineDir(resources: resources, environment: environment,
                                     devRepoRoot: devRepoRoot(), hasEngine: hasEngine)
            ?? (resources ?? URL(fileURLWithPath: "/")).appendingPathComponent(EnginePaths.bundledEngine, isDirectory: true)
    }

    /// Порядок: выбор в Настройках → встроенный → MOSTIK_PYTHON → `vendor/python` репозитория (только dev).
    /// Не нашли — путь в бандле: `EngineClient` скажет «Python не найден: …».
    public static func python(settings: MostikSettings, bundle: Bundle = .main,
                              environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let resources = bundle.resourceURL
        return EnginePaths.python(explicit: settings.enginePython, resources: resources, environment: environment,
                                  devRepoRoot: devRepoRoot()) { FileManager.default.isExecutableFile(atPath: $0) }
            ?? (resources ?? URL(fileURLWithPath: "/")).appendingPathComponent(EnginePaths.bundledPython).path
    }

    public static func config(settings: MostikSettings, paths: MostikPaths) -> EngineClient.Config {
        EngineClient.Config(python: python(settings: settings), engineDir: engineDir(), home: paths.root,
                            logFile: MostikLogPaths.standard.engine)
    }
}
