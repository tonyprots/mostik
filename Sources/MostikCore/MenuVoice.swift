import Foundation

/// Приложение, в которое вернуть фокус и вставить текст. `pid` — главное: у `swift run` нет bundle id.
public struct AppRef: Equatable, Sendable {
    public var pid: Int32
    public var bundleID: String
    public var name: String
    public init(pid: Int32, bundleID: String, name: String) {
        self.pid = pid; self.bundleID = bundleID; self.name = name
    }
}

/// Последнее приложение впереди, кроме самого Mostik. Меню строки меню (`MenuBarExtra` в стиле `.window`)
/// делает Mostik активным, поэтому «куда вставлять» запоминаем заранее, по уведомлениям о смене приложения.
public struct FrontAppMemory: Sendable {
    public let ownPID: Int32
    public private(set) var last: AppRef?

    public init(ownPID: Int32, last: AppRef? = nil) {
        self.ownPID = ownPID
        self.last = last
    }

    /// Впереди стало `app`: своё и пустое не считаются.
    public mutating func activated(_ app: AppRef?) {
        guard let app, app.pid > 0, app.pid != ownPID else { return }
        last = app
    }

    /// Приложение закрылось: вставлять в него уже нельзя.
    public mutating func terminated(pid: Int32) {
        if last?.pid == pid { last = nil }
    }
}

/// Почему текст из записи через меню остался в буфере. Значение — `PasteOutcome.clipboard(reason:)`.
public enum MenuClipboardReason: String, Equatable, Sendable {
    /// Приложение, где стоял курсор, закрыли.
    case appClosed = "app_closed"
    /// До меню впереди не было ни одного приложения, кроме Mostik.
    case noApp = "no_target"
}

/// Куда пойдёт текст записи, начатой из меню.
public enum MenuPasteTarget: Equatable, Sendable {
    case app(AppRef)
    case clipboard(MenuClipboardReason)
}

/// Пункт «Записать голос» в меню строки меню (D1 без клавиши): первое нажатие начинает запись без рук,
/// второе останавливает; вставка — туда, где стоял курсор до открытия меню.
public enum MenuVoice {
    public enum Phase: Equatable, Sendable {
        case idle
        case recording
        /// Расшифровка или вставка: пункт неактивен.
        case busy
    }

    public static func phase(_ state: DictationState) -> Phase {
        switch state {
        case .idle, .failed: return .idle
        case .recording: return .recording
        case .transcribing, .inserting: return .busy
        }
    }

    /// Что сказать машине записи. Старт и стоп — `togglePressed`, как у двойного нажатия;
    /// запись по удержанию сначала защёлкивается, иначе машина переключатель не примет.
    public static func inputs(_ state: DictationState, at time: Double) -> [DictationInput] {
        switch state {
        case .idle, .failed: return [.togglePressed(at: time)]
        case .recording(_, _, true): return [.togglePressed(at: time)]
        case .recording(_, _, false): return [.latch, .togglePressed(at: time)]
        case .transcribing, .inserting: return []
        }
    }

    public static func title(_ phase: Phase) -> String {
        switch phase {
        case .idle: return UIText.pick("Записать голос", "Record voice")
        case .recording: return UIText.pick("Остановить запись", "Stop recording")
        case .busy: return UIText.pick("Расшифровка…", "Transcribing…")
        }
    }

    /// Таймер записи: «0:07», «1:02:05». Секунды вниз, как у плашки.
    public static func timer(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Что справа от подписи: таймер во время записи, иначе подсказка клавиши (её рисует вид).
    public static func trailing(_ phase: Phase, elapsed: Double) -> String? {
        phase == .recording ? timer(elapsed) : nil
    }

    /// Подсказка клавиши, как у системных пунктов меню: клавиша записи, нажатая дважды («⌥⌥»).
    /// Без двойного нажатия — переключатель ⌥Space; без обоих — пусто.
    public static func shortcut(holdKey: String, doubleTap: Bool, toggleShortcut: Bool) -> String {
        if doubleTap {
            let key = HUDHint.keySymbol(holdKey)
            return key.count > 1 ? key + " " + key : key + key
        }
        return toggleShortcut ? "⌥Space" : ""
    }

    public static func shortcut(settings: MostikSettings) -> String {
        shortcut(holdKey: settings.holdKey, doubleTap: settings.handsFreeDoubleTap, toggleShortcut: settings.toggleShortcutEnabled)
    }

    /// Куда вставлять: в приложение, что было впереди до меню, если оно ещё открыто.
    public static func target(remembered: AppRef?, isRunning: (AppRef) -> Bool) -> MenuPasteTarget {
        guard let app = remembered, app.pid > 0 else { return .clipboard(.noApp) }
        return isRunning(app) ? .app(app) : .clipboard(.appClosed)
    }

    /// Перед вставкой: nil — вставлять как обычно (`Paster.deliver` сам сверит поле и приложение),
    /// иначе — в буфер с этой причиной. Диктовка с клавиши (`target == nil`) правил меню не получает.
    public static func delivery(_ target: MenuPasteTarget?, isRunning: (AppRef) -> Bool) -> MenuClipboardReason? {
        switch target {
        case nil: return nil
        case .clipboard(let reason): return reason
        case .app(let app): return isRunning(app) ? nil : .appClosed
        }
    }

    /// Вернуть фокус запомненному полю, если приложение после активации поставило его на другое.
    /// Токены — `CFHash` элемента AX; не знали поле — не трогаем.
    public static func needsRefocus(remembered: Int?, current: Int?) -> Bool {
        guard let remembered else { return false }
        return current != remembered
    }

    /// Подпись на плашке, когда текст в буфере по причине из меню; чужие причины — nil.
    public static func clipboardSummary(_ reason: String) -> String? {
        switch MenuClipboardReason(rawValue: reason) {
        case .appClosed: return UIText.pick("В буфере — приложение закрыто", "On clipboard — the app was closed")
        case .noApp: return UIText.pick("В буфере — некуда вставить", "On clipboard — nowhere to paste")
        case nil: return nil
        }
    }
}
