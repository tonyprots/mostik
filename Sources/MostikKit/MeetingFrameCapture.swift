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

    /// Самое большое окно на экране у приложения звонка, которое сейчас держит микрофон.
    public static func callWindow() async throws -> SCWindow? {
        let apps = MeetingDetector.inputProcesses(excluding: getpid())
            .compactMap { MeetingDetector.displayName(forBundleID: $0.bundleID) }
        guard let app = MeetingDetector.pick(apps) else { return nil }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let windows = content.windows.filter { window in
            guard window.windowLayer == 0, window.frame.width >= 320, window.frame.height >= 200,
                  let bundle = window.owningApplication?.bundleIdentifier else { return false }
            return MeetingDetector.displayName(forBundleID: bundle) == app
        }
        return windows.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
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
