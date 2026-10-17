import EventKit
import Foundation
import MostikCore

/// Календарь как источник словаря и имён (S1): отмеченные календари macOS, Google, Яндекса и внешняя
/// команда. По умолчанию ни один не подключён. Один на приложение (`shared`): у сетевых источников и
/// команды общий кеш, запросы не идут из каждого контроллера.
public final class CalendarSource: CalendarProvider, @unchecked Sendable {
    public static let shared = CalendarSource()

    public let eventKit = EventKitCalendar()
    public let google = AccountCalendar(kind: .google)
    public let yandex = AccountCalendar(kind: .yandex)
    public let command = CommandCalendar()

    public init() {}

    var providers: [CalendarProvider] { [eventKit, google, yandex, command] }

    public var isReady: Bool { providers.contains { $0.isReady } }

    /// Дубли между источниками (одна встреча в macOS и в Google) — по названию и минуте начала, остаётся первый.
    public func meetings(around now: Date, days: Int) -> [CalendarEvent] {
        providers.filter(\.isReady).reduce([]) { ExternalCalendar.merge($0, $1.meetings(around: now, days: days)) }
    }

    /// Запрос доступа к календарю macOS. Вызывать только по действию пользователя.
    public func requestAccess() async -> Bool { await eventKit.requestAccess() }
}

/// Календарь macOS через EventKit, только чтение, офлайн. Читаются только календари, отмеченные
/// в Настройках (`CalendarAccounts.mac`); не отмечено ничего — источник молчит. Доступ просим
/// только по действию пользователя.
public final class EventKitCalendar: CalendarProvider, @unchecked Sendable {
    private let store = EKEventStore()
    private let lock = NSLock()
    private var selected: Set<String> = []

    public init() {}

    /// Отмеченные `calendarIdentifier`; пусто — выключено.
    public func select(_ ids: [String]) { lock.withLock { selected = Set(ids) } }

    /// Все календари событий на этом Mac — для окна выбора. Основной — календарь для новых событий.
    public func calendars() -> [RemoteCalendar] {
        guard Self.authorized else { return [] }
        store.refreshSourcesIfNecessary()
        let main = store.defaultCalendarForNewEvents?.calendarIdentifier
        return store.calendars(for: .event)
            .sorted { ($0.source.title, $0.title) < ($1.source.title, $1.title) }
            .map { RemoteCalendar(id: $0.calendarIdentifier, name: $0.title + " — " + $0.source.title,
                                  primary: $0.calendarIdentifier == main) }
    }

    public static var authorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    public var isReady: Bool { Self.authorized && lock.withLock { !selected.isEmpty } }

    /// Запрос полного доступа (`NSCalendarsFullAccessUsageDescription`). Вызывать только по действию пользователя.
    public func requestAccess() async -> Bool {
        if Self.authorized { return true }
        // Уже отказано — системный запрос молчит, поэтому сразу панель «Календари».
        if EKEventStore.authorizationStatus(for: .event) != .notDetermined {
            Permissions.openSettings("Privacy_Calendars")
            return false
        }
        do { return try await store.requestFullAccessToEvents() } catch { return false }
    }

    public func meetings(around now: Date, days: Int) -> [CalendarEvent] {
        let ids = lock.withLock { selected }
        guard Self.authorized, !ids.isEmpty else { return [] }
        // Список календарей мог измениться с прошлого раза (добавили аккаунт).
        store.refreshSourcesIfNecessary()
        let calendars = store.calendars(for: .event).filter { ids.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        let span = TimeInterval(days) * 86_400
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-span),
                                                 end: now.addingTimeInterval(span), calendars: calendars)
        let events = store.events(matching: predicate).compactMap(Self.convert)
        return CalendarLogic.meetings(events)
    }

    private static func convert(_ event: EKEvent) -> CalendarEvent? {
        guard !event.isAllDay, let start = event.startDate, let end = event.endDate else { return nil }
        var all: [String] = []
        var others: [String] = []
        var emails: [String] = []
        let organizer = event.organizer
        var participants = event.attendees ?? []
        // Организатор не всегда есть среди приглашённых.
        if let organizer, !participants.contains(where: { $0.url == organizer.url }) { participants.insert(organizer, at: 0) }
        for p in participants where p.participantType != .room && p.participantType != .resource {
            guard let name = CalendarLogic.participantName(name: p.name, url: p.url.absoluteString),
                  !all.contains(name) else { continue }
            all.append(name)
            if !p.isCurrentUser { others.append(name) }
            // Почта — для черновика предупреждения о записи (W20); у комнат и ресурсов её нет.
            if !p.isCurrentUser, p.url.scheme?.lowercased() == "mailto" {
                let address = String(p.url.absoluteString.dropFirst("mailto:".count)).removingPercentEncoding ?? ""
                if address.contains("@"), !emails.contains(address) { emails.append(address) }
            }
        }
        let id = event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? UUID().uuidString
        let occurrence = id + "@" + String(Int(start.timeIntervalSince1970))
        // Ссылка на звонок (M13): поле URL, место, описание — в описании только известные ВКС.
        let link = MeetingLinks.find(url: event.url?.absoluteString, location: event.location, notes: event.notes)
        return CalendarEvent(id: occurrence, title: event.title ?? "", start: start, end: end,
                             attendees: all, others: others, notes: String((event.notes ?? "").prefix(2000)), link: link,
                             emails: emails)
    }
}

/// Внешний календарь — команда (docs/external-calendar.md). Синхронные вызовы читают кеш и не ждут
/// процесса: устаревший кеш (старше `ExternalCalendar.refreshInterval`) обновляется в фоне,
/// а `onUpdate` сообщает о новом наборе или ошибке. Ошибка не стирает прежние события.
public final class CommandCalendar: CalendarProvider, @unchecked Sendable {
    public enum Status: Equatable, Sendable {
        case off
        case loading
        case ok(events: Int, at: Date)
        case failed(String)
    }

    /// Новый статус после запуска — на главной очереди.
    public var onUpdate: (Status) -> Void = { _ in }

    private let lock = NSLock()
    private var path: String?
    private var events: [CalendarEvent] = []
    private var fetchedAt: Date?
    private var running = false
    private var generation = 0

    public init() {}

    public var isReady: Bool { lock.withLock { path != nil } }

    /// Подтверждённый путь к команде (`CalendarCommandTrust`); nil — выключено. Смена пути сбрасывает кеш.
    public func setPath(_ newPath: String?) {
        let changed: Bool = lock.withLock {
            guard path != newPath else { return false }
            path = newPath
            events = []
            fetchedAt = nil
            generation += 1
            return true
        }
        guard changed else { return }
        if newPath == nil { report(.off) } else { refresh() }
    }

    public func meetings(around now: Date, days: Int) -> [CalendarEvent] {
        let (cached, stale) = lock.withLock { () -> ([CalendarEvent], Bool) in
            guard path != nil else { return ([], false) }
            let stale = fetchedAt.map { Date().timeIntervalSince($0) > ExternalCalendar.refreshInterval } ?? true
            return (events, stale)
        }
        if stale { refresh() }
        return ExternalCalendar.window(cached, around: now, days: days)
    }

    /// Запустить команду сейчас (кнопка «Обновить», смена пути). Второй запуск поверх идущего не начинается.
    public func refresh() {
        let job: (String, Int)? = lock.withLock {
            guard let path, !running else { return nil }
            running = true
            return (path, generation)
        }
        guard let (path, gen) = job else { return }
        report(.loading)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = ExternalCalendar.run(path: path, now: Date())
            self?.finish(result, generation: gen)
        }
    }

    private func finish(_ result: Result<[CalendarEvent], ExternalCalendar.RunError>, generation gen: Int) {
        let status: Status? = lock.withLock {
            running = false
            guard gen == generation else { return nil }  // путь сменился, пока шёл запуск
            fetchedAt = Date()
            switch result {
            case .success(let list):
                events = list
                return .ok(events: list.count, at: fetchedAt!)
            case .failure(let error):
                return .failed(error.message)
            }
        }
        if let status { report(status) }
    }

    private func report(_ status: Status) {
        DispatchQueue.main.async { [weak self] in self?.onUpdate(status) }
    }

}
