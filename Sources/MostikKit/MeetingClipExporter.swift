import AVFoundation
import Foundation
import MostikCore

/// Фрагмент для пересылки (W9): отрезок обеих дорожек, сведённый в моно, → `.m4a` (AAC) рядом с `.md`.
/// Ничего не отправляет: файлы ложатся в `<встреча>/clips/`.
public enum MeetingClipExporter {
    public enum Failure: LocalizedError {
        case noAudio
        case encoder(String)
        public var errorDescription: String? {
            switch self {
            case .noAudio: return L("Аудио встречи нет: только текст", "No meeting audio: text only")
            case let .encoder(why): return L("Не удалось сохранить звук: \(why)", "Couldn’t save audio: \(why)")
            }
        }
    }

    static let rate = 16_000
    static let header = 44

    /// Сохранить фрагмент. Возвращает (m4a или nil, md). Аудио нет — только `.md`.
    public static func export(folder: URL, plan: MeetingClipPlan, segments: [MeetingSegment]) throws -> (audio: URL?, text: URL) {
        let clips = folder.appendingPathComponent("clips", isDirectory: true)
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        let stem = uniqueStem(plan.stem, in: clips)
        let textURL = clips.appendingPathComponent(stem + ".md")
        let audioURL = clips.appendingPathComponent(stem + ".m4a")
        var audio: URL? = audioURL
        do {
            let samples = try mix(folder: folder, segments: segments, start: plan.start, end: plan.end)
            try writeAAC(samples, to: audioURL)
        } catch Failure.noAudio {
            audio = nil
        }
        var markdown = plan.markdown
        if audio == nil {
            // Ссылка на несуществующий звук хуже, чем её отсутствие.
            markdown = markdown.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.contains("](\(plan.stem).m4a)") }.joined(separator: "\n")
        } else if stem != plan.stem {
            markdown = markdown.replacingOccurrences(of: plan.stem + ".m4a", with: stem + ".m4a")
        }
        try markdown.write(to: textURL, atomically: true, encoding: .utf8)
        return (audio, textURL)
    }

    static func uniqueStem(_ stem: String, in folder: URL) -> String {
        var candidate = stem
        var index = 2
        let fm = FileManager.default
        while fm.fileExists(atPath: folder.appendingPathComponent(candidate + ".md").path)
            || fm.fileExists(atPath: folder.appendingPathComponent(candidate + ".m4a").path) {
            candidate = "\(stem)-\(index)"
            index += 1
        }
        return candidate
    }

    /// Обе дорожки на отрезке [start, end), сложенные с потолком: Float −1…1.
    static func mix(folder: URL, segments: [MeetingSegment], start: Double, end: Double) throws -> [Float] {
        let count = Int((end - start) * Double(rate))
        guard count > 0 else { throw Failure.noAudio }
        var out = [Float](repeating: 0, count: count)
        var found = false
        for track in MeetingWatchdog.Track.allCases {
            var segs = segments.filter { $0.track == track }
            if segs.isEmpty { segs = [MeetingSegment(track: track, file: MeetingSegment.fileName(track, index: 1), offset: 0)] }
            var lengths: [String: Double] = [:]
            for seg in segs {
                let size = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(seg.file).path)[.size] as? Int) ?? 0
                if size > header { lengths[seg.file] = Double((size - header) / 2) / Double(rate) }
            }
            for piece in MeetingClipPlan.pieces(segments: segs, lengths: lengths, start: start, end: end) {
                guard let handle = try? FileHandle(forReadingFrom: folder.appendingPathComponent(piece.file)) else { continue }
                defer { try? handle.close() }
                let first = Int(piece.fileOffset * Double(rate))
                let frames = Int(piece.length * Double(rate))
                try handle.seek(toOffset: UInt64(header + first * 2))
                guard let data = try handle.read(upToCount: frames * 2), !data.isEmpty else { continue }
                found = true
                let target = Int(piece.clipOffset * Double(rate))
                data.withUnsafeBytes { raw in
                    let pcm = raw.bindMemory(to: Int16.self)
                    for i in 0..<min(pcm.count, count - target) where target + i >= 0 {
                        out[target + i] += Float(Int16(littleEndian: pcm[i])) / 32768
                    }
                }
            }
        }
        guard found else { throw Failure.noAudio }
        for i in out.indices { out[i] = max(-1, min(1, out[i])) }
        return out
    }

    static func writeAAC(_ samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1,
                                         interleaved: false) else { throw Failure.encoder(L("формат", "format")) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Double(rate),
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000,
        ]
        try? FileManager.default.removeItem(at: url)
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let chunk = rate * 10
            var index = 0
            while index < samples.count {
                let n = min(chunk, samples.count - index)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
                      let channel = buffer.floatChannelData?[0] else { throw Failure.encoder(L("буфер", "buffer")) }
                samples.withUnsafeBufferPointer { src in
                    channel.update(from: src.baseAddress! + index, count: n)
                }
                buffer.frameLength = AVAudioFrameCount(n)
                try file.write(from: buffer)
                index += n
            }
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure.encoder(error.localizedDescription)
        }
    }
}
