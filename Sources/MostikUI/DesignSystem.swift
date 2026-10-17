import AppKit
import MostikCore
import SwiftUI

// Дизайн-система Mostik. Один мир: тёплая бумага без серого UI-кита,
// чернильный тил как единственный акцент, системный SF Pro, цифры моноширинные.
// Сетка 4/8, радиусы концентрические: внешний = внутренний + отступ.

public enum DS {
    public enum Space {
        public static let xxs: CGFloat = 4
        public static let xs: CGFloat = 8
        public static let s: CGFloat = 12
        public static let m: CGFloat = 16
        public static let l: CGFloat = 24
        public static let xl: CGFloat = 32
        public static let xxl: CGFloat = 48
    }

    public enum Radius {
        /// Кнопки, поля, чипы.
        public static let control: CGFloat = 6
        /// Строки списков: control + 2 pt воздуха вокруг кнопок в строке.
        public static let row: CGFloat = 8
        /// Карточки; внутри них строки с отступом 4 → 8 + 4.
        public static let card: CGFloat = 12
        /// Пилюля HUD — половина высоты 44.
        public static let hud: CGFloat = 22
    }

    /// Минимальная зона нажатия на десктопе.
    public static let hit: CGFloat = 28
    /// Высота стандартного контрола.
    public static let controlHeight: CGFloat = 28
}

// MARK: - Цвет

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension Color {
    /// Цвет, который сам переключается со светлой темы на тёмную.
    static func dynamic(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1, darkAlpha: CGFloat? = nil) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? (darkAlpha ?? alpha) : alpha)
        })
    }

    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

/// Семантическая палитра. Нейтрали слегка тянутся к зелени акцента —
/// не холодный серый UI-кита и не кремовый «редакционный» фон.
public enum Palette {
    /// Фон окна.
    public static let canvas = Color.dynamic(0xF7F8F6, 0x1A1C1B)
    /// Поднятая поверхность: карточки, деталь, HUD без материала.
    public static let surface = Color.dynamic(0xFFFFFF, 0x232625)
    /// Утопленная колонка: список истории, поля ввода.
    public static let sunken = Color.dynamic(0xEFF2EF, 0x161817)
    /// Заливка выбранной строки.
    public static let selection = Color.dynamic(0xE3ECE9, 0x2A3532)
    /// Наведение на строку.
    public static let hover = Color.dynamic(0x1A1D1C, 0xECEFED, alpha: 0.04, darkAlpha: 0.05)

    public static let ink = Color.dynamic(0x1A1D1C, 0xECEFED)
    /// Вторичный текст: 5,9:1 на белом.
    public static let inkSecondary = Color.dynamic(0x59615E, 0xA3ACA8)
    /// Третичный — только подсказки и разделители смысла, не основное.
    /// Подсказка — тоже текст: ≥ 4,5:1 на всех фонах (ContrastTests); иерархия — размером и весом.
    public static let inkTertiary = Color.dynamic(0x646B68, 0x959C99)

    /// Край поверхности: собственный тон, низкая непрозрачность.
    public static let edge = Color.dynamic(0x1A1D1C, 0xFFFFFF, alpha: 0.08, darkAlpha: 0.07)
    public static let edgeStrong = Color.dynamic(0x1A1D1C, 0xFFFFFF, alpha: 0.14, darkAlpha: 0.12)

    /// Единственный акцент — чернильный тил, тональный, не кислотный.
    public static let accent = Color.dynamic(0x2B6B61, 0x7FC6B8)
    public static let accentSoft = Color.dynamic(0x2B6B61, 0x7FC6B8, alpha: 0.10, darkAlpha: 0.16)
    public static let onAccent = Color.dynamic(0xFFFFFF, 0x0F1F1C)

    /// Запись — системный смысл «идёт запись», не декоративный.
    /// ≥ 4,5:1 и на тинтах (ContrastTests).
    public static let record = Color.dynamic(0xB33928, 0xFF8473)
    public static let recordSoft = Color.dynamic(0xB33928, 0xFF8473, alpha: 0.10, darkAlpha: 0.16)
    /// Сомнения распознавания — приглушённая охра.
    public static let doubt = Color.dynamic(0x8A5A0B, 0xE2B45E)
    public static let doubtSoft = Color.dynamic(0xB7801F, 0xE2B45E, alpha: 0.12, darkAlpha: 0.14)
    /// Охра темнее — подпись на тинте сомнений поверх выделенной строки: ≥ 4,5:1 и там (ContrastTests).
    public static let doubtStrong = Color.dynamic(0x704805, 0xF0C77A)
    /// Говорящие во встречах: приглушённые тона одной светлоты.
    public static let speakers: [Color] = [
        accent,
        Color.dynamic(0x7A5C2E, 0xD3B17A),
        Color.dynamic(0x4E5F86, 0xA3B3DA),
        Color.dynamic(0x7C4E66, 0xD7A3BE),
    ]
}

// MARK: - Типографика

/// SF Pro, размеры macOS: 13 — основной текст, 11 — подписи.
public enum TType {
    public static let display = Font.system(size: 28, weight: .semibold)
    public static let title = Font.system(size: 20, weight: .semibold)
    public static let headline = Font.system(size: 15, weight: .semibold)
    public static let body = Font.system(size: 13)
    public static let bodyStrong = Font.system(size: 13, weight: .medium)
    public static let reading = Font.system(size: 15)
    public static let callout = Font.system(size: 12)
    public static let calloutStrong = Font.system(size: 12, weight: .semibold)
    public static let caption = Font.system(size: 11)
    public static let captionStrong = Font.system(size: 11, weight: .medium)
    /// Таймеры и метрики: моноширинные цифры, текст пропорциональный.
    public static func figure(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        Font.system(size: size, weight: weight).monospacedDigit()
    }
    /// Только для настоящих данных: идентификаторы, пути, bundle id.
    public static let code = Font.system(size: 12, design: .monospaced)
}

// MARK: - Движение

public enum Motion {
    /// «Уменьшить движение» в Универсальном доступе (шаг 3, п. 11): сдвиг и масштаб → затухание,
    /// прокрутки мгновенные, точка записи не пульсирует, значок строки меню статичен.
    public static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Раскрытия и смена состояний: пружина без отскока; при «Уменьшить движение» — короткое затухание.
    public static var spring: Animation {
        reduced ? .easeOut(duration: MotionSpec.reducedFade) : .spring(response: 0.34, dampingFraction: 0.88)
    }
    /// Частые взаимодействия — только короткое затухание.
    public static let quick = Animation.easeOut(duration: 0.12)
    /// Смена фаз плашки (шаг 3, п. 13): быстрее и без перелёта — 0,24 / 1,0.
    public static var phase: Animation { animation(MotionSpec.phaseSpring) }
    /// Подложка вкладок (шаг 3, п. 14) — 0,28 / 1,0; при «Уменьшить движение» — на месте.
    public static var tabIndicator: Animation? { reduced ? nil : animation(MotionSpec.tabIndicator) }
    /// Прокрутка к строке: при «Уменьшить движение» — сразу.
    public static var scroll: Animation? { MotionSpec.scrollAnimated(reduceMotion: reduced) ? spring : nil }

    static func animation(_ spec: MotionSpec.Spring) -> Animation {
        reduced ? .easeOut(duration: MotionSpec.reducedFade)
                : .spring(response: spec.response, dampingFraction: spec.damping)
    }
}

// MARK: - Режим снимка

/// В снимках `ImageRenderer` не умеет AppKit-контролы, прокрутку и материалы:
/// экраны подставляют честные SwiftUI-эквиваленты.
struct SnapshotKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    public var mostikSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
}
