import SwiftUI
import MostikCore

// Вкладка «Словарь» (S5): слева источники словаря сессии, справа — термины
// выбранного источника с происхождением. Личный словарь — один из источников,
// его правка открывается справа, как у остальных.

extension AppModel.TermItem {
    /// Откуда термин: "calendar", "personal" или "file".
    static func originKind(_ origin: String) -> String {
        let o = origin.lowercased()
        if o.hasPrefix("календарь") || o.hasPrefix("calendar") { return "calendar" }
        if o == "личный словарь" || o == "personal glossary" || o == "personal" { return "personal" }
        return "file"
    }

    public var fromFiles: Bool { origins.contains { Self.originKind($0) == "file" } }
    public var fromCalendar: Bool { origins.contains { Self.originKind($0) == "calendar" } }
}

extension AppModel {
    /// Самое свежее сканирование среди источников.
    public var lastScan: Date? { sources.compactMap(\.scannedAt).max() }

    /// Термины без скрытых пользователем: именно они идут в подсказку распознаванию.
    public var visibleTerms: [TermItem] {
        let hidden = Set(settings.hiddenTerms)
        return hidden.isEmpty ? terms : terms.filter { !hidden.contains($0.term) }
    }

    func hideTerm(_ term: String, _ hidden: Bool) {
        var s = settings
        s.hiddenTerms.removeAll { $0 == term }
        if hidden { s.hiddenTerms.append(term) }
        onUpdateSettings(s)
    }

    /// F4: «Удалить» у любого термина. Слово личного словаря стирается из него; слово из проекта,
    /// папок или календаря попадает в список удалённых и не возвращается при пересканировании.
    func deleteTerm(_ term: TermItem) {
        if let item = glossary.first(where: { $0.canonical == term.term }) { onForget(item) }
        if term.fromFiles || term.fromCalendar { hideTerm(term.term, true) }
    }

    /// Термины словаря сессии по видам: по списку уникальных терминов, чтобы термин из кода
    /// и из заметок не считался дважды; сумма по источникам — только пока списка нет.
    public var termCountsByKind: [String: Int] {
        var counts: [String: Int] = [:]
        if !terms.isEmpty {
            for term in visibleTerms { counts[term.kind, default: 0] += 1 }
            return counts
        }
        for source in sources { for (k, v) in source.counts { counts[k, default: 0] += v } }
        return counts
    }
}

struct GlossaryTab: View {
    @ObservedObject var model: AppModel
    @State private var selection: String

    /// "all" или `SourceItem.id`.
    init(model: AppModel, initial: String? = nil) {
        self.model = model
        _selection = State(initialValue: initial ?? "all")
    }

    /// Источники в постоянном порядке; календарь и личный словарь есть всегда,
    /// даже пока движок о них не рассказал: их можно включить и править.
    private var shown: [AppModel.SourceItem] {
        let order = ["repo": 0, "docs": 1, "calendar": 2, "personal": 3]
        var list = model.sources
        if !list.contains(where: { $0.kind == "calendar" }) {
            list.append(.init(kind: "calendar", label: L("Календарь", "Calendar")))
        }
        if !list.contains(where: { $0.kind == "personal" }) {
            list.append(.init(kind: "personal", label: L("Личный словарь", "Personal glossary"),
                              total: model.glossary.count))
        }
        return list.enumerated().sorted {
            (order[$0.element.kind] ?? 9, $0.offset) < (order[$1.element.kind] ?? 9, $1.offset)
        }.map(\.element)
    }

    var body: some View {
        HStack(spacing: 0) {
            SourcesColumn(model: model, sources: shown, selection: $selection)
                .frame(width: 380)
            Rectangle().fill(Palette.edge).frame(width: 1)
            Group {
                if let source = shown.first(where: { $0.id == selection }) {
                    if source.kind == "personal" {
                        PersonalGlossaryDetail(model: model)
                    } else {
                        TermsDetail(model: model, source: source)
                    }
                } else {
                    TermsDetail(model: model, source: nil)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Palette.surface)
        }
    }
}

// MARK: - Колонка источников

private struct SourcesColumn: View {
    @ObservedObject var model: AppModel
    let sources: [AppModel.SourceItem]
    @Binding var selection: String

    var body: some View {
        VStack(spacing: 0) {
            CompositionCard(model: model)
                .padding(.horizontal, DS.Space.m)
                .padding(.top, DS.Space.m)
                .padding(.bottom, DS.Space.s)
            MostikScroll {
                VStack(alignment: .leading, spacing: 2) {
                    GroupLabel(text: L("Источники", "Sources"), trailing: "\(sources.count)")
                        .padding(.horizontal, DS.Space.s)
                        .padding(.top, DS.Space.xs)
                        .padding(.bottom, DS.Space.xxs)
                    SourceRow(symbol: "square.stack.3d.up", title: L("Все термины", "All terms"),
                              subtitle: Text(L("Слова, которые Mostik узнаёт в речи", "Words Mostik listens for")),
                              trailing: model.terms.isEmpty ? nil : "\(model.visibleTerms.count)",
                              selected: selection == "all") { selection = "all" }
                    ForEach(sources) { source in
                        row(source)
                    }
                    if !sources.contains(where: { $0.kind == "repo" }) {
                        noProjectHint
                    }
                    Button { model.onAddSource(nil) } label: {
                        Label(L("Добавить папку", "Add folder"), systemImage: "plus")
                    }
                    .buttonStyle(.mostik(.quiet, compact: true))
                    .padding(.leading, DS.Space.xxs)
                    .padding(.top, DS.Space.xs)
                }
                .padding(.horizontal, DS.Space.xs)
                .padding(.bottom, DS.Space.m)
            }
        }
    }

    @ViewBuilder private func row(_ source: AppModel.SourceItem) -> some View {
        let selected = selection == source.id
        switch source.kind {
        case "repo":
            SourceRow(symbol: "chevron.left.forwardslash.chevron.right", title: source.label,
                      subtitle: source.auto
                        ? Text(L("определён автоматически", "detected automatically")).foregroundColor(Palette.accent)
                        : Text(L("указан вручную", "set manually")),
                      trailing: "\(source.total)", selected: selected) { selection = source.id }
        case "docs":
            SourceRow(symbol: "folder", title: source.label,
                      subtitle: Text(shortPath(source.path) ?? ""), subtitleHelp: tilde(source.path),
                      trailing: "\(source.total)", selected: selected,
                      remove: { model.onRemoveSource(source) }) { selection = source.id }
        case "calendar":
            SourceRow(symbol: "calendar", title: L("Календарь", "Calendar"),
                      subtitle: Text(model.settings.calendarEnabled
                                     ? L("встречи и участники за ±7 дней", "meetings and attendees, ±7 days")
                                     : L("выключен", "off")),
                      trailing: nil, selected: selected,
                      toggle: Binding(get: { model.settings.calendarEnabled },
                                      set: { model.onSetCalendarEnabled($0) })) { selection = source.id }
        default:
            SourceRow(symbol: "character.book.closed", title: L("Личный словарь", "Personal glossary"),
                      subtitle: Text(L("ваши слова и выученное из правок", "your words and learned fixes")),
                      trailing: "\(max(source.total, model.glossary.count))", selected: selected) { selection = source.id }
        }
    }

    private var noProjectHint: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(L("Проект определится сам, когда вы надиктуете в терминале, Cursor или VS Code с агентом.",
                   "The project is detected when you dictate into a terminal, Cursor or VS Code running an agent."))
                .font(TType.callout)
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L("Указать вручную…", "Set manually…")) { model.onChooseProject(nil) }
                .buttonStyle(.mostik(.quiet, compact: true))
                .padding(.leading, -10)
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.top, DS.Space.xs)
    }
}

/// Символ вида термина (13 pt у строки, в легенде — тоном вида): форма, а не только цвет.
func kindSymbol(_ kind: String) -> String {
    switch kind {
    case "person": "person"
    case "project": "shippingbox"
    case "tech": "wrench.and.screwdriver"
    case "acronym": "character.textbox"
    // F4: тот же знак, что у источника-проекта: слово пришло из кода.
    default: "chevron.left.forwardslash.chevron.right"
    }
}

/// Похоже на идентификатор из кода: `warm_mic`, `HistoryStore`, `src/engine`, `app.mostik`.
/// Только такие слова пишем моноширинным; имена людей и названия — обычным шрифтом.
func looksLikeIdentifier(_ word: String) -> Bool {
    if word.contains(" ") { return false }
    if word.contains(where: { "_./:#".contains($0) }) { return true }
    // camelCase: строчная, за ней заглавная, за ней снова строчная («DictationMachine», не «GigaAM»).
    let chars = Array(word)
    guard chars.count >= 3 else { return false }
    for i in 1..<(chars.count - 1) where chars[i].isUppercase && chars[i - 1].isLowercase && chars[i + 1].isLowercase {
        return true
    }
    return false
}

func tilde(_ path: String?) -> String? {
    guard let path, !path.isEmpty else { return nil }
    return NSString(string: path).abbreviatingWithTildeInPath
}

/// Путь коротко: две последние папки («Notes/Mostik»); полный — в подсказке рядом.
func shortPath(_ path: String?) -> String? {
    guard let path, !path.isEmpty else { return nil }
    let parts = URL(fileURLWithPath: path).pathComponents.filter { $0 != "/" }
    return parts.suffix(2).joined(separator: "/")
}

/// Откуда термин, коротко: файл без папок и строки («HistoryStore.swift»), остальное как есть.
func shortOrigin(_ origin: String) -> String {
    switch AppModel.TermItem.originKind(origin) {
    case "calendar":
        // «календарь: Планёрка» → «Календарь · Планёрка»
        let title = origin.split(separator: ":", maxSplits: 1).dropFirst().first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return title.isEmpty ? L("Календарь", "Calendar") : L("Календарь · ", "Calendar · ") + title
    case "personal": return L("Личный словарь", "Personal glossary")
    default: break
    }
    let file = origin.split(separator: "/").last.map(String.init) ?? origin
    if let colon = file.lastIndex(of: ":"), Int(file[file.index(after: colon)...]) != nil {
        return String(file[..<colon])
    }
    return file
}

/// Строка источника. Не кнопка целиком: внутри бывает переключатель
/// и кнопка удаления, а вложенные кнопки в SwiftUI ломают нажатия.
private struct SourceRow: View {
    let symbol: String
    let title: String
    let subtitle: Text
    var subtitleHelp: String? = nil
    let trailing: String?
    let selected: Bool
    var remove: (() -> Void)? = nil
    var toggle: Binding<Bool>? = nil
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(selected ? Palette.accent : Palette.inkSecondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(TType.bodyStrong)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                subtitle
                    .font(TType.caption)
                    .foregroundColor(Palette.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(subtitleHelp ?? "")
            }
            Spacer(minLength: DS.Space.xs)
            // Удаление появляется на месте счётчика при наведении:
            // колонка чисел остаётся ровной у всех строк.
            ZStack(alignment: .trailing) {
                if let trailing {
                    Text(trailing)
                        .font(TType.figure(12, .regular))
                        .foregroundStyle(Palette.inkSecondary)
                        .opacity(remove != nil && hovering ? 0 : 1)
                }
                if let remove, hovering {
                    Button(action: remove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.inkSecondary)
                            .frame(width: DS.hit, height: DS.hit)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(RowButtonStyle(radius: DS.Radius.control))
                    .padding(.trailing, -8)
                    .iconHelp(L("Убрать источник", "Remove source"))
                }
            }
            if let toggle {
                Toggle("", isOn: toggle)
                    .toggleStyle(MostikToggleStyle())
                    .labelsHidden()
                    .fixedSize()
                    .help(L("Брать имена и названия встреч из Календаря", "Use meeting titles and names from Calendar"))
            }
        }
        .padding(.leading, DS.Space.s)
        .padding(.trailing, DS.Space.s)
        .frame(minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                .fill(selected ? Palette.selection : (hovering ? Palette.hover : .clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
    }
}

/// Состав словаря одной полосой: доля каждого вида, легенда со счётчиками
/// и строка свежести «просканировано N ч назад · Пересканировать».
private struct CompositionCard: View {
    @ObservedObject var model: AppModel

    static func tone(_ kind: String) -> Color {
        switch kind {
        case "person": Palette.speakers[3]
        case "project": Palette.speakers[1]
        case "tech": Palette.accent
        case "acronym": Palette.speakers[2]
        default: Palette.inkTertiary
        }
    }

    var body: some View {
        let counts = model.termCountsByKind
        let total = counts.values.reduce(0, +)
        VStack(alignment: .leading, spacing: DS.Space.s) {
            usedCaption(total: total)
                .font(TType.body)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
            .help(L("Mostik узнаёт эти слова в речи и пишет их правильно. Слово из нескольких источников считается один раз; удалённые не считаются.",
                    "Mostik listens for these words and spells them right. A word found in several sources counts once; deleted words don’t count."))
            bar(counts, total: total)
            if total > 0 { KindLegend(counts: counts) }
            Hairline().padding(.top, 2)
            freshness
        }
        .padding(DS.Space.s)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(Palette.edge))
    }

    /// F6: «Mostik узнаёт 2221 слово» — одно число, полужирным. Сумма по источникам с повторами
    /// («из 2249 найденных») убрана: она читалась как отбор «самых частых», которого нет.
    private func usedCaption(total: Int) -> Text {
        let n = Text("\(total)").font(TType.figure(13, .semibold))
        let words = total % 10 == 1 && total % 100 != 11 ? "слово"
            : ((2...4).contains(total % 10) && !(12...14).contains(total % 100) ? "слова" : "слов")
        return Text(L("Mostik узнаёт в речи ", "Mostik listens for ")) + n
            + Text(L(" \(words)", total == 1 ? " word" : " words"))
    }

    /// Доли видов встык с зазором 2 pt; пока данных нет — пустая дорожка.
    private func bar(_ counts: [String: Int], total: Int) -> some View {
        GeometryReader { geo in
            let kinds = Fmt.kinds.filter { (counts[$0] ?? 0) > 0 }
            let gaps = CGFloat(max(kinds.count - 1, 0)) * 2
            HStack(spacing: 2) {
                if total == 0 {
                    Capsule().fill(Palette.sunken)
                } else {
                    ForEach(kinds, id: \.self) { kind in
                        Capsule()
                            .fill(Self.tone(kind))
                            .frame(width: max(4, (geo.size.width - gaps) * CGFloat(counts[kind] ?? 0) / CGFloat(total)))
                    }
                }
            }
        }
        .frame(height: 6)
    }

    @ViewBuilder private var freshness: some View {
        if model.sourcesScanning {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Сканирую источники…", "Scanning sources…"))
                    .font(TType.callout)
                    .foregroundStyle(Palette.accent)
                IndeterminateBar()
            }
            .frame(minHeight: DS.hit)
        } else {
            HStack(spacing: 6) {
                Text(model.lastScan.map { L("Просканировано ", "Scanned ") + Fmt.ago($0) }
                     ?? L("Ещё не сканировалось", "Not scanned yet"))
                    .font(TType.callout)
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(1)
                Text("·").font(TType.callout).foregroundStyle(Palette.inkTertiary)
                Button(L("Пересканировать", "Rescan")) { model.onRescanSources() }
                    .buttonStyle(.mostik(.quiet, compact: true))
                    .padding(.leading, -10)
                Spacer(minLength: 0)
            }
        }
    }
}

/// Счётчики по видам: точка тона вида, название, число.
private struct KindLegend: View {
    let counts: [String: Int]

    var body: some View {
        FlowLayout(spacing: DS.Space.s, lineSpacing: 4) {
            ForEach(Fmt.kinds.filter { (counts[$0] ?? 0) > 0 }, id: \.self) { kind in
                HStack(spacing: 5) {
                    Image(systemName: kindSymbol(kind))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CompositionCard.tone(kind))
                        .accessibilityHidden(true)
                    Text(Fmt.kindTitle(kind)).foregroundStyle(Palette.inkSecondary)
                    Text("\(counts[kind] ?? 0)").font(TType.figure(11, .medium)).foregroundStyle(Palette.ink)
                }
                .font(TType.caption)
                .help(Fmt.kindHelp(kind))
            }
        }
    }
}

// MARK: - Термины

private struct TermsDetail: View {
    @ObservedObject var model: AppModel
    /// nil — все термины.
    let source: AppModel.SourceItem?
    @State private var query = ""
    @State private var kind = "all"
    @State private var added: String?
    @Environment(\.mostikSnapshot) private var snapshot

    private var scoped: [AppModel.TermItem] {
        switch source?.kind {
        case nil: model.visibleTerms
        case "calendar": model.visibleTerms.filter(\.fromCalendar)
        default: model.visibleTerms.filter(\.fromFiles)
        }
    }

    /// Скрытые термины этого источника — для строки «Вернуть».
    private var hiddenHere: [String] {
        let hidden = Set(model.settings.hiddenTerms)
        return model.terms.filter { hidden.contains($0.term) && (source == nil
            || (source?.kind == "calendar" ? $0.fromCalendar : $0.fromFiles)) }.map(\.term)
    }

    private var filtered: [AppModel.TermItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return scoped.filter { term in
            (kind == "all" || term.kind == kind)
                && (q.isEmpty || term.term.lowercased().contains(q) || term.origins.contains { $0.lowercased().contains(q) })
        }
    }

    var body: some View {
        MostikScroll {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                header
                if source?.kind == "calendar" && !model.settings.calendarEnabled {
                    calendarOff
                } else {
                    findOrAdd
                    if scoped.isEmpty { emptyState } else { list }
                }
                if !hiddenHere.isEmpty { hiddenLine }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Шапка

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(meta)
                    .font(TType.figure(12, .regular))
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(tilde(source?.path) ?? "")
                Text(title).font(TType.title)
            }
            if let source, !source.counts.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                    Text(Fmt.terms(source.total))
                        .font(TType.figure(12, .medium))
                        .foregroundStyle(Palette.ink)
                        .fixedSize()
                    KindLegend(counts: source.counts)
                }
            }
            actions
                .padding(.top, DS.Space.xxs)
        }
    }

    private var title: String {
        switch source?.kind {
        case nil: L("Все термины", "All terms")
        case "calendar": L("Календарь", "Calendar")
        default: source?.label ?? ""
        }
    }

    private var meta: String {
        if let path = shortPath(source?.path) { return L("Папка ", "Folder ") + path }
        if source?.kind == "calendar" {
            return L("Встречи с двумя и более участниками · данные не покидают Mac",
                     "Meetings with two or more people · nothing leaves this Mac")
        }
        return L("Проект, папки, календарь и личный словарь вместе", "Project, folders, calendar and personal glossary together")
    }

    @ViewBuilder private var actions: some View {
        switch source?.kind {
        case "repo":
            HStack(spacing: DS.Space.xs) {
                if source?.auto == true {
                    Label(L("Определён по активному окну", "Detected from the active window"), systemImage: "scope")
                        .font(TType.callout)
                        .foregroundStyle(Palette.accent)
                        .padding(.trailing, DS.Space.xs)
                }
                Button(L("Заменить папку…", "Replace folder…")) { model.onChooseProject(nil) }
                    .buttonStyle(.mostik(.secondary, compact: true))
                if let path = source?.path {
                    Button(L("Показать в Finder", "Show in Finder")) { model.onRevealInFinder(URL(fileURLWithPath: path)) }
                        .buttonStyle(.mostik(.secondary, compact: true))
                }
            }
        case "docs":
            HStack(spacing: DS.Space.xs) {
                if let path = source?.path {
                    Button(L("Показать в Finder", "Show in Finder")) { model.onRevealInFinder(URL(fileURLWithPath: path)) }
                        .buttonStyle(.mostik(.secondary, compact: true))
                }
                if let source {
                    Button(L("Убрать источник", "Remove source")) { model.onRemoveSource(source) }
                        .buttonStyle(.mostik(.destructive, compact: true))
                }
            }
        case "calendar":
            Toggle(isOn: Binding(get: { model.settings.calendarEnabled }, set: { model.onSetCalendarEnabled($0) })) {
                Text(L("Брать названия встреч и имена участников", "Use meeting titles and attendee names"))
                    .font(TType.body)
                    .foregroundStyle(Palette.ink)
            }
            .toggleStyle(MostikToggleStyle())
            .frame(maxWidth: 420)
        default:
            EmptyView()
        }
    }

    private var calendarOff: some View {
        Text(L("Включите календарь, и Mostik будет узнавать в речи названия встреч и имена коллег, а в расшифровке встречи подпишет собеседника по приглашению. События читаются через системный Календарь, в том числе Google и Яндекс, если они там подключены.",
               "Turn the calendar on and Mostik will recognise meeting titles and colleagues’ names, and label the other speaker from the invite. Events are read through macOS Calendar, including Google and Yandex accounts added there."))
            .font(TType.body)
            .foregroundStyle(Palette.inkSecondary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 520, alignment: .leading)
    }

    // MARK: Найти или добавить

    /// Одно поле: печатаете — список сужается; такого термина нет — «Добавить» в той же строке
    /// (или ⏎), и слово уходит в личный словарь подсказкой распознаванию. Справа — вид термина.
    private var findOrAdd: some View {
        HStack(spacing: DS.Space.xs) {
            MostikTextField(placeholder: L("Найти или добавить термин", "Find or add a term"), text: $query,
                            leadingSymbol: "magnifyingglass")
                .frame(maxWidth: 320)
                .onSubmit { if canAdd { add() } }
            if canAdd {
                Button(action: add) {
                    Label(L("Добавить «\(trimmedQuery)»", "Add “\(trimmedQuery)”"), systemImage: "plus")
                }
                .buttonStyle(.mostik(.secondary, compact: true))
                .help(L("В личный словарь: Mostik будет узнавать это слово в речи", "To your glossary: Mostik will listen for this word"))
            } else if let added {
                Label(L("«\(added)» в личном словаре", "“\(added)” added to your glossary"), systemImage: "checkmark")
                    .font(TType.callout)
                    .foregroundStyle(Palette.accent)
                    .lineLimit(1)
            }
            Spacer(minLength: DS.Space.xs)
            if !scoped.isEmpty { kindFilter }
        }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    /// Добавлять есть что: слово введено и такого термина ещё нет ни в словаре сессии, ни в личном.
    private var canAdd: Bool {
        let q = trimmedQuery.lowercased()
        guard !q.isEmpty else { return false }
        return !model.terms.contains { $0.term.lowercased() == q }
            && !model.glossary.contains { $0.canonical.lowercased() == q }
    }

    private func add() {
        let term = trimmedQuery
        guard !term.isEmpty else { return }
        model.onRemember(term, term)
        withAnimation(Motion.quick) { added = term; query = "" }
    }

    private var hiddenLine: some View {
        HStack(spacing: 6) {
            Text(L10n.plural(hiddenHere.count, ru: "слово удалено", "слова удалены", "слов удалено",
                             en: "word deleted", "words deleted"))
                .font(TType.callout)
                .foregroundStyle(Palette.inkSecondary)
                .help(hiddenHere.joined(separator: ", "))
            Button(L("Вернуть", "Restore")) { for term in hiddenHere { model.hideTerm(term, false) } }
                .buttonStyle(.mostik(.quiet, compact: true))
            Spacer(minLength: 0)
        }
    }

    // MARK: Фильтр по видам

    /// Вид термина — всплывающим меню (`Picker(.menu)`), а не рядом из шести сегментов.
    /// В снимке `ImageRenderer` меню не рисует — там такой же по виду ярлык.
    @ViewBuilder private var kindFilter: some View {
        let counts = Dictionary(grouping: scoped, by: \.kind).mapValues(\.count)
        let options: [(String, String)] = [("all", L("Все виды", "All kinds"))]
            + Fmt.kinds.filter { (counts[$0] ?? 0) > 0 }.map { ($0, Fmt.kindTitle($0)) }
        if snapshot {
            HStack(spacing: 6) {
                Text(options.first { $0.0 == kind }?.1 ?? "")
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.inkSecondary)
            }
            .font(TType.body)
            .padding(.horizontal, 10)
            .frame(height: DS.controlHeight)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(Palette.edgeStrong))
        } else {
            Picker(L("Вид", "Kind"), selection: $kind) {
                ForEach(options, id: \.0) { id, title in Text(title).tag(id) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
    }

    // MARK: Список

    @ViewBuilder private var list: some View {
        if filtered.isEmpty {
            Text(query.isEmpty ? L("Терминов этого вида нет.", "No terms of this kind.")
                 : (canAdd ? L("Такого термина нет. «Добавить» — и Mostik будет его узнавать.",
                               "No such term yet. Add it and Mostik will listen for it.")
                           : L("Ничего не нашлось по «\(query)».", "Nothing matches “\(query)”.")))
                .font(TType.callout)
                .foregroundStyle(Palette.inkSecondary)
        } else {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                GroupLabel(text: kind == "all" ? L("Термины", "Terms") : Fmt.kindTitle(kind),
                           trailing: Fmt.terms(filtered.count))
                LazyVStack(spacing: 0) {
                    ForEach(Array(filtered.prefix(snapshot ? 40 : 2000).enumerated()), id: \.element.id) { i, term in
                        if i > 0 { Hairline(inset: DS.Space.s) }
                        TermRow(term: term) { model.deleteTerm(term) }
                    }
                }
                .padding(DS.Space.xxs)
                .background(Palette.canvas, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(Palette.edge))
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if model.sourcesScanning {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text(L("Читаю источники", "Reading sources")).font(TType.bodyStrong)
                IndeterminateBar().frame(maxWidth: 320)
                Text(L("Первое сканирование проекта занимает до минуты. Диктовать можно уже сейчас.",
                       "The first scan takes up to a minute. You can dictate meanwhile."))
                    .font(TType.callout)
                    .foregroundStyle(Palette.inkSecondary)
            }
            .padding(.vertical, DS.Space.xs)
        } else {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text(L("Терминов пока нет", "No terms yet")).font(TType.bodyStrong)
                Text(source == nil
                     ? L("Начните диктовку в терминале или редакторе с агентом: Mostik найдёт проект и прочитает имена из кода. Ещё можно добавить папку с документами или заметками.",
                         "Dictate into a terminal or an editor with an agent: Mostik finds the project and reads names from the code. You can also add a folder of docs or notes.")
                     : L("В этом источнике не нашлось имён и терминов. Пересканируйте, если файлы изменились.",
                         "No names or terms found here. Rescan if the files changed."))
                    .font(TType.callout)
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 480, alignment: .leading)
                HStack(spacing: DS.Space.xs) {
                    Button { model.onAddSource(nil) } label: { Label(L("Добавить папку", "Add folder"), systemImage: "plus") }
                        .buttonStyle(.mostikSecondary)
                    Button(L("Пересканировать", "Rescan")) { model.onRescanSources() }
                        .buttonStyle(.mostik(.quiet))
                }
                .padding(.top, DS.Space.xxs)
            }
            .padding(.vertical, DS.Space.xs)
        }
    }
}

/// Термин: символ вида, само слово, откуда оно (коротко, полный список — в подсказке);
/// по наведению — «Удалить» (F4: у любого слова, не только из личного словаря). То же в контекстном меню и VoiceOver.
private struct TermRow: View {
    let term: AppModel.TermItem
    let delete: () -> Void
    @State private var hovering = false

    /// Слово только из личного словаря стирается; найденное в источниках — уходит в удалённые.
    private var deleteHelp: String {
        term.fromFiles || term.fromCalendar
            ? L("Удалить из словаря: Mostik перестанет узнавать это слово и не вернёт его при пересканировании. Вернуть можно внизу списка.",
                "Delete from the glossary: Mostik stops listening for it and won’t bring it back on rescan. Restore it at the bottom of the list.")
            : L("Удалить из личного словаря", "Delete from your glossary")
    }

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.s) {
            Image(systemName: kindSymbol(term.kind))
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Palette.inkSecondary)
                .frame(width: 20)
                .help(Fmt.kindSingular(term.kind))
                .accessibilityLabel(Fmt.kindSingular(term.kind))
            VStack(alignment: .leading, spacing: 3) {
                Text(term.term)
                    // Моноширинный — только у слов, похожих на код (`warm_mic`), а не у всего из кода («archive»).
                    .font(term.kind == "identifier" && looksLikeIdentifier(term.term) ? TType.code.weight(.medium) : TType.bodyStrong)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                if !term.origins.isEmpty { origins }
            }
            Spacer(minLength: DS.Space.s)
            Button(action: delete) {
                Label(L("Удалить", "Delete"), systemImage: "trash")
            }
            .buttonStyle(.mostik(.destructive, compact: true))
            .help(deleteHelp)
            .accessibilityLabel(L("Удалить термин \(term.term)", "Delete term \(term.term)"))
            .opacity(hovering ? 1 : 0)
        }
        .padding(.leading, DS.Space.xs)
        .padding(.trailing, DS.Space.xxs)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).fill(hovering ? Palette.hover : .clear))
        .onHover { hovering = $0 }
        // Кнопка видна по наведению; правый клик и VoiceOver дают то же действие без мыши над строкой.
        .contextMenu {
            Button(L("Удалить из словаря", "Delete from glossary"), systemImage: "trash", action: delete)
        }
        .accessibilityAction(named: Text(L("Удалить термин", "Delete term")), delete)
    }

    private var origins: some View {
        let first = shortOrigin(term.origins[0])
        let rest = term.origins.count - 1
        let line = rest > 0 ? first + "  +\(rest)" : first
        return Text(line)
            .font(TType.caption)
            .foregroundStyle(Palette.inkSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(term.origins.joined(separator: "\n"))
    }
}

// MARK: - Личный словарь

private struct PersonalGlossaryDetail: View {
    @ObservedObject var model: AppModel
    @State private var canonical = ""
    @State private var aliases = ""

    var body: some View {
        MostikScroll {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(L("Как слово пишется и как его слышит распознавание", "How a word is spelled and how recognition hears it"))
                        .font(TType.figure(12, .regular))
                        .foregroundStyle(Palette.inkSecondary)
                    Text(L("Личный словарь", "Personal glossary")).font(TType.title)
                }
                addForm
                LearnSuggestionsSection(learning: model.glossaryLearning)
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    GroupLabel(text: L("Слова", "Words"), trailing: "\(model.glossary.count)")
                    if !model.glossary.isEmpty { GlossaryColumns() }
                    if model.glossary.isEmpty {
                        Text(L("Пусто. Добавьте слово выше или нажмите «Запомнить» у слова под вопросом в диктовке.",
                               "Empty. Add a word above or press Remember next to an unsure word in a dictation."))
                            .font(TType.callout)
                            .foregroundStyle(Palette.inkSecondary)
                    } else {
                        VStack(spacing: 0) {
                            // Движок дописывает слова в конец файла — новые показываем первыми.
                            ForEach(Array(model.glossary.reversed().enumerated()), id: \.element.id) { i, item in
                                if i > 0 { Hairline(inset: DS.Space.s) }
                                GlossaryRow(item: item) { model.onForget(item) }
                            }
                        }
                        .padding(DS.Space.xxs)
                        .background(Palette.canvas, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(Palette.edge))
                    }
                }
                GlossaryImportSection(learning: model.glossaryLearning)
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var addForm: some View {
        HStack(spacing: DS.Space.xs) {
            MostikTextField(placeholder: L("Как пишется", "Spelling"), text: $canonical,
                            monospaced: looksLikeIdentifier(canonical))
                .frame(width: 170)
            MostikTextField(placeholder: L("Как слышится, через запятую", "Heard as, comma-separated"),
                            text: $aliases)
            Button(L("Добавить", "Add")) {
                let name = canonical.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                let heard = aliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                for alias in heard.isEmpty ? [name] : heard { model.onRemember(alias, name) }
                canonical = ""; aliases = ""
            }
            .buttonStyle(.mostikPrimary)
            .disabled(canonical.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

/// Заголовки колонок личного словаря (L3).
struct GlossaryColumns: View {
    static let first: CGFloat = 200

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Text(L("Как пишется", "Spelling")).frame(width: Self.first, alignment: .leading)
            Text(L("Как слышится", "Heard as"))
            Spacer()
        }
        .font(TType.captionStrong)
        .foregroundStyle(Palette.inkTertiary)
        .padding(.leading, DS.Space.s + DS.Space.xxs)
    }
}

struct GlossaryRow: View {
    let item: AppModel.GlossaryItem
    let forget: () -> Void
    @State private var hovering = false

    /// Варианты, которые заменяются на написание целым словом; сам канон — не замена.
    private var insteadText: String {
        let other = item.aliases.filter { $0 != item.canonical }
        return other.isEmpty ? L("только подсказка распознаванию", "hint for recognition only") : other.joined(separator: ", ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.s) {
            // L3: две колонки — как пишется и что модель пишет вместо (замена целым словом).
            Text(item.canonical)
                .font(looksLikeIdentifier(item.canonical) ? TType.code.weight(.medium) : TType.bodyStrong)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .frame(width: GlossaryColumns.first, alignment: .leading)
            Text(insteadText)
                .font(TType.callout)
                .foregroundStyle(item.aliases.isEmpty ? Palette.inkTertiary : Palette.inkSecondary)
                .lineLimit(1)
            Spacer(minLength: DS.Space.s)
            Text(item.source == "learned" ? L("выучено из правок", "learned") : L("добавлено вами", "added by you"))
                .font(TType.caption)
                .foregroundStyle(Palette.inkTertiary)
            // «Удалить», как у терминов в общем списке; без полупрозрачности — подпись держит ≥ 4,5:1.
            Button(L("Удалить", "Delete"), action: forget)
                .buttonStyle(.mostik(.quiet, compact: true))
                .help(L("Удалить из личного словаря", "Delete from your glossary"))
        }
        .padding(.leading, DS.Space.s)
        .padding(.trailing, DS.Space.xxs)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).fill(hovering ? Palette.hover : .clear))
        .onHover { hovering = $0 }
    }
}
