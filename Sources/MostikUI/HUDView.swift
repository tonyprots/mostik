import SwiftUI
import MostikCore

/// HUD-пилюля диктовки: 400×44 снизу по центру экрана, в материале `.hudWindow`.
/// Запись → расшифровка → итог; состояния сменяются пружиной без отскока.
public struct HUDView: View {
    @ObservedObject var model: AppModel
    @Environment(\.mostikSnapshot) private var snapshot

    /// Размер самой пилюли; панель вокруг шире — под тень.
    public static let size = CGSize(width: 400, height: 44)

    public init(model: AppModel) { self.model = model }

    /// Что рисовать: при скрытии — последняя видимая фаза, пока окно гаснет прозрачностью
    /// (шаг 3, п. 13), а не пустая капсула.
    @State private var lastShown: AppModel.HUDPhase = .hidden
    /// Перетаскивание плашки (решение автора): идёт сейчас и когда кончилось — щелчок,
    /// которым плашку отпустили, не открывает историю.
    @State private var dragging = false
    @State private var dragEndedAt = Date.distantPast
    private var shown: AppModel.HUDPhase { model.hud == .hidden ? lastShown : model.hud }

    public var body: some View {
        ZStack {
            // Голосовая правка (D5) занимает ту же пилюлю: фаза HUD общая, содержимое своё.
            if model.voiceEdit.isShowing, shown != .hidden {
                VoiceEditPill(model: model, edit: model.voiceEdit).transition(.phase)
            } else {
            switch shown {
            case .hidden:
                Color.clear
            case .recording:
                recording.transition(.phase)
            case .transcribing:
                transcribing.transition(.phase)
            case let .done(summary, doubts, agent, spelling):
                done(summary: summary, doubts: doubts, agent: agent, spelling: spelling).transition(.phase)
            case let .error(message):
                error(message).transition(.phase)
            case let .notice(title, detail):
                notice(title: title, detail: detail).transition(.phase)
            }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        // Фон всегда: показ и скрытие — прозрачностью окна (WindowManager), фон не мигает.
        .modifier(PillChrome(visible: shown != .hidden))
        .animation(Motion.phase, value: shown)
        .onChange(of: model.hud, initial: true) { _, phase in
            if phase != .hidden { lastShown = phase }
        }
        // Плашку можно перетащить мышью; окно двигает WindowManager по положению курсора на экране,
        // панель не активируется — фокус остаётся в поле, куда идёт вставка. Щелчок без сдвига — как раньше.
        .simultaneousGesture(
            DragGesture(minimumDistance: 3)
                .onChanged { _ in
                    dragging = true
                    model.onHUDDrag(.changed)
                }
                .onEnded { _ in
                    dragging = false
                    dragEndedAt = Date()
                    model.onHUDDrag(.ended)
                }
        )
        // VoiceOver читает пилюлю одной фразой: «Идёт запись, уровень звука, 0:42, Стоп — правый Option…, RU».
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: Состояния

    /// Точка · волна до таймера · таймер · через 2 с «Отпустите правый ⌥ · Отмена esc» капсулами · язык с шевроном.
    private var recording: some View {
        HStack(spacing: 0) {
            RecordingDot(paused: model.dictationPaused, toggle: model.onToggleDictationPause)
                .padding(.trailing, 6)
            MeterReader(model.meter) { levels in StretchWave(levels: Array(levels.suffix(24))) }
                .padding(.trailing, DS.Space.s)
            ClockReader(model.clock) { clock in
                HStack(spacing: 0) {
                    Text(Fmt.clock(clock.elapsed))
                        .font(TType.figure(13))
                        .monospacedDigit()
                        .foregroundStyle(Palette.ink)
                        .fixedSize()
                    if model.dictationPaused {
                        Text(L("Пауза", "Paused"))
                            .font(TType.callout)
                            .foregroundStyle(Palette.inkSecondary)
                            .padding(.leading, DS.Space.s)
                            .transition(.opacity)
                    } else if let trouble = model.micTrouble {
                        Text(trouble)
                            .font(TType.callout)
                            .foregroundStyle(Palette.inkSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.leading, DS.Space.s)
                            .transition(.opacity)
                    } else if let items = HUDHint.items(holdKey: model.settings.holdKey, elapsed: clock.elapsed,
                                                        handsFree: model.recordingHandsFree) {
                        HUDControls(items: items)
                            .padding(.leading, DS.Space.s)
                            .transition(.opacity)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(HUDHint.spoken(holdKey: model.settings.holdKey, handsFree: model.recordingHandsFree))
                    }
                }
                .animation(Motion.spring, value: clock.elapsed >= HUDHint.delay)
            }
            languageChip
                .padding(.leading, 6)
        }
        .padding(.leading, 18)
        .padding(.trailing, 16)
    }

    /// Микрофон уже выключен: вместо волны — индикатор обработки, без подписи «микрофон выключен» (R3b).
    @ViewBuilder private var transcribing: some View {
        if let share = model.verifyProgress { verifying(share) } else { transcribingPlain }
    }

    /// Длинная диктовка: вторая модель сверяет текст — полоса и выход «Вставить сразу» без сверки.
    private func verifying(_ share: Double) -> some View {
        HStack(spacing: 0) {
            Text(L("Сверяю", "Checking"))
                .font(TType.bodyStrong)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(Palette.inkSecondary)
                .padding(.trailing, DS.Space.s)
            CreepingProgress(share: share).frame(width: 72)
            Spacer(minLength: DS.Space.s)
            Button(L("Вставить сразу", "Insert now")) { model.onInsertFast() }
                .buttonStyle(.mostik(.secondary, compact: true))
                .help(L("Вставить текст первой модели, не дожидаясь сверки второй",
                        "Insert the first model’s text without waiting for the second check"))
        }
        .padding(.leading, 18)
        .padding(.trailing, 6)
    }

    private var transcribingPlain: some View {
        HStack(spacing: 0) {
            WorkingArc()
                .frame(width: 14, height: 14)
                .padding(.trailing, 10)
            Text(L("Расшифровка…", "Transcribing…"))
                .font(TType.bodyStrong)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(Palette.inkSecondary)
            Spacer(minLength: DS.Space.s)
            languageLabel
        }
        .padding(.leading, 18)
        .padding(.trailing, 16)
    }

    /// Итог. С сомнениями — ссылка в историю: «Вставлено · 2 слова под вопросом ›».
    /// Без сомнений, но с правкой словаря — «Вставлено · поправить слово ›»: та же плашка, а не карточка над ней.
    @ViewBuilder private func done(summary: String, doubts: Int, agent: Bool, spelling: String?) -> some View {
        let fix = doubts == 0 ? spelling : nil
        let row = HStack(spacing: 10) {
            MostikGlyph(bars: Palette.inkTertiary, caret: Palette.accent)
                .frame(width: 18, height: 18)
            Group {
                Text(summary).foregroundStyle(Palette.ink)
                    + Text(doubtTail(doubts)).foregroundStyle(Palette.doubtStrong)
                    + Text(fix == nil ? "" : L(" · поправить слово", " · fix a word")).foregroundStyle(Palette.accent)
            }
            .font(TType.bodyStrong)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            if doubts > 0 || fix != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.inkSecondary)
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        if doubts > 0 {
            Button {
                // Плашку только что перетаскивали — это не щелчок по ней.
                guard !dragging, Date().timeIntervalSince(dragEndedAt) > 0.3 else { return }
                model.selectedTab = .dictation
                model.onOpenMainWindow()
            } label: { row }
            .buttonStyle(.plain)
            // Слова под вопросом решаются в истории (C4): принять или отклонить, агенту они не уходят.
            .help(L("Открыть запись в истории и проверить слова", "Open this dictation in History to check the words"))
            .accessibilityHint(L("Слова под вопросом можно принять или отклонить", "You can accept or dismiss the unsure words"))
        } else if let fix {
            Button {
                guard !dragging, Date().timeIntervalSince(dragEndedAt) > 0.3 else { return }
                model.glossaryLearning.onOpenSpelling(fix)
            } label: { row }
            .buttonStyle(.plain)
            .help(L("Открыть запись и запомнить, как пишется слово", "Open this dictation and remember how a word is spelled"))
            .accessibilityHint(L("Открывает запись, чтобы запомнить написание", "Opens the dictation to remember a spelling"))
        } else {
            row
        }
    }

    private func error(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.record)
            Text(message)
                .font(TType.bodyStrong)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
    }

    /// Карточка доставки в той же пилюле: что случилось и где теперь текст.
    private func notice(title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.doubt)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(TType.bodyStrong)
                    .foregroundStyle(Palette.ink)
                Text(detail)
                    .font(TType.caption)
                    .foregroundStyle(Palette.inkSecondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
    }

    // MARK: Части

    /// Язык при расшифровке — подпись: менять его уже поздно.
    private var languageLabel: some View {
        Text(model.settings.language.uppercased())
            .font(TType.captionStrong)
            .foregroundStyle(Palette.inkSecondary)
            .fixedSize()
            .accessibilityLabel(L("Язык: ", "Language: ") + model.settings.language.uppercased())
    }

    /// Язык во время записи — кнопка-меню с шевроном (R3b): «RU ⌄» читается как выбор, а не как ярлык.
    /// Панель не активирует приложение, поэтому меню открывается без кражи фокуса у поля ввода.
    /// В снимке `ImageRenderer` меню AppKit не рисует — там тот же ярлык.
    @ViewBuilder private var languageChip: some View {
        let chip = HStack(spacing: 3) {
            Text(model.settings.language.uppercased())
                .font(TType.captionStrong)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
        }
        .foregroundStyle(Palette.inkSecondary)
        .padding(.horizontal, 6)
        .frame(height: 22)
        .background(Capsule(style: .continuous).strokeBorder(Palette.edgeStrong, lineWidth: 1))
        .frame(minWidth: 40, minHeight: 40)
        .contentShape(Rectangle())
        .fixedSize()
        if snapshot {
            chip.accessibilityLabel(L("Язык: ", "Language: ") + model.settings.language.uppercased())
        } else {
            Menu {
                ForEach([("ru", "Русский"), ("en", "English")], id: \.0) { code, name in
                    Button {
                        var s = model.settings
                        s.language = code
                        model.onUpdateSettings(s)
                    } label: {
                        if model.settings.language == code { Label(name, systemImage: "checkmark") } else { Text(name) }
                    }
                }
            } label: { chip }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("Язык диктовки", "Dictation language"))
            .accessibilityLabel(L("Язык диктовки: ", "Dictation language: ") + model.settings.language.uppercased())
        }
    }

    /// Видимая строка короткая: «· 2 слова под вопросом». Что спросит агент — в подсказке и для VoiceOver,
    /// иначе русская строка не помещается в 400 pt.
    private func doubtTail(_ doubts: Int) -> String {
        guard doubts > 0 else { return "" }
        let words = L10n.plural(doubts, ru: "слово под вопросом", "слова под вопросом", "слов под вопросом",
                                en: "word in question", "words in question")
        return " · " + words
    }
}

/// «Отпустите правый ⌥ · Отмена esc» (R3b): действие словом, клавиша — капсулой SF 11 semibold
/// на `quaternarySystemFill`, буква цветом ink. Клавиша стопа — из Настроек.
private struct HUDControls: View {
    let items: [HUDHint.Control]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Text("·").foregroundStyle(Palette.inkTertiary).padding(.horizontal, 1)
                }
                Text(item.action).foregroundStyle(Palette.inkSecondary)
                KeyCapsule(key: item.key)
            }
        }
        .font(TType.caption)
        .lineLimit(1)
        .fixedSize()
    }
}

/// Клавиша капсулой: 11 pt semibold, высота 16, заливка системной четвертичной.
private struct KeyCapsule: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 16)
            .background(Capsule(style: .continuous).fill(Color(nsColor: .quaternarySystemFill)))
    }
}

/// Пилюля в материале — только когда HUD видим.
private struct PillChrome: ViewModifier {
    let visible: Bool

    func body(content: Content) -> some View {
        if visible {
            content.hudSurface(Capsule(style: .continuous), cornerRadius: HUDView.size.height / 2)
        } else {
            content
        }
    }
}

/// Волна во всю ширину до таймера: шаг столбиков растягивается, дыры перед таймером нет.
private struct StretchWave: View {
    let levels: [Float]
    private let bar: CGFloat = 2.5

    var body: some View {
        GeometryReader { geo in
            // Сколько столбиков влезает с минимальным шагом 1,5 pt: волна не наезжает на таймер.
            let fit = max(2, Int((geo.size.width + 1.5) / (bar + 1.5)))
            let shown = Array(levels.suffix(fit))
            let n = CGFloat(max(shown.count, 2))
            let spacing = max(1.5, (geo.size.width - n * bar) / (n - 1))
            LevelWave(levels: shown, color: Palette.ink, barWidth: bar, spacing: spacing, height: 22)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
        }
        .frame(height: 22)
    }
}

/// Полоса сверки: ползёт сама между редкими долями движка и добегает до конца по готовности
/// (`ProgressCreep`). В снимке — настоящая доля.
private struct CreepingProgress: View {
    let share: Double
    @Environment(\.mostikSnapshot) private var snapshot
    @State private var start = Date()

    var body: some View {
        if snapshot {
            ProgressBar(value: share)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                ProgressBar(value: ProgressCreep.shown(share: share, elapsed: context.date.timeIntervalSince(start)))
            }
            .accessibilityValue(Text(verbatim: "\(Int((share * 100).rounded())) %"))
        }
    }
}

/// Индикатор обработки: дуга, которая вращается; в снимке неподвижна.
private struct WorkingArc: View {
    @Environment(\.mostikSnapshot) private var snapshot

    var body: some View {
        if snapshot {
            arc(0)
        } else {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                arc(t.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360)
            }
        }
    }

    private func arc(_ degrees: Double) -> some View {
        ZStack {
            Circle().stroke(Palette.edgeStrong, lineWidth: 2)
            Circle().trim(from: 0, to: 0.28)
                .stroke(Palette.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(degrees - 90))
        }
        .accessibilityLabel(L("Идёт расшифровка", "Transcribing"))
    }
}

/// Точка записи с мягким дыханием — неподвижна в снимке.
/// Точка записи — она же пауза: при наведении становится «пауза», на паузе — «продолжить».
private struct RecordingDot: View {
    let paused: Bool
    let toggle: () -> Void
    @Environment(\.mostikSnapshot) private var snapshot
    @State private var dim = false
    @State private var hover = false

    var body: some View {
        Button(action: toggle) {
            glyph
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(paused ? L("Продолжить запись", "Resume recording") : L("Пауза", "Pause"))
        .accessibilityLabel(paused ? L("На паузе, продолжить", "Paused, resume") : L("Идёт запись, пауза", "Recording, pause"))
        .onHover { inside in withAnimation(Motion.quick) { hover = inside } }
        .onAppear {
            guard !snapshot, MotionSpec.recordingDotPulses(reduceMotion: Motion.reduced) else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
        }
    }

    /// Красная точка; при наведении — пауза, на паузе — «продолжить».
    private var glyph: some View {
        ZStack {
            if paused || hover {
                Image(systemName: paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(paused ? Palette.inkSecondary : Palette.record)
                    .transition(.opacity)
            } else {
                Circle()
                    .fill(Palette.record)
                    .frame(width: 8, height: 8)
                    .opacity(dim ? 0.45 : 1)
                    .transition(.opacity)
            }
        }
    }
}

private extension AnyTransition {
    /// Смена содержимого пилюли: лёгкий сдвиг и затухание, выход мягче входа.
    static var phase: AnyTransition {
        if MotionSpec.transition(reduceMotion: Motion.reduced) == .fade { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 6)).combined(with: .scale(scale: 0.98)),
            removal: .opacity.combined(with: .offset(y: -4))
        )
    }
}
