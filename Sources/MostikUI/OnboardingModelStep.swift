import SwiftUI
import MostikCore

/// Шаг онбординга «Модель» (решение автора): одна модель на диктовку и встречи,
/// а под «Настроить отдельно» — своя для каждого. Gemma при установке не ставится, поэтому
/// здесь её можно скачать: загрузка идёт, пока человек пробует диктовку на следующем шаге.
/// Согласия ставятся только тем выбором, под которым прямо сказано, куда уходит текст.
struct OnboardingModelStep: View {
    @ObservedObject var model: AppModel
    @ObservedObject var models: ModelsModel
    @State private var split: Bool

    init(model: AppModel) {
        self.model = model
        models = model.models
        _split = State(initialValue: OnboardingModelChoice(model.settings) == .custom)
    }

    private var choice: OnboardingModelChoice { OnboardingModelChoice(model.settings) }
    private var llm: ModelRow? { models.rows.first { $0.purpose == "llm" } }

    var body: some View {
        VStack(spacing: split ? DS.Space.s : DS.Space.m) {
            VStack(spacing: DS.Space.xs) {
                Text(L("Модель — по желанию", "A model — optional"))
                    .font(.system(size: 28, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Text(L("Делает сводки и названия встреч и причёсывает диктовку. Без неё текст вставляется как сказано.",
                       "Writes meeting summaries and titles and polishes dictation. Without one, text goes in as spoken."))
                    .font(TType.body)
                    .foregroundStyle(Palette.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                option(.local, title: L("На этом Mac", "On this Mac") + (llm.map { " · " + ModelCatalog.size($0.size, russian: L10n.isRussian) } ?? ""),
                       hint: L("Ничего не уходит в сеть. Скачается, пока вы пробуете диктовку.",
                               "Nothing leaves this Mac. Downloads while you try a dictation."))
                Hairline()
                option(.claude, title: L("Claude по подписке", "Claude on your subscription"),
                       hint: L("Текст диктовок и расшифровки встреч с чужими словами уходят в Anthropic. Звук — никогда.",
                               "Dictated text and meeting transcripts, with other people’s words, go to Anthropic. Never audio.")
                           + (model.polishAvailable["claude"] == false
                              ? L(" Claude Code на этом Mac не найден: установите его (claude.ai/install.sh), войдите и перезапустите Mostik.",
                                  " Claude Code isn’t on this Mac: install it (claude.ai/install.sh), sign in and relaunch Mostik.") : ""))
                Hairline()
                option(.none, title: L("Пока без модели", "No model for now"),
                       hint: L("Выбрать можно позже в Настройках.", "You can pick one later in Settings."))
            }
            .padding(.horizontal, DS.Space.m)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(Palette.edge))
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Button {
                    withAnimation(Motion.quick) { split.toggle() }
                } label: {
                    Label(L("Настроить отдельно для диктовки и встреч", "Set dictation and meetings separately"),
                          systemImage: split ? "chevron.down" : "chevron.right")
                        .font(TType.callout)
                        .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
                if split { separate }
                Label(L("Встречи «Только на этом Mac» обрабатывает только модель на этом Mac.",
                        "“This Mac only” meetings are processed only by the on-device model."),
                      systemImage: "lock")
                    .font(TType.caption)
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Варианты

    private func option(_ value: OnboardingModelChoice, title: String, hint: String) -> some View {
        let selected = choice == value
        return Button { choose(value) } label: {
            HStack(alignment: .center, spacing: DS.Space.s) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(selected ? Palette.accent : Palette.inkTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(TType.bodyStrong).foregroundStyle(Palette.ink)
                    Text(hint).font(TType.callout).foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: DS.Space.s)
                if value == .local { localStatus }
            }
            .padding(.vertical, split ? DS.Space.xs : DS.Space.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Справа у «На этом Mac»: скачана, доля загрузки или ошибка.
    @ViewBuilder private var localStatus: some View {
        if let llm {
            if llm.installed {
                Text(L("Скачана", "Downloaded")).font(TType.callout).foregroundStyle(Palette.accent)
            } else if let p = models.progress[llm.key], p.total > 0 {
                Text(MeetingProgressText.percent(Double(p.done) / Double(p.total)))
                    .font(TType.figure(13, .medium)).foregroundStyle(Palette.inkSecondary)
            } else if models.queued(llm.key) {
                // Модели распознавания идут первыми, Gemma ждёт в очереди.
                Text(L("В очереди", "Queued")).font(TType.callout).foregroundStyle(Palette.inkSecondary)
            } else if models.downloading {
                Text(L("Скачивается", "Downloading")).font(TType.callout).foregroundStyle(Palette.inkSecondary)
            } else if models.error != nil, choice == .local {
                Text(L("Не скачалась", "Download failed")).font(TType.callout).foregroundStyle(Palette.doubt)
            }
        }
    }

    // MARK: Раздельно

    private var separate: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            row(L("Диктовка", "Dictation")) {
                Segmented(options: [(PolishBackend.off, L("Выкл", "Off")), (.mlx, L("На этом Mac", "On this Mac")), (.claude, "Claude")],
                          selection: Binding(get: { model.settings.polish.effectiveBackend }, set: { setDictation($0) }))
            }
            row(L("Встречи", "Meetings")) {
                Segmented(options: [(PolishBackend.off, L("Выкл", "Off")), (.mlx, L("На этом Mac", "On this Mac")), (.claude, "Claude")],
                          selection: Binding(get: { model.settings.meetingEffectiveBackend }, set: { setMeetings($0) }))
            }
        }
        .padding(.leading, DS.Space.m)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: DS.Space.s) {
            Text(title).font(TType.callout).foregroundStyle(Palette.ink).frame(width: 72, alignment: .leading)
            content()
        }
    }

    // MARK: Запись выбора

    private func choose(_ value: OnboardingModelChoice) {
        var s = model.settings
        s.meetingBackend = nil
        switch value {
        case .local:
            s.polish.backend = .mlx
            s.grantMeetingAI()  // сказано прямо: ничего не уходит с этого Mac
        case .claude:
            s.polish.backend = .claude
            s.polish.cloudConsent = true
            s.grantMeetingAI()  // под выбором сказано: текст и расшифровки уходят в Anthropic
        case .none, .custom:
            s.polish.backend = .off
        }
        model.onUpdateSettings(s)
        if value == .local { downloadIfNeeded() }
    }

    private func setDictation(_ backend: PolishBackend) {
        var s = model.settings
        let meetings = s.meetingEffectiveBackend
        s.polish.backend = backend
        if backend == .claude { s.polish.cloudConsent = true }
        s.meetingBackend = meetings == s.polish.effectiveBackend ? nil : meetings
        model.onUpdateSettings(s)
        if backend == .mlx { downloadIfNeeded() }
    }

    private func setMeetings(_ backend: PolishBackend) {
        var s = model.settings
        s.meetingBackend = backend == s.polish.effectiveBackend ? nil : backend
        if backend != .off { s.grantMeetingAI() }
        model.onUpdateSettings(s)
        if backend == .mlx { downloadIfNeeded() }
    }

    private func downloadIfNeeded() {
        guard let llm, !llm.installed, !models.scheduled(llm.key), models.progress[llm.key] == nil else { return }
        models.start([llm.key])  // очередь ставит её после моделей распознавания
    }
}

/// Что выбрано на шаге «Модель»; `custom` — диктовка и встречи на разных моделях.
enum OnboardingModelChoice: Equatable {
    case local, claude, none, custom

    init(_ s: MostikSettings) {
        guard s.meetingBackend == nil else { self = .custom; return }
        switch s.polish.effectiveBackend {
        case .mlx: self = .local
        case .claude: self = .claude
        case .off: self = .none
        }
    }
}
