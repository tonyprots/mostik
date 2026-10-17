import Foundation

// MARK: - Перезапуск движка по одному (П8, находка ревью)

/// Перезапуски движка идут строго по одному, а события старого процесса не трогают новый.
///
/// Гонка, которую закрывает: `restartEngine` снимал колбэки со старого клиента, но события,
/// уже поставленные в главную очередь (`.failed`, `.stopped`), и недоделанное рукопожатие
/// старого поколения приходили после старта нового — и запускали ещё один перезапуск или
/// перетирали статус «Готов». Два запроса подряд (Настройки + «Проверка») поднимали два
/// Python с моделями одновременно.
///
/// Порядок: `begin()` (поколение сразу растёт — всё старое отныне чужое) → старый процесс
/// остановлен → `finish()` → новый клиент со своим поколением. Пока идёт перезапуск,
/// новые запросы вливаются в него.
public struct EngineRestartGate: Sendable {
    public private(set) var generation = 0
    public private(set) var restarting = false

    public init() {}

    /// Запрос перезапуска. false — перезапуск уже идёт, этот запрос вливается в него.
    public mutating func begin() -> Bool {
        guard !restarting else { return false }
        restarting = true
        generation += 1
        return true
    }

    /// Старый процесс остановлен; новое поколение можно запускать.
    @discardableResult
    public mutating func finish() -> Int {
        restarting = false
        return generation
    }

    /// Событие или ответ поколения `g` ещё актуальны.
    public func isCurrent(_ g: Int) -> Bool { g == generation && !restarting }
}

// MARK: - Тексты падений движка (П8, пункт 6)

/// Две ступени восстановления. Сам `EngineClient` перезапускает упавший процесс с паузами
/// 1, 2, 4, 8, 16, 30 с (до `maxRapid` падений подряд в первую минуту после запуска). Если и это
/// не помогло — `UpkeepController` ещё трижды пробует поднять движок заново с паузами 2, 5, 15 с,
/// и только потом в «Проверке» остаётся красная строка с кнопкой «Перезапустить».
public enum EngineRecovery {
    /// Паузы второй ступени (R7).
    public static let retryDelays: [Double] = [2, 5, 15]
    /// Сколько быстрых падений подряд терпит первая ступень (`EngineClient.maxRapidRestarts`).
    public static let maxRapid = 6

    /// Строка статуса, пока клиент ждёт перезапуска после падения.
    public static func restarting(attempt: Int, delay: Double, crashes: Int, russian ru: Bool) -> String {
        let seconds = formatSeconds(delay, russian: ru)
        let base = ru
            ? "Движок упал — перезапуск через \(seconds), попытка \(attempt) из \(maxRapid)"
            : "Engine crashed — restarting in \(seconds), attempt \(attempt) of \(maxRapid)"
        guard crashes > 1 else { return base }
        return base + (ru ? " · падений за сеанс: \(crashes)" : " · crashes this session: \(crashes)")
    }

    /// Ошибка + «повтор через N с (k из 3)» на второй ступени.
    public static func retrying(_ why: String, after delay: Double, attempt: Int, russian ru: Bool) -> String {
        let seconds = formatSeconds(delay, russian: ru)
        let tail = ru ? "повтор через \(seconds) (\(attempt) из \(retryDelays.count))"
                      : "retrying in \(seconds) (\(attempt) of \(retryDelays.count))"
        return why.isEmpty ? tail.prefix(1).uppercased() + tail.dropFirst() : why + " · " + tail
    }

    /// Обе ступени исчерпаны.
    public static func gaveUp(_ why: String, crashes: Int, logPath: String, russian ru: Bool) -> String {
        let pauses = retryDelays.map { formatSeconds($0, russian: ru) }
        let tried = ru
            ? "Движок не поднимается: ещё \(retryDelays.count) попытки с паузами \(pauses.joined(separator: ", ")) не помогли"
            : "The engine won’t start: \(retryDelays.count) more attempts \(pauses.joined(separator: ", ")) apart didn’t help"
        var parts = [tried]
        if !why.isEmpty { parts.append(why) }
        if crashes > 0 { parts.append(ru ? "падений за сеанс: \(crashes)" : "crashes this session: \(crashes)") }
        parts.append(ru ? "журнал: \(logPath)" : "log: \(logPath)")
        return parts.joined(separator: " · ")
    }

    public static func formatSeconds(_ seconds: Double, russian ru: Bool) -> String {
        let value = seconds == seconds.rounded() ? String(Int(seconds)) : String(format: "%.1f", seconds)
        return ru ? value.replacingOccurrences(of: ".", with: ",") + "\u{00A0}с" : value + "\u{00A0}s"
    }
}
