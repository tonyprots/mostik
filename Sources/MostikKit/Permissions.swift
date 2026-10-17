import AppKit
import ApplicationServices
import AVFoundation

/// Разрешения macOS. Проверки ничего не спрашивают; запросы вызываются
/// только по клику пользователя в интерфейсе.
public enum Permissions {
    public static var microphoneAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Пользователь ещё не отвечал на запрос микрофона.
    public static var microphoneUndetermined: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }

    public static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Публичной проверки разрешения «только звук системы» нет: помним, что системная дорожка встречи
    /// хоть раз прозвучала (`MeetingWatchdog.systemHeard`). Раньше флаг ставился, как только запись
    /// стартовала, — до ответа на системный запрос и при отказе тоже.
    public static var systemAudioGranted: Bool {
        get { UserDefaults.standard.bool(forKey: "mostik.systemAudioGranted") }
        set { UserDefaults.standard.set(newValue, forKey: "mostik.systemAudioGranted") }
    }

    /// Последняя встреча писалась без звука системы при живом микрофоне — похоже на отказ.
    public static var systemAudioSilent: Bool {
        get { UserDefaults.standard.bool(forKey: "mostik.systemAudioSilent") }
        set { UserDefaults.standard.set(newValue, forKey: "mostik.systemAudioSilent") }
    }

    /// Системный запрос микрофона; если уже отказано — открываем Настройки.
    public static func requestMicrophone(completion: @escaping @Sendable (Bool) -> Void = { _ in }) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in completion(granted) }
        case .authorized:
            completion(true)
        default:
            openSettings("Privacy_Microphone")
            completion(false)
        }
    }

    /// Запрос Accessibility. Первый раз — только системный диалог: он вносит Mostik в список и сам
    /// ведёт в Настройки. Раньше вместе с ним открывалась и панель — два окна сразу.
    /// Дальше диалог macOS не повторяет, поэтому — панель.
    public static func requestAccessibility() {
        guard !AXIsProcessTrusted() else { return }
        let asked = "mostik.accessibilityPrompted"
        if UserDefaults.standard.bool(forKey: asked) {
            openSettings("Privacy_Accessibility")
        } else {
            UserDefaults.standard.set(true, forKey: asked)
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
    }

    /// Звук системы для встреч. На macOS 15+ разрешение живёт в «Записи экрана и системного звука»
    /// (раздел «Только системный звук») — это якорь `Privacy_ScreenCapture`; `Privacy_AudioCapture`
    /// там не документирован. На 14.x — прежний якорь; не откроется — macOS покажет «Конфиденциальность».
    /// Проверить вживую на обеих версиях.
    public static func requestSystemAudio() {
        openSettings(systemAudioAnchor())
    }

    public static func systemAudioAnchor(_ version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> String {
        version.majorVersion >= 15 ? "Privacy_ScreenCapture" : "Privacy_AudioCapture"
    }

    /// Право слать нажатия (вставка ⌘V). Проверка без запроса.
    public static var postEventsGranted: Bool { CGPreflightPostEventAccess() }

    /// «Запись экрана» — для кадров окна звонка (W26). Проверка без запроса.
    public static var screenCaptureGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// «Запись экрана» по кнопке пользователя. Без `CGRequestScreenCaptureAccess` macOS не вносит Mostik
    /// в список панели, и включить там нечего (отзыв автора). Запрос показывает системное окно
    /// один раз; дальше — только панель.
    public static func openScreenCapture() {
        if !CGPreflightScreenCaptureAccess(), CGRequestScreenCaptureAccess() { return }
        openSettings("Privacy_ScreenCapture")
    }

    public static func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
