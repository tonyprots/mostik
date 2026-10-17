import Foundation

// MARK: - «Доктор» (R7): проверки окружения

/// Одна строка экрана «Проверка».
public struct DoctorCheck: Identifiable, Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case microphone, accessibility, postEvents, systemAudio, hotkey, engine, models, diarization, disk, llm, logs, loginItem
    }

    public enum Status: Int, Comparable, Sendable {
        case ok, unknown, warning, failed
        public static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }
    }

    /// Что делает кнопка «Исправить».
    public enum Fix: String, Equatable, Sendable {
        case requestMicrophone, openMicrophone, requestAccessibility, relaunch, openSystemAudio,
             openKeyboard, restartEngine, openStorage, openPolish, showLogs,
             /// Скачать модели распознавания (кнопка «Скачать» главного экрана).
             downloadModels,
             /// Скачать модели разделения по голосам (`speaker-diarization`).
             downloadDiarization,
             /// Системные настройки → Основные → Объекты входа.
             openLoginItems
    }

    public var kind: Kind
    public var status: Status
    /// Пояснение под заголовком: что не так и что будет, если не чинить.
    public var detail: String
    public var fix: Fix?
    public var id: String { kind.rawValue }

    public init(kind: Kind, status: Status, detail: String, fix: Fix? = nil) {
        self.kind = kind; self.status = status; self.detail = detail; self.fix = fix
    }
}

/// Сырые факты, собранные платформенным слоем. Решения о статусе — в `Doctor.evaluate`.
public struct DoctorFacts: Equatable, Sendable {
    public enum Microphone: Equatable, Sendable { case authorized, denied, undetermined }
    public enum Engine: Equatable, Sendable { case starting, loading, ready, failed(String) }

    public var microphone: Microphone = .undetermined
    public var accessibility = false
    /// `CGPreflightPostEventAccess`: право слать нажатия (вставка ⌘V).
    public var postEvents = false
    /// Системная дорожка встречи хоть раз прозвучала — публичной проверки нет.
    public var systemAudio = false
    /// Последняя встреча писалась без звука системы при живом микрофоне (`warnSystemSilent`).
    public var systemAudioSilent = false
    /// "rightOption" | "rightCommand" | "fn"
    public var holdKey = "rightOption"
    /// `com.apple.HIToolbox AppleFnUsageType`: 0 ничего, 1 раскладка, 2 эмодзи, 3 диктовка; nil — не задано.
    public var fnUsage: Int?
    /// Запущенные приложения, которые перехватывают модификаторы (Punto Switcher, Karabiner…).
    public var keyGrabbers: [String] = []
    public var engine: Engine = .starting
    /// Чего нет в кэше моделей (`hello.models`); nil — движок ещё не ответил.
    public var missingModels: [String]?
    /// Разделит ли движок встречу по голосам (`hello.diarization`: fluidaudiocli и модели FluidAudio); nil — не ответил.
    public var diarizationAvailable: Bool?
    /// Сколько качать моделей голосов, если их нет (строка `speaker-diarization` в `models`); nil — не нужно или неизвестно.
    public var diarizationDownloadBytes: Int64?
    /// Свободно на диске с данными; nil — не удалось узнать.
    public var freeBytes: Int64?
    /// "off" | "claude" | "mlx" …
    public var llmBackend = "off"
    /// Доступен ли выбранный бэкенд по `hello.polish`; nil — неизвестно.
    public var llmAvailable: Bool?
    /// Падений движка за сеанс (П8, пункт 6).
    public var engineCrashes = 0
    /// Отчётов о сбое за последние 7 дней в `~/Library/Logs/Mostik/crashes/`.
    public var crashReports = 0
    /// Автозапуск при входе; nil — не проверяли (строки нет).
    public var loginItem: LoginItemFacts?

    public init() {}
}

public enum Doctor {
    /// Меньше — диктовка и встречи могут не записаться.
    public static let diskCritical: Int64 = 2_000_000_000
    /// Меньше — предупреждаем: встреча на час — сотни мегабайт.
    public static let diskLow: Int64 = 10_000_000_000

    public static func evaluate(_ f: DoctorFacts, russian ru: Bool) -> [DoctorCheck] {
        func t(_ r: String, _ e: String) -> String { ru ? r : e }
        var out: [DoctorCheck] = []

        switch f.microphone {
        case .authorized:
            out.append(.init(kind: .microphone, status: .ok, detail: t("Разрешено.", "Allowed.")))
        case .undetermined:
            out.append(.init(kind: .microphone, status: .failed,
                             detail: t("Ещё не спрашивали — без него диктовка не начнётся.", "Not asked yet — dictation can’t start without it."),
                             fix: .requestMicrophone))
        case .denied:
            out.append(.init(kind: .microphone, status: .failed,
                             detail: t("Запрещено в Настройках macOS — диктовка не начнётся.", "Denied in macOS Settings — dictation can’t start."),
                             fix: .openMicrophone))
        }

        if f.accessibility {
            out.append(.init(kind: .accessibility, status: .ok, detail: t("Разрешено.", "Allowed.")))
        } else {
            out.append(.init(kind: .accessibility, status: .failed,
                             detail: t("Без него Mostik не слышит клавишу и не вставляет текст.", "Without it Mostik can’t hear the key or paste."),
                             fix: .requestAccessibility))
        }

        if f.postEvents {
            out.append(.init(kind: .postEvents, status: .ok, detail: t("Вставка ⌘V работает.", "⌘V paste works.")))
        } else if f.accessibility {
            out.append(.init(kind: .postEvents, status: .failed,
                             detail: t("Доступ выдан на ходу — macOS даст его после перезапуска. Пока текст уходит в буфер.",
                                       "Access was granted while running — macOS applies it after a relaunch. Text goes to the clipboard until then."),
                             fix: .relaunch))
        } else {
            out.append(.init(kind: .postEvents, status: .failed,
                             detail: t("Появится вместе с Универсальным доступом.", "Comes with Accessibility access."),
                             fix: .requestAccessibility))
        }

        if f.systemAudioSilent {
            out.append(.init(kind: .systemAudio, status: .warning,
                             detail: t("В последней встрече собеседников не было слышно — похоже, macOS не разрешила Mostik запись системного звука. Включите: ",
                                       "The other side was silent in the last meeting — macOS probably didn’t allow Mostik to record system audio. Turn it on: ")
                                + MeetingAudioText.pane(russian: ru) + ".",
                             fix: .openSystemAudio))
        } else {
            out.append(f.systemAudio
                ? .init(kind: .systemAudio, status: .ok, detail: t("Встреча уже записывалась со звуком собеседников.", "A meeting was recorded with the other side’s audio."))
                : .init(kind: .systemAudio, status: .unknown,
                        detail: t("Нужно только для встреч; macOS спросит при первой записи.", "Meetings only; macOS asks on the first recording."),
                        fix: .openSystemAudio))
        }

        out.append(hotkeyCheck(f, ru: ru))

        switch f.engine {
        case .ready where f.engineCrashes > 0:
            out.append(.init(kind: .engine, status: .ok,
                             detail: t("Запущен, модель в памяти. Падал за сеанс: \(f.engineCrashes) — каждый раз поднялся сам.",
                                       "Running, model loaded. Crashed this session: \(f.engineCrashes) — recovered each time.")))
        case .ready:
            out.append(.init(kind: .engine, status: .ok, detail: t("Запущен, модель в памяти.", "Running, model loaded.")))
        case .starting, .loading:
            out.append(.init(kind: .engine, status: .unknown, detail: t("Запускается…", "Starting…")))
        case .failed(let why):
            out.append(.init(kind: .engine, status: .failed, detail: why.isEmpty ? t("Не запустился.", "Failed to start.") : why,
                             fix: .restartEngine))
        }

        switch f.missingModels {
        case nil:
            out.append(.init(kind: .models, status: .unknown, detail: t("Движок ещё не ответил.", "The engine hasn’t answered yet.")))
        case let missing? where missing.isEmpty:
            out.append(.init(kind: .models, status: .ok, detail: t("Все модели в кэше.", "All models are cached.")))
        case let missing?:
            // раньше — «Скачайте их в transcriber», а чужой человек не знает, что это.
            out.append(.init(kind: .models, status: .failed,
                             detail: t("Не скачаны: ", "Not downloaded: ") + missing.joined(separator: ", ")
                                + t(". Без них диктовка не распознаётся — нажмите «Скачать», это один раз.",
                                    ". Dictation can’t be recognized without them — press Download, it’s a one-time step."),
                             fix: .downloadModels))
        }

        switch f.diarizationAvailable {
        case nil:
            out.append(.init(kind: .diarization, status: .unknown, detail: t("Движок ещё не ответил.", "The engine hasn’t answered yet.")))
        case true?:
            out.append(.init(kind: .diarization, status: .ok,
                             detail: t("Встречи делятся по собеседникам.", "Meetings are split by speaker.")))
        case false? where f.diarizationDownloadBytes != nil:
            let size = formatBytes(f.diarizationDownloadBytes ?? 0, russian: ru)
            out.append(.init(kind: .diarization, status: .warning,
                             detail: t("Модели голосов не скачаны (\(size)): встречи расшифровываются, но все собеседники — «Собеседник 1».",
                                       "Voice models aren’t downloaded (\(size)): meetings are transcribed, with everyone on the call as one speaker."),
                             fix: .downloadDiarization))
        case false?:
            out.append(.init(kind: .diarization, status: .warning,
                             detail: t("Недоступно на этом Mac: встречи расшифровываются, но все собеседники — «Собеседник 1».",
                                       "Not available on this Mac: meetings are transcribed, with everyone on the call as one speaker.")))
        }

        if let free = f.freeBytes {
            let size = formatBytes(free, russian: ru)
            if free < diskCritical {
                out.append(.init(kind: .disk, status: .failed,
                                 detail: t("Свободно \(size) — записи могут не сохраниться.", "\(size) free — recordings may fail to save."),
                                 fix: .openStorage))
            } else if free < diskLow {
                out.append(.init(kind: .disk, status: .warning,
                                 detail: t("Свободно \(size) — часовая встреча займёт сотни мегабайт.", "\(size) free — an hour-long meeting takes hundreds of megabytes."),
                                 fix: .openStorage))
            } else {
                out.append(.init(kind: .disk, status: .ok, detail: t("Свободно \(size).", "\(size) free.")))
            }
        } else {
            out.append(.init(kind: .disk, status: .unknown, detail: t("Не удалось узнать.", "Couldn’t check.")))
        }

        if f.llmBackend == "off" {
            out.append(.init(kind: .llm, status: .ok, detail: t("Не используется: причёсывание выключено.", "Not used: polish is off.")))
        } else {
            let name = f.llmBackend == "claude" ? "Claude" : (f.llmBackend == "mlx" ? t("локальная модель", "local model") : f.llmBackend)
            switch f.llmAvailable {
            case true?:
                out.append(.init(kind: .llm, status: .ok, detail: t("Готов к работе: \(name).", "Ready: \(name).")))
            case false?:
                out.append(.init(kind: .llm, status: .warning,
                                 detail: t("Бэкенд не отвечает (\(name)) — текст вставляется без причёсывания.",
                                           "Backend unavailable (\(name)) — text is inserted unpolished."),
                                 fix: .openPolish))
            case nil:
                out.append(.init(kind: .llm, status: .unknown, detail: t("Движок ещё не ответил.", "The engine hasn’t answered yet.")))
            }
        }
        out.append(f.crashReports > 0
            ? .init(kind: .logs, status: .warning,
                    detail: t("Отчётов о сбое за неделю: \(f.crashReports). Они и журнал — только на этом Mac, никуда не отправляются.",
                              "Crash reports this week: \(f.crashReports). They and the log stay on this Mac and are never sent."),
                    fix: .showLogs)
            : .init(kind: .logs, status: .ok,
                    detail: t("Сбоев не было. Журнал событий — без текста диктовок, только на этом Mac.",
                              "No crashes. The event log has no dictation text and stays on this Mac."),
                    fix: .showLogs))
        if let login = f.loginItem { out.append(loginItemCheck(login, ru: ru)) }
        return out
    }

    static func loginItemCheck(_ l: LoginItemFacts, ru: Bool) -> DoctorCheck {
        func t(_ r: String, _ e: String) -> String { ru ? r : e }
        let manual = t(" Включите вручную: Системные настройки → Основные → Объекты входа.",
                       " Turn it on manually: System Settings → General → Login Items.")
        if !l.wanted {
            return .init(kind: .loginItem, status: .ok, detail: t("Выключен в Настройках.", "Off in Settings."))
        }
        if let error = l.error {
            return .init(kind: .loginItem, status: .warning,
                         detail: t("Не удалось включить: ", "Couldn’t turn it on: ") + error + "." + manual, fix: .openLoginItems)
        }
        switch l.state {
        case .enabled:
            return .init(kind: .loginItem, status: .ok, detail: t("Mostik запускается при входе.", "Mostik opens at login."))
        case .requiresApproval:
            return .init(kind: .loginItem, status: .warning,
                         detail: t("macOS ждёт разрешения: без него Mostik не запустится при входе.",
                                   "macOS is waiting for your approval: without it Mostik won’t open at login.") + manual,
                         fix: .openLoginItems)
        case .unavailable:
            return .init(kind: .loginItem, status: .unknown,
                         detail: t("Работает только у собранного приложения Mostik.app.", "Works only for the built Mostik.app."))
        case .notRegistered, .notFound:
            return .init(kind: .loginItem, status: .unknown, detail: t("Ещё не включён.", "Not on yet."))
        }
    }

    /// Худший статус — для заголовка группы и точки у вкладки.
    public static func worst(_ checks: [DoctorCheck]) -> DoctorCheck.Status {
        checks.map(\.status).max() ?? .unknown
    }

    static func hotkeyCheck(_ f: DoctorFacts, ru: Bool) -> DoctorCheck {
        func t(_ r: String, _ e: String) -> String { ru ? r : e }
        if f.holdKey == "fn", let usage = f.fnUsage, usage != 0 {
            let what = [1: t("переключает раскладку", "switches the input source"),
                        2: t("открывает эмодзи", "opens emoji"),
                        3: t("запускает диктовку macOS", "starts macOS dictation")][usage] ?? t("занята системой", "is used by macOS")
            return .init(kind: .hotkey, status: .warning,
                         detail: t("fn \(what): при каждой диктовке сработает и это. В\u{00A0}Настройках клавиатуры выберите «Ничего не делать».",
                                   "fn \(what): it fires on every dictation too. Set it to “Do Nothing” in Keyboard settings."),
                         fix: .openKeyboard)
        }
        if !f.keyGrabbers.isEmpty {
            return .init(kind: .hotkey, status: .warning,
                         detail: t("Запущено \(f.keyGrabbers.joined(separator: ", ")) — оно может перехватывать клавишу диктовки. Если запись не начинается, выберите другую клавишу.",
                                   "\(f.keyGrabbers.joined(separator: ", ")) is running and may grab the dictation key. If recording doesn’t start, pick another key."))
        }
        return .init(kind: .hotkey, status: .ok, detail: t("Системой не занята.", "Not used by the system."))
    }

    static func formatBytes(_ bytes: Int64, russian: Bool) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb < 1 {
            let mb = String(max(1, Int((Double(bytes) / 1_000_000).rounded())))
            return mb + (russian ? "\u{00A0}МБ" : "\u{00A0}MB")
        }
        let value = gb >= 10 ? String(format: "%.0f", gb) : String(format: "%.1f", gb)
        return (russian ? value.replacingOccurrences(of: ".", with: ",") + "\u{00A0}ГБ" : value + "\u{00A0}GB")
    }
}

// MARK: - Правила повторов (R7)

/// Как сообщать о сбоях. Постоянные (отказ в микрофоне) — один раз, с напоминанием
/// не чаще `remindAfter`; временные (микрофон занят, движок упал) — повтор с паузой.
public struct FailureGate: Sendable {
    public enum Decision: Equatable, Sendable {
        /// Показать сообщение.
        case report
        /// Уже сообщали — молчать.
        case silent
        /// Повторить через столько секунд.
        case retry(after: Double)
        /// Повторы кончились — показать сообщение.
        case giveUp
    }

    public var remindAfter: Double
    public var delays: [Double]
    private var reportedAt: [String: Double] = [:]
    private var attempts: [String: Int] = [:]

    public init(remindAfter: Double = 600, delays: [Double] = [0.3, 1.0]) {
        self.remindAfter = remindAfter
        self.delays = delays
    }

    /// Постоянный отказ: первый раз — `report`, дальше `silent` до `remindAfter`.
    public mutating func permanent(_ key: String, at now: Double) -> Decision {
        if let last = reportedAt[key], now - last < remindAfter { return .silent }
        reportedAt[key] = now
        return .report
    }

    /// Временный сбой: `retry` с паузами из `delays`, затем `giveUp`; счётчик сбрасывает `succeeded`.
    public mutating func transient(_ key: String) -> Decision {
        let n = attempts[key, default: 0]
        attempts[key] = n + 1
        return n < delays.count ? .retry(after: delays[n]) : .giveUp
    }

    /// Получилось или условие изменилось (разрешение выдали) — следующий сбой снова сообщается.
    public mutating func succeeded(_ key: String) {
        reportedAt[key] = nil
        attempts[key] = nil
    }
}

// MARK: - Прогрев (R6)

/// Когда прогревать модель: через `delay` после запуска, пробуждения или разблокировки,
/// но не чаще `minInterval` и не посреди записи или расшифровки.
public struct WarmupPolicy: Sendable {
    public var delay: Double
    public var minInterval: Double
    public private(set) var lastWarm: Double?

    public init(delay: Double = 3, minInterval: Double = 120) {
        self.delay = delay
        self.minInterval = minInterval
    }

    /// Пробуждение после сна выгружает кэши — прогрев нужен, даже если был недавно.
    public mutating func shouldWarm(at now: Double, busy: Bool, afterSleep: Bool = false) -> Bool {
        if busy { return false }
        if !afterSleep, let last = lastWarm, now - last < minInterval { return false }
        lastWarm = now
        return true
    }

    /// Модель прогрета другим путём (рукопожатие с движком).
    public mutating func warmed(at now: Double) { lastWarm = now }

    /// Через сколько греть. После сна — сразу (шаг 1, п. 5): прогрев — фоновая задача движка,
    /// а человек, открывший крышку, часто диктует в первые секунды. Разблокировка без сна — как было.
    public func delay(afterSleep: Bool) -> Double { afterSleep ? 0 : delay }

    /// Какую локальную LLM прогреть вместе с моделью речи (шаг 1, п. 7): только MLX и только
    /// если на нём причёсывание или встречи. `claude` — облако, греть нечего.
    public static func polishBackendToWarm(_ settings: MostikSettings) -> String? {
        settings.polish.effectiveBackend == .mlx || settings.meetingEffectiveBackend == .mlx ? PolishBackend.mlx.rawValue : nil
    }
}
