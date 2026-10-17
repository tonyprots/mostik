import SwiftUI
import MostikCore

/// Снимки П7: подсказка во время встречи (M9), вопросы по ходу и журнал (M19), кадры окна звонка (W26),
/// согласие на кадры перед стартом и в пилюле, настройки. Люди, документы и разговоры вымышленные.
extension Snapshots {
    static var demoQuestions: [MeetingQuestion] {
        [MeetingQuestion(id: "q1", at: 431, track: "system", text: L("Сколько у нас уходит на лицензии в месяц?", "How much do we spend on monitors a month?"),
                         status: .answered, layer: "judge", answer: L("Около 2100 долларов за штуку.", "About 2,100 dollars each.")),
         MeetingQuestion(id: "q2", at: 612, track: "mic", text: L("Кто возьмёт перенос индекса?", "Who takes the index migration?"),
                         status: .unanswered),
         MeetingQuestion(id: "q3", at: 703, track: "system", text: L("А что если держать модель голосов тёплой?", "What if we keep the voice model warm?"),
                         status: .pending, layer: "judge")]
    }

    static var demoHint: MeetingHint {
        MeetingHint(id: "q3", question: L("А что если держать модель голосов тёплой?", "What if we keep the voice model warm?"),
                    snippet: L("Тёплая модель голосов держит 1,2 ГБ памяти и убирает секунду на старте каждой встречи; решили включать её только на время записи.",
                               "A warm voice model holds 1.2 GB and removes a second at the start of each meeting; we decided to keep it warm only while recording."),
                    kind: .source, title: L("notes/диаризация.md · Задержки", "notes/diarization.md · Latency"),
                    path: L("/Users/demo/notes/диаризация.md", "/Users/demo/notes/diarization.md"), line: 14,
                    more: [L("Синк с командой движка", "Engine team sync"), L("SpeakerCache — speakers.py:42", "SpeakerCache — speakers.py:42")])
    }

    @MainActor
    static func renderMeetingAssist(to dir: URL) {
        for dark in [false, true] {
            let suffix = dark ? "-dark" : ""

            // M9, M19, W26: идёт запись — подсказка, кадры, вопросы по ходу.
            let live = liveMeetingModel()
            live.selectedTab = .meetings
            live.settings.meetingAssist.hints = true
            live.meetingAssist.questions = demoQuestions
            live.meetingAssist.hint = demoHint
            live.meetingAssist.framesConsent = true
            live.meetingAssist.framesState = .watching
            live.meetingAssist.framesCount = 3
            write(MainWindowView(model: live, entry: nil, meeting: "m0"), "main-meetings-assist" + suffix, dir,
                  width: 1080, height: 1020, dark: dark)

            // Карточка подсказки отдельно, ответ локальной модели.
            var answered = demoHint
            answered.answer = L("Держать тёплой стоит только на время записи: это 1,2 ГБ памяти и минус секунда на старте [1].",
                                "Keep it warm only while recording: 1.2 GB of memory and a second saved at start [1].")
            let card = liveMeetingModel()
            write(HintCard(assist: card.meetingAssist, hint: answered)
                    .padding(DS.Space.m)
                    .background(Palette.canvas),
                  "meeting-hint-card" + suffix, dir, width: 520, dark: dark)

            // W26: нет разрешения «Запись экрана» — объяснение и ссылки, без запроса.
            let blocked = liveMeetingModel()
            blocked.meetingAssist.framesConsent = true
            blocked.meetingAssist.framesState = .blocked(.noPermission)
            write(FramesStatusRow(assist: blocked.meetingAssist)
                    .padding(DS.Space.m)
                    .background(Palette.canvas),
                  "meeting-frames-no-permission" + suffix, dir, width: 640, dark: dark)

            // M19: журнал готовой встречи.
            let done = demoModel()
            done.selectedTab = .meetings
            done.meetingAssist.journals["m2"] = demoQuestions.map { item in
                var copy = item
                if copy.status == .pending { copy.status = .answered; copy.answeredBy = L("Я", "Me") }
                if copy.status == .answered && copy.answeredBy == nil { copy.answeredBy = L("Борис", "Boris") }
                return copy
            }
            write(QuestionsList(title: L("Вопросы встречи", "Questions"), items: done.meetingAssist.journals["m2"] ?? [], live: false)
                    .padding(DS.Space.m)
                    .background(Palette.canvas),
                  "meeting-questions-journal" + suffix, dir, width: 640, dark: dark)

            // D1–D4: слайды включены на эту запись, звук по умолчанию не хранится.
            let options = demoModel()
            options.selectedTab = .meetings
            options.settings.meetingLive.textOnlyDefault = true
            options.meetingAssist.framesConsent = true
            write(MainWindowView(model: options, entry: nil, meeting: "m2"), "main-meetings-record-options" + suffix, dir,
                  width: 1080, height: 760, dark: dark)

            // Настройки.
            let settings = demoModel()
            write(MeetingAssistSettingsSection(model: settings)
                    .padding(DS.Space.l)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(Palette.canvas),
                  "settings-meeting-assist" + suffix, dir, width: 688, dark: dark)
        }
    }
}
