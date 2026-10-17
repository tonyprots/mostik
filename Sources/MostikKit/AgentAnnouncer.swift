import AppKit
import AVFoundation
import Foundation
import MostikCore

/// Озвучка хода агента (A1) системным голосом macOS: сначала звук события, потом фраза.
/// Голос — по языку фразы: кириллица → русский, иначе английский.
@MainActor
public final class AgentAnnouncer {
    private let synthesizer = AVSpeechSynthesizer()

    /// Выбранные голоса (A1) — идентификаторы `AVSpeechSynthesisVoice`; nil — лучший установленный.
    public var voiceRU: String?
    public var voiceEN: String?

    public init() {}

    /// Голос языка: выбранный, если ещё установлен, иначе лучший установленный (Premium → Enhanced → обычный).
    public func voice(russian: Bool) -> AVSpeechSynthesisVoice? {
        let pick = SystemVoicePick.best(SystemVoices.installed(), language: russian ? "ru" : "en",
                                        chosen: russian ? voiceRU : voiceEN)
        return pick.flatMap { AVSpeechSynthesisVoice(identifier: $0.id) }
            ?? AVSpeechSynthesisVoice(language: russian ? "ru-RU" : "en-US")
    }

    /// Прослушать голос в настройках: фраза без звука события.
    public func preview(_ text: String, voice identifier: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: identifier)
        synthesizer.speak(utterance)
    }

    public func announce(_ text: String, kind: AgentEventKind) {
        NSSound(named: NSSound.Name(AgentEvents.sound(kind)))?.play()
        guard !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        let russian = text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        utterance.voice = voice(russian: russian)
        // Звук события успевает отзвучать до голоса.
        utterance.preUtteranceDelay = 0.35
        synthesizer.speak(utterance)
    }

    public func stop() { synthesizer.stopSpeaking(at: .immediate) }
    public var isSpeaking: Bool { synthesizer.isSpeaking }
}

/// Папка событий хуков: маркер `.listening`, пока озвучка включена; чтение и разбор файлов.
/// Опрос раз в 0,5 с: файлов мало, а DispatchSource на папку теряет события при быстрых mv.
@MainActor
public final class AgentEventInbox {
    public let folder: URL
    private var timer: Timer?
    private var onEvent: ((AgentEvent) -> Void)?

    public init(root: URL) {
        folder = root.appendingPathComponent(AgentEvents.folderName, isDirectory: true)
    }

    public var isListening: Bool { timer != nil }

    public func start(_ handler: @escaping (AgentEvent) -> Void) {
        onEvent = handler
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder.appendingPathComponent(AgentEvents.listeningMarker).path, contents: Data())
        drain(announce: false)
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.drain(announce: true) }
        }
    }

    /// Снять маркер: хуки перестают писать, накопленное разбирается без озвучки.
    public func stop() {
        timer?.invalidate()
        timer = nil
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(AgentEvents.listeningMarker))
        drain(announce: false)
        onEvent = nil
    }

    /// Файлы событий — очередь: прочитанный файл убирается. Старые (приложение было закрыто) не озвучиваются.
    private func drain(announce: Bool) {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            .sorted()
        for name in names.prefix(32) {
            let url = folder.appendingPathComponent(name)
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            try? fm.removeItem(at: url)
            guard announce, let event = AgentEvents.parse(text),
                  Date().timeIntervalSince(event.at) <= AgentEvents.maxAge else { continue }
            onEvent?(event)
        }
    }
}
