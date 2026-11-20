import Foundation
import MostikCore

/// Плашки с именами и рамка говорящего по кадру — на нарисованных кадрах, без настоящих звонков.
func runNamePlatesTests() {
    typealias Pixels = NamePlates.Pixels

    /// Кадр 400×300: светлый фон, плитка 20…220 × 20…180 с плашкой внизу слева, по желанию — зелёная рамка.
    func frame(green: Bool, plateText: Bool = true) -> Pixels {
        let width = 400, height = 300, row = width * 4
        var data = [UInt8](repeating: 230, count: row * height)
        func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ rgb: (UInt8, UInt8, UInt8)) {
            for y in y0..<y1 { for x in x0..<x1 {
                let i = y * row + x * 4
                data[i] = rgb.0; data[i + 1] = rgb.1; data[i + 2] = rgb.2; data[i + 3] = 255
            } }
        }
        fill(20, 20, 220, 180, (120, 110, 100))  // видео плитки
        if green {
            fill(20, 20, 220, 23, (40, 200, 70)); fill(20, 177, 220, 180, (40, 200, 70))
            fill(20, 20, 23, 180, (40, 200, 70)); fill(217, 20, 220, 180, (40, 200, 70))
        }
        fill(30, 150, 130, 170, (30, 30, 34))  // тёмная таблетка
        if plateText { for x in stride(from: 40, to: 120, by: 6) { fill(x, 155, x + 3, 165, (235, 235, 235)) } }
        return Pixels(width: width, height: height, bytesPerRow: row, data: data)
    }
    let line = NamePlates.Line(text: "Пётр Иванов", x: 36, y: 154, width: 90, height: 12)

    // MARK: имя или не имя
    do {
        check(NamePlates.looksLikeName("Пётр Иванов"), "имя и фамилия")
        check(NamePlates.looksLikeName("Anna Lee"), "латиница")
        check(NamePlates.looksLikeName("Анна-Мария Ли"), "двойное имя через дефис")
        check(NamePlates.looksLikeName("Пётр Иванов-..."), "обрезанное многоточием")
        check(!NamePlates.looksLikeName("Чайка"), "одно слово — закладка или гость, не берём")
        check(!NamePlates.looksLikeName("9 Дистрибуция Ад"), "цифра")
        check(!NamePlates.looksLikeName("Спросить Алису Аl"), "смесь алфавитов в слове")
        check(!NamePlates.looksLikeName("justhost.ru"), "адрес")
        check(!NamePlates.looksLikeName("ISATT KAPTA"), "капс")
        check(!NamePlates.looksLikeName("Summarizing..."), "подпись кнопки")
        check(!NamePlates.looksLikeName("Participants"), "кнопка — не имя")
        check(!NamePlates.looksLikeName("Слот на биометрию"), "фраза со строчным словом — не имя")
        check(!NamePlates.looksLikeName("-. Participants"), "мусор распознавания")
        check(!NamePlates.looksLikeName("Mon 2 Jan 09:15"), "дата и время")
        check(!NamePlates.looksLikeName("Проект \"Стены\""), "кавычки — фраза")
    }

    // MARK: плашка и рамка
    do {
        let lit = frame(green: true)
        check(NamePlates.onDarkPlate(line, in: lit), "светлые буквы на тёмной таблетке")
        check(!NamePlates.onDarkPlate(line, in: frame(green: true, plateText: false)), "пустая таблетка — без букв")
        let onLight = NamePlates.Line(text: "Пётр Иванов", x: 250, y: 200, width: 90, height: 12)
        check(!NamePlates.onDarkPlate(onLight, in: lit), "текст на светлом — не плашка")
        let plates = NamePlates.plates([line, NamePlates.Line(text: "Chat", x: 36, y: 154, width: 90, height: 12)], in: lit)
        equal(plates.map(\.name), ["Пётр Иванов"], "кнопка отсеяна")
        check(NamePlates.framed(plates[0], in: lit), "зелёная рамка слева и снизу — говорит")
        check(!NamePlates.framed(plates[0], in: frame(green: false)), "без рамки — молчит")
        equal(NamePlates.tiles(plates, in: lit), [.init(name: "Пётр Иванов", active: true, isSelf: false)], "плитка ленты")
    }

    // MARK: устойчивость между проходами
    do {
        var tracker = NamePlates.Tracker()
        let plate = NamePlates.Plate(name: "Пётр Иванов", x: 36, y: 154, width: 90, height: 12)
        let ghost = NamePlates.Plate(name: "Мария", x: 300, y: 40, width: 50, height: 12)
        equal(tracker.update([plate, ghost]), [], "первый проход — ещё не верим")
        var moved = plate; moved.x += 10
        equal(tracker.update([moved]).map(\.name), ["Пётр Иванов"], "второй проход рядом — верим")
        equal(tracker.update([]), [], "пропала — не показываем")
        equal(tracker.update([moved]).map(\.name), ["Пётр Иванов"], "вернулась в пределах трёх проходов — снова верим")
        var far = plate; far.x += 200
        equal(tracker.update([far]), [], "далеко — другая плашка, заново")
    }

    // MARK: лишние плашки при известном счётчике
    do {
        func plate(_ name: String, _ x: Int, _ y: Int) -> NamePlates.Plate { .init(name: name, x: x, y: y, width: 80, height: 12) }
        let found = [plate("Пётр Иванов", 600, 100), plate("Мария Смирнова", 850, 101),
                     plate("Дистрибуция Отчёт", 650, 218), plate("Мария Смирнова", 740, 895)]
        equal(NamePlates.select(found, count: 2).map(\.name), ["Пётр Иванов", "Мария Смирнова", "Мария Смирнова"],
              "ряд миниатюр и подпись докладчика; закладка с показанного экрана отсеяна")
        equal(NamePlates.select(found, count: nil).count, 4, "счётчика нет — не трогаем")
        equal(NamePlates.select(found, count: 3).count, 4, "имён не больше счётчика — не трогаем")
    }

    // MARK: кадр поверх дерева
    do {
        let empty = ZoomSpeakers.Snapshot(tiles: [], myUnmuted: true, count: 2)
        let fromFrame = [ZoomSpeakers.Tile(name: "Пётр Иванов", active: true, isSelf: false)]
        equal(NamePlates.merge(empty, frame: fromFrame).tiles, fromFrame, "Телемост: плитки из кадра")
        equal(NamePlates.merge(empty, frame: fromFrame).count, 2, "счётчик остаётся")
        let zoom = ZoomSpeakers.Snapshot(tiles: [.init(name: "Пётр Иванов-Сидоров", active: false, isSelf: false),
                                                 .init(name: "Мария", active: false, isSelf: false)])
        let cut = [ZoomSpeakers.Tile(name: "Пётр Иванов-...", active: true, isSelf: false)]
        equal(NamePlates.merge(zoom, frame: cut).tiles.map(\.active), [true, false], "обрезанное имя Zoom — по началу")
        let marked = ZoomSpeakers.Snapshot(tiles: [.init(name: "Мария", active: true, isSelf: false)])
        equal(NamePlates.merge(marked, frame: fromFrame), marked, "пометка из дерева главнее кадра")
    }
}
