import SwiftUI
import MostikCore

/// Снимки встреч вокруг записи (M11–M13, W2, W9, W11, W13, W14). Данные вымышленные.
extension Snapshots {
    @MainActor
    static func renderMeetingExtras(to dir: URL) {
        let now = Date()
        let soon = UpcomingMeeting(id: "e1", title: L("Синк с командой продукта", "Product team sync"),
                                   start: now.addingTimeInterval(60), end: now.addingTimeInterval(1860),
                                   link: "https://telemost.yandex.ru/j/12345678901234",
                                   agenda: [L("Сроки релиза 2.4", "Release 2.4 dates"),
                                            L("Кто берёт диаризацию", "Who owns diarization"),
                                            L("Бюджет на мониторы", "Monitor budget")])

        // Плавающие карточки: W14, M13 (напоминание и автоостановка), M12 (нет звука).
        for dark in [false, true] {
            let prompts: [MeetingExtrasModel.Prompt] = [
                .callSuggestion(app: L("Телемосте", "Zoom")),
                .reminder(soon),
                .autoStop(deadline: now.addingTimeInterval(42)),
                .warning(title: L("Не слышно звука", "No sound"),
                         detail: L("За 10 секунд ни микрофон, ни звук звонка ничего не уловили. Проверьте устройство ввода и громкость.",
                                   "Neither the microphone nor the call audio picked anything up in 10 seconds. Check the input device and volume.")),
            ]
            let stack = VStack(spacing: 0) {
                ForEach(Array(prompts.enumerated()), id: \.offset) { _, prompt in
                    MeetingPromptView(extras: extrasModel(prompt: prompt))
                }
            }
            .padding(DS.Space.s)
            .background(Palette.canvas)
            write(stack, "meeting-prompts" + (dark ? "-dark" : ""), dir, width: 380, dark: dark)
        }

        // Вкладка «Встречи»: «Скоро» с повесткой и заметкой, сведения о встрече и метрики «только для вас».
        for dark in [false, true] {
            let model = demoModel()
            model.selectedTab = .meetings
            let extras = model.meetingExtras
            extras.upcoming = soon
            extras.prep["e1"] = L("Спросить про сроки бета-теста", "Ask about the beta dates")
            extras.links["m2"] = "https://telemost.yandex.ru/j/12345678901234"
            extras.sensitive = ["m2"]
            extras.recordingStatus["m2"] = "recovered"
            extras.metrics["m2"] = SpeakingMetrics(share: 0.34, mySeconds: 619, longestMonologue: 142, longestAt: 380, questions: 7)
            write(MainWindowView(model: model, entry: nil, meeting: "m2"), "main-meetings-extras" + (dark ? "-dark" : ""), dir,
                  width: 1080, height: 900, dark: dark)
        }

        // Запись идёт: пункты повестки — пометки в одно нажатие (W2).
        for dark in [false, true] {
            let live = liveMeetingModel()
            live.selectedTab = .meetings
            live.meetingExtras.agenda = soon.agenda
            live.meetingExtras.agendaUsed = [soon.agenda[0]]
            write(MainWindowView(model: live, entry: nil, meeting: "m0"), "main-meetings-agenda" + (dark ? "-dark" : ""), dir,
                  width: 1080, height: 760, dark: dark)
        }

        // Фрагмент (W9): выбранный отрезок и итог сохранения.
        for dark in [false, true] {
            let model = demoModel()
            let lines = Array((model.meetingTranscripts["m2"] ?? []).filter { !$0.isMark }.prefix(3))
            model.meetingExtras.clipResult = .init(meeting: "m2", folder: URL(fileURLWithPath: "/tmp/clip.md"),
                                                   message: L("Сохранено: clips/00.03-00.44.m4a + .md", "Saved: clips/00.03-00.44.m4a + .md"),
                                                   ok: true)
            let bar = ClipBar(extras: model.meetingExtras, meeting: "m2", selected: lines, onCancel: {})
                .padding(DS.Space.l)
                .background(Palette.surface)
            write(bar, "meeting-clip" + (dark ? "-dark" : ""), dir, width: 640, dark: dark)
        }

        // Настройки «Встречи» (M11, M13, W13, W14): хук включён.
        for dark in [false, true] {
            let model = demoModel()
            model.settings.calendarEnabled = true
            model.settings.meetingHook = MeetingHookSettings(enabled: true, command: "~/bin/to-obsidian.sh \"$1\"",
                                                             timeoutSeconds: 60, afterSummary: true)
            let section = MeetingSettingsSection(model: model)
                .padding(DS.Space.l)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(Palette.canvas)
            write(section, "settings-meetings" + (dark ? "-dark" : ""), dir, width: 688, dark: dark)
        }
    }

    @MainActor
    private static func extrasModel(prompt: MeetingExtrasModel.Prompt) -> MeetingExtrasModel {
        let extras = MeetingExtrasModel()
        extras.prompt = prompt
        return extras
    }
}
