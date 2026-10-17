import SwiftUI
import MostikCore

// П9-А. Форма Настроек в духе сгруппированной формы macOS (`Form` + `.grouped`):
// группа — поверхность с краем своего тона, строки через волосяную линию с отступом,
// у строки заголовок 13 pt, одна строка пояснения 11 pt и подробности по «i».
// Настоящий `Form(.grouped)` и `NSSwitch` не рисуются в `ImageRenderer`, а снимки — это то,
// что видят слепые критики. Поэтому форма собрана на SwiftUI один в один, а переключатель
// в живом окне — системный `Toggle(.switch)`, в снимке — его копия того же размера.

// MARK: - Разделы

/// Разделы Настроек в порядке боковой панели (решение автора: 9 разделов → 5).
/// «Агенты» видны, только если агент найден (`AppModel.visibleSettingsPanes`);
/// «Дополнительно» — раскрывающийся блок внутри «Приватности и данных».
public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case general, text, meetings, agents, privacy

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .general: L("Основное", "General")
        case .text: L("Текст", "Text")
        case .meetings: L("Встречи", "Meetings")
        case .agents: L("Агенты", "Agents")
        case .privacy: L("Приватность и данные", "Privacy & Data")
        }
    }

    /// Одна строка под заголовком раздела: о чём он.
    var subtitle: String {
        switch self {
        case .general: L("Клавиша, микрофон и язык — всё для первой диктовки.",
                         "Key, microphone and language: all you need for a first dictation.")
        case .text: L("Как сказанное становится текстом: причёсывание, правила, приложения.",
                      "How speech becomes text: polishing, rules and per-app settings.")
        case .meetings: L("Запись встреч, заметки и память голосов.",
                          "Meeting recording, notes and voice memory.")
        case .agents: L("Диктовка в Claude Code, Codex, Cursor и терминал.",
                        "Dictating into Claude Code, Codex, Cursor and the terminal.")
        case .privacy: L("Что остаётся на этом Mac, что и когда может уйти в сеть.",
                         "What stays on this Mac, and what may leave it and when.")
        }
    }

    /// Символ SF без подложки: знак сам по себе, без цветной плитки.
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .text: "text.cursor"
        case .meetings: "person.2"
        case .agents: "terminal"
        case .privacy: "hand.raised"
        }
    }
}

// MARK: - Типографика формы

enum FormType {
    /// Заголовок группы — 13 pt полужирный вторичным тоном, как в Системных настройках:
    /// подпись над группой, а не ещё одна строка наравне с настройками (R3b).
    static let groupTitle = Font.system(size: 13, weight: .semibold)
    /// Пояснение у строки — одна строка 11 pt.
    static let hint = TType.caption
}

// MARK: - Группа

/// Группа формы: заголовок над поверхностью, строки внутри, сноска под ней.
struct FormGroup<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    /// Справа от заголовка: кнопка группы («Скачать нужные», «Проверить снова»).
    var accessory: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        // Кнопка справа от заголовка выше строки заголовка: при ней воздуха над карточкой больше, иначе она к ней липнет.
        VStack(alignment: .leading, spacing: accessory == nil ? DS.Space.xs : DS.Space.s) {
            if title != nil || accessory != nil {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                    if let title {
                        Text(title).font(FormType.groupTitle).foregroundStyle(Palette.inkSecondary)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Spacer(minLength: DS.Space.s)
                    if let accessory { accessory }
                }
                .padding(.horizontal, DS.Space.xxs)
                .frame(minHeight: 20)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, DS.Space.m)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(Palette.edge))
            if let footer {
                Text(footer).font(FormType.hint).foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DS.Space.xxs)
            }
        }
    }
}

/// Группа, свёрнутая до заголовка со сводкой (R3b): редкие настройки не занимают экран,
/// пока их не раскрыли. Включённая настройка внутри — повод открыть группу сразу.
/// Сводка у всех групп в одном формате (слепой раунд 4): «что внутри · состояние»,
/// без сочетаний клавиш — они живут кейкапами в строках.
struct FormDisclosure<Content: View>: View {
    let title: String
    /// Что внутри, словами: «Модели, второе распознавание, диагностика».
    let contents: String
    /// Состояние сейчас: «5 моделей установлено», «всё выключено».
    let state: String
    @State private var open: Bool
    /// `false` — внутри уже свои группы (`FormGroup`): раскрытое идёт ими, без карточки вокруг карточек.
    let grouped: Bool
    @ViewBuilder var content: Content

    init(title: String, contents: String, state: String, open: Bool = false, grouped: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.contents = contents
        self.state = state
        self.grouped = grouped
        _open = State(initialValue: open)
        self.content = content()
    }

    /// Сводка одной строкой — для VoiceOver и проверок формата.
    static func summary(contents: String, state: String) -> String { contents + " · " + state }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Button { withAnimation(Motion.spring) { open.toggle() } } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 12)
                    Text(title).font(FormType.groupTitle).fixedSize()
                    Spacer(minLength: DS.Space.s)
                    if !open {
                        (Text(contents + " · ").foregroundStyle(Palette.inkSecondary)
                         + Text(state).foregroundStyle(Palette.ink))
                            .font(FormType.hint)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .foregroundStyle(Palette.inkSecondary)
                // Слева — по заголовкам групп, справа — по правой колонке контролов в карточках.
                .padding(.leading, DS.Space.xxs)
                .padding(.trailing, DS.Space.m)
                .frame(minHeight: DS.hit)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(open ? L("развёрнуто", "expanded") : Self.summary(contents: contents, state: state))
            .accessibilityAddTraits(.isHeader)
            if open {
                if grouped {
                    FormGroup { content }
                        .transition(.opacity)
                } else {
                    VStack(alignment: .leading, spacing: DS.Space.l) { content }
                        .transition(.opacity)
                }
            }
        }
    }
}

/// Разделитель строк внутри группы.
struct FormDivider: View {
    var body: some View { Hairline() }
}

// MARK: - Строки

/// Строка формы: заголовок, одна строка пояснения, «i» с подробностями, контрол справа.
struct FormRow<Control: View>: View {
    let title: String
    /// Сочетание клавиш опции — кейкапами справа, перед контролом, а не текстом в названии (слепой раунд 4).
    var keys: [String]? = nil
    var hint: String? = nil
    var details: String? = nil
    /// Пояснение-предупреждение (охра) вместо вторичного.
    var warning = false
    /// Точка состояния перед заголовком: установлено, не установлено.
    var status: Color? = nil
    var enabled = true
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.m) {
            FormLabel(title: title, hint: hint, details: details, warning: warning, status: status)
                .opacity(enabled ? 1 : 0.5)
            if let keys { ShortcutKeys(keys: keys).opacity(enabled ? 1 : 0.5) }
            control
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.5)
        }
        .padding(.vertical, 10)
        .frame(minHeight: 48)
    }
}

/// Подпись строки: заголовок с «i» и одна строка пояснения.
struct FormLabel: View {
    let title: String
    var hint: String? = nil
    var details: String? = nil
    var warning = false
    var status: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 6) {
                if let status { StatusDot(color: status, size: 7) }
                Text(title).font(TType.body).foregroundStyle(Palette.ink)
                    .lineLimit(1)
                if let details { InfoButton(title: title, details: details) }
            }
            if let hint {
                Text(hint).font(FormType.hint)
                    .foregroundStyle(warning ? Palette.doubt : Palette.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(hint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Строка-переключатель.
struct FormToggle: View {
    let title: String
    var keys: [String]? = nil
    var hint: String? = nil
    var details: String? = nil
    var warning = false
    @Binding var isOn: Bool
    var enabled = true

    var body: some View {
        FormRow(title: title, keys: keys, hint: hint, details: details, warning: warning, enabled: enabled) {
            FormSwitch(isOn: $isOn, label: title)
        }
    }
}

/// Группа, которой сейчас нечем работать: одна строка с причиной и действием вместо всех настроек.
struct FormCollapsed: View {
    let title: String
    let reason: String
    var action: String? = nil
    var perform: () -> Void = {}

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(TType.body).foregroundStyle(Palette.inkSecondary).lineLimit(1)
                Text(reason).font(FormType.hint).foregroundStyle(Palette.inkSecondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let action {
                Button(action, action: perform).buttonStyle(.mostik(.secondary, compact: true))
            }
        }
        .padding(.vertical, 10)
        .frame(minHeight: 48)
        .accessibilityElement(children: .contain)
    }
}

/// Строка-сноска внутри группы: пояснение без контрола.
struct FormNote: View {
    let text: String
    var body: some View {
        Text(text).font(FormType.hint).foregroundStyle(Palette.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
    }
}

// MARK: - Клавиши

/// Сочетание клавиш опции маленькими кейкапами — тот же рисунок, что у «Клавиши записи»:
/// поверхность, край и нижняя губа тоном. Один кейкап — одна клавиша: «⌃», «⌘», «K», «правый ⌘».
struct ShortcutKeys: View {
    let keys: [String]

    /// «⌃⌘K» → ["⌃", "⌘", "K"], «⌥Space» → ["⌥", "Space"]: модификаторы по одному, остальное — одной клавишей.
    static func split(_ combo: String) -> [String] {
        let modifiers: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
        var out: [String] = []
        var rest = ""
        for ch in combo {
            if modifiers.contains(ch) && rest.isEmpty { out.append(String(ch)) } else { rest.append(ch) }
        }
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 5)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Palette.surface))
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Palette.edgeStrong).offset(y: 1.5))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Palette.edgeStrong, lineWidth: 1))
            }
        }
        .padding(.bottom, 1.5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Сочетание: ", "Shortcut: ") + keys.joined(separator: " "))
    }
}

// MARK: - Подробности

/// «i» рядом с заголовком: подробности во всплывающем окне, в снимке — только значок.
struct InfoButton: View {
    let title: String
    let details: String
    @State private var shown = false
    @Environment(\.mostikSnapshot) private var snapshot

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Palette.inkSecondary)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Зона нажатия 40 pt внутри кнопки; в раскладке значок занимает 20 pt и строку
        // (минимум 48 pt) не раздувает: заходит только на подпись, она не нажимается.
        .padding(-10)
        .iconHelp(L("Подробнее: ", "More about: ") + title)
        .accessibilityHint(details)
        .popover(isPresented: Binding(get: { shown && !snapshot }, set: { shown = $0 }), arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(title).font(TType.bodyStrong).foregroundStyle(Palette.ink)
                Text(details).font(TType.callout).foregroundStyle(Palette.inkSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(DS.Space.m)
            .frame(width: 340, alignment: .leading)
        }
    }
}

// MARK: - Переключатель

/// В окне — системный переключатель macOS с акцентом палитры; в снимке — копия того же размера.
struct FormSwitch: View {
    @Binding var isOn: Bool
    let label: String
    @Environment(\.mostikSnapshot) private var snapshot

    var body: some View {
        if snapshot {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(isOn ? Palette.accent : Palette.edgeStrong)
                    .frame(width: 32, height: 18)
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.18), radius: 0.5, y: 0.5)
                    .frame(width: 14, height: 14)
                    .padding(2)
            }
            .frame(minHeight: DS.hit)
        } else {
            Toggle(label, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Palette.accent)
                .frame(minHeight: DS.hit)
        }
    }
}

// MARK: - Выбор из меню

/// Системное всплывающее меню в окне; в снимке — его подпись с шевроном.
struct FormMenu<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    let label: String
    @Environment(\.mostikSnapshot) private var snapshot

    var body: some View {
        if snapshot {
            HStack(spacing: 6) {
                Text(current).font(TType.body).foregroundStyle(Palette.ink)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.inkSecondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(Palette.edgeStrong))
            .frame(minHeight: DS.hit)
        } else {
            Picker(label, selection: $selection) {
                ForEach(options.indices, id: \.self) { i in
                    Text(options[i].1).tag(options[i].0)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .frame(minHeight: DS.hit)
        }
    }

    private var current: String { options.first { $0.0 == selection }?.1 ?? "—" }
}

// MARK: - Приложения

/// Человеческое имя приложения по его идентификатору: установленное — из его Info.plist
/// (не имя файла: у копии Finder это «Telegram 2»), иначе последняя часть идентификатора
/// с заглавной буквы («dev.zed.Zed» → «Zed»).
enum AppName {
    static func of(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return AppDisplayName.resolve(bundleID: bundleID, bundleName: nil, fileName: nil)
        }
        let bundle = Bundle(url: url)
        let name = ["CFBundleDisplayName", "CFBundleName"].lazy.compactMap { key in
            (bundle?.localizedInfoDictionary?[key] ?? bundle?.infoDictionary?[key]) as? String
        }.first
        return AppDisplayName.resolve(bundleID: bundleID, bundleName: name,
                                      fileName: FileManager.default.displayName(atPath: url.path))
    }

    /// Запущенные обычные приложения: имя и идентификатор, по алфавиту, без самого Mostik.
    static func running() -> [(id: String, name: String)] {
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (String, String)? in
                guard let id = app.bundleIdentifier, id != own, seen.insert(id).inserted else { return nil }
                return (id, app.localizedName ?? of(id))
            }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
            .map { (id: $0.0, name: $0.1) }
    }
}

/// Список исключений по приложениям: имя приложения, выбор из двух вариантов, «убрать»,
/// внизу — «Добавить приложение» из запущенных или по идентификатору.
struct AppOverrideList: View {
    /// Идентификатор приложения → выбран первый вариант (`true`) или второй.
    let overrides: [(String, Bool)]
    let onTitle: String
    let offTitle: String
    var set: (String, Bool?) -> Void
    @State private var typing = false
    @State private var typed = ""
    @Environment(\.mostikSnapshot) private var snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(overrides.sorted { $0.0 < $1.0 }, id: \.0) { bundle, on in
                FormDivider()
                HStack(spacing: DS.Space.s) {
                    Text(AppName.of(bundle)).font(TType.body).foregroundStyle(Palette.ink).lineLimit(1)
                        .help(bundle)
                    Spacer(minLength: DS.Space.s)
                    Segmented(options: [(true, onTitle), (false, offTitle)],
                              selection: Binding(get: { on }, set: { set(bundle, $0) }))
                    Button { set(bundle, nil) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.inkSecondary)
                            .frame(width: DS.hit, height: DS.hit)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(RowButtonStyle(radius: DS.Radius.control))
                    .iconHelp(L("Убрать исключение", "Remove exception"))
                }
                .frame(minHeight: 40)
            }
            FormDivider()
            HStack(spacing: DS.Space.xs) {
                if typing {
                    MostikTextField(placeholder: L("Идентификатор, например com.apple.mail", "Identifier, e.g. com.apple.mail"),
                                    text: $typed, monospaced: true)
                        .onSubmit { add(typed) }
                    Button(L("Отмена", "Cancel")) { typing = false; typed = "" }
                        .buttonStyle(.mostik(.quiet, compact: true))
                    Button(L("Добавить", "Add")) { add(typed) }
                        .buttonStyle(.mostik(.secondary, compact: true))
                } else if snapshot {
                    addLabel
                } else {
                    Menu {
                        let apps = AppName.running().filter { app in !overrides.contains { $0.0 == app.id } }
                        ForEach(apps, id: \.id) { app in
                            Button(app.name) { set(app.id, true) }
                        }
                        if !apps.isEmpty { Divider() }
                        Button(L("Другое — по идентификатору…", "Other, by identifier…")) { typing = true }
                    } label: { addLabel }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
        }
    }

    private var addLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
            Text(L("Добавить приложение", "Add an app")).font(TType.body)
        }
        .foregroundStyle(Palette.accent)
        .frame(minHeight: DS.hit)
    }

    private func add(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        set(trimmed, true)
        typed = ""
        typing = false
    }
}
