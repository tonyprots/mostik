import Foundation

/// Кто говорит в Zoom — по подписям плиток в дереве Accessibility (прототип, `docs/speaker-names-research.md`).
///
/// Zoom подписывает плитку участника в `AXDescription` строкой «Имя, Computer audio, active speaker»:
/// имя — до первой запятой, дальше — состояние звука и пометка активного говорящего. Так читают
/// имена Granola и открытый meeting-notes. Строки английского интерфейса подтверждены чужим кодом;
/// русские — догадка до снятия дерева на живом звонке (`AXTreeDump`).
public enum ZoomSpeakers {
    public static let bundleID = "us.zoom.xos"

    public struct Tile: Equatable, Sendable {
        public var name: String
        public var active: Bool
        public var isSelf: Bool
        /// Микрофон участника по подписи: true — включён, false — выключен, nil — не сказано.
        public var unmuted: Bool?
        public init(name: String, active: Bool, isSelf: Bool, unmuted: Bool? = nil) {
            self.name = name; self.active = active; self.isSelf = isSelf; self.unmuted = unmuted
        }
    }

    /// Снимок окна: плитки и свой микрофон по кнопке на панели (`id="audio"`).
    public struct Snapshot: Equatable, Sendable {
        public var tiles: [Tile]
        public var myUnmuted: Bool?
        /// Своё имя, если уже узнано раньше (`SpeakerTimelineWriter` запоминает его, пока я в звонке один).
        public var myName: String?
        public init(tiles: [Tile], myUnmuted: Bool? = nil, myName: String? = nil) {
            self.tiles = tiles; self.myUnmuted = myUnmuted; self.myName = myName
        }

        /// Номер своей плитки: помеченная «(Me)», иначе единственная с моим именем, иначе
        /// единственная, чей микрофон совпадает с моим. Имена бывают одинаковыми (один человек
        /// с двух устройств), поэтому — номер, а не имя. Микрофон — последний признак: подпись
        /// плитки отстаёт от кнопки на секунду-полторы.
        public var selfIndex: Int? {
            if let marked = tiles.firstIndex(where: \.isSelf) { return marked }
            if let myName {
                let named = tiles.indices.filter { ZoomSpeakers.key(tiles[$0].name) == ZoomSpeakers.key(myName) }
                if named.count == 1 { return named[0] }
            }
            guard let mine = myUnmuted else { return nil }
            let same = tiles.indices.filter { tiles[$0].unmuted == mine }
            return same.count == 1 && tiles.count > 1 ? same[0] : nil
        }

        /// Плитки собеседников: без своей. Своя не найдена — все (тогда двое с микрофоном — неизвестно кто).
        public var others: [Tile] {
            guard let index = selfIndex else { return tiles }
            return tiles.enumerated().filter { $0.offset != index }.map(\.element)
        }
    }

    /// Кнопка своего микрофона: «Mute my audio» — микрофон включён, «Unmute my audio» — выключен.
    public static func myAudio(from description: String) -> Bool? {
        let text = description.lowercased()
        if unmuteMeMarkers.contains(where: text.hasPrefix) { return false }
        if muteMeMarkers.contains(where: text.hasPrefix) { return true }
        return nil
    }

    static let muteMeMarkers = ["mute my audio", "mute", "выключить звук", "выключить микрофон"]
    static let unmuteMeMarkers = ["unmute my audio", "unmute", "включить звук", "включить микрофон"]

    /// Пометка «сейчас говорит».
    static let activeMarkers = ["active speaker", "активный докладчик", "активный оратор", "говорит"]
    /// Состояние звука: по нему подпись узнаётся как плитка участника, а не кнопка.
    static let audioMarkers = [
        "computer audio", "no audio connected", "phone audio", "device audio", "telephone", "call me",
        "звук компьютера", "звук не подключен", "звук не подключён", "звук телефона", "звук устройства", "телефон",
    ]
    /// Состояние микрофона в той же части подписи: «Computer audio muted / unmuted» (Zoom 7.2, проверено).
    static let mutedMarkers = ["muted", "выключен", "выкл"]
    static let unmutedMarkers = ["unmuted", "включен", "включён", "вкл"]
    /// Своя плитка: Zoom дописывает к имени «(Me)» или «(Я)».
    static let selfMarkers = ["(me)", "(я)"]
    /// Роли в скобках — не часть имени.
    static let roleMarkers = ["(host)", "(co-host)", "(guest)", "(организатор)", "(соорганизатор)", "(гость)"]

    static func key(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    public static func tile(from description: String) -> Tile? {
        let parts = description.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count >= 2, let first = parts.first, !first.isEmpty else { return nil }
        let rest = parts.dropFirst().map { $0.lowercased() }
        let active = rest.contains { part in activeMarkers.contains { part.contains($0) } }
        let audioParts = rest.filter { part in audioMarkers.contains { part.hasPrefix($0) } }
        guard active || !audioParts.isEmpty else { return nil }
        var unmuted: Bool? = nil
        for part in audioParts {
            let words = part.split(whereSeparator: { !$0.isLetter }).map(String.init)
            if words.contains(where: unmutedMarkers.contains) { unmuted = true }
            else if words.contains(where: mutedMarkers.contains) { unmuted = false }
        }
        var name = first
        var isSelf = false
        for marker in selfMarkers + roleMarkers {
            while let range = name.range(of: marker, options: .caseInsensitive) {
                if selfMarkers.contains(marker) { isSelf = true }
                name.removeSubrange(range)
            }
        }
        name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return name.isEmpty ? nil : Tile(name: name, active: active, isSelf: isSelf, unmuted: unmuted)
    }
}

/// Лента `speaker-timeline.jsonl` в папке встречи: строка — только при смене того, кто говорит.
/// Формат читает движок (`speaker_timeline.py`): `{"at", "active", "unmuted", "present", "self", "source"}`,
/// `at` — часы встречи. `active` — собеседники с пометкой «говорит», `unmuted` — собеседники
/// с включённым микрофоном (своя плитка уже убрана), `self` — своё имя, `present` — все плитки
/// в окне: по ним движок называет единственного собеседника, когда пометок не хватило.
public struct SpeakerTimelineWriter: Sendable {
    public static let fileName = "speaker-timeline.jsonl"
    /// Столько секунд подряд одна плитка с моим микрофоном — и это я: в звонке пока никого.
    public static let aloneSeconds = 5.0
    public let source: String
    private var last: [String: [String]]? = nil
    private var own = Set<String>()
    private var myName: String?
    private var alone: (name: String, since: Double)?
    /// Свои имена, известные заранее: имя учётной записи macOS (у многих оно совпадает с именем в Zoom)
    /// и имена, узнанные на прошлых встречах. Плитка с таким именем — я, даже если отметки «(я)» нет,
    /// панель с кнопкой микрофона спрятана и одному в звонке побыть не довелось.
    private let knownKeys: Set<String>

    public init(source: String, accountName: String? = nil, knownSelf: [String] = []) {
        self.source = source
        knownKeys = Set(([accountName].compactMap { $0 } + knownSelf).map(Self.key).filter { !$0.isEmpty })
    }

    /// Своё имя, узнанное на этой встрече любым способом, — его стоит запомнить до следующей.
    public var learnedName: String? { myName }

    private static func key(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// Снимок окна → строка ленты, если сменились говорящие, микрофоны или состав; иначе nil.
    public mutating func observe(_ snapshot: ZoomSpeakers.Snapshot, at: Double) -> String? {
        if myName == nil, !knownKeys.isEmpty {
            // Ровно одна знакомая плитка: две — это два устройства одного человека или тёзки, не угадываем.
            let known = snapshot.tiles.filter { knownKeys.contains(Self.key($0.name)) }
            if known.count == 1 { myName = known[0].name }
        }
        rememberSelf(snapshot, at: at)
        var snapshot = snapshot
        snapshot.myName = snapshot.myName ?? myName
        for tile in snapshot.tiles where tile.isSelf { own.insert(tile.name) }
        if let myName { own.insert(myName) }
        let others = snapshot.others
        let state = [
            "active": Array(Set(others.filter(\.active).map(\.name))).sorted(),
            // Без своей плитки открытые микрофоны не годятся: свой среди них неотличим.
            "unmuted": snapshot.selfIndex == nil ? [] : others.filter { $0.unmuted == true }.map(\.name).sorted(),
            "present": Array(Set(snapshot.tiles.map(\.name))).sorted(),
            "self": own.sorted(),
        ]
        guard state != last else { return nil }
        last = state
        let row: [String: Any] = ["at": (at * 100).rounded() / 100, "active": state["active"]!,
                                  "unmuted": state["unmuted"]!, "present": state["present"]!,
                                  "self": state["self"]!, "source": source]
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return nil }
        return line
    }

    /// Своё имя: одна плитка, микрофон совпадает с кнопкой, и так `aloneSeconds` подряд.
    /// Одна плитка без кнопки не годится: так выглядит и чужая плитка, пока грузятся остальные.
    private mutating func rememberSelf(_ snapshot: ZoomSpeakers.Snapshot, at: Double) {
        guard myName == nil else { return }
        guard snapshot.tiles.count == 1, let tile = snapshot.tiles.first else {
            if !snapshot.tiles.isEmpty { alone = nil }
            return
        }
        guard let mine = snapshot.myUnmuted else { return }  // панель спрятана: не сбиваем отсчёт
        guard tile.unmuted == mine else { return }  // подпись отстаёт от кнопки: ждём
        if let current = alone, ZoomSpeakers.key(current.name) == ZoomSpeakers.key(tile.name) {
            if at - current.since >= Self.aloneSeconds { myName = tile.name }
        } else {
            alone = (tile.name, at)
        }
    }

    /// Плитки без кнопки своего микрофона (старые вызовы и тесты).
    public mutating func observe(_ tiles: [ZoomSpeakers.Tile], at: Double) -> String? {
        observe(ZoomSpeakers.Snapshot(tiles: tiles), at: at)
    }

    /// Пауза записи или звонок пропал: следующий снимок пишется заново, даже тот же.
    public mutating func reset() { last = nil }
}
