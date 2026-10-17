import Foundation
import MostikCore
import Network

/// Состояние источника календаря, который читается по сети или процессом: для строки в Настройках.
public enum CalendarFetchStatus: Equatable, Sendable {
    case off
    case loading
    case ok(events: Int, at: Date)
    case failed(String)
    /// Вход не принят или секрет не прочесть из связки ключей — нужно подключить заново.
    case needsSignIn
}

/// Секреты аккаунтов календаря в связке «Вход», с ACL «только Mostik» (как отпечатки хуков).
public enum CalendarSecrets {
    public static let service = "app.mostik.mac.calendars"

    static func store(_ kind: CalendarAccounts.Kind) -> KeychainHookDigestStore {
        KeychainHookDigestStore(service: service, account: kind.rawValue,
                                label: kind == .google ? "Mostik: Google Calendar" : "Mostik: Yandex Calendar")
    }

    /// nil — нет или не прочесть без окна пароля (после пересборки ad-hoc): тогда просим войти заново.
    public static func read(_ kind: CalendarAccounts.Kind) -> String? {
        if case .value(let v) = store(kind).read(), !v.isEmpty { return v }
        return nil
    }

    @discardableResult
    public static func write(_ kind: CalendarAccounts.Kind, _ secret: String) -> Bool { store(kind).write(secret) }

    @discardableResult
    public static func delete(_ kind: CalendarAccounts.Kind) -> Bool { store(kind).delete() }
}

/// Источник по аккаунту (Google, Яндекс): синхронные вызовы читают кеш, устаревший кеш обновляется
/// в фоне. Ошибка не стирает прежние события. `fetch` — замыкание от контроллера: какой аккаунт и календари.
public final class AccountCalendar: CalendarProvider, @unchecked Sendable {
    public typealias Fetch = @Sendable (_ from: Date, _ to: Date) async throws -> [CalendarEvent]

    public let kind: CalendarAccounts.Kind
    public var onUpdate: (CalendarFetchStatus) -> Void = { _ in }

    private let lock = NSLock()
    private var fetch: Fetch?
    private var events: [CalendarEvent] = []
    private var fetchedAt: Date?
    private var running = false
    private var generation = 0

    public init(kind: CalendarAccounts.Kind) { self.kind = kind }

    public var isReady: Bool { lock.withLock { fetch != nil } }

    /// Новый аккаунт или набор календарей; nil — выключено. Сбрасывает кеш.
    public func configure(_ newFetch: Fetch?) {
        lock.withLock {
            fetch = newFetch
            events = []
            fetchedAt = nil
            generation += 1
        }
        if newFetch == nil { report(.off) } else { refresh() }
    }

    public func meetings(around now: Date, days: Int) -> [CalendarEvent] {
        let (cached, stale) = lock.withLock { () -> ([CalendarEvent], Bool) in
            guard fetch != nil else { return ([], false) }
            let stale = fetchedAt.map { Date().timeIntervalSince($0) > ExternalCalendar.refreshInterval } ?? true
            return (events, stale)
        }
        if stale { refresh() }
        return ExternalCalendar.window(cached, around: now, days: days)
    }

    public func refresh() {
        let job: (Fetch, Int)? = lock.withLock {
            guard let fetch, !running else { return nil }
            running = true
            return (fetch, generation)
        }
        guard let (fetch, gen) = job else { return }
        report(.loading)
        let now = Date()
        let span = TimeInterval(CalendarLogic.windowDays) * 86_400
        Task.detached(priority: .utility) { [weak self] in
            let result: Result<[CalendarEvent], Error>
            do { result = .success(try await fetch(now.addingTimeInterval(-span), now.addingTimeInterval(span))) }
            catch { result = .failure(error) }
            self?.finish(result, generation: gen)
        }
    }

    private func finish(_ result: Result<[CalendarEvent], Error>, generation gen: Int) {
        let status: CalendarFetchStatus? = lock.withLock {
            running = false
            guard gen == generation else { return nil }
            fetchedAt = Date()
            switch result {
            case .success(let list):
                events = Array(list.prefix(ExternalCalendar.maxEvents))
                return .ok(events: events.count, at: fetchedAt!)
            case .failure(let error as CalendarAccountError) where error == .unauthorized:
                return .needsSignIn
            case .failure(let error as CalendarAccountError):
                return .failed(error.message)
            case .failure(let error):
                return .failed(error.localizedDescription)
            }
        }
        if let status { report(status) }
    }

    private func report(_ status: CalendarFetchStatus) {
        DispatchQueue.main.async { [weak self] in self?.onUpdate(status) }
    }
}

// MARK: Google

/// Access token Google живёт час: держим его в памяти и обновляем по refresh token из связки ключей.
public actor GoogleSession {
    let client: GoogleOAuth.Client
    let refreshToken: String
    let transport: HTTPTransport
    private var tokens: GoogleOAuth.Tokens?

    public init(client: GoogleOAuth.Client, refreshToken: String, transport: HTTPTransport = URLSessionTransport()) {
        self.client = client; self.refreshToken = refreshToken; self.transport = transport
    }

    func accessToken(force: Bool = false) async throws -> String {
        if !force, let tokens, tokens.expiresAt > Date() { return tokens.access }
        let fresh = try await GoogleOAuth.refresh(refreshToken, client: client, transport: transport)
        tokens = fresh
        return fresh.access
    }

    /// Запрос с токеном; 401 на закешированном токене — один повтор со свежим.
    func authorized<T: Sendable>(_ body: @Sendable (String) async throws -> T) async throws -> T {
        do { return try await body(try await accessToken()) }
        catch CalendarAccountError.unauthorized { return try await body(try await accessToken(force: true)) }
    }

    public func calendars() async throws -> [RemoteCalendar] {
        let transport = transport
        return try await authorized { try await GoogleCalendarAPI.calendars(token: $0, transport: transport) }
    }

    public func events(calendars: [RemoteCalendar], owner: String, from: Date, to: Date) async throws -> [CalendarEvent] {
        let transport = transport
        var out: [CalendarEvent] = []
        for cal in calendars {
            out += try await authorized {
                try await GoogleCalendarAPI.events(token: $0, calendarID: cal.id, from: from, to: to, owner: owner, transport: transport)
            }
        }
        return Self.unique(out)
    }

    /// Одна встреча в двух отмеченных календарях — один раз.
    static func unique(_ events: [CalendarEvent]) -> [CalendarEvent] {
        var seen = Set<String>()
        return events.filter { seen.insert($0.id).inserted }
    }
}

/// Вход в Google: приёмник на 127.0.0.1 со случайным портом, браузер, обмен кода на токены.
/// Ждёт не дольше `timeout`; отмена задачи закрывает приёмник.
public enum GoogleSignIn {
    public static let timeout: TimeInterval = 300

    public static func run(client: GoogleOAuth.Client, transport: HTTPTransport = URLSessionTransport(),
                           open: @escaping @Sendable (URL) -> Void) async throws -> GoogleOAuth.Tokens {
        let verifier = GoogleOAuth.randomToken()
        let state = GoogleOAuth.randomToken(length: 32)
        let receiver = try LoopbackReceiver(state: state)
        defer { receiver.stop() }
        let port = try await receiver.start()
        let redirect = GoogleOAuth.redirectURI(port: port)
        open(GoogleOAuth.authURL(client: client, redirect: redirect, verifier: verifier, state: state))
        let code = try await receiver.code(timeout: timeout)
        return try await GoogleOAuth.exchange(code: code, verifier: verifier, redirect: redirect, client: client, transport: transport)
    }

    public enum Failure: Error, Equatable {
        case denied(String)
        case timedOut
        case listener
    }
}

/// HTTP-приёмник ответа Google: только 127.0.0.1, только первая строка запроса, ответ — короткая страница.
final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let state: String
    private let queue = DispatchQueue(label: "app.mostik.oauth-loopback")
    private var ready: CheckedContinuation<UInt16, Error>?
    private var waiting: CheckedContinuation<String, Error>?
    private var outcome: Result<String, Error>?

    init(state: String) throws {
        self.state = state
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        params.acceptLocalOnly = true
        do { listener = try NWListener(using: params) } catch { throw GoogleSignIn.Failure.listener }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<UInt16, Error>) in
            queue.async { [self] in
                ready = c
                listener.stateUpdateHandler = { [weak self] st in self?.stateChanged(st) }
                listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
                listener.start(queue: queue)
            }
        }
    }

    private func stateChanged(_ st: NWListener.State) {
        switch st {
        case .ready:
            if let port = listener.port?.rawValue { ready?.resume(returning: port); ready = nil }
        case .failed, .cancelled:
            ready?.resume(throwing: GoogleSignIn.Failure.listener); ready = nil
        default: break
        }
    }

    func code(timeout: TimeInterval) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
                queue.async { [self] in
                    if let outcome { c.resume(with: outcome); return }
                    waiting = c
                    queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.complete(.failure(GoogleSignIn.Failure.timedOut)) }
                }
            }
        } onCancel: { [weak self] in
            self?.queue.async { self?.complete(.failure(CancellationError())) }
        }
    }

    private func complete(_ result: Result<String, Error>) {
        guard outcome == nil else { return }
        outcome = result
        waiting?.resume(with: result)
        waiting = nil
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        read(conn, buffer: Data())
    }

    private func read(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            let text = String(decoding: buf, as: UTF8.self)
            if let end = text.range(of: "\r\n") {
                self.handle(conn, requestLine: String(text[..<end.lowerBound]))
            } else if done || error != nil || buf.count > 8192 {
                conn.cancel()
            } else {
                self.read(conn, buffer: buf)
            }
        }
    }

    private func handle(_ conn: NWConnection, requestLine: String) {
        let page: (Int, String)
        switch GoogleOAuth.callback(requestLine: requestLine, state: state) {
        case .ignore:
            page = (404, "")
        case .denied(let reason):
            page = (200, UIText.pick("Вход отменён. Окно можно закрыть.", "Sign-in cancelled. You can close this window."))
            complete(.failure(GoogleSignIn.Failure.denied(reason)))
        case .code(let code):
            page = (200, UIText.pick("Готово: календарь Google подключён к Mostik. Окно можно закрыть.",
                                     "Done: Google Calendar is connected to Mostik. You can close this window."))
            complete(.success(code))
        }
        let html = page.1.isEmpty ? "" : "<!doctype html><meta charset=utf-8><title>Mostik</title>"
            + "<link rel=icon href=\"data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>🌉</text></svg>\">"
            + "<body style=\"font:16px -apple-system,sans-serif;margin:15vh auto;max-width:28em;padding:0 1em;color:#1d1d1f\"><p>\(page.1)</p>"
        let status = page.0 == 200 ? "200 OK" : "404 Not Found"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\n"
            + "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n" + html
        conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    func stop() {
        queue.async { [self] in
            listener.cancel()
            ready?.resume(throwing: GoogleSignIn.Failure.listener); ready = nil
            complete(.failure(CancellationError()))
        }
    }
}
