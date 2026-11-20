import Foundation

/// Субтитры ВКС с именем говорящего — из дерева Accessibility, когда пользователь сам включил их
/// в звонке. Клиент подписывает каждую реплику именем; движок сводит реплики с метками диаризации
/// по времени и словам (`speaker_captions.py`). Сами субтитры не включаем и ничего не нажимаем.
///
/// Где они в дереве (по открытому meeting-capture, MIT, и снимкам Zoom 7.2):
/// - Zoom — контейнер с `AXDescription` «Closed caption subtitles», строки `AXRow` → ячейки →
///   тексты [говорящий, текст…]; пока показывают экран, субтитров в дереве нет;
/// - Teams — DOM-класс `fui-ChatMessageCompact__body`, тексты [говорящий, текст];
/// - Slack huddle — `p-huddle_closed_caption_event__wrapper`, тексты [говорящий, «:», текст];
/// - Meet — группа «Captions», в ней чередуются блок с именем и блок с репликами. Имя — блок
///   из одной строки мельче реплик; по очерёдности не считаем: Meet срезает старые блоки сверху.
public enum CallCaptions {
    public struct Caption: Equatable, Sendable {
        public var name: String
        public var text: String
        public init(name: String, text: String) { self.name = name; self.text = text }
    }

    public enum Kind: String, Sendable { case zoom, meet, teams, slack }

    public static let zoomContainer = "Closed caption subtitles"
    static let meetContainer = "Captions"
    static let teamsClass = "fui-ChatMessageCompact__body"
    static let slackClass = "p-huddle_closed_caption_event__wrapper"

    /// Строки Zoom: тексты ячеек строки по порядку → реплика.
    public static func zoom(rows: [[String]]) -> [Caption] {
        rows.compactMap { texts in caption(texts.compactMap(WebCallSpeakers.cleanLong)) }
    }

    /// Субтитры в дереве страницы (Meet, Teams, Slack); контейнера нет — nil.
    public static func captions(_ root: WebCallSpeakers.Node, kind: Kind) -> [Caption]? {
        switch kind {
        case .zoom: return nil
        case .meet: return meet(root)
        case .teams:
            let bodies = root.all.filter { $0.has(teamsClass) }
            return bodies.isEmpty ? nil : bodies.compactMap { caption($0.longTexts) }
        case .slack:
            let events = root.all.filter { $0.has(slackClass) }
            return events.isEmpty ? nil : events.compactMap { caption($0.longTexts.filter { $0 != ":" }) }
        }
    }

    static func caption(_ texts: [String]) -> Caption? {
        guard texts.count >= 2 else { return nil }
        var name = texts[0]
        if name.hasSuffix(":") { name.removeLast() }
        let text = texts.dropFirst().joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !name.isEmpty, !text.isEmpty else { return nil }
        return Caption(name: name.trimmingCharacters(in: .whitespaces), text: text)
    }

    static func meet(_ root: WebCallSpeakers.Node) -> [Caption]? {
        guard let container = root.all.first(where: { $0.label == meetContainer && !$0.children.isEmpty }) else { return nil }
        let blocks = container.children.map(\.longTexts)
        let isName = nameBlocks(blocks.indices.map { (lines: blocks[$0].count, height: container.children[$0].height ?? 0) })
        var result: [Caption] = []
        var speaker: String?
        for (index, block) in blocks.enumerated() {
            if isName[index] { speaker = block.first; continue }
            guard let speaker else { continue }
            for text in block where !text.isEmpty { result.append(Caption(name: speaker, text: text)) }
        }
        return result
    }

    /// Какие блоки Meet — имена. Имя всегда одна строка и набрано мельче реплики: если среди
    /// однострочных есть заметно разные высоты, имена — самые низкие. Высот нет или все равны —
    /// имён не знаем: по очерёдности не угадываем, у нового говорящего блок с именем приходит
    /// раньше реплики, и счёт со стороны любого конца сбивается.
    static func nameBlocks(_ shapes: [(lines: Int, height: Double)]) -> [Bool] {
        let single = shapes.filter { $0.lines == 1 && $0.height > 0 }.map(\.height)
        guard let low = single.min(), single.contains(where: { $0 > low * 1.2 }) else {
            return [Bool](repeating: false, count: shapes.count)
        }
        return shapes.map { $0.lines == 1 && $0.height > 0 && $0.height <= low * 1.2 }
    }
}

extension WebCallSpeakers {
    /// Как `clean`, но для реплик: длинный текст не отбрасываем, только схлопываем пробелы.
    static func cleanLong(_ text: String?) -> String? {
        guard let text else { return nil }
        let joined = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return joined.isEmpty ? nil : String(joined.prefix(2000))
    }
}

extension WebCallSpeakers.Node {
    /// Видимые тексты узла с длинными репликами.
    var longTexts: [String] {
        all.filter { $0.role == "AXStaticText" }.compactMap { WebCallSpeakers.cleanLong($0.value) }
    }
}

/// Лента `speaker-captions.jsonl`: реплика субтитров с именем и временем — строка, когда реплика
/// дописана (пропала с экрана или звонок кончился). `{"at", "end", "name", "text", "source"}`:
/// `at` — когда реплика появилась, `end` — когда последний раз менялась, по часам встречи.
public struct CaptionTracker: Sendable {
    public static let fileName = "speaker-captions.jsonl"
    /// Совпадение начала, по которому растущая реплика узнаётся той же.
    static let prefixLength = 12
    /// Та же реплика того же человека позже стольких секунд — новая (повторил «да, согласен»),
    /// раньше — та же строка, перерисованная клиентом.
    static let repeatGap = 30.0

    struct Open: Sendable {
        var name: String
        var text: String
        var start: Double
        var changed: Double
    }

    public let source: String
    var open: [Open] = []
    /// Записанные реплики: ключ «имя|текст» → когда реплика последний раз менялась.
    var written: [String: Double] = [:]

    public init(source: String) { self.source = source }

    static func key(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
    }

    static func sameLine(_ old: String, _ new: String) -> Bool {
        let a = key(old), b = key(new)
        if a == b || b.hasPrefix(a) || a.hasPrefix(b) { return true }
        let n = min(prefixLength, a.count, b.count)
        return n >= prefixLength && a.prefix(n) == b.prefix(n)
    }

    /// Видимые сейчас реплики → дописанные строки ленты. `nil` — субтитров в дереве нет (выключены
    /// или спрятаны показом экрана): открытые реплики не закрываем, ждём.
    public mutating func observe(_ captions: [CallCaptions.Caption]?, at: Double) -> [String] {
        guard let captions else { return [] }
        var matched = Set<Int>()
        for caption in captions {
            if let index = open.indices.first(where: { index in
                !matched.contains(index) && open[index].name == caption.name && Self.sameLine(open[index].text, caption.text)
            }) {
                if open[index].text != caption.text {
                    open[index].text = caption.text
                    open[index].changed = at
                }
                matched.insert(index)
            } else if !recent(Self.key(caption.name) + "|" + Self.key(caption.text), at: at) {
                open.append(Open(name: caption.name, text: caption.text, start: at, changed: at))
                matched.insert(open.count - 1)
            }
        }
        var lines: [String] = []
        for index in open.indices where !matched.contains(index) {
            if let text = line(open[index]) { lines.append(text) }
        }
        open = open.indices.filter(matched.contains).map { open[$0] }
        return lines
    }

    /// Конец записи: все открытые реплики — в ленту.
    public mutating func finish() -> [String] {
        var lines: [String] = []
        for entry in open { if let text = line(entry) { lines.append(text) } }
        open = []
        return lines
    }

    private func recent(_ key: String, at: Double) -> Bool {
        written[key].map { at - $0 < Self.repeatGap } ?? false
    }

    private mutating func line(_ entry: Open) -> String? {
        let key = Self.key(entry.name) + "|" + Self.key(entry.text)
        guard !recent(key, at: entry.start) else { return nil }
        written = written.filter { entry.changed - $0.value < Self.repeatGap }
        written[key] = entry.changed
        let row: [String: Any] = ["at": (entry.start * 100).rounded() / 100, "end": (entry.changed * 100).rounded() / 100,
                                  "name": entry.name, "text": entry.text, "source": source]
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
