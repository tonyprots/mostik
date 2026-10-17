import Foundation
import MostikCore

/// Выбор источников календаря: по умолчанию ничего, старые настройки к macOS не подключаются.
func runCalendarAccountsTests() {
    let a = RemoteCalendar(id: "a", name: "Работа", primary: true)
    let b = RemoteCalendar(id: "b", name: "Личный")
    let c = RemoteCalendar(id: "c", name: "Дни рождения")

    // MARK: по умолчанию и переезд
    do {
        let fresh = MostikSettings()
        equal(fresh.calendarAccounts, CalendarAccounts(), "новые настройки — ни одного источника")
        check(!fresh.calendarAccounts.hasSelection)
        let old = try? JSONDecoder().decode(MostikSettings.self, from: Data(#"{"calendarEnabled":true}"#.utf8))
        equal(old?.calendarEnabled, true)
        equal(old?.calendarAccounts.mac, nil, "старые настройки: Календарь macOS не подключается сам")
        let broken = try? JSONDecoder().decode(MostikSettings.self, from: Data(#"{"calendarAccounts":{"google":5,"mac":[{"id":"x","name":"X","primary":false}]}}"#.utf8))
        equal(broken?.calendarAccounts.google, nil, "битое поле не роняет настройки")
        equal(broken?.calendarAccounts.mac?.map(\.id), ["x"])
        var s = MostikSettings()
        s.calendarAccounts = CalendarAccounts(google: .init(login: "me@gmail.com", calendars: [a]), yandex: .init(login: "me"), mac: [])
        let back = (try? JSONEncoder().encode(s)).flatMap { try? JSONDecoder().decode(MostikSettings.self, from: $0) }
        equal(back?.calendarAccounts, s.calendarAccounts, "туда и обратно")
        let json = String(decoding: (try? JSONEncoder().encode(s)) ?? Data(), as: UTF8.self)
        check(!json.lowercased().contains("token") && !json.lowercased().contains("password"), "секретов в настройках нет")
    }

    // MARK: выбор
    do {
        equal(CalendarAccounts.initialSelection([b, a, c]), [a], "основной")
        equal(CalendarAccounts.initialSelection([b, c]), [b], "без основного — первый")
        equal(CalendarAccounts.initialSelection([]), [])
        let renamed = RemoteCalendar(id: "b", name: "Личное")
        equal(CalendarAccounts.reconcile(selected: [a, b], available: [renamed, c]), [renamed], "пропавший снят, имя новое")
        let acc = CalendarAccounts(google: .init(login: "g", calendars: []), yandex: nil, mac: [c])
        check(acc.hasSelection)
        equal(acc.selected(.google), [])
        equal(acc.selected(.mac), [c])
        check(!CalendarAccounts(google: .init(login: "g"), yandex: .init(login: "y"), mac: []).hasSelection, "подключены, но ничего не отмечено")
    }

    // MARK: подпись
    do {
        equal(CalendarAccounts.summary(selected: [a, b], total: 3), UIText.pick("Работа, Личный", "Работа, Личный"))
        equal(CalendarAccounts.summary(selected: [a, b, c], total: 5), UIText.pick("3 из 5", "3 of 5"))
        equal(CalendarAccounts.summary(selected: [], total: 5), UIText.pick("календари не выбраны", "no calendars selected"))
    }
}
