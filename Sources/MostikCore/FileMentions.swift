import Foundation

// A3: автотег файлов. Сказанное «в auth check» становится `@src/authCheck.ts`, если в проекте
// ровно один файл с таким именем. Список файлов собирает `MostikKit/ProjectFiles`.

/// Где `@путь` понимают как ссылку на файл: Claude Code, Codex, Gemini CLI и opencode
/// в терминале, Cursor и Windsurf. В остальных приложениях текст не меняется.
public enum FileMentionApps {
    public static let editors: Set<String> = ["com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf"]
    public static let cliAgents: Set<String> = ["claude", "codex", "gemini", "opencode"]

    public static func supports(_ app: FrontApp, policy: AgentAppPolicy) -> Bool {
        if policy.forcedOff.contains(app.bundleID) { return false }
        if editors.contains(app.bundleID) { return true }
        if policy.terminals.contains(app.bundleID) { return !app.runningAgentCLIs.isDisjoint(with: cliAgents) }
        return false
    }
}

/// Имена файлов проекта по ключу: части имени без расширения, слитно и строчными.
public struct FileIndex: Equatable, Sendable {
    /// Ключ → пути (относительно корня проекта).
    public var byKey: [String: [String]] = [:]
    /// Ключи, у которых в имени две части и больше: authCheck, auth_check, auth-check.
    public var compound: Set<String> = []

    public init() {}

    public init(paths: [String]) {
        for path in paths {
            let name = (path as NSString).lastPathComponent
            let parts = FileMentions.parts(ofFileName: name)
            guard !parts.isEmpty else { continue }
            let key = parts.joined()
            guard key.count >= 3 else { continue }
            byKey[key, default: []].append(path)
            if parts.count >= 2 { compound.insert(key) }
        }
    }

    /// Единственный файл с ключом; несколько — неоднозначно, nil.
    public func unique(_ key: String) -> String? {
        guard let paths = byKey[key], paths.count == 1 else { return nil }
        return paths[0]
    }
}

public enum FileMentions {
    /// После этих слов можно назвать и однословный файл: «в файле readme».
    static let triggers: Set<String> = ["файл", "файле", "файла", "файлу", "файлом", "file"]
    /// Сколько слов подряд может занимать имя файла.
    static let maxWords = 4

    /// Части имени файла без расширения: `authCheck.test.ts` → auth, check, test.
    public static func parts(ofFileName name: String) -> [String] {
        var stem = name
        if let dot = stem.lastIndex(of: "."), dot != stem.startIndex { stem = String(stem[..<dot]) }
        return split(stem)
    }

    /// camelCase, snake_case, kebab-case, точки и цифры — в строчные части.
    public static func split(_ word: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var previous: Character?
        for ch in word {
            guard ch.isASCII, ch.isLetter || ch.isNumber else {
                if !current.isEmpty { parts.append(current); current = "" }
                previous = nil
                continue
            }
            if let p = previous, !current.isEmpty {
                let boundary = (p.isLowercase && ch.isUppercase) || (p.isLetter && ch.isNumber) || (p.isNumber && ch.isLetter)
                if boundary { parts.append(current); current = "" }
            }
            current.append(ch)
            previous = ch
        }
        if !current.isEmpty { parts.append(current) }
        return parts.map { $0.lowercased() }
    }

    struct Token {
        var range: Range<String.Index>
        var text: String
        var latin: Bool
    }

    static func tokens(_ text: String) -> [Token] {
        var out: [Token] = []
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch.isLetter || ch.isNumber || ch == "_" {
                var j = i
                while j < text.endIndex, text[j].isLetter || text[j].isNumber || text[j] == "_" || text[j] == "-" {
                    j = text.index(after: j)
                }
                // Дефис в конце слова — не часть имени.
                var end = j
                while end > i, text[text.index(before: end)] == "-" { end = text.index(before: end) }
                let word = String(text[i..<end])
                out.append(Token(range: i..<end, text: word, latin: word.allSatisfy { $0.isASCII }))
                i = j
            } else {
                i = text.index(after: i)
            }
        }
        return out
    }

    /// Заменить упомянутые файлы на `@путь`. Только уверенные совпадения: имя из двух частей
    /// и больше и единственный такой файл; однословное — лишь после «файл»/«file».
    public static func apply(_ text: String, index: FileIndex) -> (text: String, tagged: [String]) {
        guard !index.byKey.isEmpty else { return (text, []) }
        let toks = tokens(text)
        var replacements: [(Range<String.Index>, String)] = []
        var i = 0
        while i < toks.count {
            let afterTrigger = i > 0 && triggers.contains(toks[i - 1].text.lowercased())
            var matched = false
            for length in stride(from: min(maxWords, toks.count - i), through: 1, by: -1) {
                let span = Array(toks[i..<(i + length)])
                guard span.allSatisfy(\.latin) else { continue }
                // Между словами — только пробелы: «auth, check» — уже не имя.
                var contiguous = true
                for k in 1..<span.count {
                    let gap = text[span[k - 1].range.upperBound..<span[k].range.lowerBound]
                    if !gap.allSatisfy({ $0 == " " }) { contiguous = false; break }
                }
                guard contiguous else { continue }
                // Уже путь или упоминание: «@auth», «src/auth», «auth.ts».
                let start = span[0].range.lowerBound
                if start > text.startIndex {
                    let prev = text[text.index(before: start)]
                    if prev == "@" || prev == "/" || prev == "." || prev == "\\" { continue }
                }
                let end = span[span.count - 1].range.upperBound
                if end < text.endIndex, text[end] == "." || text[end] == "/",
                   text.index(after: end) < text.endIndex, text[text.index(after: end)].isLetter { continue }
                let parts = span.flatMap { split($0.text) }
                let key = parts.joined()
                guard let path = index.unique(key) else { continue }
                let confident = index.compound.contains(key) && parts.count >= 2
                guard confident || (afterTrigger && key.count >= 3) else { continue }
                replacements.append((start..<end, "@" + path))
                i += length
                matched = true
                break
            }
            if !matched { i += 1 }
        }
        guard !replacements.isEmpty else { return (text, []) }
        var result = ""
        var cursor = text.startIndex
        for (range, value) in replacements {
            result += text[cursor..<range.lowerBound]
            result += value
            cursor = range.upperBound
        }
        result += text[cursor...]
        return (result, replacements.map { String($0.1.dropFirst()) })
    }
}
