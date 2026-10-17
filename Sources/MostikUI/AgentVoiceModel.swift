import SwiftUI
import MostikCore

/// Голос и агенты (G5, G6, A1, A3, A5): состояние tmux и хуков для Настроек.
/// Своя модель, чтобы не толкаться в `AppModel` с соседними фичами.
@MainActor
public final class AgentVoiceModel: ObservableObject {
    public struct PaneItem: Identifiable, Equatable {
        /// id панели tmux: `%3`.
        public var id: String
        /// «frontend · claude · web-app».
        public var title: String
        /// `frontend:0.1`.
        public var label: String
        public init(id: String, title: String, label: String) { self.id = id; self.title = title; self.label = label }
    }

    /// Что запишет установка хуков — показывается до записи.
    public struct HooksPlan: Identifiable, Equatable {
        public var id: String { settingsPath }
        public var settingsPath: String
        public var scriptPath: String
        /// Фрагмент JSON, который добавится в `hooks`.
        public var preview: String
        /// Куда ляжет копия прежнего файла; nil — файла ещё нет.
        public var backupPath: String?
        public init(settingsPath: String, scriptPath: String, preview: String, backupPath: String?) {
            self.settingsPath = settingsPath; self.scriptPath = scriptPath; self.preview = preview; self.backupPath = backupPath
        }
    }

    /// Путь к tmux; nil — не установлен, адресная вставка недоступна.
    @Published public var tmuxPath: String?
    @Published public var panes: [PaneItem] = []
    @Published public var hooksInstalled = false
    @Published public var hooksPlan: HooksPlan?
    @Published public var hooksMessage: String?

    public init() {}

    public var tmuxAvailable: Bool { tmuxPath != nil }

    public var onRefresh: () -> Void = {}
    public var onPrepareHooks: () -> Void = {}
    public var onInstallHooks: () -> Void = {}
    public var onUninstallHooks: () -> Void = {}
    public var onTestAnnouncement: () -> Void = {}
}

/// Группа «Голос и агенты» в Настройках.
struct AgentVoiceSection: View {
    /// `.main` — отправка, ссылки на файлы и озвучка, на виду в «Агентах»; `.tmux` — вставка в tmux для «Ещё».
    /// Выбор панели tmux и обращение к сессии по имени — умолчания без контрола (решение автора):
    /// текст уходит в активную панель терминала впереди.
    enum Part { case main, tmux }

    @ObservedObject var model: AppModel
    @ObservedObject var voice: AgentVoiceModel
    var part: Part

    init(model: AppModel, part: Part = .main) {
        self.model = model
        self.voice = model.agentVoice
        self.part = part
    }

    private var s: AgentVoiceSettings { model.settings.agentVoice }

    var body: some View {
        Group {
            switch part {
            case .main: main
            case .tmux: tmux
            }
        }
        .sheet(item: Binding(get: { voice.hooksPlan }, set: { voice.hooksPlan = $0 })) { plan in
            ClaudeHooksSheet(plan: plan, onInstall: voice.onInstallHooks, onCancel: { voice.hooksPlan = nil })
        }
    }

    @ViewBuilder private var tmux: some View {
        if voice.tmuxAvailable {
            toggle(L("Вставлять в панель tmux", "Paste into a tmux pane"),
                   L("Текст попадёт прямо в окно агента, буфер обмена не трогается.", "Text goes straight into the agent’s pane; the clipboard is untouched."),
                   tmuxDetails, \.tmuxPaste)
        } else {
            FormCollapsed(title: L("Вставлять в панель tmux", "Paste into a tmux pane"),
                          reason: L("tmux не найден: установите его и перезапустите Mostik.", "tmux not found: install it and restart Mostik."))
        }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            FormGroup(title: L("Отправка", "Sending")) {
                toggle(L("Отправлять голосом", "Send by voice"),
                       L("Скажите в конце «отправь» — Mostik нажмёт Enter.", "End with “send” and Mostik presses Enter."),
                       L("Скажите в конце «отправь» или «send»: слово уберётся, а после вставки Mostik нажмёт Enter. «Отправь письмо Маше» не сработает: слово должно быть последним.",
                         "End with “send”: the word is dropped and Mostik presses Enter after pasting. “Send the email to Masha” won’t trigger: the word has to come last."),
                       \.voiceSend)
                FormDivider()
                toggle(L("Ссылки на файлы проекта", "Project file mentions"),
                       L("«В auth check» станет @src/authCheck.ts.", "“In auth check” becomes @src/authCheck.ts."),
                       L("«В auth check» станет @src/authCheck.ts в Claude Code, Codex и Cursor, если в проекте ровно один такой файл. В остальных приложениях текст не меняется.",
                         "“In auth check” becomes @src/authCheck.ts in Claude Code, Codex and Cursor when the project has exactly one such file. Other apps get the text as is."),
                       \.fileMentions)
            }

            FormGroup(title: L("Озвучка агента", "Agent announcements")) {
                toggle(L("Озвучивать агента", "Speak agent updates"),
                       L("Claude Code закончил или ждёт разрешения — звук и голос.", "Claude Code is done or needs permission: a sound and a voice."),
                       L("Claude Code закончил ход или ждёт разрешения — звук и голос: «Проекту Mostik нужно разрешение». Звуки разные. Пока вы диктуете, голос ждёт.",
                         "When Claude Code finishes a turn or needs permission — a sound and a voice: “Mostik needs your permission.” Different sounds. Waits while you dictate."),
                       \.announce)
                if s.announce {
                    FormDivider()
                    hooksRow
                    AgentVoicePickerRows(model: model)  // A1: выбор установленного голоса
                    FormDivider()
                    toggle(L("Читать первую фразу ответа", "Read the first sentence of the reply"),
                           L("После «готово» — начало ответа, без кода и ссылок.", "After “done”, the start of the reply, no code or links."),
                           nil, \.announceSummary)
                }
            }
        }
    }

    private var tmuxDetails: String {
        let path = voice.tmuxPath.map { tilde($0) } ?? "tmux"
        return L("В терминале с tmux текст уходит в активную панель целиком, как вставка: буфер обмена не трогается, переносы строк не отправят сообщение раньше времени. tmux: \(path).",
                 "In a terminal running tmux, text goes to the agent pane as one paste: the clipboard is untouched and line breaks won’t send early. tmux: \(path).")
    }

    private var hooksRow: some View {
        FormRow(title: voice.hooksInstalled ? L("Подключено к Claude Code", "Connected to Claude Code")
                                            : L("Не подключено к Claude Code", "Not connected to Claude Code"),
                hint: voice.hooksMessage ?? L("Без подключения Mostik не узнает, что агент закончил.", "Without it, Mostik can’t tell the agent is done."),
                details: L("Mostik допишет пару строк в настройки Claude Code и покажет их заранее. Отключить можно здесь же.",
                           "Mostik adds a few lines to Claude Code’s settings and shows them first. Disconnect here any time."),
                status: voice.hooksInstalled ? Palette.accent : Palette.doubt) {
            HStack(spacing: DS.Space.xs) {
                Button(L("Проверить голос", "Test voice")) { voice.onTestAnnouncement() }
                    .buttonStyle(.mostik(.quiet, compact: true))
                if voice.hooksInstalled {
                    Button(L("Отключить", "Disconnect")) { voice.onUninstallHooks() }
                        .buttonStyle(.mostik(.secondary, compact: true))
                } else {
                    Button(L("Подключить…", "Connect…")) { voice.onPrepareHooks() }
                        .buttonStyle(.mostik(.secondary, compact: true))
                }
            }
        }
    }

    /// Выключенная зависимость показывается выключенным переключателем, а не сохранённым «вкл».
    private func toggle(_ title: String, _ hint: String, _ details: String?, _ keyPath: WritableKeyPath<AgentVoiceSettings, Bool>,
                        enabled: Bool = true) -> some View {
        FormToggle(title: title, hint: hint, details: details,
                   isOn: Binding(get: { enabled && s[keyPath: keyPath] }, set: { value in update { $0[keyPath: keyPath] = value } }),
                   enabled: enabled)
    }

    private func update(_ change: (inout AgentVoiceSettings) -> Void) {
        var settings = model.settings
        change(&settings.agentVoice)
        model.onUpdateSettings(settings)
    }

    private func tilde(_ path: String) -> String { NSString(string: path).abbreviatingWithTildeInPath }
}

/// Подтверждение установки хуков: какие файлы и что именно в них появится.
struct ClaudeHooksSheet: View {
    let plan: AgentVoiceModel.HooksPlan
    var onInstall: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text(L("Подключить озвучку к Claude Code", "Connect announcements to Claude Code"))
                .font(TType.headline).foregroundStyle(Palette.ink)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                item("1", L("Скрипт-приёмник", "Receiver script"), plan.scriptPath,
                     L("Кладёт событие в папку Mostik и сразу выходит. В сеть не ходит.",
                       "Drops the event into Mostik’s folder and exits. No network."))
                item("2", L("Настройки Claude Code", "Claude Code settings"), plan.settingsPath,
                     plan.backupPath == nil
                        ? L("Файла нет — он будет создан с записями ниже.", "No file yet — it will be created with the entries below.")
                        : L("Добавятся записи ниже, остальное не меняется.", "The entries below are added, nothing else changes."))
                if let backup = plan.backupPath {
                    item("3", L("Копия прежнего файла", "Copy of the old file"), backup,
                         L("На случай, если захотите вернуть всё как было.", "In case you want everything back as it was."))
                }
            }
            Text(plan.preview)
                .font(TType.code)
                .foregroundStyle(Palette.inkSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Space.s)
                .background(Palette.canvas, in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
            Text(L("Удалить можно кнопкой в Настройках: уберутся только эти записи.",
                   "Remove them with the button in Settings: only these entries go away."))
                .font(TType.callout).foregroundStyle(Palette.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.xs) {
                Spacer()
                Button(L("Отмена", "Cancel"), action: onCancel)
                    .buttonStyle(.mostik(.quiet))
                    .keyboardShortcut(.cancelAction)
                Button(L("Установить", "Install"), action: onInstall)
                    .buttonStyle(.mostikPrimary)
                    .keyboardShortcut(.defaultAction)
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
                Text(tilde(path)).font(TType.code).foregroundStyle(Palette.inkSecondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                Text(note).font(TType.callout).foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func tilde(_ path: String) -> String { NSString(string: path).abbreviatingWithTildeInPath }
}
