import SwiftUI
import MostikCore

// ИИ встреч (M5–M7) в карточке встречи: сводка, заметки по пометкам со ссылками на реплики,
// задачи с исполнителями. Переключатель «Подробно/Кратко», «Пересобрать», лист согласия.

// MARK: - Секция в карточке встречи

struct MeetingAISection: View {
    /// Что рисовать (П9-B): сводку с заметками, задачи (свой раздел окна) или органы управления
    /// для строки разделов (R3a): у сводки — меню «Вид сводки ▾» и «Пересобрать», у задач — только «Пересобрать».
    enum Part { case summary, tasks, controls, taskControls }

    @ObservedObject var model: AppModel
    @ObservedObject var ai: MeetingAIModel
    let meeting: AppModel.MeetingItem
    var part: Part = .summary
    @State private var editing: Int? = nil
    @State private var draft = ""
    @State private var editingTask: Int? = nil
    @State private var taskDraft = ""

    init(model: AppModel, meeting: AppModel.MeetingItem, part: Part = .summary) {
        self.model = model
        self.ai = model.meetingAI
        self.meeting = meeting
        self.part = part
    }

    private var id: String { meeting.id }
    private var mode: MeetingAIMode { ai.mode(for: id) }
    private var result: MeetingAIResult? { ai.result(for: id) }
    private var phase: MeetingAIModel.Phase { ai.phase(for: id) }
    /// Показанный вид сводки (W22): основная или дополнительная.
    private var shown: String { ai.shownView(for: id) }
    private var sensitive: Bool { model.meetingExtras.sensitive.contains(id) }
    private var gate: MeetingAIPolicy.Gate { MeetingAIPolicy.gate(model.settings, sensitive: sensitive, localModel: model.localLLMInstalled) }

    /// Порядок говорящих — как в расшифровке, чтобы цвета точек совпадали.
    private var speakers: [String] {
        var seen: [String] = []
        for line in model.meetingTranscripts[id] ?? [] where !line.isMark && !seen.contains(line.speaker) {
            seen.append(line.speaker)
        }
        return seen
    }

    /// Время начала реплики по её номеру в `transcript.json`.
    private var turnStarts: [TimeInterval] {
        (model.meetingTranscripts[id] ?? []).filter { !$0.isMark }.map(\.start)
    }

    // Без внешней рамки (П9-B): раздел окна — сам по себе поверхность, карточка в карточке не нужна.
    @ViewBuilder var body: some View {
        switch part {
        case .controls:
            controls
        case .taskControls:
            HStack(spacing: DS.Space.xs) {
                if let result, !result.tasks.isEmpty {
                    if model.meetingExtras.sensitive.contains(id) {
                        MeetingUnlockButton(extras: model.meetingExtras, meeting: id)
                    } else {
                        sendTasksButton
                    }
                }
                rebuildButton
            }
        case .tasks:
            tasksContent
        case .summary:
            VStack(alignment: .leading, spacing: DS.Space.m) {
                // «Своя…» из меню «Вид сводки»: поле описания над сводкой.
                if ai.customFor == id { MeetingSummaryCustomField(ai: ai, meeting: id, start: guarded) }
                if shown == MeetingAIVariant.main { content } else { variantContent }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: переключатель режима

    /// R3a: «Подробно/Кратко», другие виды, «Своя…» и шаблон — одно меню; рядом «Пересобрать».
    private var controls: some View {
        HStack(alignment: .center, spacing: DS.Space.xs) {
            if hasAnyResult || !(ai.files[id]?.variants.isEmpty ?? true) {
                MeetingSummaryViewMenu(ai: ai, meeting: id, mode: mode, switchMode: switchMode, start: guarded)
            }
            rebuildButton
        }
    }

    /// «Пересобрать» основную сводку; у дополнительного вида своя кнопка — под ним.
    @ViewBuilder private var rebuildButton: some View {
        if hasAnyResult && shown == MeetingAIVariant.main {
            Button { run(mode) } label: {
                Label(L("Пересобрать", "Rebuild"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.mostik(.quiet, compact: true))
            .disabled(isWorking)
            .help(L("Заново сделать сводку, заметки и задачи в этом режиме",
                    "Redo the summary, notes and tasks in this mode"))
        }
    }

    /// Раздел «Задачи»: из основной сводки; пока её нет — то же состояние, что в «Сводке».
    @ViewBuilder private var tasksContent: some View {
        if case .idle = phase, let result, result.status != .failed {
            tasks(result, place: .mode(mode), label: false)
        } else {
            content
        }
    }

    private var hasAnyResult: Bool { !(ai.files[id]?.results.isEmpty ?? true) }

    private var isWorking: Bool {
        switch phase {
        case .queued, .running: return true
        default: return false
        }
    }

    // MARK: состояния

    @ViewBuilder private var content: some View {
        switch phase {
        case .queued:
            working(L("В очереди: ждёт конца диктовки или расшифровки встречи", "Queued: waiting for a dictation or transcription to finish"))
        case let .running(stage):
            working(stage.isEmpty ? L("Делаем заметки и сводку", "Writing notes and summary") : stage)
        case let .failed(why):
            failed(why)
        case .idle:
            if let result, result.status == .failed {
                failed(result.error ?? "")
            } else if let result {
                resultView(result)
            } else {
                empty
            }
        }
    }

    private func working(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(text).font(TType.bodyStrong).foregroundStyle(Palette.ink)
            IndeterminateBar()
            Text(L("Расшифровка уже готова и не меняется. Диктовка в это время работает как обычно.",
                   "The transcript is ready and stays as is. Dictation keeps working meanwhile."))
                .font(TType.callout)
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func failed(_ why: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.circle").font(.system(size: 12, weight: .medium))
                Text(L("Не удалось сделать заметки и сводку", "Couldn’t write the notes and summary"))
                    .font(TType.bodyStrong)
            }
            .foregroundStyle(Palette.record)
            Text(L("Расшифровка на месте, её это не задело.", "The transcript is intact.")
                 + (why.isEmpty ? "" : " " + why))
                .font(TType.callout)
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(4)
            Button { run(mode) } label: { Label(L("Повторить", "Try again"), systemImage: "arrow.clockwise") }
                .buttonStyle(.mostikSecondary)
                .padding(.top, DS.Space.xxs)
        }
    }

    @ViewBuilder private var empty: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(L("Пометки станут полными заметками со ссылками на реплики, а ещё будут сводка и задачи с исполнителями. Всё — по расшифровке.",
                   "Your marks become full notes linked to the transcript, plus a summary and tasks with owners. All from the transcript."))
                .font(TType.body)
                .foregroundStyle(Palette.inkSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if case .noBackend = gate {
                Text(L("Нужна модель: выберите Claude или модель на этом Mac в Настройках → Текст.",
                       "A model is needed: choose Claude or an on-device model in Settings → Text."))
                    .font(TType.callout)
                    .foregroundStyle(Palette.doubt)
                    .fixedSize(horizontal: false, vertical: true)
                Button { model.openSettings(.chooseModel) } label: {
                    Label(L("Открыть настройки", "Open Settings"), systemImage: "gearshape")
                }
                .buttonStyle(.mostikSecondary)
            } else if case .sensitiveCloud = gate {
                Text(MeetingAICopy.sensitiveCloud)
                    .font(TType.callout)
                    .foregroundStyle(Palette.doubt)
                    .fixedSize(horizontal: false, vertical: true)
                // Скачанная модель снимает этот случай: gate станет `.ready(.mlx)`.
                if let llm = model.models.rows.first(where: { $0.purpose == "llm" && !$0.installed }) {
                    Button { model.models.start([llm.key]) } label: {
                        Label(model.models.downloading
                              ? L("Модель скачивается…", "Downloading the model…")
                              : L("Скачать модель на этот Mac · \(ModelCatalog.size(llm.size, russian: L10n.isRussian))",
                                  "Download the on-device model · \(ModelCatalog.size(llm.size, russian: L10n.isRussian))"),
                              systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.mostikSecondary)
                    .disabled(model.models.downloading)
                }
            } else {
                HStack(spacing: DS.Space.s) {
                    Button { run(mode) } label: {
                        Label(L("Сделать заметки и сводку", "Write notes and summary"), systemImage: "sparkles")
                    }
                    .buttonStyle(.mostikPrimary)
                    Text(MeetingAICopy.destination(gate))
                        .font(TType.callout)
                        .foregroundStyle(Palette.inkTertiary)
                }
            }
        }
    }

    // MARK: итог

    private func resultView(_ result: MeetingAIResult) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            if result.status == .partial {
                Text(L("Часть обработки не удалась; ниже то, что получилось.", "Part of the processing failed; here is what worked."))
                    .font(TType.callout)
                    .foregroundStyle(Palette.doubt)
            }
            if !result.overview.isEmpty || !result.points.isEmpty || !result.agenda.isEmpty { summary(result) }
            if !result.notes.isEmpty { notes(result) }
            MeetingInputsStrip(model: model, ai: ai, meeting: id, used: result.inputs)
            MeetingAfterActions(ai: ai, extras: model.meetingExtras, meeting: id, sensitive: sensitive, start: guarded)
            footer(result)
        }
    }

    /// Разделы по темам или людям (M17), решения, протокол (W8).
    private func summary(_ result: MeetingAIResult) -> some View {
        MeetingSummaryBody(result: result, refChips: { AnyView(refChips($0)) })
    }

    /// Дополнительный вид сводки (W22): ход, ошибка или сам вид — основная не меняется.
    @ViewBuilder private var variantContent: some View {
        let key = shown
        switch ai.variantPhase(id, key) {
        case .queued:
            working(L("В очереди: ждёт конца диктовки или расшифровки встречи", "Queued: waiting for a dictation or transcription to finish"))
        case let .running(stage):
            working(stage.isEmpty ? L("Делаем ещё одну сводку", "Writing another summary") : stage)
        case let .failed(why):
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(L("Эта сводка не получилась. Основная на месте.", "This summary failed. The main one is intact.")
                     + (why.isEmpty ? "" : " " + why))
                    .font(TType.callout).foregroundStyle(Palette.record)
                    .fixedSize(horizontal: false, vertical: true)
                Button { guarded { ai.onRunVariant(id, key, ai.files[id]?.variants[key]?.instruction) } } label: {
                    Label(L("Повторить", "Try again"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.mostikSecondary)
            }
        case .idle:
            if let result = ai.files[id]?.variants[key] {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    if let instruction = result.instruction {
                        MeetingSummaryTag(text: "«" + instruction + "»", symbol: "text.cursor")
                    }
                    summary(result)
                    if !result.tasks.isEmpty { tasks(result, place: .variant(key)) }
                    HStack {
                        footer(result)
                        Spacer()
                        Button { guarded { ai.onRunVariant(id, MeetingAIVariant.isCustom(key) ? "custom" : key, result.instruction) } } label: {
                            Label(L("Пересобрать", "Rebuild"), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.mostik(.quiet, compact: true))
                        .help(L("Прежний вариант сохранится в history/", "The previous one is kept in history/"))
                    }
                }
            } else {
                Text(L("Этой сводки ещё нет.", "This summary doesn’t exist yet."))
                    .font(TType.callout).foregroundStyle(Palette.inkSecondary)
            }
        }
    }

    private func notes(_ result: MeetingAIResult) -> some View {
        let marks = ai.marks[id] ?? []
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            GroupLabel(text: L("Заметки по пометкам", "Notes from your marks"), trailing: Fmt.marks(result.notes.count))
            ForEach(Array(result.notes.enumerated()), id: \.offset) { _, note in
                noteRow(note, stale: !marks.isEmpty && MeetingAILink.isStale(note, marks: marks),
                        current: marks.indices.contains(note.markIndex) ? marks[note.markIndex].text : nil)
            }
        }
    }

    private func noteRow(_ note: MeetingAINote, stale: Bool, current: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            // Один акцент на строку (R3a): булавка акцентом, таймкод — вторичным, как во всей вкладке.
            Text(Fmt.clock(note.at))
                .font(TType.figure(12, .regular))
                .foregroundStyle(Palette.inkSecondary)
                .frame(width: 40, alignment: .trailing)
            VStack(alignment: .leading, spacing: 6) {
                if editing == note.markIndex {
                    markEditor(note)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.accent)
                        Text(current ?? note.mark)
                            .font(TType.calloutStrong)
                            .foregroundStyle(Palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            draft = current ?? note.mark
                            editing = note.markIndex
                        } label: {
                            Image(systemName: "pencil").font(.system(size: 11, weight: .medium))
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.inkTertiary)
                        .iconHelp(L("Поправить пометку", "Edit mark"))
                        // Заметка не дополнена — ссылки в той же колонке справа, что у остальных строк.
                        if !stale && note.text == note.mark {
                            Spacer(minLength: 0)
                            refChips(note.refs)
                        }
                    }
                }
                if note.text != note.mark && !stale {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                        Text(note.text)
                            .font(TType.body)
                            .lineSpacing(2)
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        refChips(note.refs)
                    }
                }
                if stale {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "link.badge.plus").font(.system(size: 11, weight: .medium))
                        Text(L("Пометку поправили после обработки: связь с расшифровкой разорвана. «Пересобрать» свяжет заново.",
                               "The mark was edited after processing, so its link to the transcript is broken. Rebuild to relink."))
                            .font(TType.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(Palette.doubt)
                    .padding(.horizontal, DS.Space.xs)
                    .padding(.vertical, 6)
                    .background(Palette.doubtSoft, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                }
                HStack(spacing: DS.Space.xs) {
                    if note.kept {
                        tag(L("полная — без правок", "already full — kept"))
                    } else if note.fallback {
                        tag(L("не дополнена", "not expanded"))
                    }
                }
            }
        }
    }

    private func taskMenu(_ task: MeetingAITask, place: MeetingAITaskPlace, index: Int) -> some View {
        MoreMenu(help: L("Действия с задачей", "Task actions")) {
            Button(L("Изменить", "Edit")) {
                taskDraft = task.text
                editingTask = index
            }
            Button(L("Копировать", "Copy")) { ai.onCopy(task.text) }
            if !model.meetingExtras.sensitive.contains(id) {
                Button(L("Письмом…", "By email…")) {
                    var lines = [task.text]
                    if case let .speaker(name) = task.assignee { lines.append(L("Исполнитель: ", "Owner: ") + Fmt.speakerName(name)) }
                    if let due = task.due { lines.append(L("Срок: ", "Due: ") + due) }
                    lines.append(L("Со встречи «\(meeting.title)».", "From the meeting “\(meeting.title)”."))
                    ai.onOpenMailDraft(MeetingEmailDraft(subject: task.text, body: lines.joined(separator: "\n")))
                }
            }
            Divider()
            Button(L("Удалить", "Delete"), role: .destructive) {
                if editingTask == index { editingTask = nil }
                ai.onEditTask(id, place, index, .delete)
            }
        }
    }

    private func taskEditor(place: MeetingAITaskPlace, index: Int) -> some View {
        let save = {
            let text = taskDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            editingTask = nil
            ai.onEditTask(id, place, index, .text(text))
        }
        return HStack(spacing: DS.Space.xs) {
            MostikTextField(placeholder: L("Задача", "Task"), text: $taskDraft, leadingSymbol: "checklist")
                .onSubmit(save)
            Button(L("Сохранить", "Save"), action: save)
                .buttonStyle(.mostik(.primary, compact: true))
                .disabled(taskDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(L("Отмена", "Cancel")) { editingTask = nil }
                .buttonStyle(.mostik(.quiet, compact: true))
        }
    }

    private func markEditor(_ note: MeetingAINote) -> some View {
        HStack(spacing: DS.Space.xs) {
            MostikTextField(placeholder: L("Пометка", "Mark"), text: $draft, leadingSymbol: "pin")
                .onSubmit { saveMark(note) }
            Button(L("Сохранить", "Save")) { saveMark(note) }
                .buttonStyle(.mostik(.primary, compact: true))
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(L("Отмена", "Cancel")) { editing = nil }
                .buttonStyle(.mostik(.quiet, compact: true))
        }
    }

    private func saveMark(_ note: MeetingAINote) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        editing = nil
        ai.onEditMark(id, note.markIndex, text)
    }

    @ViewBuilder private func tasks(_ result: MeetingAIResult, place: MeetingAITaskPlace, label: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            if label {
                GroupLabel(text: L("Задачи", "Tasks"), trailing: result.tasks.isEmpty ? nil : MeetingAICopy.tasks(result.tasks.count))
            }
            if result.tasks.isEmpty {
                Text(L("Поручений и обещаний во встрече не нашлось.", "No assignments or promises found."))
                    .font(TType.callout)
                    .foregroundStyle(Palette.inkSecondary)
            }
            ForEach(Array(result.tasks.enumerated()), id: \.offset) { index, task in
                taskRow(task, place: place, index: index)
            }
        }
    }

    /// «Отправить…» у раздела задач: вкладка «Задачи» в «Следующих шагах» — копия для трекера, `.md`, письмо.
    private var sendTasksButton: some View {
        Button {
            ai.onOpenNextSteps(id)
            ai.nextSteps?.tab = .tasks
        } label: {
            Label(L("Отправить…", "Send…"), systemImage: "paperplane")
        }
        .buttonStyle(.mostik(.quiet, compact: true))
        .help(L("Задачи для трекера, файлом или письмом — черновиком, ничего не уходит само",
                "Tasks for a tracker, as a file or by email — as a draft, nothing is sent on its own"))
    }

    private func taskRow(_ task: MeetingAITask, place: MeetingAITaskPlace, index: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Button { ai.onEditTask(id, place, index, .done(!task.done)) } label: {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(task.done ? Palette.accent : Palette.inkTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: 16)
            .iconHelp(task.done ? L("Вернуть в открытые", "Mark as open") : L("Отметить сделанной", "Mark as done"))
            .accessibilityLabel(task.done ? L("Сделано", "Done") : L("Не сделано", "Not done"))
            VStack(alignment: .leading, spacing: 5) {
                // Таймкоды — ссылкой в конце строки, без плашек (П9-B).
                if editingTask == index {
                    taskEditor(place: place, index: index)
                } else {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                    Text(task.text)
                        .font(TType.body)
                        .strikethrough(task.done, color: Palette.inkTertiary)
                        .foregroundStyle(task.done ? Palette.inkSecondary : Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    refChips(task.refs)
                    taskMenu(task, place: place, index: index)
                }
                }
                FlowLayout(spacing: DS.Space.s) {
                    assignee(task.assignee)
                    if let owner = task.owner {
                        meta(L("поставил: ", "set by: ") + owner)
                    }
                    if let due = task.due {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar").font(.system(size: 10, weight: .medium))
                            Text(due).font(TType.callout)
                        }
                        .foregroundStyle(Palette.inkSecondary)
                    }
                }
                // W8: в протоколе у поручения один исполнитель и один срок.
                if task.needsOwner || task.needsDue {
                    MeetingSummaryWarning(text: [task.needsOwner ? L("нужен один исполнитель", "needs one owner") : nil,
                                                 task.needsDue ? L("срок не назван", "no due date") : nil]
                        .compactMap { $0 }.joined(separator: ", "))
                }
            }
        }
    }

    @ViewBuilder private func assignee(_ value: MeetingAITask.Assignee) -> some View {
        switch value {
        case let .speaker(name):
            HStack(spacing: 5) {
                StatusDot(color: color(for: name), size: 7)
                // Щелчок по «Собеседнику N» — поле имени, как в расшифровке.
                SpeakerNameButton(speakers: model.meetingSpeakers, meeting: id, name: name)
            }
        case .group:
            HStack(spacing: 5) {
                Image(systemName: "person.2").font(.system(size: 10, weight: .medium))
                Text(L("Группа", "Group")).font(TType.calloutStrong)
            }
            .foregroundStyle(Palette.ink)
        case .none:
            Text(L("Исполнитель не указан", "No owner named"))
                .font(TType.callout)
                .foregroundStyle(Palette.inkTertiary)
        }
    }

    private func meta(_ text: String) -> some View {
        Text(text).font(TType.callout).foregroundStyle(Palette.inkSecondary)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(TType.caption)
            .foregroundStyle(Palette.inkSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Palette.sunken, in: Capsule())
    }

    private func color(for speaker: String) -> Color {
        let index = speakers.firstIndex(of: speaker) ?? 0
        return Palette.speakers[index % Palette.speakers.count]
    }

    /// Ссылки на реплики (R3a): колонка постоянной ширины у правого края — первый таймкод,
    /// остальные за «+N» в поповере. Пустая колонка держит место, чтобы строки не прыгали.
    private func refChips(_ refs: [Int]) -> some View {
        RefColumn(model: model, ai: ai, meeting: id, refs: refs, starts: turnStarts)
    }

    private func footer(_ result: MeetingAIResult) -> some View {
        var parts = [result.backend == "mlx" ? L("Локальная модель", "Local model") : "Claude"]
        if let model = result.model { parts[0] += " " + model }
        if result.seconds > 0 { parts.append(String(format: L("%.0f с", "%.0f s"), result.seconds)) }
        if result.chunks > 1 { parts.append(MeetingAICopy.parts(result.chunks)) }
        return Text(parts.joined(separator: "  ·  "))
            .font(TType.figure(11, .regular))
            .foregroundStyle(Palette.inkTertiary)
    }

    // MARK: действия

    private func switchMode(_ new: MeetingAIMode) {
        ai.modes[id] = new
        // Режима ещё нет — делаем сразу, как будто нажали «Пересобрать».
        if ai.files[id]?.results[new] == nil, !isWorking { run(new) }
    }

    /// Действие с моделью — через то же согласие, что и сводка.
    private func guarded(_ action: @escaping () -> Void) {
        switch gate {
        case .ready: action()
        case .needsConsent: ai.consentFor = id
        case .noBackend: model.openSettings(.chooseModel)
        case .sensitiveCloud: ai.toast = MeetingAICopy.sensitiveCloud
        }
    }

    private func run(_ mode: MeetingAIMode) {
        switch gate {
        case .ready: ai.onRun(id, mode)
        case .needsConsent:
            ai.modes[id] = mode
            ai.consentFor = id
        case .noBackend: model.openSettings(.chooseModel)
        case .sensitiveCloud: ai.toast = MeetingAICopy.sensitiveCloud
        }
    }
}

/// Колонка ссылок на реплики (R3a): ширина постоянная, цифры моноширинные, цвет вторичный.
/// Первый таймкод — справа в своей ячейке; второй и дальше — «+N», нажатие открывает поповер со списком.
struct RefColumn: View {
    @ObservedObject var model: AppModel
    @ObservedObject var ai: MeetingAIModel
    let meeting: String
    let refs: [Int]
    let starts: [TimeInterval]
    @State private var showMore = false

    /// «12:34» — 5 знаков по ~7 pt моноширинных цифр 12 pt, плюс отступы ссылки.
    static let timeWidth: CGFloat = 46
    static let moreWidth: CGFloat = 26
    static let width: CGFloat = timeWidth + moreWidth

    private func label(_ ref: Int) -> String {
        starts.indices.contains(ref) ? Fmt.clock(starts[ref]) : "#\(ref)"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Group {
                if let first = refs.first {
                    RefChip(label: label(first)) { ai.scroll(to: first, in: meeting) }
                        .quotePreview(model, meeting: meeting, ref: first)  // W18: реплика при наведении
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .frame(width: Self.timeWidth, alignment: .trailing)
            Group {
                if refs.count > 1 {
                    Button { showMore.toggle() } label: {
                        Text("+\(refs.count - 1)")
                            .font(TType.figure(11, .medium))
                            .foregroundStyle(Palette.inkSecondary)
                            .frame(minWidth: Self.moreWidth, minHeight: DS.hit)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L("Ещё реплики к этому пункту", "More turns for this point"))
                    .accessibilityLabel(L("Ещё реплики: \(refs.count - 1)", "More turns: \(refs.count - 1)"))
                    .popover(isPresented: $showMore, arrowEdge: .trailing) { morePopover }
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .frame(width: Self.moreWidth, alignment: .leading)
        }
        .frame(width: Self.width, alignment: .trailing)
    }

    /// Все реплики пункта: таймкод колонкой и начало реплики; нажатие — переход в «Расшифровку».
    private var morePopover: some View {
        let lines = (model.meetingTranscripts[meeting] ?? []).filter { !$0.isMark }
        return VStack(alignment: .leading, spacing: DS.Space.xxs) {
            ForEach(refs, id: \.self) { ref in
                Button {
                    showMore = false
                    ai.scroll(to: ref, in: meeting)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                        Text(label(ref))
                            .font(TType.figure(12, .regular))
                            .foregroundStyle(Palette.inkSecondary)
                            .frame(width: 40, alignment: .trailing)
                        Text(lines.indices.contains(ref) ? Fmt.speakerName(lines[ref].speaker) + ": " + lines[ref].text : "")
                            .font(TType.callout)
                            .foregroundStyle(Palette.ink)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, DS.Space.xs)
                    .frame(minHeight: DS.hit)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
            }
        }
        .padding(DS.Space.xs)
        .frame(width: 340)
    }
}

/// Ссылка на реплику (П9-B, R3a): таймкод 12 pt моноширинными цифрами вторичным цветом, без плашки.
/// Наведение — акцентный цвет и цитата реплики (W18), нажатие — переход в «Расшифровку».
struct RefChip: View {
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(TType.figure(12, .regular))
                .foregroundStyle(hovering ? Palette.accent : Palette.inkSecondary)
                .underline(hovering)
                .padding(.horizontal, 3)
                // Зона нажатия 28 pt по высоте при тексте 11 pt.
                .frame(minHeight: DS.hit)
                .contentShape(Rectangle())
                .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L("Перейти к реплике", "Jump to this turn"))
        .accessibilityLabel(L("Реплика на ", "Turn at ") + label)
    }
}

// MARK: - Прокрутка и подсветка реплики

/// Невидимый проводник: ловит запрос прокрутки из модели ИИ и крутит расшифровку.
struct MeetingAIScrollDriver: View {
    @ObservedObject var ai: MeetingAIModel
    let meeting: String
    let lines: [AppModel.TranscriptLine]
    let proxy: ScrollViewProxy

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: ai.scrollRequest) { _, request in
                guard let request, request.meeting == meeting,
                      let index = MeetingAILink.line(forTurn: request.turn, isMark: lines.map(\.isMark)) else { return }
                // Запрос переключил раздел на «Расшифровку»: крутим, когда её строки уже на экране.
                let id = lines[index].id
                DispatchQueue.main.async {
                    withAnimation(Motion.scroll) { proxy.scrollTo(id, anchor: .center) }
                    ai.highlight(line: id, in: meeting)
                }
            }
    }
}

/// Подсветка строки расшифровки, к которой перешли по ссылке.
struct MeetingTurnHighlight: ViewModifier {
    @ObservedObject var ai: MeetingAIModel
    let meeting: String
    let line: Int

    func body(content: Content) -> some View {
        let on = ai.highlighted?.meeting == meeting && ai.highlighted?.turn == line
        // Подложка выходит за края строки и не сдвигает раскладку.
        content
            .background {
                if on {
                    RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                        .fill(Palette.accentSoft)
                        .padding(.horizontal, -DS.Space.xs)
                        .padding(.vertical, -6)
                }
            }
            .animation(Motion.quick, value: on)
    }
}

extension View {
    func meetingTurnHighlight(_ ai: MeetingAIModel, meeting: String, line: Int) -> some View {
        modifier(MeetingTurnHighlight(ai: ai, meeting: meeting, line: line))
    }
}

// MARK: - Согласие (M5–M7)

enum MeetingAICopy {
    static func destination(_ gate: MeetingAIPolicy.Gate) -> String {
        switch gate {
        case .ready(.mlx):
            return L("Локальная модель на этом Mac", "Local model on this Mac")
        case .needsConsent(.mlx):
            return L("Сама не запустилась: нужно разрешение. Модель на этом Mac", "Didn’t start on its own: needs your OK. On-device model")
        case .needsConsent:
            return L("Сама не запустилась: нужно разрешение. Расшифровка уйдёт в Claude", "Didn’t start on its own: needs your OK. The transcript goes to Claude")
        case .sensitiveCloud:
            return sensitiveCloud
        default:
            return L("Расшифровка уйдёт в Claude", "The transcript goes to Claude")
        }
    }

    /// «Чувствительная» встреча и облачная модель: ничего не отправляем.
    static var sensitiveCloud: String {
        L("Встреча помечена «Только на этом Mac»: в Claude она не уйдёт. Сводку и название сделает модель на этом Mac, когда она будет скачана.",
          "This meeting is marked “This Mac only”: it won’t go to Claude. The on-device model writes its summary and title once it’s downloaded.")
    }

    static func tasks(_ n: Int) -> String { L10n.plural(n, ru: "задача", "задачи", "задач", en: "task", "tasks") }
    static func parts(_ n: Int) -> String { L10n.plural(n, ru: "часть", "части", "частей", en: "part", "parts") }
}

/// Лист согласия: для облака это чужие голоса — отдельно от согласия на причёсывание.
struct MeetingAIConsentSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var ai: MeetingAIModel

    private var cloud: Bool {
        if case .needsConsent(.mlx) = MeetingAIPolicy.gate(model.settings) { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(alignment: .center, spacing: DS.Space.s) {
                Image(systemName: cloud ? "cloud" : "desktopcomputer")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Palette.doubt)
                    .frame(width: 20, height: 20)
                Text(cloud ? L("Расшифровка уйдёт в облако Anthropic", "The transcript goes to Anthropic’s cloud")
                           : L("Расшифровку обработает локальная модель", "A local model will process the transcript"))
                    .font(TType.headline).foregroundStyle(Palette.ink)
            }
            Text(cloud
                 ? L("Заметки, сводку, задачи и рецепты сделает Claude Code по вашей подписке. Расшифровка уйдёт в Anthropic: текст и пометки, но не звук. В расшифровке слова других участников, поэтому это отдельное согласие, а не то, что дано для причёсывания диктовки. Оно действует, пока выбран Claude: при смене модели Mostik спросит снова. Встречи с пометкой «Только на этом Mac» не уходят никогда.",
                     "Claude Code will write the notes, summary, tasks and recipes under your subscription. The transcript goes to Anthropic: text and marks, never audio. It holds other people’s words, so this is a separate consent from the one for polishing dictation. It lasts while Claude is selected: change the model and Mostik asks again. Meetings marked “This Mac only” are never sent.")
                 : L("Заметки, сводку и задачи сделает модель на этом Mac. Расшифровка никуда не уходит.",
                     "A model on this Mac writes the notes, summary and tasks. The transcript stays here."))
                .font(TType.body)
                .lineSpacing(3)
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L("После согласия новые встречи будут обрабатываться сразу после расшифровки. Отозвать можно в настройках.",
                   "Once allowed, new meetings are processed right after transcription. You can revoke this in Settings."))
                .font(TType.callout)
                .foregroundStyle(Palette.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.xs) {
                Spacer()
                Button(L("Отмена", "Cancel")) { ai.consentFor = nil }
                    .buttonStyle(.mostik(.quiet))
                    .keyboardShortcut(.cancelAction)
                Button(L("Разрешить и сделать", "Allow and run")) {
                    guard let meeting = ai.consentFor else { return }
                    ai.consentFor = nil
                    ai.onGrantConsent(meeting)
                }
                .buttonStyle(.mostikPrimary)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, DS.Space.xxs)
        }
        .padding(DS.Space.l)
        .frame(width: 460)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card + 4, style: .continuous)
                .fill(Palette.surface)
                .shadow(color: .black.opacity(0.14), radius: 10, y: 6)
        )
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card + 4, style: .continuous).strokeBorder(Palette.edgeStrong))
    }
}

/// Затемнение и лист поверх вкладки «Встречи».
struct MeetingAIConsentOverlay: View {
    @ObservedObject var model: AppModel
    @ObservedObject var ai: MeetingAIModel

    init(model: AppModel) {
        self.model = model
        self.ai = model.meetingAI
    }

    var body: some View {
        ZStack {
            // Согласие из Настроек (`settingsConsent`) показывается на месте выбора, не здесь.
            if let id = ai.consentFor, id != MeetingAIModel.settingsConsent {
                Palette.ink.opacity(0.18)
                    .contentShape(Rectangle())
                    .onTapGesture {}
                MeetingAIConsentSheet(model: model, ai: ai)
            } else if let preview = ai.recipePreview {
                // Черновик ничего не теряет при закрытии (он уже в recipes/) — клик мимо листа закрывает.
                Palette.ink.opacity(0.18).contentShape(Rectangle()).onTapGesture { ai.recipePreview = nil }
                MeetingRecipeSheet(ai: ai, preview: preview)
            } else if let sheet = ai.nextSteps {
                // «Закрыть» ничего не сохраняет и не отправляет — клик мимо листа делает то же.
                Palette.ink.opacity(0.18).contentShape(Rectangle()).onTapGesture { ai.nextSteps = nil }
                MeetingNextStepsSheet(ai: ai, sheet: sheet)
            }
            MeetingSummaryToast(ai: ai)
        }
        .animation(Motion.spring, value: ai.consentFor)
        .animation(Motion.spring, value: ai.recipePreview)
        .animation(Motion.spring, value: ai.nextSteps?.meeting)
    }
}
