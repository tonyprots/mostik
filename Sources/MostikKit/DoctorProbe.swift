import AppKit
import AVFoundation
import ApplicationServices
import MostikCore

/// Сбор фактов для «Проверки» (R7). Ничего не спрашивает и не меняет — только читает.
public enum DoctorProbe {
    /// Приложения, которые перехватывают модификаторы: ловят правый ⌥ или ⌘ под свои сочетания.
    static let keyGrabberNames = ["Punto Switcher", "Caramba Switcher", "Karabiner-Elements", "Karabiner-Menu", "BetterTouchTool"]

    /// Факты платформы. Движок, модели и бэкенд LLM контроллер дописывает сам.
    public static func facts(holdKey: String, dataDir: URL) -> DoctorFacts {
        var f = DoctorFacts()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: f.microphone = .authorized
        case .notDetermined: f.microphone = .undetermined
        default: f.microphone = .denied
        }
        f.accessibility = AXIsProcessTrusted()
        f.postEvents = CGPreflightPostEventAccess()
        f.systemAudio = Permissions.systemAudioGranted
        f.systemAudioSilent = Permissions.systemAudioSilent
        f.holdKey = holdKey
        f.fnUsage = fnUsageType()
        f.keyGrabbers = runningKeyGrabbers()
        f.freeBytes = freeBytes(at: dataDir)
        return f
    }

    /// Что делает fn/🌐 в macOS. nil — ключ не задан.
    static func fnUsageType() -> Int? {
        let value = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString)
        return (value as? NSNumber)?.intValue
    }

    static func runningKeyGrabbers() -> [String] {
        let names = Set(NSWorkspace.shared.runningApplications.compactMap(\.localizedName))
        return keyGrabberNames.filter(names.contains)
    }

    static func freeBytes(at url: URL) -> Int64? {
        var probe = url
        // Папки может ещё не быть — меряем ближайшую существующую.
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Панели Системных настроек для кнопок «Исправить».
    public static func openKeyboardSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    public static func openStorageSettings() {
        open("x-apple.systempreferences:com.apple.settings.Storage")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}

/// Пробуждение и разблокировка — поводы прогреть модель (R6).
@MainActor
public final class WakeMonitor {
    public enum Reason: Sendable { case wake, unlock }

    private let handler: (Reason) -> Void
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    public init(handler: @escaping (Reason) -> Void) { self.handler = handler }

    public func start() {
        guard tokens.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        tokens.append((workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handler(.wake) }
        }))
        let distributed = DistributedNotificationCenter.default()
        tokens.append((distributed, distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handler(.unlock) }
        }))
    }

    public func stop() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }
}
