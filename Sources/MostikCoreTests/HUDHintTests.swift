import Foundation
import MostikCore

// Подсказка управления в плашке записи (П9-B, R3b): клавиша из настроек, Esc — всегда, через 2 с;
// при удержании — «Отпустите правый ⌥», без рук — «Стоп ⌥»;
// отмена словом «esc», без глифа ⎋ (мелким он читается как ↺ «повторить»).
func runHUDHintTests() {
    // Пауза: пункты видны сразу и нажимаются; запись заканчивается кнопкой в любом режиме.
    equal(HUDHint.pausedItems(holdKey: "rightOption").map(\.key), ["⌥", "esc"], "на паузе — вставить и отмена")
    var held = DictationMachine(makeSessionID: { "p1" })
    _ = held.handle(.holdBegan(at: 0))
    _ = held.handle(.latch)   // пауза при удержании переводит запись в режим без рук
    equal(held.handle(.holdEnded(at: 2)), [], "на паузе отпускание клавиши текст не отправляет")
    equal(held.handle(.finish(at: 5)), [.stopRecording(session: "p1")], "«Вставить» заканчивает запись")
    equal(held.handle(.holdEnded(at: 6)), [], "отпускание после «Вставить» ничего не значит")
    var holding = DictationMachine(makeSessionID: { "p2" })
    _ = holding.handle(.holdBegan(at: 0))
    equal(holding.handle(.finish(at: 3)), [.stopRecording(session: "p2")], "«Вставить» работает и пока клавишу держат")
    var cancelled = DictationMachine(makeSessionID: { "p3" })
    _ = cancelled.handle(.togglePressed(at: 0))
    equal(cancelled.handle(.abort), [.discardRecording(session: "p3")], "«Отмена» сбрасывает запись")
    var idle = DictationMachine()
    equal(idle.handle(.finish(at: 1)), [], "без записи «Вставить» ничего не делает")

    let was = UIText.isRussian
    defer { UIText.isRussian = was }
    UIText.isRussian = true
    equal(HUDHint.controls(holdKey: "rightOption", elapsed: 1.9), nil, "до двух секунд подсказки нет")
    equal(HUDHint.items(holdKey: "rightOption", elapsed: 1.9), nil, "до двух секунд пунктов нет")
    equal(HUDHint.controls(holdKey: "rightOption", elapsed: 2), "Отпустите правый ⌥ · Отмена esc", "удержание: отпустить клавишу")
    equal(HUDHint.controls(holdKey: "rightOption", elapsed: 2, handsFree: true), "Стоп ⌥ · Отмена esc", "без рук: нажать ещё раз")
    equal(HUDHint.controls(holdKey: "rightCommand", elapsed: 42), "Отпустите правый ⌘ · Отмена esc", "правый ⌘")
    equal(HUDHint.controls(holdKey: "fn", elapsed: 42), "Отпустите fn · Отмена esc", "у fn нет стороны")
    equal(HUDHint.items(holdKey: "rightCommand", elapsed: 3)?.map(\.key), ["⌘", "esc"], "капсулы: клавиша из настроек и esc")
    equal(HUDHint.spoken(holdKey: "rightOption"), "Отпустите правый Option, чтобы закончить; отмена — Esc")
    equal(HUDHint.spoken(holdKey: "rightOption", handsFree: true), "Стоп — правый Option, отмена — Esc")
    equal(HUDHint.keySymbol("что-то старое"), "⌥", "неизвестная клавиша — умолчание правый ⌥")
    UIText.isRussian = false
    equal(HUDHint.controls(holdKey: "rightOption", elapsed: 3), "Release right ⌥ · Cancel esc")
    equal(HUDHint.controls(holdKey: "fn", elapsed: 3, handsFree: true), "Stop fn · Cancel esc")
    equal(HUDHint.spoken(holdKey: "fn"), "Release fn to finish, Esc to cancel")
    equal(HUDHint.spoken(holdKey: "fn", handsFree: true), "Stop: fn, cancel: Esc")
    for key in ["rightOption", "rightCommand", "fn"] {
        let all = (HUDHint.controls(holdKey: key, elapsed: 3) ?? "") + HUDHint.spoken(holdKey: key)
        check(!all.contains("⎋") && !all.contains("↺"), "\(key): в подсказке нет ⎋ и ↺")
    }
    // Умолчание настроек совпадает с умолчанием подсказки.
    equal(HUDHint.keySymbol(MostikSettings().holdKey), "⌥")
}
