import Darwin
import Foundation
import MostikCore

/// Журнал приложения в `~/Library/Logs/Mostik/app.log` с ротацией (П8, пункт 6).
/// Только события и ошибки, без текста диктовок и встреч — см. `MostikLogPaths`.
public final class AppLog: @unchecked Sendable {
    public static let shared = AppLog(paths: .standard)

    public let paths: MostikLogPaths
    public let rotation: LogRotation
    private let queue = DispatchQueue(label: "mostik.applog")
    private var handle: FileHandle?
    private var size = 0

    public init(paths: MostikLogPaths, rotation: LogRotation = LogRotation()) {
        self.paths = paths
        self.rotation = rotation
    }

    /// Событие: `category` — подсистема (`app`, `engine`, `dictation`, `meeting`…),
    /// `message` — что случилось. Никакого пользовательского текста.
    public func event(_ category: String, _ message: String) {
        let line = LogLine.format(Date(), category: category, message: message)
        queue.async { self.write(line) }
    }

    public func error(_ category: String, _ message: String) {
        event(category, "error: " + message)
    }

    /// Дождаться записи (выход, тесты).
    public func flush() { queue.sync {} }

    private func write(_ line: String) {
        let data = Data(line.utf8)
        if handle == nil { open() }
        if rotation.shouldRotate(size: size, incoming: data.count) {
            try? handle?.close()
            handle = nil
            Self.rotate(paths.app, rotation)
            open()
        }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            size += data.count
        } catch {
            self.handle = nil
        }
    }

    private func open() {
        StorageHygiene.secure([paths.root])
        StorageHygiene.ensurePrivateFile(paths.app)
        handle = try? FileHandle(forWritingTo: paths.app)
        size = Int((try? handle?.seekToEnd()) ?? 0)
    }

    /// Ротация файла по плану `LogRotation`; ошибки молча пропускаются — журнал не важнее работы.
    public static func rotate(_ file: URL, _ rotation: LogRotation) { rotation.rotate(file) }

    /// Ротировать заранее, если файл уже больше лимита (журнал движка открывается при каждом запуске).
    public static func rotateIfNeeded(_ file: URL, _ rotation: LogRotation) {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        if rotation.shouldRotate(size: size, incoming: 1) { rotate(file, rotation) }
    }
}

// MARK: - Отчёт о сбое

/// Локальные отчёты о сбое приложения в `~/Library/Logs/Mostik/crashes/`: необработанное
/// исключение Objective-C и смертельный сигнал (в том числе ловушки Swift — `fatalError`,
/// выход за границы массива). Ничего не отправляется.
public enum CrashReporter {
    /// Путь отчёта для сигнала готовится заранее: в обработчике сигнала нельзя выделять память.
    nonisolated(unsafe) private static var signalPath: UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) private static var signalHeader: UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) private static var signalHeaderLength = 0
    nonisolated(unsafe) private static var stackTitle: UnsafeMutablePointer<CChar>? = strdup("stack:\n")
    nonisolated(unsafe) private static var exceptionDir: URL?
    nonisolated(unsafe) private static var installed = false
    static let signals: [Int32] = [SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP]

    /// Поставить обработчики. Вызывается один раз при запуске; старые отчёты сверх лимита удаляются.
    public static func install(paths: MostikLogPaths = .standard, now: Date = Date()) {
        guard !installed else { return }
        installed = true
        StorageHygiene.secure([paths.root, paths.crashes])
        prune(paths.crashes)
        exceptionDir = paths.crashes

        let pid = ProcessInfo.processInfo.processIdentifier
        let path = paths.crashes.appendingPathComponent(CrashReportPolicy.fileName(kind: "app", date: now, pid: pid)).path
        signalPath = strdup(path)
        let header = """
        Mostik — отчёт о сбое / crash report
        Только на этом Mac, никуда не отправляется. / Stays on this Mac, never sent.

        version: \(version)
        system: \(ProcessInfo.processInfo.operatingSystemVersionString)
        launched: \(LogLine.format(now, category: "crash", message: "").split(separator: " ").first ?? "")
        kind: fatal signal
        signal: 
        """
        signalHeader = strdup(header)
        signalHeaderLength = header.utf8.count

        NSSetUncaughtExceptionHandler { exception in
            CrashReporter.writeException(exception)
        }
        for sig in signals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = CrashReporter.handleSignal
            sigemptyset(&action.sa_mask)
            action.sa_flags = 0
            sigaction(sig, &action, nil)
        }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    static func prune(_ dir: URL) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in CrashReportPolicy.excess(names) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    private static func writeException(_ exception: NSException) {
        guard let dir = exceptionDir else { return }
        let now = Date()
        let text = CrashReportPolicy.exceptionReport(
            name: exception.name.rawValue, reason: exception.reason ?? "", stack: exception.callStackSymbols,
            version: version, system: ProcessInfo.processInfo.operatingSystemVersionString, date: now)
        let url = dir.appendingPathComponent(CrashReportPolicy.fileName(kind: "app", date: now,
                                                                        pid: ProcessInfo.processInfo.processIdentifier))
        StorageHygiene.writePrivate(text, to: url)
        AppLog.shared.event("crash", "uncaught exception \(exception.name.rawValue) → \(url.lastPathComponent)")
        AppLog.shared.flush()
    }

    /// Только async-signal-safe вызовы: open, write, backtrace_symbols_fd, close, raise.
    private static let handleSignal: @convention(c) (Int32) -> Void = { sig in
        if let path = CrashReporter.signalPath {
            let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
            if fd >= 0 {
                if let header = CrashReporter.signalHeader { _ = write(fd, header, CrashReporter.signalHeaderLength) }
                var digits: (CChar, CChar, CChar, CChar) = (0, 0, 0, 10)
                var n = Int32(sig), i = 2
                withUnsafeMutableBytes(of: &digits) { raw in
                    repeat { raw[i] = UInt8(48 + n % 10); n /= 10; i -= 1 } while n > 0 && i >= 0
                    _ = write(fd, raw.baseAddress! + i + 1, 3 - i)
                }
                if let title = CrashReporter.stackTitle { _ = write(fd, title, strlen(title)) }
                var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
                let count = backtrace(&frames, 64)
                backtrace_symbols_fd(&frames, count, fd)
                close(fd)
            }
        }
        signal(sig, SIG_DFL)
        raise(sig)
    }
}
