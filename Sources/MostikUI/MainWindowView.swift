import AppKit
import SwiftUI
import MostikCore

/// Главное окно: вкладки сверху, под ними содержимое вкладки. Настройки — последняя вкладка, ⌘, (B1).
public struct MainWindowView: View {
    @ObservedObject var model: AppModel
    // Начальный выбор — для снимков; в приложении выбирается первая запись.
    var initialEntry: String?
    var initialMeeting: String?
    var initialSource: String?

    public init(model: AppModel) {
        self.model = model
    }

    init(model: AppModel, entry: String?, meeting: String? = nil, source: String? = nil) {
        self.model = model
        self.initialEntry = entry
        self.initialMeeting = meeting
        self.initialSource = source
    }

    public var body: some View {
        VStack(spacing: 0) {
            tabBar
            Hairline()
            ModelsGate(models: model.models) { model.openSettings(.modelsNeeded) }
            Group {
                switch model.selectedTab {
                case .dictation: DictationTab(model: model, initial: initialEntry)
                // Ссылка из подсказки, меню или архива открывает встречу на нужной реплике.
                case .meetings: MeetingsTab(model: model, initial: initialMeeting ?? model.meetingFocus?.meeting)
                case .glossary: GlossaryTab(model: model, initial: initialSource)
                case .settings: SettingsWindowView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(Palette.canvas)
        .foregroundStyle(Palette.ink)
        .overlay {
            if model.meetingConsentPending {
                ZStack {
                    // Затемнение тоном чернил, не чёрным: окно остаётся в своей палитре.
                    Palette.ink.opacity(0.18)
                        .contentShape(Rectangle())
                        .onTapGesture {}
                    MeetingConsentSheet(model: model)
                }
                .transition(.opacity)
            }
        }
        .animation(Motion.spring, value: model.meetingConsentPending)
        .background { keyboardShortcuts }
    }

    /// Приложение меню-бара живёт без строки меню, поэтому привычные сочетания окна
    /// заданы здесь: ⌘, — вкладка Настроек, ⌘1…⌘3 — вкладки, ⌘W — закрыть окно.
    private var keyboardShortcuts: some View {
        let tabs: [(AppModel.Tab, KeyEquivalent)] = [(.dictation, "1"), (.meetings, "2"), (.glossary, "3")]
        return ZStack {
            Button("") { model.openSettings(.menu) }
                .keyboardShortcut(",", modifiers: .command)
            ForEach(tabs, id: \.1) { tab, key in
                Button("") { model.selectedTab = tab }  // вкладка — сразу, подложка едет сама (шаг 3, п. 14)
                    .keyboardShortcut(key, modifiers: .command)
            }
            Button("") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: .command)
        }
        .buttonStyle(.plain)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private var tabBar: some View {
        Segmented(options: [
            (AppModel.Tab.dictation, L("Диктовка", "Dictation")),
            (.meetings, L("Встречи", "Meetings")),
            (.glossary, L("Словарь", "Glossary")),
            (.settings, L("Настройки", "Settings")),
        ], selection: $model.selectedTab)
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Space.s)
    }
}

// MARK: - Диктовка

struct DictationTab: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @State private var selectedID: String?

    init(model: AppModel, initial: String?) {
        self.model = model
        _selectedID = State(initialValue: initial ?? model.history.first?.id)
    }

    var body: some View {
        if model.history.isEmpty {
            DictationEmptyState(model: model)
        } else {
            HStack(spacing: 0) {
                listColumn
                    .frame(width: 380)
                Rectangle().fill(Palette.edge).frame(width: 1)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.surface)
            }
            // «Запомнить написание…» из карточки над HUD: открыть эту диктовку (L2).
            .onReceive(model.glossaryLearning.$spellingEntryID) { id in
                if let id, model.history.contains(where: { $0.id == id }) { selectedID = id }
            }
            // Выбранную удалили — показать соседнюю, а не пустую деталь.
            .onChange(of: model.history.map(\.id)) { _, ids in
                if let id = selectedID, !ids.contains(id) { selectedID = ids.first }
            }
        }
    }

    // MARK: Список

    private var filtered: [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.history }
        return model.history.filter { $0.text.lowercased().contains(q) || $0.appName.lowercased().contains(q) }
    }

    private var groups: [(day: Date, entries: [HistoryEntry])] {
        let cal = Calendar.current
        let byDay = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.createdAt) }
        return byDay.keys.sorted(by: >).map { day in
            (day, byDay[day]!.sorted { $0.createdAt > $1.createdAt })
        }
    }

    private var listColumn: some View {
        VStack(spacing: 0) {
            MostikTextField(placeholder: L("Поиск по диктовкам", "Search dictations"), text: $query,
                          leadingSymbol: "magnifyingglass")
                .padding(.horizontal, DS.Space.m)
                .padding(.top, DS.Space.m)
                .padding(.bottom, DS.Space.xs)

            MostikScroll {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                    ForEach(groups, id: \.day) { group in
                        GroupLabel(text: Fmt.dayTitle(group.day),
                                   trailing: "\(group.entries.count)")
                            .padding(.horizontal, DS.Space.s)
                            .padding(.top, DS.Space.s)
                            .padding(.bottom, DS.Space.xxs)
                        ForEach(group.entries) { entry in
                            Button { selectedID = entry.id } label: {
                                HistoryRow(entry: entry)
                            }
                            .buttonStyle(RowButtonStyle(selected: entry.id == selectedID))
                        }
                    }
                    if filtered.isEmpty {
                        Text(L("Ничего не нашлось по «\(query)».", "No dictations match “\(query)”."))
                            .font(TType.callout)
                            .foregroundStyle(Palette.inkSecondary)
                            .padding(DS.Space.s)
                    }
                }
                .padding(.horizontal, DS.Space.xs)
                .padding(.bottom, DS.Space.m)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: Деталь

    @ViewBuilder private var detail: some View {
        if let entry = model.history.first(where: { $0.id == selectedID }) {
            DictationDetail(model: model, entry: entry)
        } else {
            Text(L("Выберите диктовку слева", "Select a dictation"))
                .font(TType.body)
                .foregroundStyle(Palette.inkSecondary)
        }
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.text)
                .font(TType.body)
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                metaText
                    .font(TType.figure(11, .regular))
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                if !entry.doubts.isEmpty {
                    DoubtChip(text: L("\(entry.doubts.count) под вопросом", "\(entry.doubts.count) unsure"),
                              tone: Palette.doubtStrong)
                        .help(entry.doubts.map(\.heard).joined(separator: ", "))
                }
            }
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, 10)
    }

    /// Время · приложение · длительность. Время обработки — в подробностях диктовки.
    private var metaText: Text {
        var parts = [Fmt.time(entry.createdAt)]
        if !entry.appName.isEmpty { parts.append(entry.appName) }
        parts.append(Fmt.clock(entry.audioSeconds))
        return Text(parts.joined(separator: " · "))
    }
}

struct DictationDetail: View {
    @ObservedObject var model: AppModel
    let entry: HistoryEntry
    @State private var copied = false
    @State private var confirmDelete = false
    @Environment(\.mostikSnapshot) private var snapshot

    var body: some View {
        MostikScroll {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    header
                    audioGoneNote
                }
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    // SF 15, межстрочный ≈ 1,35: 18 pt своей строки + 2 pt.
                    DoubtHighlightedText(text: insertedBody, doubts: entry.doubts)
                        .font(TType.reading)
                        .lineSpacing(2)
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .selectableText(!snapshot)
                }
                RememberSpellingSection(learning: model.glossaryLearning, entry: entry, showsOpener: false)
                    .id(entry.id)
                if !entry.doubts.isEmpty { doubts }
                // Раскрывающиеся блоки одной группой с ровным шагом; подробности записи — в «…» (C1).
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    if let raw = rawVersion {
                        Fold(title: L("Как сказано", "As spoken")) {
                            Text(raw)
                                .font(TType.body)
                                .lineSpacing(3)
                                .foregroundStyle(Palette.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .selectableText(!snapshot)
                        }
                    }
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Шапка: куда и когда слева, действия справа (решение автора: кнопки — наверх, в плашку).
    private var header: some View {
        HStack(alignment: .center, spacing: DS.Space.s) {
            place
            Spacer(minLength: DS.Space.s)
            actions
        }
    }

    private var place: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(entry.appName.isEmpty ? L("Без приложения", "No app") : entry.appName)
                .font(TType.bodyStrong)
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            // Без «· ИИ-агент» (C2): название приложения рядом и так говорит, куда ушёл текст.
            Text(Fmt.dayAndTime(entry.createdAt))
                .font(TType.figure(12, .regular))
                .foregroundStyle(Palette.inkSecondary)
        }
        .lineLimit(1)
    }

    // MARK: Текст и строка для ассистента

    /// Что ушло в поле, целиком.
    private var inserted: String { entry.insertedText.isEmpty ? entry.text : entry.insertedText }

    /// Текст записи; у старых записей агентам — без блока слов под вопросом, его больше не вставляем (C4).
    private var insertedBody: String { entry.agent ? DoubtResolution.legacyBody(inserted) : inserted }

    /// Сырой текст модели — только если он отличается от вставленного.
    private var rawVersion: String? {
        guard let raw = entry.rawText?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let same = { (other: String) in other.trimmingCharacters(in: .whitespacesAndNewlines) == raw }
        return same(inserted) || same(insertedBody) || same(entry.text) ? nil : raw
    }

    // MARK: Действия — одна строка

    /// «Копировать» — главное действие; «Распознать снова» — вторичное; редкое — в «…».
    /// «Запомнить написание» для слова без сомнений тоже там: у слов под вопросом своя «Запомнить».
    private var actions: some View {
        HStack(spacing: DS.Space.xs) {
            Button {
                model.onCopy(insertedBody)
                withAnimation(Motion.quick) { copied = true }
            } label: {
                Label(copied ? L("Скопировано", "Copied") : L("Копировать", "Copy"),
                      systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.mostik(.primary, compact: true))
            Button { model.onRetranscribe(entry) } label: {
                Label(L("Распознать снова", "Re-transcribe"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.mostik(.secondary, compact: true))
            .disabled(entry.audioPath == nil)
            MoreMenu(help: L("Ещё для диктовки", "More for this dictation")) {
                Button {
                    withAnimation(Motion.quick) { model.glossaryLearning.spellingEntryID = entry.id }
                } label: {
                    Label(L("Запомнить написание…", "Remember spelling…"), systemImage: "character.book.closed")
                }
                // C1: подробности записи — подменю в «…», а не отдельный раскрывающийся блок.
                Divider()
                Menu {
                    ForEach(factLines, id: \.self) { Text($0) }
                } label: {
                    Label(L("Подробности", "Details"), systemImage: "info.circle")
                }
                Divider()
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label(L("Удалить диктовку…", "Delete dictation…"), systemImage: "trash")
                }
            }
        }
        .fixedSize()
        .confirmationDialog(L("Удалить диктовку?", "Delete this dictation?"), isPresented: $confirmDelete) {
            Button(L("Удалить", "Delete"), role: .destructive) { model.onDeleteEntry(entry) }
        } message: {
            Text(L("Текст и звук удалятся с этого Mac. Вернуть нельзя.", "The text and audio are removed from this Mac. This can’t be undone."))
        }
    }

    /// У неактивной кнопки macOS подсказку не показывает — причина словами под шапкой.
    @ViewBuilder private var audioGoneNote: some View {
        if entry.audioPath == nil {
            Text(model.settings.keepAudio
                 ? L("Распознать снова нельзя: звук хранится сутки, у этой записи его уже нет",
                     "Can’t re-transcribe: audio is kept for a day and this one’s is gone")
                 : L("Распознать снова нельзя: звук диктовок не сохраняется — включается в Настройках",
                     "Can’t re-transcribe: dictation audio isn’t kept — turn it on in Settings"))
                .font(TType.caption)
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Слова под вопросом

    private var doubts: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            GroupLabel(text: L("Слова под вопросом", "Unsure words"), trailing: "\(entry.doubts.count)")
            VStack(spacing: 0) {
                ForEach(Array(entry.doubts.enumerated()), id: \.offset) { i, doubt in
                    if i > 0 { Hairline(inset: DS.Space.s) }
                    doubtRow(doubt)
                }
            }
            .padding(DS.Space.xxs)
            .background(Palette.canvas, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(Palette.edge))
        }
    }

    private func doubtRow(_ doubt: Doubt) -> some View {
        HStack(alignment: .center, spacing: DS.Space.s) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(L("«\(doubt.heard)»", "“\(doubt.heard)”"))
                        .font(TType.bodyStrong)
                        .foregroundStyle(Palette.doubt)
                    if !doubt.suggestion.isEmpty, doubt.suggestion != doubt.heard {
                        Text("→").font(TType.body).foregroundStyle(Palette.inkTertiary)
                        Text(doubt.suggestion).font(TType.bodyStrong).foregroundStyle(Palette.ink)
                    }
                }
                if !doubt.context.isEmpty {
                    Text("…\(doubt.context)…")
                        .font(TType.callout)
                        .foregroundStyle(Palette.inkSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: DS.Space.xs)
            // C5: отказ снимает отметку и больше не предлагает эту пару; принятие правит текст записи
            // и кладёт написание в словарь. Обе строки уходят из списка сразу.
            Button {
                withAnimation(Motion.quick) { model.onRejectDoubt(entry.id, doubt) }
            } label: {
                Label(L("Отклонить", "Dismiss"), systemImage: "xmark")
            }
            .buttonStyle(.mostik(.quiet, compact: true))
            .help(L("Оставить как распознано и больше не предлагать", "Keep it as transcribed and stop suggesting this"))
            Button {
                withAnimation(Motion.quick) {
                    model.onAcceptDoubt(entry.id, doubt.heard, doubt.suggestion.isEmpty ? doubt.heard : doubt.suggestion)
                }
            } label: {
                Label(L("Запомнить", "Remember"), systemImage: "checkmark")
            }
            .buttonStyle(.mostik(.secondary, compact: true))
            .help(doubt.suggestion.isEmpty || doubt.suggestion == doubt.heard
                  ? L("Так и писать дальше", "Keep this spelling from now on")
                  : L("Исправить текст и писать так дальше", "Fix the text and spell it this way from now on"))
        }
        .padding(.leading, DS.Space.s)
        .padding(.trailing, DS.Space.xxs)
        .padding(.vertical, 10)
    }

    private var corrections: some View {
        FlowLayout(spacing: DS.Space.s, lineSpacing: 6) {
            ForEach(Array(entry.corrections.enumerated()), id: \.offset) { _, c in
                HStack(spacing: 6) {
                    Text(c.from).strikethrough(color: Palette.inkTertiary).foregroundStyle(Palette.inkSecondary)
                    Text("→").foregroundStyle(Palette.inkTertiary)
                    Text(c.to).font(TType.code).foregroundStyle(Palette.ink)
                }
                .font(TType.callout)
            }
        }
    }

    // MARK: Подробности записи — строками подменю «…»

    private var factLines: [String] {
        [
            L("Длительность ", "Length ") + Fmt.clock(entry.audioSeconds),
            L("Распознано за ", "Transcribed in ") + Fmt.latency(entry.latencyMs),
            L("Язык ", "Language ") + entry.language.uppercased(),
            outcome.prefix(1).uppercased() + outcome.dropFirst(),
            verifier.prefix(1).uppercased() + verifier.dropFirst(),
        ].filter { !$0.isEmpty }
    }

    private var outcome: String {
        if entry.pasteCheck == "not_inserted" { return L("не вставлено", "not inserted") }
        return switch entry.outcome {
        case "inserted": L("вставлено", "inserted")
        case "cancelled": L("отменено", "cancelled")
        case "command": L("действие голосом — черновик", "voice action — draft")
        case "undone": L("вставка отменена", "insertion undone")
        case "clipboard": L("в буфере обмена", "on the clipboard")
        case "secure_input": L("защищённое поле", "secure field")
        default: L("не вставлено", "not inserted")
        }
    }

    private var verifier: String {
        switch entry.verifier {
        case "done": L("второе распознавание терминов", "second pass for terms")
        // Движок пишет `late` (проверяющая не успела к сроку); `timeout` — в старых записях.
        case "timeout", "late": L("второе распознавание не успело", "second pass ran out of time")
        case "off": ""
        default: entry.verifier
        }
    }
}

/// Текст диктовки, где слова под вопросом подчёркнуты пунктиром и тонированы охрой —
/// прямо в строке, а не отдельным списком.
struct DoubtHighlightedText: View {
    let text: String
    let doubts: [Doubt]

    var body: some View {
        Text(attributed)
            .accessibilityLabel(text)
            .accessibilityHint(doubts.isEmpty ? "" : L("Слова под вопросом: ", "Unsure words: ")
                               + doubts.map { $0.suggestion.isEmpty ? $0.heard : $0.suggestion }.joined(separator: ", "))
    }

    private var attributed: AttributedString {
        var result = AttributedString(text)
        for doubt in doubts {
            for needle in [doubt.suggestion, doubt.heard] where !needle.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let range = result.range(of: needle, options: .caseInsensitive) else { continue }
                result[range].foregroundColor = Palette.doubt
                result[range].backgroundColor = Palette.doubtSoft
                result[range].underlineStyle = Text.LineStyle(pattern: .dot, color: Palette.doubt)
                break
            }
        }
        return result
    }
}

/// Раскрывающийся блок без рамки: шеврон, заголовок, по нажатию — содержимое.
/// Свой, а не `DisclosureGroup`: AppKit-контрол не рисуется в снимках.
struct Fold<Content: View>: View {
    let title: String
    var trailing: String? = nil
    var symbol: String? = nil
    var quiet = false
    @ViewBuilder var content: Content
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Button { withAnimation(Motion.spring) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 12)
                    if let symbol {
                        Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                    }
                    Text(title)
                        .font(quiet ? TType.callout : TType.calloutStrong)
                        .multilineTextAlignment(.leading)
                    if let trailing {
                        Text(trailing).font(TType.figure(11, .regular)).foregroundStyle(Palette.inkTertiary)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Palette.inkSecondary)
                .frame(minHeight: DS.hit)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? L("развёрнуто", "expanded") : L("свёрнуто", "collapsed"))
            if open {
                content
                    .padding(.leading, 18)
                    .transition(.opacity)
            }
        }
    }
}

/// Пустая история учит главному жесту: зажать клавишу записи и говорить.
struct DictationEmptyState: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: DS.Space.l) {
            // Только клавиша записи из Настроек: декоративные соседи (⌘, ←) путали, на что жать.
            HStack(spacing: DS.Space.s) {
                ForEach(HoldKeys.emptyStateCaps(model.settings.holdKey), id: \.symbol) { cap in
                    KeyCap(symbol: cap.symbol, caption: cap.caption, size: 52, pressed: true)
                        .overlay(alignment: .top) {
                            LevelWave(levels: [0.2, 0.5, 0.9, 0.6, 0.3, 0.7, 0.4], color: Palette.accent,
                                      barWidth: 3, spacing: 3, height: 22)
                                .offset(y: -36)
                        }
                }
            }
            .padding(.top, 36)
            VStack(spacing: DS.Space.xs) {
                Text(L("Зажмите \(HoldKeys.name(model.settings.holdKey)) и говорите", "Hold \(HoldKeys.name(model.settings.holdKey)) and speak"))
                    .font(TType.title)
                Text(L("Отпустите — текст встанет туда, где курсор.",
                       "Let go and the text lands at the cursor."))
                    .font(TType.body)
                    .foregroundStyle(Palette.inkSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(L("Открыть настройки клавиши", "Hotkey settings")) { model.openSettings(.hotkey) }
            .buttonStyle(.mostikSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, DS.Space.xxl)
    }
}
