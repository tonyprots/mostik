import CoreGraphics
import Foundation

/// Место плашки диктовки (решение автора): её можно перетащить мышью, место запоминается.
/// Хранится не точкой, а долей видимой области экрана, на котором плашка показывается: на другом
/// мониторе она встаёт в то же относительное место, а не улетает за край. Всё в координатах
/// экрана AppKit (начало — внизу слева), размеры — самой плашки, без полей под тень.
public enum HUDPosition {
    /// Центр плашки долей видимой области экрана: 0…1 по горизонтали и по вертикали.
    public struct Saved: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    /// Ключ своего места в UserDefaults: по нему же встаёт карточка словаря на место плашки.
    public static let defaultsKey = "hudPosition"

    /// Место по умолчанию: снизу по центру, в 40 pt над низом видимой области.
    public static let bottomInset: CGFloat = 40
    /// Плашка не прижимается к краю вплотную.
    public static let margin: CGFloat = 8
    /// Отпустили ближе этого к месту по умолчанию — это и есть место по умолчанию (своего места нет).
    public static let snapDistance: CGFloat = 16

    public static func defaultOrigin(plaque: CGSize, visible: CGRect) -> CGPoint {
        clamp(CGPoint(x: visible.midX - plaque.width / 2, y: visible.minY + bottomInset), plaque: plaque, visible: visible)
    }

    /// Начало плашки на экране: сохранённое место или по умолчанию; всегда целиком в видимой области.
    public static func origin(saved: Saved?, plaque: CGSize, visible: CGRect) -> CGPoint {
        guard let saved, saved.x.isFinite, saved.y.isFinite else { return defaultOrigin(plaque: plaque, visible: visible) }
        let fx = min(1, max(0, saved.x)), fy = min(1, max(0, saved.y))
        let center = CGPoint(x: visible.minX + CGFloat(fx) * visible.width, y: visible.minY + CGFloat(fy) * visible.height)
        return clamp(CGPoint(x: center.x - plaque.width / 2, y: center.y - plaque.height / 2), plaque: plaque, visible: visible)
    }

    /// Вернуть плашку в видимую область: ушла за край — встаёт к краю с отступом `margin`.
    /// Экран меньше плашки — по центру.
    public static func clamp(_ origin: CGPoint, plaque: CGSize, visible: CGRect) -> CGPoint {
        func axis(_ value: CGFloat, size: CGFloat, min lo: CGFloat, max hi: CGFloat) -> CGFloat {
            let low = lo + margin, high = hi - margin - size
            guard low <= high else { return (lo + hi - size) / 2 }
            return Swift.min(high, Swift.max(low, value))
        }
        return CGPoint(x: axis(origin.x, size: plaque.width, min: visible.minX, max: visible.maxX),
                       y: axis(origin.y, size: plaque.height, min: visible.minY, max: visible.maxY))
    }

    /// Что запомнить, когда плашку отпустили: nil — она у места по умолчанию, своё место не нужно.
    public static func save(origin: CGPoint, plaque: CGSize, visible: CGRect) -> Saved? {
        guard visible.width > 0, visible.height > 0 else { return nil }
        let placed = clamp(origin, plaque: plaque, visible: visible)
        let home = defaultOrigin(plaque: plaque, visible: visible)
        if hypot(placed.x - home.x, placed.y - home.y) <= snapDistance { return nil }
        return Saved(x: Double((placed.x + plaque.width / 2 - visible.minX) / visible.width),
                     y: Double((placed.y + plaque.height / 2 - visible.minY) / visible.height))
    }

    /// Экран для плашки: тот, где курсор; курсор вне всех экранов — первый (главный). nil — экранов нет.
    public static func screenIndex(mouse: CGPoint, screens: [CGRect]) -> Int? {
        guard !screens.isEmpty else { return nil }
        return screens.firstIndex { $0.contains(mouse) } ?? 0
    }

    /// Экран, на котором плашку отпустили: где больше её площади; ни на одном — ближайший к её центру.
    public static func screenIndex(plaque: CGRect, screens: [CGRect]) -> Int? {
        guard !screens.isEmpty else { return nil }
        let areas = screens.map { screen -> CGFloat in
            let overlap = screen.intersection(plaque)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        if let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 { return best }
        let center = CGPoint(x: plaque.midX, y: plaque.midY)
        return screens.indices.min { a, b in
            hypot(screens[a].midX - center.x, screens[a].midY - center.y) < hypot(screens[b].midX - center.x, screens[b].midY - center.y)
        }
    }

    /// Хранение в `UserDefaults` (JSON): битое значение — как будто места нет.
    public static func decode(_ data: Data?) -> Saved? {
        guard let data, let saved = try? JSONDecoder().decode(Saved.self, from: data),
              saved.x.isFinite, saved.y.isFinite else { return nil }
        return saved
    }

    public static func encode(_ saved: Saved?) -> Data? {
        saved.flatMap { try? JSONEncoder().encode($0) }
    }
}
