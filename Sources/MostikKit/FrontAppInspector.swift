import AppKit
import ApplicationServices
import Darwin
import MostikCore

/// Что сейчас впереди: приложение, заголовок окна, запущенные агенты в терминале.
public final class FrontAppInspector: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedNames: Set<String> = []
    private var cachedAt: Date = .distantPast
    public var cacheTTL: TimeInterval = 2

    public init() {}

    @MainActor
    public func current(agentCLIs: Set<String> = AgentAppPolicy.standard.agentCLIs) -> FrontApp {
        guard let app = NSWorkspace.shared.frontmostApplication else { return FrontApp(bundleID: "") }
        return FrontApp(bundleID: app.bundleIdentifier ?? "",
                        name: app.localizedName ?? "",
                        windowTitle: Self.focusedWindowTitle(pid: app.processIdentifier),
                        runningAgentCLIs: runningAgentCLIs(candidates: agentCLIs))
    }

    /// То же для уже известного приложения, с любого потока (шаг 1, п. 1): AX-заголовок
    /// и обход процессов идут вне главного потока, после старта записи.
    public func describe(bundleID: String, name: String, pid: pid_t,
                         agentCLIs: Set<String> = AgentAppPolicy.standard.agentCLIs) -> FrontApp {
        FrontApp(bundleID: bundleID, name: name, windowTitle: Self.focusedWindowTitle(pid: pid),
                 runningAgentCLIs: runningAgentCLIs(candidates: agentCLIs))
    }

    @MainActor
    public static var frontmostBundleID: String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }

    /// Заголовок окна в фокусе через AX; без Accessibility — пустая строка.
    public static func focusedWindowTitle(pid: pid_t) -> String {
        guard AXIsProcessTrusted() else { return "" }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return "" }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success
        else { return "" }
        return title as? String ?? ""
    }

    /// Какие из `candidates` запущены как процессы; кэш на `cacheTTL`.
    public func runningAgentCLIs(candidates: Set<String>) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        if Date().timeIntervalSince(cachedAt) > cacheTTL || candidates != cachedCandidates {
            cachedNames = Self.processNames(agentNames: candidates)
            cachedCandidates = candidates
            cachedAt = Date()
        }
        return candidates.filter { cachedNames.contains($0.lowercased()) }
    }
    private var cachedCandidates: Set<String> = []

    /// Имена всех процессов: короткое имя и последний компонент пути к бинарнику.
    /// У node, bun и deno имя — сам интерпретатор, поэтому агента (`claude`, `codex`,
    /// `gemini` из npm) узнаём по argv через `KERN_PROCARGS2` (`ProjectResolver.agentName`).
    static func processNames(agentNames: Set<String> = []) -> Set<String> {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }
        var names = Set<String>()
        var nameBuf = [CChar](repeating: 0, count: 256)
        var pathBuf = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            var path = ""
            if proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 { path = String(cString: pathBuf) }
            // Claude.app и прочие GUI-приложения — не CLI-агенты в терминале.
            if path.contains(".app/Contents/") { continue }
            if !path.isEmpty { names.insert((path as NSString).lastPathComponent.lowercased()) }
            var name = ""
            if proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0 {
                name = String(cString: nameBuf).lowercased()
                names.insert(name)
            }
            var entry = ProcessEntry(pid: pid, ppid: 0, name: name, path: path)
            if !agentNames.isEmpty, ProjectResolver.isInterpreter(entry) {
                entry.args = ProjectDetector.args(pid: pid)
                if let agent = ProjectResolver.agentName(entry, names: agentNames) { names.insert(agent) }
            }
        }
        return names
    }
}
