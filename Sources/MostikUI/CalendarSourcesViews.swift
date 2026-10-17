import SwiftUI
import MostikCore

public struct CalendarSourceStatus: Equatable, Sendable {
    public var text: String
    public var warning: Bool
    public init(_ text: String, warning: Bool = false) { self.text = text; self.warning = warning }
}

public struct CalendarPickerState: Identifiable, Equatable, Sendable {
    public var kind: CalendarAccounts.Kind
    public var calendars: [RemoteCalendar]
    public var selected: Set<String>
    public var id: String { kind.rawValue }

    public init(kind: CalendarAccounts.Kind, calendars: [RemoteCalendar], selected: Set<String>) {
        self.kind = kind; self.calendars = calendars; self.selected = selected
    }
}

public struct YandexSignInState: Identifiable, Equatable, Sendable {
    public var login: String
    public var busy = false
    public var error: String?
    public var id: String { "yandex" }

    public init(login: String = "", busy: Bool = false, error: String? = nil) {
        self.login = login; self.busy = busy; self.error = error
    }
}

extension CalendarAccounts.Kind {
    var title: String {
        switch self {
        case .google: L("Google Календарь", "Google Calendar")
        case .yandex: L("Яндекс Календарь", "Yandex Calendar")
        case .mac: L("Календарь macOS", "macOS Calendar")
        }
    }
}

/// Источники календаря под переключателем «Календарь»: Google, Яндекс, macOS — по умолчанию ни один,
/// у каждого свой выбор календарей. Команда для календаря без Google и CalDAV — в «Ещё» внизу раздела.
struct CalendarSourcesRows: View {
    @ObservedObject var model: AppModel

    var body: some View {
        sourceRow(.google)
        FormDivider()
        sourceRow(.yandex)
        FormDivider()
        sourceRow(.mac)
    }

    private func connected(_ kind: CalendarAccounts.Kind) -> Bool {
        switch kind {
        case .google: model.settings.calendarAccounts.google != nil
        case .yandex: model.settings.calendarAccounts.yandex != nil
        case .mac: model.settings.calendarAccounts.mac != nil
        }
    }

    private func hint(_ kind: CalendarAccounts.Kind) -> String {
        if kind == .google, model.googleSigningIn { return L("Жду ответа в браузере…", "Waiting for the browser…") }
        if connected(kind) {
            if let status = model.calendarSourceStatus[kind] { return status.text }
            return CalendarAccounts.summary(selected: model.settings.calendarAccounts.selected(kind), total: nil)
        }
        switch kind {
        case .google:
            return model.googleCalendarAvailable ? L("Вход через браузер, только чтение.", "Sign in in the browser, read-only.")
                                                 : L("Недоступно в этой сборке.", "Not available in this build.")
        case .yandex: return L("Логин и пароль приложения Яндекса, только чтение.", "Yandex login and an app password, read-only.")
        case .mac: return L("Календари, которые уже есть на этом Mac.", "Calendars already on this Mac.")
        }
    }

    private func details(_ kind: CalendarAccounts.Kind) -> String {
        switch kind {
        case .google:
            L("Mostik откроет страницу входа Google в браузере и попросит только чтение календаря. Ключ доступа хранится в связке ключей, события запрашиваются раз в 5 минут напрямую у Google.",
              "Mostik opens Google sign-in in your browser and asks for calendar read access only. The access key stays in the keychain; events are fetched from Google directly every 5 minutes.")
        case .yandex:
            L("Подключение по CalDAV к caldav.yandex.ru. Нужен пароль приложения: id.yandex.ru → Безопасность → Пароли приложений → Календарь CalDAV. Пароль хранится в связке ключей, события запрашиваются раз в 5 минут.",
              "CalDAV connection to caldav.yandex.ru. You need an app password: id.yandex.ru → Security → App passwords → Calendar CalDAV. It stays in the keychain; events are fetched every 5 minutes.")
        case .mac:
            L("Календари из приложения «Календарь» на этом Mac: iCloud, Exchange и другие аккаунты, добавленные в macOS. Mostik читает только отмеченные, без сети.",
              "Calendars from the Calendar app on this Mac: iCloud, Exchange and other accounts added to macOS. Mostik reads only the ones you tick, offline.")
        }
    }

    private func sourceRow(_ kind: CalendarAccounts.Kind) -> some View {
        let on = connected(kind)
        return FormRow(title: kind.title, hint: hint(kind), details: details(kind),
                       warning: model.calendarSourceStatus[kind]?.warning == true,
                       status: on ? Palette.accent : Palette.inkTertiary) {
            if kind == .google, model.googleSigningIn {
                Button(L("Отменить", "Cancel")) { model.onCancelCalendarSignIn() }
                    .buttonStyle(.mostik(.quiet, compact: true))
            } else if on {
                Button(L("Календари…", "Calendars…")) { model.onPickCalendars(kind) }
                    .buttonStyle(.mostik(.quiet, compact: true))
                Button(L("Отключить", "Disconnect")) { model.onDisconnectCalendar(kind) }
                    .buttonStyle(.mostik(.quiet, compact: true))
            } else {
                Button(kind == .mac ? L("Выбрать…", "Choose…") : L("Подключить…", "Connect…")) { model.onConnectCalendar(kind) }
                    .buttonStyle(.mostik(.secondary, compact: true))
                    .disabled(kind == .google && !model.googleCalendarAvailable)
            }
        }
    }
}

/// Какие календари аккаунта читать. Ничего не отмечено — источник подключён, но молчит.
struct CalendarPickerSheet: View {
    @State var state: CalendarPickerState
    var onSave: (CalendarPickerState) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text(state.kind.title).font(TType.headline).foregroundStyle(Palette.ink)
            Text(L("Mostik будет читать встречи только из отмеченных календарей.", "Mostik reads meetings only from the calendars you tick."))
                .font(TType.callout).foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if state.calendars.isEmpty {
                Text(L("В аккаунте нет календарей с событиями.", "The account has no event calendars."))
                    .font(TType.callout).foregroundStyle(Palette.inkTertiary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        ForEach(state.calendars) { cal in
                            Toggle(isOn: Binding(get: { state.selected.contains(cal.id) },
                                                 set: { on in if on { state.selected.insert(cal.id) } else { state.selected.remove(cal.id) } })) {
                                Text(cal.name).font(TType.body).foregroundStyle(Palette.ink)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)
            }
            HStack(spacing: DS.Space.xs) {
                Spacer()
                Button(L("Отмена", "Cancel"), action: onCancel)
                    .buttonStyle(.mostik(.quiet))
                    .keyboardShortcut(.cancelAction)
                Button(L("Готово", "Done")) { onSave(state) }
                    .buttonStyle(.mostikPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Space.l)
        .frame(width: 440)
        .background(Palette.surface)
    }
}

/// Вход в Яндекс Календарь: логин и пароль приложения. Пароль от аккаунта не подойдёт — CalDAV его не примет.
struct YandexSignInSheet: View {
    let state: YandexSignInState
    var onSubmit: (String, String) -> Void
    var onCancel: () -> Void
    @State private var login = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text(L("Яндекс Календарь", "Yandex Calendar")).font(TType.headline).foregroundStyle(Palette.ink)
            Text(L("Нужен пароль приложения, а не пароль от аккаунта: id.yandex.ru → Безопасность → Пароли приложений → Календарь CalDAV.",
                   "Use an app password, not your account password: id.yandex.ru → Security → App passwords → Calendar CalDAV."))
                .font(TType.callout).foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            MostikTextField(placeholder: L("Логин или почта", "Login or email"), text: $login)
            SecureField(L("Пароль приложения", "App password"), text: $password)
                .textFieldStyle(.roundedBorder)
            if let error = state.error {
                Text(error).font(TType.callout).foregroundStyle(Palette.doubt)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DS.Space.xs) {
                if state.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(L("Отмена", "Cancel"), action: onCancel)
                    .buttonStyle(.mostik(.quiet))
                    .keyboardShortcut(.cancelAction)
                Button(L("Подключить", "Connect")) { onSubmit(login.trimmingCharacters(in: .whitespaces), password) }
                    .buttonStyle(.mostikPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.busy || login.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
            }
        }
        .padding(DS.Space.l)
        .frame(width: 440)
        .background(Palette.surface)
        .onAppear { if login.isEmpty { login = state.login } }
    }
}
