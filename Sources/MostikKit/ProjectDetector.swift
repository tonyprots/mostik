import AppKit
import Darwin
import MostikCore

/// Автопроект (договор этапа A): агент `claude`/`codex` в дереве процессов переднего
/// приложения → его рабочая папка (`proc_pidinfo` + `PROC_PIDVNODEPATHINFO`) → корень git.
/// Выбор процесса и подъём до корня — в `ProjectResolver` (MostikCore), здесь только система.
public final class ProjectDetector: @unchecked Sendable {
    private let lock = NSLock()
    /// Корень git по PID агента: рабочая папка агента за сессию не меняется.
    private var rootByPID: [Int32: (start: Double, root: String?)] = [:]

    public init() {}

    /// Корень проекта агента в приложении `app`; nil — агента нет или он не в git.
    public func detect(app: NSRunningApplication, windowTitle: String, agentNames: Set<String>) -> String? {
        detect(pid: app.processIdentifier, bundlePath: app.bundleURL?.path, windowTitle: windowTitle, agentNames: agentNames)
    }

    /// С любого потока: на нажатии зовётся после старта записи, вне главного (шаг 1, п. 1).
    public func detect(pid: pid_t, bundlePath: String?, windowTitle: String, agentNames: Set<String>) -> String? {
        let processes = Self.snapshot()
        let agents = ProjectResolver.agentProcesses(appPID: pid, appBundlePath: bundlePath,
                                                    in: processes, names: agentNames)
        guard !agents.isEmpty else { return nil }
        var roots: [String] = []
        lock.lock()
        let alive = Set(processes.map(\.pid))
        rootByPID = rootByPID.filter { alive.contains($0.key) }
        for agent in agents {
            // PID мог достаться новому процессу — сверяем время запуска.
            if let cached = rootByPID[agent.pid], cached.start == agent.startTime {
                if let root = cached.root, !roots.contains(root) { roots.append(root) }
                continue
            }
            let root = Self.cwd(pid: agent.pid).flatMap { ProjectResolver.projectRoot(of: $0) }
            rootByPID[agent.pid] = (agent.startTime, root)
            if let root, !roots.contains(root) { roots.append(root) }
        }
        lock.unlock()
        return ProjectResolver.chooseRoot(roots, windowTitle: windowTitle)
    }

    /// Рабочая папка процесса; для чужого пользователя или исчезнувшего процесса — nil.
    public static func cwd(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    /// Все процессы: pid, ppid, имя, путь, время запуска; argv — только у node/bun/deno.
    static func snapshot() -> [ProcessEntry] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }
        var result: [ProcessEntry] = []
        result.reserveCapacity(Int(filled))
        var pathBuf = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            var bsd = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { continue }
            let name = withUnsafePointer(to: &bsd.pbi_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
            }
            var path = ""
            if proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 { path = String(cString: pathBuf) }
            var entry = ProcessEntry(pid: pid, ppid: Int32(bsd.pbi_ppid), name: name, path: path,
                                     startTime: Double(bsd.pbi_start_tvsec) + Double(bsd.pbi_start_tvusec) / 1e6)
            if ProjectResolver.isInterpreter(entry) { entry.args = args(pid: pid) }
            result.append(entry)
        }
        return result
    }

    /// argv через `KERN_PROCARGS2`.
    static func args(pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        return ProjectResolver.parseProcArgs(Array(buffer.prefix(size)))
    }
}
