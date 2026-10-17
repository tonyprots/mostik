import Foundation
import MostikCore

/// запуск из `.dmg` и транслоцированной копии распознаётся, остальное — нет.
func runAppLocationTests() {
    equal(AppLocation.problem(bundlePath: "/Volumes/Mostik/Mostik.app"), .diskImage)
    equal(AppLocation.problem(bundlePath: "/private/var/folders/x1/abc/T/AppTranslocation/1F2E/d/Mostik.app"), .translocated)
    equal(AppLocation.problem(bundlePath: "/Applications/Mostik.app"), nil)
    equal(AppLocation.problem(bundlePath: "/Users/someone/Applications/Mostik.app"), nil)
    equal(AppLocation.problem(bundlePath: "/Users/someone/code/mostik/.build/debug"), nil, "отладочная сборка — без вопроса")
    equal(AppLocation.problem(bundlePath: "/Volumes/Work/code/.build/debug"), nil, "не .app — не спрашиваем")
    equal(AppLocation.destination(bundleName: "Mostik.app"), "/Applications/Mostik.app")
    for russian in [true, false] {
        for problem in [AppLocation.Problem.diskImage, .translocated] {
            check(!AppLocation.message(problem, russian: russian).isEmpty)
        }
        check(AppLocation.title(russian: russian).contains("Mostik"))
        check(!AppLocation.manualHint(russian: russian).isEmpty)
    }
}
