import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import MostikCore

/// Кадры окна звонка (W26) через ScreenCaptureKit. Снимается только окно приложения, которое держит
/// микрофон (как в `MeetingDetector`), не весь экран и не курсор. Разрешение «Запись экрана» запрашивается
/// только по действию пользователя (`Permissions.openScreenCapture`); `permissionGranted` лишь проверяет.
/// Решения «снимать ли» и «новый ли кадр» — в MostikCore (`FrameDecision`, `FrameDelta`).
public enum MeetingFrameCapture {
    /// Проверка без запроса.
    public static var permissionGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Панель «Запись экрана» в Системных настройках — по кнопке пользователя; выдаёт разрешение он сам.
    /// Через `openScreenCapture`: без системного запроса Mostik не появляется в списке панели,
    /// и включить там нечего.
    public static func openPermissionSettings() { Permissions.openScreenCapture() }

    /// Окно звонка и как его искали — для журнала: «не снимается» без причины не разобрать (2026-10-21).
    public struct WindowLookup: @unchecked Sendable {  // SCWindow — неизменяемый снимок
        public var window: SCWindow?
        /// Приложение с микрофоном (`MeetingDetector.pick`), nil — микрофон никто из ВКС не держит.
        public var micApp: String?
        /// По какому правилу нашли: `mic` — окно приложения с микрофоном, `fallback` — самое большое окно ВКС.
        public var rule: String
        public var candidates: Int
    }

    /// Самое большое окно на экране у приложения звонка, которое сейчас держит микрофон.
    public static func callWindow() async throws -> SCWindow? { try await findCallWindow().window }

    /// Сначала — окно приложения с микрофоном. Не нашлось (микрофон у вспомогательного процесса,
    /// окно ВКС другого bundle id) — самое большое окно известного приложения ВКС на экране; браузер
    /// в запасном пути не берём: его окно с микрофоном не обязательно звонок.
    public static func findCallWindow() async throws -> WindowLookup {
        let apps = MeetingDetector.inputProcesses(excluding: getpid())
            .compactMap { MeetingDetector.displayName(forBundleID: $0.bundleID) }
        let micApp = MeetingDetector.pick(apps)
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let sized = content.windows.filter { $0.windowLayer == 0 && $0.frame.width >= 320 && $0.frame.height >= 200 }
        func name(_ window: SCWindow) -> String? {
            window.owningApplication.flatMap { MeetingDetector.displayName(forBundleID: $0.bundleIdentifier) }
        }
        func largest(_ list: [SCWindow]) -> SCWindow? {
            list.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        }
        if let micApp {
            let own = sized.filter { name($0) == micApp }
            if let window = largest(own) {
                return WindowLookup(window: window, micApp: micApp, rule: "mic", candidates: own.count)
            }
        }
        let browserNames = Set(MeetingDetector.browsers.map(\.name))
        let calls = sized.filter { name($0).map { !browserNames.contains($0) } ?? false }
        return WindowLookup(window: largest(calls), micApp: micApp, rule: "fallback", candidates: calls.count)
    }

    /// Снимок одного окна, не шире `maxWidth` пикселей, без курсора.
    public static func capture(_ window: SCWindow, maxWidth: Int = 1600) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let pixels = CGSize(width: filter.contentRect.width * CGFloat(filter.pointPixelScale),
                            height: filter.contentRect.height * CGFloat(filter.pointPixelScale))
        let scale = min(1, CGFloat(maxWidth) / max(1, pixels.width))
        config.width = max(1, Int(pixels.width * scale))
        config.height = max(1, Int(pixels.height * scale))
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Уменьшенная копия 64×36 в оттенках серого — вход `FrameDelta`.
    public static func thumbnail(_ image: CGImage, width: Int = 64, height: Int = 36) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : []
    }

    /// JPEG в папку кадров встречи. Ничего никуда не отправляется.
    @discardableResult
    public static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.8) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}
