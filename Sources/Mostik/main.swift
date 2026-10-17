import Foundation
import MostikCore
import MostikKit

/// `Mostik --simulate <wav> [--print] [--stream] [--language ru|en] [--project DIR]` — диктовка из файла через
/// движок (`transcribe_file`; с `--stream` — потоком, как из микрофона), без интерфейса и разрешений (сквозные тесты). Без флагов — обычный запуск приложения.
enum Simulate {
    static func run(_ args: [String]) async -> Int32 {
        guard let i = args.firstIndex(of: "--simulate"), i + 1 < args.count else {
            FileHandle.standardError.write(Data("usage: Mostik --simulate <wav> [--print] [--stream] [--language ru|en] [--project DIR]\n".utf8))
            return 2
        }
        func value(_ flag: String) -> String? {
            guard let j = args.firstIndex(of: flag), j + 1 < args.count else { return nil }
            return args[j + 1]
        }
        let wav = URL(fileURLWithPath: NSString(string: args[i + 1]).expandingTildeInPath).standardizedFileURL
        let printText = args.contains("--print")
        let paths = MostikPaths.standard
        let settings = MostikSettings.load(from: paths.settings)
        let language = value("--language") ?? settings.language
        let project = value("--project") ?? settings.codeProjectPath

        guard FileManager.default.fileExists(atPath: wav.path) else {
            FileHandle.standardError.write(Data("no such file: \(wav.path)\n".utf8))
            return 2
        }
        let client = EngineClient(config: EngineLocator.config(settings: settings, paths: paths))
        let started = Date()
        do {
            try client.start()
            _ = try await client.hello()
            let result: DictationResult
            if args.contains("--stream") {
                result = try await stream(wav, client: client, language: language, project: project)
            } else {
                result = try await client.transcribeFile(path: wav.path, language: language, project: project)
            }
            let elapsed = Date().timeIntervalSince(started)
            client.shutdownAndWait()

            if printText {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let json = String(decoding: try encoder.encode(result), as: UTF8.self)
                print(json)
                print("---")
                print(result.text)
            } else {
                print(String(format: "chars=%d doubts=%d audio_s=%.2f total_ms=%.0f wall_s=%.2f verifier=%@",
                             result.text.count, result.doubts.count, result.timings.audioS, result.timings.totalMs,
                             elapsed, result.verifier))
            }
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 1 : 0
        } catch {
            client.shutdownAndWait()
            FileHandle.standardError.write(Data("simulate failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}

final class ExitCode: @unchecked Sendable { var value: Int32 = 1 }

extension Simulate {
    /// Путь приложения: `start` → `audio` кусками по 100 мс → `stop`. Нужен WAV 16 кГц моно int16.
    static func stream(_ wav: URL, client: EngineClient, language: String, project: String?) async throws -> DictationResult {
        let data = try Data(contentsOf: wav)
        guard data.count > 44, data[22] == 1, data[34] == 16,
              Int(data[24]) | Int(data[25]) << 8 | Int(data[26]) << 16 == 16_000,
              let range = data.range(of: Data("data".utf8)) else {
            throw EngineError.engine(code: "bad_audio", message: "--stream ждёт WAV 16 кГц моно int16")  // l10n-guard: CLI-симулятор для разработчика
        }
        let pcm = data[(range.upperBound + 4)...]
        let session = "sim-" + UUID().uuidString.lowercased()
        client.startSession(session, language: language, project: project, verify: true, agent: true)
        var offset = pcm.startIndex
        while offset < pcm.endIndex {
            let end = min(offset + 3_200, pcm.endIndex)
            client.sendAudio(session: session, pcm: Data(pcm[offset..<end]))
            offset = end
        }
        // Весь файл уходит мгновенно, окна считаются после stop — таймаут §6 тут не подходит.
        let seconds = Double(pcm.count) / 32_000
        return try await client.stop(session: session, waitVerifierMs: 5_000, audioSeconds: seconds,
                                     timeout: 15 + 2 * seconds + 120)
    }
}

let arguments = CommandLine.arguments
if arguments.contains("--simulate") {
    // main остаётся синхронным: MostikApp.main() ниже держит главный поток.
    let code = ExitCode()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        code.value = await Simulate.run(arguments)
        done.signal()
    }
    done.wait()
    exit(code.value)
} else {
    MostikApp.main()
}
