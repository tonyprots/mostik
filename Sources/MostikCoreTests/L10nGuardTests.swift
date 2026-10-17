import Foundation
import MostikCore

// Страж локализации (П8, п. 9): любая строка интерфейса — парой `L(ru, en)`.
// Сканирует исходники MostikUI, Mostik и MostikKit и ищет строковые литералы
// с кириллицей без пары, `Text("…")`, `.help("…")`, `accessibilityLabel("…")`
// с латиницей без пары, и пары `L("…", "…")`, где английская половина
// пустая или с кириллицей.

enum L10nGuard {
    /// Папки со строками интерфейса.
    static let folders = ["Sources/MostikUI", "Sources/Mostik", "Sources/MostikKit"]

    /// Файлы демо-данных снимков: в них кириллица — содержимое диктовок и встреч, а не интерфейс.
    /// Интерфейсные строки в них тоже через `L`, но сам текст «диктовки» бывает только русским.
    static func skipped(_ name: String) -> Bool {
        name.hasSuffix("Snapshots.swift") || name.hasSuffix("Demo.swift")
    }

    /// Разумные исключения: подстрока в строке кода → строка не интерфейсная.
    static let exceptions: [(String, String)] = [
        ("NSLog(", "журнал для разработчика, не интерфейс"),
        ("print(", "вывод CLI и снимков"),
        ("\"Русский\"", "название языка пишется на нём самом"),
        ("(Тема|Subject)", "разбор заголовка письма на обоих языках"),
        ("hasPrefix(\"календарь\")", "разбор происхождения термина из протокола движка"),
        ("\"личный словарь\"", "разбор происхождения термина из протокола движка"),
        ("l10n-guard:", "помеченная строка: пара на соседней строке, образец речи, словарь распознавания"),
    ]

    /// Строковый литерал Swift с кириллицей (обычный и сырой `#"…"#`).
    static let cyrillicLiteral = try! NSRegularExpression(pattern: #"#?"(?:[^"\\\n]|\\.)*[А-Яа-яЁё](?:[^"\\\n]|\\.)*""#)
    /// Признаки того, что у строки есть английская пара на этой же строке кода.
    static let paired = try! NSRegularExpression(
        pattern: #"\bL\(|L10n\.plural|UIText\.pick|\bt\(|\s\?\s*"|^\s*:\s*"|^\s*\?|\bru:\s*"|isRussian\s*\?|\bru\s*\?|^\s*\(\s*"(?:[^"\\]|\\.)*"\s*,\s*"[^"А-Яа-яЁё]*"\s*\),?\s*$"#)
    /// `Text("Two words")`, `.help("…")`, `accessibilityLabel("…")` с латиницей и без пары.
    static let latinUI = try! NSRegularExpression(
        pattern: #"(?:\bText|\bButton|\bToggle|\.help|accessibilityLabel|accessibilityHint)\(\s*"[A-Za-z][^"]*\s[^"]*""#)
    /// Пара на одной строке: `L("ру", "en")`.
    static let pair = try! NSRegularExpression(pattern: #"\bL\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*"((?:[^"\\]|\\.)*)"\s*\)"#)

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static func hasCyrillic(_ s: String) -> Bool { s.range(of: "[А-Яа-яЁё]", options: .regularExpression) != nil }

    /// Код строки без комментария в конце (` // …`), комментарии целиком — пустая строка.
    static func code(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { return "" }
        if let r = line.range(of: " // ") { return String(line[..<r.lowerBound]) }
        return line
    }

    /// Нарушения в тексте одного файла: «файл:строка: причина — код».
    static func violations(in text: String, file: String) -> [String] {
        var out: [String] = []
        var inMultiline = false
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            // Многострочные литералы `"""` — шаблоны скиллов и промпты, не интерфейс.
            if raw.components(separatedBy: "\"\"\"").count % 2 == 0 { inMultiline.toggle(); continue }
            if inMultiline { continue }
            let line = code(raw)
            guard !line.isEmpty else { continue }
            if exceptions.contains(where: { raw.contains($0.0) }) { continue }
            let where_ = "\(file):\(index + 1)"
            let snippet = line.trimmingCharacters(in: .whitespaces).prefix(120)
            if matches(cyrillicLiteral, line), !matches(paired, line) {
                out.append("\(where_): кириллица без английской пары — \(snippet)")
            }
            if matches(latinUI, line), !matches(paired, line) {
                out.append("\(where_): английская строка интерфейса без русской пары — \(snippet)")
            }
            let ns = line as NSString
            for m in pair.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let ru = ns.substring(with: m.range(at: 1)), en = ns.substring(with: m.range(at: 2))
                if hasCyrillic(en) { out.append("\(where_): кириллица в английской половине — \(snippet)") }
                if en.isEmpty && !ru.isEmpty { out.append("\(where_): пустая английская половина — \(snippet)") }
            }
        }
        return out
    }
}

func runL10nGuardTests() {
    // Сам страж на плохом и хорошем входе: без этого «0 нарушений» ничего не доказывает.
    let bad = """
    Text("Готово")
    .help("Удалить запись")
    .accessibilityLabel("Start recording")
    Button("Open settings") { }
    let x = L("Готово", "")
    let y = L("Готово", "Готово")
    return "Движок не запущен"
    Text("Готово?")
    ("Что решили?", "Что решили?"),
    """
    equal(L10nGuard.violations(in: bad, file: "bad").count, 9, "страж ловит все девять плохих строк")
    let good = """
    Text(L("Готово", "Done"))
    .help(L("Удалить запись", "Delete recording"))
    // Комментарий: «Готово»
    notice(ru ? "Отменено" : "Cancelled")
    NSLog("Mostik: движок упал")
    Text("Mostik")
    ("Что решили?", "What did we decide?"),
    let ru = ["пн", "вт"]  // l10n-guard: пара — en ниже
    let x = L10n.isRussian ? "Скопировано"
                           : "Copied"
    """
    equal(L10nGuard.violations(in: good, file: "good"), [], "страж не трогает пары, комментарии и журнал")

    // Настоящие исходники.
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var files = 0, lines = 0
    var found: [String] = []
    for folder in L10nGuard.folders {
        let dir = root.appendingPathComponent(folder)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names.sorted() where name.hasSuffix(".swift") && !L10nGuard.skipped(name) {
            guard let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) else { continue }
            files += 1
            lines += text.components(separatedBy: "\n").count
            found += L10nGuard.violations(in: text, file: "\(folder)/\(name)")
        }
    }
    check(files > 50, "страж видит исходники: \(files) файлов")
    for v in found { print("L10N \(v)") }
    equal(found.count, 0, "строки интерфейса без пары RU/EN (просмотрено \(files) файлов, \(lines) строк)")
}

func runEngineErrorTextTests() {
    let was = UIText.isRussian
    defer { UIText.isRussian = was }
    UIText.isRussian = true
    equal(EngineErrorText.describe(code: "bad_audio", message: "pcm не base64"), "bad_audio: pcm не base64", "RU: как раньше")
    equal(EngineErrorText.short(code: "model_missing", message: ""), "Модель не установлена")
    // R3a: нехватка памяти на модели голосов — короткая фраза, а не хвост stderr transcriber'а.
    equal(EngineErrorText.short(code: EngineErrorText.diarizationMemory,
                                message: "Не хватило памяти для модели голосов. transcriber (system) завершился с кодом -9: …"),
          "Не хватило памяти для модели голосов")
    UIText.isRussian = false
    equal(EngineErrorText.short(code: EngineErrorText.diarizationMemory, message: "Не хватило памяти…"),
          "Not enough memory for the voice model")
    equal(EngineErrorText.describe(code: "bad_audio", message: "pcm не base64"), "Audio can’t be read", "EN: русский текст движка не показывается")
    equal(EngineErrorText.describe(code: "internal", message: "KeyError: 'x'"), "internal: KeyError: 'x'", "EN: английский текст как есть")
    equal(EngineErrorText.short(code: "internal", message: "модуль встреч недоступен"), "Internal error")
    equal(EngineErrorText.short(code: "polish", message: "нет claude"), "Internal error (polish)")
}

// Страж доступности: кнопка-значок без текста обязана иметь подпись для VoiceOver
// (`.accessibilityLabel` или `.iconHelp`, который ставит и подсказку, и подпись).
enum A11yGuard {
    static let button = try! NSRegularExpression(pattern: #"\bButton\s*(\{|\(action|\(role)"#)

    static func violations(in text: String, file: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        for (i, line) in lines.enumerated() where L10nGuard.matches(button, line) {
            // Метка кнопки — до её стиля или подсказки.
            var label: [String] = []
            for j in i..<min(i + 14, lines.count) {
                label.append(lines[j])
                if lines[j].contains(".buttonStyle") || lines[j].contains(".help(") || lines[j].contains(".iconHelp(") { break }
            }
            let joined = label.joined(separator: "\n")
            let body = joined.components(separatedBy: "label:").last ?? joined
            guard joined.contains("Image(systemName"), body.range(of: #"Text\(|Label\(|KeyCap"#, options: .regularExpression) == nil else { continue }
            let after = lines[i..<min(i + 18, lines.count)].joined(separator: "\n")
            if !after.contains("accessibilityLabel") && !after.contains(".iconHelp(") {
                out.append("\(file):\(i + 1): кнопка-значок без подписи VoiceOver — \(line.trimmingCharacters(in: .whitespaces).prefix(100))")
            }
        }
        return out
    }
}

func runA11yGuardTests() {
    let bad = """
    Button(action: remove) {
        Image(systemName: "xmark")
    }
    .buttonStyle(.plain)
    .help(L("Убрать", "Remove"))
    """
    equal(A11yGuard.violations(in: bad, file: "bad").count, 1, "страж ловит значок без подписи")
    let good = """
    Button(action: remove) {
        Image(systemName: "xmark")
    }
    .buttonStyle(.plain)
    .iconHelp(L("Убрать", "Remove"))
    Button { go() } label: {
        Label(L("Открыть", "Open"), systemImage: "arrow.up.right")
    }
    """
    equal(A11yGuard.violations(in: good, file: "good"), [], "подписанные кнопки и кнопки с текстом проходят")

    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var found: [String] = []
    var buttons = 0
    for folder in ["Sources/MostikUI", "Sources/Mostik"] {
        let dir = root.appendingPathComponent(folder)
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        where name.hasSuffix(".swift") && !L10nGuard.skipped(name) {
            guard let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) else { continue }
            buttons += text.components(separatedBy: "Button").count - 1
            found += A11yGuard.violations(in: text, file: "\(folder)/\(name)")
        }
    }
    for v in found { print("A11Y \(v)") }
    check(buttons > 100, "страж видит кнопки: \(buttons)")
    equal(found.count, 0, "кнопки-значки без подписи VoiceOver")
}
