import Foundation

/// П10 р4 Р4-4л: диктовка в поле пароля.
///
/// Раньше защищённый ввод проверялся только при вставке: к этому моменту текст уже прошёл причёсывание
/// (в том числе Claude), контекст поля мог уйти в модель, а отказ во вставке клал текст в историю на 7 дней,
/// откуда его читают агенты (`mostik history`, MCP `recent_doubts`).
///
/// Решение — **не записывать вовсе**: если включён защищённый ввод (`IsSecureEventInputEnabled`, его включает
/// любое поле пароля Cocoa и браузеров) или фокус — `AXSecureTextField`, запись не начинается и плашка говорит
/// почему. Нет звука — нечего причёсывать, хранить и отдавать. Это проще объяснить, чем «записали, но не
/// причесали и не сохранили», и вставить в поле пароля Mostik всё равно бы отказался.
///
/// Вторая линия (П10 р5) — поле пароля появилось посреди записи: `stopRefusal` в конце записи, до расшифровки.
/// Третья — защищённый ввод включился за время расшифровки: вставка отказывает, запись истории с исходом
/// `secure_input` хранится без текста, сомнений, правок и звука и в файле, и в памяти приложения
/// (`forHistory` через `HistoryStore.record`), повтор H3 её пропускает (`RecentDictations.lastWithText`),
/// а движок такие записи агентам не отдаёт (`agent_api.history_entries`).
public enum SecureDictation {
    public static let outcome = "secure_input"

    /// nil — можно записывать; иначе — причина для плашки.
    /// `field` — снимок фокуса, если он уже есть (до старта записи его не снимаем: AX-обмен съел бы начало фразы).
    public static func refusal(secureInput: Bool, field: FieldSnapshot?) -> String? {
        guard secureInput || field?.isSecure == true else { return nil }
        return UIText.pick("Поле пароля — Mostik не записывает", "Password field — Mostik won't record")
    }

    /// П10 р5: поле пароля появилось посреди записи — проверка в конце записи, до расшифровки. Звук удаляется,
    /// движок сессию бросает: ни причёсывания, ни истории, ни вставки. nil — расшифровываем как обычно.
    public static func stopRefusal(secureInput: Bool, field: FieldSnapshot?) -> String? {
        guard secureInput || field?.isSecure == true else { return nil }
        return UIText.pick("Поле пароля — запись не сохранена, текст не вставлен",
                           "Password field — recording discarded, nothing typed")
    }

    /// Запись истории для отклонённой вставки в защищённое поле: без текста, сомнений, правок и звука.
    public static func forHistory(_ entry: HistoryEntry) -> HistoryEntry {
        guard entry.outcome == outcome else { return entry }
        var clean = entry
        clean.text = ""
        clean.insertedText = ""
        clean.rawText = nil
        clean.doubts = []
        clean.corrections = []
        clean.audioPath = nil
        return clean
    }
}
