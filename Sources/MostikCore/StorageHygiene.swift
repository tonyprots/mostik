import Foundation

/// П10, низкие находки: права на данные и журналы, временные файлы встреч.
///
/// Приложение без песочницы, `NSFileProtection` на macOS не действует — данные закрывают только
/// права. Корни `Application Support/Mostik` и `Logs/Mostik` — 0700, отчёты о сбое — 0600.
public enum StorageHygiene {
    /// Создать каталоги (если нет) и выставить им 0700. Ошибки молча пропускаются.
    public static func secure(_ directories: [URL]) {
        let fm = FileManager.default
        for dir in directories {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
    }

    /// Создать пустой файл 0600, если его нет; существующему выставить 0600.
    public static func ensurePrivateFile(_ url: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Записать текст в файл с правами 0600 (отчёты о сбое).
    @discardableResult
    public static func writePrivate(_ text: String, to url: URL) -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        guard fm.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            return false
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }

    /// Временные файлы Mostik в `$TMPDIR`, которые остаются после SIGKILL: склейки дорожек
    /// встречи (`mostik-tracks-*`, движок), живая запись (`mostik-live-*.wav`), векторы голосов
    /// встречи (`mostik-voices-*`) и копия базы Wispr Flow при импорте словаря (`mostik-wispr-*`, П10 р3 Н-2);
    /// П10 р5 Р5-4л: рабочая папка `claude -p` (`mostik-polish-*`, движок) и черновики событий голосовых
    /// команд (`mostik-commands-*`, `.ics` с текстом команды).
    public static let tempPrefixes = ["mostik-tracks-", "mostik-live-", "mostik-voices-", "mostik-wispr-", "mostik-polish-",
                                      VoiceIntentICS.draftPrefix]
    /// Старые имена без префикса: общая папка черновиков событий до П10 р5.
    public static let legacyTempNames = ["Mostik-commands"]
    /// Рабочие папки transcriber со звуком встречи (П10, низкий): нарезка ASR и загрузки. Тот же
    /// `$TMPDIR` у transcriber, запущенного отдельно, а длинная расшифровка идёт часами, — поэтому
    /// только старше суток.
    public static let transcriberTempPrefixes = ["transcriber-asr-", "transcriber-download-"]
    public static let transcriberMinAge: TimeInterval = 86_400

    /// Убрать такие файлы старше `minAge` секунд (свежие может держать идущий процесс);
    /// папки transcriber — старше `transcriberMinAge`. Возвращает имена удалённого.
    /// `only` — убрать только эти префиксы (посреди работы: склейку идущей расшифровки встречи не трогаем).
    @discardableResult
    public static func cleanStaleTemp(in dir: URL, now: Date = Date(), minAge: TimeInterval = 600,
                                      only: [String]? = nil) -> [String] {
        let fm = FileManager.default
        var removed: [String] = []
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            let age: TimeInterval
            if let only {
                guard only.contains(where: { name.hasPrefix($0) }) else { continue }
                age = minAge
            } else if tempPrefixes.contains(where: { name.hasPrefix($0) }) || legacyTempNames.contains(name) {
                age = minAge
            } else if transcriberTempPrefixes.contains(where: { name.hasPrefix($0) }) {
                age = max(minAge, transcriberMinAge)
            } else {
                continue
            }
            let url = dir.appendingPathComponent(name)
            let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date ?? now
            guard now.timeIntervalSince(modified) >= age else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed.append(name) }
        }
        return removed
    }
}
