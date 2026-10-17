import Foundation
import MostikCore

/// Google: PKCE, ответ на loopback, обмен и обновление токена, календари и события. Только синтетика.
func runGoogleCalendarTests() {
    @Sendable func d(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    let client = GoogleOAuth.Client(id: "123-test.apps.googleusercontent.com", secret: "test-secret")

    // MARK: клиент из Info.plist
    do {
        equal(GoogleOAuth.client(info: ["MostikGoogleClientID": "abc", "MostikGoogleClientSecret": "s"]),
              GoogleOAuth.Client(id: "abc", secret: "s"))
        equal(GoogleOAuth.client(info: ["MostikGoogleClientID": "$(MOSTIK_GOOGLE_CLIENT_ID)"]), nil, "переменная не подставлена")
        equal(GoogleOAuth.client(info: ["MostikGoogleClientID": "  "]), nil)
        equal(GoogleOAuth.client(info: nil), nil)
        equal(GoogleOAuth.client(info: ["MostikGoogleClientID": "abc", "MostikGoogleClientSecret": ""])?.secret, nil)
    }

    // MARK: PKCE и адрес входа
    do {
        // Пример из RFC 7636, приложение B.
        equal(GoogleOAuth.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let a = GoogleOAuth.randomToken(), b = GoogleOAuth.randomToken()
        check(a.count == 64 && a != b, "случайные 64 знака")
        check(a.allSatisfy { $0.isLetter || $0.isNumber || "-._~".contains($0) }, "алфавит RFC 7636")
        let redirect = GoogleOAuth.redirectURI(port: 53123)
        equal(redirect, "http://127.0.0.1:53123/oauth2callback")
        let url = GoogleOAuth.authURL(client: client, redirect: redirect, verifier: "v", state: "st")
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        equal(url.host, "accounts.google.com")
        equal(q["code_challenge_method"], "S256")
        equal(q["code_challenge"], GoogleOAuth.challenge(for: "v"))
        equal(q["redirect_uri"], redirect)
        equal(q["access_type"], "offline")
        check(q["scope"]?.contains("calendar.readonly") == true && q["scope"]?.contains("calendar.events") != true, "только чтение")
        equal(q["client_secret"], nil, "секрет в адрес не попадает")
    }

    // MARK: ответ на loopback
    do {
        typealias R = GoogleOAuth.CallbackResult
        equal(GoogleOAuth.callback(requestLine: "GET /oauth2callback?state=st&code=4%2F0abc HTTP/1.1", state: "st"), R.code("4/0abc"))
        equal(GoogleOAuth.callback(requestLine: "GET /oauth2callback?state=st&error=access_denied HTTP/1.1", state: "st"), R.denied("access_denied"))
        equal(GoogleOAuth.callback(requestLine: "GET /oauth2callback?state=other&code=x HTTP/1.1", state: "st"), R.ignore, "чужой state")
        equal(GoogleOAuth.callback(requestLine: "GET /favicon.ico HTTP/1.1", state: "st"), R.ignore)
        equal(GoogleOAuth.callback(requestLine: "POST /oauth2callback?state=st&code=x HTTP/1.1", state: "st"), R.ignore)
        equal(GoogleOAuth.callback(requestLine: "GET /oauth2callback?state=st HTTP/1.1", state: "st"), R.denied("no_code"))
    }

    // MARK: токены
    do {
        let idPayload = Data(#"{"email":"me@gmail.com","sub":"1"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        let http = FakeHTTP()
        http.on("POST", "/token", 200, #"{"access_token":"at1","refresh_token":"rt1","expires_in":3599,"id_token":"h.\#(idPayload).s"}"#)
        let now = d("2026-10-16T09:00:00Z")
        let t = try? blocking { try await GoogleOAuth.exchange(code: "c+/=", verifier: "ver", redirect: "http://127.0.0.1:1/oauth2callback",
                                                               client: client, transport: http, now: now) }.get()
        equal(t?.access, "at1")
        equal(t?.refresh, "rt1")
        equal(t?.email, "me@gmail.com", "почта из id_token")
        equal(t?.expiresAt, now.addingTimeInterval(3539), "запас минута")
        let body = String(decoding: http.requests.first?.httpBody ?? Data(), as: UTF8.self)
        check(body.contains("code=c%2B%2F%3D") && body.contains("code_verifier=ver") && body.contains("grant_type=authorization_code"),
              "форма закодирована: \(body)")

        let http2 = FakeHTTP()
        http2.on("POST", "/token", 200, #"{"access_token":"at2","expires_in":3600}"#)
        let t2 = try? blocking { try await GoogleOAuth.refresh("rt1", client: client, transport: http2, now: now) }.get()
        equal(t2?.access, "at2")
        equal(t2?.refresh, "rt1", "refresh token сохраняется прежний")

        let http3 = FakeHTTP()
        http3.on("POST", "/token", 400, #"{"error":"invalid_grant"}"#)
        if case .failure(let e) = blocking({ try await GoogleOAuth.refresh("rt1", client: client, transport: http3) }) {
            equal(e as? CalendarAccountError, .unauthorized, "отозванный доступ — войти заново")
        } else { check(false, "invalid_grant должен падать") }

        let http4 = FakeHTTP()
        http4.on("POST", "/token", 200, #"{"access_token":"at","expires_in":3600}"#)
        if case .failure(let e) = blocking({ try await GoogleOAuth.exchange(code: "c", verifier: "v", redirect: "r", client: client, transport: http4) }) {
            equal(e as? CalendarAccountError, .badResponse, "без refresh token вход бесполезен")
        } else { check(false, "вход без refresh token должен падать") }
    }

    // MARK: календари
    do {
        let http = FakeHTTP()
        http.on("GET", "/calendar/v3/users/me/calendarList", 200, """
        {"items":[{"id":"team@group.calendar.google.com","summary":"Команда"},
                  {"id":"me@gmail.com","summary":"me@gmail.com","summaryOverride":"Личный","primary":true},
                  {"summary":"без id"}]}
        """)
        let cals = (try? blocking { try await GoogleCalendarAPI.calendars(token: "at", transport: http) }.get()) ?? []
        equal(cals.map(\.name), ["Личный", "Команда"], "основной первым, своё имя важнее")
        equal(cals.first?.primary, true)
        equal(http.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer at")

        let http2 = FakeHTTP()
        http2.on("GET", "/calendar/v3/users/me/calendarList", 401, "{}")
        if case .failure(let e) = blocking({ try await GoogleCalendarAPI.calendars(token: "old", transport: http2) }) {
            equal(e as? CalendarAccountError, .unauthorized)
        } else { check(false, "401 должен падать") }
    }

    // MARK: события
    do {
        let page1 = """
        {"items":[
          {"id":"e1","status":"confirmed","summary":" Синк ","start":{"dateTime":"2026-10-16T12:00:00+03:00"},
           "end":{"dateTime":"2026-10-16T12:30:00+03:00"},"hangoutLink":"https://meet.google.com/abc-defg-hij",
           "attendees":[{"email":"me@gmail.com","self":true,"responseStatus":"accepted"},
                        {"email":"anna@example.com","displayName":"Анна","responseStatus":"accepted"},
                        {"email":"bob@example.com","responseStatus":"declined"},
                        {"email":"room@resource.calendar.google.com","displayName":"Переговорка","resource":true}]},
          {"id":"e2","status":"cancelled","start":{"dateTime":"2026-10-16T13:00:00Z"},"end":{"dateTime":"2026-10-16T14:00:00Z"}},
          {"id":"e3","summary":"Отпуск","start":{"date":"2026-10-17"},"end":{"date":"2026-10-18"}}
        ],"nextPageToken":"p2"}
        """
        let page2 = """
        {"items":[
          {"id":"e4","summary":"Отказался","start":{"dateTime":"2026-10-17T10:00:00Z"},"end":{"dateTime":"2026-10-17T11:00:00Z"},
           "attendees":[{"email":"me@gmail.com","self":true,"responseStatus":"declined"},{"email":"x@example.com"}]},
          {"id":"e5_20261018","summary":"Повтор","start":{"dateTime":"2026-10-18T10:00:00.000Z"},"end":{"dateTime":"2026-10-18T10:15:00.000Z"},
           "conferenceData":{"entryPoints":[{"entryPointType":"phone","uri":"tel:+1"},{"entryPointType":"video","uri":"https://zoom.us/j/1"}]}}
        ]}
        """
        // Подделка отвечает по пути: вторая страница — по тому же пути, поэтому подменяем ответ после первого запроса.
        final class Paged: HTTPTransport, @unchecked Sendable {
            let pages: [String]; var n = 0; var urls: [URL] = []
            init(_ pages: [String]) { self.pages = pages }
            func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
                urls.append(r.url!)
                let body = pages[min(n, pages.count - 1)]; n += 1
                return (Data(body.utf8), HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let http = Paged([page1, page2])
        let events = (try? blocking { try await GoogleCalendarAPI.events(token: "at", calendarID: "me@gmail.com",
                                                                         from: d("2026-10-09T00:00:00Z"), to: d("2026-10-23T00:00:00Z"),
                                                                         owner: "me@gmail.com", transport: http) }.get()) ?? []
        equal(events.map(\.id), ["google:e1", "google:e5_20261018"], "без отменённых, дня целиком и отклонённых мной")
        equal(events.first?.title, "Синк")
        equal(events.first?.start, d("2026-10-16T09:00:00Z"))
        equal(events.first?.attendees, ["me@gmail.com", "Анна"], "без отказавшихся и переговорок")
        equal(events.first?.others, ["Анна"])
        equal(events.first?.emails, ["anna@example.com"])
        equal(events.first?.link, "https://meet.google.com/abc-defg-hij")
        equal(events.last?.link, "https://zoom.us/j/1", "видео из conferenceData, не телефон")
        equal(events.last?.start, d("2026-10-18T10:00:00Z"), "дробные секунды")
        equal(http.urls.count, 2, "вторая страница")
        let q = URLComponents(url: http.urls[1], resolvingAgainstBaseURL: false)?.queryItems ?? []
        check(q.contains { $0.name == "pageToken" && $0.value == "p2" })
        check(q.contains { $0.name == "singleEvents" && $0.value == "true" }, "повторы разворачивает Google")
        check(http.urls[0].absoluteString.contains("/calendars/me%40gmail.com/events"), "id календаря закодирован: \(http.urls[0])")
    }
}
