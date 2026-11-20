import Foundation

/// Имена и «кто говорит» по кадру окна звонка — для клиентов, которые не отдают их в Accessibility
/// (десктопный Телемост) или не помечают говорящего (галерея Zoom). Решения здесь, платформа —
/// в приложении: снимок окна (ScreenCaptureKit) и распознавание текста (Vision) делает
/// `CallFrameSpeakers`, сюда приходят пиксели и найденные строки текста. Кадры не сохраняются.
///
/// Плашка с именем — светлый текст на тёмной полупрозрачной подложке внизу слева в плитке
/// (Телемост, Zoom, Meet рисуют её одинаково). Говорящего клиент обводит рамкой плитки — у Телемоста
/// и Zoom она зелёная: столбец и строка зелёных пикселей слева и снизу от плашки.
/// Порог «зелёного» снят на кадрах Телемоста 3.3; для Zoom — допущение до калибровки.
public enum NamePlates {
    /// Кадр: RGBA по 8 бит, строки сверху вниз.
    public struct Pixels: Sendable {
        public let width: Int
        public let height: Int
        public let bytesPerRow: Int
        public let data: [UInt8]
        public init(width: Int, height: Int, bytesPerRow: Int, data: [UInt8]) {
            self.width = width; self.height = height; self.bytesPerRow = bytesPerRow; self.data = data
        }

        @inline(__always)
        func rgb(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
            let index = y * bytesPerRow + x * 4
            return (Int(data[index]), Int(data[index + 1]), Int(data[index + 2]))
        }

        @inline(__always)
        func luminance(_ x: Int, _ y: Int) -> Int {
            let (r, g, b) = rgb(x, y)
            return (r * 299 + g * 587 + b * 114) / 1000
        }
    }

    /// Строка текста, найденная распознаванием: рамка в пикселях кадра, начало — левый верхний угол.
    public struct Line: Equatable, Sendable {
        public var text: String
        public var x: Int, y: Int, width: Int, height: Int
        public init(text: String, x: Int, y: Int, width: Int, height: Int) {
            self.text = text; self.x = x; self.y = y; self.width = width; self.height = height
        }
    }

    public struct Plate: Equatable, Sendable {
        public var name: String
        public var x: Int, y: Int, width: Int, height: Int
        public init(name: String, x: Int, y: Int, width: Int, height: Int) {
            self.name = name; self.x = x; self.y = y; self.width = width; self.height = height
        }
        var centerX: Int { x + width / 2 }
        var centerY: Int { y + height / 2 }
    }

    /// Подписи кнопок и панелей клиента — тоже светлое на тёмном, но не имена.
    static let interfaceWords: Set<String> = [
        "participants", "chat", "share screen", "more", "leave", "mute", "unmute", "start video", "stop video",
        "record", "reactions", "apps", "captions", "summary", "security", "view", "gallery", "speaker",
        "участники", "чат", "демонстрация экрана", "показать экран", "ещё", "еще", "выйти", "покинуть",
        "запись", "реакции", "субтитры", "конспект", "вид", "галерея", "докладчик", "пригласить", "invite",
        "you", "вы", "я", "me", "host", "организатор", "summarizing", "summarizing...", "ai summary",
    ]

    /// Похоже ли на имя: два-три слова из букв одного алфавита, каждое с заглавной («Пётр Иванов»,
    /// «Anna Lee»). Строже, чем хотелось бы: на показанном экране тёмная тема рисует ту же картину —
    /// светлый текст на тёмном, — и закладки («Чайка»), кнопки («Спросить Алису AI») и адреса
    /// иначе становятся участниками. Одно слово (гость без фамилии, логин) не берём: лучше не
    /// назвать, чем назвать закладку. Обрезанное многоточием имя Zoom — берём.
    public static func looksLikeName(_ text: String) -> Bool {
        var clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let last = clean.last, last == "." || last == "…" { clean.removeLast() }
        guard (4...40).contains(clean.count), !interfaceWords.contains(clean.lowercased()) else { return false }
        let words = clean.split(separator: " ")
        guard (2...3).contains(words.count) else { return false }
        return words.allSatisfy { word in
            guard let first = word.first, first.isUppercase, word.count >= 2 else { return false }
            let letters = word.filter { $0 != "-" && $0 != "'" && $0 != "’" }
            guard !letters.isEmpty, letters.allSatisfy(\.isLetter), !word.hasPrefix("-") else { return false }
            // Один алфавит в слове: «Аl» с кириллической А и латинской l — мусор распознавания.
            let cyrillic = letters.filter { ("а"..."я").contains($0.lowercased()) || $0 == "ё" || $0 == "Ё" }.count
            guard cyrillic == 0 || cyrillic == letters.count else { return false }
            // Аббревиатуры («ISATT», «API») — не имена.
            return letters.count <= 3 || letters.contains(where: \.isLowercase)
        }
    }

    /// Подложка плашки: внутри рамки текста много тёмного (подложка) и есть светлое (буквы).
    /// Кольцо вокруг рамки не годится: распознавание даёт рамку шире или уже таблетки, и кольцо
    /// попадает то в видео плитки, то в саму таблетку. Края рамки (по 10%) не смотрим по той же причине.
    public static func onDarkPlate(_ line: Line, in pixels: Pixels) -> Bool {
        let inset = line.width / 10
        let left = max(0, line.x + inset), right = min(pixels.width, line.x + line.width - inset)
        let top = max(0, line.y), bottom = min(pixels.height, line.y + line.height)
        guard right - left >= 4, bottom - top >= 3 else { return false }
        var dark = 0, bright = 0, total = 0
        for y in top..<bottom {
            for x in stride(from: left, to: right, by: 1) {
                let value = pixels.luminance(x, y)
                total += 1
                if value < 90 { dark += 1 } else if value > 125 { bright += 1 }
            }
        }
        guard total > 0 else { return false }
        return Double(dark) / Double(total) >= 0.35 && Double(bright) / Double(total) >= 0.04
    }

    /// Плашки с именами на кадре.
    public static func plates(_ lines: [Line], in pixels: Pixels) -> [Plate] {
        lines.compactMap { line in
            let name = line.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard looksLikeName(name), onDarkPlate(line, in: pixels) else { return nil }
            return Plate(name: name, x: line.x, y: line.y, width: line.width, height: line.height)
        }
    }

    /// Зелёный рамки говорящего: зелёный канал заметно выше двух других.
    @inline(__always)
    static func isGreen(_ pixel: (r: Int, g: Int, b: Int)) -> Bool {
        pixel.g - max(pixel.r, pixel.b) > 50 && pixel.g > 140
    }

    /// Доля сплошного отрезка, чтобы считать его рамкой.
    static let frameShare = 0.8

    /// Обведена ли плитка этой плашки рамкой говорящего: слева от плашки есть зелёный столбец,
    /// а под ней — зелёная строка (рамка плитки огибает угол, где лежит плашка).
    public static func framed(_ plate: Plate, in pixels: Pixels) -> Bool {
        let reach = max(24, plate.height * 3)
        // Столбец слева: от двух высот плашки над ней до её низа — рамка идёт по краю плитки.
        let columnTop = max(0, plate.y - plate.height * 2), columnBottom = min(pixels.height - 1, plate.y + plate.height)
        guard columnBottom - columnTop >= plate.height * 2 else { return false }
        var left = false
        for x in stride(from: plate.x - 1, through: max(0, plate.x - reach), by: -1) {
            var green = 0
            for y in columnTop...columnBottom where isGreen(pixels.rgb(x, y)) { green += 1 }
            if Double(green) / Double(columnBottom - columnTop + 1) >= frameShare { left = true; break }
        }
        guard left else { return false }
        // Строка снизу — прямо под плашкой: правее плитка может кончиться раньше, чем кончится строка.
        let rowLeft = max(0, plate.x), rowRight = min(pixels.width - 1, plate.x + plate.width)
        guard rowRight - rowLeft >= 8 else { return false }
        for y in stride(from: plate.y + plate.height, through: min(pixels.height - 1, plate.y + plate.height + reach), by: 1) {
            var green = 0
            for x in rowLeft...rowRight where isGreen(pixels.rgb(x, y)) { green += 1 }
            if Double(green) / Double(rowRight - rowLeft + 1) >= frameShare { return true }
        }
        return false
    }

    /// Лишние плашки, когда клиент сказал, сколько людей в звонке: имён больше счётчика — значит,
    /// часть найдена на показанном экране. Плитки участников стоят в ряд (миниатюры над показом
    /// экрана, ряд галереи): берём ряд с наибольшим числом имён и те же имена в других местах
    /// (подпись докладчика под экраном).
    public static func select(_ plates: [Plate], count: Int?) -> [Plate] {
        let names = Set(plates.map { key($0.name) })
        guard let count, names.count > count else { return plates }
        var bands: [[Plate]] = []
        for plate in plates.sorted(by: { $0.y < $1.y }) {
            if let index = bands.firstIndex(where: { abs($0[0].y - plate.y) <= max(8, plate.height / 2) }) {
                bands[index].append(plate)
            } else {
                bands.append([plate])
            }
        }
        guard let row = bands.max(by: { Set($0.map { key($0.name) }).count < Set($1.map { key($0.name) }).count })
        else { return plates }
        let keep = Set(row.map { key($0.name) })
        return plates.filter { keep.contains(key($0.name)) }
    }

    /// Устойчивые плашки между проходами распознавания: имя на том же месте два прохода подряд.
    /// Одиночная находка — часто текст на чужом экране или всплывающая подсказка.
    public struct Tracker: Sendable {
        public static let confirmPasses = 2
        public static let forgetPasses = 3
        /// Сдвиг центра, при котором плашка считается той же (окно не двигали).
        public static let tolerance = 40

        struct Entry: Sendable {
            var plate: Plate
            var seen: Int
            var missed: Int
        }
        var entries: [Entry] = []
        public init() {}

        /// Новый проход → плашки, которым можно верить.
        public mutating func update(_ plates: [Plate]) -> [Plate] {
            var matched = Set<Int>()
            for plate in plates {
                if let index = entries.indices.first(where: { index in
                    !matched.contains(index) && NamePlates.key(entries[index].plate.name) == NamePlates.key(plate.name)
                        && abs(entries[index].plate.centerX - plate.centerX) <= Self.tolerance
                        && abs(entries[index].plate.centerY - plate.centerY) <= Self.tolerance
                }) {
                    entries[index].plate = plate
                    entries[index].seen += 1
                    entries[index].missed = 0
                    matched.insert(index)
                } else {
                    entries.append(Entry(plate: plate, seen: 1, missed: 0))
                    matched.insert(entries.count - 1)
                }
            }
            for index in entries.indices where !matched.contains(index) { entries[index].missed += 1 }
            entries.removeAll { $0.missed >= Self.forgetPasses }
            return stable
        }

        public var stable: [Plate] {
            entries.filter { $0.seen >= Self.confirmPasses && $0.missed == 0 }.map(\.plate)
        }

        public mutating func reset() { entries = [] }
    }

    static func key(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// Плашки → плитки ленты: имя и рамка говорящего. Микрофон и «я» по кадру не видны.
    public static func tiles(_ plates: [Plate], in pixels: Pixels) -> [ZoomSpeakers.Tile] {
        plates.map { ZoomSpeakers.Tile(name: $0.name, active: framed($0, in: pixels), isSelf: false) }
    }

    /// Плитки из кадра поверх снимка Accessibility. Нет плиток в дереве (Телемост) — берём кадровые.
    /// Есть (Zoom), но говорящий не помечен — помечаем по рамке ту, чьё имя совпало с плашкой
    /// (Zoom обрезает длинные имена на плашке многоточием — сравниваем по началу).
    public static func merge(_ snapshot: ZoomSpeakers.Snapshot, frame: [ZoomSpeakers.Tile]) -> ZoomSpeakers.Snapshot {
        guard !frame.isEmpty else { return snapshot }
        var result = snapshot
        if snapshot.tiles.isEmpty {
            result.tiles = frame
            return result
        }
        guard !snapshot.tiles.contains(where: \.active) else { return snapshot }
        for plate in frame where plate.active {
            let shown = key(plate.name).trimmingCharacters(in: CharacterSet(charactersIn: ".…"))
            let hits = result.tiles.indices.filter { key(result.tiles[$0].name).hasPrefix(shown) }
            if hits.count == 1 { result.tiles[hits[0]].active = true }
        }
        return result
    }
}
