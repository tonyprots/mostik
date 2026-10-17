import SwiftUI
import MostikCore

// Говорящие встречи (M14, M15): панель в окне встречи, пометка «проверить» у реплики,
// настройки голосовой памяти и экран согласия. Данные — `MeetingSpeakersModel`.

/// Панель «Говорящие» над расшифровкой: имена, подсказки голосовой памяти, сколько реплик проверить.
struct MeetingSpeakersPanel: View {
    @ObservedObject var speakers: MeetingSpeakersModel
    let meeting: String
    /// Видимые имена в порядке расшифровки — цвет точки тот же, что у реплик ниже.
    var order: [String] = []
    /// Имя поля, открытого для ввода (метка), — одно за раз.
    @State private var editing: String?
    @State private var draft = ""

    private var data: MeetingSpeakers { speakers.speakers(meeting) }

    var body: some View {
        let reviews = data.reviews.count
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            GroupLabel(text: L("Говорящие", "Speakers"),
                       trailing: reviews > 0 ? Fmt.toReview(reviews) : nil)
            VStack(alignment: .leading, spacing: 0) {
                row(label: SpeakerColors.me, name: MeetingSpeakers.me, note: L("ваш микрофон", "your microphone"),
                    color: color(MeetingSpeakers.me, fallback: max(order.count, data.speakers.count + 1)))
                ForEach(Array(data.speakers.enumerated()), id: \.element.id) { index, speaker in
                    Hairline()
                    speakerRow(speaker, color: color(speaker.name, fallback: index + 1))
                }
                if data.memoryUsed && !data.memoryAvailable {
                    Hairline()
                    Text(L("Голосовая память включена, но модели голоса нет — подсказок не будет.",
                           "Voice memory is on, but the voice model is missing — no suggestions."))
                        .font(TType.callout).foregroundStyle(Palette.inkSecondary)
                        .padding(.vertical, DS.Space.s)
                }
            }
            .padding(.horizontal, DS.Space.m)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(Palette.edge))
            if reviews > 0 {
                Text(L("Где стоит «?», Mostik не уверен, кто говорит. Проверьте эти места.",
                       "Where you see “?”, Mostik isn’t sure who’s speaking. Check those places."))
                    .font(TType.callout).foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = speakers.message[meeting] {
                Text(message).font(TType.callout).foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(label: String, name: String, note: String, color: Int) -> some View {
        HStack(spacing: DS.Space.s) {
            StatusDot(color: Palette.speakers[color % Palette.speakers.count], size: 8)
            Text(Fmt.speakerName(name)).font(TType.bodyStrong).foregroundStyle(Palette.ink)
            Text(note).font(TType.callout).foregroundStyle(Palette.inkTertiary)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 40)
    }

    @ViewBuilder private func speakerRow(_ speaker: MeetingSpeakers.Speaker, color: Int) -> some View {
        let busy = speakers.busy.contains(meeting)
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.s) {
                StatusDot(color: Palette.speakers[color % Palette.speakers.count], size: 8)
                // Само имя тоже открывает поле: по «Собеседнику 2» щёлкают чаще, чем по «Назвать».
                Button {
                    draft = speaker.isNamed ? speaker.name : ""
                    editing = speaker.label
                } label: {
                    Text(speaker.name).font(TType.bodyStrong).foregroundStyle(Palette.ink).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .help(speaker.isNamed ? L("Переименовать говорящего", "Rename this speaker") : L("Назвать говорящего", "Name this speaker"))
                Text(speaker.isNamed ? speaker.labels.joined(separator: ", ") + " · " + Fmt.speech(speaker.seconds)
                                     : Fmt.speech(speaker.seconds))
                    .font(TType.figure(12, .regular)).foregroundStyle(Palette.inkTertiary)
                    .lineLimit(1)
                Spacer(minLength: DS.Space.s)
                if editing != speaker.label {
                    Button(speaker.isNamed ? L("Переименовать", "Rename") : L("Назвать", "Name")) {
                        draft = speaker.isNamed ? speaker.name : ""
                        editing = speaker.label
                    }
                    .buttonStyle(.mostik(.quiet, compact: true))
                    .disabled(busy)
                    SpeakerMoreMenu(speakers: speakers, meeting: meeting, speaker: speaker, data: data)
                        .disabled(busy)
                }
            }
            if editing == speaker.label {
                SpeakerNameEditor(draft: $draft, onCancel: { editing = nil }, onCommit: commit)
            } else if let suggestion = data.suggestion(for: speaker.label) {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "waveform").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.accent)
                    Text(L("Похоже на голос: ", "Sounds like: ")).font(TType.callout).foregroundStyle(Palette.inkSecondary)
                        + Text(suggestion.name).font(TType.calloutStrong).foregroundStyle(Palette.ink)
                        + Text(" · " + Fmt.percent(suggestion.score)).font(TType.callout).foregroundStyle(Palette.inkTertiary)
                    Spacer(minLength: DS.Space.s)
                    Button(L("Нет", "No")) { speakers.onReject(meeting, speaker.label) }
                        .buttonStyle(.mostik(.quiet, compact: true))
                        .disabled(busy)
                    Button(L("Да, это \(suggestion.name)", "Yes, it’s \(suggestion.name)")) { speakers.onConfirm(meeting, speaker.label) }
                        .buttonStyle(.mostik(.secondary, compact: true))
                        .disabled(busy)
                }
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, 6)
                .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
            }
        }
        .padding(.vertical, DS.Space.s)
    }

    private func color(_ name: String, fallback: Int) -> Int { order.firstIndex(of: name) ?? fallback }

    private func commit() {
        guard let label = editing else { return }
        let name = draft.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        speakers.onRename(meeting, label, name)
        editing = nil
    }
}

enum SpeakerColors {
    static let me = MeetingSpeakers.me
}

/// Поле имени говорящего: одно и то же в списке говорящих и в поповере строки расшифровки (E3).
struct SpeakerNameEditor: View {
    @Binding var draft: String
    var onCancel: () -> Void
    var onCommit: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            MostikTextField(placeholder: L("Имя, как в календаре", "Name, as in the calendar"), text: $draft,
                            leadingSymbol: "person")
                .onSubmit(onCommit)
            Button(L("Отмена", "Cancel"), action: onCancel)
                .buttonStyle(.mostik(.quiet, compact: true))
                .keyboardShortcut(.cancelAction)
            Button(L("Готово", "Done"), action: onCommit)
                .buttonStyle(.mostik(.primary, compact: true))
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

/// «…» у говорящего: «Убрать имя» (E1) и «Объединить с…» (E2).
struct SpeakerMoreMenu: View {
    @ObservedObject var speakers: MeetingSpeakersModel
    let meeting: String
    let speaker: MeetingSpeakers.Speaker
    let data: MeetingSpeakers

    var body: some View {
        let targets = data.mergeTargets(for: speaker)
        if speaker.isNamed || !targets.isEmpty {
            MoreMenu(help: L("Ещё для говорящего", "More for this speaker")) {
                if speaker.isNamed {
                    Button { speakers.onUnname(meeting, speaker.label) } label: {
                        Label(L("Убрать имя", "Remove name"), systemImage: "person.crop.circle.badge.xmark")
                    }
                }
                if !targets.isEmpty {
                    Menu(L("Объединить с…", "Merge with…")) {
                        ForEach(targets) { target in
                            Button(target.name) { speakers.onMerge(meeting, speaker.label, target.label) }
                        }
                    }
                    .help(L("Это один человек: его реплики разделились на два голоса",
                            "Same person: their turns were split into two voices"))
                }
            }
        }
    }
}

/// Поповер имени из строки расшифровки (E3): заголовок, поле и «Убрать имя».
struct SpeakerRenameCard: View {
    let speaker: MeetingSpeakers.Speaker
    @Binding var draft: String
    var onCancel: () -> Void
    var onCommit: () -> Void
    var onUnname: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(speaker.isNamed ? L("Переименовать «\(speaker.name)»", "Rename “\(speaker.name)”")
                                 : L("Как зовут «\(speaker.name)»?", "Who is “\(speaker.name)”?"))
                .font(TType.bodyStrong).foregroundStyle(Palette.ink)
            Text(L("Имя получат все реплики этого голоса. Имя, которое уже есть на встрече, объединит говорящих.",
                   "Every turn in this voice gets the name. A name already used in this meeting merges the speakers."))
                .font(TType.callout).foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            SpeakerNameEditor(draft: $draft, onCancel: onCancel, onCommit: onCommit)
            if speaker.isNamed {
                Button(action: onUnname) {
                    Label(L("Убрать имя", "Remove name"), systemImage: "person.crop.circle.badge.xmark")
                }
                .buttonStyle(.mostik(.quiet, compact: true))
            }
        }
        .padding(DS.Space.m)
        .frame(width: 380, alignment: .leading)
    }
}

/// Имя говорящего в строке расшифровки (E3): щелчок — то же переименование, что в списке говорящих.
/// «Я», перекрытия «А + Б» и встречи без разобранных говорящих — просто текст.
struct SpeakerNameButton: View {
    @ObservedObject var speakers: MeetingSpeakersModel
    let meeting: String
    let name: String
    var interactive = true
    @State private var shown = false
    @State private var draft = ""
    @State private var hover = false

    var body: some View {
        let speaker = interactive ? speakers.speakers(meeting).speaker(named: name) : nil
        if let speaker {
            Button {
                draft = speaker.isNamed ? speaker.name : ""
                shown = true
            } label: {
                text.underline(hover, color: Palette.inkTertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(speakers.busy.contains(meeting))
            .onHover { hover = $0 }
            .help(speaker.isNamed ? L("Переименовать говорящего", "Rename this speaker") : L("Назвать говорящего", "Name this speaker"))
            .accessibilityHint(L("Открывает поле имени", "Opens the name field"))
            .popover(isPresented: $shown, arrowEdge: .bottom) { editor(speaker) }
        } else {
            text
        }
    }

    private var text: some View {
        Text(Fmt.speakerName(name)).font(TType.calloutStrong).foregroundStyle(Palette.ink)
    }

    private func editor(_ speaker: MeetingSpeakers.Speaker) -> some View {
        SpeakerRenameCard(speaker: speaker, draft: $draft, onCancel: { shown = false },
                          onCommit: { commit(speaker) },
                          onUnname: {
                              shown = false
                              speakers.onUnname(meeting, speaker.label)
                          })
    }

    private func commit(_ speaker: MeetingSpeakers.Speaker) {
        let value = draft.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        shown = false
        if value != speaker.name { speakers.onRename(meeting, speaker.label, value) }
    }
}

/// Пометка у реплики с неуверенной меткой (M15): согласиться или поправить в одно-два нажатия.
/// «Верно» — метка подтверждена; альтернативы — голоса, на которые похожа реплика; «Другой» —
/// любой говорящий встречи или новый по имени (диаризация могла не выделить его голос).
struct SpeakerReviewRow: View {
    @ObservedObject var speakers: MeetingSpeakersModel
    let meeting: String
    let review: MeetingSpeakers.Review
    /// Что выбрано — пометка показывает это на месте, пока движок пересчитывает реплику.
    var onResolved: (String) -> Void = { _ in }
    @State private var naming = false
    @State private var draft = ""

    var body: some View {
        let busy = speakers.busy.contains(meeting)
        let name = Fmt.speakerName(review.speaker)
        HStack(spacing: DS.Space.xs) {
            Text(L("Это \(name)?", "Is this \(name)?"))
                .font(TType.captionStrong).foregroundStyle(Palette.doubt)
                .help(L("Mostik не уверен в голосе: \(Fmt.percent(review.confidence))",
                        "Mostik isn’t sure about the voice: \(Fmt.percent(review.confidence))"))
            Button {
                onResolved(L("Верно: \(name)", "Confirmed: \(name)"))
                speakers.onSetTurn(meeting, review.turn, nil)
            } label: {
                Label(L("Верно", "Correct"), systemImage: "checkmark")
            }
            .buttonStyle(.mostik(.secondary, compact: true))
            .disabled(busy)
            ForEach(review.alternatives, id: \.label) { alt in
                Button(alt.share > 0 ? "\(alt.name) · \(Fmt.percent(alt.share))" : alt.name) {
                    onResolved(L("Теперь: \(alt.name)", "Now: \(alt.name)"))
                    speakers.onSetTurn(meeting, review.turn, alt.label)
                }
                .buttonStyle(.mostik(.quiet, compact: true))
                .disabled(busy)
            }
            Button(L("Другой…", "Someone else…")) { draft = ""; naming = true }
                .buttonStyle(.mostik(.quiet, compact: true))
                .disabled(busy)
            .popover(isPresented: $naming, arrowEdge: .bottom) { newSpeaker }
        }
        .padding(.horizontal, DS.Space.xs)
        .padding(.vertical, 4)
        .background(Palette.doubtSoft, in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
    }

    /// Говорящие встречи, кроме нынешнего и уже предложенных альтернатив; одно имя — одна строка.
    private var others: [MeetingSpeakers.Speaker] {
        let skip = Set(review.alternatives.map(\.label) + [review.label])
        var seen = Set<String>([MeetingSpeakers.key(review.speaker)])
        return speakers.speakers(meeting).speakers.filter { speaker in
            guard !speaker.labels.contains(where: skip.contains) else { return false }
            return seen.insert(MeetingSpeakers.key(speaker.name)).inserted
        }
    }

    private var newSpeaker: some View {
        SpeakerReassignCard(others: others, draft: $draft, onCancel: { naming = false }, onPick: { speaker in
            naming = false
            onResolved(L("Теперь: \(Fmt.speakerName(speaker.name))", "Now: \(Fmt.speakerName(speaker.name))"))
            speakers.onSetTurn(meeting, review.turn, speaker.label)
        }, onName: { value in
            naming = false
            onResolved(L("Теперь: \(value)", "Now: \(value)"))
            speakers.onSetTurnName(meeting, review.turn, value)
        })
    }
}

/// «Другой…» у реплики под вопросом: говорящие встречи одной кнопкой или новое имя.
struct SpeakerReassignCard: View {
    let others: [MeetingSpeakers.Speaker]
    @Binding var draft: String
    var onCancel: () -> Void
    var onPick: (MeetingSpeakers.Speaker) -> Void
    var onName: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(L("Кто говорит в этой реплике?", "Who is speaking in this turn?"))
                .font(TType.bodyStrong).foregroundStyle(Palette.ink)
            if !others.isEmpty {
                FlowLayout(spacing: DS.Space.xs) {
                    ForEach(others, id: \.label) { speaker in
                        Button(Fmt.speakerName(speaker.name)) { onPick(speaker) }
                            .buttonStyle(.mostik(.secondary, compact: true))
                    }
                }
            }
            Text(L("Или впишите имя. Меняется только эта реплика; имя, которое уже есть на встрече, отдаст её этому говорящему.",
                   "Or type a name. Only this turn changes; a name already used in this meeting moves the turn to that speaker."))
                .font(TType.callout).foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            SpeakerNameEditor(draft: $draft, onCancel: onCancel, onCommit: {
                let value = draft.trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { onName(value) }
            })
        }
        .padding(DS.Space.m)
        .frame(width: 380, alignment: .leading)
    }
}

// MARK: - Настройки

/// Настройки «Голосовая память»: выключена по умолчанию, включается только через экран согласия.
struct VoiceMemorySettingsSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var speakers: MeetingSpeakersModel
    @State private var editing: String?
    @State private var draft = ""
    @State private var confirmForgetAll = false

    init(model: AppModel) {
        self.model = model
        self.speakers = model.meetingSpeakers
    }

    private var enabled: Bool { model.settings.voiceMemory && model.settings.voiceMemoryConsent }

    var body: some View {
        FormGroup(title: L("Голосовая память", "Voice memory")) {
            if speakers.status.available || enabled {
                FormToggle(title: L("Узнавать собеседников по голосу", "Recognise people by voice"),
                           hint: L("Предложит имя, вы подтвердите. Звук не хранится.", "Suggests a name for you to confirm. No audio kept."),
                           details: L("Когда вы назовёте говорящего, Mostik запомнит отпечаток его голоса — набор чисел, не запись. На следующих встречах предложит имя, а вы подтвердите. Ваш микрофон не участвует. Включается только через экран согласия.",
                                      "When you name a speaker, Mostik keeps a voiceprint — a set of numbers, not a recording. At later meetings it suggests the name and you confirm. Your microphone is never used. Turned on only through the consent screen."),
                           isOn: Binding(get: { enabled }, set: { on in
                               if on && !model.settings.voiceMemoryConsent { speakers.consentShown = true } else { speakers.onSetEnabled(on) }
                           }))
            } else {
                FormCollapsed(title: L("Узнавать собеседников по голосу", "Recognise people by voice"),
                              reason: L("Нужна модель голоса: она ставится вместе с разделением по голосам.", "Needs the voice model; it comes with speaker separation."))
            }
            if !speakers.status.people.isEmpty {
                ForEach(speakers.status.people) { person in
                    FormDivider()
                    personRow(person)
                }
                FormDivider()
                forgetAllRow
            }
        }
        .sheet(isPresented: Binding(get: { speakers.consentShown }, set: { speakers.consentShown = $0 })) {
            VoiceMemoryConsentView(onAgree: {
                speakers.consentShown = false
                speakers.onSetEnabled(true)
            }, onCancel: { speakers.consentShown = false })
        }
    }

    @ViewBuilder private func personRow(_ person: VoicePerson) -> some View {
        HStack(spacing: DS.Space.s) {
            if editing == person.id {
                MostikTextField(placeholder: L("Имя", "Name"), text: $draft, leadingSymbol: "person")
                    .onSubmit { rename(person) }
                Button(L("Отмена", "Cancel")) { editing = nil }.buttonStyle(.mostik(.quiet, compact: true))
                Button(L("Готово", "Done")) { rename(person) }.buttonStyle(.mostik(.primary, compact: true))
            } else {
                Text(person.name).font(TType.body).foregroundStyle(Palette.ink)
                Text(Fmt.samples(person.samples)).font(FormType.hint).foregroundStyle(Palette.inkSecondary)
                Spacer(minLength: DS.Space.s)
                Button(L("Переименовать", "Rename")) { draft = person.name; editing = person.id }
                    .buttonStyle(.mostik(.quiet, compact: true))
                    .help(L("Имя другого человека из списка — объединит их образцы", "Another person’s name merges their samples"))
                Button(L("Забыть", "Forget")) { speakers.onForget(person.id) }
                    .buttonStyle(.mostik(.quiet, compact: true))
            }
        }
        .frame(minHeight: 40)
    }

    private var forgetAllRow: some View {
        HStack(spacing: DS.Space.s) {
            Text(confirmForgetAll ? L("Стереть все отпечатки голосов и подсказки?", "Erase all voiceprints and suggestions?")
                                  : L("Имена в готовых расшифровках останутся.", "Names in finished transcripts stay."))
                .font(TType.callout).foregroundStyle(Palette.inkSecondary)
            Spacer(minLength: DS.Space.s)
            if confirmForgetAll {
                Button(L("Отмена", "Cancel")) { confirmForgetAll = false }.buttonStyle(.mostik(.quiet, compact: true))
                Button(L("Стереть", "Erase")) { confirmForgetAll = false; speakers.onForget(nil) }
                    .buttonStyle(.mostik(.destructive, compact: true))
            } else {
                Button(L("Забыть всех", "Forget everyone")) { confirmForgetAll = true }
                    .buttonStyle(.mostik(.secondary, compact: true))
            }
        }
        .frame(minHeight: 44)
    }

    private func rename(_ person: VoicePerson) {
        let name = draft.trimmingCharacters(in: .whitespaces)
        editing = nil
        guard !name.isEmpty, name != person.name else { return }
        speakers.onRenamePerson(person.id, name)
    }
}

/// Экран согласия голосовой памяти (M14): что хранится, где, как работает и как стереть.
struct VoiceMemoryConsentView: View {
    var onAgree: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text(L("Узнавать собеседников по голосу?", "Recognise people by voice?"))
                .font(TType.headline).foregroundStyle(Palette.ink)
            VStack(alignment: .leading, spacing: DS.Space.s) {
                point("waveform", L("Что хранится", "What is kept"),
                      L("Отпечаток голоса — 256 чисел на образец, до 10 образцов на человека. Звук не сохраняется.",
                        "A voiceprint — 256 numbers per sample, up to 10 samples per person. No audio is kept."))
                point("lock", L("Где", "Where"),
                      L("Только на этом Mac, в папке voices рядом с данными Mostik. Никуда не отправляется.",
                        "Only on this Mac, in the voices folder next to Mostik’s data. Nothing is sent anywhere."))
                point("person.crop.circle.badge.questionmark", L("Как работает", "How it works"),
                      L("Отпечаток появляется, когда вы сами называете говорящего. Потом Mostik только предлагает имя — подставит его, когда вы ответите «да».",
                        "A voiceprint appears only when you name a speaker yourself. Later Mostik only suggests the name and applies it when you say yes."))
                point("mic.slash", L("Ваш голос", "Your voice"),
                      L("Дорожка микрофона — это вы, её память не трогает.",
                        "The microphone track is you; voice memory never touches it."))
                point("trash", L("Как стереть", "How to erase"),
                      L("«Забыть» у человека или «Забыть всех» в Настройках — отпечатки и подсказки удаляются сразу.",
                        "“Forget” next to a person or “Forget everyone” in Settings removes voiceprints and suggestions at once."))
            }
            Text(L("Голос — биометрические данные. Включайте, только если собеседники не против, что их голоса узнаются.",
                   "A voice is biometric data. Turn this on only if the people you meet with are fine with being recognised."))
                .font(TType.callout).foregroundStyle(Palette.doubt)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.xs) {
                Spacer()
                Button(L("Не сейчас", "Not now"), action: onCancel)
                    .buttonStyle(.mostik(.quiet))
                    .keyboardShortcut(.cancelAction)
                Button(L("Согласен, включить", "I agree, turn on"), action: onAgree)
                    .buttonStyle(.mostikPrimary)
            }
        }
        .padding(DS.Space.l)
        .frame(width: 520)
        .background(Palette.surface)
    }

    private func point(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.accent).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(TType.bodyStrong).foregroundStyle(Palette.ink)
                Text(text).font(TType.callout).foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension Fmt {
    static func percent(_ value: Double) -> String { "\(Int((min(1, max(0, value)) * 100).rounded()))\u{00A0}%" }

    /// Сколько говорил: секунды до минуты, дальше — как длительность встречи.
    static func speech(_ seconds: Double) -> String {
        seconds < 60 ? "\(max(1, Int(seconds.rounded())))\u{00A0}" + L("с", "s") : duration(seconds)
    }

    /// «Проверьте, кто говорит, в 3 репликах» (D5): вместо непонятного «3 реплики на проверку».
    static func toReview(_ n: Int) -> String {
        L("Проверьте, кто говорит, в ", "Check who’s speaking in ")
            + L10n.plural(n, ru: "реплике", "репликах", "репликах", en: "place", "places")
    }

    static func samples(_ n: Int) -> String {
        L10n.plural(n, ru: "образец", "образца", "образцов", en: "sample", "samples")
    }
}

/// Место под пометку у строки расшифровки: сам следит за моделью говорящих, пусто — если метка уверенная.
struct SpeakerReviewSlot: View {
    @ObservedObject var speakers: MeetingSpeakersModel
    let meeting: String
    let start: Double
    let speaker: String

    /// Только что решённая пометка: не исчезает молча, а пару секунд говорит, что принято.
    @State private var resolved: String?

    var body: some View {
        if let review = speakers.speakers(meeting).review(start: start, speaker: speaker) {
            SpeakerReviewRow(speakers: speakers, meeting: meeting, review: review) { text in
                withAnimation(.easeOut(duration: 0.15)) { resolved = text }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation(.easeOut(duration: 0.2)) { if resolved == text { resolved = nil } }
                }
            }
        } else if let resolved {
            Label(resolved, systemImage: "checkmark")
                .font(TType.caption).foregroundStyle(Palette.inkSecondary)
                .padding(.horizontal, DS.Space.xs).padding(.vertical, 4)
                .transition(.opacity)
        }
    }
}

/// Панель говорящих, если в расшифровке есть кто-то, кроме «Я».
struct MeetingSpeakersSlot: View {
    @ObservedObject var speakers: MeetingSpeakersModel
    let meeting: String
    var order: [String] = []

    var body: some View {
        if !speakers.speakers(meeting).speakers.isEmpty {
            MeetingSpeakersPanel(speakers: speakers, meeting: meeting, order: order)
        }
    }
}
