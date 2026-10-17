import AppKit
import Combine
import Foundation
import MostikCore
import MostikKit
import MostikUI

// Синтетические замеры пакета «Плавность и быстродействие» (docs/bench.md).
// Без микрофона, Accessibility и вставки: только то, что можно мерить без разрешений.
// Запуск: `swift run -c release MostikBench [повторов]`.

let repeats = max(5, Int(CommandLine.arguments.dropFirst().first ?? "") ?? 7)

func loadAverage() -> String {
    var load = [Double](repeating: 0, count: 3)
    getloadavg(&load, 3)
    return load.map { String(format: "%.1f", $0) }.joined(separator: " ")
}

func median(_ xs: [Double]) -> Double {
    let s = xs.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

func measure(_ name: String, _ body: () -> Void) {
    var samples: [Double] = []
    for _ in 0..<repeats {
        let start = Perf.now
        body()
        samples.append((Perf.now - start) * 1000)
    }
    print(String(format: "%-44@ медиана %7.1f мс  (min %.1f, max %.1f, n=%d, load %@)",
                 name as NSString, median(samples), samples.min() ?? 0, samples.max() ?? 0, repeats,
                 loadAverage() as NSString))
}

@MainActor
func run() {
    print("MostikBench · \(Date()) · load \(loadAverage())")

    // 1. Обходы процессов на нажатии (шаг 1, п. 1): раньше — на main до `recorder.begin`.
    let inspector = FrontAppInspector()
    inspector.cacheTTL = 0
    let agents = AgentAppPolicy.standard.agentCLIs
    measure("обход процессов: агенты (без кэша)") { _ = inspector.runningAgentCLIs(candidates: agents) }
    let detector = ProjectDetector()
    if let app = NSWorkspace.shared.frontmostApplication {
        measure("обход процессов: автопроект") { _ = detector.detect(app: app, windowTitle: "", agentNames: agents) }
    }

    // 2. Публикации AppModel за 10 с записи (шаг 2, п. 8): их видят все ~81 вид.
    //    Темп как у приложения: уровень 20 Гц, таймер плашки, частичный текст 1 Гц.
    let model = AppModel()
    var published = 0
    var meterPublished = 0
    var clockPublished = 0
    var iconPublished = 0
    let token = model.objectWillChange.sink { published += 1 }
    let tokens = [model.meter.objectWillChange.sink { meterPublished += 1 },
                  model.clock.objectWillChange.sink { clockPublished += 1 },
                  model.menuIcon.objectWillChange.sink { iconPublished += 1 }]
    model.hud = .recording
    published = 0
    iconPublished = 0
    for tick in 0..<200 {
        LiveFeed.pushLevel(Float(tick % 10) / 10, into: model)
        model.menuIcon.level(Float(tick % 10) / 10, at: Double(tick) * 0.05, reduceMotion: false)
        if tick % 2 == 0 { LiveFeed.tickElapsed(Double(tick) * 0.05, model: model) }
        if tick % 20 == 0 { model.partialText += " слово" }
    }
    token.cancel()
    tokens.forEach { $0.cancel() }
    print("публикаций AppModel за 10 с записи: \(published)")
    print("  волна (LevelMeter): \(meterPublished), часы (LiveClock): \(clockPublished), значок меню: \(iconPublished)")
}

MainActor.assumeIsolated { run() }
