// Оформление .dmg без сторонних утилит и без AppleScript к Finder (тот спросил бы разрешение «Автоматизация»).
//
//   swift scripts/dmg-layout.swift background <папка>      — background.png (1×) и background@2x.png (2×) кодом
//   swift scripts/dmg-layout.swift dsstore <том> [имя.app] — .DS_Store: окно, фон, места значков
//
// .DS_Store пишется по формату Finder (буддийский аллокатор + B-дерево из одного листа), фон указан
// и alias-записью, и закладкой (pBBk) — как это делает dmgbuild. Том должен быть смонтирован на запись.
import AppKit
import Foundation

let windowSize = CGSize(width: 640, height: 400)
let appPoint = CGPoint(x: 170, y: 190)     // центр значка, верхний левый угол окна — начало координат
let appsPoint = CGPoint(x: 470, y: 190)
let iconSize = 128

// MARK: фон

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func drawBackground(scale: CGFloat) -> Data {
    let w = Int(windowSize.width * scale), h = Int(windowSize.height * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = windowSize
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    // Переворачиваем: дальше координаты как у Finder — от верхнего левого угла.
    let t = NSAffineTransform()
    t.translateX(by: 0, yBy: windowSize.height)
    t.scaleX(by: 1, yBy: -1)
    t.concat()

    // Палитра приложения (DesignSystem.swift): canvas, ink, inkSecondary, accent.
    color(0xF7F8F6).setFill()
    NSRect(origin: .zero, size: windowSize).fill()

    // Стрелка от Mostik к «Программам»: тонкая линия в акцентном цвете, без градиентов и теней.
    let y = appPoint.y
    let from = appPoint.x + CGFloat(iconSize) / 2 + 22, to = appsPoint.x - CGFloat(iconSize) / 2 - 22
    let line = NSBezierPath()
    line.move(to: NSPoint(x: from, y: y))
    line.line(to: NSPoint(x: to - 3, y: y))
    line.lineWidth = 2
    line.lineCapStyle = .round
    color(0x2B6B61).setStroke()
    line.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: to - 12, y: y - 8))
    head.line(to: NSPoint(x: to, y: y))
    head.line(to: NSPoint(x: to - 12, y: y + 8))
    head.lineWidth = 2
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    func centered(_ text: String, font: NSFont, color c: NSColor, top: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: c, .paragraphStyle: style])
        let size = attributed.size()
        // В перевёрнутом контексте текст рисуется вверх ногами — рисуем через временный неперевёрнутый.
        NSGraphicsContext.saveGraphicsState()
        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: top + size.height)
        flip.scaleX(by: 1, yBy: -1)
        flip.concat()
        attributed.draw(in: NSRect(x: 0, y: 0, width: windowSize.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
    }
    centered("Перетащите Mostik в папку «Программы»", font: .systemFont(ofSize: 15, weight: .semibold),
             color: color(0x1A1D1C), top: 300)
    centered("Drag Mostik to Applications", font: .systemFont(ofSize: 12, weight: .regular),
             color: color(0x59615E), top: 324)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// MARK: alias на фон

let hfsEpochOffset: Double = 2_082_844_800  // секунды между 1904-01-01 и 1970-01-01

func be16(_ v: Int16) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
func be16u(_ v: UInt16) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
func be32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
func be64(_ v: UInt64) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
func pascal(_ s: String, field: Int) -> Data {
    var bytes = Array(s.replacingOccurrences(of: ":", with: "/").utf8.prefix(field - 1))
    var d = Data([UInt8(bytes.count)])
    d.append(contentsOf: bytes)
    bytes = []
    d.append(Data(count: field - d.count))
    return d
}
func utf16be(_ s: String) -> Data {
    var d = be16u(UInt16(s.utf16.count))
    for u in s.utf16 { d.append(be16u(u)) }
    return d
}
func inode(_ path: String) -> UInt32 {
    var st = stat()
    precondition(stat(path, &st) == 0, "stat \(path)")
    return UInt32(truncatingIfNeeded: st.st_ino)
}

/// Alias-запись версии 2 (как mac_alias в dmgbuild): Finder до сих пор читает её в icvp.backgroundImageAlias.
func aliasRecord(volume: URL, file: URL) throws -> Data {
    let volName = try volume.resourceValues(forKeys: [.volumeNameKey]).volumeName ?? volume.lastPathComponent
    let volDate = try volume.resourceValues(forKeys: [.volumeCreationDateKey]).volumeCreationDate ?? Date()
    let fileDate = try file.resourceValues(forKeys: [.creationDateKey]).creationDate ?? Date()
    let folder = file.deletingLastPathComponent()
    let volHFS = volDate.timeIntervalSince1970 + hfsEpochOffset
    let fileHFS = fileDate.timeIntervalSince1970 + hfsEpochOffset
    let relative = String(file.path.dropFirst(volume.path.count))  // "/.background/background.tiff"

    var body = Data()
    body.append(be16(0))                                    // kind: файл
    body.append(pascal(volName, field: 28))
    body.append(be32(UInt32(volHFS)))
    body.append(Data("H+".utf8))
    body.append(be16(5))                                    // съёмный диск
    body.append(be32(inode(folder.path)))
    body.append(pascal(file.lastPathComponent, field: 64))
    body.append(be32(inode(file.path)))
    body.append(be32(UInt32(fileHFS)))
    body.append(Data(count: 8))                             // тип и создатель
    body.append(be16(-1)); body.append(be16(-1))            // nlvlFrom, nlvlTo
    body.append(be32(0))                                    // атрибуты тома
    body.append(Data(count: 2 + 10))                        // fsID и резерв

    func tag(_ t: Int16, _ value: Data) {
        body.append(be16(t)); body.append(be16(Int16(value.count))); body.append(value)
        if value.count % 2 == 1 { body.append(0) }
    }
    tag(0, Data(folder.lastPathComponent.replacingOccurrences(of: ":", with: "/").utf8))
    tag(1, be32(inode(folder.path)))
    tag(2, Data((volName + relative.replacingOccurrences(of: "/", with: ":")).utf8))
    tag(14, utf16be(file.lastPathComponent))
    tag(15, utf16be(volName))
    tag(16, be64(UInt64(volHFS * 65536)))
    tag(17, be64(UInt64(fileHFS * 65536)))
    tag(18, Data(relative.utf8))
    tag(19, Data(volume.path.utf8))
    body.append(be16(-1)); body.append(be16(0))

    var record = Data(count: 4)                             // appInfo
    record.append(be16u(UInt16(8 + body.count)))
    record.append(be16(2))                                  // версия
    record.append(body)
    return record
}

// MARK: .DS_Store

enum DSValue { case blob(Data), long(UInt32) }

struct DSRecord {
    let name: String, code: String, value: DSValue
    var encoded: Data {
        var d = be32(UInt32(name.utf16.count))
        for u in name.utf16 { d.append(be16u(u)) }
        d.append(Data(code.utf8))
        switch value {
        case .blob(let b): d.append(Data("blob".utf8)); d.append(be32(UInt32(b.count))); d.append(b)
        case .long(let v): d.append(Data("long".utf8)); d.append(be32(v))
        }
        return d
    }
}

func plist(_ object: [String: Any]) -> Data {
    try! PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
}

func iloc(_ p: CGPoint) -> Data {
    be32(UInt32(p.x)) + be32(UInt32(p.y)) + Data(repeating: 0xFF, count: 6) + Data(count: 2)
}

/// Буддийский аллокатор: заголовок 0x20 по смещению 0, DSDB 0x20@0x20, корень 0x800@0x800, лист 0x1000@0x1000;
/// остальное пространство до 2^31 — в списках свободных блоков. Смещения считаются от 4-го байта файла.
func dsStore(_ records: [DSRecord]) -> Data {
    let sorted = records.sorted {
        let a = $0.name.lowercased(), b = $1.name.lowercased()
        return a == b ? $0.code < $1.code : a < b
    }
    var leaf = be32(0) + be32(UInt32(sorted.count))
    for r in sorted { leaf.append(r.encoded) }
    precondition(leaf.count <= 0x1000, "записи не помещаются в один лист")

    let dsdb = be32(2) + be32(0) + be32(UInt32(sorted.count)) + be32(1) + be32(0x1000)

    var root = be32(3) + be32(0)
    let addresses: [UInt32] = [0x800 | 11, 0x20 | 5, 0x1000 | 12]
    for i in 0..<256 { root.append(be32(i < addresses.count ? addresses[i] : 0)) }
    root.append(be32(1)); root.append(Data([4])); root.append(Data("DSDB".utf8)); root.append(be32(1))
    var free = [[UInt32]](repeating: [], count: 32)
    for k in [6, 7, 8, 9, 10] { free[k] = [UInt32(1) << k] }   // 0x40…0x400 до корня
    for k in 13..<31 { free[k] = [UInt32(1) << k] }             // 0x2000…0x40000000 после листа
    for list in free {
        root.append(be32(UInt32(list.count)))
        for o in list { root.append(be32(o)) }
    }
    precondition(root.count <= 0x800)

    var file = Data(count: 4 + 0x2000)
    func put(_ d: Data, at offset: Int) { file.replaceSubrange((4 + offset)..<(4 + offset + d.count), with: d) }
    let header = be32(1) + Data("Bud1".utf8) + be32(0x800) + be32(0x800) + be32(0x800)
        + Data([0x00, 0x00, 0x10, 0x0C, 0x00, 0x00, 0x00, 0x87, 0x00, 0x00, 0x20, 0x0B, 0x00, 0x00, 0x00, 0x00])
    file.replaceSubrange(0..<header.count, with: header)
    put(dsdb, at: 0x20)
    put(root, at: 0x800)
    put(leaf, at: 0x1000)
    return file
}

func writeDSStore(volume: URL, appName: String) throws {
    let background = volume.appendingPathComponent(".background/background.tiff")
    guard FileManager.default.fileExists(atPath: background.path) else {
        throw NSError(domain: "dmg-layout", code: 1, userInfo: [NSLocalizedDescriptionKey: "нет \(background.path)"])
    }
    let alias = try aliasRecord(volume: volume, file: background)
    // Р2 Н5: закладку `pBBk` не пишем. URL-закладка тома образа хранит путь к файлу образа на машине
    // сборщика (логин и рабочую папку). Finder берёт фон и из alias-записи `icvp.backgroundImageAlias`.
    let w = Int(windowSize.width), h = Int(windowSize.height) + 28   // + заголовок окна
    let bwsp = plist([
        "WindowBounds": "{{200, 140}, {\(w), \(h)}}",
        "ShowToolbar": false, "ShowStatusBar": false, "ShowPathbar": false,
        "ShowSidebar": false, "ContainerShowSidebar": false, "ShowTabView": false, "PreviewPaneVisibility": false,
    ])
    let icvp = plist([
        "viewOptionsVersion": 1, "backgroundType": 2, "backgroundImageAlias": alias,
        "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0,
        "iconSize": Double(iconSize), "textSize": 13.0, "gridSpacing": 100.0, "gridOffsetX": 0.0, "gridOffsetY": 0.0,
        "arrangeBy": "none", "labelOnBottom": true, "showItemInfo": false, "showIconPreview": true,
    ])
    let records = [
        DSRecord(name: ".", code: "bwsp", value: .blob(bwsp)),
        DSRecord(name: ".", code: "icvp", value: .blob(icvp)),
        DSRecord(name: ".", code: "vSrn", value: .long(1)),
        DSRecord(name: appName, code: "Iloc", value: .blob(iloc(appPoint))),
        DSRecord(name: "Applications", code: "Iloc", value: .blob(iloc(appsPoint))),
    ]
    try dsStore(records).write(to: volume.appendingPathComponent(".DS_Store"))
}

// MARK: вход

let args = CommandLine.arguments
switch args.count > 2 ? args[1] : "" {
case "background":
    let dir = URL(fileURLWithPath: args[2])
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try drawBackground(scale: 1).write(to: dir.appendingPathComponent("background.png"))
    try drawBackground(scale: 2).write(to: dir.appendingPathComponent("background@2x.png"))
    print("OK: \(dir.path)/background{,@2x}.png")
case "dsstore":
    let volume = URL(fileURLWithPath: args[2]).standardizedFileURL
    try writeDSStore(volume: volume, appName: args.count > 3 ? args[3] : "Mostik.app")
    print("OK: \(volume.path)/.DS_Store")
default:
    FileHandle.standardError.write(Data("usage: dmg-layout.swift background <dir> | dsstore <volume> [App.app]\n".utf8))
    exit(2)
}
