import Foundation
import MostikCore

/// Запуск хука после встречи (M11): `/bin/zsh -fc <команда> mostik-hook <папка>`, таймаут, вывод в лог.
/// Решение, запускать ли, — `MeetingHook.decide` в MostikCore; здесь только процесс.
public enum MeetingHookRunner {
    public struct Result: Sendable {
        public var exitCode: Int32?
        public var timedOut: Bool
        public var seconds: Double
        public var output: String
    }

    public static func run(command: String, folder: URL, event: MeetingHook.Event, timeout: TimeInterval) async -> Result {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: runSync(command: command, folder: folder, event: event, timeout: timeout))
            }
        }
    }

    static func runSync(command: String, folder: URL, event: MeetingHook.Event, timeout: TimeInterval) -> Result {
        let started = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: MeetingHook.shell)
        process.arguments = MeetingHook.arguments(command: command, folder: folder)
        process.environment = MeetingHook.environment(folder: folder, event: event,
                                                      base: ProcessInfo.processInfo.environment)
        process.currentDirectoryURL = folder
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let collected = OutputBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { collected.append(data) }
        }
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return Result(exitCode: nil, timedOut: false, seconds: 0, output: L("не запустилась: \(error.localizedDescription)", "didn’t start: \(error.localizedDescription)"))
        }
        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if done.wait(timeout: .now() + 3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 2)
            }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? pipe.fileHandleForReading.readToEnd() { collected.append(rest) }
        return Result(exitCode: process.isRunning ? nil : process.terminationStatus, timedOut: timedOut,
                      seconds: Date().timeIntervalSince(started), output: collected.text)
    }
}

/// Вывод процесса с потолком: болтливый хук не съест память.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit = MeetingHook.outputLimit * 4

    func append(_ chunk: Data) {
        lock.withLock {
            guard data.count < limit else { return }
            data.append(chunk.prefix(limit - data.count))
        }
    }

    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
