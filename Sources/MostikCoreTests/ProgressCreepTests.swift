import Foundation
import MostikCore

/// Полоса «Сверяю» ползёт сама и добегает до 100 % по готовности — ProgressCreep.
func runProgressCreepTests() {
    typealias P = ProgressCreep
    equal(P.shown(share: 0, elapsed: 0), 0, "в начале пусто")
    check(P.shown(share: 0, elapsed: 2) > 0.1, "без новых пачек полоса всё равно движется")
    check(P.shown(share: 0, elapsed: 3) > P.shown(share: 0, elapsed: 1), "и только вперёд")
    check(P.shown(share: 0, elapsed: 600) <= P.lead + 1e-9, "без пачек не убегает дальше запаса")
    check(P.shown(share: 0.5, elapsed: 600) <= P.ceiling + 1e-9, "сама до 100 % не доходит")
    equal(P.shown(share: 0.5, elapsed: 0), 0.5, "не отстаёт от настоящей доли")
    equal(P.shown(share: 1, elapsed: 0), 1, "готово — полная полоса сразу")
    equal(P.shown(share: 3, elapsed: 1), 1, "доля больше 1 обрезается")
    equal(P.shown(share: -1, elapsed: -5), 0, "мусор на входе не ломает")
}
