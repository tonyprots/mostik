import AppKit
import ApplicationServices
import MostikCore
import MostikKit

/// Пока пишется встреча — раз в 250 мс читает в окне приложения звонка, кто подсвечен как говорящий,
/// и дописывает смены в `speaker-timeline.jsonl` папки встречи (`docs/speaker-names-research.md`).
/// Имена меткам диаризации ставит движок после расшифровки (`speaker_timeline.py`).
///
/// Источник — приложение, которое держит микрофон: Zoom (подписи плиток), десктопный Телемост
/// (нативное Qt-окно: счётчик участников, свой микрофон, название — `TelemostDesktop`, плюс журнал
/// `qt.log`) и Meet или Телемост во вкладке Chromium-браузера (DOM-классы страницы, `WebCallSpeakers`).
/// Safari, Firefox и прочие ВКС пока не читаются.
///
/// Разрешение — то же Accessibility, что и для вставки текста; без него наблюдатель молчит.
/// Дерево читается в своей очереди с таймаутом: зависшее приложение не держит главный поток.
@MainActor
final class CallSpeakerObserver {
    private static let interval: TimeInterval = 0.25
    /// Раз в столько тиков заново узнаём, кто держит микрофон: запрос к Core Audio дороже обхода.
    private static let retargetTicks = 8
    /// Обход дерева ограничен: окно галереи Zoom — сотни элементов, глубже 8 плиток не бывает.
    nonisolated static let maxDepth = 8
    nonisolated static let maxNodes = 2500
    /// Страница звонка глубже и больше: плитки Meet лежат на глубине 20–30.
    nonisolated static let webMaxDepth = 45
    nonisolated static let webMaxNodes = 5000

    /// Что читать: Zoom по подписям плиток или веб-страницу звонка в окне `window` (nil — все окна).
    enum Target: Equatable, Sendable {
        case zoom(pid_t)
        case web(pid_t, WebCallSpeakers.Kind, window: String?)
        /// Десктопный Телемост: Qt-окно звонка, не страница.
        case telemostDesktop(pid_t)
        /// Teams и Slack: говорящих в дереве не видно, только субтитры, если их включили.
        case captions(pid_t, CallCaptions.Kind)

        var source: String {
            switch self {
            case .zoom: return "zoom"
            case .web(_, let kind, _): return kind.rawValue
            case .telemostDesktop: return "telemost-desktop"
            case .captions(_, let kind): return kind.rawValue
            }
        }
        var pid: pid_t {
            switch self {
            case .zoom(let pid), .web(let pid, _, _), .telemostDesktop(let pid), .captions(let pid, _): return pid
            }
        }
        /// Дерево страницы строится только по просьбе: Chromium, Electron, WebView2.
        var isWeb: Bool {
            switch self {
            case .web, .captions: return true
            case .zoom, .telemostDesktop: return false
            }
        }
    }

    private let folder: URL
    private let elapsed: () -> Double?
    private let queue = DispatchQueue(label: "app.mostik.call-speakers", qos: .utility)
    private var timer: Timer?
    private var busy = false
    private var ticks = 0
    private var target: Target?
    private let myName: String
    private var writers: [String: SpeakerTimelineWriter] = [:]
    private var saved: String?
    /// Когда процессу последний раз выставлялись флаги доступности (номер тика): Chromium строит дерево
    /// страницы только по просьбе и не всегда с первой — просьбу повторяем раз в `enableRetryTicks`.
    private var enabledAt: [pid_t: Int] = [:]
    private static let enableRetryTicks = 20
    /// Журнал десктопного Телемоста: докуда дочитан и что в нём о текущей встрече.
    private var telemostLogOffset: UInt64?
    private var telemostLog = TelemostLog.State()
    /// Субтитры по источникам и файл `speaker-captions.jsonl`.
    private var captionTrackers: [String: CaptionTracker] = [:]
    private var captionHandle: FileHandle?
    /// Своё имя узнано на этой встрече — контроллер впишет его в Настройки, если поле пустое.
    var onLearnedName: (String) -> Void = { _ in }
    /// Можно ли смотреть на кадры окна звонка (не режим «только текст»). Разрешение «Запись экрана»
    /// проверяет `CallFrameSpeakers` сам. По умолчанию — нет.
    var framesAllowed: () -> Bool = { false }
    private let frames = CallFrameSpeakers()
    private var lastCount: Int?
    private var handle: FileHandle?
    private var dump: AXTreeDump?

    /// `elapsed` — часы встречи (как у пометок) или nil на паузе; `myName` — из Настроек → Общие.
    init(folder: URL, myName: String = "", elapsed: @escaping () -> Double?) {
        self.folder = folder
        self.elapsed = elapsed
        self.myName = myName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writer(for source: String) -> SpeakerTimelineWriter {
        writers[source] ?? SpeakerTimelineWriter(source: source, accountName: NSFullUserName(),
                                                 knownSelf: (myName.isEmpty ? [] : [myName]) + ZoomSelfNames.load())
    }

    func start() {
        guard timer == nil else { return }
        if AXTreeDump.enabled { dump = AXTreeDump(folder: folder) }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        // `AXEnhancedUserInterface` меняет поведение окон браузера (анимации, перетаскивание) — снимаем.
        let pids = Array(enabledAt.keys)
        enabledAt = [:]
        queue.async { for pid in pids { Self.disableEnhancedAccessibility(pid: pid) } }
        // Конец записи закрывает последний отрезок: молчание с этой секунды.
        if let at = elapsed(), let source = target?.source { observe(ZoomSpeakers.Snapshot(tiles: []), source: source, at: at) }
        for source in Array(captionTrackers.keys) { finishCaptions(source) }
        try? handle?.close()
        handle = nil
        try? captionHandle?.close()
        captionHandle = nil
        frames.reset()
    }

    private func tick() {
        guard !busy, AXIsProcessTrusted() else { return }
        dump?.tick(elapsed: elapsed())
        guard let at = elapsed() else {
            // Пауза: никто не говорит, после паузы снимок пишется заново.
            for key in writers.keys { writers[key]?.reset() }
            return
        }
        defer { ticks += 1 }
        if ticks % Self.retargetTicks == 0 {
            // Core Audio и окна браузера — в своей очереди: чтение окна может ждать до 0,2 с.
            busy = true
            queue.async { [weak self] in
                let next = Self.target(for: MeetingDetector.currentMeetingBundleID())
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.busy = false
                        if self.timer != nil { self.retarget(to: next) }
                    }
                }
            }
            return
        }
        guard let target else { return }
        let usesFrames = Self.usesFrames(target)
        if usesFrames { frames.poll(allowed: framesAllowed(), count: lastCount, window: Self.frameWindow(target)) }
        var enable: pid_t? = nil
        if target.isWeb, ticks - (enabledAt[target.pid] ?? -Self.enableRetryTicks) >= Self.enableRetryTicks {
            enable = target.pid
            enabledAt[target.pid] = ticks
        }
        // Журнал Телемоста — раз в секунду: строки в нём появляются при событиях, не постоянно.
        var logOffset: UInt64?? = nil
        if case .telemostDesktop = target, ticks % 4 == 1 { logOffset = .some(telemostLogOffset) }
        busy = true
        let raw = AXTreeDump.enabled
        queue.async { [weak self] in
            if let enable { Self.enableWebAccessibility(pid: enable) }
            let (snapshot, descriptions, captions, origin) = Self.snapshot(target, keepRaw: raw)
            let log = logOffset.map { Self.readTelemostLog(from: $0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.busy = false
                    guard self.timer != nil, self.target == target else { return }
                    if let log {
                        self.telemostLogOffset = log.offset
                        for event in log.events { self.telemostLog.apply(event) }
                    }
                    var snapshot = snapshot
                    if case .telemostDesktop = target { self.fillFromTelemostLog(&snapshot) }
                    if usesFrames {
                        self.lastCount = snapshot.count
                        snapshot = NamePlates.merge(snapshot, frame: self.frames.tiles)
                    }
                    if raw { self.logRaw(descriptions, at: at) }
                    self.observe(snapshot, source: target.source, at: at, learnsName: origin != .unknown)
                    self.observeCaptions(captions, source: target.source, at: at)
                }
            }
        }
    }

    private func observeCaptions(_ captions: [CallCaptions.Caption]?, source: String, at: Double) {
        guard captions != nil || captionTrackers[source] != nil else { return }
        var tracker = captionTrackers[source] ?? CaptionTracker(source: source)
        let lines = tracker.observe(captions, at: at)
        captionTrackers[source] = tracker
        lines.forEach(appendCaption)
    }

    private func finishCaptions(_ source: String) {
        guard var tracker = captionTrackers[source] else { return }
        tracker.finish().forEach(appendCaption)
        captionTrackers[source] = tracker
    }

    private func appendCaption(_ line: String) {
        if captionHandle == nil {
            let url = folder.appendingPathComponent(CaptionTracker.fileName)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            captionHandle = try? FileHandle(forWritingTo: url)
            _ = try? captionHandle?.seekToEnd()
        }
        try? captionHandle?.write(contentsOf: Data((line + "\n").utf8))
    }

    /// Кадры нужны тем, кто не отдаёт имён (Телемост) или не помечает говорящего (Zoom). Meet в браузере
    /// помечает говорящего в дереве страницы сам.
    /// Телемост в браузере — только когда известен заголовок окна со звонком: самое большое окно
    /// браузера может показывать почту или документ, и имена с них попали бы в состав.
    nonisolated static func usesFrames(_ target: Target) -> Bool {
        switch target {
        case .zoom, .telemostDesktop: return true
        case .web(_, .telemost, let window): return window != nil
        case .web, .captions: return false
        }
    }

    /// Окно для снимка, если его надо искать по заголовку (браузер); иначе — окно приложения с микрофоном.
    nonisolated static func frameWindow(_ target: Target) -> (pid: pid_t, title: String)? {
        if case .web(let pid, _, let window?) = target { return (pid, window) }
        return nil
    }

    /// Окно звонка свёрнуто или дерево не отдалось — число участников и название берём из журнала.
    private func fillFromTelemostLog(_ snapshot: inout ZoomSpeakers.Snapshot) {
        guard telemostLog.connected || telemostLog.count != nil else { return }
        if snapshot.count == nil { snapshot.count = telemostLog.count }
        if snapshot.title == nil { snapshot.title = telemostLog.meetingName }
    }

    /// Хвост `qt.log`. Первый раз — последние 256 КБ: встреча могла начаться до записи, и её название
    /// и счётчик уже в журнале.
    nonisolated static func readTelemostLog(from offset: UInt64?) -> (events: [TelemostLog.Event], offset: UInt64) {
        let url = TelemostLog.defaultURL
        let start: UInt64
        if let offset { start = offset } else {
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
            start = size > 256 << 10 ? size - (256 << 10) : 0
        }
        // Начали с середины строки: первая «строка» — обрывок, разбор её просто не узнает.
        return TelemostLog.tail(url, from: start)
    }

    /// `learnsName: false` — страница браузера, адрес которой не удалось сверить: своё имя с неё
    /// в Настройки и в память не идёт.
    private func observe(_ snapshot: ZoomSpeakers.Snapshot, source: String, at: Double, learnsName: Bool = true) {
        var writer = writer(for: source)
        let line = writer.observe(snapshot, at: at)
        writers[source] = writer
        if let line { append(line) }
        // Узнанное своё имя — сразу в память: следующая встреча узнает меня с первой секунды.
        if learnsName, let name = writer.learnedName, name != saved {
            saved = name
            ZoomSelfNames.remember(name)
            onLearnedName(name)
        }
    }

    /// Кто держит микрофон → что читать. Приложение сменилось — прежний источник закрывается тишиной.
    private func retarget(to next: Target?) {
        guard next != target else { return }
        if let old = target, let at = elapsed() { observe(ZoomSpeakers.Snapshot(tiles: []), source: old.source, at: at) }
        if let old = target { finishCaptions(old.source) }
        frames.reset()  // плашки прежнего окна к новому не относятся
        lastCount = nil
        target = next
    }

    /// Bundle id процесса с микрофоном → цель. У браузера микрофон держит вспомогательный процесс
    /// (`com.google.Chrome.helper`), окно — у основного: берём запущенное приложение с самым длинным
    /// совпадающим префиксом. Окно браузера — то, чей заголовок похож на звонок.
    nonisolated static func target(for bundle: String?) -> Target? {
        guard let bundle else { return nil }
        if bundle.hasPrefix("us.zoom."),
           let zoom = NSRunningApplication.runningApplications(withBundleIdentifier: ZoomSpeakers.bundleID).first {
            return .zoom(zoom.processIdentifier)
        }
        if bundle.hasPrefix(telemostBundleID),
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: telemostBundleID).first {
            return .telemostDesktop(app.processIdentifier)
        }
        for (prefix, kind) in captionApps where bundle.hasPrefix(prefix) {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: prefix).first {
                return .captions(app.processIdentifier, kind)
            }
        }
        guard chromiumBrowsers.contains(where: bundle.hasPrefix) else { return nil }
        let owner = NSWorkspace.shared.runningApplications
            .filter { app in app.bundleIdentifier.map { bundle.hasPrefix($0) && chromiumBrowsers.contains($0) } ?? false }
            .max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
        guard let owner else { return nil }
        let app = AXUIElementCreateApplication(owner.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        for window in AX.windows(app) {
            guard let title = AX.string(window, kAXTitleAttribute), let kind = WebCallSpeakers.kind(windowTitle: title) else { continue }
            return .web(owner.processIdentifier, kind, window: title)
        }
        return nil
    }

    nonisolated static let telemostBundleID = TelemostDesktop.bundleID
    /// Приложения, где читаем только субтитры: новый Teams (WebView2) и Slack (Electron, созвоны huddle).
    nonisolated static let captionApps: [(String, CallCaptions.Kind)] = [
        ("com.microsoft.teams2", .teams), ("com.tinyspeck.slackmacgap", .slack),
    ]
    /// Браузеры на Chromium: у них страница видна в Accessibility с DOM-классами. Safari и Firefox — нет.
    nonisolated static let chromiumBrowsers = [
        "com.google.Chrome", "com.google.Chrome.beta", "ru.yandex.desktop.yandex-browser", "company.thebrowser.Browser",
        "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]

    /// Просьба к Chromium построить дерево веб-страницы. `AXManualAccessibility` понимают Chrome и Electron;
    /// Яндекс Браузер на одном нём отдаёт пустую область страницы (снято 2026-10-23), ему и WebView2
    /// нужен ещё `AXEnhancedUserInterface` — тот же флаг, что ставит VoiceOver. Коды ответа не смотрим:
    /// флаг, который приложение не знает, просто не действует.
    nonisolated static func enableWebAccessibility(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    nonisolated static func disableEnhancedAccessibility(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
    }

    /// Только с `axDump`: сырые подписи плиток и кнопки микрофона при каждой смене — `ax-tiles.jsonl`.
    /// Видно, появляется ли «active speaker» хоть в каком-то виде окна.
    private var lastRaw: [String] = []
    private func logRaw(_ descriptions: [String], at: Double) {
        guard descriptions != lastRaw else { return }
        lastRaw = descriptions
        let row: [String: Any] = ["at": (at * 100).rounded() / 100, "desc": descriptions]
        guard let data = try? JSONSerialization.data(withJSONObject: row), let line = String(data: data, encoding: .utf8) else { return }
        let url = folder.appendingPathComponent("ax-tiles.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let file = try? FileHandle(forWritingTo: url) else { return }
        _ = try? file.seekToEnd()
        try? file.write(contentsOf: Data((line + "\n").utf8))
        try? file.close()
    }

    private func append(_ line: String) {
        if handle == nil {
            let url = folder.appendingPathComponent(SpeakerTimelineWriter.fileName)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        }
        try? handle?.write(contentsOf: Data((line + "\n").utf8))
    }

    /// Снимок цели: плитки, сырые подписи (только с `axDump`), субтитры (nil — их нет в дереве) и чья
    /// страница (`WebCallSpeakers.Origin`); у Zoom и клиента Телемоста — `.verified`: их узнают по bundle id,
    /// а не по заголовку.
    nonisolated static func snapshot(_ target: Target, keepRaw: Bool = false)
        -> (ZoomSpeakers.Snapshot, [String], [CallCaptions.Caption]?, WebCallSpeakers.Origin) {
        switch target {
        case .zoom(let pid):
            let (snapshot, raw, captions) = zoomSnapshot(pid: pid, keepRaw: keepRaw)
            return (snapshot, raw, captions, .verified)
        case .web(let pid, let kind, let window):
            var origin = WebCallSpeakers.Origin.verified
            var tree = webTree(pid: pid, window: window)
            // Окно браузера выбрано по заголовку, а заголовок задаёт страница: сверяем адрес.
            if window != nil, let found = tree {
                let screened = WebCallSpeakers.screened(found, kind: kind,
                                                         extraTelemostDomains: UserDefaults.standard.stringArray(forKey: "telemost.extraDomains") ?? [])
                tree = screened.tree
                origin = screened.origin
            }
            let snapshot = tree.map { WebCallSpeakers.snapshot($0, kind: kind) } ?? ZoomSpeakers.Snapshot(tiles: [])
            let raw = keepRaw ? snapshot.tiles.map { "\($0.name)\($0.active ? " [active]" : "")\($0.isSelf ? " [self]" : "")" } : []
            let captions = kind == .meet ? tree.flatMap { CallCaptions.captions($0, kind: .meet) } : nil
            return (snapshot, raw, captions, origin)
        case .captions(let pid, let kind):
            let captions = webTree(pid: pid, window: nil).flatMap { CallCaptions.captions($0, kind: kind) }
            return (ZoomSpeakers.Snapshot(tiles: []), keepRaw ? (captions ?? []).map { "\($0.name): \($0.text)" } : [], captions, .verified)
        case .telemostDesktop(let pid):
            let snapshot = qtTree(pid: pid).flatMap(TelemostDesktop.snapshot) ?? ZoomSpeakers.Snapshot(tiles: [])
            let raw = keepRaw ? ["count=\(snapshot.count.map(String.init) ?? "?")"]
                + snapshot.tiles.map { "\($0.name)\($0.isSelf ? " [self]" : "")" } : []
            return (snapshot, raw, nil, .verified)
        }
    }

    /// Плитки участников во всех окнах Zoom и кнопка своего микрофона: обход в ширину.
    nonisolated static func zoomSnapshot(pid: pid_t, keepRaw: Bool = false)
        -> (ZoomSpeakers.Snapshot, [String], [CallCaptions.Caption]?) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var queue: [(AXUIElement, Int)] = AX.children(app).map { ($0, 0) }
        var seen = 0
        var tiles: [ZoomSpeakers.Tile] = []
        var mine: Bool? = nil
        var raw: [String] = []
        var captions: [CallCaptions.Caption]? = nil
        while !queue.isEmpty, seen < maxNodes {
            let (element, depth) = queue.removeFirst()
            seen += 1
            if let description = AX.string(element, kAXDescriptionAttribute) {
                if description == CallCaptions.zoomContainer {
                    // Субтитры: строки внутри контейнера глубже обычного предела — читаем отдельно.
                    captions = CallCaptions.zoom(rows: zoomCaptionRows(element))
                    continue
                }
                if let tile = ZoomSpeakers.tile(from: description) {
                    tiles.append(tile)
                    if keepRaw { raw.append(description) }
                } else if mine == nil, AX.string(element, kAXIdentifierAttribute) == "audio" {
                    mine = ZoomSpeakers.myAudio(from: description)
                    if keepRaw { raw.append("[audio] " + description) }
                }
            }
            if depth < maxDepth { queue.append(contentsOf: AX.children(element).map { ($0, depth + 1) }) }
        }
        return (ZoomSpeakers.Snapshot(tiles: tiles, myUnmuted: mine), raw, captions)
    }

    /// Строки субтитров Zoom: каждая `AXRow` — тексты её ячеек по порядку [говорящий, текст…].
    nonisolated static func zoomCaptionRows(_ container: AXUIElement) -> [[String]] {
        var rows: [[String]] = []
        var budget = 400
        func texts(_ element: AXUIElement, _ depth: Int) -> [String] {
            budget -= 1
            guard budget > 0 else { return [] }
            if AX.string(element, kAXRoleAttribute) == (kAXStaticTextRole as String) {
                return [AX.string(element, kAXValueAttribute) ?? AX.string(element, kAXDescriptionAttribute)].compactMap { $0 }
            }
            guard depth < 6 else { return [] }
            return AX.children(element).flatMap { texts($0, depth + 1) }
        }
        func walk(_ element: AXUIElement, _ depth: Int) {
            guard budget > 0, depth < 6 else { return }
            for child in AX.children(element) {
                if AX.string(child, kAXRoleAttribute) == (kAXRowRole as String) {
                    rows.append(texts(child, 0))
                } else {
                    walk(child, depth + 1)
                }
            }
        }
        walk(container, 0)
        return rows
    }

    /// Qt-дерево окон десктопного Телемоста для `TelemostDesktop`: роль, `AXIdentifier`, подписи, текст.
    /// Оно маленькое (окно звонка — пара десятков элементов), но окно мессенджера рядом — веб-страница
    /// на тысячи узлов: его не обходим.
    nonisolated static let qtMaxDepth = 14
    nonisolated static let qtMaxNodes = 1500
    nonisolated static func qtTree(pid: pid_t) -> WebCallSpeakers.Node? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        let windows = AX.windows(app)
        guard !windows.isEmpty else { return nil }
        var count = 0
        func node(_ element: AXUIElement, _ depth: Int) -> WebCallSpeakers.Node {
            count += 1
            let role = AX.string(element, kAXRoleAttribute) ?? "?"
            let identifier = AX.string(element, kAXIdentifierAttribute)
            var result = WebCallSpeakers.Node(role: role, identifier: identifier)
            if role == "AXStaticText" { result.value = AX.string(element, kAXValueAttribute) }
            result.title = AX.string(element, kAXTitleAttribute)
            result.label = AX.string(element, kAXDescriptionAttribute) ?? result.title
            guard depth < qtMaxDepth, role != (kAXMenuBarRole as String),
                  identifier?.contains("Messenger::") != true else { return result }
            for child in AX.children(element) {
                guard count < qtMaxNodes else { break }
                result.children.append(node(child, depth + 1))
            }
            return result
        }
        return WebCallSpeakers.Node(role: "AXApplication", children: windows.map { node($0, 1) })
    }

    /// Дерево окон приложения (или одного окна браузера по заголовку) для `WebCallSpeakers`.
    /// Читаем только то, что нужно разбору: роль, DOM-классы групп, подписи, текст. Строку меню не обходим.
    nonisolated static func webTree(pid: pid_t, window: String?) -> WebCallSpeakers.Node? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        let windows = AX.windows(app).filter { element in
            window == nil || AX.string(element, kAXTitleAttribute) == window
        }
        guard !windows.isEmpty else { return nil }
        var count = 0
        func node(_ element: AXUIElement, _ depth: Int, measure: Bool = false, inPage: Bool = false) -> WebCallSpeakers.Node {
            count += 1
            let role = AX.string(element, kAXRoleAttribute) ?? "?"
            var result = WebCallSpeakers.Node(role: role)
            // Блоки субтитров Meet различаются только кеглем: высота нужна, чтобы найти имена.
            if measure { result.height = AX.frame(element).map { Double($0.height) } }
            if role == "AXStaticText" {
                result.value = AX.string(element, kAXValueAttribute)
                return result
            }
            if ["AXGroup", "AXGenericElement", "AXList", "AXWebArea"].contains(role) {
                result.classes = AX.value(element, "AXDOMClassList") as? [String] ?? []
            }
            if role == "AXWebArea" {
                let url = AX.value(element, "AXURL")
                result.url = (url as? URL)?.absoluteString ?? (url as? String)
            }
            if ["AXList", "AXGroup", "AXRow", "AXCell"].contains(role) {
                result.label = AX.string(element, kAXDescriptionAttribute) ?? AX.string(element, kAXTitleAttribute)
            }
            // Полоса вкладок и панели браузера — не страница: на сотнях вкладок обход кончался на них.
            // Внутри страницы не режем ничего: её вкладки (ARIA tablist) — тоже AXTabGroup.
            // Классы и подпись уже прочитаны там, где они бывают у панелей браузера, — второй раз не спрашиваем.
            guard depth < webMaxDepth, inPage || !skippedChrome(role: role, classes: result.classes, label: result.label)
            else { return result }
            let captions = result.label == "Captions"
            let page = inPage || role == "AXWebArea"
            for child in AX.children(element) {
                guard count < webMaxNodes else { break }
                result.children.append(node(child, depth + 1, measure: captions, inPage: page))
            }
            return result
        }
        return WebCallSpeakers.Node(role: "AXApplication", children: windows.map { node($0, 1) })
    }
}

/// Идёт ли конспект в десктопном Телемосте: ищем кнопку ИИ в окне звонка (`TelemostSummary`).
/// Веб-области (мессенджер) не обходим. nil — Телемост не запущен, кнопки нет или подпись непонятна.
enum TelemostSummaryProbe {
    /// Сначала журнал Телемоста (`TelemostSummary.fromLog`), кнопка в окне — запасной признак.
    nonisolated static func isOn() -> Bool? {
        if let state = fromLog() { return state }
        return fromButton()
    }

    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Yandex.Telemost/log/telemost_gui.log")

    /// Хвост журнала: начала звонка хватает с запасом, весь файл — мегабайты.
    nonisolated static func fromLog(_ url: URL = logURL, tail: UInt64 = 2 << 20) -> Bool? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > tail ? size - tail : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return TelemostSummary.fromLog(Substring(String(decoding: data, as: UTF8.self)))
    }

    nonisolated static func fromButton() -> Bool? {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: CallSpeakerObserver.telemostBundleID).first
        else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.2)
        var count = 0
        func find(_ element: AXUIElement, _ depth: Int) -> AXUIElement? {
            count += 1
            let role = AX.string(element, kAXRoleAttribute)
            if role == "AXButton", AX.string(element, kAXIdentifierAttribute)?.hasSuffix(TelemostSummary.buttonSuffix) == true {
                return element
            }
            guard role != "AXWebArea", depth < CallSpeakerObserver.webMaxDepth else { return nil }
            for child in AX.children(element) {
                guard count < CallSpeakerObserver.webMaxNodes else { return nil }
                if let hit = find(child, depth + 1) { return hit }
            }
            return nil
        }
        for window in AX.windows(root) {
            if let button = find(window, 1) {
                return TelemostSummary.isOn(title: AX.string(button, kAXTitleAttribute),
                                            description: AX.string(button, kAXDescriptionAttribute))
            }
        }
        return nil
    }
}

/// Части окна браузера вокруг страницы: строка меню, панели инструментов и полоса вкладок.
nonisolated func skippedChrome(role: String, classes: [String]?, label: String?) -> Bool {
    if role == (kAXMenuBarRole as String) || role == (kAXToolbarRole as String) || role == (kAXTabGroupRole as String) { return true }
    if let classes, classes.contains(where: { $0.hasPrefix("Tabs") || $0 == "TabStrip" || $0 == "BookmarkBarView" }) { return true }
    return label == "Tabs"
}

/// Свои имена в Zoom между встречами: последние несколько, новое — первым.
/// Хранятся в настройках приложения на этом Mac, никуда не уходят.
enum ZoomSelfNames {
    private static let key = "zoom.selfNames"
    static let limit = 5

    static func load(_ defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    static func remember(_ name: String, _ defaults: UserDefaults = .standard) {
        let clean = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !clean.isEmpty else { return }
        var names = load(defaults).filter { $0.lowercased() != clean.lowercased() }
        names.insert(clean, at: 0)
        defaults.set(Array(names.prefix(limit)), forKey: key)
    }

    /// Своё имя из лент прошлых встреч (`self` в `speaker-timeline.jsonl`), самое свежее; нет — nil.
    /// Для встреч до памяти между встречами: их «я» узнано, но нигде больше не записано.
    static func fromMeetings(_ root: URL) -> String? {
        let folders = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted(by: >)
        for folder in folders.prefix(50) {
            let url = root.appendingPathComponent(folder).appendingPathComponent(SpeakerTimelineWriter.fileName)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").reversed() {
                guard let data = line.data(using: .utf8),
                      let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let own = row["self"] as? [String], let name = own.first, !name.isEmpty else { continue }
                return name
            }
        }
        return nil
    }
}

/// Тонкие обёртки над AXUIElement.
enum AX {
    static func value(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        guard let text = value(element, name) as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    static func windows(_ app: AXUIElement) -> [AXUIElement] {
        value(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = value(element, kAXPositionAttribute), let size = value(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }
}

/// Снимок дерева Accessibility приложений звонка — чтобы на живом звонке увидеть, где имена
/// и признак «говорит». Только по флагу: `defaults write app.mostik.mac axDump -bool true`.
/// Пишет в папку встречи `ax-dump-<источник>-<секунда>.txt` на 15-й, 40-й и 90-й секунде записи:
/// Zoom и Телемост, если запущены, и окна Chromium-браузеров, чей заголовок похож на Meet или Телемост
/// (другие окна браузера не читаются). Внутри — имена участников, у Телемоста ещё и текст открытых
/// чатов: файл остаётся на этом Mac.
@MainActor
final class AXTreeDump {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "axDump") }
    private static let moments: [Double] = [15, 40, 90]
    nonisolated static let maxNodes = 8000
    nonisolated static let maxDepth = 50

    private let folder: URL
    private var pending = moments
    private var running = false

    init(folder: URL) { self.folder = folder }

    /// Что снимать сейчас: тег файла, процесс и (для браузера) заголовок окна.
    nonisolated static func targets() -> [(tag: String, target: CallSpeakerObserver.Target)] {
        var result: [(String, CallSpeakerObserver.Target)] = []
        if let zoom = NSRunningApplication.runningApplications(withBundleIdentifier: ZoomSpeakers.bundleID).first {
            result.append(("zoom", .zoom(zoom.processIdentifier)))
        }
        let bundle = CallSpeakerObserver.telemostBundleID
        if let telemost = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
            result.append(("telemost", .telemostDesktop(telemost.processIdentifier)))
        }
        for (bundle, kind) in CallSpeakerObserver.captionApps {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
                result.append((kind.rawValue, .captions(app.processIdentifier, kind)))
            }
        }
        for browser in CallSpeakerObserver.chromiumBrowsers {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: browser) {
                let pid = app.processIdentifier
                // Заголовки окон видны и так; `AXEnhancedUserInterface` ставим только окну со звонком
                // (и снимаем после снимка) — браузер без звонка не трогаем.
                let element = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(element, 0.5)
                AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                for window in AX.windows(element) {
                    guard let title = AX.string(window, kAXTitleAttribute),
                          let kind = WebCallSpeakers.kind(windowTitle: title) else { continue }
                    result.append(("\(kind.rawValue)-web", .web(pid, kind, window: title)))
                }
            }
        }
        return result
    }

    func tick(elapsed: Double?) {
        guard !running, let at = elapsed, let next = pending.first, at >= next else { return }
        pending.removeFirst()
        running = true
        let folder = folder
        DispatchQueue.global(qos: .utility).async {
            for (tag, target) in Self.targets() {
                if target.isWeb { CallSpeakerObserver.enableWebAccessibility(pid: target.pid) }
                var window: String? = nil
                if case .web(_, _, let title) = target { window = title }
                var text = Self.render(pid: target.pid, window: window)
                // Что видит наблюдатель и сколько стоит обход: на звонке видно, успевает ли он за 250 мс.
                let started = Date()
                let snapshot = CallSpeakerObserver.snapshot(target).0
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                let found = snapshot.tiles.enumerated().map { index, tile in
                    "\(tile.name)\(tile.active ? " [active]" : "")\(tile.unmuted == true ? " [unmuted]" : "")"
                        + "\(index == snapshot.selfIndex ? " [self]" : "")"
                }
                let me = snapshot.myUnmuted.map { $0 ? "unmuted" : "muted" } ?? "?"
                text = "# tiles (\(ms) ms, me \(me)): \(found.joined(separator: "; "))\n" + text
                if target.isWeb { CallSpeakerObserver.disableEnhancedAccessibility(pid: target.pid) }
                let url = folder.appendingPathComponent("ax-dump-\(tag)-\(Int(at)).txt")
                FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.running = false } }
        }
    }

    /// Строка на элемент: отступ по глубине, роль, подроль, текстовые атрибуты, DOM-классы и id, рамка.
    /// `window` — снять только окно с этим заголовком (вкладка браузера со звонком).
    nonisolated static func render(pid: pid_t, window: String? = nil) -> String {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        // Chromium и Qt строят полное дерево только по просьбе вспомогательного приложения.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var lines: [String] = ["# pid \(pid), \(Date())" + (window.map { ", window \"\($0)\"" } ?? "")]
        var count = 0
        func walk(_ element: AXUIElement, _ depth: Int, inPage: Bool = false) {
            guard count < maxNodes else { return }
            count += 1
            var parts = [AX.string(element, kAXRoleAttribute) ?? "?"]
            if let subrole = AX.string(element, kAXSubroleAttribute) { parts.append("[\(subrole)]") }
            for (key, name) in [("title", kAXTitleAttribute), ("desc", kAXDescriptionAttribute),
                                ("value", kAXValueAttribute), ("help", kAXHelpAttribute),
                                ("id", kAXIdentifierAttribute), ("label", "AXLabel"), ("dom", "AXDOMIdentifier")] {
                if let text = AX.string(element, name) {
                    parts.append("\(key)=\"\(String(text.prefix(160)).replacingOccurrences(of: "\n", with: " "))\"")
                }
            }
            let classes = AX.value(element, "AXDOMClassList") as? [String]
            if let classes, !classes.isEmpty {
                parts.append("class=\"\(classes.prefix(12).joined(separator: " "))\"")
            }
            if let frame = AX.frame(element) {
                parts.append("@\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height))")
            }
            lines.append(String(repeating: "  ", count: depth) + parts.joined(separator: " "))
            // Строку меню не обходим: там «Недавние объекты» с именами файлов, а про звонок ничего.
            // Полосу вкладок браузера тоже: 900 вкладок съедали весь запас узлов до страницы.
            // Внутри страницы не режем: её собственные вкладки — тоже AXTabGroup.
            let role = parts[0]
            if depth < maxDepth, inPage || !skippedChrome(role: role, classes: classes,
                                                          label: AX.string(element, kAXDescriptionAttribute)) {
                for child in AX.children(element) { walk(child, depth + 1, inPage: inPage || role == "AXWebArea") }
            }
        }
        if let window {
            lines.append("AXApplication")
            for element in AX.windows(app) where AX.string(element, kAXTitleAttribute) == window { walk(element, 1) }
        } else {
            walk(app, 0)
        }
        if count >= maxNodes { lines.append("# truncated at \(maxNodes) elements") }
        return lines.joined(separator: "\n") + "\n"
    }
}
