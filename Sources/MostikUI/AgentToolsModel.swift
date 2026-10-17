import AppKit
import SwiftUI
import MostikCore

/// CLI, MCP, скилл и хук для агентов (G1, G2, G4): состояние для Настроек.
/// Своя модель, чтобы не толкаться в `AppModel` с соседними фичами.
@MainActor
public final class AgentToolsModel: ObservableObject {
    /// План установки в листе подтверждения.
    public struct PendingPlan: Identifiable, Equatable {
        public var id: String { plan.target.rawValue }
        public var plan: AgentInstallPlan
        /// Куда ляжет копия прежнего файла — по пути шага; нет ключа — файла ещё нет.
        public var backups: [String: String]
        public init(plan: AgentInstallPlan, backups: [String: String]) { self.plan = plan; self.backups = backups }
    }

    /// `bin/mostik` внутри приложения (в отладке — в репозитории).
    @Published public var cliPath: String = ""
    /// `~/.local/bin/mostik` уже ведёт на эту обёртку.
    @Published public var cliLinked = false
    /// Скилл и хук установлены (по агентам).
    @Published public var installed: [AgentTarget: Bool] = [:]
    /// На Mac найден агент: папка `~/.claude` или `~/.codex` (раздел «Агенты» в Настройках).
    @Published public var agentFound = false
    @Published public var pending: PendingPlan?
    @Published public var message: String?

    public init() {}

    public var onRefresh: () -> Void = {}
    public var onPrepare: (AgentTarget) -> Void = { _ in }
    public var onInstall: () -> Void = {}
}

/// Группа «Агенты: CLI, MCP, скилл» в Настройках.
struct AgentToolsSection: View {
    /// `.connect` — подключение Claude Code и Codex, на виду в «Агентах»;
    /// `.more` — подсказка на старте сессии (по умолчанию выключена) и команда mostik, в «Ещё».
    enum Part { case connect, more }

    @ObservedObject var model: AppModel
    @ObservedObject var tools: AgentToolsModel
    var part: Part

    init(model: AppModel, part: Part = .connect) {
        self.model = model
        self.tools = model.agentTools
        self.part = part
    }

    private var s: AgentContextSettings { model.settings.agentContext }

    var body: some View {
        switch part {
        case .connect: connect
        case .more: more
        }
    }

    private var connect: some View {
        FormGroup(title: L("Подключение", "Connection")) {
            targetRow(.claudeCode, "Claude Code",
                      L("Агент получит доступ к вашим встречам и словарю и команду /mostik.",
                        "The agent gets access to your meetings and glossary, plus the /mostik command."))
            FormDivider()
            targetRow(.codex, "Codex",
                      L("Агент получит доступ к вашим встречам и словарю и команду mostik.",
                        "The agent gets access to your meetings and glossary, plus the mostik command."))
            if let message = tools.message {
                FormDivider()
                FormNote(text: message)
            }
        }
        .sheet(item: Binding(get: { tools.pending }, set: { tools.pending = $0 })) { pending in
            AgentInstallSheet(pending: pending, includeAttendees: s.includeAttendees, onInstall: tools.onInstall, onCancel: { tools.pending = nil })
        }
    }

    @ViewBuilder private var more: some View {
        // Включение здесь — явный выбор: `hookExplicit` отличает его от старого умолчания «вкл» (решение автора).
        FormToggle(title: L("Ближайшая встреча — агенту на старте", "Your next meeting, to the agent at start"),
                   hint: s.hookEnabled ? L("Агент отправит это в облако своей модели.", "The agent sends this to its model’s cloud.")
                                       : L("Ближайшая встреча и словарь проекта — один раз в начале.", "The next meeting and project glossary, once at start."),
                   details: L("Название встречи в ближайший час и словарь текущего проекта — один раз, в начале сессии, только в рабочие часы. Агент отправит это в облако своей модели. Работает, если агент подключён.",
                              "The title of a meeting within the hour and the current project’s glossary — once, at the start of a session, in working hours only. The agent sends this to its model’s cloud. Needs the agent connected."),
                   warning: s.hookEnabled,
                   isOn: Binding(get: { s.hookEnabled }, set: { on in
                       var settings = model.settings
                       settings.agentContext.hookEnabled = on
                       settings.agentContext.hookExplicit = true
                       model.onUpdateSettings(settings)
                   }))
        if s.hookEnabled {
            FormDivider()
            hoursRow
            FormDivider()
            toggle(L("И по выходным", "Weekends too"),
                   L("Суббота и воскресенье — тоже рабочие дни.", "Saturday and Sunday count as working days."),
                   nil, \.weekends)
            FormDivider()
            toggle(L("Передавать участников встречи", "Include meeting attendees"),
                   s.includeAttendees ? L("Имена участников тоже уйдут в облако агента.", "Attendee names also go to the agent’s cloud.")
                                      : L("Выключено — только название встречи.", "Off: the meeting title only."),
                   L("Кроме названия встречи агент получит имена участников и отправит их в облако своей модели вместе со своим контекстом. Выключено — только название.",
                     "Besides the meeting title, the agent gets the attendees’ names and sends them to its model’s cloud with its own context. Off — the title only."),
                   \.includeAttendees, warning: s.includeAttendees)
        }
        FormDivider()
        cliRow
    }

    private var cliRow: some View {
        let command = AgentIntegration.symlinkCommand(cliPath: tools.cliPath)
        return VStack(alignment: .leading, spacing: 0) {
            FormRow(title: tools.cliLinked ? L("Команда mostik в терминале", "The mostik command in a terminal")
                                           : L("Команда mostik для терминала", "A mostik command for the terminal"),
                    hint: tools.cliLinked ? L("Готово: агенты читают историю и встречи.", "Ready: agents read your history and meetings.")
                                          : L("Выполните строку в терминале — Mostik сам не пишет.", "Run the line in a terminal; Mostik won’t do it itself."),
                    details: L("История, встречи, словарь и поиск в JSON для агентов: mostik spec покажет всё. Чтобы команда была в терминале, выполните в нём строку ниже — Mostik сам в систему не пишет.",
                               "History, meetings, glossary and search as JSON for agents: mostik spec lists everything. To get the command in a terminal, run the line below there — Mostik doesn’t write to the system itself."),
                    status: tools.cliLinked ? Palette.accent : Palette.inkTertiary) {
                Button(L("Скопировать", "Copy")) { copy(command) }
                    .buttonStyle(.mostik(.secondary, compact: true))
            }
            if !tools.cliLinked {
                codeLine(command).padding(.bottom, DS.Space.s)
            }
        }
    }

    private func targetRow(_ target: AgentTarget, _ title: String, _ details: String) -> some View {
        let done = tools.installed[target] ?? false
        return FormRow(title: title,
                       hint: done ? L("Подключено: агент видит историю, встречи и словарь.", "Connected: the agent sees history, meetings and glossary.")
                                  : L("Перед подключением Mostik покажет, какие файлы изменятся.", "Before connecting, Mostik shows which files change."),
                       details: details + " " + L("Технически это скилл, хук на старте сессии и MCP-сервер встреч; ближайшая встреча на старте не передаётся, пока вы это не включите в «Ещё».",
                                                  "Technically: a skill, a session-start hook and the meetings MCP server; your next meeting isn’t shared at start until you turn it on under More."),
                       status: done ? Palette.accent : Palette.inkTertiary) {
            Button(done ? L("Обновить…", "Update…") : L("Подключить…", "Connect…")) { tools.onPrepare(target) }
                .buttonStyle(.mostik(.secondary, compact: true))
        }
    }

    private var hoursRow: some View {
        FormRow(title: L("Рабочие часы", "Working hours"),
                hint: L("Вне них подсказки нет.", "No hint outside them.")) {
            HStack(spacing: DS.Space.xs) {
                StepperField(value: bind(\.workStart), range: 0...23) { L("с \($0):00", "from \($0):00") }
                StepperField(value: bind(\.workEnd), range: 1...24) { L("до \($0):00", "to \($0):00") }
            }
        }
    }

    private func codeLine(_ text: String) -> some View {
        Text(text)
            .font(TType.code)
            .foregroundStyle(Palette.inkSecondary)
            .textSelection(.enabled)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Space.s)
            .background(Palette.canvas, in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
    }

    private func toggle(_ title: String, _ hint: String, _ details: String?, _ keyPath: WritableKeyPath<AgentContextSettings, Bool>,
                        warning: Bool = false) -> some View {
        FormToggle(title: title, hint: hint, details: details, warning: warning, isOn: bind(keyPath))
    }

    private func bind<T>(_ keyPath: WritableKeyPath<AgentContextSettings, T>) -> Binding<T> {
        Binding(get: { s[keyPath: keyPath] }, set: { value in
            var settings = model.settings
            settings.agentContext[keyPath: keyPath] = value
            model.onUpdateSettings(settings)
        })
    }
}

/// Подтверждение установки: каждый файл, что именно в нём появится, куда ляжет копия прежнего.
struct AgentInstallSheet: View {
    let pending: AgentToolsModel.PendingPlan
    /// Хук передаёт участников встречи (`AgentContextSettings.includeAttendees`).
    var includeAttendees = false
    var onInstall: () -> Void
    var onCancel: () -> Void

    private var title: String {
        pending.plan.target == .claudeCode ? L("Mostik для Claude Code", "Mostik for Claude Code")
                                           : L("Mostik для Codex", "Mostik for Codex")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text(title).font(TType.headline).foregroundStyle(Palette.ink)
            // Без ScrollView: три шага с короткими фрагментами помещаются, и лист виден целиком.
            VStack(alignment: .leading, spacing: DS.Space.m) {
                ForEach(Array(pending.plan.steps.enumerated()), id: \.element.id) { index, step in
                    item(index + 1, step)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Приватность (п. 3): прямо — что уходит агенту и что агент отправляет в облако.
            Text(AgentIntegration.privacyNotice(includeAttendees: includeAttendees))
                .font(TType.callout).foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(DS.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.canvas, in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
            Text(L("Другие записи в этих файлах не меняются. Ближайшая встреча на старте сессии не передаётся — это включается в Настройках → Агенты → Ещё.",
                   "Nothing else in these files changes. Your next meeting isn’t shared at session start; turn it on in Settings → Agents → More."))
                .font(TType.callout).foregroundStyle(Palette.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.xs) {
                Spacer()
                Button(L("Отмена", "Cancel"), action: onCancel)
                    .buttonStyle(.mostik(.quiet))
                    .keyboardShortcut(.cancelAction)
                Button(L("Записать", "Write"), action: onInstall)
                    .buttonStyle(.mostikPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Space.l)
        .frame(width: 560)
        .background(Palette.surface)
    }

    private func item(_ number: Int, _ step: AgentInstallStep) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Text("\(number)").font(TType.figure(12, .semibold)).foregroundStyle(Palette.inkTertiary).frame(width: 14)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(step.summary).font(TType.bodyStrong).foregroundStyle(Palette.ink)
                if step.kind == .manual {
                    Text(L("Выполните сами в Терминале — приложение эту команду не запускает:",
                           "Run it yourself in Terminal — the app doesn’t run this command:"))
                        .font(TType.callout).foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(tilde(step.path)).font(TType.code).foregroundStyle(Palette.inkSecondary)
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    Text(note(step)).font(TType.callout).foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top, spacing: DS.Space.xs) {
                    Text(step.preview)
                        .font(TType.code)
                        .foregroundStyle(Palette.inkSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Space.s)
                        .background(Palette.canvas, in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
                    if step.kind == .manual {
                        Button(L("Скопировать", "Copy")) { copy(step.preview) }
                            .buttonStyle(.mostik(.secondary, compact: true))
                    }
                }
            }
        }
    }

    private func note(_ step: AgentInstallStep) -> String {
        let backup = pending.backups[step.path]
        switch step.kind {
        case .writeFile:
            return backup.map { L("Файл заменится, копия прежнего: ", "The file is replaced; old copy: ") + tilde($0) }
                ?? L("Новый файл.", "A new file.")
        case .mergeHook:
            return backup.map { L("Добавится запись ниже, прежняя запись Mostik заменится. Копия файла: ",
                                  "The entry below is added, an older Mostik entry is replaced. Copy of the file: ") + tilde($0) }
                ?? L("Файла нет — он будет создан с записью ниже.", "No file yet — it will be created with the entry below.")
        case .appendToml:
            return backup.map { L("Блок допишется в конец, если раздела mostik ещё нет. Копия файла: ",
                                  "The block is appended unless a mostik section exists. Copy of the file: ") + tilde($0) }
                ?? L("Файла нет — он будет создан с блоком ниже.", "No file yet — it will be created with the block below.")
        case .manual:
            return ""
        }
    }

    private func tilde(_ path: String) -> String { NSString(string: path).abbreviatingWithTildeInPath }
}

@MainActor
private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
