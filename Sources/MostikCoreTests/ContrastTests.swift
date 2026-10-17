import Foundation

// Контраст палитры по WCAG 2.x (П8, п. 9). Палитра живёт в MostikUI (SwiftUI), тесты — без UI,
// поэтому цвета берутся разбором `Sources/MostikUI/DesignSystem.swift`: `Color.dynamic(светлый, тёмный,
// alpha:, darkAlpha:)`. Полупрозрачные заливки сперва композятся на фон, под которым лежат,
// и только потом меряются — иначе альфа молча завышает контраст.

enum Contrast {
    struct RGB: Equatable { var r, g, b: Double }
    struct Token { var light: RGB; var dark: RGB; var alpha: Double; var darkAlpha: Double }

    static func rgb(_ hex: UInt32) -> RGB {
        RGB(r: Double((hex >> 16) & 0xFF), g: Double((hex >> 8) & 0xFF), b: Double(hex & 0xFF))
    }

    static func luminance(_ c: RGB) -> Double {
        func lin(_ v: Double) -> Double { let s = v / 255; return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Альфа-композиция `fg` поверх непрозрачного `bg`.
    static func over(_ fg: RGB, alpha: Double, _ bg: RGB) -> RGB {
        RGB(r: fg.r * alpha + bg.r * (1 - alpha), g: fg.g * alpha + bg.g * (1 - alpha), b: fg.b * alpha + bg.b * (1 - alpha))
    }

    /// Токены палитры из исходника: `public static let имя = Color.dynamic(0x…, 0x…[, alpha: a][, darkAlpha: d])`
    /// и `Color.dynamic(…)` в массиве говорящих — как `speaker1`, `speaker2`, …
    static func parse(_ source: String) -> [String: Token] {
        var out: [String: Token] = [:]
        let re = try! NSRegularExpression(pattern:
            #"(?:static let (\w+) = )?Color\.dynamic\(0x([0-9A-Fa-f]{6}),\s*0x([0-9A-Fa-f]{6})(?:,\s*alpha:\s*([0-9.]+))?(?:,\s*darkAlpha:\s*([0-9.]+))?\)"#)
        var speaker = 1  // первый говорящий — сам акцент
        var inPalette = false
        for line in source.components(separatedBy: "\n") {
            if line.contains("enum Palette") { inPalette = true }
            if line.hasPrefix("// MARK: - Типографика") { inPalette = false }
            guard inPalette else { continue }
            let l = line as NSString
            guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: l.length)) else { continue }
            func group(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : l.substring(with: m.range(at: i)) }
            let name: String
            if let n = group(1) { name = n } else { speaker += 1; name = "speaker\(speaker)" }
            let alpha = Double(group(4) ?? "1") ?? 1
            out[name] = Token(light: rgb(UInt32(group(2)!, radix: 16)!), dark: rgb(UInt32(group(3)!, radix: 16)!),
                              alpha: alpha, darkAlpha: Double(group(5) ?? "") ?? alpha)
        }
        return out
    }
}

func runContrastTests() {
    // Формула на эталонах WCAG: чёрное на белом — 21, серый #777 на белом — 4,48.
    let white = Contrast.rgb(0xFFFFFF), black = Contrast.rgb(0x000000)
    check(abs(Contrast.ratio(black, white) - 21) < 0.01, "чёрное на белом 21:1")
    check(abs(Contrast.ratio(Contrast.rgb(0x777777), white) - 4.48) < 0.01, "#777 на белом 4,48:1")
    // Альфа композится: 10% чёрного на белом почти не темнит фон.
    check(Contrast.ratio(Contrast.over(black, alpha: 0.1, white), white) < 1.3, "композиция альфы")

    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard let source = try? String(contentsOf: root.appendingPathComponent("Sources/MostikUI/DesignSystem.swift"), encoding: .utf8) else {
        check(false, "нет DesignSystem.swift"); return
    }
    let p = Contrast.parse(source)
    for name in ["canvas", "surface", "sunken", "selection", "ink", "inkSecondary", "inkTertiary", "accent", "accentSoft",
                 "onAccent", "record", "recordSoft", "doubt", "doubtSoft", "speaker2", "speaker3", "speaker4"] {
        check(p[name] != nil, "в палитре есть \(name)")
    }
    guard p.count >= 17 else { return }

    var measured = 0
    var worst: (ratio: Double, label: String) = (99, "")
    func expect(_ text: String, on bgs: [String], min: Double, dark: Bool, over base: String = "surface") {
        guard let t = p[text] else { return }
        let fg = dark ? t.dark : t.light
        for bgName in bgs {
            guard let b = p[bgName], let under = p[base] else { continue }
            let baseColor = dark ? under.dark : under.light
            let a = dark ? b.darkAlpha : b.alpha
            let bg = a < 1 ? Contrast.over(dark ? b.dark : b.light, alpha: a, baseColor) : (dark ? b.dark : b.light)
            let r = Contrast.ratio(fg, bg)
            measured += 1
            let label = "\(dark ? "тёмная" : "светлая"): \(text) на \(bgName)\(a < 1 ? " поверх \(base)" : "") — \(String(format: "%.2f", r)):1"
            if r < worst.ratio { worst = (r, label) }
            check(r >= min, "\(label), нужно ≥ \(min)")
        }
    }
    let plain = ["canvas", "surface", "sunken", "selection"]
    let tints = ["accentSoft", "recordSoft", "doubtSoft"]
    for dark in [false, true] {
        // Текст: основной, вторичный, третичный (подсказки — тоже текст, WCAG не делает им скидки).
        for text in ["ink", "inkSecondary", "inkTertiary"] { expect(text, on: plain, min: 4.5, dark: dark) }
        // Цветной текст и подписи: акцент, запись, сомнения, говорящие — на фонах и на своих тинтах.
        for text in ["ink", "inkSecondary", "accent", "record", "doubt", "speaker2", "speaker3", "speaker4"] {
            expect(text, on: plain, min: 4.5, dark: dark)
            for base in ["surface", "canvas"] { expect(text, on: tints, min: 4.5, dark: dark, over: base) }
        }
        // Чип «N под вопросом» на выделенной строке истории: тёмная охра на тинте поверх выделения.
        expect("doubtStrong", on: ["doubtSoft"], min: 4.5, dark: dark, over: "selection")
        expect("doubtStrong", on: plain, min: 4.5, dark: dark)
        // Текст и значок на заливке акцента.
        expect("onAccent", on: ["accent"], min: 4.5, dark: dark)
        // Значки и крупные элементы (точки статуса, волна) — ≥ 3:1.
        for icon in ["accent", "record", "doubt", "inkTertiary"] { expect(icon, on: plain, min: 3, dark: dark) }
    }
    print("Контраст: \(measured) пар, худшая — \(worst.label)")
}
