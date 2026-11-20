import Foundation

/// Десктопный Телемост (`ru.yandex.desktop.telemost`, 3.x): окно звонка — нативный Qt, не веб-страница.
/// Доступность у него своя (`Orbita::Accessible*`): DOM-классов нет, зато у каждого элемента есть
/// `AXIdentifier` — путь объектов Qt вида `…MainConferenceView.ControlPanelWidget.microphoneButton`.
/// Веб-движок в клиенте рисует только мессенджер, поэтому разбор `WebCallSpeakers.telemost` здесь
/// не находит ничего — на 16 встречах из 16 (`docs/speaker-names-research.md`).
///
/// Что видно в дереве окна звонка (снято на 3.3.3):
/// - счётчик на кнопке «Участники» — `AXStaticText` с числом, вместе со мной;
/// - своя кнопка микрофона: «Turn off microphone» — включён, «Turn on microphone» — выключен;
/// - название встречи — заголовок окна;
/// - плитки — только значки 16×16 без имён.
/// Имена появляются, только когда открыт список участников (`ParticipantListWidget`) — его разбор
/// написан по именам классов из бинарника и не проверен на живом дереве.
public enum TelemostDesktop {
    public static let bundleID = "ru.yandex.desktop.telemost"

    static let conferenceMarker = "MainConferenceView"
    static let participantsButton = "participantsButton"
    static let microphoneButton = "ControlPanelWidget.microphoneButton"
    static let participantList = "ParticipantList"
    static let participantItem = "ParticipantListItem"

    /// Общие заголовки окна — не название встречи.
    static let genericTitles = ["yandex telemost", "яндекс телемост", "telemost", "телемост"]

    /// Снимок окна звонка; окна звонка нет (открыт только мессенджер) — nil.
    public static func snapshot(_ root: WebCallSpeakers.Node) -> ZoomSpeakers.Snapshot? {
        let windows = root.role == "AXWindow" ? [root] : root.children.filter { $0.role == "AXWindow" }
        guard let window = windows.first(where: { $0.all.contains { $0.identifier?.contains(conferenceMarker) == true } })
        else { return nil }
        let nodes = window.all
        var snapshot = ZoomSpeakers.Snapshot(tiles: participants(nodes))
        snapshot.count = nodes.lazy
            .filter { $0.role == "AXStaticText" && $0.identifier?.hasSuffix(participantsButton) == true }
            .compactMap { Int(($0.value ?? "").trimmingCharacters(in: .whitespaces)) }
            .first
        snapshot.myUnmuted = nodes.lazy
            .filter { $0.identifier?.hasSuffix(microphoneButton) == true }
            .compactMap { microphone($0.label) }
            .first
        snapshot.title = meetingTitle(window.title)
        return snapshot
    }

    /// Подпись кнопки микрофона → включён ли он. Кнопка предлагает действие: «выключить» — значит, включён.
    public static func microphone(_ label: String?) -> Bool? {
        guard let text = label?.lowercased() else { return nil }
        guard text.contains("microphone") || text.contains("микрофон") else { return nil }
        if text.contains("turn off") || text.contains("выключить") || text.contains("mute microphone") { return true }
        if text.contains("turn on") || text.contains("включить") || text.contains("unmute") { return false }
        if text.contains("muted") || text.contains("выключен") || text.contains("is off") { return false }
        return nil
    }

    /// Заголовок окна → название встречи; общий заголовок клиента и счётчик сообщений — не название.
    public static func meetingTitle(_ title: String?) -> String? {
        guard let title = WebCallSpeakers.clean(title) else { return nil }
        let lower = title.lowercased()
        if genericTitles.contains(where: { lower == $0 || lower.hasPrefix($0 + ":") }) { return nil }
        return title
    }

    static let selfMarkers = ["(you)", "(вы)", "(я)"]
    static let selfWords = ["you", "вы", "я"]
    /// Подписи кнопок и бейджей в строке списка — не имя.
    static let controlWords = ["microphone", "микрофон", "camera", "камера", "more", "ещё", "еще", "host",
                               "организатор", "соорганизатор", "co-host", "guest", "гость", "pin", "закрепить"]

    /// Список участников, если он открыт: строка — имя, пометка «вы», микрофон по значку.
    static func participants(_ nodes: [WebCallSpeakers.Node]) -> [ZoomSpeakers.Tile] {
        // Строка — узел, чей путь кончается этим классом; у потомков путь длиннее.
        let items = nodes.filter { $0.identifier?.split(separator: ".").last?.contains(participantItem) == true }
        var tiles: [ZoomSpeakers.Tile] = []
        for item in items {
            // Имя — видимый текст строки; подписи кнопок (микрофон, «ещё») в него не идут.
            let texts = item.all.filter { $0.role == "AXStaticText" }.compactMap { WebCallSpeakers.clean($0.value) }
            let parts = texts.isEmpty ? [item.title, item.label].compactMap(WebCallSpeakers.clean) : texts
            var isSelf = false
            var name: String?
            for part in parts {
                let lower = part.lowercased()
                if selfWords.contains(lower) { isSelf = true; continue }
                if controlWords.contains(lower) || microphone(part) != nil { continue }
                if Int(part) != nil { continue }
                var clean = part
                for marker in selfMarkers {
                    if let range = clean.range(of: marker, options: .caseInsensitive) {
                        isSelf = true
                        clean.removeSubrange(range)
                    }
                }
                clean = clean.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if name == nil, clean.contains(where: \.isLetter) { name = clean }
            }
            guard let name else { continue }
            let unmuted = item.all.lazy.compactMap { microphone($0.label) }.first
            tiles.append(ZoomSpeakers.Tile(name: name, active: false, isSelf: isSelf, unmuted: unmuted))
        }
        return tiles
    }
}

/// Журнал десктопного Телемоста `~/Library/Application Support/Yandex.Telemost/log/qt.log`:
/// клиент пишет в него сообщения моста между Qt и веб-частью — JSON в кавычках, с экранированными
/// кавычками внутри. Из них нужны число участников и название встречи — запасной источник, когда
/// окно звонка свёрнуто или дерево не отдаётся. Имён участников в журнале нет. Времени в строках
/// тоже нет: наблюдатель дочитывает дописанный хвост и ставит время чтения.
public enum TelemostLog {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Yandex.Telemost/log/qt.log")
    }

    public struct Event: Equatable, Sendable {
        public var method: String
        public var meetingID: String?
        public var meetingName: String?
        public var count: Int?
        public init(method: String, meetingID: String? = nil, meetingName: String? = nil, count: Int? = nil) {
            self.method = method; self.meetingID = meetingID; self.meetingName = meetingName; self.count = count
        }
    }

    static let methods: Set = ["handleMeetingInfo", "handleMeetingParticipantsCountChanged",
                               "handleMeetingConnect", "handleMeetingDisconnect"]

    /// Строка журнала → событие встречи; прочее — nil.
    public static func event(_ line: String) -> Event? {
        guard line.contains("handleMeeting") else { return nil }
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
            text = String(text.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\\", with: "\u{1}")
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\u{1}", with: "\\")
        }
        guard let start = text.firstIndex(of: "{"), let data = String(text[start...]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = object["data"] as? [String: Any],
              let method = body["method"] as? String, methods.contains(method)
        else { return nil }
        let payload = body["payload"] as? [String: Any] ?? [:]
        return Event(method: method, meetingID: payload["meetingId"] as? String,
                     meetingName: (payload["meetingName"] as? String).flatMap(WebCallSpeakers.clean),
                     count: payload["count"] as? Int)
    }

    /// Состояние текущей встречи по журналу: последнее число участников и название.
    public struct State: Equatable, Sendable {
        public var meetingID: String?
        public var meetingName: String?
        public var count: Int?
        public var connected = false
        public init() {}

        /// Применить событие; true — что-то изменилось.
        @discardableResult
        public mutating func apply(_ event: Event) -> Bool {
            let before = self
            if let id = event.meetingID, id != meetingID, event.method != "handleMeetingDisconnect" {
                // Другая встреча: старое название и счётчик к ней не относятся.
                self = State()
                meetingID = id
            }
            switch event.method {
            case "handleMeetingInfo": meetingName = event.meetingName ?? meetingName
            case "handleMeetingParticipantsCountChanged": count = event.count ?? count
            case "handleMeetingConnect": connected = true
            case "handleMeetingDisconnect":
                if event.meetingID == nil || event.meetingID == meetingID { connected = false; count = nil }
            default: break
            }
            return self != before
        }
    }

    /// Дочитать журнал с `offset`: новые события и новое смещение. Журнал обрезан или пересоздан
    /// (размер меньше смещения) — читаем сначала. Последняя неполная строка ждёт следующего раза.
    public static func tail(_ url: URL, from offset: UInt64) -> (events: [Event], offset: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], offset) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        var start = offset > size ? 0 : offset
        // Больше мегабайта за раз не читаем: после долгого перерыва нужен хвост, а не история.
        if size - start > 1 << 20 { start = size - (1 << 20) }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return ([], size) }
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return ([], start) }
        let complete = data[data.startIndex...lastNewline]
        let text = String(decoding: complete, as: UTF8.self)
        let events = text.split(separator: "\n").compactMap { event(String($0)) }
        return (events, start + UInt64(complete.count))
    }
}
