import Foundation
import MostikCore

/// Автозапуск при входе: умолчание, чтение старых настроек, что делать с объектом входа и строка «Проверки».
func runLaunchAtLoginTests() {
    // Умолчание: включено, но до конца онбординга объект входа не трогаем.
    let fresh = MostikSettings()
    check(fresh.launchAtLogin, "автозапуск включён по умолчанию")
    check(!LaunchAtLogin.wanted(fresh), "до конца онбординга автозапуск не включается")
    var done = fresh; done.onboarded = true
    check(LaunchAtLogin.wanted(done), "онбординг пройден — автозапуск нужен")
    done.launchAtLogin = false
    check(!LaunchAtLogin.wanted(done), "галочку сняли — не нужен")

    // Миграция: у прошедших онбординг поля в файле нет — значит, включено.
    let old = MostikSettings.decode(Data(#"{"schemaVersion":1,"onboarded":true,"language":"ru"}"#.utf8))
    check(old?.launchAtLogin == true, "старый settings.json без поля — автозапуск включён")
    check(old.map(LaunchAtLogin.wanted) == true, "…и нужен сразу, без повторного онбординга")
    let off = MostikSettings.decode(Data(#"{"onboarded":true,"launchAtLogin":false}"#.utf8))
    check(off?.launchAtLogin == false, "выключенный автозапуск читается из файла")
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mostik-login-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    var saved = MostikSettings(); saved.onboarded = true; saved.launchAtLogin = false
    try? saved.save(to: url)
    check(MostikSettings.load(from: url).launchAtLogin == false, "выключенный автозапуск переживает сохранение")

    // Что делать с объектом входа.
    let table: [(Bool, LaunchAtLogin.State, LaunchAtLogin.Action?)] = [
        (true, .notRegistered, .register), (true, .notFound, .register),
        (true, .enabled, nil), (true, .requiresApproval, nil), (true, .unavailable, nil),
        (false, .enabled, .unregister), (false, .requiresApproval, .unregister),
        (false, .notRegistered, nil), (false, .notFound, nil), (false, .unavailable, nil),
    ]
    for (wanted, state, action) in table {
        equal(LaunchAtLogin.action(wanted: wanted, state: state), action, "wanted=\(wanted) \(state)")
    }

    // «Проверка»: ошибка регистрации видна и ведёт в Объекты входа.
    func row(_ facts: LoginItemFacts?) -> DoctorCheck? {
        var f = DoctorFacts(); f.loginItem = facts
        return Doctor.evaluate(f, russian: true).first { $0.kind == .loginItem }
    }
    check(row(nil) == nil, "не проверяли — строки нет")
    let failed = row(.init(wanted: true, state: .notRegistered, error: "Operation not permitted"))
    equal(failed?.status, .warning, "ошибка регистрации — предупреждение, а не тишина")
    check(failed?.detail.contains("Operation not permitted") == true, "текст ошибки в строке")
    equal(failed?.fix, .openLoginItems, "кнопка ведёт в Объекты входа")
    equal(row(.init(wanted: true, state: .requiresApproval))?.status, .warning, "macOS ждёт разрешения — предупреждение")
    equal(row(.init(wanted: true, state: .requiresApproval))?.fix, .openLoginItems)
    equal(row(.init(wanted: true, state: .enabled))?.status, .ok)
    equal(row(.init(wanted: false, state: .notRegistered, error: nil))?.status, .ok, "выключено — в порядке")
    equal(row(.init(wanted: true, state: .unavailable))?.status, .unknown, "swift run — не проверено")
    check(Doctor.evaluate({ var f = DoctorFacts(); f.loginItem = .init(wanted: true, state: .enabled); return f }(), russian: false)
            .first { $0.kind == .loginItem }?.detail == "Mostik opens at login.", "строка по-английски")
}
