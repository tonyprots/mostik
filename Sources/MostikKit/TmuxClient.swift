import AppKit
import Foundation
import MostikCore

/// tmux для адресной вставки (G5, A5): найти бинарник, перечислить панели с агентами,
/// вставить текст bracketed paste и нажать Enter. Решения — `MostikCore/Tmux.swift`.
/// Все вызовы синхронные и короткие (таймаут 2 с) — звать не с главного потока.
public final class TmuxClient: @unchecked Sendable {
    public let binary: String?
    /// Имя сокета (`tmux -L`): тесты держат свой сервер и не трогают сессии пользователя.
    public let socketName: String?
    public var timeout: TimeInterval = 2

    public init(binary: String? = TmuxClient.locate(), socketName: String? = nil) {
        self.binary = binary
        self.socketName = socketName
    }

    public var isAvailable: Bool { binary != nil }

    /// Первый исполняемый tmux из известных мест: у GUI-приложения в PATH нет Homebrew.
    public static func locate(fileManager: FileManager = .default) -> String? {
        Tmux.candidatePaths.first { fileManager.isExecutableFile(atPath: $0) }
    }

    public struct RunResult: Sendable {
        public var status: Int32
        public var output: String
    }

    /// Запуск tmux с аргументами; `input` уходит в stdin. nil — tmux нет или он не ответил.
    @discardableResult
    public func run(_ args: [String], input: String? = nil) -> RunResult? {
        guard let binary else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = (socketName.map { ["-L", $0] } ?? []) + args
        // П10: урезанное окружение с системным PATH, без TMUX (`Tmux.environment`).
        process.environment = Tmux.environment(parent: ProcessInfo.processInfo.environment)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        do { try process.run() } catch { return nil }
        if let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        let done = DispatchSemaphore(value: 0)
        var data = Data()
        DispatchQueue.global(qos: .userInitiated).async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        return RunResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// Все панели; сервер не запущен — пусто.
    public func panes() -> [TmuxPane] {
        guard let result = run(Tmux.listArgs()), result.status == 0 else { return [] }
        return Tmux.parsePanes(result.output)
    }

    public func clients() -> [TmuxClientInfo] {
        guard let result = run(Tmux.clientsArgs()), result.status == 0 else { return [] }
        return Tmux.parseClients(result.output)
    }

    /// Панели с агентами; корень проекта — только при `projects`: поиск `.git` читает папку агента,
    /// а она может лежать в «Документах», и macOS спросит доступ без объяснения.
    public func agentPanes(names: Set<String>, projects: Bool) -> [TmuxAgentPane] {
        let panes = panes()
        guard !panes.isEmpty else { return [] }
        let processes = ProjectDetector.snapshot()
        return Tmux.agentPanes(panes, processes: processes, names: names).map { found in
            var pane = found
            if projects, let cwd = ProjectDetector.cwd(pid: found.agentPID) ?? (found.pane.path.isEmpty ? nil : found.pane.path) {
                pane.project = ProjectResolver.projectRoot(of: cwd)
            }
            return pane
        }
    }

    /// Сессия tmux, которую показывает приложение (терминал впереди); `hasClient` false — в нём нет клиента tmux.
    public func focusedSession(appPID: Int32, bundlePath: String?) -> (hasClient: Bool, session: String?) {
        let processes = ProjectDetector.snapshot()
        let local = ProjectResolver.agentProcesses(appPID: appPID, appBundlePath: bundlePath,
                                                   in: processes, names: ["tmux"])
        guard !local.isEmpty else { return (false, nil) }
        let session = TmuxTargeting.focusedSession(clients(), frontClientPIDs: Set(local.map(\.pid)))
        return (true, session)
    }

    /// Bracketed paste в панель. Переводы строк — LF: CR в терминале — это Enter.
    public func paste(_ text: String, pane: String, id: String) -> Bool {
        let buffer = Tmux.bufferName(id)
        let commands = Tmux.pasteCommands(pane: pane, buffer: buffer)
        guard let load = run(commands[0], input: VoiceSend.terminalNewlines(text)), load.status == 0 else { return false }
        guard let paste = run(commands[1]), paste.status == 0 else {
            run(["delete-buffer", "-b", buffer])
            return false
        }
        return true
    }

    public func enter(pane: String) -> Bool {
        run(Tmux.enterCommand(pane: pane))?.status == 0
    }

    /// Доставка в панель как отчёт обычной вставки: буфер обмена не трогаем, проверки поля нет.
    public func deliver(_ text: String, pane: String, id: String) async -> DeliveryReport {
        let ok = await Task.detached { [self] in paste(text, pane: pane, id: id) }.value
        if ok { return DeliveryReport(outcome: .inserted, check: .unknown, before: nil, after: nil, sent: text) }
        return DeliveryReport(outcome: .failed("tmux"), check: nil, before: nil, after: nil, sent: text)
    }
}

/// Нажатие Return без модификаторов — голосовая отправка (G6) вне tmux.
public enum KeyPresser {
    @discardableResult
    public static func pressReturn() -> Bool {
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else { return false }
        let source = CGEventSource(stateID: .privateState)
        let key = CGKeyCode(36) // kVK_Return
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
        down.flags = []
        up.flags = []
        down.post(tap: .cghidEventTap)
        usleep(8_000)
        up.post(tap: .cghidEventTap)
        return true
    }
}
