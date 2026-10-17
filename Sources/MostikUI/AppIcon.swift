import SwiftUI

/// Иконка приложения по сетке macOS: холст 1024, «сквиркл» 824 с полями 100,
/// радиус ~185 (непрерывное скругление). Глиф — речь, переходящая в курсор.
/// Фон — глубокий чернильный тил одного тона: сверху на ступень светлее,
/// как от верхнего света, без второго оттенка и без свечения.
public struct AppIconView: View {
    public init() {}

    public var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 1024
            ZStack {
                let shape = RoundedRectangle(cornerRadius: 185 * s, style: .continuous)
                shape
                    .fill(LinearGradient(colors: [Color(hex: 0x24514A), Color(hex: 0x173832)],
                                         startPoint: .top, endPoint: .bottom))
                    // Узкая направленная тень вниз, как в шаблоне Apple.
                    .shadow(color: .black.opacity(0.28), radius: 10 * s, y: 8 * s)
                // Светлая «губа» по верхнему краю — собственный цвет поверхности.
                shape
                    .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.0)],
                                                 startPoint: .top, endPoint: .center),
                                  lineWidth: 3 * s)
                MostikGlyph(bars: Color(hex: 0xEEF3F0), caret: Color(hex: 0x9FDCCB))
                    .frame(width: 500 * s, height: 500 * s)
            }
            .frame(width: 824 * s, height: 824 * s)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}
