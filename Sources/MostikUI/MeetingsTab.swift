import SwiftUI
import MostikCore

/// Вкладка «Встречи»: большая кнопка записи, список встреч, расшифровка по голосам.
struct MeetingsTab: View {
    @ObservedObject var model: AppModel
    @State private var selectedID: String?

    init(model: AppModel, initial: String?) {
        self.model = model
        _selectedID = State(initialValue: initial ?? model.meetings.first?.id)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                // Левая колонка: кнопка записи и одна строка пояснения с согласием (D1–D2).
                RecordPanel(model: model)
                    .padding(.horizontal, DS.Space.m)
                    .padding(.top, DS.Space.m)
                    .padding(.bottom, DS.Space.s)
                // Ближайшая встреча календаря: ссылка, повестка, заметка до встречи (M13, W2).
                UpcomingSlot(model: model, extras: model.meetingExtras)
                MostikScroll {
                    // Ленивый список (шаг 2, п. 9): за год встреч строки строятся только видимые.
                    LazyVStack(alignment: .leading, spacing: 2) {
                        GroupLabel(text: L("Встречи", "Meetings"), trailing: "\(model.meetings.count)")
                            .padding(.horizontal, DS.Space.s)
                            .padding(.top, DS.Space.xs)
                            .padding(.bottom, DS.Space.xxs)
                        if model.meetings.isEmpty {
                            Text(L("Записей пока нет. Mostik предложит запись сам, когда микрофон займёт Телемост, Zoom или Meet.",
                                   "No recordings yet. Mostik offers to record when Zoom, Meet or Telemost takes the mic."))
                                .font(TType.callout)
                                .foregroundStyle(Palette.inkSecondary)
                                .padding(DS.Space.s)
                        }
                        ForEach(model.meetings) { meeting in
                            Button { selectedID = meeting.id } label: { MeetingRow(meeting: meeting) }
                                .buttonStyle(RowButtonStyle(selected: meeting.id == selectedID))
                        }
                    }
                    .padding(.horizontal, DS.Space.xs)
                    .padding(.bottom, DS.Space.m)
                }
            }
            .frame(width: 380)
            Rectangle().fill(Palette.edge).frame(width: 1)
            Group {
                if let meeting = model.meetings.first(where: { $0.id == selectedID }) {
                    MeetingDetail(model: model, meeting: meeting)
                } else {
                    Text(L("Выберите запись слева", "Select a recording"))
                        .font(TType.body)
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.surface)
        }
        // Встречу открыли извне (меню «За сутки», архив, подсказка встречи), а вкладка уже на экране.
        .onChange(of: model.meetingFocus?.meeting) { _, meeting in
            if let meeting { selectedID = meeting }
        }
        // Выбранную встречу удалили — показать соседнюю.
        .onChange(of: model.meetings.map(\.id)) { _, ids in
            if let id = selectedID, !ids.contains(id) { selectedID = ids.first }
        }
        // Лист согласия ИИ встреч (M5–M7) поверх вкладки.
        .overlay { MeetingAIConsentOverlay(model: model) }
    }
}

/// Запись встречи (отзыв автора, D1–D2): одна строка-кнопка «● Записать встречу», под ней —
/// одна строка пояснения с согласием. Идёт запись — та же кнопка становится «■ Остановить» с таймером.
/// Красный — только у знака записи.
struct RecordPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var assist: MeetingAssistModel

    init(model: AppModel) {
        self.model = model
        self.assist = model.meetingAssist
    }

    var body: some View {
        let recording = model.isMeetingRecording
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.xs) {
                Button {
                    recording ? model.onStopMeeting() : model.onStartMeeting()
                } label: {
                    RecordButtonLabel(model: model, recording: recording)
                }
                .buttonStyle(RecordButtonStyle(recording: recording))
                .help(recording ? L("Остановить запись и расшифровать", "Stop recording and transcribe")
                                : L("Начать запись встречи", "Start recording the meeting"))
            }
            if !recording {
                // Согласие (W19, R3a) — частью пояснения, без значка: Mostik участникам ничего не показывает,
                // поэтому строка честно говорит, что подтверждает нажатие.
                Text(note)
                    .font(TType.callout)
                    .lineSpacing(2)
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DS.Space.xxs)
            }
        }
    }

    private var note: String {
        let base = L("Звук звонка и микрофон, всё остаётся на этом Mac. Начиная запись, вы подтверждаете, что участники о ней знают.",
                     "Call audio and your mic, kept on this Mac. By starting, you confirm everyone knows they’re being recorded.")
        // «Только текст» задаётся в Настройках (D4); здесь — только состояние, без переключателя.
        guard model.settings.meetingLive.textOnlyDefault else { return base }
        return base + " " + L("Звук не сохранится, останется текст.", "Audio isn’t kept, only the text.")
    }
}

/// Содержимое кнопки записи: знак, подпись, справа таймер идущей записи.
private struct RecordButtonLabel: View {
    @ObservedObject var model: AppModel
    let recording: Bool

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Group {
                if recording {
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Palette.record)
                } else {
                    Circle().fill(Palette.record)
                }
            }
            .frame(width: 10, height: 10)
            Text(recording ? L("Остановить", "Stop") : L("Записать встречу", "Record meeting"))
                .font(TType.bodyStrong)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Spacer(minLength: DS.Space.xs)
            if recording {
                ClockReader(model.clock) { clock in
                    Text(Fmt.clock(clock.meetingElapsed))
                        .font(TType.figure(13, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
        }
        .padding(.horizontal, DS.Space.s)
        .frame(maxWidth: .infinity, minHeight: 36)
        .contentShape(Rectangle())
    }
}

/// Кнопка записи: светлая плашка с тонкой рамкой; идёт запись — тон записи вместо рамки.
private struct RecordButtonStyle: ButtonStyle {
    let recording: Bool

    func makeBody(configuration: Configuration) -> some View {
        Inner(configuration: configuration, recording: recording)
    }

    private struct Inner: View {
        let configuration: Configuration
        let recording: Bool
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
            configuration.label
                .background(recording ? Palette.recordSoft : (hovering ? Palette.sunken : Palette.surface), in: shape)
                .overlay(shape.strokeBorder(recording ? Palette.record.opacity(0.25) : Palette.edgeStrong, lineWidth: 1))
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(Motion.quick, value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

/// Меню «…»: в приложении системное меню, в снимке — его значок (`ImageRenderer` меню не рисует).
struct MoreMenu<Content: View>: View {
    let help: String
    @ViewBuilder var content: Content
    @Environment(\.mostikSnapshot) private var snapshot

    var body: some View {
        Group {
            if snapshot {
                glyph
            } else {
                Menu { content } label: { glyph }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
            }
        }
        .frame(width: DS.hit, height: DS.hit)
        .contentShape(Rectangle())
        .help(help)
        .accessibilityLabel(help)
    }

    private var glyph: some View {
        Image(systemName: "ellipsis.circle")
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(Palette.inkSecondary)
            .frame(width: DS.hit, height: DS.hit)
    }
}

/// Нажатие без подсветки: только сжатие 0.96.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Motion.quick, value: configuration.isPressed)
    }
}

struct MeetingRow: View {
    let meeting: AppModel.MeetingItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                Text(meeting.title)
                    .font(TType.bodyStrong)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                // Идущая расшифровка — полоса с долей рядом с названием, без строки статуса.
                if case .processing = meeting.state, let share = meeting.progress {
                    Spacer(minLength: DS.Space.xs)
                    ProgressBar(value: share).frame(width: 56)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    Text(MeetingProgressText.percent(share))
                        .font(TType.figure(11, .medium))
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
            Text(meta)
                .font(TType.figure(11, .regular))
                .foregroundStyle(Palette.inkSecondary)
                .lineLimit(1)
            if !(meeting.progress != nil && meeting.state.isProcessing) {
                MeetingStateLine(state: meeting.state)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, 10)
    }

    private var meta: String {
        var parts = [Fmt.dayAndTime(meeting.startedAt), Fmt.duration(meeting.duration)]
        if meeting.speakers > 0 { parts.append(Fmt.speakers(meeting.speakers)) }
        return parts.joined(separator: "  ·  ")
    }
}

struct MeetingStateLine: View {
    let state: AppModel.MeetingState

    var body: some View {
        switch state {
        case .recording:
            // Красная только точка, подпись — вторичным цветом.
            label(L("Идёт запись", "Recording"), Palette.inkSecondary, dot: true, dotColor: Palette.record)
        case let .processing(stage):
            label(stage.isEmpty ? L("Обработка…", "Processing…") : stage + "…", Palette.accent, dot: false)
        case .done:
            EmptyView()
        case let .failed(why):
            label(why, Palette.record, dot: false, symbol: "exclamationmark.circle")
        }
    }

    private func label(_ text: String, _ color: Color, dot: Bool, dotColor: Color? = nil, symbol: String? = nil) -> some View {
        HStack(spacing: 6) {
            if dot { StatusDot(color: dotColor ?? color) }
            if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .medium)) }
            Text(text).font(TType.captionStrong).lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.top, 2)
    }
}

struct MeetingDetail: View {
    @ObservedObject var model: AppModel
    @ObservedObject var ai: MeetingAIModel
    let meeting: AppModel.MeetingItem
    @Environment(\.mostikSnapshot) private var snapshot
    /// Выбор фрагмента (W9): первая и последняя нажатые реплики.
    @State private var clip: ClipSelection?

    init(model: AppModel, meeting: AppModel.MeetingItem) {
        self.model = model
        self.ai = model.meetingAI
        self.meeting = meeting
    }

    private var lines: [AppModel.TranscriptLine] { model.meetingTranscripts[meeting.id] ?? [] }

    /// Разделы есть у готовой встречи с расшифровкой: сводка, задачи, расшифровка (П9-B).
    private var sectioned: Bool { meeting.state == .done && !lines.isEmpty }

    /// Выбранный раздел; ссылка на реплику без выбора открывает расшифровку.
    private var section: Binding<MeetingSection> {
        Binding(get: { ai.section[meeting.id] ?? (focusLine != nil ? .transcript : .summary) },
                set: { ai.section[meeting.id] = $0 })
    }

    var body: some View {
        ScrollViewReader { proxy in
            MostikScroll {
                // Внешний стек обычный: ленивый внутри ленивого теряет строки расшифровки.
                // Ленивая сама расшифровка (шаг 2, п. 9) — сотни реплик, строятся только видимые.
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    header
                    if sectioned {
                        sectionBar
                        sectionContent
                    } else {
                        stateBlock
                        // Живая расшифровка и «только текст» по ходу записи (W10, W15).
                        MeetingLiveSlot(model: model, meeting: meeting)
                        // Подсказка, кадры и вопросы по ходу записи (M9, W26, M19).
                        MeetingAssistSlot(model: model, meeting: meeting)
                        if meeting.state == .recording { liveMarks }
                        if !lines.isEmpty { transcript }
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(.horizontal, DS.Space.xl)
                .padding(.vertical, DS.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Ссылка из заметки или сводки (M5): открыть «Расшифровку» и прокрутить к реплике.
            .background(MeetingAIScrollDriver(ai: model.meetingAI, meeting: meeting.id, lines: lines, proxy: proxy))
            // Ссылка на реплику (подсказка встречи, архив): прокрутить к ней.
            .onAppear { if let id = focusLine { proxy.scrollTo(id, anchor: .center) } }
            .onDisappear { if focusLine != nil { model.meetingFocus = nil } }
        }
    }

    // MARK: Шапка: время, название, сведения; справа расшифровка и «…»

    private var header: some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(Fmt.dayAndTime(meeting.startedAt) + "  ·  " + Fmt.duration(meeting.duration))
                    .font(TType.figure(12, .regular))
                    .foregroundStyle(Palette.inkSecondary)
                Text(meeting.title).font(TType.title)
                    .fixedSize(horizontal: false, vertical: true)
                // Ссылка, статус записи, аудио в Корзине и «никуда, кроме этого Mac» (M12, M13, W13).
                MeetingFacts(extras: model.meetingExtras, meeting: meeting, showToggle: false)
                    .padding(.top, DS.Space.xxs)
            }
            Spacer(minLength: DS.Space.m)
            if meeting.state == .done {
                Button { model.onOpenTranscript(meeting) } label: {
                    // Не путать с разделом «Расшифровка»: кнопка открывает файл в редакторе.
                    Label(L("Открыть файлом", "Open as file"), systemImage: "doc.text")
                }
                .buttonStyle(.mostik(.secondary, compact: true))
                .help(L("Открыть расшифровку в редакторе текста", "Open the transcript in a text editor"))
            }
            MeetingMoreMenu(model: model, meeting: meeting)
        }
    }

    // MARK: Разделы

    private var sectionBar: some View {
        HStack(alignment: .center, spacing: DS.Space.s) {
            Segmented(options: [(MeetingSection.summary, L("Сводка", "Summary")),
                                (.tasks, L("Задачи", "Tasks")),
                                (.transcript, L("Расшифровка", "Transcript"))],
                      selection: section)
            Spacer(minLength: DS.Space.s)
            // «Вид сводки ▾» и «Пересобрать» — у сводки; у задач только «Пересобрать» (R3a).
            switch section.wrappedValue {
            case .summary: MeetingAISection(model: model, meeting: meeting, part: .controls)
            case .tasks: MeetingAISection(model: model, meeting: meeting, part: .taskControls)
            case .transcript: EmptyView()
            }
        }
    }

    @ViewBuilder private var sectionContent: some View {
        switch section.wrappedValue {
        case .summary:
            // «Продолжить запись», если встреча не закончилась (W16).
            MeetingLiveSlot(model: model, meeting: meeting)
            // ИИ встреч (M5–M7): сводка и заметки по пометкам — MeetingAIViews.swift.
            MeetingAISection(model: model, meeting: meeting)
            // Журнал вопросов (M19) и метрики говорения — только про вас (W11).
            MeetingAssistSlot(model: model, meeting: meeting)
            MeetingMetricsSlot(extras: model.meetingExtras, meeting: meeting.id)
        case .tasks:
            MeetingAISection(model: model, meeting: meeting, part: .tasks)
        case .transcript:
            if meeting.diarizationUnavailable || meeting.diarizationFailed { diarizationNote }
            // Говорящие: имена, подсказки голосовой памяти, метки на проверку (M14, M15).
            MeetingSpeakersSlot(speakers: model.meetingSpeakers, meeting: meeting.id,
                                order: Array(NSOrderedSet(array: lines.filter { !$0.isMark }.map(\.speaker))) as? [String] ?? [])
            transcript
        }
    }

    private var focusLine: Int? { model.meetingFocus?.line(in: lines, meeting: meeting.id) }

    @ViewBuilder private var stateBlock: some View {
        switch meeting.state {
        case .recording:
            // Красной остаётся только точка: «идёт запись» — сигнал, а пояснение — обычный вторичный текст.
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                if !model.meetingPaused {
                    StatusDot(color: Palette.record, size: 7)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                }
                note(model.meetingPaused
                     ? L("Запись на паузе. Пока она стоит, звук не пишется.", "Recording is paused. Nothing is captured until you resume.")
                     : L("Запись идёт. Расшифровка начнётся, как только вы её остановите.",
                         "Recording. The transcript starts as soon as you stop."),
                     color: Palette.inkSecondary)
            }
        case let .processing(stage):
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack(alignment: .firstTextBaseline) {
                    Text(stage.isEmpty ? L("Обработка", "Processing") : stage)
                        .font(TType.bodyStrong)
                    Spacer(minLength: DS.Space.s)
                    if let share = meeting.progress {
                        Text(MeetingProgressText.percent(share))
                            .font(TType.figure(13, .medium))
                            .foregroundStyle(Palette.inkSecondary)
                    }
                }
                if let share = meeting.progress { ProgressBar(value: share) } else { IndeterminateBar() }
                Text(L("Можно закрыть окно: Mostik закончит в фоне и пришлёт уведомление.",
                       "You can close the window; Mostik finishes in the background."))
                    .font(TType.callout)
                    .foregroundStyle(Palette.inkSecondary)
            }
        case .done:
            // Готовая встреча без расшифровки: открыть расшифровку можно из шапки.
            if meeting.diarizationUnavailable || meeting.diarizationFailed { diarizationNote }
        case let .failed(why):
            if meeting.failureCode == EngineErrorText.diarizationMemory {
                MeetingVoiceMemoryFailure(model: model, meeting: meeting, why: why)
            } else {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    note(why, color: Palette.record)
                    HStack(spacing: DS.Space.xs) {
                        Button { model.onRetryMeeting(meeting.id) } label: {
                            Label(L("Повторить расшифровку", "Retry transcript"), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.mostikPrimary)
                        Button { model.onRevealInFinder(meeting.folder) } label: {
                            Label(L("Показать аудио в Finder", "Show audio in Finder"), systemImage: "folder")
                        }
                        .buttonStyle(.mostik(.quiet))
                    }
                }
            }
        }
    }

    /// Нет `fluidaudiocli`: расшифровка есть, собеседники не разделены. Сведение, не ошибка — без красного.
    @ViewBuilder private var diarizationNote: some View {
        if meeting.diarizationFailed {
            note(L("Голоса не разделились: модель голосов дала сбой. Все собеседники подписаны одним именем.",
                   "Voices weren’t split: the voice model failed. Everyone else shares one label."),
                 color: Palette.inkSecondary)
        } else if let row = model.models.rows.first(where: { $0.purpose == "diarization" }) {
            // модели голосов качаются по кнопке, а встреча переделывается без перезаписи.
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                note(row.installed
                     ? L("Модели голосов скачаны — расшифруйте встречу заново, и собеседники разделятся.",
                         "Voice models are installed — transcribe the meeting again to split speakers.")
                     : L("Все собеседники подписаны одним именем: на этом Mac нет моделей разделения по голосам.",
                         "Everyone else shares one label: this Mac has no speaker-separation models."),
                     color: Palette.inkSecondary)
                if row.installed {
                    Button { model.onRetryMeeting(meeting.id) } label: {
                        Label(L("Расшифровать заново", "Transcribe again"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.mostik(.secondary, compact: true))
                } else if model.models.scheduled(row.key) {
                    note(L("Скачиваются…", "Downloading…"), color: Palette.inkTertiary)
                } else {
                    Button { model.models.start([row.key]) } label: {
                        Label(L("Скачать · ", "Download · ") + ModelCatalog.size(max(row.missingBytes, 0), russian: L10n.isRussian),
                              systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.mostik(.secondary, compact: true))
                }
            }
        } else {
            note(L("Разделение по голосам недоступно на этом Mac", "Speaker separation isn’t available on this Mac"),
                 color: Palette.inkSecondary)
        }
    }

    private func note(_ text: String, color: Color) -> some View {
        Text(text)
            .font(TType.body)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Пометки текущей записи (M1): новые снизу, как лягут в расшифровку.
    private var liveMarks: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            // Пункты повестки из события — пометки в одно нажатие (W2).
            AgendaMarks(extras: model.meetingExtras)
                .padding(.bottom, model.meetingExtras.agenda.isEmpty ? 0 : DS.Space.s)
            GroupLabel(text: L("Пометки", "Marks"),
                       trailing: model.meetingMarks.isEmpty ? nil : Fmt.marks(model.meetingMarks.count))
            ForEach(model.meetingMarks) { mark in
                MarkLine(at: mark.at, text: mark.text)
            }
            MeetingMarkField(model: model)
                .padding(.top, model.meetingMarks.isEmpty ? 0 : DS.Space.xxs)
        }
    }

    private var transcript: some View {
        let speakers = Array(NSOrderedSet(array: lines.filter { !$0.isMark }.map(\.speaker))) as? [String] ?? []
        let people = MeetingSpeakers.peopleCount(speakers)  // «А + Б» и одно имя в разном регистре — не новые люди
        let marks = lines.filter(\.isMark).count
        return VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                GroupLabel(text: sectioned ? Fmt.speakers(people) + (marks > 0 ? " · " + Fmt.marks(marks) : "")
                                           : L("Расшифровка", "Transcript"),
                           trailing: sectioned ? nil : Fmt.speakers(people) + (marks > 0 ? " · " + Fmt.marks(marks) : ""))
                // Фрагмент для пересылки (W9): отрезок аудио + текст в clips/.
                if meeting.state == .done && clip == nil {
                    Button { clip = ClipSelection() } label: { Label(L("Отрывок", "Clip"), systemImage: "scissors") }
                        .buttonStyle(.mostik(.quiet, compact: true))
                        .help(L("Выбрать реплики и сохранить отрывок: звук и текст", "Pick turns and save a clip: audio and text"))
                }
            }
            if let clip {
                ClipBar(extras: model.meetingExtras, meeting: meeting.id, selected: clip.lines(in: lines)) {
                    self.clip = nil
                }
            }
            // Фильтр по говорящему, прослушивание, итог ремонта (W17, W18).
            if meeting.state == .done { MeetingRepairBar(live: model.meetingLive, meeting: meeting.id, speakers: speakers) }
            // Ленивые только реплики (шаг 2, п. 9): у часовой встречи их сотни, строятся видимые.
            LazyVStack(alignment: .leading, spacing: DS.Space.m) {
                ForEach(lines) { line in
                    if line.isMark {
                        MarkLine(at: line.start, text: line.markText)
                    } else if let current = clip {
                        Button { clip = current.tapped(line.id) } label: {
                            speech(line, speakers: speakers, selectable: false)
                                .padding(DS.Space.xxs)
                                .background(current.contains(line.id) ? Palette.accentSoft : .clear,
                                            in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(line.id)
                    } else {
                        speech(line, speakers: speakers)
                            .meetingFocus(line.id == focusLine)
                            .meetingTurnHighlight(model.meetingAI, meeting: meeting.id, line: line.id)
                            .meetingTurnRepair(model.meetingLive, meeting: meeting.id, line: line)
                            .id(line.id)
                    }
                }
            }
        }
    }

    private func speech(_ line: AppModel.TranscriptLine, speakers: [String], selectable: Bool = true) -> some View {
        let index = speakers.firstIndex(of: line.speaker) ?? 0
        return HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            // Таймкоды вкладки — одной колонкой: 12 pt, моноширинные цифры, вторичный цвет (R3a).
            Text(Fmt.clock(line.start))
                .font(TType.figure(12, .regular))
                .foregroundStyle(Palette.inkSecondary)
                .frame(width: 40, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    StatusDot(color: Palette.speakers[index % Palette.speakers.count], size: 7)
                    // Щелчок по имени — переименовать говорящего (E3).
                    SpeakerNameButton(speakers: model.meetingSpeakers, meeting: meeting.id, name: line.speaker,
                                      interactive: !snapshot && selectable)
                }
                // Метка под вопросом (M15): уверенность и альтернативы.
                SpeakerReviewSlot(speakers: model.meetingSpeakers, meeting: meeting.id, start: line.start, speaker: line.speaker)
                Text(line.text)
                    .font(TType.body)
                    .lineSpacing(3)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .selectableText(!snapshot && selectable)
            }
        }
    }
}

/// Сбой на модели голосов (R3a): запись цела, есть путь дальше — повторить без разделения по голосам.
/// Одна главная кнопка; Finder — тихой, как запасной выход.
struct MeetingVoiceMemoryFailure: View {
    @ObservedObject var model: AppModel
    let meeting: AppModel.MeetingItem
    let why: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.circle").font(.system(size: 13, weight: .medium))
                Text(why).font(TType.bodyStrong).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Palette.record)
            Text(L("Запись цела. Без разделения по голосам расшифровке нужно меньше памяти: ваши реплики останутся вашими, а все собеседники будут подписаны одним именем. Имена можно расставить потом.",
                   "The recording is intact. Without splitting by voice the transcript needs less memory: your lines stay yours, and everyone else shares one label. You can name people later."))
                .font(TType.body)
                .lineSpacing(2)
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.xs) {
                Button { model.onRetryMeetingWithoutVoices(meeting.id) } label: {
                    Label(L("Повторить без разделения по голосам", "Retry without splitting by voice"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.mostikPrimary)
                Button { model.onRevealInFinder(meeting.folder) } label: {
                    Label(L("Показать аудио в Finder", "Show audio in Finder"), systemImage: "folder")
                }
                .buttonStyle(.mostik(.quiet))
            }
            .padding(.top, DS.Space.xxs)
        }
    }
}

/// Подпись хода расшифровки встречи по фазе движка: без дорожек, полных имён моделей и счётчиков окон.
public enum MeetingProgressText {
    public static func label(phase: String, model: String) -> String {
        switch phase {
        case "prepare": return L("Подготовка", "Preparing")
        case "voices": return L("Разделение по голосам", "Splitting by voice")
        case "transcribe":
            let base = L("Расшифровка", "Transcribing")
            return model.isEmpty ? base : base + " · " + model
        case "finish": return L("Сборка расшифровки", "Putting it together")
        default: return phase
        }
    }

    public static func percent(_ share: Double) -> String {
        "\(Int((min(max(share, 0), 1) * 100).rounded(.down)))%"
    }
}

/// Определённый прогресс: заполненная доля дорожки, анимированно.
struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.accentSoft)
                Capsule().fill(Palette.accent)
                    .frame(width: max(4, geo.size.width * min(max(value, 0), 1)))
            }
            .clipShape(Capsule())
            .animation(Motion.quick, value: value)
        }
        .frame(height: 4)
    }
}

/// Неопределённый прогресс: бегущий отрезок со скруглёнными концами.
struct IndeterminateBar: View {
    @Environment(\.mostikSnapshot) private var snapshot

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.accentSoft)
                if snapshot {
                    segment(width: geo.size.width, phase: 0.35)
                } else {
                    TimelineView(.animation) { ctx in
                        let t = ctx.date.timeIntervalSinceReferenceDate
                        segment(width: geo.size.width, phase: t.truncatingRemainder(dividingBy: 1.6) / 1.6)
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 4)
    }

    private func segment(width: CGFloat, phase: Double) -> some View {
        let w = width * 0.3
        return Capsule().fill(Palette.accent)
            .frame(width: w)
            .offset(x: -w + (width + w) * phase)
    }
}

/// «…» в шапке встречи (П9-B; D6): сверху действие «Показать в Finder», ниже отдельным
/// разделом — где встреча доступна. «Только на этом Mac» — выбор состояния, а не кнопка рядом с действием;
/// включённое состояние видно и в шапке строкой с замком (`MeetingFacts`).
struct MeetingMoreMenu: View {
    @ObservedObject var model: AppModel
    @ObservedObject var extras: MeetingExtrasModel
    @ObservedObject var assist: MeetingAssistModel
    let meeting: AppModel.MeetingItem
    @State private var confirmUnlock = false
    @State private var confirmDelete = false

    init(model: AppModel, meeting: AppModel.MeetingItem) {
        self.model = model
        self.extras = model.meetingExtras
        self.assist = model.meetingAssist
        self.meeting = meeting
    }

    private var failed: Bool {
        if case .failed = meeting.state { return true }
        return false
    }

    var body: some View {
        MoreMenu(help: L("Ещё для встречи", "More for this meeting")) {
            Button(failed ? L("Показать аудио в Finder", "Show audio in Finder") : L("Показать в Finder", "Show in Finder")) {
                model.onRevealInFinder(meeting.folder)
            }
            Divider()
            // Смысл приватности: встреча «только на этом Mac» не уходит ни в облако, ни хукам, ни агентам.
            // Закрыть — в один клик, открыть — только через вопрос (заголовок секции
            // в тёмной теме сливался, поэтому пункт один и говорит сам за себя).
            if extras.sensitive.contains(meeting.id) {
                Button { confirmUnlock = true } label: {
                    Label(L("Открыть агентам, скриптам и Claude…", "Open to agents, scripts and Claude…"), systemImage: "lock.open")
                }
            } else {
                Button { extras.onSetSensitive(meeting.id, true) } label: {
                    Label(L("Только на этом Mac", "This Mac only"), systemImage: "lock")
                }
            }
            if meeting.state == .recording {
                Divider()
                Toggle(MeetingMenu.framesTitle(on: assist.framesConsent, count: assist.framesCount),
                       isOn: Binding(get: { assist.framesConsent }, set: { _ in assist.onToggleFrames() }))
            } else {
                Divider()
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label(L("Удалить встречу…", "Delete meeting…"), systemImage: "trash")
                }
            }
        }
        .modifier(MeetingUnlockConfirm(extras: extras, meeting: meeting.id, isPresented: $confirmUnlock))
        .confirmationDialog(L("Удалить встречу «\(meeting.title)»?", "Delete “\(meeting.title)”?"), isPresented: $confirmDelete) {
            Button(L("Удалить", "Delete"), role: .destructive) { model.onDeleteMeeting(meeting) }
        } message: {
            Text(L("Запись, расшифровка и сводка уйдут в Корзину — вернуть можно оттуда.",
                   "The recording, transcript and summary go to the Trash — restore them from there."))
        }
    }
}
