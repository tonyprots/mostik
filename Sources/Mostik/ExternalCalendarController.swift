import AppKit
import MostikCore
import MostikKit
import MostikUI

/// Внешний календарь — команда (docs/external-calendar.md): выбор файла, подтверждение пути,
/// статус в Настройках. Запускается только путь, выбранный или подтверждённый здесь (`CalendarCommandTrust`).
@MainActor
final class ExternalCalendarController {
    private let model: AppModel
    private let calendar = CalendarSource.shared
    private let store: HookDigestStore = KeychainHookDigestStore(account: CalendarCommandTrust.keychainAccount)
    /// Новые события пришли — отправить движку и пересобрать словарь.
    private var onEventsChanged: () -> Void = {}

    init(model: AppModel) {
        self.model = model
    }

    /// Старт приложения: подтверждённый путь — в работу, вписанный в настройки снаружи — спросить.
    func start(onEventsChanged: @escaping () -> Void) {
        self.onEventsChanged = onEventsChanged
        calendar.command.onUpdate = { [weak self] status in self?.show(status) }
        let check = CalendarCommandTrust.reconcile(model.settings.calendarCommand, store: store)
        calendar.command.setPath(check.active)
        if let path = check.ask {
            DispatchQueue.main.async { [weak self] in self?.confirm(path) }
        }
    }

    func settingsChanged(old: MostikSettings, new: MostikSettings) {
        guard old.calendarCommand != new.calendarCommand else { return }
        let check = CalendarCommandTrust.reconcile(new.calendarCommand, store: store)
        calendar.command.setPath(check.active)
        if let path = check.ask {
            DispatchQueue.main.async { [weak self] in self?.confirm(path) }
        }
    }

    /// «Выбрать…»: исполняемый файл. Выбор здесь — воля пользователя, отпечаток пишется сразу.
    func choose() {
        let ru = L10n.isRussian
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = ru ? "Выбрать" : "Choose"
        panel.message = ru ? "Файл, который печатает события календаря в JSON"
                           : "A file that prints calendar events as JSON"
        if let path = model.settings.calendarCommand {
            panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        }
        MenuBarPanel.activateApp()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        if let problem = ExternalCalendar.check(path: path) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = ru ? "Этот файл не подойдёт" : "This file won’t work"
            alert.informativeText = ExternalCalendar.describe(problem)
            alert.runModal()
            return
        }
        guard CalendarCommandTrust.approve(path, store: store) else {
            model.externalCalendarStatus = ru ? "Не удалось сохранить разрешение в связке ключей"
                                              : "Couldn’t save the permission to the keychain"
            return
        }
        var s = model.settings
        s.calendarCommand = path
        s.calendarEnabled = true
        model.onUpdateSettings(s)
    }

    func clear() {
        var s = model.settings
        s.calendarCommand = nil
        model.onUpdateSettings(s)
    }

    func refresh() { calendar.command.refresh() }

    /// Путь появился в настройках не через Mostik: показать его и спросить. По умолчанию — «Не запускать».
    private func confirm(_ path: String) {
        guard model.settings.calendarCommand == path, !CalendarCommandTrust.isTrusted(path, store: store) else { return }
        let ru = L10n.isRussian
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = ru ? "Подключить внешний календарь?" : "Connect an external calendar?"
        let problem = ExternalCalendar.check(path: path).map { "\n\n" + (ru ? "Сейчас не запустится: " : "Won’t run now: ") + ExternalCalendar.describe($0) } ?? ""
        alert.informativeText = (ru ? "Путь к команде календаря вписан в настройки не в Mostik. Mostik будет запускать этот файл раз в несколько минут и читать из него встречи:\n\n"
                                    : "The calendar command path was set outside Mostik. Mostik will run this file every few minutes and read meetings from it:\n\n")
            + MeetingHookPrompt.visible(path) + problem
        alert.addButton(withTitle: ru ? "Не запускать" : "Don’t run")
        alert.addButton(withTitle: ru ? "Разрешить" : "Allow")
        MenuBarPanel.activateApp()
        let allow = alert.runModal() == .alertSecondButtonReturn
        if allow, CalendarCommandTrust.approve(path, store: store) {
            calendar.command.setPath(path)
        } else {
            clear()
        }
    }

    private func show(_ status: CommandCalendar.Status) {
        let ru = L10n.isRussian
        switch status {
        case .off:
            model.externalCalendarStatus = nil
        case .loading:
            if model.externalCalendarStatus == nil { model.externalCalendarStatus = ru ? "Читаю события…" : "Reading events…" }
        case .ok(let count, let at):
            let time = at.formatted(date: .omitted, time: .shortened)
            model.externalCalendarStatus = ru ? "Событий: \(count) · обновлено в \(time)" : "Events: \(count) · updated at \(time)"
            onEventsChanged()
        case .failed(let message):
            model.externalCalendarStatus = (ru ? "Ошибка: " : "Error: ") + message
        }
    }
}
