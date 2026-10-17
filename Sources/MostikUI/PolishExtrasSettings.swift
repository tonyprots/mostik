import SwiftUI
import MostikCore

/// П6-А: состояние для Настроек — пакеты стилей (P4), живое превью тона (P2), хуки очереди агенту (A6).
@MainActor
public final class PolishExtrasModel: ObservableObject {
    @Published public var packs: [StylePackInfo] = []
    @Published public var stylesFolder: String?
    /// Ответ модели для превью: ключ — вариант превью (`plain`, `business`, … `en`).
    @Published public var preview: [String: String] = [:]
    @Published public var previewBusy = false
    @Published public var previewMessage: String?
    /// Разовый режим, ждущий следующей диктовки (⌃⌘E, ⌃⌘J).
    @Published public var pendingMode: PolishMode?
    @Published public var queueHooksInstalled = false
    @Published public var queueHooksPlan: AgentVoiceModel.HooksPlan?
    @Published public var queueHooksMessage: String?

    public init() {}

    public var onRefreshPacks: () -> Void = {}
    public var onOpenStylesFolder: () -> Void = {}
    public var onAddExample: () -> Void = {}
    /// Причесать образец вживую: вариант превью и сырой текст.
    public var onPreview: (_ variant: String, _ raw: String) -> Void = { _, _ in }
    public var onPrepareQueueHooks: () -> Void = {}
    public var onInstallQueueHooks: () -> Void = {}
    public var onUninstallQueueHooks: () -> Void = {}
}

/// Образец для превью тона: синтетика, на модели гоняется только по кнопке.
enum TonePreview {
    static var raw: String {
        L("ну короче давай созвонимся завтра в три обсудим релиз и э глянь пожалуйста отчёт до вечера",
          "so um let's like have a call tomorrow at three talk about the release and uh check the report by tonight please")
    }

    static let variants: [(String, String)] = [
        ("plain", L("Обычный", "Plain")), ("business", L("Деловой", "Business")),
        ("brief", L("Кратко", "Brief")), ("en", "EN"),
    ]

    /// Как примерно выйдет без модели — чтобы видеть разницу тонов сразу.
    static func sample(_ variant: String) -> String {
        switch variant {
        case "business": return L("Предлагаю созвониться завтра в 15:00 и обсудить релиз. Также прошу посмотреть отчёт до конца дня.",
                                   "Let’s meet tomorrow at 3:00 PM to discuss the release. Please also review the report by end of day.")
        case "brief": return L("Созвон завтра в 15:00 — релиз. Посмотри отчёт до вечера.", "Call tomorrow at 3 PM re: release. Check the report by tonight.")
        case "en": return "Let’s have a call tomorrow at 3 to discuss the release. Also, please take a look at the report by tonight."
        default: return L("Давай созвонимся завтра в три, обсудим релиз. И глянь, пожалуйста, отчёт до вечера.",
                           "Let’s have a call tomorrow at three to talk about the release. And please check the report by tonight.")
        }
    }
}

/// Части П6-А в разделах Настроек: правила речи, контекст, сценарии, разовые режимы, тон, свои стили, очередь агенту,
/// редкое для «Дополнительно» (буфер обмена, вставка по ходу). Раздел берёт нужные части; снимок группы — все сразу.
struct PolishExtrasSection: View {
    enum Part: CaseIterable { case rules, context, scenarios, modes, tone, styleFiles, midTurn, advanced }

    @ObservedObject var model: AppModel
    @ObservedObject var extras: PolishExtrasModel
    var parts: Set<Part>
    @State private var variant = "plain"

    init(model: AppModel, parts: Set<Part> = Set(Part.allCases)) {
        self.model = model
        self.extras = model.polishExtras
        self.parts = parts
    }

    private var p: PolishSettings { model.settings.polish }
    private var polishOn: Bool { p.effectiveBackend != .off }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            if parts.contains(.rules) { rules }
            if parts.contains(.context) { context }
            if parts.contains(.tone) { tone }
            if parts.contains(.styleFiles) { styleFiles }
            if parts.contains(.scenarios) { scenarios }
            if parts.contains(.modes) { modes }
            if parts.contains(.midTurn) { midTurn }
            if parts.contains(.advanced) { advanced }
        }
        .sheet(item: Binding(get: { extras.queueHooksPlan }, set: { extras.queueHooksPlan = $0 })) { plan in
            QueueHooksSheet(plan: plan, onInstall: extras.onInstallQueueHooks, onCancel: { extras.queueHooksPlan = nil })
        }
    }

    // MARK: правила речи

    /// «Абзац и строка голосом» и «Зачеркни» — умолчания без переключателя (решение автора):
    /// работают всегда, а на виду остаются два правила, которые меняют вид текста.
    private var rules: some View {
        FormGroup(title: L("Правила речи", "Speech rules"),
                  footer: L("Работают и без причёсывания. «Новый абзац», «новая строка» и «зачеркни» срабатывают всегда.",
                            "Work without polishing too. “New paragraph”, “new line” and “scratch that” always work.")) {
            ruleToggle(L("Списки из «во-первых, во-вторых»", "Lists from “first, second”"),
                       L("Пункты по порядку становятся списком — от двух пунктов.", "Ordered items become a list, from two items up."),
                       nil, \.lists)
            FormDivider()
            ruleToggle(L("Числа цифрами", "Numbers as digits"),
                       L("«Триста двадцать» → 320, «в девятнадцать тридцать» → 19:30.", "“Three hundred twenty” → 320, “nineteen thirty” → 19:30."),
                       L("«Триста двадцать гостей» → 320, «к девятнадцати тридцати» → 19:30, «два запятая семь процента» → 2,7. «Три варианта» остаются словом.",
                         "“Three hundred twenty” → 320, “at nineteen thirty” → 19:30. Small counts without units stay words."), \.numbers)
        }
    }

    // MARK: контекст

    private var context: some View {
        FormGroup(title: L("Контекст", "Context")) {
            contextToggle(L("Текст вокруг курсора", "Text around the cursor"),
                          L("Помогает написать имена как в поле. Пароли — никогда.", "Helps spell names as in the field. Never passwords."),
                          L("Выделение и до 256 знаков до и после курсора помогают модели написать имена и термины как в поле. Текст поля в результат не копируется. Поля паролей, менеджеры паролей и банки — никогда.",
                            "The selection and up to 256 characters around the cursor help spell names and terms. Field text is never copied into the result. Password fields, password managers and banks — never."),
                          \.enabled)
            FormDivider()
            contextToggle(L("Отдавать контекст и в облако", "Send context to the cloud too"),
                          L("Выключено — контекст видит только модель на этом Mac.", "Off: only the on-device model sees it."),
                          nil, \.toCloud, enabled: p.context.enabled, warning: p.context.toCloud && p.effectiveBackend.isCloud)
        }
    }

    // MARK: сценарии

    /// Сценарии строками без своей карточки: в Настройках они — часть группы «Приложения и сайты»
    /// рядом с исключениями; в снимке всех частей — своя группа с заголовком.
    @ViewBuilder private var scenarios: some View {
        if parts.count > 1 {
            FormGroup(title: L("Сценарии по приложению и сайту", "Scenarios per app and site")) { scenarioRows }
        } else {
            scenarioRows
        }
    }

    private var scenarioRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            FormRow(title: L("Сценарии", "Scenarios"),
                    hint: p.scenarios.isEmpty ? L("Свои язык, стиль и перевод в приложении или на сайте.", "Its own language, style and translation in an app or site.")
                                              : L10n.plural(p.scenarios.count, ru: "сценарий", "сценария", "сценариев", en: "scenario", "scenarios"),
                    details: L("В выбранном приложении или на сайте — свой язык, стиль, перевод, Enter после вставки и слова под вопросом. Сайт Mostik узнаёт по адресу страницы в браузере. Подошли несколько — действует верхний.",
                               "In a chosen app or site: its own language, style, translation, Enter after paste and unsure words. Mostik matches sites by the browser’s page address. If several match, the top one wins.")) { EmptyView() }
            ForEach(Array(p.scenarios.enumerated()), id: \.element.id) { index, scenario in
                FormDivider()
                ScenarioEditor(scenario: scenarioBinding(index), packs: extras.packs, onRemove: { removeScenario(index) })
            }
            FormDivider()
            HStack(spacing: DS.Space.xs) {
                ForEach(Scenario.presets, id: \.id) { preset in
                    Button("+ " + preset.name) { addScenario(preset) }
                        .buttonStyle(.mostik(.secondary, compact: true))
                }
                Button(L("+ Пустой", "+ Blank")) { addScenario(Scenario(name: L("Новый сценарий", "New scenario"))) }
                    .buttonStyle(.mostik(.secondary, compact: true))
                Spacer(minLength: 0)
            }
            .padding(.top, DS.Space.s)
            // Что делает каждая заготовка — словами, а не только названием на кнопке.
            Text(L("Slack — обычный стиль, Почта — деловой, Задача для агента — диктовка становится задачей: цель, контекст, критерии приёмки.",
                   "Slack: plain style. Mail: business. Task for an agent: the dictation becomes a task with a goal, context and acceptance criteria."))
                .font(FormType.hint).foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DS.Space.xs)
                .padding(.bottom, DS.Space.s)
        }
    }

    // MARK: разовые режимы

    private var modes: some View {
        FormGroup(title: L("Разовые режимы", "One-off modes")) {
            FormRow(title: L("Перевод на английский", "Translate to English"), keys: ["⌃", "⌘", "E"],
                    hint: L("Следующая диктовка: говорите по-русски — вставится по-английски.", "Next dictation: speak Russian, get English.")) {
                Segmented(options: [(TranslateTone.plain, L("Обычный", "Plain")), (.business, L("Деловой", "Business")),
                                    (.dev, L("Разработчик", "Developer"))],
                          selection: Binding(get: { p.translateTone }, set: { v in update { $0.translateTone = v } }))
            }
            FormDivider()
            FormRow(title: L("Мысли вслух → задача", "Thinking aloud → task"), keys: ["⌃", "⌘", "J"],
                    hint: L("Следующая диктовка станет задачей для агента.", "Next dictation becomes a task for an agent."),
                    details: L("⌃⌘J — следующая диктовка оформляется задачей агенту: цель, контекст, файлы, критерии приёмки, открытые вопросы. Слова под вопросом остаются.",
                               "⌃⌘J — the next dictation becomes an agent task: goal, context, files, acceptance criteria, open questions. Unsure words stay.")) {
                if let mode = extras.pendingMode {
                    Text(mode == .translate ? L("Ждёт: перевод", "Next: translate") : L("Ждёт: задача", "Next: task"))
                        .font(TType.captionStrong).foregroundStyle(Palette.accent)
                }
            }
        }
    }

    // MARK: тон

    private var tone: some View {
        FormGroup(title: L("Как это будет выглядеть", "How it will look")) {
            HStack(spacing: DS.Space.m) {
                Segmented(options: TonePreview.variants, selection: $variant)
                Spacer(minLength: DS.Space.s)
                Button(extras.previewBusy ? L("Причёсываю…", "Polishing…") : L("Проверить на модели", "Try on the model")) {
                    extras.onPreview(variant, TonePreview.raw)
                }
                .buttonStyle(.mostik(.secondary, compact: true))
                .disabled(!polishOn || extras.previewBusy)
            }
            .padding(.top, DS.Space.s)
            .padding(.bottom, DS.Space.xs)
            let text = extras.preview[variant] ?? TonePreview.sample(variant)
            HStack(alignment: .top, spacing: DS.Space.s) {
                SlackMockup(text: text)
                MailMockup(text: text)
            }
            Text(extras.previewMessage ?? (extras.preview[variant] == nil
                ? L("Пример написан заранее. «Проверить на модели» причешет тот же образец.",
                    "This sample is pre-written. “Try on the model” polishes the same sample.")
                : L("Ответ модели на образец: «\(TonePreview.raw)».", "Model output for the sample: “\(TonePreview.raw)”.")))
                .font(FormType.hint).foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, DS.Space.s)
        }
    }

    // MARK: свои стили

    private var styleFiles: some View {
        FormGroup(title: L("Свои стили", "Custom styles")) {
            packsRow
        }
    }

    // MARK: дополнительно

    /// Редкое — в «Дополнительно» раздела «Приватность и данные»: буфер обмена как контекст и вставка по ходу.
    private var advanced: some View {
        VStack(alignment: .leading, spacing: 0) {
            contextToggle(L("Буфер обмена как подсказка модели", "Clipboard as a hint for the model"),
                          L("Выключен: в буфере бывают пароли и чужие данные.", "Off by default: clipboards hold passwords and others’ data."),
                          nil, \.clipboard, enabled: p.context.enabled)
            FormDivider()
            FormToggle(title: L("Вставлять по ходу причёсывания", "Insert while polishing"),
                       hint: p.effectiveBackend == .mlx ? L("Предложения появляются, пока модель пишет дальше.", "Sentences appear while the model keeps writing.")
                                                        : L("Только с моделью на этом Mac.", "On-device model only."),
                       details: L("Готовые предложения появляются в поле, пока модель пишет дальше. Если финальный текст отличается, Mostik заменит его, пока вы не начали печатать. Иначе положит в буфер.",
                                  "Finished sentences appear while the model keeps writing. If the final text differs, Mostik replaces it until you start typing; otherwise it goes to the clipboard."),
                       isOn: Binding(get: { p.streamInsert }, set: { v in update { $0.streamInsert = v } }),
                       enabled: p.effectiveBackend == .mlx)
        }
    }

    // MARK: очередь агенту

    private var midTurn: some View {
        FormGroup(title: L("Пока агент занят", "While the agent is busy")) {
            FormToggle(title: L("Диктовать, пока агент занят", "Dictate while the agent is busy"),
                       hint: L("Текст дойдёт до Claude Code после его текущего шага, не дожидаясь конца ответа.",
                               "The text reaches Claude Code after its current step, without waiting for the reply to end."),
                       details: L("Нужно подключение ниже: без него текст ждёт, пока агент закончит ответ.",
                                  "Needs the connection below; without it the text waits until the agent finishes."),
                       isOn: Binding(get: { model.settings.agentVoice.midTurn },
                                     set: { v in var s = model.settings; s.agentVoice.midTurn = v; model.onUpdateSettings(s) }))
            FormDivider()
            queueHooksRow
        }
    }

    // MARK: части

    private var packsRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            FormRow(title: L("Стили из папки", "Styles from a folder"),
                    hint: L("Указания и замены слов; ⌃⌘Y — стиль по кругу.", "Instructions and word swaps; ⌃⌘Y cycles styles."),
                    details: L("Папка на стиль: prompt.md с указаниями и dictionary.txt с терминами и заменами «кубер → Kubernetes». ⌃⌘Y переключает стиль по кругу — встроенные, затем файлы.",
                               "A folder per style: prompt.md with instructions and dictionary.txt with terms and “kube → Kubernetes” replacements. ⌃⌘Y cycles styles — built-in, then files.")) {
                HStack(spacing: DS.Space.xs) {
                    Button(L("Добавить пример", "Add example")) { extras.onAddExample() }
                        .buttonStyle(.mostik(.quiet, compact: true))
                    Button(L("Открыть папку", "Open folder")) { extras.onOpenStylesFolder() }
                        .buttonStyle(.mostik(.secondary, compact: true))
                }
            }
            if !extras.packs.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    packOption(nil, L("Встроенный стиль", "Built-in style"), nil)
                    ForEach(extras.packs) { pack in
                        packOption(pack.id, pack.name, L("\(pack.terms) терм. · \(pack.replacements) замен", "\(pack.terms) terms · \(pack.replacements) replacements"))
                    }
                }
                .padding(.bottom, DS.Space.s)
            }
        }
    }

    private func packOption(_ id: String?, _ title: String, _ detail: String?) -> some View {
        let on = p.pack == id
        return Button { update { $0.pack = id } } label: {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13)).foregroundStyle(on ? Palette.accent : Palette.inkTertiary).frame(width: 18)
                Text(title).font(on ? TType.bodyStrong : TType.body).foregroundStyle(Palette.ink)
                if let detail { Text(detail).font(TType.caption).foregroundStyle(Palette.inkTertiary) }
                Spacer(minLength: 0)
            }
            .frame(minHeight: DS.hit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var queueHooksRow: some View {
        FormRow(title: extras.queueHooksInstalled ? L("Очередь подключена к Claude Code", "Queue connected to Claude Code")
                                                  : L("Очередь не подключена к Claude Code", "Queue not connected to Claude Code"),
                hint: extras.queueHooksMessage ?? L("Перед подключением Mostik покажет, какие файлы изменятся.", "Before connecting, Mostik shows which files change."),
                status: extras.queueHooksInstalled ? Palette.accent : Palette.inkTertiary) {
            if extras.queueHooksInstalled {
                Button(L("Отключить", "Disconnect")) { extras.onUninstallQueueHooks() }
                    .buttonStyle(.mostik(.secondary, compact: true))
            } else {
                Button(L("Подключить…", "Connect…")) { extras.onPrepareQueueHooks() }
                    .buttonStyle(.mostik(.secondary, compact: true))
            }
        }
    }

    private func ruleToggle(_ title: String, _ hint: String, _ details: String?, _ key: WritableKeyPath<SpeechRuleSettings, Bool>) -> some View {
        FormToggle(title: title, hint: hint, details: details,
                   isOn: Binding(get: { p.rules[keyPath: key] }, set: { v in update { $0.rules[keyPath: key] = v } }))
    }

    private func contextToggle(_ title: String, _ hint: String, _ details: String?, _ key: WritableKeyPath<PolishContextSettings, Bool>,
                               enabled: Bool = true, warning: Bool = false) -> some View {
        FormToggle(title: title, hint: hint, details: details, warning: warning,
                   isOn: Binding(get: { enabled && p.context[keyPath: key] }, set: { v in update { $0.context[keyPath: key] = v } }),
                   enabled: enabled)
    }

    private func scenarioBinding(_ index: Int) -> Binding<Scenario> {
        Binding(get: { index < p.scenarios.count ? p.scenarios[index] : Scenario(name: "") },
                set: { value in update { if index < $0.scenarios.count { $0.scenarios[index] = value } } })
    }

    private func addScenario(_ preset: Scenario) {
        var scenario = preset
        scenario.id = UUID().uuidString
        update { $0.scenarios.append(scenario) }
    }

    private func removeScenario(_ index: Int) {
        update { if index < $0.scenarios.count { $0.scenarios.remove(at: index) } }
    }

    private func update(_ change: (inout PolishSettings) -> Void) {
        var s = model.settings
        change(&s.polish)
        model.onUpdateSettings(s)
    }
}

/// Один сценарий: где срабатывает и что меняет. Пустые значения — как в общих настройках.
struct ScenarioEditor: View {
    @Binding var scenario: Scenario
    let packs: [StylePackInfo]
    var onRemove: () -> Void
    @State private var apps = ""
    @State private var hosts = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.xs) {
                MostikTextField(placeholder: L("Название", "Name"), text: $scenario.name)
                check(L("Включён", "On"), $scenario.enabled)
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.inkSecondary)
                        .frame(width: DS.hit, height: DS.hit).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .iconHelp(L("Убрать сценарий", "Remove scenario"))
            }
            HStack(spacing: DS.Space.xs) {
                MostikTextField(placeholder: L("Приложения: com.apple.mail, …", "Apps: com.apple.mail, …"), text: list(\.apps), monospaced: true)
                MostikTextField(placeholder: L("сайты: mail.yandex.ru", "sites: mail.google.com"), text: list(\.hosts), monospaced: true)
            }
            optionRow(L("Язык", "Language"), Segmented(options: [(nil, L("как везде", "default")), ("ru", "RU"), ("en", "EN")] as [(String?, String)],
                                                        selection: $scenario.language))
            optionRow(L("Причёсывание", "Polish"),
                      Segmented(options: [(nil, L("как везде", "default")), (PolishBackend.off, L("как сказано", "as spoken")),
                                          (.mlx, L("локально", "local")), (.claude, "Claude/Codex")] as [(PolishBackend?, String)],
                                selection: $scenario.backend))
            optionRow(L("Стиль", "Style"),
                      Segmented(options: [(nil, L("как везде", "default")), (PolishStyle.plain, L("обычный", "plain")),
                                          (.business, L("деловой", "business")), (.brief, L("кратко", "brief")),
                                          (.list, L("списком", "list")), (.task, L("задача", "task"))] as [(PolishStyle?, String)],
                                selection: $scenario.style))
            if !packs.isEmpty {
                optionRow(L("Стиль-файл", "Style file"),
                          Segmented(options: [(nil, L("нет", "none"))] + packs.map { (Optional($0.id), $0.name) },
                                    selection: $scenario.pack))
            }
            optionRow(L("Перевод", "Translate"),
                      Segmented(options: [(nil, L("нет", "no")), (TranslateTone.plain, "EN"), (.business, L("EN деловой", "EN business")),
                                          (.dev, L("EN разработчик", "EN developer"))] as [(TranslateTone?, String)],
                                selection: Binding(get: { scenario.translate?.tone },
                                                   set: { scenario.translate = $0.map { PolishTranslate(to: "en", tone: $0) } })))
            HStack(spacing: DS.Space.m) {
                check(L("Enter после вставки", "Enter after paste"), flag(\.autoEnter))
            }
            .padding(.top, 2)
        }
        .padding(.vertical, DS.Space.s)
        .opacity(scenario.enabled ? 1 : 0.6)
    }

    /// Галочка без системного чекбокса: в снимках и в тёмной теме выглядит одинаково.
    private func check(_ title: String, _ value: Binding<Bool>) -> some View {
        Button { value.wrappedValue.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: value.wrappedValue ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13)).foregroundStyle(value.wrappedValue ? Palette.accent : Palette.inkTertiary)
                Text(title).font(TType.callout).foregroundStyle(Palette.ink).fixedSize()
            }
            .frame(minHeight: DS.hit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func optionRow<V: View>(_ title: String, _ control: V) -> some View {
        HStack(spacing: DS.Space.s) {
            Text(title).font(TType.callout).foregroundStyle(Palette.inkSecondary).frame(width: 96, alignment: .leading)
            control
            Spacer(minLength: 0)
        }
    }

    private func list(_ key: WritableKeyPath<Scenario, [String]>) -> Binding<String> {
        Binding(get: { scenario[keyPath: key].joined(separator: ", ") },
                set: { text in
                    scenario[keyPath: key] = text.split(whereSeparator: { $0 == "," || $0 == " " })
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                })
    }

    private func flag(_ key: WritableKeyPath<Scenario, Bool?>) -> Binding<Bool> {
        Binding(get: { scenario[keyPath: key] ?? false }, set: { scenario[keyPath: key] = $0 ? true : nil })
    }
}

/// Макет сообщения в Slack: как текст ляжет в чат.
struct SlackMockup: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("# release").font(TType.captionStrong).foregroundStyle(Palette.inkTertiary)
            HStack(alignment: .top, spacing: DS.Space.xs) {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.accentSoft)
                    .overlay(Text("A").font(TType.calloutStrong).foregroundStyle(Palette.accent))
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(L("Анна", "Anna")).font(TType.calloutStrong).foregroundStyle(Palette.ink)
                        Text("15:42").font(TType.caption).foregroundStyle(Palette.inkTertiary)
                    }
                    Text(text).font(TType.body).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(DS.Space.s)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Palette.canvas, in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).strokeBorder(Palette.edge))
    }
}

/// Макет письма: тема, кому, текст.
struct MailMockup: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field(L("Кому", "To"), "team@example.com")
            Hairline()
            field(L("Тема", "Subject"), L("Релиз", "Release"))
            Hairline()
            Text(text).font(TType.body).foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DS.Space.xs)
        }
        .padding(DS.Space.s)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Palette.canvas, in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).strokeBorder(Palette.edge))
    }

    private func field(_ name: String, _ value: String) -> some View {
        HStack(spacing: DS.Space.xs) {
            Text(name).font(TType.caption).foregroundStyle(Palette.inkTertiary).frame(width: 40, alignment: .leading)
            Text(value).font(TType.callout).foregroundStyle(Palette.ink)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

/// Подтверждение установки хуков очереди: что и куда ляжет.
struct QueueHooksSheet: View {
    let plan: AgentVoiceModel.HooksPlan
    var onInstall: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text(L("Подключить очередь к Claude Code", "Connect the queue to Claude Code"))
                .font(TType.headline).foregroundStyle(Palette.ink)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                item("1", L("Скрипт очереди", "Queue script"), plan.scriptPath,
                     L("Отмечает, что агент занят, и отдаёт ему надиктованное из папки Mostik. В сеть не ходит. Пока очередь выключена в Настройках — ничего не делает.",
                       "Marks the agent as busy and hands it what you dictated from Mostik’s folder. No network. Does nothing while the queue is off in Settings."))
                item("2", L("Настройки Claude Code", "Claude Code settings"), plan.settingsPath,
                     plan.backupPath == nil
                        ? L("Файла нет — он будет создан с записями ниже.", "No file yet — it will be created with the entries below.")
                        : L("Добавятся записи ниже, остальное, включая хуки озвучки, не меняется.", "The entries below are added; nothing else, including voice hooks, changes."))
                if let backup = plan.backupPath {
                    item("3", L("Копия прежнего файла", "Copy of the old file"), backup,
                         L("На случай, если захотите вернуть всё как было.", "In case you want everything back as it was."))
                }
            }
            Text(plan.preview)
                .font(TType.code).foregroundStyle(Palette.inkSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Space.s)
                .background(Palette.canvas, in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
            HStack(spacing: DS.Space.xs) {
                Spacer()
                Button(L("Отмена", "Cancel"), action: onCancel).buttonStyle(.mostik(.quiet)).keyboardShortcut(.cancelAction)
                Button(L("Установить", "Install"), action: onInstall).buttonStyle(.mostikPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Space.l)
        .frame(width: 520)
        .background(Palette.surface)
    }

    private func item(_ number: String, _ title: String, _ path: String, _ note: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Text(number).font(TType.figure(12, .semibold)).foregroundStyle(Palette.inkTertiary).frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(TType.bodyStrong).foregroundStyle(Palette.ink)
                Text(NSString(string: path).abbreviatingWithTildeInPath).font(TType.code).foregroundStyle(Palette.inkSecondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                Text(note).font(TType.callout).foregroundStyle(Palette.inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
