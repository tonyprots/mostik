import SwiftUI
import MostikCore

// Встречи вокруг записи: плавающая карточка (W14, M13, M12), «Скоро» с повесткой (W2),
// повестка во время записи, сведения о встрече (M13, W13), метрики «только для вас» (W11),
// выбор фрагмента (W9). Состояние — `MeetingExtrasModel`.

// MARK: - Плавающая карточка

/// Одна карточка поверх окон, у правого верхнего края экрана: предложение записать,
/// напоминание о встрече, отсчёт автоостановки или предупреждение о звуке.
public struct MeetingPromptView: View {
    @ObservedObject var extras: MeetingExtrasModel
    @Environment(\.mostikSnapshot) private var snapshot

    public init(extras: MeetingExtrasModel) { self.extras = extras }

    public var body: some View {
        Group {
            if let prompt = extras.prompt {
                card(prompt)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(width: 340, alignment: .top)
        .animation(Motion.spring, value: extras.prompt)
    }

    @ViewBuilder private func joinButton(_ meeting: UpcomingMeeting) -> some View {
        if let link = meeting.link {
            Button(L("Подключиться", "Join")) { extras.onJoin(link) }
                .buttonStyle(.mostik(.primary, compact: true))
        }
    }

    @ViewBuilder private func reminderRecordButtons(_ meeting: UpcomingMeeting) -> some View {
        recordButton(meeting.link == nil ? .primary : .secondary)
        Button(L("Скрыть", "Dismiss")) { extras.onDismissPrompt() }
            .buttonStyle(.mostik(.quiet, compact: true))
    }

    /// «Записать ▾»: по стрелке — запись сразу «Только на этом Mac» (без Claude, агентов и скриптов).
    private func recordButton(_ kind: MostikButtonStyle.Kind) -> some View {
        MostikSplitButton(title: L("Записать", "Record"), kind: kind,
                          menuHelp: L("Другие способы записи", "More ways to record"),
                          action: { extras.onRecordNow() }) {
            Button { extras.onRecordLocal() } label: {
                Label(L("Записать локально — без Claude, агентов и скриптов",
                        "Record locally — no Claude, agents or scripts"), systemImage: "lock")
            }
        }
    }

    @ViewBuilder private func card(_ prompt: MeetingExtrasModel.Prompt) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            switch prompt {
            case let .callSuggestion(app):
                header(symbol: "record.circle", tint: Palette.record,
                       title: L("Похоже, идёт встреча в \(app)", "Looks like a meeting in \(app)"))
                detail(L("Mostik запишет встречу и подпишет, кто что сказал.",
                          "Mostik records the meeting and labels who said what."))
                HStack(spacing: DS.Space.xs) {
                    recordButton(.primary)
                    Button(L("Нет", "No")) { extras.onDismissPrompt() }
                        .buttonStyle(.mostik(.quiet, compact: true))
                }
                .padding(.top, DS.Space.xxs)
            case let .reminder(meeting):
                header(symbol: "calendar", tint: Palette.accent,
                       title: L("Через минуту: \(meeting.title)", "In a minute: \(meeting.title)"))
                detail(Self.timeRange(meeting) + (meeting.agenda.isEmpty ? "" : " · " + Fmt.agendaItems(meeting.agenda.count)))
                // Не влезает в 340 pt — «Подключиться» уходит в свою строку.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DS.Space.xs) {
                        joinButton(meeting)
                        reminderRecordButtons(meeting)
                    }
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        joinButton(meeting)
                        HStack(spacing: DS.Space.xs) { reminderRecordButtons(meeting) }
                    }
                }
                .padding(.top, DS.Space.xxs)
            case let .autoStop(deadline):
                header(symbol: "stop.circle", tint: Palette.record,
                       title: L("Встреча закончилась", "The meeting is over"))
                countdown(deadline)
                // «Завершить сейчас» — тот же путь, что обычная остановка записи: встреча сохраняется.
                HStack(spacing: DS.Space.xs) {
                    Button(L("Завершить сейчас", "Finish now")) { extras.onFinishNow() }
                        .buttonStyle(.mostik(.primary, compact: true))
                        .help(MeetingMenu.help(.finish))
                    Button(L("Не останавливать", "Keep recording")) { extras.onCancelAutoStop() }
                        .buttonStyle(.mostik(.secondary, compact: true))
                }
                .padding(.top, DS.Space.xxs)
            case let .warning(title, text):
                header(symbol: "exclamationmark.triangle", tint: Palette.doubt, title: title)
                detail(text)
                Button(L("Понятно", "OK")) { extras.onDismissPrompt() }
                    .buttonStyle(.mostik(.quiet, compact: true))
                    .padding(.top, DS.Space.xxs)
            case .systemAudioMissing:
                header(symbol: "speaker.slash", tint: Palette.doubt,
                       title: L("Не слышно собеседников", "Can’t hear the other side"))
                detail(MeetingAudioText.systemSilent(russian: L10n.isRussian))
                HStack(spacing: DS.Space.xs) {
                    Button(L("Открыть настройки", "Open Settings")) { extras.onOpenSystemAudio() }
                        .buttonStyle(.mostik(.primary, compact: true))
                    Button(L("Понятно", "OK")) { extras.onDismissPrompt() }
                        .buttonStyle(.mostik(.quiet, compact: true))
                }
                .padding(.top, DS.Space.xxs)
            }
        }
        .padding(DS.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card + 2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card + 2, style: .continuous).strokeBorder(Palette.edgeStrong))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        .padding(DS.Space.s)
    }

    private func header(symbol: String, tint: Color, title: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(TType.bodyStrong)
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(TType.callout)
            .foregroundStyle(Palette.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 21)
    }

    @ViewBuilder private func countdown(_ deadline: Date) -> some View {
        if snapshot {
            detail(L("Остановлю запись через 0:42", "Stopping in 0:42"))
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let left = max(0, deadline.timeIntervalSince(ctx.date))
                detail(L("Остановлю запись через \(Fmt.clock(left))", "Stopping in \(Fmt.clock(left))"))
                    .monospacedDigit()
            }
        }
    }

    static func timeRange(_ meeting: UpcomingMeeting) -> String {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.dateFormat = "HH:mm"
        return f.string(from: meeting.start) + "–" + f.string(from: meeting.end)
    }
}

// MARK: - «Скоро» (W2)

/// Карточка ближайшей встречи под кнопкой записи: ссылка, повестка, заметка до встречи.
struct UpcomingMeetingCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var extras: MeetingExtrasModel
    let meeting: UpcomingMeeting
    @Environment(\.mostikSnapshot) private var snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                Text(meeting.start <= Date() && !snapshot ? L("Идёт", "Now") : L("Скоро", "Soon"))
                    .font(TType.captionStrong)
                    .foregroundStyle(Palette.accent)
                Text(MeetingPromptView.timeRange(meeting))
                    .font(TType.figure(11, .regular))
                    .foregroundStyle(Palette.inkSecondary)
                Spacer(minLength: 0)
                if let link = meeting.link {
                    Button { extras.onJoin(link) } label: {
                        Label(L("Подключиться", "Join"), systemImage: "video")
                    }
                    .buttonStyle(.mostik(.quiet, compact: true))
                    .help(link)
                }
            }
            Text(meeting.title.isEmpty ? L("Без названия", "Untitled") : meeting.title)
                .font(TType.bodyStrong)
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
            if !meeting.agenda.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(meeting.agenda, id: \.self) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Circle().fill(Palette.inkTertiary).frame(width: 4, height: 4)
                            Text(item).font(TType.callout).foregroundStyle(Palette.inkSecondary).lineLimit(2)
                        }
                    }
                }
                .padding(.top, 2)
            }
            PrepField(extras: extras, eventID: meeting.id)
                .padding(.top, DS.Space.xxs)
            // Черновик предупреждения участникам — в почте, неотправленным (W20).
            WarnParticipantsRow(model: model, meeting: meeting)
        }
        .padding(DS.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(Palette.edge))
    }
}

/// Заметка до встречи: уходит в `notes.md`, когда начнётся запись.
struct PrepField: View {
    @ObservedObject var extras: MeetingExtrasModel
    let eventID: String
    @State private var draft = ""
    @Environment(\.mostikSnapshot) private var snapshot

    var body: some View {
        let placeholder = L("Мои заметки к встрече: что спросить, о чём договориться", "My prep notes: what to ask, what to agree on")
        HStack(spacing: DS.Space.xs) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.inkTertiary)
            Group {
                if snapshot {
                    let text = extras.prep[eventID] ?? ""
                    Text(text.isEmpty ? placeholder : text)
                        .foregroundStyle(text.isEmpty ? Palette.inkTertiary : Palette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField(placeholder, text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                        .foregroundStyle(Palette.ink)
                        .onAppear { draft = extras.prep[eventID] ?? "" }
                        .onChange(of: draft) { _, value in extras.onSetPrep(eventID, value) }
                }
            }
            .font(TType.callout)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: DS.controlHeight)
        .background(Palette.sunken, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
    }
}

// MARK: - Повестка во время записи (W2)

/// Пункты повестки: нажатие ставит пометку M1 с этим текстом в текущую секунду.
struct AgendaMarks: View {
    @ObservedObject var extras: MeetingExtrasModel

    var body: some View {
        if !extras.agenda.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                GroupLabel(text: L("Повестка", "Agenda"), trailing: L("нажмите — станет пометкой", "click to mark"))
                FlowLayout(spacing: 6) {
                    ForEach(extras.agenda, id: \.self) { item in
                        let used = extras.agendaUsed.contains(item)
                        Button { extras.onUseAgendaItem(item) } label: {
                            HStack(spacing: 5) {
                                Image(systemName: used ? "checkmark" : "pin")
                                    .font(.system(size: 10, weight: .semibold))
                                Text(item).lineLimit(1)
                            }
                            .font(TType.callout)
                            .foregroundStyle(used ? Palette.inkTertiary : Palette.accent)
                            .padding(.horizontal, 10)
                            .frame(minHeight: DS.hit)
                            .background(used ? Palette.sunken : Palette.accentSoft,
                                        in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressScale())
                        .help(used ? L("Уже отмечено — нажмите ещё раз, чтобы поставить снова", "Marked — click again to re-mark")
                                   : L("Поставить пометку сейчас", "Mark now"))
                    }
                }
            }
        }
    }
}

// MARK: - Сведения о встрече (M13, W13, M12)

struct MeetingFacts: View {
    @ObservedObject var extras: MeetingExtrasModel
    let meeting: AppModel.MeetingItem
    /// false — переключатель живёт в меню «…» шапки (П9-B), здесь только строка-состояние.
    var showToggle = true

    var body: some View {
        let sensitive = Binding(get: { extras.sensitive.contains(meeting.id) },
                                set: { extras.onSetSensitive(meeting.id, $0) })
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            if let status = extras.recordingStatus[meeting.id], status != "complete" {
                fact(symbol: status == "recovered" ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle",
                     tint: status == "recovered" ? Palette.inkSecondary : Palette.doubt,
                     text: status == "recovered"
                        ? L("Запись восстановлена: дорожка вставала и перезапущена", "Recording recovered: a track stalled and was restarted")
                        : L("Запись неполная: часть звука потеряна", "Recording incomplete: part of the audio is missing"))
            }
            if let link = extras.links[meeting.id] {
                Button { extras.onJoin(link) } label: {
                    fact(symbol: "video", tint: Palette.inkSecondary, text: Self.short(link))
                }
                .buttonStyle(.plain)
                .help(link)
            }
            if !showToggle {
                if sensitive.wrappedValue {
                    HStack(alignment: .center, spacing: DS.Space.xs) {
                        fact(symbol: "lock.fill", tint: Palette.accent,
                             text: L("Только на этом Mac", "This Mac only"))
                            .help(L("Не уходит в облако, агентам и вашим скриптам", "Never sent to the cloud, agents or your scripts"))
                        MeetingUnlockButton(extras: extras, meeting: meeting.id)
                    }
                }
            } else {
            Toggle(isOn: sensitive) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Только на этом Mac", "This Mac only")).font(TType.bodyStrong).foregroundStyle(Palette.ink)
                    Text(L("Не уходит в облако, агентам и вашим скриптам.",
                           "Never sent to the cloud, agents or your scripts."))
                        .font(TType.callout).foregroundStyle(Palette.inkSecondary)
                }
            }
            .toggleStyle(MostikToggleStyle())
            }
        }
    }

    private func fact(symbol: String, tint: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(tint)
            Text(text).font(TType.callout).foregroundStyle(tint == Palette.doubt ? Palette.doubt : Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 22)
    }

    static func short(_ link: String) -> String {
        guard let url = URL(string: link), let host = url.host else { return link }
        return host + (url.path.count > 1 ? url.path : "")
    }
}

// MARK: - Метрики говорения (W11)

/// Только про вас: доля речи, самый длинный монолог, вопросы. Других участников не оцениваем.
struct SpeakingMetricsCard: View {
    let metrics: SpeakingMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            // Плашки «видите только вы» нет (D7): всё в Mostik видит только сам пользователь.
            GroupLabel(text: L("Вы на этой встрече", "You in this meeting"))
            HStack(spacing: 0) {
                figure(String(format: "%.0f%%", metrics.share * 100), L("ваша доля речи", "your share of talk"))
                divider
                figure(Fmt.clock(metrics.longestMonologue), L("самый длинный монолог", "longest monologue"))
                divider
                figure("\(metrics.questions)", L("заданные вами вопросы", "questions you asked"))
            }
            .padding(.vertical, DS.Space.xs)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(Palette.edge))
        }
    }

    private var divider: some View { Rectangle().fill(Palette.edge).frame(width: 1, height: 32) }

    private func figure(_ value: String, _ caption: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(TType.figure(18, .semibold)).foregroundStyle(Palette.ink).monospacedDigit()
            Text(caption).font(TType.caption).foregroundStyle(Palette.inkSecondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Фрагмент (W9)

/// Нижняя плашка режима «Фрагмент»: что выделено и куда сохранится.
struct ClipBar: View {
    @ObservedObject var extras: MeetingExtrasModel
    let meeting: String
    let selected: [AppModel.TranscriptLine]
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "scissors").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.accent)
                Text(summary).font(TType.bodyStrong).foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
                Button(L("Отмена", "Cancel"), action: onCancel)
                    .buttonStyle(.mostik(.quiet, compact: true))
                Button(L("Сохранить .m4a и .md", "Save .m4a and .md")) { extras.onExportClip(meeting, selected) }
                    .buttonStyle(.mostik(.primary, compact: true))
                    .disabled(selected.isEmpty)
            }
            Text(L("Нажмите первую и последнюю реплику. Отрывок сохранится в папке встречи и никуда не уйдёт.",
                   "Click the first and last turn. The clip is saved in the meeting folder and goes nowhere else."))
                .font(TType.callout)
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let result = extras.clipResult, result.meeting == meeting {
                HStack(spacing: 6) {
                    Image(systemName: result.ok ? "checkmark.circle" : "exclamationmark.circle")
                    Text(result.message).lineLimit(2)
                    if let folder = result.folder {
                        Button(L("Показать", "Show")) { extras.onRevealClip(folder) }
                            .buttonStyle(.mostik(.quiet, compact: true))
                    }
                }
                .font(TType.callout)
                .foregroundStyle(result.ok ? Palette.accent : Palette.record)
            }
        }
        .padding(DS.Space.s)
        .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
    }

    private var summary: String {
        guard let first = selected.first, let last = selected.last else { return L("Выберите реплики", "Select turns") }
        let count = selected.count
        return "\(Fmt.clock(first.start))–\(Fmt.clock(last.start)) · " + Fmt.turns(count)
    }
}

extension Fmt {
    static func agendaItems(_ n: Int) -> String {
        L10n.plural(n, ru: "пункт повестки", "пункта повестки", "пунктов повестки", en: "agenda item", "agenda items")
    }
    static func turns(_ n: Int) -> String { L10n.plural(n, ru: "реплика", "реплики", "реплик", en: "turn", "turns") }
}

// MARK: - Слоты во вкладке «Встречи»

/// Карточка «Скоро» под кнопкой записи — пока не пишем и в календаре есть встреча.
struct UpcomingSlot: View {
    @ObservedObject var model: AppModel
    @ObservedObject var extras: MeetingExtrasModel

    var body: some View {
        if let meeting = extras.upcoming, !model.isMeetingRecording {
            UpcomingMeetingCard(model: model, extras: extras, meeting: meeting)
                .padding(.horizontal, DS.Space.m)
                .padding(.bottom, DS.Space.s)
        }
    }
}

struct MeetingMetricsSlot: View {
    @ObservedObject var extras: MeetingExtrasModel
    let meeting: String

    var body: some View {
        if let metrics = extras.metrics[meeting] { SpeakingMetricsCard(metrics: metrics) }
    }
}

/// Выбор фрагмента (W9): первое нажатие — начало, второе — конец, третье — начать заново.
struct ClipSelection: Equatable {
    var first: Int?
    var last: Int?

    func tapped(_ id: Int) -> ClipSelection {
        if first == nil || last != nil { return ClipSelection(first: id, last: nil) }
        return ClipSelection(first: first, last: id)
    }

    private var range: ClosedRange<Int>? {
        guard let first else { return nil }
        let last = self.last ?? first
        return min(first, last)...max(first, last)
    }

    func contains(_ id: Int) -> Bool { range?.contains(id) ?? false }

    func lines(in lines: [AppModel.TranscriptLine]) -> [AppModel.TranscriptLine] {
        guard let range else { return [] }
        return lines.filter { !$0.isMark && range.contains($0.id) }
    }
}


/// Перевод встречи «Только на этом Mac» к агентам, скриптам и Claude — всегда через вопрос
/// (решение автора: кнопка везде — в шапке, сводке и задачах, но не в один клик).
struct MeetingUnlockButton: View {
    @ObservedObject var extras: MeetingExtrasModel
    let meeting: String
    @State private var confirm = false

    var body: some View {
        Button { confirm = true } label: {
            Label(L("Открыть агентам…", "Open to agents…"), systemImage: "lock.open")
        }
        .buttonStyle(.mostik(.quiet, compact: true))
        .help(L("Разрешить Claude, агентам и вашим скриптам работать с этой встречей",
                "Let Claude, agents and your scripts use this meeting"))
        .modifier(MeetingUnlockConfirm(extras: extras, meeting: meeting, isPresented: $confirm))
    }
}

/// Вопрос перед снятием «Только на этом Mac»; общий для кнопки и меню «…».
struct MeetingUnlockConfirm: ViewModifier {
    @ObservedObject var extras: MeetingExtrasModel
    let meeting: String
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.confirmationDialog(L("Открыть встречу агентам?", "Open this meeting to agents?"), isPresented: $isPresented) {
            Button(L("Открыть агентам, скриптам и Claude/Codex", "Open to agents, scripts and Claude/Codex")) {
                extras.onSetSensitive(meeting, false)
            }
        } message: {
            Text(L("Расшифровку смогут читать агенты, получат ваши скрипты, а для сводки она уйдёт в Claude/Codex. Вернуть «Только на этом Mac» можно в «…».",
                   "Agents can read the transcript, your scripts receive it, and it goes to Claude/Codex for the summary. Switch back to “This Mac only” in “…”."))
        }
    }
}
