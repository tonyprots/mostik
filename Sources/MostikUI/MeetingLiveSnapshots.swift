import SwiftUI
import MostikCore

/// Снимки П6-Б: живая расшифровка и «только текст» (W10, W15), продолжение (W16), ремонт говорящих (W17),
/// цитата сводки (W18), черновик письма (W20), настройки по ходу записи (W24, V6) и голоса (A1).
/// Люди, голоса и разговоры вымышленные.
extension Snapshots {
    /// Установленные голоса для демо: свои у каждого Mac, здесь — выдуманный набор.
    static var demoVoices: [SystemVoiceInfo] {
        [SystemVoiceInfo(id: "demo.ru.milena.premium", name: "Milena", language: "ru-RU", quality: 3),
         SystemVoiceInfo(id: "demo.ru.yuri", name: "Yuri", language: "ru-RU", quality: 1),
         SystemVoiceInfo(id: "demo.en.ava.enhanced", name: "Ava", language: "en-US", quality: 2),
         SystemVoiceInfo(id: "demo.en.samantha", name: "Samantha", language: "en-US", quality: 1)]
    }

    @MainActor
    static func renderMeetingLive(to dir: URL) {
        for dark in [false, true] {
            let suffix = dark ? "-dark" : ""

            // W10, W15: идёт запись, строки по ходу, «только текст» включён с середины.
            let live = liveMeetingModel()
            live.selectedTab = .meetings
            live.meetingLive.textOnly = true
            var transcript = LiveTranscript()
            transcript.add(track: "system", start: 688, text: L("Давайте по задержкам: на длинных файлах мы теряем почти секунду на диаризации.",
                                                                  "On latency: we lose almost a second on diarization for long files."))
            transcript.add(track: "mic", start: 703, text: L("Секунда — это в холодном старте или всегда?", "Is that second on a cold start or always?"))
            transcript.add(track: "system", start: 711, text: L("Всегда, модель голосов грузится на каждую встречу заново.",
                                                                  "Always — the voice model reloads for every meeting."))
            transcript.add(track: "mic", start: 728, text: L("Тогда держим её тёплой, пока открыто окно встречи.",
                                                               "Then keep it warm while the meeting window is open."))
            live.meetingLive.transcript = transcript
            write(MainWindowView(model: live, entry: nil, meeting: "m0"), "main-meetings-live-transcript" + suffix, dir,
                  width: 1080, height: 1020, dark: dark)

            // R3a: сбой на модели голосов — повтор без разделения по голосам.
            let memory = demoModel()
            memory.selectedTab = .meetings
            if let index = memory.meetings.firstIndex(where: { $0.id == "m4" }) {
                memory.meetings[index].failureCode = EngineErrorText.diarizationMemory
            }
            write(MainWindowView(model: memory, entry: nil, meeting: "m4"), "main-meetings-voice-memory" + suffix, dir,
                  width: 1080, height: 700, dark: dark)

            // W16, W17, W18: готовая встреча — «Продолжить запись», фильтр по говорящему, «Слушать с…», итог правки.
            let repair = demoModel()
            repair.selectedTab = .meetings
            repair.meetingLive.continuable = ["m2"]
            repair.meetingLive.speakerFilter["m2"] = L("Борис", "Boris")
            repair.meetingLive.cue["m2"] = 21
            repair.meetingAI.section["m2"] = .transcript  // П9-B: ремонт говорящих — в разделе «Расшифровка»
            repair.meetingLive.repairNote["m2"] = L("«Собеседник 3» → Борис: перенесено реплик — 2.", "“Speaker 3” → Boris: 2 turns moved.")
            write(MainWindowView(model: repair, entry: nil, meeting: "m2"), "main-meetings-repair" + suffix, dir,
                  width: 1080, height: 900, dark: dark)

            // W18: карточка цитаты при наведении.
            let quote = demoModel()
            let line = (quote.meetingTranscripts["m2"] ?? []).first { !$0.isMark && $0.start == 21 }
            if let line {
                write(QuoteCard(model: quote, meeting: "m2", line: line)
                        .background(Palette.surface)
                        .padding(DS.Space.m)
                        .background(Palette.canvas),
                      "meeting-quote-card" + suffix, dir, width: 380, dark: dark)
            }

            // W20: карточка ближайшей встречи с адресами участников.
            let upcoming = demoModel()
            let soon = UpcomingMeeting(id: "e1", title: L("Синк с дизайном", "Design sync"),
                                       start: Date().addingTimeInterval(600), end: Date().addingTimeInterval(4200),
                                       link: "https://telemost.yandex.ru/j/0000000000",
                                       emails: ["anna@example.com", "boris@example.com", "vera@example.com"])
            write(UpcomingMeetingCard(model: upcoming, extras: upcoming.meetingExtras, meeting: soon)
                    .padding(DS.Space.m)
                    .background(Palette.canvas),
                  "meeting-upcoming-warn" + suffix, dir, width: 360, dark: dark)

            // W24, V6, W19: настройки по ходу записи.
            let settings = demoModel()
            settings.meetingLive.hotkeyActive = true
            settings.settings.meetingLive.meetingVoiceProcessing = VoiceProcessingPolicy.speakers
            write(liveSettingsStage(MeetingLiveSettingsSection(model: settings)), "settings-meeting-live" + suffix, dir,
                  width: 688, dark: dark)

            // A1: выбор голоса озвучки.
            let voice = demoModel()
            voice.settings.agentVoice.announce = true
            voice.agentVoice.hooksInstalled = true
            voice.meetingLive.voices = demoVoices
            write(liveSettingsStage(AgentVoiceSection(model: voice)), "settings-agent-voice-picker" + suffix, dir,
                  width: 688, dark: dark)
        }
    }

    @MainActor
    private static func liveSettingsStage<V: View>(_ view: V) -> some View {
        view
            .padding(DS.Space.l)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Palette.canvas)
    }
}
