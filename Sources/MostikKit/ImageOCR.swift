import Foundation
import ImageIO
import Vision

/// Текст с картинки локально через Vision (W23): облачная модель картинок не видит, ей идёт подпись
/// и этот текст. Ничего не отправляется; результат кладётся рядом: `<картинка>.ocr.txt`.
public enum ImageOCR {
    public static func recognize(_ url: URL, languages: [String] = ["ru-RU", "en-US"]) -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return "" }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    /// Файл рядом с картинкой, его читает движок (`meeting_ai.ocr_sidecar`).
    public static func sidecar(for image: URL) -> URL {
        image.deletingLastPathComponent().appendingPathComponent(image.lastPathComponent + ".ocr.txt")
    }
}
