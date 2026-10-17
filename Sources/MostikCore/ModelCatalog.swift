import Foundation

/// Модели по кнопке (П8, пункт 5): строки манифеста движка (`models`) и решения о них.
/// Движок сам не качает; приложение показывает, чего не хватает, и качает по кнопке.
public struct ModelRow: Equatable, Sendable, Identifiable {
    public var id: String { key }
    public var key: String
    public var label: String
    /// vad | ru | en | verifier-en | llm
    public var purpose: String
    public var required: Bool
    public var size: Int64
    public var installed: Bool
    public var missingBytes: Int64
    public var partialBytes: Int64

    public init(key: String, label: String, purpose: String, required: Bool, size: Int64,
                installed: Bool, missingBytes: Int64 = 0, partialBytes: Int64 = 0) {
        self.key = key; self.label = label; self.purpose = purpose; self.required = required
        self.size = size; self.installed = installed; self.missingBytes = missingBytes; self.partialBytes = partialBytes
    }

    /// Строка из ответа `models`; без ключа — nil.
    public init?(_ value: JSONValue) {
        guard case .object(let o) = value, let key = o["key"]?.stringValue else { return nil }
        self.init(key: key, label: o["label"]?.stringValue ?? key, purpose: o["purpose"]?.stringValue ?? "",
                  required: o["required"]?.boolValue ?? false,
                  size: Int64(o["size"]?.doubleValue ?? 0), installed: o["installed"]?.boolValue ?? false,
                  missingBytes: Int64(o["missing_bytes"]?.doubleValue ?? 0),
                  partialBytes: Int64(o["partial_bytes"]?.doubleValue ?? 0))
    }

    /// Нужна ли модель для диктовки на языке `language` (ru/en): VAD всегда, основная — своего языка.
    public func neededFor(language: String) -> Bool {
        guard required else { return false }
        switch purpose {
        case "vad": return true
        case "ru", "en": return purpose == language
        default: return true
        }
    }
}

public enum ModelCatalog {
    public static func rows(from payload: [String: JSONValue]) -> [ModelRow] {
        guard case .array(let items)? = payload["models"] else { return [] }
        return items.compactMap(ModelRow.init)
    }

    /// Чего не хватает для диктовки на `language` — экран «Нужны модели», если не пусто.
    public static func missing(_ rows: [ModelRow], language: String) -> [ModelRow] {
        rows.filter { !$0.installed && $0.neededFor(language: language) }
    }

    /// Состояние моделей одной фразой с числом — для сводки свёрнутого «Дополнительно»:
    /// «5 моделей установлено», «1 модель не скачана». Раньше при полном наборе выходило
    /// голое «модели на месте» без числа (замечание слепого раунда 4).
    public static func summary(_ rows: [ModelRow], language: String) -> String {
        guard !rows.isEmpty else { return UIText.pick("список моделей ещё не получен", "model list not loaded yet") }
        let missing = missing(rows, language: language).count
        if missing > 0 {
            return UIText.plural(missing, ru: "модель не скачана", "модели не скачаны", "моделей не скачано",
                                 en: "model missing", "models missing")
        }
        let installed = rows.filter(\.installed).count
        return UIText.plural(installed, ru: "модель установлена", "модели установлены", "моделей установлено",
                             en: "model installed", "models installed")
    }

    /// Сколько качать для `rows` (докачка учтена).
    public static func bytesToDownload(_ rows: [ModelRow]) -> Int64 {
        rows.filter { !$0.installed }.reduce(0) { $0 + max(0, $1.missingBytes) }
    }

    /// «1,6 ГБ» / «850 МБ» / «1.6 GB»: десятичные единицы, как у Finder.
    public static func size(_ bytes: Int64, russian: Bool) -> String {
        let gb = Double(bytes) / 1e9
        if gb >= 1 {
            let text = String(format: "%.1f", gb)
            return (russian ? text.replacingOccurrences(of: ".", with: ",") : text) + (russian ? " ГБ" : " GB")
        }
        let mb = max(1, Int((Double(bytes) / 1e6).rounded()))
        return "\(mb)" + (russian ? " МБ" : " MB")
    }

    /// Ошибка загрузки по коду движка — коротко и с тем, что делать.
    public static func errorText(code: String, message: String, russian: Bool) -> String {
        switch code {
        case "models_network":
            return russian ? "Нет связи с сервером моделей. Проверьте интернет и нажмите «Скачать» — загрузка продолжится с того же места."
                : "Can’t reach the model server. Check your connection and press Download — it resumes where it stopped."
        case "models_disk_full":
            return russian ? "Не хватает места на диске. " + message : "Not enough disk space. " + message
        case "models_checksum":
            return russian ? "Файл пришёл повреждённым и удалён. Нажмите «Скачать» ещё раз."
                : "A file arrived damaged and was removed. Press Download again."
        case "models_cancelled":
            return russian ? "Загрузка остановлена. «Скачать» продолжит с того же места."
                : "Download paused. Download resumes where it stopped."
        case "models_http":
            return russian ? "Сервер моделей ответил ошибкой. Попробуйте позже." + (message.isEmpty ? "" : " (\(message))")
                : "The model server returned an error. Try again later." + (message.isEmpty ? "" : " (\(message))")
        default:
            return message
        }
    }
}

/// Ход загрузки одной модели по событиям `models_progress`.
public struct ModelProgress: Equatable, Sendable {
    public var key: String
    public var done: Int64
    public var total: Int64
    public init(key: String, done: Int64, total: Int64) { self.key = key; self.done = done; self.total = total }
    public var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }

    /// `models_progress` приходит как `.progress(task: "models:<key>", …)`.
    public static let taskPrefix = "models:"
}

/// Очередь загрузок моделей. Движок качает одной командой за раз; раньше
/// вторая кнопка «Скачать» во время загрузки молча ничего не делала, и человек, выбравший в
/// онбординге LLM на 3,6 ГБ, ждал её, прежде чем мог скачать 0,9 ГБ модели распознавания.
/// Теперь новые ключи встают в очередь, а модели распознавания вытесняют идущую загрузку
/// менее важной: она останавливается (недокачанное остаётся в `.part`) и продолжается после.
public struct ModelDownloadQueue: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        /// Запустить загрузку этих ключей одной командой, по порядку.
        case start([String])
        /// Остановить идущую загрузку: следующей пойдёт более важная (`cancelled` → `failed`).
        case cancelRunning
        /// Ждать: ключи в очереди.
        case wait
    }

    public private(set) var running: [String] = []
    public private(set) var pending: [String] = []
    /// Идущую загрузку остановили ради более важной — её отказ `cancelled` не ошибка.
    public private(set) var preempting = false

    public init() {}

    public var busy: Bool { !running.isEmpty }

    /// Чем меньше, тем раньше: распознавание (0) → разделение по голосам (1) → остальное (2).
    public static func priority(_ row: ModelRow?) -> Int {
        guard let row else { return 2 }
        switch row.purpose {
        case "vad", "ru", "en": return 0
        case "diarization": return 1
        default: return row.required ? 0 : 2
        }
    }

    public mutating func request(_ keys: [String], priority: (String) -> Int) -> Step {
        let fresh = keys.reduce(into: [String]()) { out, key in
            if !running.contains(key), !pending.contains(key), !out.contains(key) { out.append(key) }
        }
        guard busy else {
            guard !fresh.isEmpty else { return .wait }
            running = Self.ordered(fresh + pending, priority)
            pending = []
            return .start(running)
        }
        guard !fresh.isEmpty else { return .wait }
        pending = Self.ordered(pending + fresh, priority)
        let best = fresh.map(priority).min() ?? 2
        let current = running.map(priority).min() ?? 2
        if best < current, !preempting {
            preempting = true
            pending = Self.ordered(pending + running, priority)
            return .cancelRunning
        }
        return .wait
    }

    /// Загрузка кончилась успешно: следующая из очереди или nil.
    public mutating func finished() -> [String]? {
        running = []
        preempting = false
        return next()
    }

    /// Загрузка кончилась ошибкой. Вытеснение — продолжаем с очереди; любая другая (нет сети,
    /// место, «Остановить») — очередь сбрасывается: «Скачать» начнёт заново с того же места.
    public mutating func failed(cancelled: Bool) -> [String]? {
        running = []
        if cancelled, preempting {
            preempting = false
            return next()
        }
        preempting = false
        pending = []
        return nil
    }

    /// «Остановить» человеком: очередь не продолжается.
    public mutating func userCancelled() {
        pending = []
        preempting = false
    }

    private mutating func next() -> [String]? {
        guard !pending.isEmpty else { return nil }
        running = pending
        pending = []
        return running
    }

    static func ordered(_ keys: [String], _ priority: (String) -> Int) -> [String] {
        keys.enumerated().sorted { a, b in
            let (pa, pb) = (priority(a.element), priority(b.element))
            return pa != pb ? pa < pb : a.offset < b.offset
        }.map(\.element)
    }
}
