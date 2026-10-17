import Foundation

/// «Записать ▾ → Записать локально» в карточке встречи: запись сразу «Только на этом Mac».
/// Путь живёт в цели приложения, поэтому страж — по исходникам: кнопка, проводка и флаг
/// в первой записи манифеста, до кадров, хуков и расшифровки.
func runRecordLocalTests() {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func source(_ path: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
    }
    let views = source("Sources/MostikUI/MeetingExtrasViews.swift")
    let folders = source("Sources/Mostik/MeetingFolderController.swift")
    let app = source("Sources/Mostik/AppController.swift")
    check(!views.isEmpty && !folders.isEmpty && !app.isEmpty, "исходники карточки и контроллеров найдены")

    check(views.contains("MostikSplitButton(title: L(\"Записать\", \"Record\")") && views.contains("extras.onRecordLocal()"),
          "«Записать ▾»: по стрелке — запись локально через onRecordLocal")
    check(views.components(separatedBy: "recordButton(").count - 1 >= 3,
          "«Записать ▾» и в предложении записи, и в напоминании")
    check(!views.contains("Всё останется на этом Mac"),
          "карточка не обещает «всё на этом Mac» для обычной записи")

    check(folders.contains("extras.onRecordLocal = {") && folders.contains("self?.startMeeting(true)"),
          "onRecordLocal начинает запись с флагом")
    check(folders.contains("patch[\"sensitive\"] = true"),
          "флаг уходит в манифест в recordingStarted, первой записью")

    check(app.contains("startMeeting(sensitive: pendingMeetingSensitive)"),
          "флаг переживает первое предупреждение о согласии")
    check(app.contains("started: started,\n                                        sensitive: sensitive)"),
          "AppController передаёт флаг в recordingStarted")
}
