import Foundation
import MostikCore

/// Поддельный HTTP: ответ по методу и пути, журнал запросов. Ответы — в духе caldav.yandex.ru, данные синтетические.
final class FakeHTTP: HTTPTransport, @unchecked Sendable {
    struct Reply { var status: Int; var body: String }
    private let lock = NSLock()
    private var replies: [String: Reply] = [:]
    private(set) var log: [URLRequest] = []

    func on(_ method: String, _ path: String, _ status: Int, _ body: String) {
        lock.withLock { replies[method + " " + path] = Reply(status: status, body: body) }
    }

    func on(_ method: String, _ path: String, _ body: String) { on(method, path, 207, body) }

    var requests: [URLRequest] { lock.withLock { log } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let key = (request.httpMethod ?? "GET") + " " + (request.url?.path ?? "")
        let reply = lock.withLock { () -> Reply in
            log.append(request)
            return replies[key] ?? Reply(status: 404, body: "")
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(reply.body.utf8), response)
    }
}

final class AsyncBox<T>: @unchecked Sendable { var result: Result<T, Error>? }

/// Дождаться async-функции в синхронном раннере.
func blocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) -> Result<T, Error> {
    let done = DispatchSemaphore(value: 0)
    let box = AsyncBox<T>()
    Task {
        do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
        done.signal()
    }
    done.wait()
    return box.result!
}

func runCalDAVTests() {
    let iso = ISO8601DateFormatter()
    func d(_ s: String) -> Date { iso.date(from: s)! }
    let account = CalDAVAccount(server: CalDAVAccount.yandexServer, username: "test.user", password: "app-pass")

    func multistatus(_ inner: String) -> String {
        #"<?xml version="1.0" encoding="UTF-8"?><D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">"#
            + inner + "</D:multistatus>"
    }
    let principal = multistatus("""
    <D:response><D:href>/</D:href><D:propstat><D:prop>
    <D:current-user-principal><D:href>/principals/users/test.user%40yandex.ru/</D:href></D:current-user-principal>
    </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
    """)
    let home = multistatus("""
    <D:response><D:href>/principals/users/test.user%40yandex.ru/</D:href><D:propstat><D:prop>
    <C:calendar-home-set><D:href>/calendars/test.user%40yandex.ru/</D:href></C:calendar-home-set>
    </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
    """)
    let list = multistatus("""
    <D:response><D:href>/calendars/test.user%40yandex.ru/</D:href><D:propstat><D:prop>
      <D:resourcetype><D:collection/></D:resourcetype><D:displayname>test.user</D:displayname>
    </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
    <D:response><D:href>/calendars/test.user%40yandex.ru/events-1/</D:href><D:propstat><D:prop>
      <D:resourcetype><D:collection/><C:calendar/></D:resourcetype><D:displayname>Мои события</D:displayname>
      <C:supported-calendar-component-set><C:comp name="VEVENT"/></C:supported-calendar-component-set>
    </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
    <D:response><D:href>/calendars/test.user%40yandex.ru/todos-2/</D:href><D:propstat><D:prop>
      <D:resourcetype><D:collection/><C:calendar/></D:resourcetype><D:displayname>Дела</D:displayname>
      <C:supported-calendar-component-set><C:comp name="VTODO"/></C:supported-calendar-component-set>
    </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
    <D:response><D:href>https://caldav.yandex.ru/calendars/test.user%40yandex.ru/events-3/</D:href>
      <D:propstat><D:prop><D:resourcetype><D:collection/><C:calendar/></D:resourcetype></D:prop>
        <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
      <D:propstat><D:prop><D:displayname/></D:prop><D:status>HTTP/1.1 404 Not Found</D:status></D:propstat>
    </D:response>
    """)

    // MARK: поиск календарей
    do {
        let http = FakeHTTP()
        http.on("PROPFIND", "/", principal)
        http.on("PROPFIND", "/principals/users/test.user@yandex.ru", home)
        http.on("PROPFIND", "/calendars/test.user@yandex.ru", list)
        let result = blocking { try await CalDAV.calendars(account, transport: http) }
        let cals = (try? result.get()) ?? []
        equal(cals.map(\.name), ["Мои события", "events-3"], "только календари событий; без имени — по пути; дела и сама папка мимо")
        equal(cals.first?.primary, true, "первый — основной")
        equal(cals.first?.id, "/calendars/test.user%40yandex.ru/events-1/", "путь как в ответе, с кодированием")
        let reqs = http.requests
        equal(reqs.count, 3)
        equal(reqs.map { $0.value(forHTTPHeaderField: "Depth") ?? "" }, ["0", "0", "1"])
        let auth = "Basic " + Data("test.user:app-pass".utf8).base64EncodedString()
        check(reqs.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == auth }, "Basic с логином и паролем приложения")
        check(reqs.allSatisfy { $0.url?.host == "caldav.yandex.ru" && $0.url?.scheme == "https" })
        check(String(decoding: reqs[0].httpBody ?? Data(), as: UTF8.self).contains("current-user-principal"))
    }

    // MARK: ошибки
    do {
        let http = FakeHTTP()
        http.on("PROPFIND", "/", 401, "")
        let r = blocking { try await CalDAV.calendars(account, transport: http) }
        if case .failure(let e) = r { equal(e as? CalendarAccountError, .unauthorized, "401 — неверный пароль") } else { check(false, "401 должен падать") }

        let http2 = FakeHTTP()
        http2.on("PROPFIND", "/", 500, "")
        if case .failure(let e) = blocking({ try await CalDAV.calendars(account, transport: http2) }) {
            equal(e as? CalendarAccountError, .http(500))
        } else { check(false, "500 должен падать") }

        let http3 = FakeHTTP()
        http3.on("PROPFIND", "/", multistatus("""
        <D:response><D:href>/</D:href><D:propstat><D:prop>
        <D:current-user-principal><D:href>https://evil.example.com/steal/</D:href></D:current-user-principal>
        </D:prop></D:propstat></D:response>
        """))
        if case .failure(let e) = blocking({ try await CalDAV.calendars(account, transport: http3) }) {
            equal(e as? CalendarAccountError, .foreignHost, "чужой хост в ответе")
        } else { check(false, "чужой хост должен падать") }
        equal(http3.requests.count, 1, "на чужой хост пароль не уходит")

        let http4 = FakeHTTP()
        http4.on("PROPFIND", "/", "<не xml")
        if case .failure(let e) = blocking({ try await CalDAV.calendars(account, transport: http4) }) {
            equal(e as? CalendarAccountError, .badResponse)
        } else { check(false, "не XML должен падать") }

        equal((try? CalDAV.resolve("http://caldav.yandex.ru/x/", against: CalDAVAccount.yandexServer)) == nil, true, "http без s — нельзя")
        equal(try? CalDAV.resolve("/x/y/", against: CalDAVAccount.yandexServer).absoluteString, "https://caldav.yandex.ru/x/y/")
    }

    // MARK: события
    do {
        let ics = """
        BEGIN:VCALENDAR\r
        VERSION:2.0\r
        BEGIN:VEVENT\r
        UID:abc-1\r
        SUMMARY:Синк по продукту\r
        DTSTART;TZID=Europe/Moscow:20261016T120000\r
        DTEND;TZID=Europe/Moscow:20261016T123000\r
        ORGANIZER;CN=Тест Пользователь:mailto:test.user@yandex.ru\r
        ATTENDEE;CN=Анна Иванова;PARTSTAT=ACCEPTED:mailto:anna@example.com\r
        ATTENDEE;CN=Тест Пользователь:mailto:test.user@yandex.ru\r
        END:VEVENT\r
        END:VCALENDAR\r

        """
        let http = FakeHTTP()
        http.on("REPORT", "/calendars/test.user@yandex.ru/events-1", multistatus("""
        <D:response><D:href>/calendars/test.user%40yandex.ru/events-1/abc-1.ics</D:href><D:propstat><D:prop>
        <C:calendar-data>\(ics.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;"))</C:calendar-data>
        </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        <D:response><D:href>/calendars/test.user%40yandex.ru/events-1/empty.ics</D:href>
        <D:status>HTTP/1.1 404 Not Found</D:status></D:response>
        """))
        let from = d("2026-10-09T00:00:00Z"), to = d("2026-10-23T00:00:00Z")
        let r = blocking { try await CalDAV.events(account, calendarPath: "/calendars/test.user%40yandex.ru/events-1/",
                                                   from: from, to: to, transport: http) }
        let events = (try? r.get()) ?? []
        equal(events.count, 1)
        equal(events.first?.title, "Синк по продукту")
        equal(events.first?.start, d("2026-10-16T09:00:00Z"))
        equal(events.first?.others, ["Анна Иванова"], "владелец по логину без домена не считается собеседником")
        check(events.first?.id.hasPrefix("caldav:caldav.yandex.ru:") == true, "id с префиксом источника")
        let body = String(decoding: http.requests.first?.httpBody ?? Data(), as: UTF8.self)
        check(body.contains(#"start="20261009T000000Z""#) && body.contains(#"end="20261023T000000Z""#), "time-range в UTC")
        equal(http.requests.first?.httpMethod, "REPORT")
    }

    // MARK: CDATA и почта владельца
    do {
        let x = DAVXML.parse(Data(#"<a xmlns="DAV:"><b><![CDATA[x < y]]></b></a>"#.utf8))
        equal(x?.first(path: ["b"])?.text, "x < y")
        equal(CalDAVAccount(server: CalDAVAccount.yandexServer, username: "Me@Ya.ru", password: "").ownerEmail, "me@ya.ru")
    }
}
