import AppKit
import Combine
import Foundation
import MostikCore
import MostikKit
import MostikUI

/// ИИ встреч (M5–M7): читает `notes.json`, запускает `meeting_ai` в движке, правит пометки.
///
/// Встречи берёт из `AppModel.meetings`: готовая встреча (`.done`) читается с диска, а встреча,
/// которая только что перешла из «обработки» в «готово», уходит в движок сама — если есть
/// согласие и бэкенд (`MeetingAIPolicy.autoRun`). Очередь в движке одна: встречи идут по одной.
@MainActor
final class MeetingAIController {
    let model: AppModel
    let engine: () -> EngineClient
    var ai: MeetingAIModel { model.meetingAI }
    private var states: [String: AppModel.MeetingState] = [:]
    private var loaded: Set<String> = []
    /// Встречи, отправленные в движок, в порядке отправки: прогресс без папки относится к первой.
    private var inFlight: [String] = []
    private var cancellables: Set<AnyCancellable> = []
    /// Дополнительные сводки в движке: «встреча|вид» (W22).
    var variantsInFlight: [String] = []
    var templatesLoaded = false
    /// Сводка встречи записана без ошибки — для хука и переноса аудио (M11, W13).
    var finished: (String) -> Void = { _ in }

    init(model: AppModel, engine: @escaping () -> EngineClient) {
        self.model = model
        self.engine = engine
        ai.onRun = { [weak self] id, mode in self?.run(id, mode: mode) }
        ai.onGrantConsent = { [weak self] id in self?.grantConsent(id) }
        ai.onEditMark = { [weak self] id, index, text in self?.editMark(id, index: index, text: text) }
        ai.onEditTask = { [weak self] id, place, index, change in self?.editTask(id, place: place, index: index, change: change) }
        wireExtras()
        model.$meetings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] meetings in self?.meetingsChanged(meetings) }
            .store(in: &cancellables)
    }

    // MARK: встречи

    private func meetingsChanged(_ meetings: [AppModel.MeetingItem]) {
        for meeting in meetings {
            let previous = states[meeting.id]
            states[meeting.id] = meeting.state
            guard meeting.state == .done else { continue }
            if case .processing? = previous {
                // Расшифровка только что закончилась: перечитать и, если можно, обработать.
                load(meeting, then: { [weak self] in
                    guard let self, self.ai.files[meeting.id] == nil else { return }
                    let gate = MeetingAIPolicy.gate(self.model.settings, sensitive: self.isSensitive(meeting.id),
                                                    localModel: self.model.localLLMInstalled)
                    guard case .ready = gate else {
                        // Раньше отказ был немым: «почему нет автосводки» нечем было проверить.
                        AppLog.shared.event("meetingAI", "auto summary skipped: \(gate)")
                        return
                    }
                    self.run(meeting.id, mode: self.ai.mode(for: meeting.id))
                })
            } else if !loaded.contains(meeting.id) {
                load(meeting)
            }
        }
    }

    /// `notes.json` и пометки из `transcript.json` — в фоне: у долгих встреч файлы большие.
    func load(_ meeting: AppModel.MeetingItem, then: (() -> Void)? = nil) {
        loaded.insert(meeting.id)
        loadTemplatesIfNeeded()
        let folder = meeting.folder
        Task.detached(priority: .utility) {
            let file = (try? Data(contentsOf: folder.appendingPathComponent("notes.json"))).flatMap(MeetingAIFile.parse)
            let marks = (try? Data(contentsOf: folder.appendingPathComponent("transcript.json")))
                .map(MeetingAILink.marks(transcriptJSON:)) ?? []
            let inputs = MeetingAIController.scanInputs(folder)
            await MainActor.run {
                if let file { self.ai.files[meeting.id] = file } else { self.ai.files.removeValue(forKey: meeting.id) }
                self.ai.marks[meeting.id] = marks
                self.ai.inputs[meeting.id] = inputs
                then?()
            }
        }
    }

    func meeting(_ id: String) -> AppModel.MeetingItem? { model.meetings.first { $0.id == id } }

    // MARK: запуск

    func run(_ id: String, mode: MeetingAIMode) {
        guard let meeting = meeting(id),
              case let .ready(backend) = MeetingAIPolicy.gate(model.settings, sensitive: isSensitive(meeting.id),
                                                                    localModel: model.localLLMInstalled) else { return }
        if inFlight.contains(id) { return }
        ai.modes[id] = mode
        ai.phases[id] = .queued
        inFlight.append(id)
        let language = model.settings.language
        let client = engine()
        Task {
            var failure: String?
            do {
                let reply = try await client.meetingAI(folder: meeting.folder, mode: mode, language: language, backend: backend,
                                                       options: self.options(for: id))
                if reply["status"]?.stringValue == "failed" {
                    failure = reply["error"]?.stringValue ?? ""
                }
                self.applyTitle(reply, meeting: id)
            } catch {
                failure = error.localizedDescription
            }
            self.inFlight.removeAll { $0 == id }
            // Итог — из файла: там и удачный режим, и пометка «не удалось» для этого режима.
            self.load(meeting) {
                if let failure, self.ai.result(for: id)?.status != .failed {
                    // Движок не дошёл до записи файла (упал, нет связи) — показываем причину здесь.
                    self.ai.phases[id] = .failed(failure)
                } else {
                    self.ai.phases[id] = .idle
                    if failure == nil { self.finished(id) }
                }
            }
        }
    }

    /// Событие `progress` с `task: meeting_ai` — к встрече, которая сейчас в работе.
    func progress(stage: String, done: Int, total: Int) {
        if let id = inFlight.first {
            ai.phases[id] = .running(stage)
        } else if let key = variantsInFlight.first {
            ai.variantPhases[key] = .running(stage)
        }
    }

    private func grantConsent(_ id: String) {
        var settings = model.settings
        // С листа, где прямо сказано, куда уйдёт расшифровка: для облака ставится и облачное согласие.
        settings.grantMeetingAI()
        // Только через applySettings (П10): там сброс облачного согласия и снимок для движка.
        model.onUpdateSettings(settings)
        // Лист открыт из Настроек — встречи нет, только согласие.
        guard !id.isEmpty else { return }
        run(id, mode: ai.mode(for: id))
    }

    // MARK: задачи

    /// Сделано, правка текста или удаление — сразу в `notes.json`; окно перечитывает файл из записанного.
    private func editTask(_ id: String, place: MeetingAITaskPlace, index: Int, change: MeetingAITaskEdit) {
        guard let meeting = meeting(id) else { return }
        let url = meeting.folder.appendingPathComponent("notes.json")
        guard let data = try? Data(contentsOf: url), let updated = change.applied(to: data, place: place, index: index) else { return }
        do {
            try updated.write(to: url, options: .atomic)
        } catch {
            NSLog("Mostik: задача не сохранена: \(error)")
            return
        }
        if let file = MeetingAIFile.parse(updated) { ai.files[id] = file }
    }

    // MARK: пометки

    /// Поправить пометку в `transcript.json` и `transcript.md`; заметка покажет разорванную связь.
    private func editMark(_ id: String, index: Int, text: String) {
        guard let meeting = meeting(id) else { return }
        let json = meeting.folder.appendingPathComponent("transcript.json")
        let md = meeting.folder.appendingPathComponent("transcript.md")
        guard let data = try? Data(contentsOf: json) else { return }
        let old = MeetingAILink.marks(transcriptJSON: data)
        guard old.indices.contains(index), let updated = MeetingAILink.replacingMark(in: data, index: index, text: text)
        else { return }
        do {
            try updated.write(to: json, options: .atomic)
            if let markdown = try? String(contentsOf: md, encoding: .utf8) {
                let patched = MeetingAILink.replacingMark(inMarkdown: markdown, old: old[index].text, new: text)
                try patched.write(to: md, atomically: true, encoding: .utf8)
            }
        } catch {
            NSLog("Mostik: пометка не сохранена: \(error)")
            return
        }
        ai.marks[id] = MeetingAILink.marks(transcriptJSON: updated)
        model.meetingTranscripts[id] = AppController.parseTranscript(json: json)
    }
}
