import SwiftUI
import MostikCore

// Сводка встречи сверх M5–M7: разделы по темам и людям (M17), протокол (W8), шаблон по типу
// встречи (M16), несколько видов сводки (W22), свои записи и картинки как вход (W23), рецепты (W7)
// и следующие шаги черновиками (W25). Всё нарисовано на SwiftUI — снимки совпадают с приложением.

// MARK: - Тело сводки: разделы, решения, протокол

struct MeetingSummaryBody: View {
    let result: MeetingAIResult
    let refChips: ([Int]) -> AnyView

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            if !result.overview.isEmpty {
                Text(result.overview)
                    .font(TType.reading)
                    .lineSpacing(4)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if result.isProtocol {
                protocolView
            } else {
                ForEach(Array(result.groupedPoints.enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        if let title = group.title {
                            Text(title)
                                .font(TType.bodyStrong)
                                .foregroundStyle(Palette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(Array(group.points.enumerated()), id: \.offset) { _, point in pointRow(point) }
                    }
                }
                if !result.decisions.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        GroupLabel(text: L("Решения", "Decisions"))
                        ForEach(Array(result.decisions.enumerated()), id: \.offset) { _, point in
                            pointRow(point, symbol: "checkmark.seal")
                        }
                    }
                }
            }
        }
    }

    private func pointRow(_ point: MeetingAIPoint, symbol: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 12)
            } else {
                Circle().fill(Palette.inkTertiary).frame(width: 4, height: 4).offset(y: -3)
            }
            // Таймкоды — ссылкой в конце строки, без плашек (П9-B).
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(point.text)
                        .font(TType.body)
                        .lineSpacing(2)
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if point.fromNotes { MeetingSummaryTag(text: L("из моих записей", "from my notes"), symbol: "square.and.pencil") }
                }
                Spacer(minLength: 0)
                refChips(point.refs)
            }
        }
    }

    // W8: вопросы по повестке, СЛУШАЛИ / РЕШИЛИ.
    private var protocolView: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            ForEach(Array(result.agenda.enumerated()), id: \.offset) { index, item in
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("\(index + 1). " + item.question)
                        .font(TType.bodyStrong)
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if !item.heard.isEmpty {
                        protocolLabel(L("СЛУШАЛИ", "HEARD"))
                        ForEach(Array(item.heard.enumerated()), id: \.offset) { _, point in pointRow(point) }
                    }
                    protocolLabel(L("РЕШИЛИ", "DECIDED"))
                    if item.decided.isEmpty {
                        Text(L("Решения не приняли.", "No decision taken."))
                            .font(TType.callout).foregroundStyle(Palette.inkSecondary)
                    }
                    ForEach(Array(item.decided.enumerated()), id: \.offset) { _, point in
                        VStack(alignment: .leading, spacing: 4) {
                            pointRow(point, symbol: "checkmark.seal")
                            if !point.formOK {
                                MeetingSummaryWarning(text: L("Решение пишется инфинитивом: «Утвердить…», «Поручить…».",
                                                              "Not phrased as a resolution: “Approve…”, “Assign…”."))
                                    .padding(.leading, 20)
                            }
                        }
                    }
                }
            }
        }
    }

    private func protocolLabel(_ text: String) -> some View {
        Text(text)
            .font(TType.captionStrong)
            .tracking(0.6)
            .foregroundStyle(Palette.inkTertiary)
            .padding(.top, 2)
    }
}

/// Пометка рядом с пунктом: маленькая капсула.
struct MeetingSummaryTag: View {
    let text: String
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
            Text(text).font(TType.caption)
        }
        .foregroundStyle(Palette.inkSecondary)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Palette.sunken, in: Capsule())
    }
}

/// Предупреждение тоном «сомнения»: протоколу не хватает исполнителя, срока или формы.
struct MeetingSummaryWarning: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 10, weight: .medium))
            Text(text).font(TType.callout).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Palette.doubt)
        .padding(.horizontal, DS.Space.xs)
        .padding(.vertical, 4)
        .background(Palette.doubtSoft, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
    }
}

// MARK: - Вид сводки: одно меню в строке разделов (R3a)

/// «Вид сводки ▾»: подробно или кратко, другие виды (протокол, для руководителя, только решения, свои),
/// «Своя…» и шаблон пересказа — одним системным меню вместо четырёх рядов переключателей.
/// Что ещё не сделано, помечено «…»: выбор запускает модель через то же согласие.
struct MeetingSummaryViewMenu: View {
    @ObservedObject var ai: MeetingAIModel
    let meeting: String
    let mode: MeetingAIMode
    /// Переключить «Подробно / Кратко» основной сводки (недостающий режим строится сразу).
    let switchMode: (MeetingAIMode) -> Void
    let start: (_ action: @escaping () -> Void) -> Void
    @Environment(\.mostikSnapshot) private var snapshot

    private var file: MeetingAIFile? { ai.files[meeting] }
    private var shown: String { ai.shownView(for: meeting) }

    var body: some View {
        Group {
            if snapshot {
                // `ImageRenderer` системное меню не рисует — в снимке его кнопка.
                label
            } else {
                Menu { items } label: { label }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
            }
        }
        .help(L("Вид сводки: подробно, кратко, протокол, для руководителя или свой",
                "Summary view: detailed, brief, minutes, for the boss or your own"))
        .accessibilityLabel(L("Вид сводки: ", "Summary view: ") + currentName)
    }

    // MARK: кнопка меню

    private var label: some View {
        HStack(spacing: 6) {
            Text(L("Вид сводки", "Summary view"))
                .foregroundStyle(Palette.inkSecondary)
            Text(currentName)
                .fontWeight(.semibold)
                .foregroundStyle(Palette.ink)
            if working(shown) {
                Image(systemName: "hourglass").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Palette.inkSecondary)
        }
        .font(TType.callout)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(minHeight: 24)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(Palette.edgeStrong))
        .frame(minHeight: DS.hit)
        .contentShape(Rectangle())
    }

    private var currentName: String {
        if shown == MeetingAIVariant.main {
            return mode == .brief ? L("Кратко", "Brief") : L("Подробно", "Detailed")
        }
        return extraViews.first { $0.0 == shown }?.1 ?? L("Своя", "Custom")
    }

    // MARK: пункты

    @ViewBuilder private var items: some View {
        Section(L("Основная сводка", "Main summary")) {
            Toggle(L("Подробно", "Detailed"), isOn: modeBinding(.detailed))
            Toggle(L("Кратко", "Brief"), isOn: modeBinding(.brief))
        }
        Section(L("Другие виды — основная сводка не меняется", "Other views — the main summary stays")) {
            ForEach(extraViews, id: \.0) { key, name in
                Toggle(itemTitle(key, name), isOn: viewBinding(key))
            }
            Button(L("Своя…", "Custom…")) { ai.customFor = meeting }
        }
        if !regularTemplates.isEmpty {
            Section(L("Шаблон сводки — прежний сохранится в папке встречи", "Summary template — the old one stays in the meeting folder")) {
                Toggle(L("Сам по событию", "From the event") + (autoTemplate ? " · " + usedTemplateName : ""),
                       isOn: templateBinding(nil))
                ForEach(regularTemplates) { template in
                    Toggle(template.title(russian: L10n.isRussian) + (template.source == "user" ? L(" · мой", " · mine") : ""),
                           isOn: templateBinding(template.id))
                }
                Button(L("Свои шаблоны…", "My templates…")) { ai.onOpenTemplatesFolder() }
            }
        }
    }

    /// Не сделанный ещё вид — с «…»: выбор запустит модель; идущий — с пометкой.
    private func itemTitle(_ key: String, _ name: String) -> String {
        if working(key) { return name + L(" — делается", " — in progress") }
        return file?.variants[key] != nil ? name : name + "…"
    }

    private func modeBinding(_ value: MeetingAIMode) -> Binding<Bool> {
        Binding(get: { shown == MeetingAIVariant.main && mode == value },
                set: { _ in
                    ai.view[meeting] = MeetingAIVariant.main
                    if mode != value { switchMode(value) }
                })
    }

    private func viewBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { shown == key },
                set: { _ in
                    if file?.variants[key] != nil || working(key) {
                        ai.view[meeting] = key
                    } else {
                        start { ai.onRunVariant(meeting, key, nil) }
                    }
                })
    }

    private func templateBinding(_ id: String?) -> Binding<Bool> {
        Binding(get: { id == nil ? autoTemplate : (!autoTemplate && usedTemplate == id) },
                set: { _ in start { ai.onChooseTemplate(meeting, id) } })
    }

    private func working(_ key: String) -> Bool {
        switch ai.variantPhase(meeting, key) {
        case .queued, .running: return true
        default: return false
        }
    }

    private var extraViews: [(String, String)] {
        let known = MeetingTemplateInfo.extraViews.map { id in (id, ai.templateName(id) ?? fallbackName(id)) }
        let custom = (file?.variantKeys ?? []).filter(MeetingAIVariant.isCustom).map { key in
            (key, file?.variants[key]?.title ?? file?.variants[key]?.instruction ?? L("Своя", "Custom"))
        }
        return known + custom
    }

    private func fallbackName(_ id: String) -> String {
        switch id {
        case "protocol": return L("Протокол", "Minutes")
        case "exec": return L("Для руководителя", "For the boss")
        case "decisions": return L("Только решения", "Decisions only")
        default: return id
        }
    }

    // M16: шаблон основной сводки — сам по событию или выбранный.
    private var usedTemplate: String? { file?.template ?? ai.result(for: meeting)?.template }
    private var usedTemplateName: String {
        let name = ai.templateName(usedTemplate) ?? ai.result(for: meeting)?.templateName ?? ""
        return name.isEmpty ? L("обычная встреча", "general meeting") : name
    }
    private var autoTemplate: Bool { ai.chosenTemplate[meeting] == nil && (file?.templateAuto ?? true) }
    private var regularTemplates: [MeetingTemplateInfo] {
        ai.templates.filter { !MeetingTemplateInfo.extraViews.contains($0.id) }
    }
}

/// «Своя…»: сводка по описанию словами; появляется под строкой разделов, пока открыта.
struct MeetingSummaryCustomField: View {
    @ObservedObject var ai: MeetingAIModel
    let meeting: String
    let start: (_ action: @escaping () -> Void) -> Void
    @State private var custom = ""

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            MostikTextField(placeholder: L("Какой нужна сводка: «только риски и сроки»", "What you need: “risks and deadlines only”"),
                            text: $custom, leadingSymbol: "text.cursor")
                .onSubmit(submit)
            Button(L("Сделать", "Make"), action: submit)
                .buttonStyle(.mostik(.primary, compact: true))
                .disabled(custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(L("Отмена", "Cancel")) { ai.customFor = nil }
                .buttonStyle(.mostik(.quiet, compact: true))
        }
    }

    private func submit() {
        let text = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        custom = ""
        ai.customFor = nil
        start { ai.onRunVariant(meeting, "custom", text) }
    }
}

// MARK: - Свои записи и картинки (W23)

struct MeetingInputsStrip: View {
    @ObservedObject var model: AppModel
    @ObservedObject var ai: MeetingAIModel
    let meeting: String
    let used: MeetingAIInputs?

    private var info: MeetingAIModel.MeetingInputsInfo { ai.inputs[meeting] ?? .init(notesChars: 0, images: []) }

    /// Учитывать нечего (R3a): ни записей, ни картинок, ни повестки — переключатель неактивен.
    private var empty: Bool { info.notesChars == 0 && info.images.isEmpty && (used?.agenda ?? 0) == 0 }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L("Учитывать мои заметки и картинки", "Use my notes and images"))
                .font(TType.body).foregroundStyle(empty ? Palette.inkSecondary : Palette.ink)
            Text(summaryLine)
                .font(TType.callout).foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if empty {
                // Выключатель погашен и не нажимается, пока материалов нет; включённая настройка не теряется.
                HStack(spacing: DS.Space.s) {
                    label
                    Spacer(minLength: DS.Space.s)
                    Capsule(style: .continuous)
                        .fill(Palette.edgeStrong.opacity(0.55))
                        .frame(width: 32, height: 18)
                        .overlay(alignment: .leading) {
                            Circle().fill(Palette.surface).frame(width: 14, height: 14).padding(2)
                        }
                }
                .frame(minHeight: DS.hit)
                .accessibilityRepresentation {
                    Toggle(isOn: .constant(false)) { label }.disabled(true)
                }
            } else {
                Toggle(isOn: Binding(get: { model.settings.meetingNotes.useMyNotes }, set: { ai.onUseNotes($0) })) { label }
                    .toggleStyle(MostikToggleStyle())
            }
            HStack(spacing: DS.Space.xs) {
                Button { ai.onOpenNotes(meeting) } label: {
                    Label(L("Мои заметки", "My notes"), systemImage: "square.and.pencil")
                }
                .buttonStyle(.mostik(.quiet, compact: true))
                Button { ai.onAddImages(meeting) } label: {
                    Label(L("Добавить картинку…", "Add image…"), systemImage: "photo.badge.plus")
                }
                .buttonStyle(.mostik(.quiet, compact: true))
                .help(L("Скриншот слайда или доски: текст распознаётся на этом Mac, в модель уходят подпись и этот текст.",
                        "A slide or whiteboard shot: its text is read on this Mac; the model gets the caption and that text."))
            }
        }
    }

    private var summaryLine: String {
        var parts: [String] = []
        if info.notesChars > 0 { parts.append(L("заметки — \(info.notesChars) зн.", "notes — \(info.notesChars) chars")) }
        if !info.images.isEmpty {
            parts.append(L10n.plural(info.images.count, ru: "картинка", "картинки", "картинок", en: "image", "images"))
        }
        var line = parts.isEmpty ? L("Станет доступно, когда у встречи появятся повестка, ваши записи или скриншоты: они пойдут в сводку отдельно от расшифровки.",
                                     "Available once the meeting has an agenda, your notes or screenshots: they go in separately from the transcript.")
                                 : L("Во встрече: ", "In this meeting: ") + parts.joined(separator: ", ")
        if let used, used.used, used.notesChars + used.images + used.agenda > 0 {
            line += L(". В текущей сводке учтены.", ". Used in this summary.")
        }
        return line
    }
}

// MARK: - После встречи: рецепты и следующие шаги

struct MeetingAfterActions: View {
    @ObservedObject var ai: MeetingAIModel
    @ObservedObject var extras: MeetingExtrasModel
    let meeting: String
    let sensitive: Bool
    let start: (_ action: @escaping () -> Void) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            GroupLabel(text: L("После встречи", "After the meeting"))
            if sensitive {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "lock").font(.system(size: 11, weight: .medium))
                    Text(L("Письмо, задачи и событие по встрече недоступны: она только для этого Mac.",
                           "Email, tasks and event are unavailable: this meeting is for this Mac only."))
                        .font(TType.callout).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Palette.inkSecondary)
                MeetingUnlockButton(extras: extras, meeting: meeting)
            } else {
                FlowLayout(spacing: DS.Space.xs) {
                    Button { ai.onOpenNextSteps(meeting) } label: {
                        Label(L("Следующие шаги…", "Next steps…"), systemImage: "arrow.turn.down.right")
                    }
                    .buttonStyle(.mostik(.secondary, compact: true))
                    .help(L("Письмо, задачи и событие черновиками: ничего не отправляется само",
                            "Email, tasks and an event as drafts: nothing is sent on its own"))
                }
            }
        }
    }
}

// MARK: - Листы: рецепт и следующие шаги

/// Подложка листа поверх вкладки — как у согласия.
struct MeetingSheetChrome<Content: View>: View {
    let width: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(DS.Space.l)
            .frame(width: width)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.card + 4, style: .continuous)
                    .fill(Palette.surface)
                    .shadow(color: .black.opacity(0.14), radius: 10, y: 6)
            )
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card + 4, style: .continuous).strokeBorder(Palette.edgeStrong))
    }
}

/// Текст черновика в рамке с прокруткой; выделяется и копируется.
struct MeetingDraftText: View {
    let text: String
    var height: CGFloat = 220
    @Environment(\.mostikSnapshot) private var snapshot

    private var content: some View {
        Text(text)
            .font(TType.body)
            .lineSpacing(3)
            .foregroundStyle(Palette.ink)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Space.s)
    }

    var body: some View {
        Group {
            // ScrollView в снимке пуст — рисуем текст сверху, обрезая по высоте.
            if snapshot {
                content.frame(maxHeight: .infinity, alignment: .top).clipped()
            } else {
                ScrollView { content }
            }
        }
        .frame(height: height)
        .background(Palette.sunken, in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).strokeBorder(Palette.edge))
    }
}

struct MeetingRecipeSheet: View {
    @ObservedObject var ai: MeetingAIModel
    let preview: MeetingAIModel.RecipePreview

    private var email: MeetingEmailDraft {
        var lines = preview.text.components(separatedBy: "\n")
        var subject = ""
        if let first = lines.first, let range = first.range(of: #"^(Тема|Subject):\s*"#, options: .regularExpression) {
            subject = String(first[range.upperBound...])
            lines.removeFirst()
        }
        return MeetingEmailDraft(subject: subject, body: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        MeetingSheetChrome(width: 560) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: preview.email ? "envelope" : "doc.text")
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.accent)
                    Text(preview.name).font(TType.headline).foregroundStyle(Palette.ink)
                    Spacer()
                    MeetingSummaryTag(text: L("черновик", "draft"))
                    // Выход без «Готово»: крестик и Esc (клик мимо листа — в MeetingAIConsentOverlay).
                    Button { ai.recipePreview = nil } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.inkSecondary)
                            .frame(width: DS.hit, height: DS.hit)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(RowButtonStyle(radius: DS.Radius.row))
                    .keyboardShortcut(.cancelAction)
                    .help(L("Закрыть", "Close"))
                    .accessibilityLabel(L("Закрыть", "Close"))
                }
                MeetingDraftText(text: preview.text, height: 280)
                Text(preview.email
                     ? L("Письмо не отправляется: «Открыть в Почте» создаст неотправленный черновик, адресатов впишете сами.",
                         "Nothing is sent: “Open in Mail” makes an unsent draft; you add the recipients.")
                     : L("Черновик сохранён в папке встречи, в recipes/.", "The draft is saved in the meeting folder, under recipes/."))
                    .font(TType.callout).foregroundStyle(Palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DS.Space.xs) {
                    if let path = preview.path {
                        Button { ai.onReveal(path) } label: { Label(L("Показать файл", "Show file"), systemImage: "folder") }
                            .buttonStyle(.mostik(.quiet))
                    }
                    Spacer()
                    Button(L("Копировать", "Copy")) { ai.onCopy(preview.text) }
                        .buttonStyle(.mostikSecondary)
                    if preview.email {
                        Button(L("Открыть в Почте", "Open in Mail")) { ai.onOpenMailDraft(email) }
                            .buttonStyle(.mostikSecondary)
                    }
                    Button(L("Готово", "Done")) { ai.recipePreview = nil }
                        .buttonStyle(.mostikPrimary)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

struct MeetingNextStepsSheet: View {
    @ObservedObject var ai: MeetingAIModel
    let sheet: MeetingAIModel.NextStepsSheet

    private var binding: Binding<MeetingAIModel.NextStepsSheet> {
        Binding(get: { ai.nextSteps ?? sheet }, set: { ai.nextSteps = $0 })
    }

    var body: some View {
        let current = ai.nextSteps ?? sheet
        MeetingSheetChrome(width: 580) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.accent)
                    Text(L("Следующие шаги", "Next steps")).font(TType.headline).foregroundStyle(Palette.ink)
                    Spacer()
                    Segmented(options: [(MeetingAIModel.NextStepsSheet.Tab.email, L("Письмо", "Email")),
                                        (.tasks, L("Задачи", "Tasks")),
                                        (.event, L("Событие", "Event"))],
                              selection: binding.tab)
                }
                switch current.tab {
                case .email: emailTab(current)
                case .tasks: tasksTab(current)
                case .event: eventTab(current)
                }
                Text(L("Всё это черновики: Mostik сам ничего не отправляет и не создаёт в почте, трекере и календаре.",
                       "All drafts: Mostik never sends or creates anything in mail, trackers or calendars on its own."))
                    .font(TType.callout).foregroundStyle(Palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func emailTab(_ current: MeetingAIModel.NextStepsSheet) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            MostikTextField(placeholder: L("Кому: адреса через запятую", "To: comma-separated addresses"),
                            text: binding.steps.email.to, leadingSymbol: "person")
            MostikTextField(placeholder: L("Тема", "Subject"), text: binding.steps.email.subject, leadingSymbol: "textformat")
            MeetingDraftText(text: current.steps.email.body)
            HStack(spacing: DS.Space.xs) {
                Spacer()
                closeButton
                Button(L("Копировать", "Copy")) {
                    ai.onCopy(current.steps.email.subject + "\n\n" + current.steps.email.body)
                }
                .buttonStyle(.mostikSecondary)
                Button(L("Открыть черновик в Почте", "Open draft in Mail")) { ai.onOpenMailDraft(current.steps.email) }
                    .buttonStyle(.mostikPrimary)
                    .help(L("mailto: — почта откроет неотправленное письмо", "mailto: — your mail app opens an unsent message"))
            }
        }
    }

    private func tasksTab(_ current: MeetingAIModel.NextStepsSheet) -> some View {
        let markdown = MeetingNextSteps.tasksMarkdown(current.steps.tasks, russian: L10n.isRussian)
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            if current.steps.tasks.isEmpty {
                Text(L("Поручений во встрече не нашлось.", "No assignments found."))
                    .font(TType.body).foregroundStyle(Palette.inkSecondary)
            }
            MeetingSheetScroll(maxHeight: 240) {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    ForEach(current.steps.tasks.indices, id: \.self) { index in
                        let task = current.steps.tasks[index]
                        Toggle(isOn: binding.steps.tasks[index].include) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.title).font(TType.body).foregroundStyle(Palette.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text([task.assignee ?? L("исполнитель не назван", "no owner named"),
                                      task.due ?? L("срок не назван", "no due date")].joined(separator: " · "))
                                    .font(TType.callout).foregroundStyle(Palette.inkSecondary)
                            }
                        }
                        .toggleStyle(MostikToggleStyle())
                    }
                }
            }
            HStack(spacing: DS.Space.xs) {
                Spacer()
                closeButton
                Button(L("Сохранить .md", "Save .md")) { ai.onSaveTasks(current.meeting, markdown) }
                    .buttonStyle(.mostikSecondary)
                Button(L("Копировать для трекера", "Copy for tracker")) { ai.onCopy(markdown) }
                    .buttonStyle(.mostikPrimary)
                    .disabled(!current.steps.tasks.contains(where: \.include))
            }
        }
    }

    private func eventTab(_ current: MeetingAIModel.NextStepsSheet) -> some View {
        let formatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = L10n.locale
            formatter.dateFormat = L10n.isRussian ? "EEEE, d MMMM, HH:mm" : "EEEE, MMMM d, h:mm a"
            return formatter
        }()
        let event = current.steps.event
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            MostikTextField(placeholder: L("Название", "Title"), text: binding.steps.event.title, leadingSymbol: "calendar")
            HStack(spacing: DS.Space.s) {
                Text(formatter.string(from: event.start)).font(TType.bodyStrong).foregroundStyle(Palette.ink)
                Text(L("\(event.minutes) мин", "\(event.minutes) min")).font(TType.callout).foregroundStyle(Palette.inkSecondary)
                Spacer()
            }
            MeetingDraftText(text: event.notes, height: 120)
            HStack(spacing: DS.Space.xs) {
                if let saved = current.savedICS {
                    Button { ai.onReveal(saved) } label: { Label("follow-up.ics", systemImage: "folder") }
                        .buttonStyle(.mostik(.quiet))
                }
                Spacer()
                closeButton
                Button(L("Сохранить .ics", "Save .ics")) { ai.onSaveICS(current.meeting, event) }
                    .buttonStyle(.mostik(current.savedICS == nil ? .primary : .secondary))
                if let saved = current.savedICS {
                    Button(L("Создать в Календаре…", "Create in Calendar…")) { ai.onAddICSToCalendar(saved) }
                        .buttonStyle(.mostikPrimary)
                        .help(L("Календарь откроет файл и спросит, куда добавить событие", "Calendar opens the file and asks where to add it"))
                }
            }
        }
    }

    private var closeButton: some View {
        Button(L("Закрыть", "Close")) { ai.nextSteps = nil }
            .buttonStyle(.mostik(.quiet))
            .keyboardShortcut(.cancelAction)
    }
}

/// Прокрутка в листе; в снимке ScrollView пуст — там содержимое как есть.
struct MeetingSheetScroll<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content
    @Environment(\.mostikSnapshot) private var snapshot

    var body: some View {
        if snapshot {
            content
        } else {
            ScrollView { content }.frame(maxHeight: maxHeight)
        }
    }
}

/// Короткое сообщение внизу вкладки после действия.
struct MeetingSummaryToast: View {
    @ObservedObject var ai: MeetingAIModel

    var body: some View {
        VStack {
            Spacer()
            if let toast = ai.toast {
                Text(toast)
                    .font(TType.callout)
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, DS.Space.s)
                    .padding(.vertical, 8)
                    .background(Palette.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(Palette.edgeStrong))
                    .shadow(color: .black.opacity(0.10), radius: 6, y: 3)
                    .padding(.bottom, DS.Space.l)
                    .transition(.opacity)
                    .task(id: toast) {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        if ai.toast == toast { ai.toast = nil }
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
        .animation(Motion.quick, value: ai.toast)
    }
}
