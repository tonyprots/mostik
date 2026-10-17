import SwiftUI
import MostikCore

// Виды П6-Б. В чужие файлы они встают одной строкой каждый: слот, модификатор или кнопка.

// MARK: - W10, W15, W16: слот под состоянием встречи

/// Идёт запись — живая расшифровка и «только текст»; встреча готова — «Продолжить запись».
struct MeetingLiveSlot: View {
    @ObservedObject var model: AppModel
    @ObservedObject var live: MeetingLiveModel
    let meeting: AppModel.MeetingItem

    init(model: AppModel, meeting: AppModel.MeetingItem) {
        self.model = model
        self.live = model.meetingLive
        self.meeting = meeting
    }

    var body: some View {
        if meeting.state == .recording {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                // «Только текст» — не переключатель, а состояние из Настроек (D4).
                if live.textOnly { TextOnlyNote() }
                if model.settings.meetingLive.liveTranscript { LiveTranscriptPanel(live: live) }
            }
        } else if meeting.state == .done && live.continuable.contains(meeting.id) && !model.isMeetingRecording {
            HStack(alignment: .center, spacing: DS.Space.m) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Встреча не закончилась?", "Meeting not over?")).font(TType.body).foregroundStyle(Palette.ink)
                    Text(L("Запись продолжится в эту же папку, время пойдёт дальше. Расшифровка соберётся заново — имена говорящих придётся подтвердить ещё раз.",
                           "Recording continues in the same folder and the clock picks up where it stopped. The transcript is rebuilt — you’ll confirm speaker names again."))
                        .font(TType.callout).foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: DS.Space.m)
                Button { live.onContinue(meeting.id) } label: {
                    Label(L("Продолжить запись", "Continue recording"), systemImage: "record.circle")
                }
                .buttonStyle(.mostik(.secondary, compact: true))
            }
        }
    }
}

/// «Только текст» (W15) идущей записи — строкой-состоянием. Выбор живёт в Настройках → «Звук встреч»,
/// где он объяснён; переключатель из вкладки и меню убран (отзыв автора, D4).
struct TextOnlyNote: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "text.bubble").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.inkTertiary)
            Text(L("Звук этой встречи не сохранится, останется только текст. Так задано в Настройках → «Звук встреч».",
                   "This meeting’s audio won’t be kept, only the text. Set in Settings → Meeting audio."))
                .font(TType.callout).foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Живая расшифровка (W10): строки по дорожкам, прокрутка к последней, копирование всего.
struct LiveTranscriptPanel: View {
    @ObservedObject var live: MeetingLiveModel
    @Environment(\.mostikSnapshot) private var snapshot
    @State private var copied = false
    /// Высота строк: блок растёт по содержимому до 280 pt, дальше прокрутка (П9-B).
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                GroupLabel(text: L("По ходу встречи", "As it happens"),
                           trailing: live.transcript.lines.isEmpty ? nil : L("черновик", "draft"))
                Button {
                    copyToPasteboard(live.plainText)
                    copied = true
                } label: {
                    Label(copied ? L("Скопировано", "Copied") : L("Скопировать", "Copy"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.mostik(.quiet, compact: true))
                .disabled(live.transcript.lines.isEmpty)
            }
            ScrollViewReader { proxy in
                SnapshotSafeScroll(.vertical) {
                    LazyVStack(alignment: .leading, spacing: DS.Space.xs) {  // шаг 2, п. 9
                        if live.transcript.lines.isEmpty {
                            Text(live.liveNote ?? L("Первые строки появятся через 15–25 секунд разговора.",
                                                    "The first lines appear after 15–25 seconds of talk."))
                                .font(TType.callout).foregroundStyle(Palette.inkTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(live.transcript.lines) { line in
                            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                                Text(Fmt.clock(line.start))
                                    .font(TType.figure(11, .regular))
                                    .foregroundStyle(Palette.inkTertiary)
                                    .frame(width: 40, alignment: .trailing)
                                Text(LiveTranscript.speaker(line.track, russian: L10n.isRussian))
                                    .font(TType.calloutStrong)
                                    .foregroundStyle(line.track == "mic" ? Palette.ink : Palette.inkSecondary)
                                    .frame(width: 92, alignment: .leading)
                                Text(line.text)
                                    .font(TType.body).lineSpacing(2).foregroundStyle(Palette.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .selectableText(!snapshot)
                            }
                            .id(line.id)
                        }
                        if let note = live.liveNote, !live.transcript.lines.isEmpty {
                            Text(note).font(TType.callout).foregroundStyle(Palette.inkTertiary)
                        }
                    }
                    .padding(DS.Space.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: LiveDraftHeight.self, value: geo.size.height)
                    })
                }
                .frame(height: snapshot ? nil : min(max(contentHeight, 44), 280), alignment: .top)
                .onPreferenceChange(LiveDraftHeight.self) { contentHeight = $0 }
                .onChange(of: live.transcript.lines.count) {
                    copied = false
                    if let last = live.transcript.lines.last?.id {
                        withAnimation(Motion.scroll) { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(Palette.edge))
            Text(L("Черновик без сверки и без имён говорящих. Точная расшифровка — после остановки.",
                   "A rough draft without speaker names. The accurate transcript comes after you stop."))
                .font(TType.callout).foregroundStyle(Palette.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Высота строк черновика по ходу встречи.
private struct LiveDraftHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - W19: согласие — часть старта

/// «Скопировать предупреждение» — свой текст из настроек или стандартный.
struct CopyWarningButton: View {
    @ObservedObject var model: AppModel
    /// Подпись кнопки; nil — «Текст предупреждения».
    var title: String? = nil
    @State private var copied = false

    var body: some View {
        Button {
            copyToPasteboard(ConsentWarning.text(custom: model.settings.meetingLive.warningText, russian: L10n.isRussian))
            copied = true
        } label: {
            Label(copied ? L("Скопировано", "Copied") : title ?? L("Текст предупреждения", "Notice text"),
                  systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.mostik(.quiet, compact: true))
        .help(L("Скопировать предупреждение для чата встречи: что идёт запись и где она хранится",
                "Copy a notice for the meeting chat: that you’re recording and where it’s kept"))
    }
}

// MARK: - W20: черновик письма участникам

struct WarnParticipantsRow: View {
    @ObservedObject var model: AppModel
    let meeting: UpcomingMeeting

    var body: some View {
        if !meeting.emails.isEmpty {
            HStack(spacing: DS.Space.xs) {
                Button { model.meetingLive.onWarnParticipants(meeting) } label: {
                    Label(L("Черновик письма участникам", "Draft a note to participants"), systemImage: "envelope")
                }
                .buttonStyle(.mostik(.quiet, compact: true))
                .help(L("Откроется в почте неотправленным: предупреждение о записи, адреса из события. Отправляете вы.",
                        "Opens unsent in Mail: the recording notice, addresses from the event. You send it."))
                Text(Fmt.participants(meeting.emails.count))
                    .font(TType.figure(11, .regular)).foregroundStyle(Palette.inkTertiary)
                Spacer(minLength: 0)
            }
        }
    }
}

extension Fmt {
    static func participants(_ n: Int) -> String {
        L10n.plural(n, ru: "адресат", "адресата", "адресатов", en: "recipient", "recipients")
    }
}

// MARK: - W17: фильтр по говорящему, прослушивание, переназначение

/// Над расшифровкой: фильтр по говорящему, что сейчас звучит, итог последней правки.
struct MeetingRepairBar: View {
    @ObservedObject var live: MeetingLiveModel
    let meeting: String
    let speakers: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if speakers.count > 1 {
                SnapshotSafeScroll(.horizontal) {
                    HStack(spacing: 4) {
                        chip(nil, L("Все", "All"), color: nil)
                        ForEach(Array(speakers.enumerated()), id: \.offset) { index, name in
                            chip(name, name, color: Palette.speakers[index % Palette.speakers.count])
                        }
                    }
                }
            }
            if let playing = live.playing, playing.meeting == meeting {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "speaker.wave.2.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.accent)
                    Text(Fmt.clock(playing.start) + "–" + Fmt.clock(playing.end))
                        .font(TType.figure(12, .medium)).foregroundStyle(Palette.ink)
                    Button(L("Стоп", "Stop")) { live.onStopPlaying() }
                        .buttonStyle(.mostik(.quiet, compact: true))
                    Spacer(minLength: 0)
                }
            } else if let cue = live.cue[meeting] {
                HStack(spacing: DS.Space.xs) {
                    Button { live.onPlay(meeting, cue, cue + 30, nil) } label: {
                        Label(L("Слушать с ", "Listen from ") + Fmt.clock(cue), systemImage: "play.fill")
                    }
                    .buttonStyle(.mostik(.quiet, compact: true))
                    Spacer(minLength: 0)
                }
            }
            if let note = live.repairNote[meeting] {
                Text(note).font(TType.callout).foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chip(_ value: String?, _ title: String, color: Color?) -> some View {
        let on = live.speakerFilter[meeting] == value
        return Button { live.speakerFilter[meeting] = value } label: {
            HStack(spacing: 5) {
                if let color { StatusDot(color: color, size: 7) }
                Text(title).font(on ? TType.calloutStrong : TType.callout)
                    .foregroundStyle(on ? Palette.ink : Palette.inkSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, DS.Space.xs)
            .frame(height: 26)
            .background(on ? Palette.accentSoft : Palette.sunken, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Строка расшифровки: скрыта фильтром или с меню «Прослушать / Это говорит… / Все реплики…».
struct MeetingTurnRepair: ViewModifier {
    @ObservedObject var live: MeetingLiveModel
    let meeting: String
    let line: AppModel.TranscriptLine
    let next: Double?

    func body(content: Content) -> some View {
        if live.isHidden(line, meeting: meeting) {
            EmptyView()
        } else {
            content.contextMenu { menu }
        }
    }

    @ViewBuilder private var menu: some View {
        Button { live.playLine(line, meeting: meeting, next: next) } label: {
            Label(L("Прослушать", "Listen"), systemImage: "play.fill")
        }
        if let ref = live.turn(for: line, meeting: meeting), ref.isReassignable {
            let labels = TurnRef.labels(live.turns[meeting] ?? [])
            let others = labels.filter { $0.0 != ref.label }
            if !others.isEmpty {
                Menu(L("Эту реплику говорит…", "This turn is…")) {
                    ForEach(others, id: \.0) { label, speaker in
                        Button(title(label, speaker)) { live.onReassignTurn(meeting, ref.id, label) }
                    }
                }
                Menu(L("Все реплики «\(ref.speaker)» — это…", "All of “\(ref.speaker)” is…")) {
                    ForEach(others, id: \.0) { label, speaker in
                        Button(title(label, speaker)) { live.onMergeLabel(meeting, ref.label, label) }
                    }
                }
            }
        }
        if live.speakerFilter[meeting] == nil, !line.isMark {
            Button { live.speakerFilter[meeting] = line.speaker } label: {
                Label(L("Только «\(line.speaker)»", "Only “\(line.speaker)”"), systemImage: "line.3.horizontal.decrease")
            }
        } else if live.speakerFilter[meeting] != nil {
            Button { live.speakerFilter[meeting] = nil } label: {
                Label(L("Показать всех", "Show everyone"), systemImage: "line.3.horizontal.decrease")
            }
        }
    }

    private func title(_ label: String, _ speaker: String) -> String {
        label == speaker ? label : "\(speaker) (\(label))"
    }
}

extension View {
    func meetingTurnRepair(_ live: MeetingLiveModel, meeting: String, line: AppModel.TranscriptLine, next: Double? = nil) -> some View {
        modifier(MeetingTurnRepair(live: live, meeting: meeting, line: line, next: next))
    }
}

// MARK: - W18: цитата сводки при наведении

/// Наведение на ссылку сводки — поповер с репликой; нажатие ставит «Слушать с этого места».
struct QuotePreview: ViewModifier {
    @ObservedObject var model: AppModel
    let meeting: String
    /// Номер реплики среди строк без пометок — как в ссылках сводки.
    let ref: Int
    @State private var shown = false
    @State private var hoverTask: Task<Void, Never>?

    private var line: AppModel.TranscriptLine? {
        let lines = (model.meetingTranscripts[meeting] ?? []).filter { !$0.isMark }
        return lines.indices.contains(ref) ? lines[ref] : nil
    }

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                hoverTask?.cancel()
                if inside {
                    hoverTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        if !Task.isCancelled { shown = line != nil }
                    }
                } else {
                    shown = false
                }
            }
            .simultaneousGesture(TapGesture().onEnded {
                if let line { model.meetingLive.cue[meeting] = line.start }
            })
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                if let line { QuoteCard(model: model, meeting: meeting, line: line) }
            }
    }
}

struct QuoteCard: View {
    @ObservedObject var model: AppModel
    let meeting: String
    let line: AppModel.TranscriptLine

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.xs) {
                Text(Fmt.speakerName(line.speaker)).font(TType.calloutStrong).foregroundStyle(Palette.ink)
                Text(Fmt.clock(line.start)).font(TType.figure(11, .regular)).foregroundStyle(Palette.inkTertiary)
                Spacer(minLength: DS.Space.m)
                Button { model.meetingLive.playLine(line, meeting: meeting, next: nil) } label: {
                    Label(L("Прослушать", "Listen"), systemImage: "play.fill")
                }
                .buttonStyle(.mostik(.quiet, compact: true))
            }
            Text(line.text)
                .font(TType.body).lineSpacing(2).foregroundStyle(Palette.ink)
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.s)
        .frame(width: 340, alignment: .leading)
    }
}

extension View {
    func quotePreview(_ model: AppModel, meeting: String, ref: Int) -> some View {
        modifier(QuotePreview(model: model, meeting: meeting, ref: ref))
    }
}

// MARK: - Настройки: встреча по ходу записи, шумоподавление

struct MeetingLiveSettingsSection: View {
    /// `.more` — ⌃⌘M и шумоподавление в «Ещё». Текст предупреждения о записи в настройках не правится:
    /// его копируют прямо во время встречи (`CopyWarningButton`).
    /// Расшифровка по ходу встречи — умолчание без переключателя (решение автора);
    /// «только текст» живёт в «Приватность и данные → Хранение», автостарт убран.
    enum Part { case more }

    @ObservedObject var model: AppModel
    @ObservedObject var live: MeetingLiveModel
    var part: Part

    init(model: AppModel, part: Part = .more) {
        self.model = model
        self.live = model.meetingLive
        self.part = part
    }

    var body: some View {
        switch part {
        case .more:
            VStack(alignment: .leading, spacing: 0) {
                FormToggle(title: L("Начать или остановить запись", "Start or stop recording"), keys: ["⌃", "⌘", "M"],
                           hint: hotkeyHint, warning: hotkeyBusy, isOn: bind(\.meetingLive.hotkey))
                FormDivider()
                FormRow(title: L("Шумо- и эхоподавление", "Noise and echo suppression"),
                        hint: L("«С колонками» — когда звонок звучит из динамиков.", "“On speakers”: when the call plays through speakers."),
                        details: L("«С колонками» — только когда звук идёт в динамики: тогда без эхоподавления собеседники попадут в ваш микрофон. В наушниках обработка не нужна и слегка портит голос.",
                                   "“On speakers” — only when audio plays through speakers, where the call would leak into your mic. With headphones it isn’t needed and slightly dulls your voice.")) {
                    Segmented(options: [(VoiceProcessingPolicy.off, L("Выкл", "Off")),
                                        (VoiceProcessingPolicy.speakers, L("С колонками", "On speakers")),
                                        (VoiceProcessingPolicy.always, L("Всегда", "Always"))],
                              selection: bind(\.meetingLive.meetingVoiceProcessing))
                }
            }
        }
    }

    private var hotkeyBusy: Bool { model.settings.meetingLive.hotkey && !live.hotkeyActive }

    private var hotkeyHint: String {
        if hotkeyBusy {
            return L("Сочетание занято другим приложением — освободите его.", "Another app holds this shortcut; free it.")
        }
        return L("Из любого приложения. Пометки, пауза и «Завершить» — в меню Mostik в строке меню.", "From any app. Marks, pause and Finish are in the Mostik menu in the menu bar.")
    }

    private func bind<T>(_ keyPath: WritableKeyPath<MostikSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: keyPath] },
                set: { value in update { $0[keyPath: keyPath] = value } })
    }

    private func update(_ change: (inout MostikSettings) -> Void) {
        var s = model.settings
        change(&s)
        model.onUpdateSettings(s)
    }
}

// MARK: - A1: голос озвучки агента

/// Строки выбора голоса (русский и английский) в «Голос и агенты»: установленные голоса macOS,
/// Premium и улучшенные — первыми. Скачать новые голоса можно только в системных настройках.
struct AgentVoicePickerRows: View {
    @ObservedObject var model: AppModel
    @ObservedObject var live: MeetingLiveModel
    @Environment(\.mostikSnapshot) private var snapshot

    init(model: AppModel) {
        self.model = model
        self.live = model.meetingLive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Hairline()
            row(L("Русский голос", "Russian voice"), language: "ru", keyPath: \.voiceRU,
                sample: "Проекту Мостик нужно разрешение.")  // l10n-guard: образец русского голоса
            Hairline()
            row(L("Английский голос", "English voice"), language: "en", keyPath: \.voiceEN,
                sample: "Mostik needs your permission.")
            Text(L("Голоса — те, что уже есть на Mac. Улучшенные и Premium добавляются в Системных настройках → Универсальный доступ → Устная речь.",
                   "Voices already on this Mac. Enhanced and Premium ones are added in System Settings → Accessibility → Spoken Content."))
                .font(FormType.hint).foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, DS.Space.s)
        }
        .onAppear { if live.voices.isEmpty { live.onRefreshVoices() } }
    }

    private func row(_ title: String, language: String, keyPath: WritableKeyPath<AgentVoiceSettings, String?>,
                     sample: String) -> some View {
        let options = SystemVoicePick.options(live.voices, language: language)
        let chosen = SystemVoicePick.best(live.voices, language: language, chosen: model.settings.agentVoice[keyPath: keyPath])
        return HStack(alignment: .center, spacing: DS.Space.m) {
            Text(title).font(TType.body).foregroundStyle(Palette.ink)
            Spacer(minLength: DS.Space.m)
            if options.isEmpty {
                Text(L("Нет установленных", "None installed")).font(TType.callout).foregroundStyle(Palette.inkTertiary)
            } else if snapshot {
                // `ImageRenderer` не рисует системное меню: в снимке — его подпись.
                HStack(spacing: 4) {
                    Text(chosen.map(label) ?? "—").font(TType.body).foregroundStyle(Palette.ink)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.inkSecondary)
                }
            } else {
                Menu {
                    ForEach(options) { voice in
                        Button(label(voice)) {
                            var s = model.settings
                            s.agentVoice[keyPath: keyPath] = voice.id
                            model.onUpdateSettings(s)
                        }
                    }
                } label: {
                    Text(chosen.map(label) ?? "—").font(TType.body)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button { if let chosen { live.onPreviewVoice(chosen.id, sample) } } label: {
                    Image(systemName: "play.fill").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.mostik(.quiet, compact: true))
                .help(L("Послушать", "Preview"))
                .accessibilityLabel(L("Послушать", "Preview"))
            }
        }
        .frame(minHeight: 44)
    }

    private func label(_ voice: SystemVoiceInfo) -> String {
        switch voice.quality {
        case 3: return voice.name + " · Premium"
        case 2: return voice.name + " · " + L("улучшенный", "Enhanced")
        default: return voice.name
        }
    }
}

/// Прокрутка, которая в снимках раскрывается целиком: `ImageRenderer` не рисует содержимое `ScrollView`.
struct SnapshotSafeScroll<Content: View>: View {
    let axis: Axis.Set
    let content: Content
    @Environment(\.mostikSnapshot) private var snapshot

    init(_ axis: Axis.Set, @ViewBuilder content: () -> Content) {
        self.axis = axis
        self.content = content()
    }

    var body: some View {
        if snapshot { content } else { ScrollView(axis, showsIndicators: false) { content } }
    }
}
