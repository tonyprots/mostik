import SwiftUI
import MostikCore

/// Окно меню-бара (MenuBarExtra в стиле .window), ширина 320.
public struct MenuBarContentView: View {
    @ObservedObject var model: AppModel
    @State private var copiedID: String?

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, DS.Space.m)
                .padding(.top, 14)
                .padding(.bottom, DS.Space.s)

            // Идёт запись встречи — раздел записи сверху: окошка внизу экрана нет (решение автора).
            if model.isMeetingRecording {
                MenuMeetingSection(model: model)
                    .padding(.horizontal, DS.Space.xs)
                    .padding(.bottom, DS.Space.xs)
            } else if model.meetingConsentPending {
                consent
                    .padding(.horizontal, DS.Space.xs)
                    .padding(.bottom, DS.Space.xs)
            } else if let app = model.meetingSuggestion, !model.isMeetingRecording {
                suggestion(app)
                    .padding(.horizontal, DS.Space.xs)
                    .padding(.bottom, DS.Space.xs)
            }

            section {
                VStack(spacing: 0) {
                    voiceRow
                    if !model.isMeetingRecording { meetingRow }
                }
            }
            section { recent }
            section(last: true) { footer }
        }
        .frame(width: 320)
        .background(Palette.canvas)
        .background(MenuWindowReader())
    }

    // MARK: Шапка

    private var header: some View {
        HStack(spacing: 10) {
            MostikGlyph(bars: Palette.ink, caret: Palette.accent)
                .frame(width: 20, height: 20)
            Text("Mostik").font(TType.headline).foregroundStyle(Palette.ink)
            Spacer()
            // Состояние движка — в шапке, как раньше; клавиша удержания — у «Записать голос» (решение автора).
            HStack(spacing: 6) {
                StatusDot(color: engine.color)
                Text(engine.text ?? L("Готов", "Ready"))
                    .font(TType.callout)
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .help(engine.text ?? "")
        }
    }

    /// Подсказка у «Записать голос»: «держать правый ⌥». Двойное нажатие — в подсказке при наведении:
    /// по-русски обе не влезают в 320 pt.
    private func doubleHint(ru: Bool) -> String {
        let double = MenuVoice.shortcut(settings: model.settings)
        guard !double.isEmpty else { return "" }
        return ru ? ", без рук — \(double)" : ", hands-free — \(double)"
    }

    private var holdHint: String { L("держать ", "hold ") + HoldKeys.name(model.settings.holdKey) }

    /// Состояние движка — в шапке: готов — «Готов», иначе — что мешает.
    private var engine: (text: String?, color: Color) {
        switch model.engineStatus {
        case .starting: (L("Запуск…", "Starting…"), Palette.inkTertiary)
        case let .loading(what): (what.isEmpty ? L("Загрузка модели…", "Loading model…") : what, Palette.doubt)
        case .ready: (nil, Palette.accent)
        case let .failed(why): (why, Palette.record)
        }
    }

    // MARK: Предложение записать встречу

    private func suggestion(_ app: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(L("Похоже, идёт встреча в \(app)", "Looks like a meeting in \(app)"))
                .font(TType.bodyStrong)
                .foregroundStyle(Palette.ink)
            Text(L("Mostik запишет встречу и подпишет, кто что сказал. Всё останется на этом Mac.",
                   "Mostik records the meeting and labels who said what. Everything stays on this Mac."))
                .font(TType.callout)
                .foregroundStyle(Palette.inkSecondary)
            HStack(spacing: DS.Space.xs) {
                Button(L("Записать", "Record")) { model.onStartMeeting() }
                    .buttonStyle(.mostik(.primary, compact: true))
                Button(L("Нет", "No")) { model.onDismissMeetingSuggestion() }
                    .buttonStyle(.mostik(.quiet, compact: true))
            }
            .padding(.top, DS.Space.xxs)
        }
        .padding(DS.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
    }

    // MARK: Согласие на запись

    private var consent: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(ConsentCopy.title)
                .font(TType.bodyStrong)
                .foregroundStyle(Palette.ink)
            Text(ConsentCopy.short)
                .font(TType.callout)
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.xs) {
                Button(L("Понятно, записывать", "Got it, record")) { model.onAcknowledgeConsent() }
                    .buttonStyle(.mostik(.primary, compact: true))
                Button(L("Отмена", "Cancel")) { model.meetingConsentPending = false }
                    .buttonStyle(.mostik(.quiet, compact: true))
            }
            .padding(.top, DS.Space.xxs)
        }
        .padding(DS.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.recordSoft, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
    }

    // MARK: Голос (D1 из меню)

    /// «Записать голос»: запись без рук, как двойное нажатие; вставка — туда, где стоял курсор до меню.
    /// Меню закрывает и фокус возвращает controller (`onMenuVoice`).
    private var voiceRow: some View {
        let phase = model.menuVoicePhase
        let recording = phase == .recording
        return Button { model.onMenuVoice() } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().strokeBorder(Palette.accent.opacity(0.35), lineWidth: 1.5)
                    if recording {
                        RoundedRectangle(cornerRadius: 1.5).fill(Palette.accent).frame(width: 7, height: 7)
                    } else {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(phase == .busy ? Palette.inkTertiary : Palette.accent)
                    }
                }
                .frame(width: 18, height: 18)
                Text(MenuVoice.title(phase))
                    .font(TType.body)
                    .foregroundStyle(phase == .busy ? Palette.inkSecondary : Palette.ink)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer()
                if MenuVoice.trailing(phase, elapsed: 0) != nil {
                    ClockReader(model.clock) { clock in
                        Text(MenuVoice.trailing(phase, elapsed: clock.elapsed) ?? "")
                            .font(TType.figure(12))
                            .foregroundStyle(Palette.accent)
                    }
                } else if phase == .idle {
                    // Какой клавишей диктовать: держать — и двойное нажатие без рук, если включено.
                    Text(holdHint)
                        .font(TType.callout)
                        .foregroundStyle(Palette.inkTertiary)
                        .lineLimit(1)
                        .accessibilityLabel(L("Держите \(HoldKeys.name(model.settings.holdKey)) для диктовки",
                                              "Hold \(HoldKeys.name(model.settings.holdKey)) to dictate"))
                }
            }
            .padding(.horizontal, DS.Space.xs)
            .frame(height: DS.hit + 2)
        }
        .buttonStyle(RowButtonStyle(radius: DS.Radius.control))
        .disabled(phase == .busy)
        .help(L("Запись без удержания клавиши; текст вставится туда, где стоял курсор. Или держите \(HoldKeys.name(model.settings.holdKey))" + doubleHint(ru: true) + ".",
                "Records without holding a key; the text goes where your cursor was. Or hold \(HoldKeys.name(model.settings.holdKey))" + doubleHint(ru: false) + "."))
    }

    // MARK: Встреча

    /// «Записать встречу»; во время записи её действия — в разделе сверху (`MenuMeetingSection`).
    private var meetingRow: some View {
        Button {
            MenuWindow.close()
            model.onStartMeeting()
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().strokeBorder(Palette.record.opacity(0.35), lineWidth: 1.5)
                    Circle().fill(Palette.record).frame(width: 8, height: 8)
                }
                .frame(width: 18, height: 18)
                Text(L("Записать встречу", "Record meeting"))
                    .font(TType.body)
                    .foregroundStyle(Palette.ink)
                Spacer()
            }
            .padding(.horizontal, DS.Space.xs)
            .frame(height: DS.hit + 2)
        }
        .buttonStyle(RowButtonStyle(radius: DS.Radius.control))
    }

    // MARK: Последние диктовки

    private var recent: some View {
        VStack(alignment: .leading, spacing: 2) {
            GroupLabel(text: L("За сутки", "Last 24 hours"))
                .padding(.horizontal, DS.Space.xs)
                .padding(.bottom, DS.Space.xxs)
            if recentItems.isEmpty {
                Text(L("Пока пусто. Зажмите \(HoldKeys.name(model.settings.holdKey)) и говорите.", "Nothing yet. Hold \(HoldKeys.name(model.settings.holdKey)) and speak."))
                    .font(TType.callout)
                    .foregroundStyle(Palette.inkSecondary)
                    .padding(.horizontal, DS.Space.xs)
                    .padding(.vertical, DS.Space.xxs)
            }
            // R5: последние за сутки; диктовка без текста, но с аудио — расшифровать заново.
            ForEach(recentItems, id: \.id) { row in
                switch row.item {
                case let .dictation(entry): dictationRow(entry)
                case let .meeting(meeting): meetingRow(meeting)
                }
            }
        }
    }

    private func dictationRow(_ entry: HistoryEntry) -> some View {
        Button {
            MenuWindow.close()
            if entry.text.isEmpty { model.onRetranscribe(entry); return }
            model.onCopy(entry.text)
            withAnimation(Motion.quick) { copiedID = entry.id }
        } label: {
            HStack(spacing: DS.Space.s) {
                Text(entry.text.isEmpty ? L("Не расшифровано — повторить", "Not transcribed — retry") : entry.text)
                    .font(TType.body)
                    .foregroundStyle(entry.text.isEmpty ? Palette.inkSecondary : Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: DS.Space.xs)
                if let tag = deliveryTag(entry), copiedID != entry.id {
                    Text(tag)
                        .font(TType.caption)
                        .foregroundStyle(Palette.doubt)
                        .lineLimit(1)
                        .fixedSize()
                }
                Text(copiedID == entry.id ? L("Скопировано", "Copied") : Fmt.time(entry.createdAt))
                    .font(TType.figure(11, .regular))
                    .foregroundStyle(copiedID == entry.id ? Palette.accent : Palette.inkSecondary)
            }
            .padding(.horizontal, DS.Space.xs)
            .frame(height: DS.hit)
        }
        .buttonStyle(RowButtonStyle(radius: DS.Radius.control))
    }

    /// Встреча за сутки: клик открывает её на вкладке «Встречи».
    private func meetingRow(_ meeting: AppModel.MeetingItem) -> some View {
        Button {
            MenuWindow.close()
            model.meetingFocus = MeetingFocus(meeting: meeting.id, at: 0)
            model.selectedTab = .meetings
            model.onOpenMainWindow()
        } label: {
            HStack(spacing: DS.Space.s) {
                Text(meeting.title)
                    .font(TType.body)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: DS.Space.xs)
                if let tag = meetingTag(meeting) {
                    Text(tag.text)
                        .font(TType.caption)
                        .foregroundStyle(tag.color)
                        .lineLimit(1)
                        .fixedSize()
                }
                Text(Fmt.time(meeting.startedAt))
                    .font(TType.figure(11, .regular))
                    .foregroundStyle(Palette.inkSecondary)
            }
            .padding(.horizontal, DS.Space.xs)
            .frame(height: DS.hit)
        }
        .buttonStyle(RowButtonStyle(radius: DS.Radius.control))
    }

    /// Пометка вместо значка: строка встречи выровнена с диктовками, а тип виден справа.
    /// Пока идёт расшифровка или она упала, пометка говорит об этом словами, не только цветом.
    private func meetingTag(_ meeting: AppModel.MeetingItem) -> (text: String, color: Color)? {
        switch meeting.state {
        case .processing:
            let base = L("расшифровка", "transcribing")
            let text = meeting.progress.map { base + " " + MeetingProgressText.percent($0) } ?? base
            return (text, Palette.accent)
        case .failed: return (L("сбой", "failed"), Palette.doubt)
        case .done: return (L("встреча", "meeting"), Palette.inkTertiary)
        case .recording: return nil
        }
    }

    private struct RecentRow {
        let id: String
        let item: RecentDictations.Item<AppModel.MeetingItem>
    }

    /// Идущая запись в список не входит: она и так сверху меню.
    private var recentItems: [RecentRow] {
        RecentDictations.withMeetings(model.history, meetings: model.meetings, startedAt: \.startedAt,
                                      include: { $0.state != .recording })
            .map { item in
                switch item {
                case let .dictation(entry): return RecentRow(id: "d-" + entry.id, item: item)
                case let .meeting(meeting): return RecentRow(id: "m-" + meeting.id, item: item)
                }
            }
    }

    /// Пометка у диктовки, которая не дошла до поля: текст есть только здесь.
    private func deliveryTag(_ entry: HistoryEntry) -> String? {
        if entry.pasteCheck == PasteCheck.notInserted.rawValue { return L("не вставлено", "not inserted") }
        switch entry.outcome {
        case "cancelled": return L("отменено", "cancelled")
        case "command": return L("действие голосом", "voice action")
        case "undone": return L("вставка отменена", "insertion undone")
        case "failed": return L("не вставлено", "not inserted")
        default: return nil
        }
    }

    // MARK: Низ

    private var footer: some View {
        VStack(spacing: 0) {
            menuRow(L("Открыть Mostik", "Open Mostik"), shortcut: "⌘O") { model.onOpenMainWindow() }
            menuRow(L("Настройки…", "Settings…"), shortcut: "⌘,") { model.openSettings(.menu) }
            // Только с настоящим адресом ленты: с заглушкой пункта нет вовсе (UpdatePolicy.showsCheckForUpdates).
            if model.updatesCheckable {
                menuRow(L("Проверить обновления…", "Check for Updates…"), shortcut: "") { model.onCheckForUpdates() }
            }
            menuRow(L("Выйти", "Quit"), shortcut: "⌘Q") { model.onQuit() }
        }
    }

    private func menuRow(_ title: String, shortcut: String, action: @escaping () -> Void) -> some View {
        Button {
            MenuWindow.close()
            action()
        } label: {
            HStack {
                Text(title).font(TType.body).foregroundStyle(Palette.ink)
                Spacer()
                Text(shortcut).font(TType.callout).foregroundStyle(Palette.inkTertiary)
            }
            .padding(.horizontal, DS.Space.xs)
            .frame(height: DS.hit)
        }
        .buttonStyle(RowButtonStyle(radius: DS.Radius.control))
    }

    // Секции разделены линией с отступом, внутри — 8 pt по краям,
    // строки с радиусом 6 под окном с радиусом ~10.
    private func section<C: View>(last: Bool = false, @ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) {
            Hairline(inset: DS.Space.m)
            content()
                .padding(.horizontal, DS.Space.xs)
                .padding(.vertical, DS.Space.xs)
        }
        .padding(.bottom, last ? DS.Space.xxs : 0)
    }
}
