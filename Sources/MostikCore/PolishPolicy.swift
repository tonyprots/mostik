import Foundation

/// Бэкенд полировщика (D3, G7). `claude` — `claude -p` по подписке, текст уходит в облако
/// Anthropic; `mlx` — локальная модель этапа B (пока не установлена, движок отвечает `unavailable`).
public enum PolishBackend: String, Codable, CaseIterable, Sendable {
    case off, claude, mlx
}

/// Через какую программу идёт пункт «Claude/Codex»: `auto` — Claude Code, а если его нет или вход
/// истёк — Codex. Явный выбор нужен, когда установлены обе, а пользоваться хочется одной.
public enum PolishCLI: String, Codable, CaseIterable, Sendable {
    case auto, claude, codex
}

/// Стили текста (D4) — пресеты промпта полировщика. `dev` — режим разработчика для смешанной
/// речи (V1): в настройках не выбирается, его получают агентные приложения с ручным включением.
/// `task` — «мысли вслух → задача» (A4): цель, контекст, файлы, критерии приёмки, открытые вопросы;
/// включается сценарием (P2) или разово сочетанием ⌃⌘J.
public enum PolishStyle: String, Codable, CaseIterable, Sendable {
    case plain, business, brief, list, dev, task
}

/// Тон перевода (V3): говорю по-русски — вставляется по-английски.
public enum TranslateTone: String, Codable, CaseIterable, Sendable {
    case plain, business, dev
}

/// `polish.translate` протокола: на какой язык и каким тоном.
public struct PolishTranslate: Codable, Equatable, Sendable {
    public var to: String
    public var tone: TranslateTone
    public init(to: String = "en", tone: TranslateTone = .plain) { self.to = to; self.tone = tone }
}

/// Что уходит в `start.polish` / `transcribe_file.polish`.
public struct PolishRequest: Equatable, Sendable {
    public var backend: PolishBackend
    public var style: PolishStyle
    /// Пакет стиля (P4) — id папки в `<MOSTIK_HOME>/styles/`; встаёт на место стиля.
    public var pack: String?
    /// Перевод (V3) вместо причёсывания на языке речи.
    public var translate: PolishTranslate?
    /// Куски причёсывания по ходу (P6): движок шлёт `polish_partial`, приложение вставляет их сразу.
    public var stream: Bool
    /// Сначала текст как распознан, причёсанный — следом событием `polished` (2026-10-21):
    /// приложение заменяет вставку, если поле не трогали.
    public var late: Bool
    public init(backend: PolishBackend, style: PolishStyle, pack: String? = nil, translate: PolishTranslate? = nil,
                stream: Bool = false, late: Bool = false) {
        self.backend = backend; self.style = style; self.pack = pack; self.translate = translate; self.stream = stream
        self.late = late
    }

    /// Причёсывать после вставки можно, когда причёсанный текст — та же мысль в той же форме:
    /// не перевод, не задача и не пакет стиля, без потока и без Enter сценария. Агентные окна — тоже
    /// (Антон, 2026-10-22): отправил раньше — причёсанный текст остаётся в истории.
    public static func allowsLate(_ polish: PolishRequest, autoEnter: Bool, command: Bool) -> Bool {
        polish.backend == .claude && !polish.stream && polish.translate == nil && polish.pack == nil
            && polish.style != .task && !autoEnter && !command
    }
}

/// Настройки причёсывания и политика по приложениям.
///
/// Решение автора: в агентных приложениях полировка по умолчанию выключена —
/// агенту нужен точный текст и блок сомнений, а не пересказ. В остальных включена, если
/// бэкенд выбран. Ручное переопределение по bundle id побеждает оба правила.
public struct PolishSettings: Codable, Equatable, Sendable {
    public var backend: PolishBackend = .off
    public var style: PolishStyle = .plain
    /// Пользователь подтвердил, что с `claude` текст уходит в облако Anthropic (G7).
    /// Любое изменение ставит или снимает метку `cloudConsentFor` (П10).
    public var cloudConsent: Bool = false { didSet { cloudConsentFor = CloudConsentLabel.stamp(cloudConsent) } }
    /// На что дано согласие (`CloudConsentLabel.current`); без метки при загрузке согласие сбрасывается.
    public private(set) var cloudConsentFor: String?
    public var forcedOn: Set<String> = []
    public var forcedOff: Set<String> = []
    /// Правила речи (P3, V4): «новый абзац», «зачеркни», «во-первых…» списком, числа цифрами.
    public var rules: SpeechRuleSettings = SpeechRuleSettings()
    /// Контекст из приложения для причёсывания (P1).
    public var context: PolishContextSettings = PolishContextSettings()
    /// Сценарии по приложению и сайту (P2); первый подошедший побеждает общие настройки.
    public var scenarios: [Scenario] = []
    /// Пакет стиля (P4) вместо `style`; nil — встроенный стиль. Переключается ⌃⌘Y.
    public var pack: String? = nil
    /// Потоковая вставка (P6): причёсанный текст вставляется по предложению, пока модель пишет.
    /// Только локальная модель; если приложение кусков не приняло — вставка целиком, как раньше.
    public var streamInsert: Bool = false
    /// Перевод (V3): куда и каким тоном — для ⌃⌘E и сценариев без своего тона.
    public var translateTo: String = "en"
    public var translateTone: TranslateTone = .plain
    /// Быстрый выключатель в меню строки меню (2026-11-09, Антон): что вернуть при включении.
    /// nil — выключали не им; тогда включают в Настройках, где спрашивается согласие на облако.
    public var pausedBackend: PolishBackend? = nil
    /// Claude Code, Codex или «сам» для пункта «Claude/Codex».
    public var cli: PolishCLI = .auto

    public init(backend: PolishBackend = .off, style: PolishStyle = .plain, cloudConsent: Bool = false,
                forcedOn: Set<String> = [], forcedOff: Set<String> = []) {
        self.backend = backend; self.style = style; self.cloudConsent = cloudConsent
        self.cloudConsentFor = CloudConsentLabel.stamp(cloudConsent)
        self.forcedOn = forcedOn; self.forcedOff = forcedOff
    }

    public init(from decoder: Decoder) throws {
        let d = PolishSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        backend = (try? c.decodeIfPresent(PolishBackend.self, forKey: .backend)) ?? d.backend
        style = (try? c.decodeIfPresent(PolishStyle.self, forKey: .style)) ?? d.style
        cloudConsent = CloudConsentLabel.accepts(
            try c.decodeIfPresent(Bool.self, forKey: .cloudConsent) ?? d.cloudConsent,
            label: try? c.decodeIfPresent(String.self, forKey: .cloudConsentFor))
        cloudConsentFor = CloudConsentLabel.stamp(cloudConsent)
        forcedOn = try c.decodeIfPresent(Set<String>.self, forKey: .forcedOn) ?? d.forcedOn
        forcedOff = try c.decodeIfPresent(Set<String>.self, forKey: .forcedOff) ?? d.forcedOff
        rules = (try? c.decodeIfPresent(SpeechRuleSettings.self, forKey: .rules)) ?? d.rules
        context = (try? c.decodeIfPresent(PolishContextSettings.self, forKey: .context)) ?? d.context
        scenarios = (try? c.decodeIfPresent([Scenario].self, forKey: .scenarios)) ?? d.scenarios
        pack = try? c.decodeIfPresent(String.self, forKey: .pack)
        streamInsert = (try? c.decodeIfPresent(Bool.self, forKey: .streamInsert)) ?? d.streamInsert
        translateTo = (try? c.decodeIfPresent(String.self, forKey: .translateTo)) ?? d.translateTo
        translateTone = (try? c.decodeIfPresent(TranslateTone.self, forKey: .translateTone)) ?? d.translateTone
        pausedBackend = try? c.decodeIfPresent(PolishBackend.self, forKey: .pausedBackend)
        if pausedBackend == .off { pausedBackend = nil }
        cli = (try? c.decodeIfPresent(PolishCLI.self, forKey: .cli)) ?? d.cli
    }

    /// Есть ли что переключать из меню: причёсывание включено или выключено быстрым выключателем.
    public var quickToggleAvailable: Bool { backend != .off || pausedBackend != nil }
    /// Бэкенд, о котором говорит быстрый выключатель: включённый или отложенный.
    public var quickBackend: PolishBackend { backend != .off ? backend : (pausedBackend ?? .off) }

    /// Выключить, запомнив бэкенд, или вернуть запомненный. Согласие на облако не трогается:
    /// `claude` без него и после включения остаётся выключенным (`effectiveBackend`).
    public mutating func setQuickEnabled(_ on: Bool) {
        if on {
            guard backend == .off, let paused = pausedBackend else { return }
            backend = paused
            pausedBackend = nil
        } else {
            guard backend != .off else { return }
            pausedBackend = backend
            backend = .off
        }
    }

    /// Бэкенд, которым действительно можно пользоваться: `claude` без согласия — всё равно что выключено.
    public var effectiveBackend: PolishBackend {
        if backend == .claude && !cloudConsent { return .off }
        return backend
    }

    /// Полировать ли диктовку в этом приложении. nil — не полировать (в `start` уходит без `polish`).
    public func decide(bundleID: String, isAgent: Bool) -> PolishRequest? {
        let backend = effectiveBackend
        guard backend != .off else { return nil }
        if forcedOff.contains(bundleID) { return nil }
        let base = PolishRequest(backend: backend, style: style, pack: pack)
        // 2026-10-21 (Антон): агентные окна тоже полируются — «обычным» (он чинит ослышки и термины)
        // или «разработчиком»; стили, меняющие форму (деловой, кратко, списком, пакеты), агенту не идут.
        // Выключить для приложения — `forcedOff`.
        if isAgent { return PolishRequest(backend: backend, style: style == .dev ? .dev : .plain) }
        return base
    }

    /// Ручное переопределение: true — полировать, false — нет, nil — по правилу.
    public mutating func setOverride(_ bundleID: String, _ on: Bool?) {
        let id = bundleID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        forcedOn.remove(id); forcedOff.remove(id)
        switch on {
        case true?: forcedOn.insert(id)
        case false?: forcedOff.insert(id)
        case nil: break
        }
    }
}

/// Полировка была включена, но текст ушёл без неё — это видно в плашке после диктовки, а не только в логе
/// (Антон, 2026-10-21: «если полировка не происходит, хотя была включена, надо подсвечивать»).
public enum PolishNotice {
    /// Хвост к итогу плашки («Вставлено · без причёсывания — войдите в Claude»); nil — сказать нечего.
    /// `refused` (тишина, обрывки) и `empty` — не сбой: полировать было нечего.
    /// `short` — в плашке уже есть хвост сомнений: одна строка не вмещает и причину.
    public static func suffix(status: String?, short: Bool = false) -> String? {
        switch status {
        case nil, "done", "off", "empty", "refused", "skipped", "pending": return nil  // skipped — сам нажал «Вставить сразу»
        case _ where short: return UIText.pick("без причёсывания", "not polished")
        case "auth": return UIText.pick("без причёсывания — войдите в Claude", "not polished — sign in to Claude")
        case "unavailable": return UIText.pick("без причёсывания — модель недоступна", "not polished — model unavailable")
        case "timeout": return UIText.pick("без причёсывания — нет ответа", "not polished — no response")
        case "offline": return UIText.pick("без причёсывания — нет сети", "not polished — offline")
        default: return UIText.pick("без причёсывания", "not polished")
        }
    }

    /// Сбой, который не пройдёт сам: бэкенд надо чинить (войти, поставить) — отметка до следующей удачи.
    public static func isLasting(_ status: String?) -> Bool { status == "auth" || status == "unavailable" }
}
