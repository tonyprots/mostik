import MostikCore
import AppKit
import SwiftUI

// Общие элементы экранов. Все нарисованы на SwiftUI, без AppKit-контролов:
// так снимки совпадают с живым приложением пиксель в пиксель.

// MARK: - Кнопки

struct MostikButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet, destructive }
    var kind: Kind = .secondary
    var compact = false
    /// Крупная кнопка (как `controlSize(.large)`): главное действие шага онбординга.
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind, compact: compact, large: large)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        let kind: Kind
        let compact: Bool
        var large = false
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(large ? Font.system(size: 14, weight: .semibold) : (compact ? TType.callout.weight(.medium) : TType.bodyStrong))
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.horizontal, large ? 20 : (compact ? 10 : 12))
                .frame(minHeight: large ? 34 : (compact ? 24 : DS.controlHeight))
                .background(background, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .overlay {
                    if kind == .secondary {
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .strokeBorder(Palette.edgeStrong, lineWidth: 1)
                    }
                }
                // Зона нажатия не меньше 28 pt даже у компактной кнопки.
                .frame(minHeight: DS.hit)
                .contentShape(Rectangle())
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .opacity(enabled ? 1 : 0.45)
                .animation(Motion.quick, value: configuration.isPressed)
                .onHover { hovering = $0 }
        }

        private var foreground: Color {
            switch kind {
            case .primary: Palette.onAccent
            case .secondary: Palette.ink
            case .quiet: Palette.accent
            case .destructive: Palette.record
            }
        }

        private var background: Color {
            switch kind {
            case .primary: hovering ? Palette.accent.opacity(0.9) : Palette.accent
            case .secondary: hovering ? Palette.sunken : Palette.surface
            case .quiet, .destructive: hovering ? Palette.hover : .clear
            }
        }
    }
}

extension ButtonStyle where Self == MostikButtonStyle {
    static var mostikPrimary: MostikButtonStyle { MostikButtonStyle(kind: .primary) }
    static var mostikSecondary: MostikButtonStyle { MostikButtonStyle(kind: .secondary) }
    static var mostikQuiet: MostikButtonStyle { MostikButtonStyle(kind: .quiet) }
    static func mostik(_ kind: MostikButtonStyle.Kind, compact: Bool = false) -> MostikButtonStyle {
        MostikButtonStyle(kind: kind, compact: compact)
    }
    static func mostik(_ kind: MostikButtonStyle.Kind, large: Bool) -> MostikButtonStyle {
        MostikButtonStyle(kind: kind, large: large)
    }
}

/// Кнопка с выпадашкой: главное действие слева, редкий вариант — по стрелке справа.
/// Обе половины — одна плашка в размерах компактной `MostikButtonStyle`.
struct MostikSplitButton<Items: View>: View {
    let title: String
    var kind: MostikButtonStyle.Kind = .primary
    /// Подсказка и имя для VoiceOver у стрелки.
    let menuHelp: String
    let action: () -> Void
    @ViewBuilder var items: Items
    @Environment(\.mostikSnapshot) private var snapshot

    var body: some View {
        HStack(spacing: 0) {
            Button(title, action: action)
                .buttonStyle(Half(foreground: foreground))
            Rectangle().fill(divider).frame(width: 1, height: 14)
            Group {
                if snapshot {
                    chevron
                } else {
                    // `.borderlessButton` рисует метку через AppKit и теряет цвет —
                    // на зелёной плашке стрелка пропадала. Так метка остаётся SwiftUI.
                    Menu { items } label: { chevron }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                }
            }
            .frame(width: 26, height: 24)
            .contentShape(Rectangle())
            .help(menuHelp)
            .accessibilityLabel(menuHelp)
        }
        .frame(minHeight: 24)
        .background(background, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .overlay {
            if kind == .secondary {
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .strokeBorder(Palette.edgeStrong, lineWidth: 1)
            }
        }
        // Зона нажатия не меньше 28 pt, плашка — 24, как у компактной кнопки.
        .frame(minHeight: DS.hit)
        .contentShape(Rectangle())
        .fixedSize()
    }

    private var chevron: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(foreground)
            .frame(width: 26, height: 24)
    }

    private var foreground: Color { kind == .primary ? Palette.onAccent : Palette.ink }
    private var background: Color { kind == .primary ? Palette.accent : Palette.surface }
    private var divider: Color { kind == .primary ? Palette.onAccent.opacity(0.35) : Palette.edgeStrong }

    /// Левая половина: текст компактной кнопки, без своей плашки.
    private struct Half: ButtonStyle {
        let foreground: Color
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(TType.callout.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.leading, 10).padding(.trailing, 8)
                .frame(minHeight: 24)
                .contentShape(Rectangle())
                .opacity(configuration.isPressed ? 0.7 : 1)
        }
    }
}

/// Строка, на которую можно нажать: подсветка наведения тоном, без подъёма.
struct RowButtonStyle: ButtonStyle {
    var selected = false
    var radius: CGFloat = DS.Radius.row

    func makeBody(configuration: Configuration) -> some View {
        Inner(configuration: configuration, selected: selected, radius: radius)
    }

    private struct Inner: View {
        let configuration: Configuration
        let selected: Bool
        let radius: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(selected ? Palette.selection : (hovering || configuration.isPressed ? Palette.hover : .clear))
                )
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Переключатель

/// Тумблер в пропорциях macOS: дорожка 32×18, ручка 14.
struct MostikToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: DS.Space.s) {
                configuration.label
                Spacer(minLength: DS.Space.s)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule(style: .continuous)
                        .fill(configuration.isOn ? Palette.accent : Palette.edgeStrong)
                        .frame(width: 32, height: 18)
                    Circle()
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.18), radius: 0.5, y: 0.5)
                        .frame(width: 14, height: 14)
                        .padding(2)
                }
                .animation(Motion.spring, value: configuration.isOn)
            }
            .frame(minHeight: DS.hit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // VoiceOver видит настоящий переключатель с состоянием, а не безымянную кнопку.
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// Галочка: квадрат 16 с радиусом 4, подпись справа. Свой рисунок, а не `.checkbox`: тот — NSButton,
/// и снимки экранов рисуют вместо него заглушку.
struct MostikCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: DS.Space.xs) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(configuration.isOn ? Palette.accent : Palette.surface)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(configuration.isOn ? Palette.accent : Palette.edgeStrong)
                    if configuration.isOn {
                        // Галочка линией, а не символом: подпись у переключателя — `configuration.label`.
                        Path { p in
                            p.move(to: CGPoint(x: 4, y: 8.5)); p.addLine(to: CGPoint(x: 7, y: 11.5)); p.addLine(to: CGPoint(x: 12, y: 5))
                        }
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                }
                .frame(width: 16, height: 16)
                configuration.label
            }
            .frame(minHeight: DS.hit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

// MARK: - Сегменты

/// Сегментированный выбор. Внешний радиус 8 = внутренний 6 + отступ 2.
struct Segmented<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var fill = false
    @Namespace private var indicator
    /// Один фокус на весь переключатель, стрелки ←→ меняют выбор. Раньше фокус был у каждой кнопки:
    /// при «Навигации с клавиатуры» рамка вставала на первый сегмент и не уходила при щелчке по другому.
    @FocusState private var focused: Bool
    /// Рамка — только при фокусе с клавиатуры (Tab, стрелки), как `:focus-visible`: фокус от открытия
    /// окна или щелчка мышью рамку не рисует, иначе она «иногда» вспыхивала синим без причины.
    @State private var keyboardFocus = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                let (value, title) = options[i]
                let on = value == selection
                // Шаг 3, п. 14: содержимое (вкладка) меняется сразу, едет только подложка.
                Button { selection = value } label: {
                    Text(title)
                        .font(TType.callout.weight(on ? .semibold : .regular))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(on ? Palette.ink : Palette.inkSecondary)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: fill ? .infinity : nil, minHeight: 24)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                                    .fill(Palette.surface)
                                    // Узкая направленная тень: сегмент лежит на дорожке.
                                    .shadow(color: .black.opacity(0.10), radius: 1, y: 1)
                                    // Фокус с клавиатуры — на выбранном сегменте: рамка идёт за выбором.
                                    .overlay {
                                        if focused && keyboardFocus {
                                            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                                                .strokeBorder(Color.accentColor, lineWidth: 2)
                                        }
                                    }
                                    .matchedGeometryEffect(id: "indicator", in: indicator)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .animation(Motion.tabIndicator, value: selection)
        .padding(2)
        .background(Palette.sunken, in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).strokeBorder(Palette.edge))
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onChange(of: focused) { _, now in
            keyboardFocus = now && NSApp.currentEvent?.type == .keyDown
        }
        .onMoveCommand { direction in
            keyboardFocus = true
            guard let index = options.firstIndex(where: { $0.0 == selection }) else { return }
            switch direction {
            case .left where index > 0: selection = options[index - 1].0
            case .right where index < options.count - 1: selection = options[index + 1].0
            default: break
            }
        }
    }
}

// MARK: - Степпер

struct StepperField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    var label: (Int) -> String

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", enabled: value > range.lowerBound) { value = max(range.lowerBound, value - step) }
            Text(label(value))
                .font(TType.figure(12))
                .foregroundStyle(Palette.ink)
                .frame(minWidth: 64)
                .contentTransition(.numericText())
            stepButton("plus", enabled: value < range.upperBound) { value = min(range.upperBound, value + step) }
        }
        .padding(2)
        .background(Palette.sunken, in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).strokeBorder(Palette.edge))
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button { withAnimation(Motion.quick) { action() } } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(enabled ? Palette.ink : Palette.inkTertiary)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle(radius: DS.Radius.control))
        .disabled(!enabled)
        .accessibilityLabel(symbol == "minus" ? L("Меньше", "Decrease") : L("Больше", "Increase"))
        .accessibilityValue(label(value))
    }
}

// MARK: - Поле ввода

/// Однострочное поле. В снимке — текст вместо NSTextField.
struct MostikTextField: View {
    let placeholder: String
    @Binding var text: String
    var leadingSymbol: String? = nil
    var monospaced = false
    @Environment(\.mostikSnapshot) private var snapshot

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            if let leadingSymbol {
                Image(systemName: leadingSymbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.inkTertiary)
            }
            Group {
                if snapshot {
                    Text(text.isEmpty ? placeholder : text)
                        .foregroundStyle(text.isEmpty ? Palette.inkTertiary : Palette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField(placeholder, text: $text)
                        .textFieldStyle(.plain)
                        .foregroundStyle(Palette.ink)
                }
            }
            // Подсказка — обычным шрифтом, моноширинный только у введённого кода.
            .font(monospaced && !text.isEmpty ? TType.code : TType.body)
            .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: DS.controlHeight)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(Palette.edgeStrong))
    }
}

// MARK: - Прокрутка

/// Прокрутка в приложении, обычный стек в снимке — `ImageRenderer` не рисует ScrollView.
struct MostikScroll<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.mostikSnapshot) private var snapshot

    var body: some View {
        if snapshot {
            // Наложение не влияет на раскладку: длинный список обрезается
            // по низу, а не выталкивает шапку окна вверх.
            Color.clear
                .overlay(alignment: .top) { VStack(spacing: 0) { content } }
                .clipped()
        } else {
            ScrollView { content }.scrollIndicators(.automatic)
        }
    }
}

extension View {
    /// Выделение текста только в живом окне: в снимке оно не нужно.
    @ViewBuilder func selectableText(_ on: Bool) -> some View {
        if on { self.textSelection(.enabled) } else { self }
    }
}

// MARK: - Карточки и заголовки

struct Card<Content: View>: View {
    var padding: CGFloat = DS.Space.m
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(Palette.edge))
    }
}

/// Заголовок группы: обычный регистр, полужирный, вторичный цвет.
struct GroupLabel: View {
    let text: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(TType.calloutStrong).foregroundStyle(Palette.inkSecondary)
            Spacer()
            if let trailing {
                Text(trailing).font(TType.figure(11, .regular)).foregroundStyle(Palette.inkTertiary)
            }
        }
    }
}

/// Тонкий разделитель со скруглёнными концами, с отступом от краёв.
struct Hairline: View {
    var inset: CGFloat = 0
    var body: some View {
        Capsule().fill(Palette.edge).frame(height: 1).padding(.horizontal, inset)
    }
}

/// Точка статуса. С `label` VoiceOver читает её смысл; без него точка декоративная
/// (смысл уже в тексте рядом) и скрыта от VoiceOver.
struct StatusDot: View {
    var color: Color
    var size: CGFloat = 6
    var label: String? = nil
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .accessibilityHidden(label == nil)
            .accessibilityLabel(label ?? "")
    }
}

/// Слово под вопросом: модель расслышала его неуверенно.
struct DoubtChip: View {
    let text: String
    /// Тон подписи; `doubtStrong` — там, где чип лежит на выделенной строке.
    var tone: Color = Palette.doubt
    var body: some View {
        Text(text)
            .font(TType.caption)
            .foregroundStyle(tone)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(Palette.doubtSoft, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .accessibilityLabel(L("Слово под вопросом: ", "Unsure word: ") + text)
    }
}

// MARK: - Раскладка «облаком»

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += lineHeight + lineSpacing
                x = 0; lineHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX; lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Клавиша

/// Клавиша клавиатуры: подсказка про горячую клавишу.
struct KeyCap: View {
    let symbol: String
    var caption: String? = nil
    var size: CGFloat = 56
    var pressed = false

    var body: some View {
        VStack(spacing: 2) {
            Text(symbol)
                .font(.system(size: size * 0.36, weight: .regular))
            if let caption {
                Text(caption).font(.system(size: max(12, size * 0.18), weight: .medium))  // мельче 12 pt не читается
            }
        }
        .foregroundStyle(Palette.ink)
        .frame(width: size * 1.3, height: size)
        .background(
            RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                .fill(pressed ? Palette.selection : Palette.surface)
        )
        // Нижняя «губа» клавиши — тон, а не тень по кругу.
        .background(
            RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                .fill(Palette.edgeStrong)
                .offset(y: pressed ? 1 : 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                .strokeBorder(Palette.edgeStrong, lineWidth: 1)
        )
        .offset(y: pressed ? 2 : 0)
    }
}

// MARK: - Волна уровня

/// Живая волна уровня: столбики со скруглёнными концами, высота от сигнала.
struct LevelWave: View {
    var levels: [Float]
    var color: Color
    var barWidth: CGFloat = 2.5
    var spacing: CGFloat = 2
    var height: CGFloat = 20
    /// 0…1 — позиция бегущей подсветки при расшифровке; nil — живой сигнал.
    var shimmer: Double? = nil

    /// Шаг 3, п. 12: один `Canvas` без неявной анимации — 20 кадров в секунду не тянут
    /// пересчёт раскладки столбиков. Сглаживание — в данных (`LevelSmoothing`): рост сразу, спад ~120 мс.
    var body: some View {
        let n = levels.count
        let width = CGFloat(n) * barWidth + CGFloat(max(n - 1, 0)) * spacing
        Canvas { context, size in
            for i in 0..<n {
                let level = CGFloat(min(max(levels[i], 0), 1))
                let h = max(barWidth, 3 + level * (height - 3))
                let rect = CGRect(x: CGFloat(i) * (barWidth + spacing), y: (size.height - h) / 2, width: barWidth, height: h)
                let bar = Path(roundedRect: rect, cornerRadius: min(barWidth, h) / 2, style: .continuous)
                context.fill(bar, with: .color(color.opacity(opacity(for: i))))
            }
        }
        .frame(width: width, height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shimmer == nil ? L("Уровень звука", "Audio level") : L("Идёт расшифровка", "Transcribing"))
        .accessibilityValue(shimmer == nil ? "\(Int((levels.max() ?? 0) * 100))%" : "")
    }

    private func opacity(for i: Int) -> Double {
        guard let shimmer else { return 1 }
        let pos = Double(i) / Double(max(levels.count - 1, 1))
        let d = pos - shimmer
        return 0.28 + 0.72 * exp(-(d * d) / 0.012)
    }
}

// MARK: - Знак Mostik

/// Знак: четыре столбика речи переходят в текстовый курсор.
/// Речь становится текстом — вся идея приложения в одном глифе.
public struct MostikGlyph: View, Animatable {
    var bars: Color
    var caret: Color
    /// 0…1 — однократное «оживание» (решение автора): столбики по очереди
    /// вздыхают, как голос, и встают на место. 1 — обычный знак.
    var life: CGFloat = 1

    public init(bars: Color = .primary, caret: Color? = nil, life: CGFloat = 1) {
        self.bars = bars
        self.caret = caret ?? bars
        self.life = life
    }

    public var animatableData: CGFloat {
        get { life }
        set { life = newValue }
    }

    /// Множитель высоты столбика `i` в момент `life`: подъём до ×1,5 и возврат, с задержкой по порядку.
    static func swell(_ i: Int, life: CGFloat) -> CGFloat {
        let local = min(max((life * 1.6 - CGFloat(i) * 0.2), 0), 1)
        return 1 + 0.5 * sin(.pi * local)
    }

    public var body: some View {
        Canvas { ctx, size in
            let u = min(size.width, size.height) / 100
            let ox = (size.width - 100 * u) / 2, oy = (size.height - 100 * u) / 2
            func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
                CGRect(x: ox + x * u, y: oy + y * u, width: w * u, height: h * u)
            }
            // Столбики шириной 10 с шагом 17: левые края 3.5…54.5.
            // Вся фигура занимает 3.5…96.5 — центр ровно на 50.
            let heights: [CGFloat] = [28, 60, 42, 20]
            for (i, h) in heights.enumerated() {
                let h = min(96, h * Self.swell(i, life: life))
                let r = rect(3.5 + CGFloat(i) * 17, 50 - h / 2, 10, h)
                ctx.fill(Path(roundedRect: r, cornerRadius: 5 * u), with: .color(bars))
            }
            // Курсор-«балка» I: стойка и две перекладины, правый край 96.5.
            let cx: CGFloat = 85.5
            ctx.fill(Path(roundedRect: rect(cx - 4, 14, 8, 72), cornerRadius: 4 * u), with: .color(caret))
            ctx.fill(Path(roundedRect: rect(cx - 11, 11, 22, 7), cornerRadius: 3.5 * u), with: .color(caret))
            ctx.fill(Path(roundedRect: rect(cx - 11, 82, 22, 7), cornerRadius: 3.5 * u), with: .color(caret))
        }
    }
}

/// Знак, который оживает один раз при появлении; при «Уменьшить движение» и в снимках — статичен.
struct LivelyMostikGlyph: View {
    var bars: Color
    var caret: Color
    @Environment(\.mostikSnapshot) private var snapshot
    @State private var life: CGFloat = 1
    @State private var played = false

    var body: some View {
        MostikGlyph(bars: bars, caret: caret, life: life)
            .onAppear {
                guard !snapshot, MotionSpec.glyphAnimates(reduceMotion: Motion.reduced, alreadyPlayed: played) else { return }
                played = true
                life = 0
                withAnimation(.easeInOut(duration: 0.7)) { life = 1 }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Доступность

extension View {
    /// Кнопка-значок без текста: подсказка при наведении и та же подпись для VoiceOver.
    /// `.help` сам по себе подписью не служит — VoiceOver прочёл бы имя символа.
    func iconHelp(_ text: String) -> some View {
        help(text).accessibilityLabel(text)
    }
}
