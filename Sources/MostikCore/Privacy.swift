import Foundation

// Приватность: без ведома пользователя ничего не уходит с компьютера.
// Здесь чистая логика решений «можно ли в облако» — Swift-слой только исполняет их,
// движок проверяет то же самое ещё раз (`engine/mostik_engine/privacy.py`).

extension PolishBackend {
    /// Бэкенд, с которым текст уходит с этого Mac. Сейчас это только `claude` (`claude -p`).
    public var isCloud: Bool { self == .claude }
}

// MARK: - ИИ встреч и облако (M5–M8)

/// Облачный путь для встреч: сводки, рецепты, архив.
///
/// Согласий два: `meetingAIConsent` — «отдавать расшифровки модели вообще» (для локальной модели
/// его достаточно) и `meetingAICloudConsent` — «расшифровка уйдёт в Anthropic». Облачное даётся
/// только на своём экране и сбрасывается при любой смене бэкенда: согласие, данное при локальной
/// модели, облако не открывает.
public enum MeetingCloudPolicy {
    /// Можно ли сейчас отдать расшифровку в облако.
    public static func cloudAllowed(_ settings: MostikSettings) -> Bool {
        settings.meetingEffectiveBackend.isCloud && settings.meetingAIConsent && settings.meetingAICloudConsent
    }

    /// Бэкенд для встреч с учётом обоих согласий; `sensitive` — встреча «никуда, кроме этого Mac».
    public static func backend(_ settings: MostikSettings, sensitive: Bool = false) -> PolishBackend {
        let backend = settings.meetingEffectiveBackend
        guard backend != .off, settings.meetingAIConsent else { return .off }
        if backend.isCloud { return !sensitive && cloudAllowed(settings) ? backend : .off }
        return backend
    }

    /// Применить к новым настройкам правило сброса: сменился бэкенд (или отозвано облачное
    /// согласие причёсывания, что для встреч то же самое) — облачного согласия встреч больше нет.
    public static func reconcile(old: MostikSettings, new: MostikSettings) -> MostikSettings {
        var result = new
        // Своя модель встреч (`meetingBackend`) не зависит от смены модели диктовки.
        let followsDictation = new.meetingBackend == nil && old.meetingBackend == nil
        // Сбрасывается согласие, данное раньше; данное тем же действием, что сменило модель
        // (онбординг: «Claude» с текстом про Anthropic), остаётся.
        if old.meetingAICloudConsent, old.meetingEffectiveBackend != new.meetingEffectiveBackend
            || (followsDictation && old.polish.backend != new.polish.backend) {
            result.meetingAICloudConsent = false
        }
        if !result.meetingAIConsent { result.meetingAICloudConsent = false }
        return result
    }

    /// Что делает переключатель «Заметки и сводка встреч» в Настройках.
    public enum ToggleAction: Equatable, Sendable {
        /// Сохранить настройки как есть.
        case apply(MostikSettings)
        /// Облачного согласия нет — открыть экран «расшифровка уйдёт в Anthropic», настройки не трогать.
        case askCloudConsent
    }

    /// Состояние переключателя: для облака — только при облачном согласии.
    public static func toggleIsOn(_ settings: MostikSettings) -> Bool {
        settings.meetingEffectiveBackend.isCloud ? cloudAllowed(settings) : settings.meetingAIConsent
    }

    /// Переключатель сам облачного согласия не ставит: при облачном бэкенде он только открывает экран.
    public static func toggle(_ on: Bool, settings: MostikSettings) -> ToggleAction {
        var s = settings
        guard on else {
            s.revokeMeetingAI()
            return .apply(s)
        }
        if s.meetingEffectiveBackend.isCloud { return .askCloudConsent }
        s.meetingAIConsent = true
        return .apply(s)
    }
}

extension MostikSettings {
    /// Модель, которой на самом деле работают встречи. Своя (`meetingBackend`) не требует согласия
    /// на причёсывание: для облака у встреч своё согласие (`meetingAICloudConsent`).
    public var meetingEffectiveBackend: PolishBackend {
        meetingBackend ?? polish.effectiveBackend
    }

    /// Согласие с экрана, где сказано, куда уйдёт расшифровка. Для облачного бэкенда ставит
    /// и облачное согласие — поэтому вызывать только с экрана, где прямо написано про Anthropic.
    public mutating func grantMeetingAI() {
        meetingAIConsent = true
        if meetingEffectiveBackend.isCloud { meetingAICloudConsent = true }
    }

    public mutating func revokeMeetingAI() {
        meetingAIConsent = false
        meetingAICloudConsent = false
    }
}

// MARK: - Поле consent в командах движка

/// Какие согласия действуют сейчас — снимок для `EngineClient`, который ставит поле `consent`.
public struct CloudGrants: Equatable, Sendable {
    /// Диктовка: причёсывание, правка голосом, перевод, команды-намерения (G7).
    public var dictation: Bool
    /// Встречи: сводки, рецепты, архив.
    public var meetings: Bool

    public init(dictation: Bool = false, meetings: Bool = false) {
        self.dictation = dictation; self.meetings = meetings
    }

    public init(settings: MostikSettings) {
        dictation = settings.polish.cloudConsent
        meetings = MeetingCloudPolicy.cloudAllowed(settings)
    }
}

/// Глубокая защита: движок отказывает облачной команде без `consent: true`. Приложение ставит
/// поле само, по снимку согласий, — и только при действующем согласии на этот вид данных.
public enum CloudConsentStamp {
    public enum Purpose: Sendable { case dictation, meetings }

    static let dictationCommands: Set<String> = ["start", "transcribe_file", "polish_text", "edit", "intent", "warmup"]

    /// Вид данных команды; неизвестная команда — nil: облачного согласия у неё нет.
    public static func purpose(of cmd: String) -> Purpose? {
        if dictationCommands.contains(cmd) { return .dictation }
        if cmd.hasPrefix("meeting_") || cmd.hasPrefix("archive_") { return .meetings }
        return nil
    }

    /// Команда зовёт облачный бэкенд: поле `backend` или `polish.backend`.
    public static func usesCloud(_ fields: [String: JSONValue]) -> Bool {
        if let name = fields["backend"]?.stringValue, PolishBackend(rawValue: name)?.isCloud == true { return true }
        if case .object(let polish)? = fields["polish"], let name = polish["backend"]?.stringValue,
           PolishBackend(rawValue: name)?.isCloud == true { return true }
        return false
    }

    /// Поля команды с `consent`: для облачной — согласие вызывающего И действующее согласие
    /// на этот вид данных; локальные команды не трогаем.
    public static func stamp(_ cmd: String, fields: [String: JSONValue], grants: CloudGrants) -> [String: JSONValue] {
        guard usesCloud(fields) else { return fields }
        let granted: Bool
        switch purpose(of: cmd) {
        case .dictation?: granted = grants.dictation
        case .meetings?: granted = grants.meetings
        case nil: granted = false
        }
        var result = fields
        let asked = fields["consent"]?.boolValue ?? true
        result["consent"] = .bool(asked && granted)
        return result
    }
}

// MARK: - Окружение движка: офлайн и без телеметрии

/// Списки этого раздела, `ToolEnvironment` и `SafeGit` сверяются с общим эталоном `docs/engine-environment.json`
/// (тот же файл сверяет движок): меняете список — меняйте эталон.
///
/// Окружение процесса движка (п. 5): Hugging Face не ходит в сеть и не шлёт телеметрию,
/// transcriber не проверяет обновления — независимо от `--offline` у отдельных прогонов.
///
/// Загрузку моделей по кнопке (`models_download`) это не ломает: загрузчик движка
/// (`engine/mostik_engine/model_store.py`) ходит своим HTTP через urllib, а не через `huggingface_hub`,
/// и `HF_HUB_OFFLINE` на него не действует.
public enum EngineEnvironment {
    public static let offline: [String: String] = [
        "HF_HUB_OFFLINE": "1",
        "HF_HUB_DISABLE_TELEMETRY": "1",
        "TRANSCRIBER_NO_UPDATE_CHECK": "1",
    ]

    /// Переопределения адресов, которые движок не должен брать из окружения процесса:
    /// приложение передаёт их в команде само и только в debug-сборке (`DebugOverrides`).
    public static let addressOverrides = ["MOSTIK_MODELS_BASE_URL"]

    /// Переопределения для разработки (П10): подменённый манифест моделей, снятое закрепление
    /// ревизий, чужой код transcriber и чужой Python. В выпуске из окружения не доходят до движка —
    /// иначе `launchctl setenv` уводил бы загрузку моделей или запуск кода в сторону.
    public static let debugOnlyOverrides = [
        "MOSTIK_MODELS_MANIFEST", "TRANSCRIBER_UNPIN", "MOSTIK_TRANSCRIBER", "MOSTIK_TRANSCRIBER_PYTHON",
        "MOSTIK_LLM_PYTHON",
    ]

    /// Переменные, которыми чужой код попадает в процесс Python или в загрузчик (П10 С1).
    public static let unsafePrefixes = ["PYTHON", "DYLD_", "LD_"]

    /// в выпуске движок не берёт из окружения, где искать программы (`fluidaudiocli`, `ffmpeg`)
    /// и модели: `TRANSCRIBER_*` и `HF_*` (кроме своих `offline`), словарь и `XDG_CACHE_HOME`.
    /// `PATH` — только системный; папку `bin` бандла и `HF_HOME` движок ставит сам (`privacy.scrub_dev_overrides`).
    public static let releaseDropPrefixes = ["TRANSCRIBER_", "HF_"]
    public static let releaseDrop = ["MOSTIK_CURATED_GLOSSARY", "XDG_CACHE_HOME"]

    /// П10 р4 Р4-1: шимы `/usr/bin/git`, `xcrun`, `python3`, `swift` следуют этим переменным и запускают
    /// `$DEVELOPER_DIR/usr/bin/xcrun` — чужой код с разрешениями Mostik. Снимаются всегда, и в debug.
    public static let toolchain = ["DEVELOPER_DIR", "SDKROOT", "TOOLCHAINS"]

    /// Р4-1: окружение движка — белый список. Движку и его детям нужны только эти переменные: дом и язык,
    /// свои настройки (`MOSTIK_*`), офлайн и кэш моделей (`HF_*`, `TRANSCRIBER_*` — в выпуске снимаются ниже),
    /// вход и сеть `claude` (ключ, прокси, корпоративный сертификат). Без `NODE_OPTIONS`, `BASH_ENV`, toolchain.
    public static let engineKeys: Set<String> = ToolEnvironment.allowed.union([
        "PATH", "XDG_CACHE_HOME", "CLAUDE_CONFIG_DIR", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY",
        "http_proxy", "https_proxy", "no_proxy", "all_proxy", "NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE",
    ])
    public static let enginePrefixes = ["LC_", "MOSTIK_", "TRANSCRIBER_", "HF_", "TRANSFORMERS_", "TOKENIZERS_", "ANTHROPIC_"]

    public static func allowlisted(_ base: [String: String]) -> [String: String] {
        base.filter { key, _ in engineKeys.contains(key) || enginePrefixes.contains(where: { key.hasPrefix($0) }) }
    }

    public static func apply(to env: inout [String: String], debug: Bool = DebugOverrides.isDebugBuild) {
        for key in env.keys where unsafePrefixes.contains(where: { key.hasPrefix($0) }) || toolchain.contains(key) {
            env.removeValue(forKey: key)
        }
        if !debug {
            for key in env.keys where releaseDrop.contains(key) || releaseDropPrefixes.contains(where: { key.hasPrefix($0) }) {
                env.removeValue(forKey: key)
            }
            env["PATH"] = ToolEnvironment.defaultPath
        }
        for (key, value) in offline { env[key] = value }
        for key in addressOverrides { env.removeValue(forKey: key) }
        if !debug { for key in debugOnlyOverrides { env.removeValue(forKey: key) } }
    }
}

/// Переопределения адресов через окружение — только в debug-сборке (п. 8).
public enum DebugOverrides {
    public static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Адрес зеркала моделей из `MOSTIK_MODELS_BASE_URL`: в выпуске — всегда nil.
    public static func modelsBaseURL(environment: [String: String], debug: Bool = isDebugBuild) -> String? {
        guard debug, let raw = environment["MOSTIK_MODELS_BASE_URL"]?.trimmingCharacters(in: .whitespaces),
              let url = URL(string: raw), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else { return nil }
        return raw
    }
}

/// П10: облачное согласие хранится с меткой «на что дано» — бэкенд и версия текста согласия.
/// Согласие без метки или с чужой меткой при загрузке `settings.json` сбрасывается: файл,
/// дописанный руками или другой программой, облако не открывает, пока пользователь не согласится
/// в приложении. Сменится текст экрана согласия или бэкенд — поднять `current`, и спросим заново.
public enum CloudConsentLabel {
    public static let current = "claude@v1"

    public static func stamp(_ consent: Bool) -> String? { consent ? current : nil }

    public static func accepts(_ consent: Bool, label: String??) -> Bool {
        consent && (label ?? nil) == current
    }
}
