import Foundation

/// Кто говорит в звонке, который рисуется веб-страницей: Google Meet в Chromium-браузере
/// и Телемост — в браузере и в десктопном клиенте (Qt 6 + QtWebEngine, там та же страница).
/// Разбор идёт по дереву Accessibility страницы: Chromium отдаёт в нём DOM-классы (`AXDOMClassList`),
/// и по ним видны плитка, подпись с именем и признак «говорит» (`docs/speaker-names-research.md`).
public enum WebCallSpeakers {
    public enum Kind: String, Sendable, CaseIterable {
        case meet, telemost
    }

    /// Узел дерева страницы — только то, что нужно разбору. Строит наблюдатель из `AXUIElement`,
    /// тесты — руками.
    public struct Node: Equatable, Sendable {
        public var role: String
        public var classes: [String]
        /// `AXTitle` или `AXDescription`: подпись строки списка участников, кнопки.
        public var label: String?
        /// `AXValue` у `AXStaticText`: видимый текст.
        public var value: String?
        /// `AXIdentifier`: в нативном Qt-клиенте Телемоста — путь объектов вида
        /// `…MainConferenceView.ControlPanelWidget.microphoneButton` (`TelemostDesktop`).
        public var identifier: String?
        /// `AXTitle` отдельно от `label`: у окна это название встречи.
        public var title: String?
        /// Высота в точках — только где она нужна разбору (блоки субтитров Meet), иначе nil.
        public var height: Double?
        public var children: [Node]
        /// `AXURL` у `AXWebArea`: адрес страницы. nil — браузер его не отдал.
        public var url: String?
        public init(role: String, classes: [String] = [], label: String? = nil, value: String? = nil,
                    identifier: String? = nil, title: String? = nil, children: [Node] = [], url: String? = nil) {
            self.role = role; self.classes = classes; self.label = label; self.value = value
            self.identifier = identifier; self.title = title; self.children = children
            self.url = url
        }

        func has(_ name: String) -> Bool { classes.contains(name) }
        func hasPrefix(_ prefix: String) -> Bool { classes.contains { $0.hasPrefix(prefix) } }

        /// Сам узел и все потомки, в глубину.
        var all: [Node] {
            var result: [Node] = []
            var pending = [self]
            while let node = pending.popLast() {
                result.append(node)
                pending.append(contentsOf: node.children.reversed())
            }
            return result
        }

        var texts: [String] {
            all.filter { $0.role == "AXStaticText" }.compactMap { WebCallSpeakers.clean($0.value) }
        }
    }

    /// Звонок по заголовку окна браузера (заголовок активной вкладки). Другие вкладки не читаем:
    /// в них чужое, а Chromium отдаёт дерево только видимой вкладки.
    public static func kind(windowTitle: String) -> Kind? {
        let title = windowTitle.lowercased()
        if title.hasPrefix("meet -") || title.hasPrefix("meet –") || title.contains("meet.google.com") { return .meet }
        if title.contains("телемост") || title.contains("telemost") { return .telemost }
        return nil
    }

    // MARK: чья это страница

    /// Заголовок окна задаёт сама страница: любая вкладка с заголовком «Meet – …» во время записи
    /// подставила бы свои «имена участников» в ленту спикеров (ревью 2026-11-14, Н9). Поэтому
    /// в браузере сверяется ещё и адрес страницы.
    public enum Origin: Equatable, Sendable {
        /// Адрес страницы — сервис звонка.
        case verified
        /// Браузер не отдал адрес ни одной страницы: читаем, как раньше, но своё имя с неё не запоминаем.
        case unknown
        /// Адрес есть, и это не сервис звонка: страницу не читаем.
        case foreign
    }

    static let meetHosts = ["meet.google.com"]
    /// Телемост живёт на `telemost.<домен Яндекса>`.
    static let telemostDomains = ["yandex.ru", "yandex.com", "yandex.kz", "yandex.by", "yandex.uz"]

    /// `extraTelemostDomains` — свои домены Телемоста (корпоративная установка): в коде их нет,
    /// берутся из настройки `telemost.extraDomains`.
    public static func isCallURL(_ text: String, kind: Kind, extraTelemostDomains: [String] = []) -> Bool {
        guard let parts = URLComponents(string: text), parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased() else { return false }
        switch kind {
        case .meet:
            return meetHosts.contains(host)
        case .telemost:
            guard host.hasPrefix("telemost.") else { return false }
            let rest = String(host.dropFirst("telemost.".count))
            let domains = telemostDomains + extraTelemostDomains.map { $0.lowercased() }.filter { !$0.isEmpty }
            return domains.contains { rest == $0 || rest.hasSuffix("." + $0) }
        }
    }

    /// Дерево окна браузера без чужих страниц и вердикт. Судим по верхним веб-областям (вложенные —
    /// фреймы самой страницы): с адресом звонка остаются, с другим адресом убираются; без адреса
    /// остаются, только если адреса нет ни у одной.
    public static func screened(_ root: Node, kind: Kind, extraTelemostDomains: [String] = []) -> (tree: Node, origin: Origin) {
        let isCallURL = { (url: String, kind: Kind) in Self.isCallURL(url, kind: kind, extraTelemostDomains: extraTelemostDomains) }
        var known = 0, calls = 0
        func count(_ node: Node) {
            if node.role == "AXWebArea" {
                if let url = node.url { known += 1; if isCallURL(url, kind) { calls += 1 } }
                return
            }
            node.children.forEach(count)
        }
        count(root)
        guard known > 0 else { return (root, .unknown) }
        guard calls > 0 else { return (Node(role: root.role), .foreign) }
        func prune(_ node: Node) -> Node? {
            if node.role == "AXWebArea" { return node.url.map { isCallURL($0, kind) } == true ? node : nil }
            var copy = node
            copy.children = node.children.compactMap(prune)
            return copy
        }
        return (prune(root) ?? Node(role: root.role), .verified)
    }

    public static func snapshot(_ root: Node, kind: Kind) -> ZoomSpeakers.Snapshot {
        switch kind {
        case .meet: return meet(root)
        case .telemost: return telemost(root)
        }
    }

    static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let joined = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return joined.isEmpty || joined.count > 100 ? nil : joined
    }

    // MARK: - Google Meet

    /// Классы Meet в Chrome — по дереву с реального звонка (открытый проект seashell, MIT).
    /// Классы Meet генерируются сборкой и меняются с обновлениями: сломается — снять дерево заново.
    enum MeetClass {
        static let tile = "oZRSLe"
        static let nameSlot = ["XEazBc", "adnwBd"]
        static let signal = ["DYfzY", "cYKTje"]
        /// Один из них у значка — человек говорит.
        static let speaking = ["Oaajhc", "HX2H7", "wEsLMd", "OgVli"]
    }

    static let meetSelfMarkers = ["(you)", "(вы)"]
    static let meetPeopleLabels = ["participants", "участники"]

    static func meet(_ root: Node) -> ZoomSpeakers.Snapshot {
        let nodes = root.all
        let isSignal: (Node) -> Bool = { node in node.role == "AXGroup" && MeetClass.signal.allSatisfy(node.has) }
        let isSpeaking: (Node) -> Bool = { node in isSignal(node) && MeetClass.speaking.contains(where: node.has) }
        var tiles: [ZoomSpeakers.Tile] = []
        var boundSpeaking = 0
        for tile in nodes where tile.role == "AXGroup" && tile.has(MeetClass.tile) {
            let contents = tile.all
            // Плитка внутри плитки — это контейнер раскладки, не участник.
            guard contents.filter({ $0.has(MeetClass.tile) }).count == 1 else { continue }
            let slots = contents.filter { $0.role == "AXGroup" && MeetClass.nameSlot.allSatisfy($0.has) }
            guard slots.count == 1, let name = single(slots[0].texts) else { continue }
            let signals = contents.filter(isSignal)
            guard signals.count <= 1 else { continue }
            let speaking = signals.contains(where: isSpeaking)
            if speaking { boundSpeaking += 1 }
            tiles.append(.init(name: name, active: speaking, isSelf: false))
        }
        // Значок «говорит» вне разобранных плиток — кто-то, кого мы не знаем. Не называем никого.
        if nodes.filter(isSpeaking).count != boundSpeaking {
            tiles = tiles.map { var tile = $0; tile.active = false; return tile }
        }
        // Своя плитка — по пометке «(You)» в открытой панели «Участники».
        var mine = Set<String>()
        for list in nodes where list.role == "AXList"
            && meetPeopleLabels.contains(where: { (list.label ?? "").lowercased().contains($0) }) {
            for row in list.children {
                guard let name = clean(row.label),
                      row.texts.contains(where: { meetSelfMarkers.contains($0.lowercased()) }) else { continue }
                mine.insert(name)
            }
        }
        if mine.count == 1, let me = mine.first, tiles.filter({ $0.name == me }).count == 1 {
            tiles = tiles.map { var tile = $0; tile.isSelf = tile.name == me; return tile }
        }
        return ZoomSpeakers.Snapshot(tiles: tiles)
    }

    // MARK: - Телемост

    /// Признак говорящего в веб-клиенте Телемоста — обводка плитки, класс `rootStroke_<хеш>`
    /// (разведка Vexa через Playwright, github.com/Vexa-ai/vexa/pull/1735). Через Accessibility
    /// пока не проверено: дерево страницы на звонке ещё не снято. Имя — ближайший текст плитки.
    static let telemostSpeakingPrefix = "rootStroke"
    /// На сколько уровней вверх от обводки искать подпись с именем.
    static let telemostNameDepth = 4

    static func telemost(_ root: Node) -> ZoomSpeakers.Snapshot {
        var tiles: [ZoomSpeakers.Tile] = []
        func walk(_ node: Node, _ path: [Node]) {
            if node.hasPrefix(telemostSpeakingPrefix) {
                // Обводка — рамка поверх плитки: имя ищем в ней самой и выше, у ближайшего предка с текстом.
                for ancestor in ([node] + path.reversed()).prefix(telemostNameDepth + 1) {
                    let texts = ancestor.texts
                    if !texts.isEmpty {
                        if let name = single(texts) ?? texts.first, !tiles.contains(where: { $0.name == name }) {
                            tiles.append(.init(name: name, active: true, isSelf: false))
                        }
                        break
                    }
                }
                return
            }
            for child in node.children { walk(child, path + [node]) }
        }
        walk(root, [])
        return ZoomSpeakers.Snapshot(tiles: tiles)
    }

    private static func single(_ texts: [String]) -> String? {
        Set(texts).count == 1 ? texts.first : nil
    }
}
