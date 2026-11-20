import AppKit
import MostikCore
import MostikKit
import ScreenCaptureKit
import Vision

/// Имена и «кто говорит» по кадру окна звонка (`NamePlates`): десктопный Телемост имён в Accessibility
/// не отдаёт, а галерея Zoom не помечает говорящего — но оба пишут имя на плашке плитки и обводят
/// говорящего рамкой. Раз в секунду снимаем окно звонка в память, раз в пять секунд читаем на нём
/// текст (Vision, на этом Mac), между чтениями только проверяем рамки у найденных плашек.
///
/// Ничего не сохраняется и никуда не уходит: кадр живёт до конца проверки. Работает, только если
/// «Запись экрана» уже разрешена (сами не просим — это делает переключатель кадров встречи)
/// и встреча не в режиме «только текст».
@MainActor
final class CallFrameSpeakers {
    /// Снимок окна — не чаще.
    static let captureInterval: TimeInterval = 1
    /// Распознавание текста — раз во столько снимков: оно в десять раз дороже снимка.
    static let ocrEvery = 5
    /// Результат старше — не используем: окно закрыли или снимки встали.
    static let freshness: TimeInterval = 3

    private var tracker = NamePlates.Tracker()
    private var plates: [NamePlates.Plate] = []
    private var captures = 0
    private var running = false
    private var lastCapture = Date.distantPast
    private var latest: (tiles: [ZoomSpeakers.Tile], at: Date)?
    private var window: (window: SCWindow, found: Date)?
    private var loggedStart = false
    private var count: Int?
    /// Номер сброса: снимок, начатый до `reset()`, относится к прежнему окну и отбрасывается.
    private var generation = 0
    /// Окно звонка, если наблюдатель его знает: процесс и заголовок (вкладка браузера со звонком).
    private var target: (pid: pid_t, title: String)?

    /// Свежие плитки из кадра (имя + рамка) или пусто.
    var tiles: [ZoomSpeakers.Tile] {
        guard let latest, Date().timeIntervalSince(latest.at) <= Self.freshness else { return [] }
        return latest.tiles
    }

    /// Вызывать на каждом тике наблюдателя; сам решает, пора ли снимать.
    /// `count` — сколько людей в звонке по счётчику клиента, если известно: лишние плашки отсеиваются.
    /// `window` — процесс и заголовок окна звонка, когда приложение держит несколько окон (браузер):
    /// иначе снимается самое большое окно приложения с микрофоном, а у браузера это может быть не звонок.
    func poll(allowed: Bool, count: Int? = nil, window target: (pid: pid_t, title: String)? = nil) {
        self.count = count
        if let target, self.target.map({ $0.pid != target.pid || $0.title != target.title }) ?? true {
            window = nil  // вкладку со звонком перенесли или переключили: окно ищем заново
        }
        self.target = target
        guard allowed, MeetingFrameCapture.permissionGranted else {
            if latest != nil { reset() }
            return
        }
        guard !running, Date().timeIntervalSince(lastCapture) >= Self.captureInterval else { return }
        running = true
        lastCapture = Date()
        let readText = captures % Self.ocrEvery == 0 || plates.isEmpty && captures % 2 == 0
        captures += 1
        let cached = window.flatMap { Date().timeIntervalSince($0.found) < 10 ? $0.window : nil }
        let known = plates
        let started = generation
        Task { [weak self] in
            let result = await Self.inspect(window: cached, target: target, readText: readText, known: known)
            guard let self else { return }
            self.running = false
            guard self.generation == started else { return }  // окно сменилось, пока снимали
            self.apply(result)
        }
    }

    func reset() {
        generation += 1
        target = nil
        tracker.reset()
        plates = []
        latest = nil
        window = nil
    }

    private struct Inspection: @unchecked Sendable {  // SCWindow — неизменяемый снимок, как в `MeetingFrameCapture`
        var window: SCWindow?
        var plates: [NamePlates.Plate]?
        var tiles: [ZoomSpeakers.Tile]
    }

    private func apply(_ result: Inspection?) {
        guard let result else {
            window = nil
            return
        }
        if let found = result.window { window = (found, window?.window === found ? window!.found : Date()) }
        var tiles = result.tiles
        if let found = result.plates {
            plates = NamePlates.select(tracker.update(found), count: count)
            // Рамки уже посчитаны по всем найденным плашкам — оставляем устойчивые.
            let keys = Set(plates.map { $0.name.lowercased() })
            tiles = tiles.filter { keys.contains($0.name.lowercased()) }
            if !loggedStart, !plates.isEmpty {
                loggedStart = true
                AppLog.shared.event("speakers", "frame plates: \(plates.count)")
            }
        }
        latest = (tiles, Date())
    }

    /// Снимок окна → плашки (если читаем текст) и плитки с рамками. Ошибка снимка — nil.
    private nonisolated static func inspect(window cached: SCWindow?, target: (pid: pid_t, title: String)?,
                                            readText: Bool, known: [NamePlates.Plate]) async -> Inspection? {
        var window = cached
        if window == nil, let target {
            window = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true).windows
                .first { $0.owningApplication?.processID == target.pid && $0.title == target.title }
        } else if window == nil {
            window = try? await MeetingFrameCapture.findCallWindow().window
        }
        guard let window, let image = try? await MeetingFrameCapture.capture(window) else { return nil }
        let pixels = Self.pixels(image)
        if readText {
            let found = NamePlates.plates(recognize(image), in: pixels)
            return Inspection(window: window, plates: found, tiles: NamePlates.tiles(found, in: pixels))
        }
        return Inspection(window: window, plates: nil, tiles: NamePlates.tiles(known, in: pixels))
    }

    /// Кадр в RGBA по 8 бит, строки сверху вниз.
    nonisolated static func pixels(_ image: CGImage) -> NamePlates.Pixels {
        let width = image.width, height = image.height, row = width * 4
        var data = [UInt8](repeating: 0, count: row * height)
        data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: row, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return NamePlates.Pixels(width: width, height: height, bytesPerRow: row, data: data)
    }

    /// Строки текста на кадре. Точный режим: быстрый путает кириллицу («з» → «3»).
    nonisolated static func recognize(_ image: CGImage) -> [NamePlates.Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ru-RU", "en-US"]
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let width = CGFloat(image.width), height = CGFloat(image.height)
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox  // нормированная, начало — левый нижний угол
            return NamePlates.Line(text: text, x: Int(box.minX * width), y: Int((1 - box.maxY) * height),
                                   width: Int(box.width * width), height: Int(box.height * height))
        }
    }
}
