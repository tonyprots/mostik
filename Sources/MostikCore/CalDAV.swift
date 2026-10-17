import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP для календарей. В приложении — URLSession, в тестах — подделка с записанными ответами.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// URLSession без кеша и cookie: ответы календаря не оседают на диске, сессии сервера не копятся.
public struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    public init(timeout: TimeInterval = 20) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 3
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CalendarAccountError.badResponse }
        return (data, http)
    }
}

/// Календарь внутри аккаунта (Google, Яндекс, macOS): его можно отметить в Настройках.
public struct RemoteCalendar: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// Google — id календаря; CalDAV — путь коллекции; macOS — `calendarIdentifier`.
    public var id: String
    public var name: String
    /// Основной календарь аккаунта: его отмечаем при первом подключении.
    public var primary: Bool

    public init(id: String, name: String, primary: Bool = false) {
        self.id = id; self.name = name; self.primary = primary
    }
}

public enum CalendarAccountError: Error, Equatable, Sendable {
    /// Логин, пароль или токен не приняты.
    case unauthorized
    case http(Int)
    case badResponse
    /// Сервер прислал ссылку на другой хост или не https — туда пароль не отправляем.
    case foreignHost
    case notConfigured

    public var message: String {
        switch self {
        case .unauthorized: UIText.pick("вход не принят — подключите заново", "sign-in rejected — reconnect")
        case .http(let code): UIText.pick("сервер ответил \(code)", "server returned \(code)")
        case .badResponse: UIText.pick("непонятный ответ сервера", "unexpected server response")
        case .foreignHost: UIText.pick("сервер отправил на чужой адрес", "server pointed to a foreign address")
        case .notConfigured: UIText.pick("в этой сборке не настроено", "not configured in this build")
        }
    }
}

/// CalDAV (RFC 4791) — только чтение: найти календари аккаунта и взять события в окне.
/// Яндекс Календарь: `https://caldav.yandex.ru`, логин и пароль приложения (id.yandex.ru → Безопасность →
/// Пароли приложений → Календарь CalDAV).
public struct CalDAVAccount: Equatable, Sendable {
    public var server: URL
    public var username: String
    public var password: String

    public init(server: URL, username: String, password: String) {
        self.server = server; self.username = username; self.password = password
    }

    public static let yandexServer = URL(string: "https://caldav.yandex.ru/")!

    /// Почта владельца — чтобы не считать его собеседником. Логин Яндекса без домена — `@yandex.ru`.
    public var ownerEmail: String {
        username.contains("@") ? username.lowercased() : username.lowercased() + "@yandex.ru"
    }
}

public enum CalDAV {
    static let maxResponseBytes = 20_000_000

    // MARK: запросы

    static let principalBody = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:"><d:prop><d:current-user-principal/></d:prop></d:propfind>
    """

    static let homeBody = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><c:calendar-home-set/></d:prop></d:propfind>
    """

    static let listBody = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
    <d:prop><d:resourcetype/><d:displayname/><c:supported-calendar-component-set/></d:prop></d:propfind>
    """

    static func queryBody(from: Date, to: Date) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
        <d:prop><c:calendar-data/></d:prop>
        <c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT">
        <c:time-range start="\(stamp(from))" end="\(stamp(to))"/>
        </c:comp-filter></c:comp-filter></c:filter>
        </c:calendar-query>
        """
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    static func request(_ method: String, _ url: URL, depth: String, body: String, account: CalDAVAccount) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue(depth, forHTTPHeaderField: "Depth")
        r.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let token = Data((account.username + ":" + account.password).utf8).base64EncodedString()
        r.setValue("Basic " + token, forHTTPHeaderField: "Authorization")
        r.httpBody = Data(body.utf8)
        return r
    }

    /// Ссылка из ответа — только https и только тот же хост: пароль не уходит туда, куда указал чужой ответ.
    public static func resolve(_ href: String, against base: URL) throws -> URL {
        guard let url = URL(string: href, relativeTo: base)?.absoluteURL,
              url.scheme?.lowercased() == "https", url.host?.lowercased() == base.host?.lowercased()
        else { throw CalendarAccountError.foreignHost }
        return url
    }

    static func send(_ r: URLRequest, _ transport: HTTPTransport) async throws -> Data {
        guard r.url?.scheme?.lowercased() == "https" else { throw CalendarAccountError.foreignHost }
        let (data, response) = try await transport.send(r)
        switch response.statusCode {
        case 401, 403: throw CalendarAccountError.unauthorized
        case 200...299: break
        default: throw CalendarAccountError.http(response.statusCode)
        }
        guard data.count <= maxResponseBytes else { throw CalendarAccountError.badResponse }
        return data
    }

    // MARK: поток

    /// Найти календари аккаунта с событиями (без задач и напоминаний). Ошибка входа — `.unauthorized`.
    public static func calendars(_ account: CalDAVAccount, transport: HTTPTransport) async throws -> [RemoteCalendar] {
        let base = account.server
        let principalXML = try await send(request("PROPFIND", base, depth: "0", body: principalBody, account: account), transport)
        guard let principalHref = DAVXML.parse(principalXML)?.first(path: ["response", "propstat", "prop", "current-user-principal", "href"])?.text
        else { throw CalendarAccountError.badResponse }
        let principal = try resolve(principalHref, against: base)
        let homeXML = try await send(request("PROPFIND", principal, depth: "0", body: homeBody, account: account), transport)
        guard let homeHref = DAVXML.parse(homeXML)?.first(path: ["response", "propstat", "prop", "calendar-home-set", "href"])?.text
        else { throw CalendarAccountError.badResponse }
        let home = try resolve(homeHref, against: base)
        let listXML = try await send(request("PROPFIND", home, depth: "1", body: listBody, account: account), transport)
        guard let root = DAVXML.parse(listXML) else { throw CalendarAccountError.badResponse }
        var out: [RemoteCalendar] = []
        for response in root.children(named: "response") {
            guard let href = response.first(path: ["href"])?.text else { continue }
            let props = response.children(named: "propstat")
                .filter { ($0.first(path: ["status"])?.text ?? "200").contains(" 200 ") || $0.first(path: ["status"]) == nil }
                .compactMap { $0.first(path: ["prop"]) }
            guard props.contains(where: { $0.first(path: ["resourcetype", "calendar"]) != nil }) else { continue }
            let comps = props.flatMap { $0.first(path: ["supported-calendar-component-set"])?.children(named: "comp") ?? [] }
                .compactMap { $0.attributes["name"]?.uppercased() }
            if !comps.isEmpty, !comps.contains("VEVENT") { continue }
            let url = try resolve(href, against: base)
            let name = props.compactMap { $0.first(path: ["displayname"])?.text }.first { !$0.isEmpty } ?? url.lastPathComponent
            let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
            out.append(RemoteCalendar(id: path, name: name))
        }
        if let first = out.indices.first { out[first].primary = true }
        return out
    }

    /// События календаря `calendarPath` в окне. Повторы разворачиваются локально (`ICS.events`).
    public static func events(_ account: CalDAVAccount, calendarPath: String, from: Date, to: Date,
                              transport: HTTPTransport) async throws -> [CalendarEvent] {
        let url = try resolve(calendarPath, against: account.server)
        let xml = try await send(request("REPORT", url, depth: "1", body: queryBody(from: from, to: to), account: account), transport)
        guard let root = DAVXML.parse(xml) else { throw CalendarAccountError.badResponse }
        let prefix = "caldav:" + (account.server.host ?? "") + ":"
        return root.children(named: "response")
            .compactMap { $0.first(path: ["propstat", "prop", "calendar-data"])?.text }
            .flatMap { ICS.events($0, from: from, to: to, owner: account.ownerEmail, idPrefix: prefix) }
    }
}

/// Мини-DOM для ответов WebDAV: имена без пространств имён (`d:href`, `D:href`, `href` — одно и то же).
public final class DAVXML: NSObject, XMLParserDelegate {
    public let name: String
    public var attributes: [String: String]
    public var text = ""
    public private(set) var nodes: [DAVXML] = []
    private weak var parent: DAVXML?

    init(name: String, attributes: [String: String] = [:], parent: DAVXML? = nil) {
        self.name = name; self.attributes = attributes; self.parent = parent
    }

    public static func parse(_ data: Data) -> DAVXML? {
        let root = DAVXML(name: "#root")
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        let builder = Builder(root: root)
        parser.delegate = builder
        guard parser.parse() else { return nil }
        return root.nodes.first
    }

    public func children(named n: String) -> [DAVXML] { nodes.filter { $0.name == n } }

    /// Первый узел по пути имён от этого узла, в глубину.
    public func first(path: [String]) -> DAVXML? {
        guard let head = path.first else { return self }
        for child in nodes where child.name == head {
            if let found = child.first(path: Array(path.dropFirst())) { return found }
        }
        return nil
    }

    final class Builder: NSObject, XMLParserDelegate {
        var current: DAVXML
        init(root: DAVXML) { current = root }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            let node = DAVXML(name: local.lowercased(), attributes: attributeDict, parent: current)
            current.nodes.append(node)
            current = node
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            current.text = current.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let up = current.parent { current = up }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { current.text += string }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            current.text += String(decoding: CDATABlock, as: UTF8.self)
        }
    }
}
