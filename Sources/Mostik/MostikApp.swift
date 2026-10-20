import AppKit
import MostikKit
import Combine
import SwiftUI
import MostikCore
import MostikUI

/// Приложение меню-бара: MenuBarExtra от SwiftUI, окна и HUD — через AppKit,
/// чтобы контроллер открывал их сам, без `openWindow` из вида.
struct MostikApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(model: delegate.controller.model)
                .tint(Palette.accent)
        } label: {
            MenuBarLabel(icon: delegate.controller.model.menuIcon)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Иконка в меню-баре: во время записи — заполненная; во время записи встречи — значок записи и время.
/// Значок строки меню смотрит только на `MenuBarIcon`: фаза, (при записи) ступень голоса не чаще 10 раз
/// в секунду и время встречи раз в секунду. Окна при этом не перерисовываются (шаг 2, п. 8).
private struct MenuBarLabel: View {
    @ObservedObject var icon: MenuBarIcon

    var body: some View {
        let look = icon.look
        HStack(spacing: 4) {
            if let value = icon.variableValue, look.breathes {
                Image(systemName: look.symbol, variableValue: value)
            } else {
                Image(systemName: look.symbol)
            }
            if let timer = icon.timer {
                Text(timer).monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(look.spoken)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Без бандла (swift run) LSUIElement не действует — задаём явно.
        NSApp.setActivationPolicy(.accessory)
        // Самопроверка меню — без движка, хоткеев и записи в данные: рядом может работать настоящий Mostik.
        if MenuSelfTest.mode == nil { controller.start() }
        MenuSelfTest.runIfRequested(controller: controller)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Щелчок по значку в Dock (он есть, пока открыто главное окно, B2) — окно вперёд.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.model.onOpenMainWindow()
        return false
    }
}

/// Главное окно (с вкладкой Настроек), онбординг, плашка диктовки и согласие на запись встречи.
/// Запись встречи живёт в строке меню (значок и раздел меню), своей панели у неё нет.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    weak var model: AppModel? {
        didSet {
            observeHUD(); observeMeeting()
            model?.onHUDDrag = { [weak self] phase in self?.hudDrag(phase) }
            model?.onResetHUDPosition = { [weak self] in self?.resetHUDPosition() }
            model?.hudMoved = savedHUDPosition != nil
        }
    }
    private var mainWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var hudPanel: NSPanel?
    private var hudCancellable: AnyCancellable?
    private var hudHideWork: DispatchWorkItem?
    /// Плашка гаснет (шаг 3, п. 13); поколение отменяет устаревшее «убрать окно».
    private var hudFading = false
    private var hudGeneration = 0
    /// Перетаскивание плашки: где был курсор и плашка, когда начали тянуть.
    private var hudDragStart: (mouse: NSPoint, origin: NSPoint)?
    /// Своё место плашки — доля видимой области экрана (`HUDPosition`); nil — по умолчанию.
    private static let hudPositionKey = HUDPosition.defaultsKey
    private var consentWindow: NSWindow?
    private var meetingCancellables: [AnyCancellable] = []
    /// Плашка вышла на экран (замер `hud.shown`, шаг 0).
    var onHUDShown: ((AppModel.HUDPhase) -> Void)?

    var isOnboardingVisible: Bool { onboardingWindow?.isVisible ?? false }

    func showMain() {
        guard let model else { return }
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Mostik"
            window.contentViewController = NSHostingController(rootView: MainWindowView(model: model).tint(Palette.accent))
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("MostikMain")
            window.delegate = self
            mainWindow = window
        }
        setDockPresence(true)
        MenuBarPanel.activateApp()
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    /// B2 (отзыв автора): пока открыто главное окно — значок в Dock и в ⌘Tab (`.regular`);
    /// окно закрыли — снова только строка меню (`.accessory`). Политику меняет только главное окно:
    /// плашка диктовки — неактивирующая панель, её показ Mostik не активирует и фокус из поля не забирает.
    private func setDockPresence(_ visible: Bool) {
        let policy: NSApplication.ActivationPolicy = visible ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }

    func showOnboarding() {
        guard let model else { return }
        if onboardingWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Mostik"
            window.contentViewController = NSHostingController(rootView: OnboardingView(model: model).tint(Palette.accent))
            window.isReleasedWhenClosed = false
            window.center()
            window.delegate = self
            onboardingWindow = window
        }
        MenuBarPanel.activateApp()
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    func closeOnboarding() {
        onboardingWindow?.close()
    }

    // MARK: HUD

    private func observeHUD() {
        hudCancellable = model?.$hud
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                MainActor.assumeIsolated { self?.hudChanged(phase) }
            }
    }

    private func hudChanged(_ phase: AppModel.HUDPhase) {
        hudHideWork?.cancel()
        hudGeneration += 1
        let generation = hudGeneration
        if phase == .hidden {
            // Шаг 3, п. 13: скрытие — прозрачностью окна за 0,15 с, окно убираем по окончании,
            // если за это время плашку не показали снова.
            guard let panel = hudPanel, panel.isVisible else { return }
            hudFading = true
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = HUDPlacement.hideDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.hudGeneration == generation else { return }
                    self.hudFading = false
                    panel.orderOut(nil)
                }
            })
            return
        }
        var panel = hudPanel ?? makeHUDPanel()
        hudPanel = panel
        let wasVisible = panel.isVisible && !hudFading
        hudFading = false
        // Плашка ловит мышь, только когда в ней есть что нажать: итог с сомнениями — ссылка в историю (П9-B),
        // запись — меню языка (R3b). Панель не активирующая: клик не уводит фокус из поля ввода.
        switch phase {
        case let .done(_, doubts, _, spelling) where doubts > 0 || spelling != nil:
            panel.ignoresMouseEvents = false
        case .recording where !(model?.voiceEdit.isShowing ?? false):
            panel.ignoresMouseEvents = false
        default:
            panel.ignoresMouseEvents = true
        }
        // Экран выбирается на показе (у курсора) и дальше не меняется: «Расшифровка» и «Вставлено»
        // не перепрыгивают на другой монитор вслед за мышью.
        if HUDPlacement.reposition(wasVisible: wasVisible, phaseVisible: true) { positionHUD(panel) }
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        // Долгоживущая панель бывает «прилипшей» к другому пространству: над полноэкранным окном
        // она выводится с прозрачностью 1, но на экране её нет. Не на текущем пространстве — новая панель.
        if !panel.isOnActiveSpace {
            AppLog.shared.event("hud", "panel not on active space, recreated")
            let fresh = makeHUDPanel()
            fresh.ignoresMouseEvents = panel.ignoresMouseEvents
            fresh.setFrameOrigin(panel.frame.origin)
            fresh.alphaValue = 0
            panel.orderOut(nil)
            panel.contentView = nil
            hudPanel = fresh
            panel = fresh
            panel.orderFrontRegardless()
        }
        if panel.alphaValue < 1 {
            let target = panel
            NSAnimationContext.runAnimationGroup { context in
                context.duration = HUDPlacement.showDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                target.animator().alphaValue = 1
            }
        }
        onHUDShown?(phase)
    }

    /// Панель шире пилюли на поля под тень материала (П9-B): тень 0 8 24 не обрезается краем окна.
    private static let hudShadowInset: CGFloat = 32
    private static let hudSize = NSSize(width: HUDView.size.width + 2 * hudShadowInset,
                                        height: HUDView.size.height + 2 * hudShadowInset)

    private func makeHUDPanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.hudSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        if let model {
            let host = NSHostingView(rootView: HUDView(model: model)
                .frame(width: Self.hudSize.width, height: Self.hudSize.height))
            host.frame = NSRect(origin: .zero, size: Self.hudSize)
            panel.contentView = host
        }
        return panel
    }

    /// Экран, где сейчас курсор; место — своё (если плашку перетаскивали) или снизу по центру.
    /// Своё место хранится долей экрана: на другом мониторе плашка встаёт туда же и не уходит за край.
    private func positionHUD(_ panel: NSPanel) {
        let screens = NSScreen.screens
        guard let index = HUDPosition.screenIndex(mouse: NSEvent.mouseLocation, screens: screens.map(\.frame)) else { return }
        let origin = HUDPosition.origin(saved: savedHUDPosition, plaque: HUDView.size, visible: screens[index].visibleFrame)
        panel.setFrameOrigin(NSPoint(x: origin.x - Self.hudShadowInset, y: origin.y - Self.hudShadowInset))
    }

    // MARK: перетаскивание плашки

    private var savedHUDPosition: HUDPosition.Saved? {
        get { HUDPosition.decode(UserDefaults.standard.data(forKey: Self.hudPositionKey)) }
        set {
            if let data = HUDPosition.encode(newValue) {
                UserDefaults.standard.set(data, forKey: Self.hudPositionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.hudPositionKey)
            }
            model?.hudMoved = newValue != nil
        }
    }

    /// Окно двигается за курсором по экранным координатам: само окно под курсором едет,
    /// поэтому сдвиг жеста в координатах вида не годится. Панель не активируется — фокус не уходит.
    private func hudDrag(_ phase: AppModel.HUDDrag) {
        guard let panel = hudPanel, panel.isVisible else { hudDragStart = nil; return }
        let mouse = NSEvent.mouseLocation
        switch phase {
        case .changed:
            let start = hudDragStart ?? (mouse, panel.frame.origin)
            hudDragStart = start
            panel.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                         y: start.origin.y + mouse.y - start.mouse.y))
        case .ended:
            hudDragStart = nil
            let plaque = panel.frame.insetBy(dx: Self.hudShadowInset, dy: Self.hudShadowInset)
            let screens = NSScreen.screens
            guard let index = HUDPosition.screenIndex(plaque: plaque, screens: screens.map(\.frame)) else { return }
            let visible = screens[index].visibleFrame
            let saved = HUDPosition.save(origin: plaque.origin, plaque: HUDView.size, visible: visible)
            savedHUDPosition = saved
            // Отпустили за краем или у места по умолчанию — плашка встаёт туда, где её запомнили.
            let origin = HUDPosition.origin(saved: saved, plaque: HUDView.size, visible: visible)
            panel.setFrameOrigin(NSPoint(x: origin.x - Self.hudShadowInset, y: origin.y - Self.hudShadowInset))
        }
    }

    /// «Вернуть на место» в Настройках → Основное.
    private func resetHUDPosition() {
        savedHUDPosition = nil
        if let panel = hudPanel, panel.isVisible { positionHUD(panel) }
    }

    // MARK: согласие на запись встречи (M4)

    private func observeMeeting() {
        meetingCancellables.removeAll()
        guard let model else { return }
        model.$meetingConsentPending
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] pending in MainActor.assumeIsolated { self?.consentPendingChanged(pending) } }
            .store(in: &meetingCancellables)
    }

    private func consentPendingChanged(_ pending: Bool) {
        guard pending else {
            consentWindow?.delegate = nil
            consentWindow?.close()
            consentWindow = nil
            return
        }
        // Главное окно показывает предупреждение само.
        guard let model, !(mainWindow?.isVisible ?? false) else { return }
        // Открытое меню в строке меню тоже показывает его — второе окно не нужно.
        let menuOpen = NSApp.windows.contains { $0.isVisible && MenuBarPanelPolicy.isMenuBarExtraWindow(className: String(describing: type(of: $0))) }
        guard !menuOpen else { return }
        if consentWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 220),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = L10n.isRussian ? "Запись встречи" : "Meeting recording"
            let host = NSHostingController(rootView: MeetingConsentSheet(model: model).tint(Palette.accent))
            host.sizingOptions = [.preferredContentSize]
            window.contentViewController = host
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.delegate = self
            window.center()
            consentWindow = window
        }
        MenuBarPanel.activateApp()
        consentWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === onboardingWindow {
            onboardingWindow = nil
        }
        // Закрытое главное окно не держит дерево видов: история и встречи не перерисовываются
        // в фоне (шаг 2, п. 8). Размер и место окна хранит autosave, вкладку — модель.
        if let window = notification.object as? NSWindow, window === mainWindow {
            mainWindow = nil
            setDockPresence(false)
            DispatchQueue.main.async { window.contentViewController = nil }
        }
        // Закрыли окно согласия крестиком — это отмена записи.
        if let window = notification.object as? NSWindow, window === consentWindow {
            consentWindow = nil
            model?.meetingConsentPending = false
        }
    }
}
