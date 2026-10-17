import AppKit
import Foundation
import MostikCore
import MostikKit
import MostikUI

// Сводка встречи сверх M5–M7: шаблоны по типу встречи (M16), виды сводки (W22), рецепты (W7),
// свои записи и картинки как вход (W23), имя встречи из сводки (W21) и следующие шаги
// черновиками (W25). Ничего не отправляется и не создаётся во внешних системах: письмо — черновик
// `mailto:`, задачи — текст, событие — файл `.ics`, который пользователь сам открывает в Календаре.
extension MeetingAIController {
    func wireExtras() {
        ai.onRunVariant = { [weak self] id, key, instruction in self?.runVariant(id, key: key, instruction: instruction) }
        ai.onChooseTemplate = { [weak self] id, template in self?.chooseTemplate(id, template: template) }
        ai.onRunRecipe = { [weak self] id, recipe in self?.runRecipe(id, recipe: recipe) }
        ai.onOpenNextSteps = { [weak self] id in self?.openNextSteps(id) }
        ai.onOpenMailDraft = { draft in
            // Только по нажатию пользователя: почта откроет неотправленный черновик.
            if let url = draft.mailtoURL { NSWorkspace.shared.open(url) }
        }
        ai.onCopy = { [weak self] text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self?.ai.toast = L10n.isRussian ? "Скопировано" : "Copied"
        }
        ai.onSaveTasks = { [weak self] id, text in self?.saveNextStep(id, name: "tasks.md", text: text) }
        ai.onSaveICS = { [weak self] id, event in self?.saveICS(id, event: event) }
        ai.onAddICSToCalendar = { path in
            // Календарь сам спросит, в какой календарь добавить, — событие создаёт пользователь.
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        ai.onReveal = { path in NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        ai.onAddImages = { [weak self] id in self?.addImages(id) }
        ai.onOpenNotes = { [weak self] id in self?.openNotes(id) }
        ai.onOpenTemplatesFolder = { [weak self] in self?.openTemplatesFolder() }
        ai.onUseNotes = { [weak self] on in
            guard let self else { return }
            var settings = self.model.settings
            settings.meetingNotes.useMyNotes = on
            self.model.onUpdateSettings(settings)  // только через applySettings (П10)
        }
    }

    /// Как просить сводку: выбранный шаблон и галочка «использовать мои пометки».
    func options(for id: String) -> EngineClient.MeetingAIOptions {
        .init(template: ai.chosenTemplate[id], useNotes: model.settings.meetingNotes.useMyNotes)
    }

    /// W21: «Встреча 14:32» → тема из сводки. Движок уже переписал манифест; здесь — список встреч.
    func applyTitle(_ reply: [String: JSONValue], meeting id: String) {
        guard reply["title_source"]?.stringValue == "summary", let title = reply["title"]?.stringValue,
              !title.isEmpty, let index = model.meetings.firstIndex(where: { $0.id == id }) else { return }
        model.meetings[index].title = title
    }

    func isSensitive(_ id: String) -> Bool {
        if model.meetingExtras.sensitive.contains(id) { return true }
        guard let meeting = meeting(id) else { return true }
        return MeetingFolder.isSensitive(meeting.folder)
    }

    // MARK: шаблоны

    func loadTemplatesIfNeeded() {
        guard !templatesLoaded else { return }
        templatesLoaded = true
        let client = engine()
        Task {
            do {
                let reply = try await client.meetingTemplates()
                self.ai.templates = MeetingTemplateInfo.list(reply["templates"])
                self.ai.recipes = MeetingTemplateInfo.list(reply["recipes"])
            } catch {
                // Движок ещё не поднялся — попробуем при следующем чтении встречи.
                self.templatesLoaded = false
            }
        }
    }

    private func chooseTemplate(_ id: String, template: String?) {
        if let template { ai.chosenTemplate[id] = template } else { ai.chosenTemplate.removeValue(forKey: id) }
        // Пересобрать основную сводку: движок сначала кладёт прежнюю в `history/`.
        ai.view[id] = MeetingAIVariant.main
        run(id, mode: ai.mode(for: id))
    }

    // MARK: виды сводки (W22)

    func runVariant(_ id: String, key: String, instruction: String?) {
        guard let meeting = meeting(id),
              case let .ready(backend) = MeetingAIPolicy.gate(model.settings, sensitive: isSensitive(id), localModel: model.localLLMInstalled) else { return }
        let custom = key == "custom"
        let text = instruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if custom && text.isEmpty { return }
        let phaseKey = id + "|" + key
        guard !variantsInFlight.contains(phaseKey) else { return }
        variantsInFlight.append(phaseKey)
        ai.variantPhases[phaseKey] = .queued
        ai.view[id] = key
        ai.customFor = nil
        let language = model.settings.language
        let mode = ai.mode(for: id)
        let options = EngineClient.MeetingAIOptions(variant: key, instruction: custom ? text : nil,
                                                    useNotes: model.settings.meetingNotes.useMyNotes)
        let client = engine()
        Task {
            var failure: String?
            var stored = key
            do {
                let reply = try await client.meetingAI(folder: meeting.folder, mode: mode, language: language,
                                                       backend: backend, options: options)
                if let variant = reply["variant"]?.stringValue { stored = variant }
                if reply["status"]?.stringValue == "failed" { failure = reply["error"]?.stringValue ?? "" }
            } catch {
                failure = error.localizedDescription
            }
            self.variantsInFlight.removeAll { $0 == phaseKey }
            self.load(meeting) {
                if let failure {
                    self.ai.variantPhases[phaseKey] = .failed(failure)
                } else {
                    self.ai.variantPhases.removeValue(forKey: phaseKey)
                    self.ai.view[id] = stored
                }
            }
        }
    }

    // MARK: рецепты (W7)

    private func runRecipe(_ id: String, recipe: String) {
        guard let meeting = meeting(id), ai.recipeRunning[id] == nil else { return }
        // Чувствительные встречи в рецепты не идут — и движок это проверяет ещё раз.
        if isSensitive(id) {
            ai.toast = L10n.isRussian ? "Письмо, задачи и событие по встрече недоступны: она только для этого Mac"
                                      : "Email, tasks and event are unavailable: this meeting is for this Mac only"
            return
        }
        guard case let .ready(backend) = MeetingAIPolicy.gate(model.settings, sensitive: isSensitive(id), localModel: model.localLLMInstalled) else { return }
        ai.recipeRunning[id] = recipe
        let info = ai.recipes.first { $0.id == recipe }
        let language = model.settings.language
        let useNotes = model.settings.meetingNotes.useMyNotes
        let client = engine()
        Task {
            defer { self.ai.recipeRunning.removeValue(forKey: id) }
            do {
                let reply = try await client.meetingRecipe(folder: meeting.folder, recipe: recipe, language: language,
                                                           backend: backend, useNotes: useNotes)
                guard reply["status"]?.stringValue == "done", let text = reply["text"]?.stringValue else {
                    let why = reply["error"]?.stringValue ?? ""
                    self.ai.toast = why == "sensitive"
                        ? (L10n.isRussian ? "Встреча только для этого Mac — рецепт не запущен" : "This Mac only meeting — recipe not run")
                        : (L10n.isRussian ? "Рецепт не получился: " : "Recipe failed: ") + why
                    return
                }
                self.ai.recipePreview = .init(meeting: id, recipe: recipe,
                                              name: info?.title(russian: L10n.isRussian) ?? recipe, text: text,
                                              path: reply["path"]?.stringValue, email: info?.output == "email")
            } catch {
                self.ai.toast = (L10n.isRussian ? "Рецепт не получился: " : "Recipe failed: ") + error.localizedDescription
            }
        }
    }

    // MARK: следующие шаги (W25)

    private func openNextSteps(_ id: String) {
        guard let meeting = meeting(id), let result = ai.result(for: id), !isSensitive(id) else { return }
        // Письмо «от меня» из рецепта, если его уже делали, — иначе собранное из сводки.
        let recipeEmail = Self.latestRecipeEmail(meeting.folder)
        let steps = MeetingNextSteps.build(result: result, title: meeting.title, started: meeting.startedAt,
                                           meetingID: id, russian: L10n.isRussian, recipeEmail: recipeEmail)
        ai.nextSteps = .init(meeting: id, steps: steps)
    }

    static func latestRecipeEmail(_ folder: URL) -> (subject: String, body: String)? {
        let dir = folder.appendingPathComponent("recipes")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        guard let name = files.filter({ $0.hasPrefix("followup-email-") && $0.hasSuffix(".md") }).sorted().last,
              let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\n")
        var subject = ""
        if let first = lines.first, let range = first.range(of: #"^(Тема|Subject):\s*"#, options: .regularExpression) {
            subject = String(first[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            lines.removeFirst()
        }
        return (subject, lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Черновики шагов — в `<встреча>/next-steps/`.
    @discardableResult
    private func saveNextStep(_ id: String, name: String, text: String) -> URL? {
        guard let meeting = meeting(id) else { return nil }
        let dir = meeting.folder.appendingPathComponent("next-steps")
        let url = dir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            ai.toast = (L10n.isRussian ? "Не сохранилось: " : "Not saved: ") + error.localizedDescription
            return nil
        }
        ai.toast = (L10n.isRussian ? "Сохранено: " : "Saved: ") + "next-steps/" + name
        return url
    }

    private func saveICS(_ id: String, event: MeetingEventDraft) {
        guard let url = saveNextStep(id, name: "follow-up.ics", text: ICSWriter.render(event)) else { return }
        ai.nextSteps?.savedICS = url.path
    }

    // MARK: свои записи и картинки (W23)

    /// Сколько своих записей и какие картинки во встрече — для полоски «Что ещё учтёт сводка».
    nonisolated static func scanInputs(_ folder: URL) -> MeetingAIModel.MeetingInputsInfo {
        let text = (try? String(contentsOf: folder.appendingPathComponent(MeetingFolder.notesName), encoding: .utf8)) ?? ""
        let chars = text.split(separator: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#") && !trimmed.hasPrefix("![")
        }.reduce(0) { $0 + $1.count }
        let attachments = folder.appendingPathComponent("attachments")
        let images = ((try? FileManager.default.contentsOfDirectory(atPath: attachments.path)) ?? [])
            .filter { ["png", "jpg", "jpeg", "heic", "gif", "tiff", "webp"].contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
        return .init(notesChars: chars, images: images)
    }

    /// «Добавить картинку…»: копия в `attachments/`, распознанный текст рядом, строка в `notes.md`.
    private func addImages(_ id: String) {
        guard let meeting = meeting(id) else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.message = L10n.isRussian ? "Картинки к встрече: текст на них распознается на этом Mac"
                                       : "Images for the meeting: their text is read on this Mac"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let sources = panel.urls
        let folder = meeting.folder
        ai.toast = L10n.isRussian ? "Распознаём текст на картинках…" : "Reading text in images…"
        Task.detached(priority: .userInitiated) {
            let added = Self.attach(sources, to: folder)
            await MainActor.run {
                self.ai.inputs[id] = Self.scanInputs(folder)
                self.ai.toast = L10n.isRussian ? "Добавлено картинок: \(added)" : "Images added: \(added)"
            }
        }
    }

    nonisolated static func attach(_ sources: [URL], to folder: URL) -> Int {
        let fm = FileManager.default
        let dir = folder.appendingPathComponent("attachments")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var lines: [String] = []
        for source in sources {
            // Имя без пробелов и скобок: путь в Markdown-ссылке не ломается.
            let base = source.deletingPathExtension().lastPathComponent
                .components(separatedBy: CharacterSet(charactersIn: " ()[]")).filter { !$0.isEmpty }.joined(separator: "-")
            let ext = source.pathExtension
            var target = dir.appendingPathComponent(base + (ext.isEmpty ? "" : "." + ext))
            var n = 2
            while fm.fileExists(atPath: target.path) {
                target = dir.appendingPathComponent("\(base)-\(n)" + (ext.isEmpty ? "" : "." + ext))
                n += 1
            }
            guard (try? fm.copyItem(at: source, to: target)) != nil else { continue }
            let text = ImageOCR.recognize(target)
            if !text.isEmpty { try? text.write(to: ImageOCR.sidecar(for: target), atomically: true, encoding: .utf8) }
            let caption = source.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
            lines.append("![\(caption)](attachments/\(target.lastPathComponent))")
        }
        guard !lines.isEmpty else { return 0 }
        let notes = folder.appendingPathComponent(MeetingFolder.notesName)
        var text = (try? String(contentsOf: notes, encoding: .utf8)) ?? ""
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        // Свой раздел: в конце файла может стоять «Пометки» или заметка агента — их движок не берёт.
        let heading = L10n.isRussian ? "## Картинки" : "## Images"
        let lastHeading = text.components(separatedBy: "\n").last { $0.hasPrefix("#") }
        if lastHeading?.trimmingCharacters(in: .whitespaces) != heading { text += "\n" + heading + "\n" }
        text += "\n" + lines.joined(separator: "\n") + "\n"
        try? text.write(to: notes, atomically: true, encoding: .utf8)
        return lines.count
    }

    private func openNotes(_ id: String) {
        guard let meeting = meeting(id) else { return }
        let url = meeting.folder.appendingPathComponent(MeetingFolder.notesName)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? (L10n.isRussian ? "# Мои заметки\n\n" : "# My notes\n\n").write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }

    private func openTemplatesFolder() {
        let client = engine()
        Task {
            guard let reply = try? await client.meetingTemplates(ensure: true),
                  case let .object(dirs)? = reply["dirs"], let path = dirs["template"]?.stringValue else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }
}
