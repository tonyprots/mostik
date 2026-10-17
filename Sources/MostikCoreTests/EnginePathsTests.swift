import Foundation
import MostikCore

/// П8, пункт 1: порядок поиска движка и Python, без путей к машине разработчика.
func runEnginePathsTests() {
    let res = URL(fileURLWithPath: "/Applications/Mostik.app/Contents/Resources", isDirectory: true)
    let repo = URL(fileURLWithPath: "/src/mostik", isDirectory: true)
    let bundledPy = res.appendingPathComponent("python/bin/python3").path
    let repoPy = repo.appendingPathComponent("vendor/python/bin/python3").path

    // MARK: движок
    do {
        let all: (URL) -> Bool = { _ in true }
        equal(EnginePaths.engineDir(resources: res, environment: ["MOSTIK_ENGINE_DIR": "/x"], devRepoRoot: repo, hasEngine: all)?.path,
              res.appendingPathComponent("engine").path, "встроенный главнее переменной")
        let noBundle: (URL) -> Bool = { !$0.path.hasPrefix(res.path) }
        equal(EnginePaths.engineDir(resources: res, environment: ["MOSTIK_ENGINE_DIR": "/x"], devRepoRoot: repo, hasEngine: noBundle)?.path,
              "/x", "переменная для разработки")
        equal(EnginePaths.engineDir(resources: res, environment: [:], devRepoRoot: repo, hasEngine: noBundle)?.path,
              repo.appendingPathComponent("engine").path, "репозиторий в dev-сборке")
        equal(EnginePaths.engineDir(resources: res, environment: [:], devRepoRoot: nil, hasEngine: noBundle), nil,
              "в релизе репозитория нет — не нашли")
    }

    // MARK: Python
    do {
        let exec: (String) -> Bool = { _ in true }
        equal(EnginePaths.python(explicit: "", resources: res, environment: ["MOSTIK_PYTHON": "/env/py"], devRepoRoot: repo, isExecutable: exec),
              bundledPy, "встроенный")
        equal(EnginePaths.python(explicit: "/my/py", resources: res, environment: [:], devRepoRoot: repo, isExecutable: exec),
              "/my/py", "ручной выбор главнее")
        let notBundled: (String) -> Bool = { $0 != bundledPy }
        equal(EnginePaths.python(explicit: "", resources: res, environment: ["MOSTIK_PYTHON": "/env/py"], devRepoRoot: repo, isExecutable: notBundled),
              "/env/py", "MOSTIK_PYTHON")
        equal(EnginePaths.python(explicit: "", resources: res, environment: [:], devRepoRoot: repo, isExecutable: notBundled),
              repoPy, "vendor/python репозитория")
        equal(EnginePaths.python(explicit: "", resources: res, environment: [:], devRepoRoot: nil, isExecutable: notBundled), nil,
              "ничего нет — nil, а не чужой путь")
    }

    // MARK: П10 С3 — в выпуске Python и движок только изнутри бандла
    do {
        let exec: (String) -> Bool = { _ in true }
        equal(EnginePaths.python(explicit: "/tmp/evil/python", resources: res, environment: ["MOSTIK_PYTHON": "/env/py"],
                                 devRepoRoot: nil, isExecutable: exec, debug: false),
              bundledPy, "выбор из settings.json в выпуске не действует")
        let notBundled: (String) -> Bool = { $0 != bundledPy }
        equal(EnginePaths.python(explicit: "/tmp/evil/python", resources: res, environment: ["MOSTIK_PYTHON": "/env/py"],
                                 devRepoRoot: repo, isExecutable: notBundled, debug: false), nil,
              "встроенного нет — не находим, а не берём чужой")
        equal(EnginePaths.python(explicit: "/my/py", resources: res, environment: [:], devRepoRoot: repo,
                                 isExecutable: exec, debug: true), "/my/py", "в debug-сборке ручной выбор работает")
        let noBundle: (URL) -> Bool = { !$0.path.hasPrefix(res.path) }
        equal(EnginePaths.engineDir(resources: res, environment: ["MOSTIK_ENGINE_DIR": "/x"], devRepoRoot: nil,
                                    hasEngine: noBundle, debug: false), nil, "MOSTIK_ENGINE_DIR в выпуске не действует")
        check(EnginePaths.honorsExplicitPython(debug: false) == false)
    }

    // MARK: корень репозитория от исполняемого файла
    do {
        let exe = URL(fileURLWithPath: "/src/mostik/.build/arm64-apple-macosx/debug/Mostik")
        equal(EnginePaths.repoRoot(executable: exe, isRepo: { $0.path == "/src/mostik" })?.path, "/src/mostik")
        equal(EnginePaths.repoRoot(executable: exe, isRepo: { _ in false }), nil)
    }

    // MARK: настройки: свой интерпретатор
    do {
        let custom = try? JSONDecoder().decode(MostikSettings.self, from: Data(#"{"enginePython": "/opt/py"}"#.utf8))
        equal(custom?.enginePython, "/opt/py", "свой выбор сохраняется")
        equal(MostikSettings().enginePython, "", "по умолчанию — автопоиск")
    }

    // MARK: в исходниках приложения нет абсолютных путей к машине разработчика
    do {
        let here = URL(fileURLWithPath: #filePath)
        let sources = here.deletingLastPathComponent().deletingLastPathComponent()
        let banned = FileManager.default.homeDirectoryForCurrentUser.path + "/"
        var offenders: [String] = []
        if let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) {
            for case let file as URL in walker where file.pathExtension == "swift" {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                if text.contains(banned) { offenders.append(file.lastPathComponent) }
                // #filePath попадает в релизный бинарник строкой полного пути к исходнику.
                let isTest = file.path.contains("/MostikCoreTests/")
                if !isTest, text.contains("#file" + "Path") { offenders.append(file.lastPathComponent + " (#filePath)") }
            }
        }
        equal(offenders, [], "жёсткие пути в Sources/")
    }
}
