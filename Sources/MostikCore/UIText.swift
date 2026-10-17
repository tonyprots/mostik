import Foundation

/// Язык интерфейса для всех слоёв: MostikCore, MostikKit, MostikUI.
/// `L10n.isRussian` в MostikUI — то же значение; снимки и тесты переключают его явно.
public enum UIText {
    nonisolated(unsafe) public static var isRussian: Bool = {
        let preferred = Locale.preferredLanguages.first ?? Locale.current.identifier
        return preferred.lowercased().hasPrefix("ru")
    }()

    /// Строка интерфейса: русский и английский рядом, в месте использования.
    public static func pick(_ ru: String, _ en: String) -> String {
        let s = isRussian ? ru : en
        return neutralName ? neutralize(s, russian: isRussian) : s
    }

    /// Форма слова по числу: 1 модель, 2 модели, 5 моделей; по-английски — единственное и множественное.
    public static func plural(_ n: Int, ru one: String, _ few: String, _ many: String, en singular: String, _ pluralEN: String) -> String {
        guard isRussian else { return "\(n) " + (n == 1 ? singular : pluralEN) }
        let mod10 = n % 10, mod100 = n % 100
        let word: String
        if mod10 == 1 && mod100 != 11 { word = one }
        else if (2...4).contains(mod10) && !(12...14).contains(mod100) { word = few }
        else { word = many }
        return "\(n) \(word)"
    }

    // MARK: Нейтральное имя (слепые тесты)

    /// Снимки для слепых тестов (`MostikSnapshots --neutral-name`): в подписях нет имени продукта,
    /// вместо него «приложение» / «the app». В обычной работе и обычных снимках выключено.
    nonisolated(unsafe) public static var neutralName = false

    /// Слова, после которых «Mostik» стоит в родительном падеже: «папка Mostik» → «папка приложения».
    private static let genitiveBefore: Set<String> = [
        "самого", "папку", "папки", "папке", "захвата", "данными", "данные", "настройках", "из", "у", "для", "окна", "окне", "имени",
    ]

    /// Заменяет имя продукта на нейтральное. Падеж в русском — по предыдущему слову, регистр — по началу фразы;
    /// в путях — нейтральные `App.app` и `app`.
    public static func neutralize(_ text: String, russian: Bool) -> String {
        guard text.range(of: "mostik", options: .caseInsensitive) != nil else { return text }
        let pattern = #"(?<![\w.\-/])(Mostik|mostik)(’s|'s)?(?![\w\-]|\.app)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let before = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            out += before
            let trimmed = out.trimmingCharacters(in: .whitespaces)
            let sentenceStart = trimmed.isEmpty || [".", "!", "?", "«", "“", "\""].contains { trimmed.hasSuffix($0) }
            let previous = trimmed.split(whereSeparator: { $0 == " " }).last.map { String($0).lowercased() } ?? ""
            let possessive = m.range(at: 2).location != NSNotFound
            var word: String
            if ns.substring(with: m.range(at: 1)) == "mostik" {
                // Команда в терминале — нейтральное имя команды, без падежей.
                out += "app" + (possessive ? ns.substring(with: m.range(at: 2)) : "")
                cursor = m.range.location + m.range.length
                continue
            } else if russian {
                // «сам Mostik» → «само приложение»: местоимение согласуем с новым словом среднего рода.
                if previous == "сам", let r = out.range(of: "ам ", options: [.backwards, .anchored], range: out.index(out.endIndex, offsetBy: -3, limitedBy: out.startIndex).map { $0..<out.endIndex } ?? out.startIndex..<out.endIndex) {
                    out.replaceSubrange(r, with: "амо ")
                }
                if previous == "в" || previous == "во" { word = "приложении" }
                else if genitiveBefore.contains(previous) { word = "приложения" }
                else { word = "приложение" }
            } else {
                word = possessive ? "the app’s" : "the app"
            }
            if sentenceStart { word = word.prefix(1).uppercased() + word.dropFirst() }
            out += word
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        // Пути и команды тоже выдают продукт: «/Applications/Mostik.app/…/mostik» → «/Applications/App.app/…/app».
        return out.replacingOccurrences(of: "Mostik.app", with: "App.app")
            .replacingOccurrences(of: #"(?<=[/~])mostik"#, with: "app", options: .regularExpression)
    }
}

/// Ошибка движка для человека. Движок пишет сообщения по-русски (это журнал и CLI),
/// поэтому в английском интерфейсе русский текст заменяется фразой по коду ошибки;
/// подробности остаются в `logs/engine.log`.
public enum EngineErrorText {
    /// Встреча упала на модели голосов от нехватки памяти: её можно повторить без диаризации (R3a).
    public static let diarizationMemory = "diarization_memory"
    /// Не сбой: на этом Mac нет `fluidaudiocli`, встреча расшифрована без разделения по голосам
    /// (`transcript.code` при `status: done`).
    public static let diarizationUnavailable = "diarization_unavailable"
    /// Не сбой встречи: модель голосов упала дважды, встреча расшифрована одним собеседником.
    public static let diarizationFailed = "diarization_failed"

    static func phrase(_ code: String) -> String {
        switch code {
        case diarizationMemory: return UIText.pick("Не хватило памяти для модели голосов", "Not enough memory for the voice model")
        case "model_missing": return UIText.pick("Модель не установлена", "Model isn’t installed")
        case "bad_audio": return UIText.pick("Звук не читается", "Audio can’t be read")
        case "import_failed": return UIText.pick("Импорт не удался", "Import failed")
        case "speaker": return UIText.pick("Не удалось изменить собеседников", "Couldn’t update speakers")
        case "not_found": return UIText.pick("Не найдено", "Not found")
        case "bad_request": return UIText.pick("Неверный запрос", "Invalid request")
        case "consent_required": return UIText.pick("Без согласия в облако не отправлено", "Not sent to the cloud without consent")
        case "sensitive": return UIText.pick("Встреча только для этого Mac — в облако не отправлена", "Meeting is for this Mac only — not sent to the cloud")
        default: return UIText.pick("Внутренняя ошибка", "Internal error") + (code.isEmpty || code == "internal" ? "" : " (\(code))")
        }
    }

    static func russian(_ s: String) -> Bool { s.range(of: "[А-Яа-яЁё]", options: .regularExpression) != nil }

    /// Короткая причина — для строки состояния встречи: сообщение движка или фраза по коду.
    public static func short(code: String, message: String) -> String {
        // Для этого кода у строки встречи есть своё действие — показываем короткую фразу, не хвост stderr.
        if message.isEmpty || code == diarizationMemory { return phrase(code) }
        if !UIText.isRussian && russian(message) { return phrase(code) }
        return message
    }

    /// Полное описание — для `EngineError.engine`: «код: сообщение» как раньше, по-английски без русского текста.
    public static func describe(code: String, message: String) -> String {
        if message.isEmpty { return code }
        if !UIText.isRussian && russian(message) { return phrase(code) }
        return "\(code): \(message)"
    }
}

/// Имя приложения для списков исключений. Finder добавляет к копии « 2» («Telegram 2.app»),
/// и LaunchServices может вернуть именно копию — поэтому сначала имя из Info.plist,
/// а имя файла — без «.app» и без номера копии.
public enum AppDisplayName {
    public static func resolve(bundleID: String, bundleName: String?, fileName: String?) -> String {
        if let name = bundleName?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        if var file = fileName?.trimmingCharacters(in: .whitespaces), !file.isEmpty {
            if file.hasSuffix(".app") { file = String(file.dropLast(4)) }
            if let r = file.range(of: #" \d+$"#, options: .regularExpression) { file.removeSubrange(r) }
            if !file.isEmpty { return file }
        }
        let last = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return last.prefix(1).uppercased() + last.dropFirst()
    }
}
