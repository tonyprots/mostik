import Foundation
import MostikCore
import os

/// Замеры диктовки (шаг 0, «Плавность и быстродействие»): os_signpost для Instruments
/// (Points of Interest, `log stream --signpost --predicate 'subsystem == "app.mostik"'`)
/// и строка отрезков в `app.log` на каждую диктовку. Только время, без текста и имён приложений.
public enum Perf {
    public static let signposter = OSSignposter(subsystem: "app.mostik", category: "dictation")

    /// Время для отрезков: то же, что у машины диктовки.
    public static var now: Double { ProcessInfo.processInfo.systemUptime }
}

/// Одна диктовка: общий signpost-id, отметки и интервалы. Живёт на главном потоке,
/// кроме `firstBuffer` — его ставит очередь записи через `markFromAnyThread`.
public final class DictationPerf: @unchecked Sendable {
    public let session: String
    public let signpostID: OSSignpostID
    private let lock = NSLock()
    private var timeline = DictationTimeline()
    private var intervals: [String: OSSignpostIntervalState] = [:]
    private var finished = false

    public init(session: String, at time: Double = Perf.now) {
        self.session = session
        signpostID = Perf.signposter.makeSignpostID()
        mark(.hotkey, at: time)
    }

    /// Пришёл ли первый буфер микрофона (диагностика залипшего входа).
    public var hasFirstBuffer: Bool {
        lock.lock(); defer { lock.unlock() }
        return timeline.marks[.firstBuffer] != nil
    }

    public func mark(_ point: DictationTimeline.Mark, at time: Double = Perf.now) {
        lock.lock()
        let first = timeline.marks[point] == nil
        timeline.mark(point, at: time)
        lock.unlock()
        guard first else { return }
        switch point {
        case .hotkey: Perf.signposter.emitEvent("hotkey", id: signpostID)
        case .hudShown: Perf.signposter.emitEvent("hud.shown", id: signpostID)
        case .firstBuffer: Perf.signposter.emitEvent("recorder.firstBuffer", id: signpostID)
        case .release: Perf.signposter.emitEvent("release", id: signpostID)
        case .engineFinal: Perf.signposter.emitEvent("engine.final", id: signpostID)
        case .pastePosted: Perf.signposter.emitEvent("paste.posted", id: signpostID)
        case .idle: Perf.signposter.emitEvent("machine.idle", id: signpostID)
        }
    }

    /// Интервалы: `plan`, `recorder.start`, `engine.final`, `deliver`.
    public func begin(_ name: StaticString) {
        let state = Perf.signposter.beginInterval(name, id: signpostID)
        lock.lock(); intervals["\(name)"] = state; lock.unlock()
    }

    public func end(_ name: StaticString, _ detail: String = "") {
        lock.lock(); let state = intervals.removeValue(forKey: "\(name)"); lock.unlock()
        guard let state else { return }
        Perf.signposter.endInterval(name, state, "\(detail, privacy: .public)")
    }

    public func ms(_ from: DictationTimeline.Mark, _ to: DictationTimeline.Mark) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return timeline.ms(from, to)
    }

    /// Итог в журнал один раз: отрезки и раскладка хвоста движка.
    public func finish(engine: String = "", dropped: Int = 0) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return nil }
        finished = true
        var parts = [timeline.summary]
        if !engine.isEmpty { parts.append("engine: " + engine) }
        if dropped > 0 { parts.append("dropped presses \(dropped)") }
        return parts.filter { !$0.isEmpty }.joined(separator: " | ")
    }
}
