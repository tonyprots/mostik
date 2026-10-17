import Foundation

/// Страж словаря интерфейса (copy-clarity): в русских половинах строк нет слов,
/// от которых решено отказаться, — жаргона, старых названий и разделов, которых больше нет.
/// Проверяет первую строку в `L("…", …)`, `UIText.pick("…", …)` и `ru ? "…" : …`;
/// снимки и демо-данные не в счёт, как у стража локализации.
enum CopyGuard {
    static let folders = ["Sources/MostikUI", "Sources/Mostik", "Sources/MostikKit", "Sources/MostikCore"]

    /// Слово → чем заменено (для сообщения теста).
    static let banned: [(String, String)] = [
        ("Accessibility", "Универсальный доступ"),
        ("Мостик", "Mostik"),
        ("пилюл", "окошко записи"),
        ("бриф", "справка перед встречей"),
        ("сомнени", "слова под вопросом"),
        ("откач", "отменить вставку"),
        ("сыр", "как сказано"),
        ("Проверка →", "Диагностика"),
        ("Голосовые команды", "Действия голосом"),
    ]

    static func skipped(_ name: String) -> Bool { name.hasSuffix("Snapshots.swift") || name.hasSuffix("Demo.swift") }

    private static let patterns: [NSRegularExpression] = [
        #"\bL\(\s*"((?:[^"\\]|\\.)*)""#,
        #"UIText\.pick\(\s*"((?:[^"\\]|\\.)*)""#,
        #"\b(?:ru|russian|isRussian)\s*\?\s*"((?:[^"\\]|\\.)*)""#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// Русские половины строк в тексте файла.
    static func russianHalves(in text: String) -> [String] {
        let ns = text as NSString
        var out: [String] = []
        for regex in patterns {
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                out.append(ns.substring(with: m.range(at: 1)))
            }
        }
        return out
    }

    static func violations(in text: String, file: String) -> [String] {
        var out: [String] = []
        for half in russianHalves(in: text) {
            for (word, instead) in banned where half.range(of: word, options: .caseInsensitive) != nil {
                out.append("\(file): «\(word)» → «\(instead)»: \(half.prefix(90))")
            }
        }
        return out
    }
}

func runCopyGuardTests() {
    // Страж на плохом и хорошем входе: без этого «0 нарушений» ничего не доказывает.
    let bad = """
    Text(L("Нужен доступ Accessibility", "Accessibility needed"))
    let a = L("Проекту Мостик нужно разрешение", "Mostik needs permission")
    let b = L("Пометка — в пилюле", "Marks are in the pill")
    let c = UIText.pick("Бриф перед встречей", "Brief")
    let d = L("Блок сомнений", "Doubts")
    let e = ru ? "Вставка откачена" : "Undone"
    let f = L("Заменить сырой расшифровкой", "Replace with raw")
    let g = L("см. Настройки → Проверка → Микрофон", "see Settings")
    let h = UIText.pick("Включите в Голосовые команды", "Turn on")
    """
    equal(CopyGuard.violations(in: bad, file: "bad").count, 9, "страж ловит все девять слов")
    let good = """
    Text(L("Включите Mostik в Универсальном доступе", "Turn on Mostik in Accessibility"))
    // Комментарий: бриф, пилюля, сомнения
    let s = "Проекту Мостик нужно разрешение"  // образец голоса, не строка интерфейса
    let t = L("Справка перед встречей", "Pre-meeting brief")
    """
    equal(CopyGuard.violations(in: good, file: "good"), [], "страж не трогает английские половины, комментарии и не-UI строки")

    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var files = 0, halves = 0
    var found: [String] = []
    for folder in CopyGuard.folders {
        let dir = root.appendingPathComponent(folder)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names.sorted() where name.hasSuffix(".swift") && !CopyGuard.skipped(name) {
            guard let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) else { continue }
            files += 1
            halves += CopyGuard.russianHalves(in: text).count
            found += CopyGuard.violations(in: text, file: "\(folder)/\(name)")
        }
    }
    check(files > 80, "страж словаря видит исходники: \(files) файлов")
    check(halves > 1000, "страж словаря видит русские строки: \(halves)")
    for v in found { print("COPY \(v)") }
    equal(found.count, 0, "запрещённые слова в русских строках (просмотрено \(files) файлов, \(halves) строк)")
}
