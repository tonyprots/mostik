import Foundation

// П6-А: что добавляется к причёсыванию сверх стиля (D4).
// - P1 — контекст из приложения: выделение, текст у курсора, буфер обмена, адрес страницы;
// - P2 — сценарии по приложению и сайту;
// - P3, V4 — правила речи и числа цифрами (сами правила — в движке, `speech_rules.py`);
// - P4 — пакеты стилей (файлы читает движок, здесь — переключение по кругу);
// - P6 — потоковая вставка;
// - V3, A4 — разовые режимы «перевести» и «задача».

// MARK: P3, V4 — правила речи

/// Какие правила речи применять (`start.rules`). Правила работают и без причёсывания: они
/// детерминированные, их снимает движок до модели и после распознавания.
public struct SpeechRuleSettings: Codable, Equatable, Sendable {
    /// «Новый абзац», «новая строка» — разрыв строки вместо слов.
    public var commands: Bool = true
    /// «Зачеркни» в конце фразы — убрать предыдущее предложение.
    public var scratch: Bool = true
    /// «Во-первых… во-вторых…» — список, и только с двух пунктов (V4).
    public var lists: Bool = false
    /// Числа цифрами (V4): «триста двадцать» → 320, «в девятнадцать тридцать» → 19:30.
    public var numbers: Bool = false

    public init(commands: Bool = true, scratch: Bool = true, lists: Bool = false, numbers: Bool = false) {
        self.commands = commands; self.scratch = scratch; self.lists = lists; self.numbers = numbers
    }

    public init(from decoder: Decoder) throws {
        let d = SpeechRuleSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        commands = (try? c.decodeIfPresent(Bool.self, forKey: .commands)) ?? d.commands
        scratch = (try? c.decodeIfPresent(Bool.self, forKey: .scratch)) ?? d.scratch
        lists = (try? c.decodeIfPresent(Bool.self, forKey: .lists)) ?? d.lists
        numbers = (try? c.decodeIfPresent(Bool.self, forKey: .numbers)) ?? d.numbers
    }

    public var anyOn: Bool { commands || scratch || lists || numbers }

    /// `start.rules` протокола; nil — правила не нужны, поле не отправляется.
    public var payload: [String: Bool]? {
        anyOn ? ["commands": commands, "scratch": scratch, "lists": lists, "numbers": numbers] : nil
    }
}

// MARK: P1 — контекст из приложения

/// Что из приложения можно отдать полировщику. Контекст — данные, не инструкции: движок кладёт
/// его в метки `<context>` с защитой от инъекции (V2) и просит модель только сверять имена и термины.
public struct PolishContextSettings: Codable, Equatable, Sendable {
    /// Выделение и текст у курсора (до 256 знаков с каждой стороны).
    public var enabled: Bool = true
    /// Буфер обмена — по умолчанию нет: там бывают пароли и чужие данные.
    public var clipboard: Bool = false
    /// Отдавать контекст и в облако (`claude -p`). По умолчанию только локальной модели.
    public var toCloud: Bool = false
    /// Свои исключения к встроенным: bundle id приложений и домены сайтов.
    public var excludedApps: [String] = []
    public var excludedHosts: [String] = []

    public init(enabled: Bool = true, clipboard: Bool = false, toCloud: Bool = false,
                excludedApps: [String] = [], excludedHosts: [String] = []) {
        self.enabled = enabled; self.clipboard = clipboard; self.toCloud = toCloud
        self.excludedApps = excludedApps; self.excludedHosts = excludedHosts
    }

    public init(from decoder: Decoder) throws {
        let d = PolishContextSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
        clipboard = (try? c.decodeIfPresent(Bool.self, forKey: .clipboard)) ?? d.clipboard
        toCloud = (try? c.decodeIfPresent(Bool.self, forKey: .toCloud)) ?? d.toCloud
        excludedApps = (try? c.decodeIfPresent([String].self, forKey: .excludedApps)) ?? d.excludedApps
        excludedHosts = (try? c.decodeIfPresent([String].self, forKey: .excludedHosts)) ?? d.excludedHosts
    }
}

/// Сырой контекст из поля и окружения — до фильтров.
public struct ContextSource: Equatable, Sendable {
    public var bundleID: String
    /// Поле пароля — контекст не берём вовсе.
    public var secure: Bool
    /// Значение поля и выделение в UTF-16 (как отдаёт AX).
    public var value: String?
    public var selection: CaretRange?
    public var clipboard: String?
    /// Домен страницы в браузере: `mail.yandex.ru`.
    public var host: String?

    public init(bundleID: String, secure: Bool = false, value: String? = nil, selection: CaretRange? = nil,
                clipboard: String? = nil, host: String? = nil) {
        self.bundleID = bundleID; self.secure = secure; self.value = value; self.selection = selection
        self.clipboard = clipboard; self.host = host
    }
}

public enum PolishContext {
    /// Столько знаков до и после курсора — как в движке (`CONTEXT_AROUND`).
    public static let around = 256
    public static let block = 600

    /// Менеджеры паролей, связка ключей, банковские клиенты — контекст отсюда не берём никогда.
    public static let excludedApps: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "com.apple.keychainaccess", "com.apple.Passwords", "in.sinew.Enpass-Desktop",
        "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal", "org.keepassxc.keepassxc", "com.keepersecurity.passwordmanager",
        "ru.sberbank.sberbankonline", "com.tinkoff.bank", "ru.tbank.app", "ru.alfabank.mobile",
    ]

    /// Слова в домене, по которым страница считается чувствительной: банки, вход, госуслуги, пароли.
    public static let sensitiveHostWords = [
        "bank", "sber", "tinkoff", "tbank", "vtb", "alfa", "raiffeisen", "gazprombank", "paypal", "stripe",
        "gosuslugi", "nalog", "login", "signin", "sign-in", "auth", "passport", "accounts.", "id.yandex",
        "1password", "bitwarden", "lastpass", "keeper", "vault",
    ]

    /// Домен из адреса: `https://mail.yandex.ru/inbox` → `mail.yandex.ru`. Путь и параметры не берём.
    public static func host(of url: String?) -> String? {
        guard let url, !url.isEmpty else { return nil }
        if let host = URL(string: url)?.host, !host.isEmpty { return host.lowercased() }
        return nil
    }

    /// `host` совпадает с доменом из списка сам или как поддомен.
    public static func hostMatches(_ host: String, _ domain: String) -> Bool {
        let h = host.lowercased(), d = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !d.isEmpty else { return false }
        return h == d || h.hasSuffix("." + d)
    }

    public static func isSensitive(host: String) -> Bool {
        let h = host.lowercased()
        return sensitiveHostWords.contains { h.contains($0) }
    }

    /// Можно ли брать контекст для этой диктовки. `backend` — бэкенд её причёсывания; без
    /// причёсывания контекст не нужен вовсе.
    public static func allowed(_ source: ContextSource, settings: PolishContextSettings, backend: PolishBackend?) -> Bool {
        guard settings.enabled, let backend, backend != .off else { return false }
        if backend == .claude && !settings.toCloud { return false }
        if source.secure { return false }
        if excludedApps.contains(source.bundleID) || settings.excludedApps.contains(source.bundleID) { return false }
        if let host = source.host {
            if isSensitive(host: host) { return false }
            if settings.excludedHosts.contains(where: { hostMatches(host, $0) }) { return false }
        }
        return true
    }

    /// `context` протокола: `before`, `after`, `selection`, `clipboard`, `page`. nil — нечего отдавать.
    public static func make(_ source: ContextSource, settings: PolishContextSettings, backend: PolishBackend?) -> [String: String]? {
        guard allowed(source, settings: settings, backend: backend) else { return nil }
        var out: [String: String] = [:]
        if let value = source.value, !value.isEmpty {
            let units = Array(value.utf16)
            let caret = source.selection ?? CaretRange(location: units.count, length: 0)
            let start = min(max(0, caret.location), units.count)
            let end = min(units.count, start + max(0, caret.length))
            let before = String(decoding: units[max(0, start - around * 2)..<start], as: UTF16.self)
            let after = String(decoding: units[end..<min(units.count, end + around * 2)], as: UTF16.self)
            let selection = String(decoding: units[start..<end], as: UTF16.self)
            out["before"] = String(before.suffix(around))
            out["after"] = String(after.prefix(around))
            out["selection"] = String(selection.prefix(block))
        }
        if settings.clipboard, let clip = source.clipboard {
            out["clipboard"] = String(clip.prefix(block))
        }
        if let host = source.host { out["page"] = host }
        out = out.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return out.isEmpty ? nil : out
    }
}

// MARK: P2 — сценарии по приложению и сайту

/// Сценарий: в каком приложении или на каком сайте что делать с диктовкой. nil в поле — как в
/// общих настройках.
public struct Scenario: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var enabled: Bool = true
    /// bundle id приложений: `com.tinyspeck.slackmacgap`.
    public var apps: [String] = []
    /// Домены сайтов: `mail.yandex.ru` — и поддомены. Сайт узнаётся по адресу страницы в браузере.
    public var hosts: [String] = []
    /// Язык распознавания: `ru`, `en`.
    public var language: String? = nil
    /// Чем причёсывать; `.off` — вставлять как сказано.
    public var backend: PolishBackend? = nil
    public var style: PolishStyle? = nil
    public var pack: String? = nil
    public var translate: PolishTranslate? = nil
    /// Нажать Enter после вставки.
    public var autoEnter: Bool? = nil

    public init(id: String = UUID().uuidString, name: String, enabled: Bool = true, apps: [String] = [],
                hosts: [String] = [], language: String? = nil, backend: PolishBackend? = nil, style: PolishStyle? = nil,
                pack: String? = nil, translate: PolishTranslate? = nil, autoEnter: Bool? = nil) {
        self.id = id; self.name = name; self.enabled = enabled; self.apps = apps; self.hosts = hosts
        self.language = language; self.backend = backend; self.style = style; self.pack = pack
        self.translate = translate; self.autoEnter = autoEnter
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        apps = (try? c.decodeIfPresent([String].self, forKey: .apps)) ?? []
        hosts = (try? c.decodeIfPresent([String].self, forKey: .hosts)) ?? []
        language = try? c.decodeIfPresent(String.self, forKey: .language)
        backend = try? c.decodeIfPresent(PolishBackend.self, forKey: .backend)
        style = try? c.decodeIfPresent(PolishStyle.self, forKey: .style)
        pack = try? c.decodeIfPresent(String.self, forKey: .pack)
        translate = try? c.decodeIfPresent(PolishTranslate.self, forKey: .translate)
        autoEnter = try? c.decodeIfPresent(Bool.self, forKey: .autoEnter)
    }

    /// Меняет ли сценарий причёсывание (тогда он включает его и в приложениях агентов).
    public var touchesPolish: Bool { style != nil || pack != nil || translate != nil || (backend != nil && backend != .off) }

    /// Готовые заготовки для «Добавить сценарий».
    public static var presets: [Scenario] { [
        Scenario(id: "preset-slack", name: "Slack", apps: ["com.tinyspeck.slackmacgap"], hosts: ["app.slack.com"],
                 style: .plain),
        Scenario(id: "preset-mail", name: UIText.pick("Почта", "Mail"), apps: ["com.apple.mail"], hosts: ["mail.yandex.ru", "mail.google.com"],
                 style: .business),
        Scenario(id: "preset-agent-task", name: UIText.pick("Задача для агента", "Task for an agent"), apps: [], style: .task),
    ] }
}

public enum ScenarioBook {
    /// Первый подходящий сценарий: по сайту или по приложению. Сайт точнее приложения: сценарий
    /// с совпавшим доменом побеждает сценарий, подошедший только по bundle id браузера.
    public static func match(_ scenarios: [Scenario], bundleID: String, host: String?) -> Scenario? {
        let active = scenarios.filter { $0.enabled && !($0.apps.isEmpty && $0.hosts.isEmpty) }
        if let host {
            if let byHost = active.first(where: { s in s.hosts.contains { PolishContext.hostMatches(host, $0) } }) {
                return byHost
            }
        }
        return active.first { $0.apps.contains(bundleID) }
    }
}

// MARK: V3, A4 — разовые режимы

/// Режим на одну следующую диктовку: ⌃⌘E — перевести, ⌃⌘J — оформить задачей.
public enum PolishMode: String, Codable, Equatable, Sendable {
    case translate, task
}

/// Что решено на старте записи: язык, причёсывание и Enter.
public struct DictationPlan: Equatable, Sendable {
    /// Язык распознавания из сценария; nil — как в настройках.
    public var language: String?
    public var polish: PolishRequest?
    /// Нажать Enter после вставки (сценарий).
    public var autoEnter: Bool
    /// Имя сработавшего сценария — для подписи в HUD.
    public var scenario: String?
    public var mode: PolishMode?

    public init(language: String? = nil, polish: PolishRequest?, autoEnter: Bool = false,
                scenario: String? = nil, mode: PolishMode? = nil) {
        self.language = language; self.polish = polish; self.autoEnter = autoEnter
        self.scenario = scenario; self.mode = mode
    }
}

extension PolishSettings {
    /// Бэкенд с учётом согласия на облако: `claude` без согласия — выключено.
    func usable(_ backend: PolishBackend) -> PolishBackend {
        backend == .claude && !cloudConsent ? .off : backend
    }

    /// Полный план диктовки: общее правило (`decide`), затем сценарий (P2), затем разовый режим.
    /// Сценарий и разовый режим — явная воля, они включают причёсывание и в приложениях агентов.
    public func plan(bundleID: String, host: String?, isAgent: Bool, mode: PolishMode? = nil) -> DictationPlan {
        var polish = decide(bundleID: bundleID, isAgent: isAgent)
        var plan = DictationPlan(polish: polish, mode: mode)
        if let scenario = ScenarioBook.match(scenarios, bundleID: bundleID, host: host) {
            plan.scenario = scenario.name
            plan.language = scenario.language
            plan.autoEnter = scenario.autoEnter ?? false
            if scenario.backend == .off {
                polish = nil
            } else if scenario.touchesPolish {
                let backend = usable(scenario.backend ?? backend)
                if backend == .off {
                    polish = nil
                } else {
                    var request = polish ?? PolishRequest(backend: backend, style: style, pack: pack)
                    request.backend = backend
                    if let style = scenario.style { request.style = style; request.pack = nil }
                    if let pack = scenario.pack { request.pack = pack }
                    if let translate = scenario.translate { request.translate = translate }
                    polish = request
                }
            }
        }
        if let mode {
            let backend = usable(polish?.backend ?? backend)
            if backend != .off {
                var request = polish ?? PolishRequest(backend: backend, style: isAgent ? .dev : style, pack: isAgent ? nil : pack)
                request.backend = backend
                switch mode {
                case .translate:
                    request.translate = PolishTranslate(to: translateTo, tone: request.translate?.tone ?? translateTone)
                case .task:
                    request.style = .task; request.pack = nil; request.translate = nil
                }
                polish = request
            }
        }
        // Куски по ходу — только у локальной модели (у `claude -p` их нет) и не для агентов:
        // там в конец дописывается блок сомнений, его надо ставить к полному тексту.
        if var request = polish {
            request.stream = streamInsert && request.backend == .mlx && !isAgent && request.style != .task
            polish = request
        }
        plan.polish = polish
        return plan
    }

    /// ⌃⌘Y: следующий стиль по кругу — встроенные, затем пакеты из папки стилей.
    public func nextStyle(packs: [String]) -> (style: PolishStyle, pack: String?) {
        let builtIn: [PolishStyle] = [.plain, .business, .brief, .list]
        var ring: [(PolishStyle, String?)] = builtIn.map { ($0, nil) }
        ring += packs.map { (style, $0) }
        let current = ring.firstIndex { pair in
            if let pack { return pair.1 == pack }
            return pair.1 == nil && pair.0 == style
        } ?? -1
        let next = ring[(current + 1) % ring.count]
        return (next.0, next.1)
    }
}

// MARK: P4 — пакеты стилей

/// Пакет стиля из папки `<MOSTIK_HOME>/styles/` (P4).
public struct StylePackInfo: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var terms: Int
    public var replacements: Int
    public var path: String
    public init(id: String, name: String, terms: Int = 0, replacements: Int = 0, path: String = "") {
        self.id = id; self.name = name; self.terms = terms; self.replacements = replacements; self.path = path
    }
}

// MARK: P6 — потоковая вставка

public enum StreamInsert {
    /// Знаки конца предложения: вставляем только целые предложения, хвост ждёт следующего куска.
    static let enders: Set<Character> = [".", "!", "?", "…", "\n"]

    /// Целые предложения из куска: до последнего конца предложения, за которым пробел или перевод строки.
    public static func complete(_ partial: String) -> String {
        var cut: String.Index?
        var i = partial.startIndex
        while i < partial.endIndex {
            let ch = partial[i]
            let next = partial.index(after: i)
            if ch == "\n" {
                cut = next
            } else if enders.contains(ch), next < partial.endIndex, partial[next] == " " {
                cut = partial.index(after: next)  // с пробелом: следующий кусок начнётся без него
            }
            i = next
        }
        guard let cut else { return "" }
        return String(partial[..<cut])
    }

    /// Что допечатать к уже вставленному. nil — кусок разошёлся со вставленным (модель
    /// переписала начало) или нового целого предложения нет.
    public static func append(inserted: String, partial: String) -> String? {
        let whole = complete(partial)
        guard whole.count > inserted.count, whole.hasPrefix(inserted) else { return nil }
        return String(whole.dropFirst(inserted.count))
    }

    public enum Finish: Equatable, Sendable {
        /// Ничего не вставлено по ходу — обычная доставка целиком.
        case whole
        /// Вставленное — начало итога: допечатать хвост (может быть пустым).
        case append(String)
        /// Итог разошёлся со вставленным: выделить назад `count` знаков (UTF-16) и вставить итог.
        case replace(count: Int, with: String)
    }

    /// Чем закончить, когда пришёл итог.
    public static func finish(inserted: String, final: String) -> Finish {
        guard !inserted.isEmpty else { return .whole }
        if final.hasPrefix(inserted) { return .append(String(final.dropFirst(inserted.count))) }
        // Пробелы в конце вставленного движок мог срезать в итоге.
        let trimmed = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, final.hasPrefix(trimmed) {
            let rest = String(final.dropFirst(trimmed.count))
            let spacer = String(inserted.dropFirst(trimmed.count))
            if rest.isEmpty { return .append("") }
            return .append(rest.hasPrefix(spacer) ? String(rest.dropFirst(spacer.count)) : rest)
        }
        return .replace(count: inserted.utf16.count, with: final)
    }

    /// Заменять можно, только если поле не трогали: перед курсором ровно вставленное нами.
    public static func canReplace(field: FieldSnapshot?, inserted: String) -> Bool {
        guard let field, !field.isSecure, let value = field.value, let caret = field.selection, caret.length == 0 else {
            return false
        }
        let units = Array(value.utf16)
        let end = min(units.count, max(0, caret.location))
        let count = inserted.utf16.count
        guard count > 0, end >= count else { return false }
        return Array(units[(end - count)..<end]) == Array(inserted.utf16)
    }
}
