import Foundation

// Голос и агенты (П4): адресная вставка в tmux (G5), голосовая отправка (G6), озвучка хода (A1),
// автотег файлов (A3), адресация сессии по имени (A5). Здесь — настройки и разбор речи;
// tmux — `Tmux.swift`, файлы — `FileMentions.swift`, хуки и озвучка — `AgentEvents.swift`.

/// Настройки П4. Всё, что меняет поведение вставки или говорит вслух, выключено по умолчанию;
/// автотег включён, но работает только в приложениях, где `@путь` что-то значит.
public struct AgentVoiceSettings: Codable, Equatable, Sendable {
    /// G5: в терминале с tmux текст уходит в панель с агентом через bracketed paste, а не ⌘V.
    public var tmuxPaste: Bool = false
    /// Какая панель: `auto` — единственная панель с агентом или активная в подключённой сессии;
    /// иначе id панели tmux (`%3`), выбранный в настройках.
    public var tmuxTarget: String = TmuxTargeting.auto
    /// A5: «фронтенду: …» — текст в панель, чьё имя сессии, окна или папка проекта совпали.
    /// Работает только вместе с `tmuxPaste`.
    public var addressing: Bool = true
    /// G6: фраза кончается на «отправь» / «send» — слово снимается, после вставки нажимается Enter.
    public var voiceSend: Bool = false
    /// A3: «в auth check» → `@src/authCheck.ts`, если файл в проекте один такой.
    public var fileMentions: Bool = true
    /// A1: озвучка конца хода и запроса разрешения по хукам Claude Code.
    public var announce: Bool = false
    /// A1: к «готово» добавить первую фразу ответа агента.
    public var announceSummary: Bool = true
    /// A1: голос macOS для русских и английских фраз (`AVSpeechSynthesisVoice.identifier`);
    /// nil — лучший установленный (Premium, затем улучшенный).
    public var voiceRU: String? = nil
    public var voiceEN: String? = nil
    /// A6: пока Claude Code работает, надиктованное в его окно уходит в очередь и доходит до агента
    /// посреди хода (хук `mostik-queue.sh`), а не ждёт в поле ввода.
    public var midTurn: Bool = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = AgentVoiceSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tmuxPaste = try c.decodeIfPresent(Bool.self, forKey: .tmuxPaste) ?? d.tmuxPaste
        tmuxTarget = try c.decodeIfPresent(String.self, forKey: .tmuxTarget) ?? d.tmuxTarget
        addressing = try c.decodeIfPresent(Bool.self, forKey: .addressing) ?? d.addressing
        voiceSend = try c.decodeIfPresent(Bool.self, forKey: .voiceSend) ?? d.voiceSend
        fileMentions = try c.decodeIfPresent(Bool.self, forKey: .fileMentions) ?? d.fileMentions
        announce = try c.decodeIfPresent(Bool.self, forKey: .announce) ?? d.announce
        announceSummary = try c.decodeIfPresent(Bool.self, forKey: .announceSummary) ?? d.announceSummary
        voiceRU = try c.decodeIfPresent(String.self, forKey: .voiceRU)
        voiceEN = try c.decodeIfPresent(String.self, forKey: .voiceEN)
        midTurn = (try? c.decodeIfPresent(Bool.self, forKey: .midTurn)) ?? d.midTurn
    }
}

// MARK: G6 — голосовая отправка

public struct VoiceSendResult: Equatable, Sendable {
    /// Текст без слова-команды.
    public var text: String
    /// Нажать Enter после вставки.
    public var submit: Bool
    public init(text: String, submit: Bool) { self.text = text; self.submit = submit }
}

public enum VoiceSend {
    /// Слова-команды в самом конце фразы.
    public static let words: Set<String> = ["отправь", "send"]
    /// Перед ними команда не срабатывает: «не отправь», «напиши письмо и отправь» (агенту велели
    /// отправить письмо), «I want to send».
    static let blockers: Set<String> = ["не", "и", "а", "чтобы", "not", "don't", "dont", "and", "to", "never",
                                        "can't", "cannot", "won't", "will", "please"]
    /// Пауза между вставкой и Enter: приложение должно успеть принять текст.
    public static let enterDelay: TimeInterval = 0.35
    /// Для панели tmux — меньше: bracketed paste доходит синхронно.
    public static let tmuxEnterDelay: TimeInterval = 0.25

    static let trailingPunctuation: Set<Character> = [".", "!", "?", "…", ",", ";", ":", "—", "–", "-", " ", "\n", "\t"]
    static let terminal: Set<Character> = [".", "!", "?", "…"]
    static let separators: Set<Character> = [",", ";", ":", "—", "–", "-", ".", "!", "?", "…"]

    /// «Поправь тест, отправь.» → «Поправь тест.» + Enter. «Отправь письмо Маше» — без изменений.
    public static func detect(_ text: String) -> VoiceSendResult {
        let unchanged = VoiceSendResult(text: text, submit: false)
        var body = Substring(text)
        var tailPunct: Character?
        while let last = body.last, trailingPunctuation.contains(last) {
            if terminal.contains(last), tailPunct == nil { tailPunct = last }
            body = body.dropLast()
        }
        let isWordChar: (Character) -> Bool = { $0.isLetter || $0 == "'" || $0 == "’" }
        let wordStart = body.lastIndex(where: { !isWordChar($0) }).map { body.index(after: $0) } ?? body.startIndex
        guard wordStart < body.endIndex else { return unchanged }
        let word = body[wordStart...].lowercased()
        guard words.contains(word) else { return unchanged }
        var before = body[..<wordStart]
        // Что стояло перед словом: знак препинания — граница фразы, блокер — часть просьбы.
        var hadSeparator = false
        var beforePunct: Character?
        while let last = before.last, last.isWhitespace || separators.contains(last) {
            if separators.contains(last) { hadSeparator = true }
            if terminal.contains(last), beforePunct == nil { beforePunct = last }
            before = before.dropLast()
        }
        if !hadSeparator, let previous = before.split(whereSeparator: { $0.isWhitespace }).last {
            let p = previous.lowercased().replacingOccurrences(of: "’", with: "'")
            if blockers.contains(p) { return unchanged }
        }
        // Вернуть знак конца фразы, съеденный вместе с командой: «Поправь тест, отправь.» → «Поправь тест.»
        var result = String(before).trimmingCharacters(in: .whitespacesAndNewlines)
        if let punct = beforePunct ?? tailPunct, let last = result.last, !terminal.contains(last) { result.append(punct) }
        return VoiceSendResult(text: result, submit: true)
    }

    /// В терминал переносы строк уходят как LF: CR в tmux и терминалах — это Enter.
    /// П10 р3 Н-8: управляющие знаки — прочь (C0, кроме LF и таба, DEL, C1): `ESC[201~` закрыл бы
    /// bracketed paste раньше времени, и хвост текста выполнился бы в оболочке панели как команда.
    public static func terminalNewlines(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var out = String.UnicodeScalarView()
        for scalar in lines.unicodeScalars {
            let value = scalar.value
            if scalar == "\n" || scalar == "\t" || !(value < 0x20 || value == 0x7F || (0x80...0x9F).contains(value)) {
                out.append(scalar)
            }
        }
        return String(out)
    }
}

/// П10 р3 Н-7: «отправь» и обращение к сессии — команды человека. Если текст прошёл модель
/// (причёсывание, перевод, задача), она могла их дописать — например, следуя инъекции из вывода
/// терминала в контексте. Тогда команда засчитывается, только если она есть и в сказанном до модели.
public enum SpokenCommands {
    /// Текст до модели: после словаря, до причёсывания; nil — модели не было, проверять не по чему.
    public static func spoken(_ result: DictationResult) -> String? {
        guard result.polished else { return nil }
        return (result.unpolishedText ?? result.rawText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// «Отправь» в конце: снимается и жмёт Enter, только если его сказали.
    public static func send(_ text: String, spoken: String?) -> VoiceSendResult {
        let found = VoiceSend.detect(text)
        guard found.submit, let spoken else { return found }
        return VoiceSend.detect(spoken).submit ? found : VoiceSendResult(text: text, submit: false)
    }

    /// Обращение к сессии: та же панель должна найтись и в сказанном.
    public static func address(_ text: String, spoken: String?, candidates: [AddressCandidate]) -> AddressMatch? {
        guard let match = SessionAddress.parse(text, candidates: candidates) else { return nil }
        guard let spoken else { return match }
        return SessionAddress.parse(spoken, candidates: candidates)?.id == match.id ? match : nil
    }
}

// MARK: A5 — адресация сессии по имени

/// Сессия, к которой можно обратиться: id панели и имена (сессия tmux, окно, папка проекта).
public struct AddressCandidate: Equatable, Sendable {
    public var id: String
    public var names: [String]
    public init(id: String, names: [String]) { self.id = id; self.names = names }
}

public struct AddressMatch: Equatable, Sendable {
    public var id: String
    /// Имя, по которому узнали, — для HUD и озвучки.
    public var name: String
    /// Текст без обращения.
    public var rest: String
    public init(id: String, name: String, rest: String) { self.id = id; self.name = name; self.rest = rest }
}

public enum SessionAddress {
    /// Имена, которые tmux и терминалы ставят сами, — по ним не адресуемся.
    static let automaticNames: Set<String> = ["zsh", "bash", "fish", "sh", "node", "claude", "codex", "tmux",
                                              "python", "python3", "vim", "nvim", "login", "ssh", "aider", "gemini",
                                              "opencode", "bun", "deno"]
    /// Окончания дательного и других падежей: «фронтенду», «бэкенду», «мостику».
    static let endings = ["ому", "ему", "ами", "ями", "ом", "ем", "ой", "ей", "ам", "ям", "ах", "ях", "у", "ю", "а", "я", "е", "и", "ы"]

    /// «Фронтенду: поправь тест» → панель frontend, «Поправь тест». Обращение — до трёх слов
    /// перед двоеточием или запятой; без знака — только одно слово в дательном («фронтенду поправь»).
    /// Совпасть должна ровно одна сессия.
    public static func parse(_ text: String, candidates: [AddressCandidate]) -> AddressMatch? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !candidates.isEmpty else { return nil }
        var head: Substring
        var rest: Substring
        var dativeOnly = false
        if let sep = trimmed.firstIndex(where: { $0 == ":" || $0 == "," }),
           trimmed.distance(from: trimmed.startIndex, to: sep) <= 40,
           trimmed[..<sep].split(whereSeparator: { $0.isWhitespace }).count <= 3 {
            head = trimmed[..<sep]
            rest = trimmed[trimmed.index(after: sep)...]
        } else {
            guard let space = trimmed.firstIndex(where: { $0.isWhitespace }) else { return nil }
            head = trimmed[..<space]
            rest = trimmed[space...]
            dativeOnly = true
        }
        var headWords = head.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if let first = headWords.first?.lowercased(), ["to", "для", "сессия", "сессии", "session"].contains(first), headWords.count > 1 {
            headWords.removeFirst()
        }
        let spoken = headWords.joined(separator: " ")
        if dativeOnly {
            guard let last = spoken.lowercased().last, last == "у" || last == "ю" else { return nil }
        }
        let spokenKeys = keys(forSpoken: spoken, inflected: true)
        guard !spokenKeys.isEmpty else { return nil }
        var hits: [(id: String, name: String)] = []
        for candidate in candidates {
            for name in candidate.names where usable(name) {
                if NameKey.matches(spokenKeys, name: name) {
                    if !hits.contains(where: { $0.id == candidate.id }) { hits.append((candidate.id, name)) }
                    break
                }
            }
        }
        guard hits.count == 1 else { return nil }
        var body = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = body.first, first == ":" || first == "," || first == "—" || first == "-" {
            body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        guard !body.isEmpty else { return nil }
        body = body.prefix(1).uppercased() + body.dropFirst()
        return AddressMatch(id: hits[0].id, name: hits[0].name, rest: body)
    }

    /// Годится ли имя для обращения и озвучки: не число и не имя, которое ставит сам tmux.
    public static func usable(_ name: String) -> Bool {
        let key = NameKey.key(name)
        guard key.count >= 3, !key.allSatisfy(\.isNumber) else { return false }
        return !automaticNames.contains(name.lowercased())
    }

    /// Варианты ключа сказанного: как есть и без падежного окончания.
    static func keys(forSpoken spoken: String, inflected: Bool) -> [String] {
        let lower = spoken.lowercased()
        var variants = [lower]
        if inflected, lower.unicodeScalars.contains(where: { NameKey.isCyrillic($0) }) {
            for ending in endings where lower.hasSuffix(ending) && lower.count - ending.count >= 3 {
                variants.append(String(lower.dropLast(ending.count)))
            }
        }
        var keys: [String] = []
        for v in variants {
            let k = NameKey.key(v)
            if k.count >= 3, !keys.contains(k) { keys.append(k) }
        }
        return keys
    }
}

/// Ключ имени для сравнения сказанного с написанным: латиница, без разделителей и регистра,
/// кириллица транслитом. Остов — без гласных и двойных букв: «бэкенд» и backend → bknd.
public enum NameKey {
    static let translit: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e", "ж": "zh", "з": "z", "и": "i",
        "й": "i", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t",
        "у": "u", "ф": "f", "х": "h", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "sch", "ъ": "", "ы": "y", "ь": "",
        "э": "e", "ю": "yu", "я": "ya",
    ]

    static func isCyrillic(_ s: Unicode.Scalar) -> Bool { (0x0400...0x04FF).contains(s.value) }

    public static func key(_ text: String) -> String {
        var out = ""
        for ch in text.lowercased() {
            if let t = translit[ch] { out += t; continue }
            if ch.isASCII, ch.isLetter || ch.isNumber { out.append(ch) }
        }
        return out
    }

    public static func skeleton(_ key: String) -> String {
        var s = key.replacingOccurrences(of: "ck", with: "k").replacingOccurrences(of: "ph", with: "f")
        s = String(s.map { ch -> Character in
            switch ch { case "c", "q": return "k"; case "w": return "v"; default: return ch }
        }).replacingOccurrences(of: "x", with: "ks")
        var out = ""
        for ch in s where !"aeiouy".contains(ch) {
            if out.last != ch { out.append(ch) }
        }
        return out
    }

    /// Совпадение по ключу; по остову — только для имён из трёх и больше согласных.
    static func matches(_ spokenKeys: [String], name: String) -> Bool {
        let nameKey = key(name)
        guard !nameKey.isEmpty else { return false }
        let nameSkeleton = skeleton(nameKey)
        for k in spokenKeys {
            if k == nameKey { return true }
            if nameSkeleton.count >= 3, skeleton(k) == nameSkeleton { return true }
        }
        return false
    }
}
