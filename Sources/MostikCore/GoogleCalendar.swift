import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Вход в Google для установленного приложения (RFC 8252): браузер, PKCE S256, ответ на 127.0.0.1.
/// Mostik просит только `calendar.readonly` и почту — чтобы показать, какой аккаунт подключён.
/// Client ID подставляется при сборке (`MOSTIK_GOOGLE_CLIENT_ID` → Info.plist); без него Google недоступен.
public enum GoogleOAuth {
    public struct Client: Equatable, Sendable {
        public var id: String
        /// У клиента «Desktop app» Google выдаёт и секрет; он не секретен (RFC 8252 §8.5), но без него обмен не проходит.
        public var secret: String?
        public init(id: String, secret: String? = nil) { self.id = id; self.secret = secret }
    }

    public struct Tokens: Equatable, Sendable {
        public var access: String
        /// Есть только после входа; при обновлении Google его обычно не присылает — храним прежний.
        public var refresh: String?
        public var expiresAt: Date
        public var email: String?
    }

    public enum CallbackResult: Equatable, Sendable {
        case code(String)
        /// Пользователь отказал или Google вернул ошибку.
        case denied(String)
        /// Чужой `state` или запрос не на наш путь — игнорировать.
        case ignore
    }

    public static let scopes = "https://www.googleapis.com/auth/calendar.readonly openid email"
    public static let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    public static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
    public static let callbackPath = "/oauth2callback"

    /// Ключи Info.plist; незаполненная переменная сборки (`$(MOSTIK_…)`) и пустая строка — «нет клиента».
    public static func client(info: [String: Any]?) -> Client? {
        func value(_ key: String) -> String? {
            guard let v = (info?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !v.isEmpty, !v.hasPrefix("$(") else { return nil }
            return v
        }
        guard let id = value("MostikGoogleClientID") else { return nil }
        return Client(id: id, secret: value("MostikGoogleClientSecret"))
    }

    // MARK: PKCE

    static let unreserved = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// 64 знака из алфавита RFC 7636 — и для verifier, и для state.
    public static func randomToken(length: Int = 64) -> String {
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in unreserved[Int.random(in: 0..<unreserved.count, using: &rng)] })
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: шаги

    public static func redirectURI(port: UInt16) -> String { "http://127.0.0.1:\(port)\(callbackPath)" }

    public static func authURL(client: Client, redirect: String, verifier: String, state: String) -> URL {
        var c = URLComponents(url: authEndpoint, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "client_id", value: client.id),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes),
            .init(name: "code_challenge", value: challenge(for: verifier)),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            // Без offline нет refresh token; consent — чтобы он пришёл и при повторном подключении.
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        return c.url!
    }

    /// Первая строка HTTP-запроса к приёмнику: `GET /oauth2callback?code=…&state=… HTTP/1.1`.
    public static func callback(requestLine: String, state: String) -> CallbackResult {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let c = URLComponents(string: "http://127.0.0.1" + parts[1]), c.path == callbackPath else { return .ignore }
        let q = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard let got = q["state"], constantTimeEqual(got, state) else { return .ignore }
        if let error = q["error"] { return .denied(error) }
        guard let code = q["code"], !code.isEmpty else { return .denied("no_code") }
        return .code(code)
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func form(_ items: [(String, String?)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = items.compactMap { k, v in
            v.map { k + "=" + ($0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    static func tokenRequest(_ items: [(String, String?)]) -> URLRequest {
        var r = URLRequest(url: tokenEndpoint)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = form(items)
        return r
    }

    public static func exchange(code: String, verifier: String, redirect: String, client: Client,
                                transport: HTTPTransport, now: Date = Date()) async throws -> Tokens {
        let r = tokenRequest([("grant_type", "authorization_code"), ("code", code), ("code_verifier", verifier),
                              ("redirect_uri", redirect), ("client_id", client.id), ("client_secret", client.secret)])
        let tokens = try parseTokens(try await post(r, transport), now: now)
        guard tokens.refresh != nil else { throw CalendarAccountError.badResponse }
        return tokens
    }

    public static func refresh(_ refreshToken: String, client: Client, transport: HTTPTransport,
                               now: Date = Date()) async throws -> Tokens {
        let r = tokenRequest([("grant_type", "refresh_token"), ("refresh_token", refreshToken),
                              ("client_id", client.id), ("client_secret", client.secret)])
        var tokens = try parseTokens(try await post(r, transport), now: now)
        if tokens.refresh == nil { tokens.refresh = refreshToken }
        return tokens
    }

    /// Отключение: отозвать токен у Google. Ошибка не мешает удалить его локально.
    public static func revoke(_ token: String, transport: HTTPTransport) async {
        var r = URLRequest(url: revokeEndpoint)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = form([("token", token)])
        _ = try? await transport.send(r)
    }

    static func post(_ r: URLRequest, _ transport: HTTPTransport) async throws -> Data {
        let (data, response) = try await transport.send(r)
        if response.statusCode == 400 || response.statusCode == 401 {
            // invalid_grant — refresh token отозван или истёк: нужен новый вход.
            let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw error == "invalid_grant" || response.statusCode == 401 ? CalendarAccountError.unauthorized
                                                                          : CalendarAccountError.http(response.statusCode)
        }
        guard (200...299).contains(response.statusCode) else { throw CalendarAccountError.http(response.statusCode) }
        return data
    }

    static func parseTokens(_ data: Data, now: Date) throws -> Tokens {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty else { throw CalendarAccountError.badResponse }
        let expires = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return Tokens(access: access, refresh: json["refresh_token"] as? String,
                      expiresAt: now.addingTimeInterval(max(60, expires - 60)),
                      email: (json["id_token"] as? String).flatMap(email(fromIDToken:)))
    }

    /// Почта из id_token — только для подписи «подключён как …». Пришла по TLS прямо от Google, подпись не проверяем.
    static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["email"] as? String
    }
}

/// Google Calendar API v3 — только чтение: список календарей и события в окне (повторы разворачивает Google).
public enum GoogleCalendarAPI {
    public static let base = URL(string: "https://www.googleapis.com/calendar/v3/")!
    static let maxPages = 5

    static func get(_ url: URL, token: String, transport: HTTPTransport) async throws -> [String: Any] {
        var r = URLRequest(url: url)
        r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.send(r)
        switch response.statusCode {
        case 401: throw CalendarAccountError.unauthorized
        case 200...299: break
        default: throw CalendarAccountError.http(response.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CalendarAccountError.badResponse
        }
        return json
    }

    public static func calendars(token: String, transport: HTTPTransport) async throws -> [RemoteCalendar] {
        var c = URLComponents(url: base.appendingPathComponent("users/me/calendarList"), resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "minAccessRole", value: "reader"), .init(name: "maxResults", value: "250")]
        return parseCalendars(try await get(c.url!, token: token, transport: transport))
    }

    public static func parseCalendars(_ json: [String: Any]) -> [RemoteCalendar] {
        ((json["items"] as? [[String: Any]]) ?? []).compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            let name = (item["summaryOverride"] as? String) ?? (item["summary"] as? String) ?? id
            return RemoteCalendar(id: id, name: name, primary: item["primary"] as? Bool ?? false)
        }
        .sorted { $0.primary && !$1.primary }
    }

    public static func events(token: String, calendarID: String, from: Date, to: Date, owner: String?,
                              transport: HTTPTransport) async throws -> [CalendarEvent] {
        // id календаря — почта или `…@group.calendar.google.com`: кодируем как сегмент пути.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let segment = calendarID.addingPercentEncoding(withAllowedCharacters: allowed) ?? calendarID
        let iso = ISO8601DateFormatter()
        var out: [CalendarEvent] = []
        var page: String?
        for _ in 0..<maxPages {
            var c = URLComponents(string: base.absoluteString + "calendars/" + segment + "/events")!
            c.queryItems = [
                .init(name: "timeMin", value: iso.string(from: from)),
                .init(name: "timeMax", value: iso.string(from: to)),
                .init(name: "singleEvents", value: "true"),
                .init(name: "orderBy", value: "startTime"),
                .init(name: "maxResults", value: "500"),
            ] + (page.map { [.init(name: "pageToken", value: $0)] } ?? [])
            let json = try await get(c.url!, token: token, transport: transport)
            out += parseEvents(json, owner: owner, idPrefix: "google:")
            page = json["nextPageToken"] as? String
            if page == nil || out.count >= ExternalCalendar.maxEvents { break }
        }
        return out
    }

    static func date(_ value: Any?) -> Date? {
        guard let s = (value as? [String: Any])?["dateTime"] as? String else { return nil }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    public static func parseEvents(_ json: [String: Any], owner: String?, idPrefix: String) -> [CalendarEvent] {
        let ownerLower = owner?.lowercased()
        return ((json["items"] as? [[String: Any]]) ?? []).compactMap { item -> CalendarEvent? in
            if item["status"] as? String == "cancelled" { return nil }
            // Событие на весь день — `date` без `dateTime`: пропускаем, как в Календаре macOS.
            guard let id = item["id"] as? String, let start = date(item["start"]) else { return nil }
            let end = date(item["end"]) ?? start
            let people = (item["attendees"] as? [[String: Any]]) ?? []
            if people.contains(where: { ($0["self"] as? Bool == true) && $0["responseStatus"] as? String == "declined" }) {
                return nil
            }
            var all: [String] = [], others: [String] = [], emails: [String] = []
            for p in people {
                if p["resource"] as? Bool == true { continue }
                if p["responseStatus"] as? String == "declined", p["self"] as? Bool != true { continue }
                let email = p["email"] as? String
                guard let name = CalendarLogic.participantName(name: p["displayName"] as? String, url: email),
                      !all.contains(name) else { continue }
                all.append(name)
                let isOwner = p["self"] as? Bool == true || (ownerLower != nil && email?.lowercased() == ownerLower)
                if !isOwner {
                    others.append(name)
                    if let email, email.contains("@"), !emails.contains(email) { emails.append(email) }
                }
            }
            let notes = (item["description"] as? String) ?? ""
            let video = ((item["conferenceData"] as? [String: Any])?["entryPoints"] as? [[String: Any]])?
                .first { $0["entryPointType"] as? String == "video" }?["uri"] as? String
            let link = MeetingLinks.find(url: video ?? item["hangoutLink"] as? String,
                                         location: item["location"] as? String, notes: notes)
            return CalendarEvent(id: idPrefix + id, title: ((item["summary"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                 start: start, end: max(end, start), attendees: all, others: others,
                                 notes: String(notes.prefix(2000)), link: link, emails: emails)
        }
    }
}
