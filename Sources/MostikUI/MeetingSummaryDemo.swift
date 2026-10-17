import Foundation
import MostikCore

/// Снимки сводки по шаблонам (M16, M17), протокола (W8), видов (W22), своих записей (W23),
/// рецептов (W7) и следующих шагов (W25). Встреча `m2` из `Snapshots.demoModel()`.
enum MeetingSummaryDemo {
    typealias Scene = MeetingAIDemo.Scene

    @MainActor
    static func scenes() -> [Scene] {
        var scenes: [Scene] = []
        for dark in [false, true] {
            let suffix = dark ? "-dark" : ""
            scenes.append(Scene(name: "main-meetings-summary-sections" + suffix, model: model(), height: 1700, dark: dark))

            let minutes = model()
            minutes.meetingAI.view["m2"] = "protocol"
            scenes.append(Scene(name: "main-meetings-summary-protocol" + suffix, model: minutes, height: 1300, dark: dark))

            let steps = model()
            if let result = steps.meetingAI.result(for: "m2") {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
                let started = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 11))!
                var sheet = MeetingAIModel.NextStepsSheet(
                    meeting: "m2",
                    steps: MeetingNextSteps.build(result: result, title: L("Распознавание терминов", "Recognising terms"),
                                                  started: started, meetingID: "m2", russian: L10n.isRussian, calendar: calendar))
                sheet.steps.email.to = "team@example.com"
                steps.meetingAI.nextSteps = sheet
            }
            scenes.append(Scene(name: "main-meetings-next-steps" + suffix, model: steps, height: 900, dark: dark))
        }

        let custom = model()
        custom.meetingAI.customFor = "m2"
        custom.meetingAI.view["m2"] = "exec"
        custom.meetingAI.variantPhases["m2|exec"] = .running(L("Сводка «Для руководителя»", "Summary “For the boss”"))
        scenes.append(Scene(name: "main-meetings-summary-variant-running", model: custom, height: 900))

        let tasks = model()
        if let result = tasks.meetingAI.result(for: "m2") {
            var sheet = MeetingAIModel.NextStepsSheet(
                meeting: "m2",
                steps: MeetingNextSteps.build(result: result, title: L("Распознавание терминов", "Recognising terms"),
                                              started: Date(timeIntervalSince1970: 1_791_536_400), meetingID: "m2",
                                              russian: L10n.isRussian))
            sheet.tab = .tasks
            sheet.steps.tasks[2].include = false
            tasks.meetingAI.nextSteps = sheet
        }
        scenes.append(Scene(name: "main-meetings-next-steps-tasks", model: tasks, height: 900))

        let recipe = model()
        recipe.meetingAI.recipePreview = .init(
            meeting: "m2", recipe: "followup-email", name: L("Письмо-итог от меня", "Follow-up email from me"),
            text: L("""
                    Тема: Итоги: распознавание терминов

                    Коллеги, привет!

                    Коротко по итогам. «Паракит» вместо parakeet_tdt лечится термином проекта: с выбранной папкой имя модуля попадает в подсказку. Без проекта помогает «Запомнить» в сомнениях. Лимит сомнений для агента оставили пять.

                    Кто что делает:
                    — Борис проверит на свежей сборке с папкой проекта до пятницы;
                    — опишем «Запомнить» в онбординге.

                    Если что-то упустил — поправьте.
                    """,
                    """
                    Subject: Recap: recognising terms

                    Hi all,

                    A short recap. “Parakeet” instead of parakeet_tdt is fixed by project terms: with a folder chosen, the module name goes into the hint. Without a project, Remember on a doubt helps. The agent doubt limit stays at five.

                    Who does what:
                    — Boris checks a fresh build with a project folder by Friday;
                    — we describe Remember in onboarding.

                    Tell me if I missed anything.
                    """),
            path: "/tmp/m2/recipes/followup-email.md", email: true)
        scenes.append(Scene(name: "main-meetings-recipe-email", model: recipe, height: 900))

        let sensitive = model()
        sensitive.meetingExtras.sensitive = ["m2"]
        scenes.append(Scene(name: "main-meetings-summary-sensitive", model: sensitive, height: 1700))
        return scenes
    }

    @MainActor
    static func model() -> AppModel {
        let m = MeetingAIDemo.model()
        let ai = m.meetingAI
        ai.templates = [
            MeetingTemplateInfo(id: "general", name: "Обычная встреча", nameEn: "General meeting"),
            MeetingTemplateInfo(id: "standup", name: "Стендап", nameEn: "Standup", layout: "people"),
            MeetingTemplateInfo(id: "one-on-one", name: "1:1", nameEn: "1:1", layout: "people"),
            MeetingTemplateInfo(id: "retro", name: "Ретро", nameEn: "Retro"),
            MeetingTemplateInfo(id: "client", name: "Встреча с клиентом", nameEn: "Client meeting"),
            MeetingTemplateInfo(id: "protocol", name: "Протокол", nameEn: "Minutes", layout: "protocol"),
            MeetingTemplateInfo(id: "exec", name: "Для руководителя", nameEn: "For the boss"),
            MeetingTemplateInfo(id: "decisions", name: "Только решения", nameEn: "Decisions only"),
        ]
        ai.recipes = [
            MeetingTemplateInfo(id: "followup-email", name: "Письмо-итог от меня", nameEn: "Follow-up email", output: "email"),
            MeetingTemplateInfo(id: "prd", name: "PRD", nameEn: "PRD"),
            MeetingTemplateInfo(id: "feedback", name: "Обратная связь", nameEn: "Feedback"),
            MeetingTemplateInfo(id: "feature-requests", name: "Запросы на функции", nameEn: "Feature requests"),
        ]
        ai.inputs["m2"] = .init(notesChars: 412, images: ["attachments/slide-roadmap.png"])
        guard var file = ai.files["m2"], var result = file.results[.detailed] else { return m }
        result.topic = L("Распознавание терминов и лимит сомнений", "Term recognition and the doubt limit")
        result.template = "retro"
        result.templateName = L("Ретро", "Retro")
        result.sections = [
            MeetingAISummarySection(title: L("Почему «паракит»", "Why “parakeet”"), points: [0]),
            MeetingAISummarySection(title: L("Как лечить с проектом и без", "Fixing it with and without a project"), points: [1, 2]),
        ]
        var fromNotes = MeetingAIPoint(text: L("Слайд дорожной карты: термины проекта — в ноябрьском релизе.",
                                               "Roadmap slide: project terms ship in the November release."), refs: [])
        fromNotes.fromNotes = true
        result.points = Array(result.points.prefix(3)) + [fromNotes]
        result.sections[1].points.append(3)
        result.decisions = [MeetingAIPoint(text: L("Лимит сомнений для агента — пять.", "The agent doubt limit stays at five."), refs: [4])]
        result.inputs = MeetingAIInputs(used: true, agenda: 0, notesChars: 412, images: 1)
        file.results[.detailed] = result
        file.template = "retro"
        file.templateAuto = true

        var minutes = MeetingAIResult(mode: .detailed, status: .done, overview: "", backend: "claude", model: "sonnet",
                                      seconds: 11, calls: 1, chunks: 1, coverage: 1)
        minutes.layout = "protocol"
        minutes.template = "protocol"
        minutes.agenda = [
            MeetingAIAgendaItem(
                question: L("О распознавании «паракит» вместо parakeet_tdt", "On “parakeet” instead of parakeet_tdt"),
                heard: [MeetingAIPoint(text: L("Анна — ошибка в каждой третьей диктовке.", "Anna: the error shows up in every third dictation."), refs: [0]),
                        MeetingAIPoint(text: L("Борис — лечится термином проекта.", "Boris: project terms fix it."), refs: [1])],
                decided: [MeetingAIPoint(text: L("Проверить на свежей сборке с выбранной папкой проекта.",
                                                 "Check on a fresh build with a project folder chosen."), refs: [1])]),
            MeetingAIAgendaItem(
                question: L("О лимите сомнений агента", "On the agent doubt limit"),
                heard: [MeetingAIPoint(text: L("Борис — больше пяти агент не переспрашивает.", "Boris: the agent never asks about more than five."), refs: [4])],
                decided: [MeetingAIPoint(text: L("Решили оставить пять.", "We decided to keep five."), refs: [4])]),
        ]
        minutes.agenda[1].decided[0].formOK = false
        minutes.tasks = [
            MeetingAITask(text: L("Проверить «паракит» на свежей сборке", "Check “parakeet” on a fresh build"),
                          owner: L("Анна", "Anna"), assignee: .speaker(L("Борис", "Boris")), due: L("до пятницы", "by Friday"), refs: [1]),
            MeetingAITask(text: L("Описать «Запомнить» в онбординге", "Describe Remember in onboarding"),
                          owner: nil, assignee: .group, due: nil, refs: [3]),
        ]
        minutes.tasks[1].needsOwner = true
        minutes.tasks[1].needsDue = true
        file.variants["protocol"] = minutes
        ai.files["m2"] = file
        return m
    }
}
