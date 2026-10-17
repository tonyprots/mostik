import Foundation

// Обучение на правках (L1) и язык диктовки (L5): чистые правила.
// Платформа — `Mostik/GlossaryLearningController.swift` (AX-чтение поля, только чтение),
// дифф по словам и фильтры звучания и смысла — в движке (`engine/mostik_engine/edit_learning.py`):
// там же личный словарь, стеммер и фонетика transcriber, и логика не дублируется на двух языках.

/// Что в поле стало со вставленным текстом: исходный кусок и его правленая версия.
public struct InsertionEdit: Equatable, Sendable {
    public var before: String
    public var after: String
    public init(before: String, after: String) { self.before = before; self.after = after }
}

public enum EditWatch {
    /// Сколько после вставки следим за полем.
    public static let duration: TimeInterval = 60
    /// Как часто перечитываем поле.
    public static let interval: TimeInterval = 2
    /// Правка, ушедшая дальше вставки больше чем на столько знаков, — уже не про неё.
    public static let spill = 40

    /// Где в поле стоит вставка: сначала там, куда вставляли, потом ближайшее вхождение.
    /// Отступы — в UTF-16, как в AX.
    public static func locate(_ inserted: String, in value: String, near location: Int?) -> Range<Int>? {
        let text = Array(value.utf16), needle = Array(inserted.utf16)
        guard !needle.isEmpty, needle.count <= text.count else { return nil }
        if let location, location >= 0, location + needle.count <= text.count,
           Array(text[location..<location + needle.count]) == needle {
            return location..<location + needle.count
        }
        var best: Int?
        var start = 0
        while start + needle.count <= text.count {
            if text[start] == needle[0], Array(text[start..<start + needle.count]) == needle {
                if best == nil || abs(start - (location ?? 0)) < abs(best! - (location ?? 0)) { best = start }
            }
            start += 1
        }
        return best.map { $0..<$0 + needle.count }
    }

    /// Правка вставки: поле сразу после вставки (`after`) против итогового значения (`final`).
    ///
    /// Общие начало и конец отбрасываются; если изменилась хоть часть вставленного (замена или
    /// удаление, а не только дописанное рядом) — возвращается кусок вставки и то, чем он стал.
    /// Правка, задевшая текст вокруг вставки, расширяется до границ слов. nil — вставку не трогали
    /// или правка далеко за её пределами.
    public static func edit(after: String, final: String, inserted range: Range<Int>) -> InsertionEdit? {
        let a = Array(after.utf16), f = Array(final.utf16)
        guard a != f, range.lowerBound >= 0, range.upperBound <= a.count, !range.isEmpty else { return nil }
        var prefix = 0
        while prefix < a.count, prefix < f.count, a[prefix] == f[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < f.count - prefix,
              a[a.count - 1 - suffix] == f[f.count - 1 - suffix] { suffix += 1 }
        let changedA = prefix..<(a.count - suffix)
        // Только дописали — вставленное цело, учить нечему.
        guard !changedA.isEmpty, changedA.overlaps(range) else { return nil }
        guard range.lowerBound - changedA.lowerBound <= spill, changedA.upperBound - range.upperBound <= spill else {
            return nil
        }
        var start = min(range.lowerBound, changedA.lowerBound)
        var endA = max(range.upperBound, changedA.upperBound)
        if start < range.lowerBound { start = wordStart(a, before: start) }
        if endA > range.upperBound { endA = wordEnd(a, after: endA) }
        let endF = endA + (f.count - a.count)
        guard start <= endF, endF <= f.count else { return nil }
        let before = String(decoding: a[start..<endA], as: UTF16.self)
        let edited = String(decoding: f[start..<endF], as: UTF16.self)
        guard before != edited else { return nil }
        return InsertionEdit(before: before, after: edited)
    }

    private static func isSpace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x0A || unit == 0x0D || unit == 0x09 || unit == 0xA0
    }

    private static func wordStart(_ text: [UInt16], before index: Int) -> Int {
        var i = index
        while i > 0, !isSpace(text[i - 1]) { i -= 1 }
        return i
    }

    private static func wordEnd(_ text: [UInt16], after index: Int) -> Int {
        var i = index
        while i < text.count, !isSpace(text[i]) { i += 1 }
        return i
    }

    /// Читать ли поле сейчас: то же приложение, тот же элемент (кроме Electron и Gecko,
    /// где AX пересоздаёт элементы), не пароль и значение прочитано.
    public static func sameField(_ snapshot: FieldSnapshot?, as record: InsertionRecord) -> Bool {
        guard let snapshot, !snapshot.isSecure, snapshot.value != nil, snapshot.bundleID == record.bundleID else {
            return false
        }
        if record.engine == .native, let a = record.elementToken, let b = snapshot.elementToken, a != b { return false }
        return true
    }
}

/// Предложение запомнить написание (L1): пара набралась повторами, ждёт ответа пользователя.
public struct GlossarySuggestion: Equatable, Hashable, Sendable, Identifiable {
    public var heard: String
    public var canonical: String
    public var language: String?
    public var count: Int
    public var id: String { heard.lowercased() + "→" + canonical }
    public init(heard: String, canonical: String, language: String? = nil, count: Int = 2) {
        self.heard = heard; self.canonical = canonical; self.language = language; self.count = count
    }

    /// Разбор `suggestions` из ответа движка.
    public static func parse(_ value: JSONValue?) -> [GlossarySuggestion] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap { item in
            guard case .object(let o) = item, let heard = o["heard"]?.stringValue,
                  let canonical = o["canonical"]?.stringValue else { return nil }
            return GlossarySuggestion(heard: heard, canonical: canonical, language: o["language"]?.stringValue,
                                      count: Int(o["count"]?.doubleValue ?? 2))
        }
    }
}

// MARK: L5 — язык диктовки

public enum LanguageChoice {
    public static let supported = ["ru", "en"]

    /// Коды языков: «ru-RU» → «ru», только поддерживаемые, без повторов, в порядке списка.
    public static func normalize(_ codes: [String]) -> [String] {
        var picked: [String] = []
        for code in codes {
            let base = code.lowercased().replacingOccurrences(of: "_", with: "-")
                .split(separator: "-").first.map(String.init) ?? ""
            if supported.contains(base), !picked.contains(base) { picked.append(base) }
        }
        return picked
    }

    /// Список, из которого выбирает автоопределение: свой из Настроек или языки Mac.
    public static func candidates(configured: [String]?, preferred: [String]) -> [String] {
        let own = normalize(configured ?? [])
        return own.isEmpty ? normalize(preferred) : own
    }

    /// Что отправить движку в `languages`: пусто — автоопределение выключено или выбирать не из чего.
    public static func request(settings: MostikSettings, preferred: [String]) -> [String] {
        guard settings.autoLanguage else { return [] }
        var list = candidates(configured: settings.autoLanguages, preferred: preferred)
        guard list.count >= 2 else { return [] }
        // Язык по умолчанию — первым: на него движок откатывается, если не уверен.
        if let index = list.firstIndex(of: settings.language) { list.remove(at: index) } else { return [] }
        return [settings.language] + list
    }
}

// MARK: L6 — импорт словаря

/// Ответ `glossary_import`: сколько нашлось, сколько уже было, что новое.
public struct GlossaryImportPreview: Equatable, Sendable {
    public struct Item: Equatable, Hashable, Sendable {
        public var canonical: String
        public var heard: String
        public init(canonical: String, heard: String = "") { self.canonical = canonical; self.heard = heard }
    }

    /// "handy" | "wispr" | "csv" | "lines"
    public var source: String
    public var total: Int
    public var duplicates: Int
    public var newCount: Int
    /// Первые новые записи (движок присылает до 500).
    public var items: [Item]
    public var added: Int
    /// Путь к CSV или текст строк: с ними же повторяется команда с `apply`.
    public var path: String?
    public var text: String?

    public init(source: String, total: Int, duplicates: Int, newCount: Int, items: [Item], added: Int = 0,
                path: String? = nil, text: String? = nil) {
        self.source = source; self.total = total; self.duplicates = duplicates; self.newCount = newCount
        self.items = items; self.added = added; self.path = path; self.text = text
    }

    public init(payload: [String: JSONValue], path: String? = nil, text: String? = nil) {
        var items: [Item] = []
        if case .array(let raw)? = payload["new"] {
            for value in raw {
                guard case .object(let o) = value, let canonical = o["canonical"]?.stringValue else { continue }
                items.append(Item(canonical: canonical, heard: o["heard"]?.stringValue ?? ""))
            }
        }
        self.init(source: payload["source"]?.stringValue ?? "", total: Int(payload["total"]?.doubleValue ?? 0),
                  duplicates: Int(payload["duplicates"]?.doubleValue ?? 0),
                  newCount: Int(payload["new_count"]?.doubleValue ?? Double(items.count)), items: items,
                  added: Int(payload["added"]?.doubleValue ?? 0), path: path, text: text)
    }
}

/// Одна всплывашка после вставки, а не две.
public enum LearnPromptPolicy {
    /// «Слово распознано не так?» над плашкой — только когда плашка сама не ведёт к словам:
    /// при сомнениях в ней уже «N слов под вопросом ›».
    public static func showsSpellingChip(doubts: Int, corrections: Int) -> Bool {
        doubts == 0 && corrections > 0
    }
}
