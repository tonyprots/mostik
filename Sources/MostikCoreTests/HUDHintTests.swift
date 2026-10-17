import Foundation
import MostikCore

// Подсказка управления в плашке записи (П9-B, R3b): клавиша из настроек, Esc — всегда, через 2 с;
// при удержании — «Отпустите правый ⌥», без рук — «Стоп ⌥»;
// отмена словом «esc», без глифа ⎋ (мелким он читается как ↺ «повторить»).
func runHUDHintTests() {
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
