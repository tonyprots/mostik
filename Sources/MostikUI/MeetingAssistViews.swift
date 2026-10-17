import SwiftUI
import MostikCore

// Виды П7. В чужие файлы они встают одной строкой каждый: слот, строка или секция.

// MARK: - Слот в окне встречи: подсказка, кадры, вопросы

/// Идёт запись — карточка-подсказка (M9), состояние кадров (W26), вопросы по ходу (M19);
/// встреча готова — журнал вопросов «отвечен / нет».
struct MeetingAssistSlot: View {
    @ObservedObject var model: AppModel
    @ObservedObject var assist: MeetingAssistModel
    let meeting: AppModel.MeetingItem

    init(model: AppModel, meeting: AppModel.MeetingItem) {
        self.model = model
        self.assist = model.meetingAssist
        self.meeting = meeting
    }

    var body: some View {
        if meeting.state == .recording {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                if let hint = assist.hint { HintCard(assist: assist, hint: hint).transition(.opacity) }
                FramesStatusRow(assist: assist)
                if model.settings.meetingAssist.questions && !assist.questions.isEmpty {
                    QuestionsList(title: L("Вопросы по ходу", "Questions so far"), items: assist.questions, live: true)
                }
            }
            .animation(Motion.spring, value: assist.hint)
        } else if meeting.state == .done {
            Group {
                if let items = assist.journals[meeting.id], !items.isEmpty {
                    QuestionsList(title: L("Вопросы встречи", "Questions"), items: items, live: false)
                }
            }
            .onAppear { assist.onLoadJournal(meeting.id) }
        }
    }
}

/// Карточка подсказки (M9): вопрос, ответ или фрагмент, ссылка на источник, «Закрыть».
struct HintCard: View {
    @ObservedObject var assist: MeetingAssistModel
    let hint: MeetingHint

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                Text(L("Подсказка", "Hint")).font(TType.calloutStrong).foregroundStyle(Palette.accent)
                Text(hint.answer == nil ? L("фрагмент из ваших источников", "excerpt from your sources")
                                        : L("ответ локальной модели по источникам", "local model answer from your sources"))
                    .font(TType.caption).foregroundStyle(Palette.inkTertiary)
                Spacer(minLength: DS.Space.xs)
                Button { assist.onDismissHint() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.inkSecondary)
                        .frame(width: DS.hit, height: DS.hit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle(radius: DS.Radius.row))
                .help(L("Закрыть подсказку", "Close hint"))
                .accessibilityLabel(L("Закрыть подсказку", "Close hint"))
            }
            Text("«\(hint.question)»")
                .font(TType.callout).foregroundStyle(Palette.inkSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let body = hint.answer ?? hint.snippet {
                Text(body)
                    .font(TType.body).lineSpacing(2).foregroundStyle(Palette.ink)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                Button { assist.onOpenHint(hint) } label: {
                    Label(hint.sourceLabel, systemImage: hint.kind == .meeting ? "waveform" : "doc.text")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.mostik(.quiet, compact: true))
                .help(hint.path ?? hint.title)
                if !hint.more.isEmpty {
                    Text(L("ещё: ", "also: ") + hint.more.joined(separator: " · "))
                        .font(TType.caption).foregroundStyle(Palette.inkTertiary)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(DS.Space.s)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(Palette.accent.opacity(0.35)))
    }
}

/// Состояние кадров идущей встречи (W26) и что сделать, если их нельзя снять.
struct FramesStatusRow: View {
    @ObservedObject var assist: MeetingAssistModel

    var body: some View {
        if let line = assist.framesLine {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                Image(systemName: assist.framesState == .watching ? "rectangle.on.rectangle" : "rectangle.slash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.inkTertiary)
                Text(line).font(TType.callout).foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DS.Space.xs)
                if assist.framesState == .blocked(.noPermission) {
                    Button(L("Проверка", "Checkup")) { assist.onOpenCheckup() }
                        .buttonStyle(.mostik(.quiet, compact: true))
                    Button(L("Системные настройки…", "System Settings…")) { assist.onOpenScreenSettings() }
                        .buttonStyle(.mostik(.secondary, compact: true))
                } else if assist.framesCount > 0 {
                    Button(L("Папка слайдов", "Slides folder")) { assist.onOpenFrames() }
                        .buttonStyle(.mostik(.quiet, compact: true))
                }
            }
        }
    }
}

/// Вопросы: по ходу встречи — последние пять; после — весь журнал со статусами.
struct QuestionsList: View {
    let title: String
    let items: [MeetingQuestion]
    let live: Bool
    @State private var expanded = false

    private var shown: [MeetingQuestion] {
        // Открытые вопросы выше отвеченных; по ходу встречи — из пяти последних.
        if live { return MeetingQuestion.openFirst(Array(items.suffix(5))) }
        let ordered = MeetingQuestion.openFirst(items)
        return expanded ? ordered : Array(ordered.prefix(5))
    }

    var body: some View {
        let counts = MeetingAssistModel.counts(items)
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            GroupLabel(text: title, trailing: summary(counts))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Hairline() }
                    row(item)
                }
            }
            .padding(.horizontal, DS.Space.s)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(Palette.edge))
            if !live && items.count > 5 {
                Button(expanded ? L("Свернуть", "Show less") : L("Все вопросы — \(items.count)", "All \(items.count) questions")) {
                    expanded.toggle()
                }
                .buttonStyle(.mostik(.quiet, compact: true))
            }
        }
    }

    private func summary(_ c: (answered: Int, unanswered: Int, pending: Int)) -> String {
        var parts = [L("отвечено \(c.answered)", "\(c.answered) answered"), L("без ответа \(c.unanswered)", "\(c.unanswered) open")]
        if c.pending > 0 { parts.append(L("ждут \(c.pending)", "\(c.pending) waiting")) }
        return parts.joined(separator: " · ")
    }

    private func row(_ item: MeetingQuestion) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Text(Fmt.clock(item.at))
                .font(TType.figure(11, .regular)).foregroundStyle(Palette.inkTertiary)
                .frame(width: 40, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text).font(TType.body).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let who = speaker(item) {
                    Text(who).font(TType.caption).foregroundStyle(Palette.inkTertiary)
                }
            }
            Spacer(minLength: DS.Space.xs)
            StatusTag(status: item.status)
        }
        .padding(.vertical, DS.Space.xs)
    }

    private func speaker(_ item: MeetingQuestion) -> String? {
        let asker = item.speaker ?? LiveTranscript.speaker(item.track, russian: L10n.isRussian)
        guard item.status == .answered, let by = item.answeredBy else { return asker }
        return asker + L(" → ответ: ", " → answer: ") + by
    }
}

private struct StatusTag: View {
    let status: MeetingQuestion.Status

    var body: some View {
        Text(label)
            .font(TType.captionStrong)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(background, in: Capsule())
            .fixedSize()
    }

    private var label: String {
        switch status {
        case .answered: return L("отвечен", "answered")
        case .unanswered: return L("нет ответа", "no answer")
        case .pending: return L("ждёт", "waiting")
        }
    }

    private var color: Color {
        switch status {
        case .answered: return Palette.accent
        case .unanswered: return Palette.doubt
        case .pending: return Palette.inkSecondary
        }
    }

    private var background: Color {
        switch status {
        case .answered: return Palette.accentSoft
        case .unanswered: return Palette.doubtSoft
        case .pending: return Palette.sunken
        }
    }
}

// MARK: - Настройки

struct MeetingAssistSettingsSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        // Журнал вопросов и частота кадров — умолчания без контрола (решение автора):
        // журнал ведётся всегда. Слайды — в группе «Звонки» (MeetingSettingsSection).
        FormToggle(title: L("Подсказки во время встречи", "Hints during meetings"),
                   hint: L("На вопрос собеседника — отрывок из ваших документов.", "An excerpt from your documents when someone asks."),
                   details: L("На вопрос собеседника — отрывок из ваших документов, словаря проекта или прошлых встреч со ссылкой. Не чаще одной карточки за 20 секунд, закрывается крестиком. Только для встреч, не для диктовки; встречи «только на этом Mac» не показываются.",
                              "When someone asks a question, an excerpt from your documents, project glossary or past meetings, with a link. At most one card per 20 seconds, closes with ×. Meetings only, not dictation; “this Mac only” meetings are never shown."),
                   isOn: bind(\.meetingAssist.hints))
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
