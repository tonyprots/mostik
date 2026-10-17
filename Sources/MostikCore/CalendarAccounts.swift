import Foundation

/// Какие календари подключены и какие из них отмечены. По умолчанию — ничего: ни Google, ни Яндекс,
/// ни Календарь macOS не читаются, пока пользователь не выберет. Секреты (refresh token Google,
/// пароль приложения Яндекса) здесь не хранятся — только в связке ключей.
public struct CalendarAccounts: Codable, Equatable, Sendable {
    public struct Account: Codable, Equatable, Sendable {
        /// Почта Google или логин Яндекса — для подписи в Настройках и чтобы не считать владельца собеседником.
        public var login: String
        /// Отмеченные календари. Пусто — аккаунт подключён, но ничего не читается.
        public var calendars: [RemoteCalendar]

        public init(login: String, calendars: [RemoteCalendar] = []) {
            self.login = login; self.calendars = calendars
        }
    }

    public var google: Account?
    public var yandex: Account?
    /// Отмеченные календари macOS (`EKCalendar.calendarIdentifier`). nil — Календарь macOS не подключён.
    /// Старые настройки (`calendarEnabled` без этого поля) к macOS не подключаются: выбор делает пользователь.
    public var mac: [RemoteCalendar]?

    public init(google: Account? = nil, yandex: Account? = nil, mac: [RemoteCalendar]? = nil) {
        self.google = google; self.yandex = yandex; self.mac = mac
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        google = try? c.decodeIfPresent(Account.self, forKey: .google)
        yandex = try? c.decodeIfPresent(Account.self, forKey: .yandex)
        mac = try? c.decodeIfPresent([RemoteCalendar].self, forKey: .mac)
    }

    public enum Kind: String, CaseIterable, Sendable { case google, yandex, mac }

    public func selected(_ kind: Kind) -> [RemoteCalendar] {
        switch kind {
        case .google: google?.calendars ?? []
        case .yandex: yandex?.calendars ?? []
        case .mac: mac ?? []
        }
    }

    /// Хоть один календарь отмечен — есть что читать.
    public var hasSelection: Bool { Kind.allCases.contains { !selected($0).isEmpty } }

    /// Первое подключение: отмечаем основной календарь, а если сервер его не назвал — первый.
    public static func initialSelection(_ all: [RemoteCalendar]) -> [RemoteCalendar] {
        if let primary = all.first(where: \.primary) { return [primary] }
        return all.first.map { [$0] } ?? []
    }

    /// Новый список с сервера: отмеченные остаются отмеченными (с новым именем), пропавшие снимаются.
    public static func reconcile(selected: [RemoteCalendar], available: [RemoteCalendar]) -> [RemoteCalendar] {
        let ids = Set(selected.map(\.id))
        return available.filter { ids.contains($0.id) }
    }

    /// Строка статуса под источником: «Работа, Личный» или «2 из 5».
    public static func summary(selected: [RemoteCalendar], total: Int?) -> String {
        if selected.isEmpty { return UIText.pick("календари не выбраны", "no calendars selected") }
        if selected.count <= 2 { return selected.map(\.name).joined(separator: ", ") }
        if let total { return UIText.pick("\(selected.count) из \(total)", "\(selected.count) of \(total)") }
        return UIText.pick("календарей: \(selected.count)", "\(selected.count) calendars")
    }
}
