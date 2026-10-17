import Foundation
import MostikCore

/// Локализация без таблиц: каждая строка задаётся парой «русский, английский»
/// прямо в месте использования, поэтому оба языка всегда полные.
/// Язык интерфейса — по языку системы; снимки переключают его явно.
/// Хранится в `UIText` (MostikCore), чтобы ядро и платформенный слой говорили на том же языке.
/// Страж в MostikCoreTests (L10nGuardTests) ловит кириллицу без пары.
public enum L10n {
    public static var isRussian: Bool {
        get { UIText.isRussian }
        set { UIText.isRussian = newValue }
    }

    public static var locale: Locale { Locale(identifier: isRussian ? "ru_RU" : "en_US") }

    /// Русская форма числа: 1 сомнение, 2 сомнения, 5 сомнений.
    public static func plural(_ n: Int, ru one: String, _ few: String, _ many: String, en singular: String, _ pluralEN: String) -> String {
        UIText.plural(n, ru: one, few, many, en: singular, pluralEN)
    }

    /// Снимки для слепых тестов: имя продукта в подписях заменено на «приложение» / «the app».
    public static var neutralName: Bool {
        get { UIText.neutralName }
        set { UIText.neutralName = newValue }
    }
}

/// Строка интерфейса: русский и английский рядом.
@inline(__always)
func L(_ ru: String, _ en: String) -> String { UIText.pick(ru, en) }

/// Форматирование времени и чисел для экранов.
enum Fmt {
    /// 0:42, 12:07, 1:02:15 — для таймеров.
    static func clock(_ t: TimeInterval) -> String {
        let total = max(0, Int(t.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// 0,8 с / 0.8 s
    static func latency(_ ms: Double) -> String {
        let f = NumberFormatter()
        f.locale = L10n.locale
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        let value = f.string(from: NSNumber(value: ms / 1000)) ?? "\(ms / 1000)"
        return value + L("\u{00A0}с", "\u{00A0}s")
    }

    /// Длительность встречи словами: «47 мин», «1 ч 12 мин».
    static func duration(_ t: TimeInterval) -> String {
        let minutes = Int((t / 60).rounded())
        if minutes < 60 { return "\(max(1, minutes))\u{00A0}" + L("мин", "min") }
        return "\(minutes / 60)\u{00A0}" + L("ч", "h") + " \(minutes % 60)\u{00A0}" + L("мин", "min")
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.dateFormat = L10n.isRussian ? "HH:mm" : "h:mm a"
        return f.string(from: date)
    }

    static func dayTitle(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return L("Сегодня", "Today") }
        if calendar.isDateInYesterday(date) { return L("Вчера", "Yesterday") }
        let f = DateFormatter()
        f.locale = L10n.locale
        f.setLocalizedDateFormatFromTemplate("dMMMMEEEE")
        let s = f.string(from: date)
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    static func dayAndTime(_ date: Date) -> String {
        "\(dayTitle(date)), \(time(date))"
    }

    static func doubts(_ n: Int) -> String {
        L10n.plural(n, ru: "слово под вопросом", "слова под вопросом", "слов под вопросом", en: "unsure word", "unsure words")
    }

    static func terms(_ n: Int) -> String {
        L10n.plural(n, ru: "термин", "термина", "терминов", en: "term", "terms")
    }

    static func days(_ n: Int) -> String {
        L10n.plural(n, ru: "день", "дня", "дней", en: "day", "days")
    }

    static func speakers(_ n: Int) -> String {
        L10n.plural(n, ru: "собеседник", "собеседника", "собеседников", en: "speaker", "speakers")
    }

    /// «только что», «12 мин назад», «2 ч назад», «3 дня назад».
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return L("только что", "just now") }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)\u{00A0}" + L("мин назад", "min ago") }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)\u{00A0}" + L("ч назад", "h ago") }
        return L10n.plural(hours / 24, ru: "день", "дня", "дней", en: "day", "days") + L(" назад", " ago")
    }

    /// Вид термина из протокола движка — человеческим словом, во множественном числе.
    static func kindTitle(_ kind: String) -> String {
        switch kind {
        // F7: «люди» — это слова с заглавной буквы посреди фразы; среди них и названия, и падежи одного имени.
        case "person": L("Имена", "Names")
        case "project": L("Проекты", "Projects")
        case "tech": L("Техтермины", "Tech terms")
        case "acronym": L("Аббревиатуры", "Acronyms")
        // F5: имена функций, переменных и файлов из кода проекта.
        case "identifier": L("Слова из кода", "Code words")
        default: kind
        }
    }

    /// Вид термина в единственном числе — подпись у строки.
    static func kindSingular(_ kind: String) -> String {
        switch kind {
        case "person": L("имя или название", "name")
        case "project": L("проект", "project")
        case "tech": L("техтермин", "tech term")
        case "acronym": L("аббревиатура", "acronym")
        case "identifier": L("слово из кода", "code word")
        default: kind
        }
    }

    /// Что значит вид — подсказка у легенды и фильтра.
    static func kindHelp(_ kind: String) -> String {
        switch kind {
        case "person": L("Слова с заглавной буквы из текстов: имена людей, а также места и названия. Разные падежи одного имени — отдельные слова.",
                         "Capitalised words from your texts: people’s names, places and other names.")
        case "project": L("Названия проектов и клиентов: слово после «проект», «клиент», «codename».",
                          "Project and client names: the word after “project”, “client” or “codename”.")
        case "tech": L("Названия продуктов и технологий, латиница в русском тексте.", "Product and technology names.")
        case "acronym": L("Сокращения из заглавных букв: API, CRM.", "All-caps abbreviations: API, CRM.")
        case "identifier": L("Имена функций, переменных и файлов из кода проекта: Mostik пишет их как в коде.",
                             "Function, variable and file names from your project’s code, spelled the way the code does.")
        default: ""
        }
    }

    /// Порядок видов везде один.
    static let kinds = ["person", "project", "tech", "acronym", "identifier"]

    /// «Я» — метка своего микрофона в данных движка; на экране — на языке интерфейса.
    static func speakerName(_ name: String) -> String {
        name == MeetingSpeakers.me ? L("Я", "Me") : name
    }

    static func marks(_ n: Int) -> String {
        L10n.plural(n, ru: "пометка", "пометки", "пометок", en: "mark", "marks")
    }
}
