import CoreAudio
import Foundation

/// Определяет начало и конец созвона по тому, кто пишет с микрофона (§12.8).
///
/// Раз в 2 секунды берёт `kAudioHardwarePropertyProcessObjectList` и у каждого
/// процесса смотрит `kAudioProcessPropertyIsRunningInput`. Свой PID
/// исключается — тёплый микрофон Mostik детектор не обманывает. Если вход
/// держит известное приложение ВКС или браузер, `onChange` получает его
/// название; когда микрофон отпущен — `nil`. Колбэк вызывается только на
/// переходах и всегда на главной очереди. Разрешений не требует.
public final class MeetingDetector: @unchecked Sendable {
    private let onChange: (String?) -> Void
    private let queue = DispatchQueue(label: "mostik.meeting.detector", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var current: String?
    private let ownPID = getpid()

    public init(onChange: @escaping (String?) -> Void) {
        self.onChange = onChange
    }

    deinit { timer?.cancel() }

    public func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .seconds(2), leeway: .milliseconds(500))
            source.setEventHandler { [weak self] in self?.poll() }
            timer = source
            source.resume()
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            current = nil
        }
    }

    /// Название приложения, которое сейчас держит микрофон, или nil.
    public func currentMeetingApp() -> String? {
        let apps = Self.inputProcesses(excluding: ownPID).compactMap { Self.displayName(forBundleID: $0.bundleID) }
        return Self.pick(apps)
    }

    /// Bundle id приложения звонка, которое сейчас держит микрофон (тот же выбор, что у
    /// `currentMeetingApp`), или nil. По нему наблюдатель говорящих выбирает, чьё окно читать.
    public static func currentMeetingBundleID(excluding pid: pid_t = getpid()) -> String? {
        let bundles = inputProcesses(excluding: pid).map(\.bundleID).filter { displayName(forBundleID: $0) != nil }
        let browserPrefixes = browsers.map(\.prefix)
        return bundles.first { bundle in !browserPrefixes.contains(where: bundle.hasPrefix) } ?? bundles.first
    }

    private func poll() {
        let app = currentMeetingApp()
        guard app != current else { return }
        current = app
        let callback = onChange
        DispatchQueue.main.async { callback(app) }
    }

    // MARK: - Процессы Core Audio

    struct InputProcess {
        let pid: pid_t
        let bundleID: String
    }

    static func inputProcesses(excluding ownPID: pid_t) -> [InputProcess] {
        let objects = CoreAudioQuery.objectList(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList
        )
        var result: [InputProcess] = []
        for object in objects {
            guard CoreAudioQuery.uint32(object, kAudioProcessPropertyIsRunningInput) == 1 else { continue }
            let pid = pid(of: object)
            guard pid != ownPID else { continue }
            let bundle = CoreAudioQuery.string(object, kAudioProcessPropertyBundleID) ?? ""
            result.append(InputProcess(pid: pid, bundleID: bundle))
        }
        return result
    }

    private static func pid(of object: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : -1
    }

    // MARK: - Справочник приложений

    /// Префикс bundle id → название. Префикс ловит и вспомогательные процессы
    /// (`com.google.Chrome.helper`, `us.zoom.CptHost` у Zoom — отдельно).
    static var meetingApps: [(prefix: String, name: String)] { [
        ("us.zoom.", "Zoom"),
        ("ru.yandex.desktop.telemost", L("Телемост", "Telemost")),
        ("com.microsoft.teams", "Microsoft Teams"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.apple.avconferenced", "FaceTime"),
        ("com.hnc.Discord", "Discord"),
        ("com.skype.", "Skype"),
        ("com.microsoft.SkypeForBusiness", L("Skype для бизнеса", "Skype for Business")),
        ("ru.mail.messenger-biz", "VK Teams"),
        ("com.cisco.webexmeetings", "Webex"),
        ("Cisco-Systems.Spark", "Webex"),
        ("com.tdesktop.Telegram", "Telegram"),
        ("ru.keepcoder.Telegram", "Telegram"),
        ("net.whatsapp.WhatsApp", "WhatsApp"),
    ] }

    /// Браузеры: Meet, Телемост и прочие веб-ВКС видны только как браузер.
    static var browsers: [(prefix: String, name: String)] { [
        ("com.google.Chrome", "Google Chrome"),
        ("ru.yandex.desktop.yandex-browser", L("Яндекс Браузер", "Yandex Browser")),
        ("com.apple.Safari", "Safari"),
        ("com.apple.WebKit", "Safari"),
        ("company.thebrowser.Browser", "Arc"),
        ("org.mozilla.firefox", "Firefox"),
        ("com.microsoft.edgemac", "Microsoft Edge"),
        ("com.brave.Browser", "Brave"),
        ("com.operasoftware.Opera", "Opera"),
        ("com.vivaldi.Vivaldi", "Vivaldi"),
    ] }

    static func displayName(forBundleID bundleID: String) -> String? {
        guard !bundleID.isEmpty else { return nil }
        for entry in meetingApps + browsers where bundleID.hasPrefix(entry.prefix) {
            return entry.name
        }
        return nil
    }

    /// Нативное приложение ВКС важнее браузера: открытая вкладка с микрофоном
    /// реже бывает созвоном, чем запущенный Zoom.
    static func pick(_ names: [String]) -> String? {
        let browserNames = Set(browsers.map(\.name))
        return names.first { !browserNames.contains($0) } ?? names.first
    }
}
