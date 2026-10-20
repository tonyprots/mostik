import Foundation

/// Полоса «Сверяю» в плашке диктовки. Движок присылает долю проверенных пачек, а пачек в диктовке
/// две–восемь, и последнюю долю он не шлёт вовсе: настоящая доля стоит на одной ступеньке, потом
/// плашка гаснет. Поэтому полоса ползёт сама, замедляясь у потолка, и не отстаёт от настоящей
/// доли. Когда результат готов, доля становится 1 и полоса быстро добегает до конца.
public enum ProgressCreep {
    /// Выше этой доли полоса сама не заползает: последние проценты — только по готовности.
    public static let ceiling = 0.9
    /// На сколько полоса может обогнать настоящую долю: следующая пачка ещё не пришла.
    public static let lead = 0.35
    /// Постоянная времени ползучести, с: за 6 с проходит ~63 % пути до потолка.
    public static let tau: TimeInterval = 6
    /// Сколько держать полную полосу перед итогом, с: глаз должен успеть увидеть 100 %.
    public static let finishHold: TimeInterval = 0.3

    /// Видимая доля через `elapsed` секунд с начала сверки при настоящей доле `share`.
    public static func shown(share: Double, elapsed: TimeInterval) -> Double {
        let real = min(max(share, 0), 1)
        if real >= 1 { return 1 }
        let creep = ceiling * (1 - exp(-max(elapsed, 0) / tau))
        return max(real, min(creep, real + lead, ceiling))
    }
}
