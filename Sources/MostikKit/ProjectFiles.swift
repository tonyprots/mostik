import Foundation
import MostikCore

/// Файлы проекта для автотега (A3): `git ls-files` (с учётом .gitignore), без git — обход папки
/// без служебных каталогов. Кэш на корень, обновление не чаще раза в `ttl`.
public final class ProjectFiles: @unchecked Sendable {
    public static let limit = 50_000
    public var ttl: TimeInterval = 120
    private let lock = NSLock()
    private var cache: [String: (at: Date, index: FileIndex)] = [:]
    private var loading: Set<String> = []

    public init() {}

    /// Готовый индекс, если он есть и свежий; иначе nil и фоновое обновление.
    public func index(root: String) -> FileIndex? {
        lock.lock()
        let cached = cache[root]
        let stale = cached.map { Date().timeIntervalSince($0.at) > ttl } ?? true
        let start = stale && !loading.contains(root)
        if start { loading.insert(root) }
        lock.unlock()
        if start {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let index = FileIndex(paths: Self.list(root: root))
                guard let self else { return }
                self.lock.lock()
                self.cache[root] = (Date(), index)
                self.loading.remove(root)
                self.lock.unlock()
            }
        }
        return cached?.index
    }

    /// Подождать индекс до `timeout`: при первой диктовке в проекте он ещё строится.
    public func index(root: String, waiting timeout: TimeInterval) async -> FileIndex? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let index = index(root: root) { return index }
            if Date() >= deadline { return nil }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    static let skipped: Set<String> = [".git", "node_modules", ".build", ".build-release", "build", "dist", "target",
                                       ".venv", "venv", "__pycache__", "Pods", "DerivedData", ".next", ".cache"]

    public static func list(root: String) -> [String] {
        if let files = gitFiles(root: root) { return files }
        var out: [String] = []
        let base = URL(fileURLWithPath: root)
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let prefix = base.standardizedFileURL.path + "/"
        for case let url as URL in walker {
            if skipped.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            let path = url.standardizedFileURL.path
            if path.hasPrefix(prefix) { out.append(String(path.dropFirst(prefix.count))) }
            if out.count >= limit { break }
        }
        return out
    }

    /// П10 р5 Р5-2: git мимо шима `/usr/bin/git` (его уводит подложенный кэш xcrun) — из папки разработчика
    /// по `xcode-select -p` (спрашиваем один раз за запуск); путь проверяет `SafeGit.executable`. nil — обход папки.
    /// Ф-1: владельцев цепочки — перед каждым запуском git: `.app` в `/Applications` могли подменить после старта.
    private static let developerDirectory: String? = SafeGit.developerDir()
    static var git: String? {
        SafeGit.executable(developerDir: developerDirectory, isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    static func gitFiles(root: String) -> [String]? {
        guard FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(".git")),
              let git = Self.git else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        // П10: репозиторий может быть чужим — без fsmonitor, хуков и `GIT_*` (`SafeGit`).
        process.arguments = SafeGit.arguments(root: root, ["ls-files", "-z", "--cached", "--others", "--exclude-standard"])
        process.environment = SafeGit.environment(ProcessInfo.processInfo.environment)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let files = data.split(separator: 0).prefix(limit).map { String(decoding: $0, as: UTF8.self) }
        return files
    }
}
