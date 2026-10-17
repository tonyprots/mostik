import SwiftUI
import MostikCore

// Встречи этапа A: раздел записи в меню строки меню (M3), пометки по ходу (M1),
// предупреждение о согласии участников (M4).

// MARK: - Пометки в расшифровке

extension AppModel.TranscriptLine {
    /// Строка-пометка: движок пишет её в transcript.md как `> 📌 MM:SS — текст`;
    /// controller может передать её как реплику с говорящим «📌» или с этим текстом.
    public var isMark: Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return speaker == "📌" || t.hasPrefix("📌") || t.hasPrefix("> 📌")
    }

    /// Текст пометки без `> 📌 MM:SS — `.
    public var markText: String {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix(">") { t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if t.hasPrefix("📌") { t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if let range = t.range(of: #"^\d{1,2}:\d{2}(:\d{2})?\s*[—–-]\s*"#, options: .regularExpression) {
            t.removeSubrange(range)
        }
        return t
    }
}

enum ConsentCopy {
    static var title: String { L("Перед записью встречи", "Before you record a meeting") }
    static var body: String {
        L("Mostik запишет звук системы и микрофон и расшифрует запись на этом Mac. Предупредите участников, что встреча записывается, и получите их согласие: за это отвечаете вы.",
          "Mostik records system audio and your mic and transcribes them on this Mac. Tell everyone the meeting is being recorded and get their consent: that part is on you.")
    }
    static var short: String {
        L("Записываете встречу — предупредите участников и получите их согласие.",
          "Recording a meeting? Tell the participants and get their consent.")
    }
}

// MARK: - Запись встречи в меню строки меню (M3)

/// Раздел «Запись встречи · 12:34» сверху меню строки меню (решение автора): окошка внизу
/// экрана больше нет, всё его содержимое здесь — состояние и волна, последние пометки и поле пометки,
/// слайды звонка (если включены в Настройках), пауза и главная кнопка «Завершить». Логика — `MeetingMenu`.
struct MenuMeetingSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var assist: MeetingAssistModel
    @ObservedObject var extras: MeetingExtrasModel

    init(model: AppModel) {
        self.model = model
        assist = model.meetingAssist
        extras = model.meetingExtras
    }

    var body: some View {
        let state = model.meetingMenuState
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            header(state)
            marks
            MeetingMarkField(model: model)
            // «Только текст» здесь не показываем (D4): он задаётся в Настройках, где объяснён.
            // Слайды звонка — на эту запись, включаются и выключаются посреди встречи.
            Toggle(isOn: Binding(get: { assist.framesConsent }, set: { _ in assist.onToggleFrames() })) {
                toggleLabel(MeetingMenu.framesTitle(on: assist.framesConsent, count: assist.framesCount))
            }
            .toggleStyle(MostikToggleStyle())
            // Кому доступна запись — переключается посреди встречи, как в «…» у встречи в главном окне.
            if let live = model.meetings.first(where: { $0.state == .recording }) {
                Toggle(isOn: Binding(get: { extras.sensitive.contains(live.id) },
                                     set: { extras.onSetSensitive(live.id, $0) })) {
                    toggleLabel(L("Только на этом Mac — без Claude, агентов и скриптов",
                                  "This Mac only — no Claude, agents or scripts"))
                }
                .toggleStyle(MostikToggleStyle())
            }
            buttons(state)
        }
        .padding(DS.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.recordSoft, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .animation(Motion.spring, value: model.meetingPaused)
    }

    // «● Запись встречи · 12:34» и волна: время перерисовывается раз в секунду только у подписи.
    private func header(_ state: MeetingMenu.State) -> some View {
        let paused = state == .paused
        return HStack(spacing: DS.Space.xs) {
            Circle()
                .fill(paused ? Palette.inkTertiary : Palette.record)
                .frame(width: 8, height: 8)
            ClockReader(model.clock) { clock in
                Text(MeetingMenu.title(state, elapsed: clock.meetingElapsed) ?? "")
                    .font(TType.bodyStrong)
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
            }
            Spacer(minLength: DS.Space.xs)
            MeterReader(model.meter) { levels in
                LevelWave(levels: paused ? Array(repeating: 0, count: 14) : Array(levels.suffix(14)),
                          color: Palette.record, barWidth: 2, spacing: 2, height: 16)
            }
                .frame(width: 54)
                .opacity(paused ? 0.3 : 0.85)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var marks: some View {
        let recent = MeetingMenu.recentMarks(model.meetingMarks)
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                ForEach(recent) { mark in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                        Text(Fmt.clock(mark.at))
                            .font(TType.figure(11, .regular))
                            .foregroundStyle(Palette.inkSecondary)
                            .frame(width: 38, alignment: .leading)
                        Text(mark.text)
                            .font(TType.callout)
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
    }

    private func toggleLabel(_ title: String) -> some View {
        Text(title)
            .font(TType.callout)
            .foregroundStyle(Palette.ink)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func buttons(_ state: MeetingMenu.State) -> some View {
        HStack(spacing: DS.Space.xs) {
            ForEach(MeetingMenu.actions(state), id: \.self) { action in
                Button { perform(action) } label: {
                    Label(MeetingMenu.label(action), systemImage: symbol(action))
                        .frame(maxWidth: action == .finish ? .infinity : nil)
                }
                .buttonStyle(.mostik(action == .finish ? .primary : .secondary, compact: true))
                .help(MeetingMenu.help(action))
            }
        }
    }

    private func symbol(_ action: MeetingMenu.Action) -> String {
        switch action {
        case .pause: "pause.fill"
        case .resume: "play.fill"
        case .finish: "stop.fill"
        }
    }

    private func perform(_ action: MeetingMenu.Action) {
        switch action {
        case .pause, .resume: model.onToggleMeetingPause()
        // Тот же путь, что прежняя «Остановить запись встречи»: меню закрывается, встреча сохраняется.
        case .finish:
            MenuWindow.close()
            model.onStopMeeting()
        }
    }
}

// MARK: - Поле пометки в окне встречи

/// То же действие, что в пилюле, для окна «Встречи», пока идёт запись.
struct MeetingMarkField: View {
    @ObservedObject var model: AppModel
    @State private var draft = ""
    @Environment(\.mostikSnapshot) private var snapshot

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: "pin")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.inkTertiary)
            Group {
                if snapshot {
                    Text(L("Короткая пометка к \(Fmt.clock(model.clock.meetingElapsed))", "Quick mark at \(Fmt.clock(model.clock.meetingElapsed))"))
                        .foregroundStyle(Palette.inkTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ClockReader(model.clock) { clock in
                        TextField(L("Короткая пометка к \(Fmt.clock(clock.meetingElapsed))", "Quick mark at \(Fmt.clock(clock.meetingElapsed))"),
                                  text: $draft)
                    }
                        .textFieldStyle(.plain)
                        .foregroundStyle(Palette.ink)
                        .onSubmit {
                            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { return }
                            model.onAddMeetingMark(text)
                            draft = ""
                        }
                }
            }
            .font(TType.body)
            .lineLimit(1)
            Text("⏎").font(TType.callout).foregroundStyle(Palette.inkTertiary)
        }
        .padding(.horizontal, 10)
        .frame(height: DS.controlHeight)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(Palette.edgeStrong))
    }
}

/// Пометка в списке: время акцентом, булавка, текст полужирным — веха среди реплик
/// без подложки (П9-B: без карточек внутри раздела).
struct MarkLine: View {
    let at: TimeInterval
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            // Один акцент на строку (R3a): булавка акцентом, таймкод — вторичным, как в расшифровке.
            Text(Fmt.clock(at))
                .font(TType.figure(12, .regular))
                .foregroundStyle(Palette.inkSecondary)
                .frame(width: 40, alignment: .trailing)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                Text(text)
                    .font(TType.bodyStrong)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.trailing, DS.Space.s)
    }
}

// MARK: - Согласие участников (M4)

/// Лист-предупреждение перед первой записью встречи.
/// «Понятно, записывать» → `onAcknowledgeConsent`, «Отмена» снимает флаг.
public struct MeetingConsentSheet: View {
    @ObservedObject var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(alignment: .center, spacing: DS.Space.s) {
                ZStack {
                    Circle().strokeBorder(Palette.record.opacity(0.35), lineWidth: 1.5)
                    Circle().fill(Palette.record).frame(width: 8, height: 8)
                }
                .frame(width: 20, height: 20)
                Text(ConsentCopy.title).font(TType.headline).foregroundStyle(Palette.ink)
            }
            Text(ConsentCopy.body)
                .font(TType.body)
                .lineSpacing(3)
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L("Больше не спросим. Напоминаний во время записи не будет.",
                   "We won’t ask again, and there are no reminders during recording."))
                .font(TType.callout)
                .foregroundStyle(Palette.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.xs) {
                // Текст предупреждения для чата встречи (W19).
                CopyWarningButton(model: model)
                Spacer()
                Button(L("Отмена", "Cancel")) { model.meetingConsentPending = false }
                    .buttonStyle(.mostik(.quiet))
                    .keyboardShortcut(.cancelAction)
                Button(L("Понятно, записывать", "Got it, record")) { model.onAcknowledgeConsent() }
                    .buttonStyle(.mostikPrimary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, DS.Space.xxs)
        }
        .padding(DS.Space.l)
        .frame(width: 440)
        // Направленная тень только у подложки, от одного источника сверху:
        // у текста и кнопок внутри своей тени нет.
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card + 4, style: .continuous)
                .fill(Palette.surface)
                .shadow(color: .black.opacity(0.14), radius: 10, y: 6)
        )
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card + 4, style: .continuous).strokeBorder(Palette.edgeStrong))
    }
}
