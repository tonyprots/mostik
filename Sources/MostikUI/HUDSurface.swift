import AppKit
import SwiftUI

// Поверхность плавающих панелей (П9-B): плашка диктовки и мини-панель встречи.
// В приложении — системный материал `.hudWindow` через `NSVisualEffectView`,
// направленная тень сверху вниз и обводка 0,5 pt цветом разделителя.
// В снимке `ImageRenderer` AppKit-вид не рисует: материал имитирован полупрозрачной
// поверхностью над подложкой — без размытия, это честно видно на светлой подложке.

/// Системный материал за окном, вырезанный по форме с концентрическим радиусом.
struct HUDMaterial: NSViewRepresentable {
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        view.maskImage = Self.mask(radius: cornerRadius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.maskImage = Self.mask(radius: cornerRadius)
    }

    /// Растягиваемая маска со скруглением: углы фиксированы, середина тянется.
    static func mask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Фон плавающей панели: материал, тень только снаружи формы, обводка 0,5 pt.
struct HUDSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let cornerRadius: CGFloat
    @Environment(\.mostikSnapshot) private var snapshot
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background {
                if snapshot {
                    // Имитация `.hudWindow`: светлая или тёмная вуаль на 78 % — подложка проступает,
                    // как у системного материала; размытия нет, поэтому подложка снимка — плавный градиент.
                    shape.fill(Color.dynamic(0xF6F7F6, 0x2A2D2C).opacity(0.78))
                } else {
                    HUDMaterial(cornerRadius: cornerRadius)
                }
            }
            .clipShape(shape)
            .background {
                // Тень отбрасывает непрозрачная копия формы, а внутренность вырезана:
                // под полупрозрачным материалом не проступает серое пятно.
                shape.fill(Color.black)
                    .shadow(color: .black.opacity(scheme == .dark ? 0.36 : 0.18), radius: 12, y: 8)
                    .mask {
                        ZStack {
                            Rectangle().padding(-48)
                            shape.blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    }
                    .allowsHitTesting(false)
            }
            // Один акцент во всём приложении: системные контролы внутри панели — тил, а не синий.
            .tint(Palette.accent)
            .overlay {
                // Обводка цветом системного разделителя: в тёмной теме светлый край, в светлой — тёмный.
                shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
    }
}

extension View {
    /// Плавающая панель в материале `.hudWindow` с тенью и обводкой 0,5 pt.
    func hudSurface<S: InsettableShape>(_ shape: S, cornerRadius: CGFloat) -> some View {
        modifier(HUDSurface(shape: shape, cornerRadius: cornerRadius))
    }
}
