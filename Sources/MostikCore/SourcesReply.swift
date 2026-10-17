import Foundation

/// Источник словаря из ответа `sources`/`rescan` (S5).
public struct SourceInfo: Equatable, Sendable {
    /// "repo" | "docs" | "calendar" | "personal"
    public var kind: String
    public var label: String
    public var path: String?
    public var scannedAt: Date?
    public var counts: [String: Int]
    public var total: Int

    public init(kind: String, label: String, path: String? = nil, scannedAt: Date? = nil,
                counts: [String: Int] = [:], total: Int = 0) {
        self.kind = kind; self.label = label; self.path = path; self.scannedAt = scannedAt
        self.counts = counts; self.total = total
    }
}

public struct TermInfo: Equatable, Sendable {
    public var term: String
    public var kind: String
    public var origins: [String]
    public init(term: String, kind: String, origins: [String]) {
        self.term = term; self.kind = kind; self.origins = origins
    }
}

public struct SourcesReply: Equatable, Sendable {
    public var sources: [SourceInfo]
    public var terms: [TermInfo]

    public init(sources: [SourceInfo] = [], terms: [TermInfo] = []) {
        self.sources = sources; self.terms = terms
    }

    /// Разбор `{ok, sources: [...], terms: [...]}`; терпим к пропущенным полям.
    public static func parse(_ payload: [String: JSONValue]) -> SourcesReply {
        var sources: [SourceInfo] = []
        if case .array(let items)? = payload["sources"] {
            for item in items {
                guard case .object(let o) = item, let kind = o["kind"]?.stringValue else { continue }
                let path = o["path"]?.stringValue
                var counts: [String: Int] = [:]
                if case .object(let c)? = o["counts"] {
                    for (key, value) in c { if let n = value.doubleValue { counts[key] = Int(n) } }
                }
                let total = o["total"]?.doubleValue.map { Int($0) } ?? counts.values.reduce(0, +)
                let label = o["label"]?.stringValue
                    ?? path.map { ($0 as NSString).lastPathComponent } ?? kind
                sources.append(SourceInfo(kind: kind, label: label, path: path,
                                          scannedAt: date(o["scanned_at"]), counts: counts, total: total))
            }
        }
        var terms: [TermInfo] = []
        var seen = Set<String>()
        if case .array(let items)? = payload["terms"] {
            for item in items {
                guard case .object(let o) = item, let term = o["term"]?.stringValue, !term.isEmpty,
                      seen.insert(term).inserted else { continue }
                var origins: [String] = []
                if case .array(let a)? = o["origins"] { origins = a.compactMap(\.stringValue) }
                terms.append(TermInfo(term: term, kind: o["kind"]?.stringValue ?? "", origins: origins))
            }
        }
        return SourcesReply(sources: sources, terms: terms)
    }

    /// `scanned_at`: ISO 8601 (с долями секунды или без) или секунды с 1970.
    static func date(_ value: JSONValue?) -> Date? {
        switch value {
        case .number(let n)?: return n > 0 ? Date(timeIntervalSince1970: n) : nil
        case .string(let s)?:
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            iso.formatOptions = [.withInternetDateTime]
            if let d = iso.date(from: s) { return d }
            // Без часового пояса (`datetime.isoformat()` в Python) — считаем местным временем.
            let local = DateFormatter()
            local.locale = Locale(identifier: "en_US_POSIX")
            for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss"] {
                local.dateFormat = format
                if let d = local.date(from: s) { return d }
            }
            return Double(s).map { Date(timeIntervalSince1970: $0) }
        default:
            return nil
        }
    }
}
