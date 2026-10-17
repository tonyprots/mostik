import Foundation

/// Слова под вопросом решаются в интерфейсе (история, плашка), а не в тексте для агента:
/// принятая подсказка сразу правит текст записи, отклонённая — только снимает отметку.
public enum DoubtResolution {
    /// Принять написание: услышанное в тексте записи — целыми словами — заменяется на `canonical`,
    /// а сомнения про это слово снимаются. Так же работает «Запомнить написание».
    public static func accept(_ entry: HistoryEntry, heard: String, canonical: String) -> HistoryEntry {
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonical = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = entry
        if !heard.isEmpty, !canonical.isEmpty, heard != canonical {
            updated.text = replacing(heard, with: canonical, in: entry.text)
            if !entry.insertedText.isEmpty {
                updated.insertedText = replacing(heard, with: canonical, in: entry.insertedText)
            }
        }
        updated.doubts = entry.doubts.filter { doubt in
            !(same(doubt.heard, heard) || (!canonical.isEmpty && same(doubt.suggestion, canonical)))
        }
        return updated
    }

    /// Отклонить подсказку: сомнение снимается, текст остаётся как был.
    public static func reject(_ entry: HistoryEntry, doubt: Doubt) -> HistoryEntry {
        var updated = entry
        updated.doubts = entry.doubts.filter { !(same($0.heard, doubt.heard) && same($0.suggestion, doubt.suggestion)) }
        return updated
    }

    /// Текст старой записи без блока «[Слова под вопросом: …]», который прежние версии дописывали агентам.
    public static func legacyBody(_ inserted: String) -> String {
        guard inserted.hasSuffix("]"), let range = inserted.range(of: "\n\n[", options: .backwards) else { return inserted }
        let block = inserted[range.upperBound...]
        guard block.hasPrefix("Слова под вопросом:") || block.hasPrefix("Unsure words:") else { return inserted }
        return String(inserted[..<range.lowerBound])
    }

    static func same(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    /// Замена целыми словами без учёта регистра: «parakeet» не трогает «parakeet_tdt».
    static func replacing(_ heard: String, with canonical: String, in text: String) -> String {
        let pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: heard) + "(?![\\p{L}\\p{N}_])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range,
                                              withTemplate: NSRegularExpression.escapedTemplate(for: canonical))
    }
}
