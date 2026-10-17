import Foundation

// Пакет «Плавность и быстродействие»: чистая логика замеров и порядка работ
// вокруг диктовки. Платформенная часть (signpost, AppKit) — в MostikKit и приложении.

/// Отрезки одной диктовки (шаг 0): нажатие → плашка → первый буфер, отпускание → ⌘V → покой.
/// Время — `systemUptime` в секундах; первая отметка каждой точки выигрывает.
public struct DictationTimeline: Equatable, Sendable {
    public enum Mark: String, CaseIterable, Sendable {
        case hotkey, hudShown, firstBuffer, release, engineFinal, pastePosted, idle
    }

    public private(set) var marks: [Mark: Double] = [:]

    public init() {}

    public mutating func mark(_ mark: Mark, at time: Double) {
        if marks[mark] == nil { marks[mark] = time }
    }

    /// Отрезок `from → to` в миллисекундах, округлённый до целых; nil — какой-то отметки нет.
    public func ms(_ from: Mark, _ to: Mark) -> Double? {
        guard let a = marks[from], let b = marks[to] else { return nil }
        return ((b - a) * 1000).rounded()
    }

    /// Строка для журнала: только отрезки, без текста и имён приложений (П10).
    public var summary: String {
        let parts: [(String, Mark, Mark)] = [
            ("hotkey→hud", .hotkey, .hudShown),
            ("hotkey→buffer", .hotkey, .firstBuffer),
            ("release→final", .release, .engineFinal),
            ("release→paste", .release, .pastePosted),
            ("release→idle", .release, .idle),
        ]
        return parts.compactMap { name, a, b in ms(a, b).map { "\(name) \(Int($0)) ms" } }
            .joined(separator: " · ")
    }
}

/// Шлюз звука до `start` (шаг 1, п. 1): микрофон стартует раньше, чем готов план сессии,
/// поэтому куски PCM копятся здесь и уходят движку только после `start` — по порядку.
/// Потокобезопасен: `push` зовёт очередь записи, `open`/`close` — главный поток.
public final class StartGate<Item>: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Item] = []
    private var sink: ((Item) -> Void)?
    private var closed = false

    public init() {}

    public func push(_ item: Item) {
        lock.lock(); defer { lock.unlock() }
        if let sink { sink(item); return }
        if !closed { pending.append(item) }
    }

    /// Отдать накопленное и дальше пропускать напрямую. Под замком: новый кусок не обгонит старые.
    public func open(_ sink: @escaping (Item) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        for item in pending { sink(item) }
        pending.removeAll()
        self.sink = sink
    }

    /// Запись отменили до `start`: всё накопленное — прочь, дальше ничего не копим.
    public func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        sink = nil
        pending.removeAll()
    }

    public var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }
}

/// Обход AX-родителей в поиске адреса страницы (шаг 1, п. 1): раньше до 40 уровней по 0,2 с
/// на каждый — до 8 с на main в худшем случае. Теперь общий срок 100 мс и тот же предел глубины.
public struct AXWalkBudget: Sendable {
    public static let standardDeadline: Double = 0.1
    public let maxDepth: Int
    public let deadline: Double
    public let startedAt: Double
    private var steps = 0

    public init(maxDepth: Int = 40, deadline: Double = AXWalkBudget.standardDeadline, startedAt: Double) {
        self.maxDepth = maxDepth
        self.deadline = deadline
        self.startedAt = startedAt
    }

    /// Можно ли сделать ещё один шаг вверх.
    public mutating func allowsStep(now: Double) -> Bool {
        guard steps < maxDepth, now - startedAt < deadline else { return false }
        steps += 1
        return true
    }

    public func left(now: Double) -> Double { max(0, deadline - (now - startedAt)) }

    /// Таймаут одного AX-вызова: остаток срока, но не больше прежних 0,2 с и не меньше 10 мс.
    public static func messagingTimeout(left: Double) -> Float {
        Float(min(0.2, max(0.01, left)))
    }
}

/// Уровень микрофона для волны (шаг 3, п. 12): рост мгновенный, спад экспонентой ~120 мс
/// (×0,75 на тике 50 мс). Сглаживание — в данных, анимации у волны нет.
public enum LevelSmoothing {
    public static let decay: Float = 0.75

    public static func next(previous: Float, sample: Float) -> Float {
        max(sample, previous * decay)
    }

    /// Новый уровень в конец буфера; буфер едет лентой, старое уходит с начала.
    public static func push(_ sample: Float, into ring: inout [Float]) {
        let value = next(previous: ring.last ?? 0, sample: sample)
        if !ring.isEmpty { ring.removeFirst() }
        ring.append(value)
    }
}

/// Иконка строки меню «дышит» голосом при записи (решение автора):
/// не чаще ~10 Гц и только при смене ступени — строка меню не перерисовывается зря.
public struct MenuBarMeter: Sendable {
    public static let steps = 4
    public static let minInterval: Double = 0.1
    private var lastAt: Double?
    private var lastStep: Int?

    public init() {}

    /// Новая ступень 0…3, если её пора показать; nil — оставить как есть.
    public mutating func update(level: Float, at now: Double) -> Int? {
        if let lastAt, now - lastAt < Self.minInterval { return nil }
        let step = min(Self.steps - 1, max(0, Int((level * Float(Self.steps)).rounded(.down))))
        guard step != lastStep else { return nil }
        lastAt = now
        lastStep = step
        return step
    }

    /// Доля заливки символа (`variableValue`): даже в тишине видно, что идёт запись.
    public static func variableValue(step: Int) -> Double {
        Double(min(steps, max(1, step + 1))) / Double(steps)
    }
}

/// Плашка диктовки (шаг 3, п. 13): экран выбирается на показе и дальше не меняется —
/// «Расшифровка» и «Вставлено» не перепрыгивают за курсором на другой монитор.
public enum HUDPlacement {
    public static let showDuration: Double = 0.12
    public static let hideDuration: Double = 0.15

    public static func reposition(wasVisible: Bool, phaseVisible: Bool) -> Bool {
        phaseVisible && !wasVisible
    }
}

/// Частые правки (ввод в поле Настроек) — одна запись после паузы `delay` (шаг 2, п. 10):
/// JSON настроек и связка ключей не трогаются на каждую клавишу.
public struct Coalescer<Value>: Sendable where Value: Sendable {
    public let delay: Double
    private var value: Value?
    public private(set) var deadline: Double?

    public init(delay: Double) { self.delay = delay }

    public mutating func submit(_ value: Value, at now: Double) {
        self.value = value
        deadline = now + delay
    }

    /// Значение, если пауза выдержана; отдаётся один раз.
    public mutating func due(at now: Double) -> Value? {
        guard let deadline, now >= deadline else { return nil }
        return flush()
    }

    /// Выход или смена контекста: отдать ждущее сразу.
    public mutating func flush() -> Value? {
        defer { value = nil; deadline = nil }
        return value
    }
}

/// Клавиша в пустой истории главного окна: та, что в Настройках, без декоративных соседей.
public struct KeyCapSpec: Equatable, Sendable {
    public let symbol: String
    public let caption: String?
}

extension HoldKeys {
    public static func emptyStateCaps(_ holdKey: String) -> [KeyCapSpec] {
        [KeyCapSpec(symbol: HUDHint.keySymbol(holdKey),
                    caption: holdKey == fn ? nil : UIText.pick("правый", "right"))]
    }
}

/// Числа движения (шаг 3, пп. 11–14) — одна точка правды для токенов `Motion` в MostikUI.
public enum MotionSpec {
    public struct Spring: Equatable, Sendable {
        public let response: Double
        public let damping: Double
        public init(response: Double, damping: Double) {
            self.response = response
            self.damping = damping
        }
    }

    /// Смена фаз плашки: короче прежних 0,34 / 0,88 и без перелёта.
    public static let phaseSpring = Spring(response: 0.24, damping: 1.0)
    /// Подложка вкладок.
    public static let tabIndicator = Spring(response: 0.28, damping: 1.0)
    /// Затухание вместо сдвига при «Уменьшить движение».
    public static let reducedFade = 0.15

    public enum Transition: Equatable, Sendable { case shiftAndFade, fade }

    /// Смена содержимого плашки и раскрытия: при «Уменьшить движение» — только прозрачность.
    public static func transition(reduceMotion: Bool) -> Transition { reduceMotion ? .fade : .shiftAndFade }
    public static func scrollAnimated(reduceMotion: Bool) -> Bool { !reduceMotion }
    /// Точка записи пульсирует; при «Уменьшить движение» — статична.
    public static func recordingDotPulses(reduceMotion: Bool) -> Bool { !reduceMotion }
    /// Знак Mostik оживает в онбординге один раз; при «Уменьшить движение» — статичен.
    public static func glyphAnimates(reduceMotion: Bool, alreadyPlayed: Bool) -> Bool { !reduceMotion && !alreadyPlayed }
}
