import AppKit
import SwiftUI
import MostikCore

/// Вкладка «Настройки» главного окна (отзыв автора, B1; имя осталось от отдельного окна R3b):
/// боковая панель с разделами и поиском, справа форма раздела. Открывается ⌘, и ссылками
/// `AppModel.openSettings(_:)`; снимки рендерят её и сами по себе, без панели вкладок.
/// Согласие на облако для причёсывания даётся только здесь — на месте выбора в разделе «Текст».
public struct SettingsWindowView: View {
    @ObservedObject var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        SettingsTab(model: model)
            .frame(minWidth: 760, minHeight: 520)
            .background(Palette.canvas)
            .foregroundStyle(Palette.ink)
            .onAppear { model.onSettingsShown() }
    }
}

/// Содержимое вкладки Настроек (П9-А): слева разделы и поиск, справа форма раздела.
/// Каждое изменение сразу уходит в `onUpdateSettings`. Полный перечень настроек и их разделов —
/// `SettingsIndex`; что ни одна настройка старого экрана не потерялась, проверяет SettingsInventoryTests.
struct SettingsTab: View {
    @ObservedObject var model: AppModel
    @Environment(\.mostikSnapshot) private var snapshot
    @State private var query = ""

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(model: model, query: $query)
                .frame(width: 216)
            Rectangle().fill(Palette.edge).frame(width: 1)
            MostikScroll {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    header
                    pane
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, DS.Space.xl)
                .padding(.top, DS.Space.l)
                .padding(.bottom, DS.Space.xl)
                .frame(maxWidth: .infinity)
            }
            .id(model.settingsPane.rawValue + (model.settingsReveal ?? ""))  // новый раздел — с начала; ссылка с раскрытием — заново
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(model.settingsPane.title).font(TType.title).foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            Text(model.settingsPane.subtitle).font(TType.callout).foregroundStyle(Palette.inkSecondary)
        }
    }

    @ViewBuilder private var pane: some View {
        switch model.settingsPane {
        case .general: generalPane
        case .text: textPane
        case .meetings: meetingsPane
        case .agents: agentsPane
        case .privacy: privacyPane
        }
    }

    // MARK: pane general

    /// Имя учётной записи macOS как подсказка; на снимках — условное, чтобы в картинки не попало настоящее.
    private var namePlaceholder: String {
        let full = snapshot ? "" : NSFullUserName()
        return full.isEmpty ? L("Имя Фамилия", "First Last") : full
    }

    @ViewBuilder private var generalPane: some View {
        // Имя для звонков: своя плитка в Zoom и «Я» в расшифровке. Узнанное на встрече
        // вписывается само, пока поле пустое.
        FormGroup(title: L("Вы", "You")) {
            FormRow(title: L("Имя и фамилия", "Your name"),
                    hint: L("Как в звонках — чтобы отличать вас от собеседника.",
                            "As in calls, to tell you from the others."),
                    details: L("Никуда не отправляется. Если поле пустое, Mostik впишет сюда имя, под которым узнал вас на встрече в Zoom.",
                               "Never sent anywhere. If empty, Mostik fills in the name it recognized you by in a Zoom meeting.")) {
                MostikTextField(placeholder: namePlaceholder,
                                text: bind(\.myName), leadingSymbol: "person")
                    .frame(width: 240)
            }
        }

        FormGroup(title: L("Клавиша записи", "Record key")) {
            // Один контрол: клавиши сами и есть выбор, а не плитка рядом с сегментами (R3b).
            // ⇧-защёлка — умолчание без переключателя (решение автора): о ней говорит «i».
            FormRow(title: L("Держите и говорите", "Hold and speak"),
                    hint: L("Отпустите — текст встанет туда, где курсор.", "Release, and the text lands at the cursor."),
                    details: L("Начали говорить и поняли, что надолго? Нажмите ⇧ и отпустите клавишу — запись продолжится без рук. Esc отменяет запись.",
                               "Started talking and it’s going to take a while? Press ⇧ and let go of the key: recording continues hands-free. Esc cancels.")) {
                KeyPicker(selection: bind(\.holdKey))
            }
            FormDivider()
            FormToggle(title: L("Запись двойным нажатием", "Record with a double tap"),
                       hint: L("Нажмите клавишу дважды — говорите, не держа её. Ещё раз — стоп.",
                               "Tap the key twice to talk without holding it. Tap again to stop."),
                       isOn: bind(\.handsFreeDoubleTap))
            FormDivider()
            // Окошко диктовки перетаскивается мышью (решение автора); вернуть — здесь.
            FormRow(title: L("Окошко диктовки", "Dictation window"),
                    hint: model.hudMoved
                        ? L("Стоит там, куда вы его перетащили.", "It stays where you dragged it.")
                        : L("Внизу по центру экрана. Его можно перетащить мышью.", "Bottom centre of the screen. Drag it to move it.")) {
                Button(L("Вернуть на место", "Move back")) { model.onResetHUDPosition() }
                    .buttonStyle(.mostik(.secondary, compact: true))
                    .disabled(!model.hudMoved)
            }
        }

        FormGroup(title: L("Микрофон", "Microphone")) {
            MicrophoneRow(model: model)
            FormDivider()
            FormToggle(title: L("Шумоподавление", "Noise suppression"),
                       hint: L("Глушит вентилятор и клавиатуру во время диктовки.", "Removes fan and keyboard noise while you dictate."),
                       details: L("Голос звучит чуть по-телефонному, а музыка и звонки на время диктовки становятся тише.",
                                  "Your voice sounds slightly phone-like, and music and calls get quieter while you dictate."),
                       isOn: bind(\.meetingLive.dictationVoiceProcessing))
            FormDivider()
            FormToggle(title: L("Приглушать звук во время записи", "Mute sound while recording"),
                       hint: L("Музыка и видео молчат, пока вы диктуете.", "Music and video go quiet while you dictate."),
                       isOn: bind(\.muteWhileRecording))
        }

        FormGroup(title: L("Язык", "Language")) {
            FormRow(title: L("Язык диктовки", "Dictation language"),
                    hint: L("Mostik ждёт этот язык, если не определил другой.",
                            "Mostik expects this language unless it detects another.")) {
                Segmented(options: [("ru", "Русский"), ("en", "English")], selection: bind(\.language))
            }
            FormDivider()
            LanguageAutoRows(model: model)
        }

        FormGroup(title: L("Запуск", "Startup")) {
            FormToggle(title: L("Запускать при входе в систему", "Open at login"),
                       hint: L("Mostik будет в строке меню сразу после входа в macOS.",
                               "Mostik is in the menu bar right after you log in to macOS."),
                       details: L("Если macOS не дала включить, причина — в «Диагностике» (Приватность и данные → Дополнительно).",
                                  "If macOS didn’t allow it, the reason is in Diagnostics (Privacy & Data → Advanced)."),
                       isOn: bind(\.launchAtLogin))
        }

        // Редкое — свёрнуто со сводкой; если что-то уже включено, группа открыта сразу.
        let mouseOn = model.settings.mouseTrigger != "off"
        let headsetOn = model.settings.headsetTrigger
        FormDisclosure(title: L("Другие способы начать запись", "Other ways to start recording"),
                       contents: L("Сочетание, мышь, гарнитура", "Shortcut, mouse, headset"),
                       state: otherTriggersState(mouse: mouseOn, headset: headsetOn, toggle: model.settings.toggleShortcutEnabled),
                       open: mouseOn || headsetOn || model.settingsReveal == "triggers") {
            FormToggle(title: L("Начать и остановить сочетанием", "Start and stop with a shortcut"),
                       keys: ["⌥", "Space"],
                       hint: L("Из любого приложения. Другие приложения это сочетание не получат.",
                               "From any app. Other apps stop getting this shortcut."),
                       isOn: bind(\.toggleShortcutEnabled))
            FormDivider()
            FormRow(title: L("Боковая кнопка мыши", "Side mouse button"),
                    hint: L("Работает как клавиша записи: держите и говорите.", "Works like the record key: hold and speak."),
                    details: L("Пока включено, своё действие кнопки, например «назад» в браузере, не срабатывает.",
                               "While on, the button’s own action, such as Back in a browser, is off.")) {
                Segmented(options: [("off", L("Выкл", "Off")), ("back", L("«Назад»", "Back")), ("forward", L("«Вперёд»", "Forward"))],
                          selection: bind(\.mouseTrigger))
            }
            FormDivider()
            FormToggle(title: L("Кнопка гарнитуры", "Headset button"),
                       hint: L("▶︎⏸ на гарнитуре начинает и останавливает запись.", "▶︎⏸ on the headset starts and stops recording."),
                       details: L("Медиаклавиша на клавиатуре тоже перестаёт управлять музыкой.",
                                  "The keyboard media key stops controlling music too."),
                       isOn: bind(\.headsetTrigger))
        }
    }

    private func otherTriggersState(mouse: Bool, headset: Bool, toggle: Bool) -> String {
        var on: [String] = []
        if toggle { on.append(L("сочетание", "shortcut")) }
        if mouse { on.append(L("мышь", "mouse")) }
        if headset { on.append(L("гарнитура", "headset")) }
        return on.isEmpty ? L("всё выключено", "all off") : L("включено: ", "on: ") + on.joined(separator: ", ")
    }

    // MARK: pane text

    @ViewBuilder private var textPane: some View {
        let backend = model.settings.polish.effectiveBackend
        let pending = model.polishConsentPending
        FormGroup(title: L("Причёсывание", "Polishing")) {
            let shown = pending ? PolishBackend.claude : backend
            FormRow(title: L("Чем причёсывать", "Polish with"), hint: polishHint(shown), details: polishDetails(shown),
                    warning: polishUnavailable(shown)) {
                Segmented(options: [(PolishBackend.off, L("Выкл", "Off")),
                                    (.mlx, L("На этом Mac", "On this Mac")),
                                    (.claude, "Claude/Codex")],
                          selection: Binding(get: { pending ? .claude : backend }, set: { choosePolishBackend($0) }))
                    .accessibilityLabel(L("Чем причёсывать", "Polish with"))
            }
            // Облако — предупреждение прямо под выбором (слепой раунд 4), без окна поверх Настроек.
            if pending {
                cloudConsent
            } else if backend == .claude {
                cloudNotice
                MeetingCloudOffer(model: model)
            }
            if backend == .mlx, let row = localModelRow, !row.installed {
                FormDivider()
                localModelDownload(row)
            }
            if backend != .off {
                FormDivider()
                FormRow(title: L("Стиль", "Style"),
                        hint: L("Как переписать сказанное.", "How to rewrite what you said.")) {
                    Segmented(options: [(PolishStyle.plain, L("Обычный", "Plain")),
                                        (.business, L("Деловой", "Business")),
                                        (.brief, L("Кратко", "Brief")),
                                        (.list, L("Списком", "List"))],
                              selection: Binding(get: { model.settings.polish.style },
                                                 set: { value in var s = model.settings; s.polish.style = value; model.onUpdateSettings(s) }))
                }
            }
        }

        // «Абзац» и «Зачеркни» — умолчания без переключателя (решение автора): на виду два правила.
        PolishExtrasSection(model: model, parts: [.rules])

        if backend != .off {
            PolishExtrasSection(model: model, parts: [.context])
        }

        // Слепой раунд 4: сценарии и прежние «Исключения» — одна группа с явным порядком.
        let p = model.settings.polish
        let appRules = p.scenarios.count + p.forcedOn.count + p.forcedOff.count
        FormDisclosure(title: L("Приложения и сайты", "Apps and sites"),
                       contents: L("Сценарии и исключения", "Scenarios and exceptions"),
                       state: appRules == 0 ? L("везде общие правила", "general rules everywhere")
                                            : L10n.plural(appRules, ru: "своё правило", "своих правила", "своих правил",
                                                          en: "custom rule", "custom rules"),
                       open: appRules > 0 || model.settingsReveal == "apps") {
            FormNote(text: L("Что важнее: сценарий → исключение → общие правила. Подошли несколько сценариев — действует верхний.",
                             "What wins: scenario → exception → general rules. If several scenarios match, the top one wins."))
            FormDivider()
            PolishExtrasSection(model: model, parts: [.scenarios])
            if backend != .off {
                FormDivider()
                FormRow(title: L("Исключения: не причёсывать или всегда", "Exceptions: never or always polish"),
                        hint: L("Везде, кроме окон агентов: агенту нужен точный текст.",
                                "Everywhere except agent windows: an agent needs the exact text.")) { EmptyView() }
                AppOverrideList(overrides: p.forcedOn.map { ($0, true) } + p.forcedOff.map { ($0, false) },
                                onTitle: L("причёсывать", "polish"), offTitle: L("как сказано", "as spoken"),
                                set: { bundle, on in var s = model.settings; s.polish.setOverride(bundle, on); model.onUpdateSettings(s) })
            }
        }

        // Действия голосом — реже нужны, чем правила: свёрнуты, пока ничего не включено.
        let editOn = model.settings.voiceEdit
        let intentsOn = model.settings.voiceIntents.enabled
        FormDisclosure(title: L("Действия голосом", "Voice actions"),
                       contents: L("Правка выделенного, встречи и письма", "Edit a selection, events and emails"),
                       state: voiceActionsState(edit: editOn, intents: intentsOn),
                       open: editOn || intentsOn || model.settingsReveal == "voice") {
            VoiceEditSettingsRow(model: model)
            FormDivider()
            VoiceIntentSettingsSection(model: model)  // D6: действия голосом по ⌃⌘K
        }

        FormDisclosure(title: L("Стили и разовые режимы", "Styles and one-off modes"),
                       contents: L("Свои стили, перевод, задача для агента", "Custom styles, translation, task for an agent"),
                       state: stylesState,
                       open: model.settingsReveal == "styles", grouped: false) {
            PolishExtrasSection(model: model, parts: backend == .off ? [.modes] : [.styleFiles, .modes, .tone])
        }
    }

    private func voiceActionsState(edit: Bool, intents: Bool) -> String {
        var on: [String] = []
        if edit { on.append(L("правка", "edit")) }
        if intents { on.append(L("встречи и письма", "events and emails")) }
        return on.isEmpty ? L("всё выключено", "all off") : L("включено: ", "on: ") + on.joined(separator: ", ")
    }

    /// Какой стиль действует сейчас: встроенный или из папки.
    private var stylesState: String {
        if let id = model.settings.polish.pack, let pack = model.polishExtras.packs.first(where: { $0.id == id }) {
            return L("стиль «\(pack.name)»", "style “\(pack.name)”")
        }
        return L("встроенный стиль", "built-in style")
    }

    /// Строка модели на этом Mac из каталога движка (`purpose == "llm"`).
    private var localModelRow: ModelRow? { model.models.rows.first { $0.purpose == "llm" } }

    private func localModelDownload(_ row: ModelRow) -> some View {
        FormRow(title: L("Модель на этом Mac", "On-device model"),
                hint: L("Не установлена · ", "Not installed · ") + ModelCatalog.size(row.size, russian: L10n.isRussian),
                warning: true) {
            if let p = model.models.progress[row.key] {
                Text(ModelCatalog.size(p.done, russian: L10n.isRussian) + L(" из ", " of ")
                     + ModelCatalog.size(p.total, russian: L10n.isRussian))
                    .font(TType.body.monospacedDigit()).foregroundStyle(Palette.inkSecondary)
            } else {
                Button(L("Скачать", "Download")) { model.models.start([row.key]) }
                    .buttonStyle(.mostik(.secondary, compact: true))
                    .disabled(model.models.downloading)
            }
        }
    }

    /// Claude включён: где сейчас текст и как вернуть. Строка сводки приватности — тут же, тем же видом.
    private var cloudNotice: some View {
        HStack(alignment: .center, spacing: DS.Space.xs) {
            ledgerPreview(now: true)
            Spacer(minLength: DS.Space.s)
            if model.visibleSettingsPanes.contains(.privacy) {
                Button(L("Открыть «Приватность»", "Open Privacy")) { model.openSettings(.pane(SettingsPane.privacy.rawValue)) }
                    .buttonStyle(.mostik(.quiet, compact: true))
            }
            Button(L("Отозвать согласие", "Revoke consent")) {
                var s = model.settings
                s.polish.cloudConsent = false
                s.polish.backend = .off
                model.onUpdateSettings(s)
            }
            .buttonStyle(.mostik(.quiet, compact: true))
        }
        .padding(.leading, DS.Space.s)
        .padding(.vertical, DS.Space.xxs)
        .background(Palette.doubtSoft, in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
        .padding(.bottom, DS.Space.s)
    }

    /// Claude выбран впервые: предупреждение на месте выбора и то, как изменится «Что уходит с этого Mac».
    /// «Включить Claude» даёт согласие и выбирает бэкенд, «Отмена» оставляет всё как было (G7).
    private var cloudConsent: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                Image(systemName: "cloud")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.doubt)
                    .accessibilityHidden(true)
                Text(L("Каждая диктовка, которую нужно причесать, уйдёт в облако Anthropic или OpenAI по вашей подписке Claude или Codex. Звук не отправляется, только текст. В окнах агентов не причёсываем.",
                       "Every dictation to be polished goes to Anthropic or OpenAI cloud under your Claude/Codex subscription. Only text is sent, never audio. Agent windows are not polished."))
                    .font(TType.callout)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ledgerPreview(now: false)
            HStack(spacing: DS.Space.xs) {
                Spacer(minLength: 0)
                Button(L("Отмена", "Cancel")) { model.polishConsentPending = false }
                    .buttonStyle(.mostik(.quiet, compact: true))
                    .keyboardShortcut(.cancelAction)
                Button(L("Включить Claude/Codex", "Turn on Claude/Codex")) {
                    var s = model.settings
                    s.polish.cloudConsent = true
                    s.polish.backend = .claude
                    model.polishConsentPending = false
                    model.onUpdateSettings(s)
                    // Согласий два (в расшифровке чужие голоса), но спрашиваем о встречах сразу, тут же.
                    model.meetingAI.offerAfterPolish = !MeetingCloudPolicy.cloudAllowed(model.settings)
                }
                .buttonStyle(.mostik(.primary, compact: true))
            }
        }
        .padding(DS.Space.s)
        .background(Palette.doubtSoft, in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
        .padding(.bottom, DS.Space.s)
        .accessibilityElement(children: .contain)
    }

    /// Строка «Текст диктовки» из сводки приватности — с той же точкой состояния, что в «Приватности и данных».
    private func ledgerPreview(now: Bool) -> some View {
        LedgerLine(now: now, what: L("текст диктовки уходит в Anthropic или OpenAI", "dictated text goes to Anthropic or OpenAI"))
    }

    private func polishUnavailable(_ backend: PolishBackend) -> Bool {
        switch backend {
        case .off: false
        case .claude: model.polishAvailable["claude"] == false
        case .mlx: model.polishAvailable["mlx"] != true
        }
    }

    private func polishHint(_ backend: PolishBackend) -> String {
        switch backend {
        case .off:
            return L("Вставляется как сказано, с правилами ниже.", "Text goes in as spoken; only the rules below apply.")
        case .claude:
            if model.polishAvailable["claude"] == false {
                return L("Claude Code не найден на этом Mac — текст вставится как сказано. Установка в Терминале: curl -fsSL https://claude.ai/install.sh | bash, затем войти командой claude.",
                         "Claude Code isn’t on this Mac, so text goes in as spoken. Install in Terminal: curl -fsSL https://claude.ai/install.sh | bash, then sign in with claude.")
            }
            return L("Через Claude/Codex по подписке. Текст появится через 2–3 с.", "Via Claude/Codex on your subscription. Text appears in 2–3 s.")
        case .mlx:
            if model.polishAvailable["mlx"] == true {
                return L("Модель на этом Mac: текст не уходит в сеть, около 2 с.", "On-device model: text stays local, about 2 s.")
            }
            return L("Модель не установлена — текст вставится как сказано.", "Model not installed, so text goes in as spoken.")
        }
    }

    private func polishDetails(_ backend: PolishBackend) -> String {
        let what = L("Причёсывание убирает «э», самоисправления и повторы, расставляет знаки. Смысл не меняется.",
                     "Polishing removes “um”, self-corrections and repeats, and adds punctuation. Meaning stays the same.")
        switch backend {
        case .off:
            return what
        case .claude:
            if model.polishAvailable["claude"] == false {
                return what + " " + L("Программа claude не найдена в PATH и ~/.local/bin, поэтому текст вставляется как сказано.",
                                      "The claude program wasn’t found in PATH or ~/.local/bin, so text goes in as spoken.")
            }
            return what + " " + L("Работает через claude -p (модель haiku), а без Claude Code — через codex exec: 2–5 с после того, как отпустите клавишу. Если ответа нет за 30 с, вставится текст как сказано.",
                                  "Runs via claude -p (haiku), or codex exec without Claude Code: 2–5 s after you release the key. If there’s no reply within 30 s, the text goes in as spoken.")
        case .mlx:
            let size = localModelRow.map { ModelCatalog.size($0.size, russian: L10n.isRussian) } ?? L("около 3,6 ГБ", "about 3.6 GB")
            if model.polishAvailable["mlx"] == true {
                return what + " " + L("Модель на этом Mac (\(size)), текст не уходит в сеть: около 2 с после того, как отпустите клавишу. При сбое вставится текст как сказано.",
                                      "On-device model (\(size)), text stays local: about 2 s after you release the key. On failure the text goes in as spoken.")
            }
            return what + " " + L("Модель на этом Mac (\(size)) пока не установлена — её можно скачать здесь же.",
                                  "The on-device model (\(size)) isn’t installed yet; download it right here.")
        }
    }

    /// `claude` впервые — только через предупреждение об облаке (решение автора по G7).
    private func choosePolishBackend(_ backend: PolishBackend) {
        var s = model.settings
        if backend != .claude {
            model.polishConsentPending = false
            model.meetingAI.offerAfterPolish = false
        }
        if backend == .claude && !s.polish.cloudConsent {
            model.polishConsentPending = true
            return
        }
        s.polish.backend = backend
        model.onUpdateSettings(s)
    }

    // MARK: pane meetings

    @ViewBuilder private var meetingsPane: some View {
        MeetingSettingsSection(model: model)
        meetingNotesGroup
        VoiceMemorySettingsSection(model: model)
        let ms = model.settings
        FormDisclosure(title: L("Ещё", "More"),
                       contents: L("Справка перед встречей, итоги недели, подсказки, сочетание, свои команды",
                                   "Pre-meeting brief, weekly recap, hints, shortcut, your commands"),
                       state: Self.onCount([ms.archive.brief, ms.archive.weeklyDigest, ms.meetingAssist.hints,
                                            ms.meetingLive.hotkey, ms.meetingHook.enabled]),
                       open: model.settings.meetingHook.enabled || model.settings.calendarCommand != nil
                           || model.settingsReveal == "more") {
            ArchiveSettingsSection(model: model)
            FormDivider()
            MeetingAssistSettingsSection(model: model)  // П7: подсказки во время встречи
            FormDivider()
            MeetingLiveSettingsSection(model: model, part: .more)
            FormDivider()
            MeetingHookRows(model: model)
            FormDivider()
            ExternalCalendarRow(model: model)  // календарь без Google и CalDAV — командой (docs/external-calendar.md)
        }
    }

    /// ИИ встреч (M5–M7): по умолчанию та же модель, что у причёсывания, можно выбрать свою;
    /// своё согласие — в расшифровке чужие голоса.
    @ViewBuilder private var meetingNotesGroup: some View {
        let backend = model.settings.meetingEffectiveBackend
        FormGroup(title: L("Заметки и сводка", "Notes and summary")) {
            FormRow(title: L("Модель для встреч", "Model for meetings"),
                    hint: MeetingModelChoice.hint(model.settings, localInstalled: model.localLLMInstalled),
                    details: L("Сводки и названия встреч. «Как у диктовки» — та же модель, что в разделе «Текст». Встречи «Только на этом Mac» обрабатывает только модель на этом Mac: если для встреч выбран Claude/Codex, они уходят на неё.",
                               "Summaries and meeting titles. “Same as dictation” uses the model from Text. “This Mac only” meetings are processed only by the on-device model: when Claude/Codex is chosen for meetings, they go to it instead.")) {
                Segmented(options: [(MeetingModelChoice.same, L("Как у диктовки", "Same as dictation")),
                                    (.mlx, L("На этом Mac", "On this Mac")),
                                    (.claude, "Claude/Codex"),
                                    (.off, L("Выкл", "Off"))],
                          selection: Binding(get: { MeetingModelChoice(model.settings.meetingBackend) },
                                             set: { choice in
                                                 var s = model.settings
                                                 s.meetingBackend = choice.backend
                                                 model.onUpdateSettings(s)
                                             }))
                    .accessibilityLabel(L("Модель для встреч", "Model for meetings"))
            }
            if backend != .off {
                FormDivider()
                MeetingNotesChoice(model: model)
            }
        }
    }

    // MARK: pane agents

    @ViewBuilder private var agentsPane: some View {
        AgentToolsSection(model: model, part: .connect)

        AgentVoiceSection(model: model, part: .main)

        PolishExtrasSection(model: model, parts: [.midTurn])

        FormDisclosure(title: L("Ещё", "More"),
                       contents: L("tmux, приложения агентов, встреча на старте, команда в терминале",
                                   "tmux, agent apps, meeting at start, terminal command"),
                       state: Self.onCount([model.settings.agentVoice.tmuxPaste, model.settings.agentContext.hookEnabled]),
                       open: model.settings.agentContext.hookEnabled || model.settingsReveal == "more") {
            AgentVoiceSection(model: model, part: .tmux)
            FormDivider()
            FormRow(title: L("Приложения агентов", "Agent apps"),
                    hint: L("Mostik сам находит окна с агентом.", "Mostik finds agent windows by itself."),
                    details: agentDetectionDetails) { EmptyView() }
            AppOverrideList(overrides: model.settings.agentPolicy.forcedOn.map { ($0, true) } + model.settings.agentPolicy.forcedOff.map { ($0, false) },
                            onTitle: L("агент", "agent"), offTitle: L("не агент", "not agent"),
                            set: { bundle, on in setOverride(bundle, on) })
            AgentToolsSection(model: model, part: .more)
        }
    }

    /// Состояние свёрнутой группы переключателей: «всё выключено» или «включено 2 из 5».
    static func onCount(_ flags: [Bool]) -> String {
        let on = flags.filter { $0 }.count
        return on == 0 ? L("всё выключено", "all off") : L("включено \(on) из \(flags.count)", "\(on) of \(flags.count) on")
    }

    private var agentDetectionDetails: String {
        let policy = model.settings.agentPolicy
        return L("Mostik узнаёт \(policy.agentApps.count) редакторов, \(policy.terminals.count) терминалов с запущенным \(policy.agentCLIs.sorted().prefix(3).joined(separator: ", ")) и браузеры с \(policy.browserTitleMarkers.joined(separator: ", ")) в заголовке. В окне агента текст не причёсывается, а слова под вопросом идут агенту. Исключения — ниже.",
                 "Detected: \(policy.agentApps.count) editors, \(policy.terminals.count) terminals running \(policy.agentCLIs.sorted().prefix(3).joined(separator: ", ")), browsers with \(policy.browserTitleMarkers.joined(separator: ", ")) in the title. In an agent window text isn’t polished and unsure words go to the agent. Exceptions below.")
    }

    private func setOverride(_ bundle: String, _ on: Bool?) {
        let id = bundle.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        var s = model.settings
        s.agentPolicy.forcedOn.remove(id)
        s.agentPolicy.forcedOff.remove(id)
        if let on { if on { s.agentPolicy.forcedOn.insert(id) } else { s.agentPolicy.forcedOff.insert(id) } }
        model.onUpdateSettings(s)
    }

    // MARK: pane privacy

    @ViewBuilder private var privacyPane: some View {
        // Проверка обновлений — переключатель прямо в строке сводки, а не второй раз группой ниже (слепой раунд 4).
        PrivacyLedger(model: model, updates: UpdateChecksSection())

        FormGroup(title: L("Хранение", "Storage")) {
            FormRow(title: L("Хранить историю", "Keep history"),
                    hint: L("Старые записи удаляются сами.", "Older entries are removed automatically.")) {
                StepperField(value: bind(\.retentionDays), range: 1...90) { Fmt.days($0) }
            }
            FormDivider()
            FormToggle(title: L("Сохранять звук диктовок", "Keep dictation audio"),
                       hint: L("Сутки — чтобы распознать запись заново. Текст остаётся.",
                               "For a day, to re-transcribe. The text stays."),
                       isOn: bind(\.keepAudio))
            FormDivider()
            MeetingAudioRow(model: model)
        }

        FormGroup(title: L("Доступ", "Access")) {
            permissionRow(.microphone, L("Микрофон", "Microphone"),
                          L("Для диктовки и встреч.", "For dictation and meetings."), model.permissions.microphone)
            FormDivider()
            permissionRow(.accessibility, L("Универсальный доступ", "Accessibility"),
                          L("Чтобы слышать клавишу и вставлять текст.", "To hear the hotkey and paste text."),
                          model.permissions.accessibility)
            FormDivider()
            permissionRow(.screenRecording, L("Звук собеседников", "Other side’s audio"),
                          L("Только для встреч. В macOS — «Запись экрана и звука».", "Meetings only. In macOS: Screen & System Audio Recording."),
                          model.permissions.screenRecording)
            FormDivider()
            permissionRow(.screenCapture, L("Запись экрана", "Screen Recording"),
                          L("Для слайдов со встречи. Включается на каждую встречу.", "For meeting slides. Turned on per meeting."),
                          model.permissions.screenCapture)
        }

        FormDisclosure(title: L("Дополнительно", "Advanced"),
                       contents: L("Модели, второе распознавание, диагностика", "Models, second pass, diagnostics"),
                       state: ModelCatalog.summary(model.models.rows, language: model.models.language),
                       open: model.settingsReveal == SettingsRoute.advanced, grouped: false) {
            FormGroup { advancedRows }
            ModelsSection(models: model.models)
            DoctorSection(doctor: model.doctor)
        }
    }

    @ViewBuilder private var advancedRows: some View {
        FormToggle(title: L("Второе распознавание терминов", "Second pass for terms"),
                   hint: L("Вторая модель сверяет термины: меньше ошибок, на полсекунды дольше.",
                           "A second model checks terms: fewer mistakes, half a second slower."),
                   isOn: bind(\.verify))
        FormDivider()
        FormToggle(title: L("Держать микрофон наготове", "Keep the microphone ready"),
                   hint: L("Первое слово не обрежется. Значок микрофона будет гореть всё время.",
                           "The first word isn’t cut off. The microphone icon stays on."),
                   details: L("Mostik не начинает запись без клавиши. С Bluetooth-гарнитурой не работает: она портит звук.",
                              "Mostik never records without the key. Doesn’t work with Bluetooth headsets: they degrade the audio."),
                   isOn: bind(\.warmMicrophone))
        FormDivider()
        FormToggle(title: L("Учиться на правках", "Learn from edits"),
                   hint: L("Предложит запомнить слово, которое вы поправили дважды.", "Offers to remember a word you fixed twice."),
                   details: L("Минуту после вставки Mostik сверяет поле с тем, что вставил. Если одно слово поправлено дважды за неделю, Mostik предложит запомнить написание. В словарь попадает только то, что вы подтвердили. Поля паролей не читаются.",
                              "For a minute after inserting, Mostik compares the field with what it inserted. If you fix the same word twice in a week, it offers to remember the spelling. Only what you confirm goes into the glossary. Password fields are never read."),
                   isOn: bind(\.learnFromEdits))
        FormDivider()
        FormToggle(title: L("Термины из кода", "Terms from code"),
                   hint: L("Для разработчиков: словарь из репозитория, открытого в редакторе или терминале.",
                           "For developers: glossary from the repository open in your editor or terminal."),
                   details: L("Выключено — словарь берётся только из ваших папок с документами, календаря и личного словаря. В репозитории тысячи имён из кода, и с ними русская речь чаще превращается в короткие английские слова. Если проект лежит в «Документах», на «Рабочем столе» или в «Загрузках», macOS один раз спросит доступ к этой папке: Mostik читает её, чтобы найти корень репозитория.",
                              "When off, the glossary comes only from your document folders, calendar and personal glossary. A repository holds thousands of code names, and with them speech more often turns into short English words. If the project is in Documents, Desktop or Downloads, macOS asks once for access to that folder: Mostik reads it to find the repository root."),
                   isOn: bind(\.codeTerms))
        if model.settings.codeTerms {
            FormDivider()
            projectRows
        }
        FormDivider()
        PolishExtrasSection(model: model, parts: [.advanced])
        FormDivider()
        FormRow(title: L("Движок распознавания", "Recognition engine"), hint: nil) {
            HStack(spacing: 6) {
                StatusDot(color: engine.color, size: 7)
                Text(engine.text).font(TType.body).foregroundStyle(Palette.inkSecondary).lineLimit(1)
            }
        }
        // П10 С3: свой Python — только в debug-сборке; в выпуске движок берёт встроенный.
        if EnginePaths.honorsExplicitPython() {
            FormDivider()
            FormRow(title: L("Python движка", "Engine Python"),
                    hint: model.settings.enginePython.isEmpty ? L("Встроенный. Свой нужен только разработчику.", "Built-in. A custom one is for developers only.")
                                                             : NSString(string: model.settings.enginePython).abbreviatingWithTildeInPath) {
                Button(L("Изменить…", "Change…")) { model.onChooseEnginePython() }
                    .buttonStyle(.mostik(.secondary, compact: true))
            }
        }
    }

    /// Проект для терминов из кода: автопоиск и запасная папка. Видны, только когда термины из кода включены.
    @ViewBuilder private var projectRows: some View {
        FormToggle(title: L("Определять проект сам", "Detect the project"),
                   hint: L("Берёт термины из проекта, открытого в редакторе или терминале.", "Takes terms from the project open in your editor or terminal."),
                   isOn: bind(\.autoProject))
        FormDivider()
        FormRow(title: model.settings.autoProject ? L("Если проект не нашёлся", "When no project is found") : L("Папка проекта", "Project folder"),
                hint: fallbackWarning ?? (model.settings.autoProject
                                          ? L("Запасная папка, если проект не нашёлся.", "A fallback folder when no project is found.")
                                          : L("Термины берутся из этой папки.", "Terms come from this folder.")),
                warning: fallbackWarning != nil) {
            HStack(spacing: DS.Space.xs) {
                Text(tilde(model.settings.projectPath) ?? L("не выбрана", "none"))
                    .font(TType.callout)
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 160, alignment: .trailing)
                    .help(model.settings.projectPath ?? "")
                Button(model.settings.projectPath == nil ? L("Выбрать…", "Choose…") : L("Сменить…", "Change…")) {
                    model.onChooseProject(nil)
                }
                .buttonStyle(.mostik(.secondary, compact: true))
            }
        }
    }

    /// Запасная папка проекта, которая ничего не даёт словарю.
    private var fallbackWarning: String? {
        guard model.settings.projectPath != nil else { return nil }
        switch model.fallbackProjectStatus {
        case .missing: return L("Папки нет — словарь проекта из неё не берётся.", "Folder not found, so no project terms come from it.")
        case .empty: return L("В папке нет терминов — она не помогает распознаванию.", "No terms in this folder, so it doesn't help recognition.")
        case .unknown, .terms: return nil
        }
    }

    private func permissionRow(_ kind: AppModel.PermissionKind, _ title: String, _ hint: String, _ granted: Bool) -> some View {
        FormRow(title: title, hint: hint) {
            if granted {
                // Статус, а не действие: вторичный текст без рамки и цвета ссылки (слепой раунд 4).
                HStack(spacing: 5) {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                    Text(L("Разрешено", "Allowed")).font(TType.callout).foregroundStyle(Palette.inkSecondary)
                }
                .frame(minHeight: DS.hit)
                .accessibilityElement(children: .combine)
            } else {
                Button(L("Открыть настройки", "Open Settings")) { model.onRequestPermission(kind) }
                    .buttonStyle(.mostikSecondary)
            }
        }
    }

    private var engine: (text: String, color: Color) {
        switch model.engineStatus {
        case .starting: (L("Запускается", "Starting"), Palette.inkTertiary)
        case let .loading(what): (what.isEmpty ? L("Загружает модель", "Loading model") : what, Palette.doubt)
        case .ready: (L("Готов", "Ready"), Palette.accent)
        case let .failed(why): (why, Palette.record)
        }
    }

    /// Привязка к полю настроек: запись идёт через намерение, не напрямую.
    private func bind<T>(_ keyPath: WritableKeyPath<MostikSettings, T>) -> Binding<T> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { value in
                var s = model.settings
                s[keyPath: keyPath] = value
                model.onUpdateSettings(s)
            }
        )
    }
}

// MARK: - Боковая панель

/// Разделы с поиском. Пока в поиске текст — вместо разделов найденные настройки.
struct SettingsSidebar: View {
    @ObservedObject var model: AppModel
    @Binding var query: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            MostikTextField(placeholder: L("Поиск настроек", "Search settings"), text: $query, leadingSymbol: "magnifyingglass")
                .accessibilityLabel(L("Поиск настроек", "Search settings"))
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.visibleSettingsPanes) { pane in paneRow(pane) }
                }
            } else {
                results
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Space.s)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func paneRow(_ pane: SettingsPane) -> some View {
        let on = model.settingsPane == pane
        return Button { withAnimation(Motion.quick) { model.settingsPane = pane } } label: {
            HStack(spacing: DS.Space.s) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(on ? Palette.accent : Palette.inkSecondary)
                    .frame(width: 18)
                Text(pane.title)
                    .font(on ? TType.bodyStrong : TType.body)
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.xs)
            .frame(height: 32)
        }
        .buttonStyle(RowButtonStyle(selected: on))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder private var results: some View {
        let found = SettingsIndex.search(query).filter { model.visibleSettingsPanes.contains($0.pane) }
        if found.isEmpty {
            Text(L("Ничего не нашлось.", "Nothing found."))
                .font(TType.callout).foregroundStyle(Palette.inkSecondary)
                .padding(.horizontal, DS.Space.xs)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(found) { item in
                    Button {
                        withAnimation(Motion.quick) { model.settingsReveal = item.reveal; model.settingsPane = item.pane }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(TType.body).foregroundStyle(Palette.ink).lineLimit(1)
                            Text(item.pane.title).font(TType.caption).foregroundStyle(Palette.inkSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, DS.Space.xs)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(RowButtonStyle(selected: model.settingsPane == item.pane))
                }
            }
        }
    }
}

// MARK: - Что уходит с этого Mac

/// Сводка приватности: каждый путь, по которому что-то может уйти с Mac, и его состояние сейчас.
/// Только читает настройки; менять — в разделе пути, по кнопке.
struct PrivacyLedger: View {
    @ObservedObject var model: AppModel
    /// Строка «Проверка обновлений» — без переключателя: проверка всегда включена.
    var updates: UpdateChecksSection? = nil

    var body: some View {
        let s = model.settings
        let cloud = s.polish.effectiveBackend.isCloud
        FormGroup(title: L("Что уходит с этого Mac", "What leaves this Mac"),
                  footer: L("Звук диктовок и встреч не отправляется никуда. Встречи с пометкой «Только на этом Mac» не уходят никогда.",
                            "Dictation and meeting audio is never sent anywhere. Meetings marked “This Mac only” never leave it.")) {
            line(L("Текст диктовки", "Dictated text"),
                 cloud ? L("Уходит в Anthropic или OpenAI: причёсывает Claude/Codex.", "Goes to Anthropic or OpenAI: Claude/Codex polishes it.")
                       : L("Остаётся на этом Mac.", "Stays on this Mac."),
                 out: cloud, pane: .text)
            FormDivider()
            let context = cloud && s.polish.context.enabled && s.polish.context.toCloud
            line(L("Текст вокруг курсора", "Text around the cursor"),
                 context ? L("Уходит в Anthropic или OpenAI вместе с диктовкой.", "Goes to Anthropic or OpenAI with the dictation.")
                         : L("В облако не уходит.", "Never goes to the cloud."),
                 out: context, pane: .text)
            FormDivider()
            let meetings = MeetingCloudPolicy.cloudAllowed(s)
            line(L("Расшифровки встреч", "Meeting transcripts"),
                 meetings ? L("Уходят в Anthropic или OpenAI для заметок и сводки.", "Go to Anthropic or OpenAI for notes and summary.")
                          : L("Остаются на этом Mac.", "Stay on this Mac."),
                 out: meetings, pane: .meetings)
            FormDivider()
            let hint = s.agentContext.hookEnabled
            line(L("Ближайшая встреча — агенту", "Your next meeting, to agents"),
                 hint ? (s.agentContext.includeAttendees
                         ? L("Название и участники — агенту на старте, он шлёт их в облако.", "Title and attendees go to the agent at start, and on to its cloud.")
                         : L("Название — агенту на старте, он шлёт его в облако.", "The title goes to the agent at start, and on to its cloud."))
                      : L("Выключено: агенты не видят ваш календарь.", "Off: agents don’t see your calendar."),
                 out: hint, pane: .agents)
            // Пока лента обновлений не задана, строки нет.
            if model.updatesConfigurable, let updates {
                FormDivider()
                updates
            }
        }
    }

    private func line(_ title: String, _ state: String, out: Bool, pane: SettingsPane) -> some View {
        FormRow(title: title, hint: state, status: out ? Palette.doubt : Palette.accent) {
            if pane != model.settingsPane, model.visibleSettingsPanes.contains(pane) {
                // Кнопка называет, куда ведёт; текст — по правой колонке контролов.
                Button(L("Открыть «\(pane.title)»", "Open \(pane.title)")) { model.openSettings(.pane(pane.rawValue)) }
                    .buttonStyle(.mostik(.quiet, compact: true))
                    .padding(.trailing, -10)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title + ": " + state)
    }
}

// MARK: - Клавиша записи и микрофон (R3b)

/// Выбор клавиши записи одним контролом: три клавиши, нажатая — выбранная.
/// Плитка-картинка и сегменты рядом говорили одно и то же дважды.
struct KeyPicker: View {
    @Binding var selection: String

    private var keys: [(id: String, symbol: String, caption: String?, spoken: String)] {
        [("rightOption", "⌥", L("правый", "right"), L("правый Option", "right Option")),
         ("rightCommand", "⌘", L("правый", "right"), L("правый Command", "right Command")),
         ("fn", "fn", nil, "fn")]
    }

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            ForEach(keys, id: \.id) { key in
                let on = selection == key.id
                Button { withAnimation(Motion.quick) { selection = key.id } } label: {
                    KeyCap(symbol: key.symbol, caption: key.caption, size: 40, pressed: on)
                        .overlay {
                            // Выбранная клавиша — обводка акцентом по контуру самой клавиши.
                            RoundedRectangle(cornerRadius: 40 * 0.18, style: .continuous)
                                .strokeBorder(Palette.accent, lineWidth: 1.5)
                                .offset(y: on ? 2 : 0)
                                .opacity(on ? 1 : 0)
                        }
                        .padding(.vertical, 3)  // нижняя губа клавиши и зона нажатия 46 pt
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(key.spoken)
                .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Клавиша записи", "Record key"))
    }
}

/// Вход звука в Настройках (R3b).
public struct InputDevice: Identifiable, Hashable, Sendable {
    public let id: UInt32
    /// UID Core Audio: по нему выбор хранится в настройках, числовой `id` меняется при переподключении.
    public let uid: String
    public let name: String
    public init(id: UInt32, uid: String, name: String) { self.id = id; self.uid = uid; self.name = name }
}

/// Первая строка группы «Микрофон»: с какого входа пишет Mostik (R3b, `MicChoice`).
/// Выбор — только для захвата Mostik; вход по умолчанию в macOS не меняется, Zoom и Телемост не задеты.
struct MicrophoneRow: View {
    @ObservedObject var model: AppModel

    private var devices: [MicChoice.Device] { model.inputDevices.map { MicChoice.Device(id: $0.id, uid: $0.uid, name: $0.name) } }

    private var options: [(String, String)] {
        var list: [(String, String)] = [("", L("Как в системе", "System default"))]
        list += model.inputDevices.map { ($0.uid, $0.name) }
        let chosen = model.settings.micDeviceUID
        if !chosen.isEmpty, !model.inputDevices.contains(where: { $0.uid == chosen }) {
            let name = model.settings.micDeviceName.isEmpty ? L("Выбранный микрофон", "Chosen microphone") : model.settings.micDeviceName
            list.append((chosen, name + L(" — не подключён", " — not connected")))
        }
        return list
    }

    var body: some View {
        FormRow(title: L("Вход", "Input"),
                hint: MicChoice.hint(chosenUID: model.settings.micDeviceUID, chosenName: model.settings.micDeviceName,
                                     devices: devices)) {
            FormMenu(options: options,
                     selection: Binding(get: { model.settings.micDeviceUID },
                                        set: { uid in
                                            var s = model.settings
                                            s.micDeviceUID = uid
                                            if let device = model.inputDevices.first(where: { $0.uid == uid }) {
                                                s.micDeviceName = device.name
                                            } else if uid.isEmpty {
                                                s.micDeviceName = ""
                                            }
                                            model.onUpdateSettings(s)
                                        }),
                     label: L("Вход микрофона", "Microphone input"))
        }
    }
}

/// Строка из сводки приватности «Что уходит с этого Mac» — с той же точкой состояния, что в «Приватности и данных».
private struct LedgerLine: View {
    let now: Bool
    let what: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            StatusDot(color: Palette.doubt, size: 7)
            (Text(now ? L("Что уходит с этого Mac: ", "What leaves this Mac: ")
                      : L("В «Что уходит с этого Mac» станет: ", "“What leaves this Mac” will say: "))
                .foregroundStyle(Palette.inkSecondary)
             + Text(what).fontWeight(.semibold).foregroundStyle(Palette.ink))
                .font(FormType.hint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private enum MeetingConsentText {
    static var ledger: String { L("расшифровки встреч уходят в Anthropic или OpenAI", "meeting transcripts go to Anthropic or OpenAI") }
    static var warning: String {
        L("Заметки, сводку и задачи сделает Claude или Codex по вашей подписке. Уйдёт текст расшифровки и пометки, звук — никогда. В расшифровке слова других участников, поэтому согласие отдельное от диктовки. Встречи «Только на этом Mac» не уходят.",
          "Claude or Codex writes the notes, summary and tasks under your subscription. The transcript text and marks are sent, never audio. It holds other people’s words, so this consent is separate from dictation. Meetings marked “This Mac only” are never sent.")
    }

    static func block<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(DS.Space.s)
            .background(Palette.doubtSoft, in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
            .padding(.bottom, DS.Space.s)
            .accessibilityElement(children: .contain)
    }

    static func warningRow() -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
            Image(systemName: "cloud")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.doubt)
                .accessibilityHidden(true)
            Text(warning)
                .font(TType.callout)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// «Текст»: Claude только что включён — тут же спросить, не включить ли его и для встреч.
private struct MeetingCloudOffer: View {
    @ObservedObject var model: AppModel
    @ObservedObject var ai: MeetingAIModel

    init(model: AppModel) {
        self.model = model
        self.ai = model.meetingAI
    }

    var body: some View {
        if ai.offerAfterPolish && !MeetingCloudPolicy.cloudAllowed(model.settings) {
            MeetingConsentText.block {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Text(L("Включить Claude/Codex и для встреч?", "Use Claude/Codex for meetings too?"))
                        .font(TType.bodyStrong).foregroundStyle(Palette.ink)
                    MeetingConsentText.warningRow()
                    LedgerLine(now: false, what: MeetingConsentText.ledger)
                    HStack(spacing: DS.Space.xs) {
                        Spacer(minLength: 0)
                        Button(L("Не сейчас", "Not now")) { ai.offerAfterPolish = false }
                            .buttonStyle(.mostik(.quiet, compact: true))
                        Button(L("Включить и для встреч", "Turn on for meetings")) {
                            var s = model.settings
                            s.grantMeetingAI()
                            ai.offerAfterPolish = false
                            model.onUpdateSettings(s)
                        }
                        .buttonStyle(.mostik(.primary, compact: true))
                    }
                }
            }
        }
    }
}

/// «Встречи»: выбор того же вида, что «Чем причёсывать» в «Тексте». Для Claude — согласие на месте выбора,
/// без окна поверх Настроек; при смене модели оно сбрасывается (`MeetingCloudPolicy.reconcile`).
private struct MeetingNotesChoice: View {
    @ObservedObject var model: AppModel
    @ObservedObject var ai: MeetingAIModel

    init(model: AppModel) {
        self.model = model
        self.ai = model.meetingAI
    }

    private var cloud: Bool { model.settings.polish.effectiveBackend.isCloud }
    private var pending: Bool { ai.consentFor == MeetingAIModel.settingsConsent }

    var body: some View {
        let on = MeetingCloudPolicy.toggleIsOn(model.settings)
        FormRow(title: L("Заметки, сводка и задачи", "Notes, summary and tasks"),
                hint: hint(on: on || pending),
                details: L("После расшифровки пометки становятся заметками, появляются сводка и задачи. Модель та же, что причёсывает текст; ей уходит текст расшифровки, не звук. С Claude нужно отдельное согласие: в расшифровке чужие голоса. При смене модели Mostik спросит снова.",
                           "After transcription, marks become notes, plus a summary and tasks. Same model as polishing; it gets the transcript text, not audio. Claude needs a separate consent, since the transcript holds other people’s voices. Change the model and Mostik asks again.")) {
            Segmented(options: [(false, L("Выкл", "Off")), (true, cloud ? "Claude/Codex" : L("На этом Mac", "On this Mac"))],
                      selection: Binding(get: { on || pending }, set: { choose($0) }))
                .accessibilityLabel(L("Заметки, сводка и задачи", "Notes, summary and tasks"))
        }
        if pending {
            consent
        } else if cloud && on {
            notice
        }
    }

    private func hint(on: Bool) -> String {
        guard on else { return L("Встречи только расшифровываются.", "Meetings are only transcribed.") }
        return cloud ? L("Через Claude/Codex по подписке: расшифровка уходит в Anthropic или OpenAI.", "Via Claude/Codex on your subscription: the transcript goes to Anthropic or OpenAI.")
                     : L("Модель на этом Mac получает текст расшифровки, не звук.", "The on-device model gets the transcript text, never audio.")
    }

    private func choose(_ value: Bool) {
        if !value { ai.consentFor = nil }
        switch MeetingCloudPolicy.toggle(value, settings: model.settings) {
        case .apply(let s): model.onUpdateSettings(s)
        case .askCloudConsent: ai.consentFor = MeetingAIModel.settingsConsent
        }
    }

    private var consent: some View {
        MeetingConsentText.block {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                MeetingConsentText.warningRow()
                LedgerLine(now: false, what: MeetingConsentText.ledger)
                HStack(spacing: DS.Space.xs) {
                    Spacer(minLength: 0)
                    Button(L("Отмена", "Cancel")) { ai.consentFor = nil }
                        .buttonStyle(.mostik(.quiet, compact: true))
                        .keyboardShortcut(.cancelAction)
                    Button(L("Включить для встреч", "Turn on for meetings")) {
                        var s = model.settings
                        s.grantMeetingAI()
                        ai.consentFor = nil
                        model.onUpdateSettings(s)
                    }
                    .buttonStyle(.mostik(.primary, compact: true))
                }
            }
        }
    }

    private var notice: some View {
        HStack(alignment: .center, spacing: DS.Space.xs) {
            LedgerLine(now: true, what: MeetingConsentText.ledger)
            Spacer(minLength: DS.Space.s)
            Button(L("Отозвать согласие", "Revoke consent")) {
                var s = model.settings
                s.revokeMeetingAI()
                model.onUpdateSettings(s)
            }
            .buttonStyle(.mostik(.quiet, compact: true))
        }
        .padding(.leading, DS.Space.s)
        .padding(.vertical, DS.Space.xxs)
        .background(Palette.doubtSoft, in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
        .padding(.bottom, DS.Space.s)
    }
}

/// Выбор модели для встреч: своя или как у диктовки (`MostikSettings.meetingBackend`).
enum MeetingModelChoice: Hashable {
    case same, mlx, claude, off

    init(_ backend: PolishBackend?) {
        switch backend {
        case nil: self = .same
        case .mlx?: self = .mlx
        case .claude?: self = .claude
        case .off?: self = .off
        }
    }

    var backend: PolishBackend? {
        switch self {
        case .same: nil
        case .mlx: .mlx
        case .claude: .claude
        case .off: .off
        }
    }

    /// Подсказка под выбором в одну строку: чего не хватает или куда уходят встречи «Только на этом Mac».
    static func hint(_ settings: MostikSettings, localInstalled: Bool) -> String {
        switch settings.meetingEffectiveBackend {
        case .off:
            return L("Сводок и названий встреч нет.", "No meeting summaries or titles.")
        case .mlx:
            return localInstalled ? L("Расшифровки не уходят с этого Mac.", "Transcripts stay on this Mac.")
                                  : L("Модель на этом Mac не скачана.", "The on-device model isn’t downloaded.")
        case .claude:
            return localInstalled ? L("Встречи «Только на этом Mac» — тут.", "“This Mac only” stay on this Mac.")
                                  : L("Локальным встречам нужна модель.", "“This Mac only” needs the model.")
        }
    }
}
