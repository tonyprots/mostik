import AppKit
import Combine
import Foundation
import MostikCore
import MostikKit
import MostikUI

/// Говорящие встреч (M14, M15): читает `transcript.json`, отдаёт правки движку, держит голосовую память.
/// Решения — в MostikCore (`MeetingSpeakers`) и движке (`meeting_speakers.py`, `voices.py`), здесь только связка.
@MainActor
final class SpeakersController {
    private let model: AppModel
    private let engine: () -> EngineClient
    private var speakers: MeetingSpeakersModel { model.meetingSpeakers }
    private var seen: [String: [AppModel.TranscriptLine]] = [:]
    private var cancellables: Set<AnyCancellable> = []

    init(model: AppModel, engine: @escaping () -> EngineClient) {
        self.model = model
        self.engine = engine
        wireIntents()
        // Расшифровка встречи появилась или поменялась — перечитать говорящих этой встречи.
        model.$meetingTranscripts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transcripts in self?.transcriptsChanged(transcripts) }
            .store(in: &cancellables)
    }

    /// Движок запущен: включить память, если есть согласие, и узнать, есть ли модель голоса.
    func engineReady() async {
        let s = model.settings
        _ = try? await engine().voicesConfig(enabled: s.voiceMemory && s.voiceMemoryConsent)
        await refreshStatus()
    }

    private func refreshStatus() async {
        guard let reply = try? await engine().voicesStatus() else { return }
        speakers.status = VoiceMemoryStatus.parse(reply, previous: speakers.status)
    }

    private func transcriptsChanged(_ transcripts: [String: [AppModel.TranscriptLine]]) {
        let changed = transcripts.filter { seen[$0.key] != $0.value }.map(\.key)
        seen = transcripts
        let folders = Dictionary(model.meetings.map { ($0.id, $0.folder) }, uniquingKeysWith: { a, _ in a })
        for id in changed {
            guard let folder = folders[id] else { continue }
            let url = folder.appendingPathComponent("transcript.json")
            Task.detached(priority: .utility) {
                let parsed = (try? Data(contentsOf: url)).map(MeetingSpeakers.parse) ?? MeetingSpeakers()
                await MainActor.run { self.speakers.byMeeting[id] = parsed }
            }
        }
    }

    private func folder(_ meeting: String) -> URL? { model.meetings.first { $0.id == meeting }?.folder }

    /// Правка через движок, потом — перечитать расшифровку встречи целиком.
    private func edit(_ meeting: String, _ action: @escaping (EngineClient, URL) async throws -> [String: JSONValue],
                      done: (([String: JSONValue]) -> String?)? = nil) {
        guard let folder = folder(meeting) else { return }
        speakers.busy.insert(meeting)
        speakers.message[meeting] = nil
        Task {
            do {
                let reply = try await action(engine(), folder)
                speakers.message[meeting] = done?(reply)
            } catch {
                speakers.message[meeting] = error.localizedDescription
            }
            let json = folder.appendingPathComponent("transcript.json")
            model.meetingTranscripts[meeting] = AppController.parseTranscript(json: json)
            speakers.byMeeting[meeting] = (try? Data(contentsOf: json)).map(MeetingSpeakers.parse) ?? MeetingSpeakers()
            speakers.busy.remove(meeting)
            if model.settings.voiceMemory { await refreshStatus() }
        }
    }

    private static func remembered(_ reply: [String: JSONValue]) -> String? {
        guard case let .object(person)? = reply["person"], let name = person["name"]?.stringValue else { return nil }
        return person["merged"]?.boolValue == true
            ? L10n.isRussian ? "Голос добавлен к образцам: \(name)." : "Voice added to \(name)’s samples."
            : L10n.isRussian ? "Голос запомнен: \(name)." : "Voice remembered: \(name)."
    }

    /// «Стереть отпечатки голосов?» — кнопка по умолчанию (Return) — «Стереть».
    private func askWipe() -> Bool {
        let ru = L10n.isRussian
        let alert = NSAlert()
        alert.messageText = ru ? "Стереть отпечатки голосов?" : "Erase voiceprints?"
        alert.informativeText = ru
            ? "Голосовая память выключена. Стереть всех, кого Mostik помнит, и отпечатки голосов из встреч? Расшифровки останутся."
            : "Voice memory is off. Erase everyone Mostik remembers and the voice vectors from meetings? Transcripts stay."
        alert.addButton(withTitle: ru ? "Стереть" : "Erase")
        alert.addButton(withTitle: ru ? "Оставить" : "Keep")
        MenuBarPanel.activateApp()
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func wireIntents() {
        speakers.onRename = { [weak self] meeting, label, name in
            self?.edit(meeting, { try await $0.speakerRename(folder: $1, label: label, name: name) }, done: { reply in
                // Имя уже было у другой метки — движок объединил их в одного человека (E2).
                let merged = reply["merged_from"]?.stringValue != nil
                    ? (L10n.isRussian ? "Это один человек: реплики объединены под именем «\(name)»." :
                                        "Same person: turns merged under “\(name)”.")
                    : nil
                let text = [merged, Self.remembered(reply)].compactMap { $0 }.joined(separator: " ")
                return text.isEmpty ? nil : text
            })
        }
        speakers.onConfirm = { [weak self] meeting, label in
            self?.edit(meeting, { try await $0.speakerConfirm(folder: $1, label: label) }, done: Self.remembered)
        }
        speakers.onReject = { [weak self] meeting, label in
            self?.edit(meeting, { try await $0.speakerReject(folder: $1, label: label) })
        }
        speakers.onUnname = { [weak self] meeting, label in
            self?.edit(meeting, { try await $0.speakerUnname(folder: $1, label: label) }, done: { reply in
                let removed = reply["removed"]?.stringValue ?? ""
                return L10n.isRussian ? "Имя «\(removed)» убрано." : "Name “\(removed)” removed."
            })
        }
        speakers.onMerge = { [weak self] meeting, source, target in
            self?.edit(meeting, { try await $0.speakerMerge(folder: $1, source: source, target: target) }, done: { reply in
                let who = reply["speaker"]?.stringValue ?? target
                return Self.remembered(reply) ?? (L10n.isRussian ? "Объединено: \(who)." : "Merged into \(who).")
            })
        }
        speakers.onSetTurn = { [weak self] meeting, turn, label in
            self?.edit(meeting, { try await $0.speakerTurn(folder: $1, turn: turn, label: label) })
        }
        speakers.onSetTurnName = { [weak self] meeting, turn, name in
            self?.edit(meeting, { try await $0.speakerTurn(folder: $1, turn: turn, label: nil, name: name) })
        }
        speakers.onSetEnabled = { [weak self] on in
            guard let self else { return }
            let wasOn = model.settings.voiceMemory
            var s = model.settings
            s.voiceMemory = on
            if on { s.voiceMemoryConsent = true }
            model.onUpdateSettings(s)
            // П10 С8: выключили — спросить, стереть ли отпечатки; по умолчанию «Стереть».
            let wipe = VoiceMemoryWipe.asks(old: wasOn, new: on) && askWipe()
            Task {
                _ = try? await self.engine().voicesConfig(enabled: on)
                if wipe {
                    do {
                        try await self.engine().voicesWipe()
                    } catch {
                        NSLog("Mostik voices_wipe: \(error.localizedDescription)")
                    }
                }
                await self.refreshStatus()
            }
        }
        speakers.onRenamePerson = { [weak self] id, name in
            guard let self else { return }
            Task {
                if let reply = try? await self.engine().voicesRename(person: id, name: name) {
                    self.speakers.status = VoiceMemoryStatus.parse(reply, previous: self.speakers.status)
                }
            }
        }
        speakers.onForget = { [weak self] id in
            guard let self else { return }
            Task {
                if let reply = try? await self.engine().voicesForget(person: id) {
                    self.speakers.status = VoiceMemoryStatus.parse(reply, previous: self.speakers.status)
                }
                // Подсказки забытых пропали из расшифровок — перечитать открытые встречи.
                let ids = Array(self.speakers.byMeeting.keys)
                for meeting in ids {
                    guard let json = self.folder(meeting)?.appendingPathComponent("transcript.json") else { continue }
                    self.speakers.byMeeting[meeting] = (try? Data(contentsOf: json)).map(MeetingSpeakers.parse) ?? MeetingSpeakers()
                }
            }
        }
        speakers.onRefreshStatus = { [weak self] in
            guard let self else { return }
            Task { await self.refreshStatus() }
        }
    }
}
