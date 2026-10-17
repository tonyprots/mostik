import SwiftUI
import MostikCore

/// Снимки говорящих встречи (M14, M15): панель с подсказкой, метка под вопросом, настройки и согласие.
/// Люди и голоса вымышленные.
extension Snapshots {
    @MainActor
    static func renderMeetingSpeakers(to dir: URL) {
        let anna = L("Анна", "Anna"), vera = L("Вера", "Vera"), boris = L("Борис", "Boris")
        let s1 = L("Собеседник 1", "Speaker 1"), s2 = L("Собеседник 2", "Speaker 2"), s3 = L("Собеседник 3", "Speaker 3")

        // Окно встречи: второй голос не назван, память предлагает имя; одна реплика под вопросом.
        for dark in [false, true] {
            let model = demoModel()
            model.selectedTab = .meetings
            model.meetingTranscripts["m2"] = (model.meetingTranscripts["m2"] ?? []).map { line in
                var line = line
                if line.speaker == boris { line.speaker = s2 }
                return line
            }
            model.meetingAI.section["m2"] = .transcript  // П9-B: говорящие — в разделе «Расшифровка»
            model.meetingSpeakers.byMeeting["m2"] = MeetingSpeakers(
                speakers: [.init(label: s1, name: anna, seconds: 412, turns: 9),
                           .init(label: s2, name: s2, seconds: 388, turns: 7),
                           .init(label: s3, name: vera, seconds: 46, turns: 2)],
                reviews: [.init(turn: 4, label: s3, speaker: vera, start: 44, confidence: 0.42,
                                alternatives: [.init(label: s1, name: anna, share: 0.35)])],
                suggestions: [.init(label: s2, personID: "p1", name: boris, score: 0.74)],
                memoryUsed: true)
            write(MainWindowView(model: model, entry: nil, meeting: "m2"), "main-meetings-speakers" + (dark ? "-dark" : ""), dir,
                  width: 1080, height: 1180, dark: dark)
        }

        // E2: старая расшифровка, где одному человеку дали имя дважды, — в списке он один.
        // E3: поповер имени из строки расшифровки (меню и поповер `ImageRenderer` не рисует — карточка отдельно).
        for dark in [false, true] {
            let model = demoModel()
            model.selectedTab = .meetings
            let s4 = L("Собеседник 4", "Speaker 4")
            model.meetingAI.section["m2"] = .transcript
            model.meetingSpeakers.byMeeting["m2"] = MeetingSpeakers(
                speakers: [.init(label: s1, name: anna, seconds: 640, turns: 12, labels: [s1, s4]),
                           .init(label: s2, name: boris, seconds: 388, turns: 7),
                           .init(label: s3, name: s3, seconds: 46, turns: 2)],
                memoryUsed: false)
            write(MainWindowView(model: model, entry: nil, meeting: "m2"), "main-meetings-speakers-merged" + (dark ? "-dark" : ""), dir,
                  width: 1080, height: 900, dark: dark)
            for (name, speaker) in [("speaker-rename-card", MeetingSpeakers.Speaker(label: s1, name: anna, seconds: 640, turns: 12)),
                                    ("speaker-name-card", MeetingSpeakers.Speaker(label: s3, name: s3, seconds: 46, turns: 2))] {
                let card = SpeakerRenameCard(speaker: speaker, draft: .constant(speaker.isNamed ? speaker.name : ""),
                                             onCancel: {}, onCommit: {}, onUnname: {})
                    .background(Palette.surface)
                write(card, name + (dark ? "-dark" : ""), dir, width: 380, dark: dark)
            }
            // M15: «Другой…» у реплики под вопросом — говорящие встречи или новое имя.
            let reassign = SpeakerReassignCard(others: [.init(label: s1, name: anna, seconds: 640, turns: 12),
                                                        .init(label: s2, name: boris, seconds: 388, turns: 7)],
                                               draft: .constant(""), onCancel: {}, onPick: { _ in }, onName: { _ in })
                .background(Palette.surface)
            write(reassign, "speaker-reassign-card" + (dark ? "-dark" : ""), dir, width: 380, dark: dark)
        }

        // Нет fluidaudiocli: встреча расшифрована одним собеседником, над говорящими — спокойная строка.
        do {
            let model = demoModel()
            model.selectedTab = .meetings
            model.meetingTranscripts["m2"] = (model.meetingTranscripts["m2"] ?? []).map { line in
                var line = line
                if line.speaker != anna { line.speaker = s1 }
                return line
            }
            if let index = model.meetings.firstIndex(where: { $0.id == "m2" }) {
                model.meetings[index].diarizationUnavailable = true
                model.meetings[index].speakers = 1
            }
            model.meetingAI.section["m2"] = .transcript
            write(MainWindowView(model: model, entry: nil, meeting: "m2"), "main-meetings-no-diarization", dir,
                  width: 1080, height: 900, dark: false)
        }

        // Настройки: память включена, два человека; и вариант без модели голоса.
        for (name, available) in [("settings-voice-memory", true), ("settings-voice-memory-no-model", false)] {
            for dark in [false, true] where available || !dark {
                let model = demoModel()
                model.settings.voiceMemory = available
                model.settings.voiceMemoryConsent = available
                model.meetingSpeakers.status = VoiceMemoryStatus(
                    available: available, detail: "", model: "fluidaudio-wespeaker-v2-256",
                    people: available ? [VoicePerson(id: "p1", name: boris, samples: 4, seconds: 1260),
                                         VoicePerson(id: "p2", name: anna, samples: 10, seconds: 5400)] : [])
                let section = VoiceMemorySettingsSection(model: model)
                    .padding(DS.Space.l)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(Palette.canvas)
                write(section, name + (dark ? "-dark" : ""), dir, width: 688, dark: dark)
            }
        }

        // Экран согласия.
        for dark in [false, true] {
            write(VoiceMemoryConsentView(onAgree: {}, onCancel: {}), "voice-memory-consent" + (dark ? "-dark" : ""), dir,
                  width: 520, dark: dark)
        }
    }
}
