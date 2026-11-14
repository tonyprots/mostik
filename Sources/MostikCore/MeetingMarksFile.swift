import Foundation

/// Пометки встречи на диске (`marks.json` в папке встречи). Пока идёт запись, пометки жили только
/// в памяти и пропадали при падении или выходе; файл переживает и то и другое — дорасшифровка
/// и «Повторить расшифровку» после перезапуска берут пометки из него.
public enum MeetingMarksFile {
    public static let name = "marks.json"

    public static func url(in folder: URL) -> URL { folder.appendingPathComponent(name) }

    /// Записать текущий набор целиком, атомарно. Пустой набор файл не создаёт.
    public static func save(_ marks: [MeetingMarkPayload], in folder: URL) {
        guard !marks.isEmpty else { return }
        let items = marks.map { ["at": ($0.at * 10).rounded() / 10, "text": $0.text] as [String: Any] }
        guard let data = try? JSONSerialization.data(withJSONObject: ["marks": items], options: [.prettyPrinted]) else { return }
        try? data.write(to: url(in: folder), options: .atomic)
    }

    /// Пометки из файла; нет файла или он не читается — пусто.
    public static func load(from folder: URL) -> [MeetingMarkPayload] {
        guard let data = try? Data(contentsOf: url(in: folder)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["marks"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let at = (item["at"] as? NSNumber)?.doubleValue, at.isFinite, at >= 0,
                  let text = item["text"] as? String, !text.isEmpty else { return nil }
            return MeetingMarkPayload(at: at, text: text)
        }
    }
}
