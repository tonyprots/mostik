import AppKit
import MostikCore
import MostikKit
import MostikUI

/// Источники календаря в Настройках: Google (OAuth в браузере), Яндекс (CalDAV, пароль приложения),
/// Календарь macOS (EventKit, отмеченные календари). По умолчанию не подключён ни один.
/// Что отмечено — в `settings.calendarAccounts`, секреты — в связке ключей (`CalendarSecrets`).
@MainActor
final class CalendarAccountsController {
    private let model: AppModel
    private let calendar = CalendarSource.shared
    private let transport: HTTPTransport = URLSessionTransport()
    private let googleClient = GoogleOAuth.client(info: Bundle.main.infoDictionary)
    private var googleTask: Task<Void, Never>?
    private var yandexTask: Task<Void, Never>?
    private var onEventsChanged: () -> Void = {}

    init(model: AppModel) {
        self.model = model
    }

    func start(onEventsChanged: @escaping () -> Void) {
        self.onEventsChanged = onEventsChanged
        model.googleCalendarAvailable = googleClient != nil
        for source in [calendar.google, calendar.yandex] {
            let kind = source.kind
            source.onUpdate = { [weak self] status in self?.show(kind, status) }
        }
        apply(model.settings.calendarAccounts)
        model.onConnectCalendar = { [weak self] in self?.connect($0) }
        model.onDisconnectCalendar = { [weak self] in self?.disconnect($0) }
        model.onPickCalendars = { [weak self] in self?.pick($0) }
        model.onSaveCalendars = { [weak self] in self?.save($0, $1) }
        model.onSubmitYandex = { [weak self] in self?.signInYandex(login: $0, password: $1) }
        model.onCancelCalendarSignIn = { [weak self] in self?.cancelSignIn() }
    }

    func settingsChanged(old: MostikSettings, new: MostikSettings) {
        guard old.calendarAccounts != new.calendarAccounts else { return }
        apply(new.calendarAccounts)
    }

    // MARK: настройки → провайдеры

    private func apply(_ accounts: CalendarAccounts) {
        calendar.eventKit.select((accounts.mac ?? []).map(\.id))
        model.calendarSourceStatus[.mac] = accounts.mac.map {
            CalendarSourceStatus(CalendarAccounts.summary(selected: $0, total: nil))
        }
        configureGoogle(accounts.google)
        configureYandex(accounts.yandex)
        onEventsChanged()
    }

    private func configureGoogle(_ account: CalendarAccounts.Account?) {
        guard let account, !account.calendars.isEmpty else { return configure(calendar.google, nil, account) }
        guard let client = googleClient, let refresh = CalendarSecrets.read(.google) else {
            calendar.google.configure(nil)
            model.calendarSourceStatus[.google] = needsSignIn
            return
        }
        let session = GoogleSession(client: client, refreshToken: refresh, transport: transport)
        let calendars = account.calendars, owner = account.login
        configure(calendar.google, { from, to in
            try await session.events(calendars: calendars, owner: owner, from: from, to: to)
        }, account)
    }

    private func configureYandex(_ account: CalendarAccounts.Account?) {
        guard let account, !account.calendars.isEmpty else { return configure(calendar.yandex, nil, account) }
        guard let password = CalendarSecrets.read(.yandex) else {
            calendar.yandex.configure(nil)
            model.calendarSourceStatus[.yandex] = needsSignIn
            return
        }
        let dav = CalDAVAccount(server: CalDAVAccount.yandexServer, username: account.login, password: password)
        let calendars = account.calendars, transport = transport
        configure(calendar.yandex, { from, to in
            var out: [CalendarEvent] = []
            for cal in calendars {
                out += try await CalDAV.events(dav, calendarPath: cal.id, from: from, to: to, transport: transport)
            }
            return out
        }, account)
    }

    private func configure(_ source: AccountCalendar, _ fetch: AccountCalendar.Fetch?, _ account: CalendarAccounts.Account?) {
        source.configure(fetch)
        model.calendarSourceStatus[source.kind] = account.map {
            CalendarSourceStatus(($0.login.isEmpty ? "" : $0.login + " · ") + CalendarAccounts.summary(selected: $0.calendars, total: nil))
        }
    }

    private var needsSignIn: CalendarSourceStatus {
        CalendarSourceStatus(L10n.isRussian ? "Нужно подключить заново" : "Reconnect needed", warning: true)
    }

    private func show(_ kind: CalendarAccounts.Kind, _ status: CalendarFetchStatus) {
        let ru = L10n.isRussian
        let account = kind == .google ? model.settings.calendarAccounts.google : model.settings.calendarAccounts.yandex
        let base = account.map { ($0.login.isEmpty ? "" : $0.login + " · ") } ?? ""
        switch status {
        case .off, .loading:
            return
        case .ok(let count, let at):
            let time = at.formatted(date: .omitted, time: .shortened)
            model.calendarSourceStatus[kind] = CalendarSourceStatus(base + (ru ? "встреч: \(count) · \(time)" : "meetings: \(count) · \(time)"))
            onEventsChanged()
        case .failed(let message):
            model.calendarSourceStatus[kind] = CalendarSourceStatus(base + (ru ? "ошибка: " : "error: ") + message, warning: true)
        case .needsSignIn:
            model.calendarSourceStatus[kind] = needsSignIn
        }
    }

    // MARK: действия

    private func connect(_ kind: CalendarAccounts.Kind) {
        switch kind {
        case .google: signInGoogle()
        case .yandex: model.yandexSignIn = YandexSignInState(login: model.settings.calendarAccounts.yandex?.login ?? "")
        case .mac: connectMac()
        }
    }

    private func disconnect(_ kind: CalendarAccounts.Kind) {
        var s = model.settings
        switch kind {
        case .google:
            if let token = CalendarSecrets.read(.google) {
                let transport = transport
                Task.detached { await GoogleOAuth.revoke(token, transport: transport) }
            }
            CalendarSecrets.delete(.google)
            s.calendarAccounts.google = nil
        case .yandex:
            CalendarSecrets.delete(.yandex)
            s.calendarAccounts.yandex = nil
        case .mac:
            s.calendarAccounts.mac = nil
        }
        model.calendarSourceStatus[kind] = nil
        model.onUpdateSettings(s)
    }

    /// Список календарей с сервера и окно выбора. Отмеченные остаются отмеченными.
    private func pick(_ kind: CalendarAccounts.Kind) {
        let selected = Set(model.settings.calendarAccounts.selected(kind).map(\.id))
        switch kind {
        case .mac:
            model.calendarPicker = CalendarPickerState(kind: .mac, calendars: calendar.eventKit.calendars(), selected: selected)
        case .google:
            guard let client = googleClient, let refresh = CalendarSecrets.read(.google) else { return signInGoogle() }
            let session = GoogleSession(client: client, refreshToken: refresh, transport: transport)
            Task { await self.present(.google, selected: selected) { try await session.calendars() } }
        case .yandex:
            guard let login = model.settings.calendarAccounts.yandex?.login, let password = CalendarSecrets.read(.yandex) else {
                model.yandexSignIn = YandexSignInState(login: model.settings.calendarAccounts.yandex?.login ?? "")
                return
            }
            let dav = CalDAVAccount(server: CalDAVAccount.yandexServer, username: login, password: password)
            let transport = transport
            Task { await self.present(.yandex, selected: selected) { try await CalDAV.calendars(dav, transport: transport) } }
        }
    }

    private func present(_ kind: CalendarAccounts.Kind, selected: Set<String>,
                         _ load: @Sendable () async throws -> [RemoteCalendar]) async {
        do {
            let all = try await load()
            model.calendarPicker = CalendarPickerState(kind: kind, calendars: all, selected: selected)
        } catch let error as CalendarAccountError {
            model.calendarSourceStatus[kind] = error == .unauthorized ? needsSignIn
                : CalendarSourceStatus((L10n.isRussian ? "Ошибка: " : "Error: ") + error.message, warning: true)
        } catch {
            model.calendarSourceStatus[kind] = CalendarSourceStatus(error.localizedDescription, warning: true)
        }
    }

    private func save(_ kind: CalendarAccounts.Kind, _ calendars: [RemoteCalendar]) {
        var s = model.settings
        switch kind {
        case .google: s.calendarAccounts.google?.calendars = calendars
        case .yandex: s.calendarAccounts.yandex?.calendars = calendars
        case .mac: s.calendarAccounts.mac = calendars
        }
        s.calendarEnabled = true
        model.onUpdateSettings(s)
    }

    // MARK: Google

    private func signInGoogle() {
        guard let client = googleClient, googleTask == nil else { return }
        model.googleSigningIn = true
        let transport = transport
        googleTask = Task {
            defer { self.googleTask = nil; self.model.googleSigningIn = false }
            do {
                let tokens = try await GoogleSignIn.run(client: client, transport: transport) { url in
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                }
                guard let refresh = tokens.refresh, CalendarSecrets.write(.google, refresh) else {
                    return self.fail(.google, L10n.isRussian ? "не удалось сохранить вход в связке ключей" : "couldn’t save the sign-in to the keychain")
                }
                let all = (try? await GoogleCalendarAPI.calendars(token: tokens.access, transport: transport)) ?? []
                var s = self.model.settings
                s.calendarAccounts.google = .init(login: tokens.email ?? "", calendars: CalendarAccounts.initialSelection(all))
                s.calendarEnabled = true
                self.model.onUpdateSettings(s)
                MenuBarPanel.activateApp()
                // Сразу показать выбор: основной уже отмечен, остальные — по желанию.
                if all.count > 1 {
                    self.model.calendarPicker = CalendarPickerState(kind: .google, calendars: all,
                                                                    selected: Set(s.calendarAccounts.google!.calendars.map(\.id)))
                }
            } catch is CancellationError {
            } catch GoogleSignIn.Failure.denied {
                self.fail(.google, L10n.isRussian ? "вход отменён" : "sign-in cancelled")
            } catch GoogleSignIn.Failure.timedOut {
                self.fail(.google, L10n.isRussian ? "браузер не ответил за 5 минут" : "no answer from the browser in 5 minutes")
            } catch let error as CalendarAccountError {
                self.fail(.google, error.message)
            } catch {
                self.fail(.google, error.localizedDescription)
            }
        }
    }

    private func fail(_ kind: CalendarAccounts.Kind, _ message: String) {
        model.calendarSourceStatus[kind] = CalendarSourceStatus((L10n.isRussian ? "Не подключено: " : "Not connected: ") + message, warning: true)
    }

    private func cancelSignIn() {
        googleTask?.cancel()
        yandexTask?.cancel()
        yandexTask = nil
        model.yandexSignIn = nil
    }

    // MARK: Яндекс

    private func signInYandex(login: String, password: String) {
        guard yandexTask == nil, !login.isEmpty, !password.isEmpty else { return }
        model.yandexSignIn?.busy = true
        model.yandexSignIn?.error = nil
        let dav = CalDAVAccount(server: CalDAVAccount.yandexServer, username: login, password: password)
        let transport = transport
        yandexTask = Task {
            defer { self.yandexTask = nil }
            do {
                let all = try await CalDAV.calendars(dav, transport: transport)
                guard !Task.isCancelled else { return }
                guard CalendarSecrets.write(.yandex, password) else {
                    self.model.yandexSignIn?.busy = false
                    self.model.yandexSignIn?.error = L10n.isRussian ? "Не удалось сохранить пароль в связке ключей." : "Couldn’t save the password to the keychain."
                    return
                }
                self.model.yandexSignIn = nil
                var s = self.model.settings
                s.calendarAccounts.yandex = .init(login: login, calendars: CalendarAccounts.initialSelection(all))
                s.calendarEnabled = true
                self.model.onUpdateSettings(s)
                if all.count > 1 {
                    self.model.calendarPicker = CalendarPickerState(kind: .yandex, calendars: all,
                                                                    selected: Set(s.calendarAccounts.yandex!.calendars.map(\.id)))
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.model.yandexSignIn?.busy = false
                let ru = L10n.isRussian
                self.model.yandexSignIn?.error = (error as? CalendarAccountError) == .unauthorized
                    ? (ru ? "Логин или пароль не подошли. Нужен пароль приложения для CalDAV, а не пароль от аккаунта."
                          : "Login or password rejected. Use a CalDAV app password, not your account password.")
                    : (ru ? "Не удалось подключиться: " : "Couldn’t connect: ") + ((error as? CalendarAccountError)?.message ?? error.localizedDescription)
            }
        }
    }

    // MARK: macOS

    /// Доступ к Календарю macOS просим только здесь — по кнопке «Выбрать…».
    private func connectMac() {
        Task {
            guard await calendar.requestAccess() else {
                model.calendarSourceStatus[.mac] = CalendarSourceStatus(
                    L10n.isRussian ? "Нет доступа. Включите Mostik в открывшейся панели «Календари» и нажмите «Выбрать…» ещё раз"
                                   : "No access. Turn Mostik on in the Calendars pane that opened, then press “Choose…” again", warning: true)
                return
            }
            let all = calendar.eventKit.calendars()
            model.calendarPicker = CalendarPickerState(kind: .mac, calendars: all,
                                                       selected: Set(CalendarAccounts.initialSelection(all).map(\.id)))
        }
    }
}
