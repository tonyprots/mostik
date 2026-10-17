import Foundation
import MostikCore

/// Демо-данные ИИ встреч (M5–M7) для снимков: встреча `m2` из `Snapshots.demoModel()`.
/// Реплики там: 0 — Анна, 1 — Борис, 2 — Анна, 3 — Вера, 4 — Борис; пометки на 0:18 и 1:00.
enum MeetingAIDemo {
    struct Scene {
        let name: String
        let model: AppModel
        let height: CGFloat
        var dark = false
    }

    @MainActor
    static func scenes() -> [Scene] {
        var scenes: [Scene] = []
        for dark in [false, true] {
            scenes.append(Scene(name: "main-meetings-ai" + (dark ? "-dark" : ""), model: model(), height: 980, dark: dark))  // П9-B: сводка без расшифровки ниже — короче
        }

        // П9-B: разделы готовой встречи — «Задачи» и «Расшифровка».
        for dark in [false, true] {
            let tasks = model()
            tasks.meetingAI.section["m2"] = .tasks
            scenes.append(Scene(name: "main-meetings-tasks" + (dark ? "-dark" : ""), model: tasks, height: 760, dark: dark))
            let transcript = model()
            transcript.meetingAI.section["m2"] = .transcript
            scenes.append(Scene(name: "main-meetings-transcript" + (dark ? "-dark" : ""), model: transcript, height: 1000, dark: dark))
        }

        let brief = model()
        brief.meetingAI.modes["m2"] = .brief
        // Пометку поправили после обработки — связь с расшифровкой разорвана.
        brief.meetingAI.marks["m2"]?[1].text = L("Лимит сомнений пять, пересмотреть в ноябре", "Doubt limit five, revisit in November")
        scenes.append(Scene(name: "main-meetings-ai-brief", model: brief, height: 1000))

        let empty = model(result: false)
        scenes.append(Scene(name: "main-meetings-ai-empty", model: empty, height: 760))

        let running = model(result: false)
        running.meetingAI.phases["m2"] = .running(L("Сводка: часть 2 из 4", "Summary: part 2 of 4"))
        scenes.append(Scene(name: "main-meetings-ai-running", model: running, height: 760))

        let failed = model(result: false)
        failed.meetingAI.files["m2"] = MeetingAIFile(lastMode: .detailed, results: [
            .detailed: MeetingAIResult(mode: .detailed, status: .failed,
                                       error: L("Нет ответа за 180 с.", "No answer in 180 s.")),
        ])
        scenes.append(Scene(name: "main-meetings-ai-failed", model: failed, height: 760))

        let consent = model(result: false)
        consent.settings.meetingAIConsent = false
        consent.meetingAI.consentFor = "m2"
        scenes.append(Scene(name: "main-meetings-ai-consent", model: consent, height: 760))

        let noBackend = model(result: false)
        noBackend.settings.polish.backend = .off
        scenes.append(Scene(name: "main-meetings-ai-no-backend", model: noBackend, height: 760))
        // Шаблоны, протокол, виды сводки, рецепты, следующие шаги — MeetingSummaryDemo.swift.
        scenes += MeetingSummaryDemo.scenes()
        return scenes
    }

    @MainActor
    static func model(result: Bool = true) -> AppModel {
        let m = Snapshots.demoModel()
        m.selectedTab = .meetings
        m.settings.polish.backend = .claude
        m.settings.polish.cloudConsent = true
        m.settings.meetingAIConsent = true
        m.settings.meetingAICloudConsent = true
        let marks = [
            MeetingAIMark(at: 18, text: L("Проверить «паракит» на свежей сборке", "Check “parakeet” on a fresh build")),
            MeetingAIMark(at: 60, text: L("Решили: лимит сомнений пять", "Decided: doubt limit stays at five")),
        ]
        m.meetingAI.marks["m2"] = marks
        if result {
            m.meetingAI.files["m2"] = MeetingAIFile(lastMode: .detailed, results: [
                .detailed: detailed(marks), .brief: brief(marks),
            ])
        }
        return m
    }

    static func detailed(_ marks: [MeetingAIMark]) -> MeetingAIResult {
        let anna = L("Анна", "Anna"), boris = L("Борис", "Boris"), vera = L("Вера", "Vera")
        return MeetingAIResult(
            mode: .detailed, status: .done,
            overview: L("Разобрали, почему parakeet_tdt распознаётся как «паракит» и как это лечить с проектом и без него. Лимит сомнений для агента оставили прежним — пять.",
                        "We went over why parakeet_tdt comes out as “parakeet” and how to fix it with and without a project. The agent doubt limit stays at five."),
            points: [
                MeetingAIPoint(text: L("parakeet_tdt распознаётся как «паракит» примерно в каждой третьей диктовке.",
                                       "parakeet_tdt comes out as “parakeet” in about every third dictation."), refs: [0]),
                MeetingAIPoint(text: L("С выбранной папкой проекта имя модуля попадает в подсказку движку — это и лечит ошибку.",
                                       "With a project folder chosen, the module name goes into the engine hint, which fixes it."), refs: [1]),
                MeetingAIPoint(text: L("Без проекта помогает «Запомнить» в сомнениях: одна правка — и слово в личном словаре.",
                                       "Without a project, Remember on a doubt helps: one fix and the word is in the personal glossary."), refs: [2, 3]),
                MeetingAIPoint(text: L("Решили: лимит сомнений для агента — пять, больше он всё равно не переспросит.",
                                       "Decided: the agent doubt limit is five; it won’t ask about more anyway."), refs: [4]),
            ],
            notes: [
                MeetingAINote(markIndex: 0, at: marks[0].at, mark: marks[0].text,
                              text: L("Анна: «паракит» вместо parakeet_tdt в каждой третьей диктовке. Борис: лечится термином проекта — проверить на свежей сборке с выбранной папкой.",
                                      "Anna: “parakeet” instead of parakeet_tdt in every third dictation. Boris: project terms fix it — check on a fresh build with a folder chosen."),
                              refs: [0, 1]),
                MeetingAINote(markIndex: 1, at: marks[1].at, mark: marks[1].text,
                              text: L("Борис предложил оставить агенту пять сомнений: больше он не переспрашивает. Возражений не было.",
                                      "Boris proposed keeping five doubts for the agent, since it never asks about more. No objections."),
                              refs: [4]),
            ],
            tasks: [
                MeetingAITask(text: L("Проверить «паракит» на свежей сборке с выбранной папкой проекта",
                                      "Check “parakeet” on a fresh build with a project folder chosen"),
                              owner: anna, assignee: .speaker(boris), due: L("до пятницы", "by Friday"), refs: [1]),
                MeetingAITask(text: L("Описать «Запомнить» в онбординге", "Describe Remember in onboarding"),
                              owner: vera, assignee: .group, due: nil, refs: [3], done: true),
                MeetingAITask(text: L("Собрать статистику переспросов агента", "Collect stats on agent follow-up questions"),
                              owner: anna, assignee: .none, due: nil, refs: [2, 4]),
            ],
            backend: "claude", model: "sonnet", seconds: 14, calls: 1, chunks: 1, coverage: 1)
    }

    static func brief(_ marks: [MeetingAIMark]) -> MeetingAIResult {
        var result = detailed(marks)
        result.mode = .brief
        result.overview = L("«Паракит» лечится термином проекта или «Запомнить»; лимит сомнений — пять.",
                            "“Parakeet” is fixed by project terms or Remember; the doubt limit stays at five.")
        result.points = Array(result.points.prefix(3))
        result.notes[0].text = L("Проверить на свежей сборке с папкой проекта.", "Check on a fresh build with a project folder.")
        result.notes[1].text = L("Пять сомнений, больше агент не переспрашивает.", "Five doubts; the agent asks about no more.")
        result.seconds = 10
        return result
    }
}
