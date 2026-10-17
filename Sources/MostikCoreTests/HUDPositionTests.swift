import CoreGraphics
import Foundation
import MostikCore

/// Плашку диктовки можно перетащить (решение автора): место — доля экрана,
/// всегда в видимой области; «Вернуть на место» — место по умолчанию.
func runHUDPositionTests() {
    let plaque = CGSize(width: 400, height: 44)
    // Экран 1440×900 с Dock снизу (видимая область выше на 60) и строкой меню сверху (25).
    let visible = CGRect(x: 0, y: 60, width: 1440, height: 815)

    // По умолчанию — снизу по центру, в 40 pt над низом видимой области.
    equal(HUDPosition.defaultOrigin(plaque: plaque, visible: visible), CGPoint(x: 520, y: 100))
    equal(HUDPosition.origin(saved: nil, plaque: plaque, visible: visible), CGPoint(x: 520, y: 100), "без своего места")

    // Отпустили у места по умолчанию — своё место не заводится.
    equal(HUDPosition.save(origin: CGPoint(x: 530, y: 108), plaque: plaque, visible: visible), nil, "в пределах 16 pt")
    // Отпустили в правом верхнем углу — запоминается доля, и плашка встаёт туда же.
    let corner = CGPoint(x: 1000, y: 780)
    let saved = HUDPosition.save(origin: corner, plaque: plaque, visible: visible)
    check(saved != nil, "своё место")
    if let saved {
        check(abs(saved.x - 1200.0 / 1440) < 1e-9, "доля по горизонтали — центр плашки")
        check(abs(saved.y - (802.0 - 60) / 815) < 1e-9, "доля по вертикали — от низа видимой области")
        let back = HUDPosition.origin(saved: saved, plaque: plaque, visible: visible)
        check(abs(back.x - corner.x) < 0.001 && abs(back.y - corner.y) < 0.001, "то же место на том же экране")
        // Другой экран, поменьше и со сдвигом: то же относительное место, целиком на экране.
        let other = CGRect(x: -1280, y: 0, width: 1280, height: 775)
        let moved = HUDPosition.origin(saved: saved, plaque: plaque, visible: other)
        check(other.contains(CGRect(origin: moved, size: plaque)), "на другом экране — в видимой области")
        check(moved.x > other.midX, "и в той же стороне экрана")
    }

    // Ушла за край — встаёт к краю с отступом 8.
    equal(HUDPosition.clamp(CGPoint(x: -300, y: -50), plaque: plaque, visible: visible), CGPoint(x: 8, y: 68))
    equal(HUDPosition.clamp(CGPoint(x: 5000, y: 5000), plaque: plaque, visible: visible), CGPoint(x: 1032, y: 823))
    equal(HUDPosition.clamp(CGPoint(x: 300, y: 300), plaque: plaque, visible: visible), CGPoint(x: 300, y: 300), "внутри — не трогаем")
    // Экран уже плашки — по центру, а не за краем.
    let tiny = CGRect(x: 0, y: 0, width: 300, height: 40)
    equal(HUDPosition.clamp(CGPoint(x: 100, y: 100), plaque: plaque, visible: tiny), CGPoint(x: -50, y: -2))
    // Сохранили за краем — запоминается уже возвращённое место.
    if let edge = HUDPosition.save(origin: CGPoint(x: -300, y: 400), plaque: plaque, visible: visible) {
        equal(HUDPosition.origin(saved: edge, plaque: plaque, visible: visible).x, 8, "слева у края")
    } else {
        check(false, "за краем далеко от места по умолчанию — своё место")
    }
    // Битые доли — тоже в видимой области.
    let wild = HUDPosition.origin(saved: .init(x: 7, y: -3), plaque: plaque, visible: visible)
    check(visible.contains(CGRect(origin: wild, size: plaque)), "доли за 0…1")
    equal(HUDPosition.origin(saved: .init(x: .nan, y: 0.5), plaque: plaque, visible: visible), CGPoint(x: 520, y: 100), "NaN — по умолчанию")
    equal(HUDPosition.save(origin: .zero, plaque: plaque, visible: .zero), nil, "экран без размера")

    // Выбор экрана.
    let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
    equal(HUDPosition.screenIndex(mouse: CGPoint(x: 2000, y: 500), screens: screens), 1, "экран с курсором")
    equal(HUDPosition.screenIndex(mouse: CGPoint(x: -10, y: -10), screens: screens), 0, "курсор вне экранов — главный")
    equal(HUDPosition.screenIndex(mouse: .zero, screens: []), nil)
    equal(HUDPosition.screenIndex(plaque: CGRect(x: 1300, y: 100, width: 400, height: 44), screens: screens), 1, "где больше площади")
    equal(HUDPosition.screenIndex(plaque: CGRect(x: 4000, y: 100, width: 400, height: 44), screens: screens), 1, "вне экранов — ближайший")

    // Хранение.
    let data = HUDPosition.encode(.init(x: 0.25, y: 0.75))
    equal(HUDPosition.decode(data), .init(x: 0.25, y: 0.75))
    equal(HUDPosition.encode(nil), nil, "сброс — пусто")
    equal(HUDPosition.decode(Data("мусор".utf8)), nil, "битое значение — как будто места нет")
    equal(HUDPosition.decode(nil), nil)

    // Страж по исходникам: перетаскивание не активирует приложение и не делает панель активирующей.
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let app = (try? String(contentsOf: root.appendingPathComponent("Mostik/MostikApp.swift"), encoding: .utf8)) ?? ""
    check(app.contains("styleMask: [.borderless, .nonactivatingPanel]"), "плашка — неактивирующая панель")
    if let a = app.range(of: "private func hudDrag("), let b = app.range(of: "private func resetHUDPosition(") {
        let body = app[a.upperBound..<b.lowerBound]
        check(!body.contains("activate") && !body.contains("makeKey"), "перетаскивание не уводит фокус")
    } else {
        check(false, "hudDrag и resetHUDPosition в MostikApp.swift")
    }
    let hud = (try? String(contentsOf: root.appendingPathComponent("MostikUI/HUDView.swift"), encoding: .utf8)) ?? ""
    check(hud.contains(".simultaneousGesture("), "перетаскивание не отнимает щелчки у плашки")
    check(hud.contains("guard !dragging, Date().timeIntervalSince(dragEndedAt) > 0.3"), "отпустили после перетаскивания — история не открывается")
}
